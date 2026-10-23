@Library('Shared') _

// =============================================================================
//  dev-build.groovy — ecom CI pipeline (Phase 2)
// =============================================================================
//  FLOW:
//    validate → checkout → trivy (filesystem) → OWASP → SonarQube →
//    parallel build+scan+push (4 services) → update values-prod.yaml → git push
//
//  WHY PARALLEL:
//    4 Spring Boot services × ~3 min each = 12 min sequential.
//    Parallel = ~3 min (limited by the longest single build).
//
//  IMAGE TAGGING: always :<GIT_SHA>  — never :latest
//    :latest = can't trace what's running, stale-cache bugs, rollback impossible
//    :abc1234 = unique, immutable, traceable to an exact git commit
//
//  ECR AUTH: no stored credentials — Jenkins EC2 instance role has
//    ecr:GetAuthorizationToken + ecr:BatchCheckLayerAvailability + ecr:PutImage
// =============================================================================

pipeline {
    agent any

    environment {
        SONAR_HOME   = tool "Sonar"
        ECR_REGISTRY = "656022989575.dkr.ecr.us-east-2.amazonaws.com"
        AWS_REGION   = "us-east-2"
        // Role assumed per-build for ECR push — instance role only needs sts:AssumeRole
        // Get this ARN from: terraform output jenkins_ci_role_arn  (after applying iam-jenkins.tf)
        ECR_ROLE_ARN = "arn:aws:iam::656022989575:role/CartOps-Jenkins-CI-Role"
    }

    parameters {
        string(
            name: 'IMAGE_TAG',
            defaultValue: '',
            description: 'Git SHA tag applied to all 4 service images (git rev-parse --short HEAD)'
        )
    }

    stages {

        // ── 1. Validate ───────────────────────────────────────────────────────
        stage("Validate Parameters") {
            steps {
                script {
                    if (params.IMAGE_TAG == '') {
                        error("IMAGE_TAG must be provided. Use: git rev-parse --short HEAD")
                    }
                }
            }
        }

        // ── 2. Clean workspace ────────────────────────────────────────────────
        stage("Workspace Cleanup") {
            steps {
                script { cleanWs() }
            }
        }

        // ── 3. Checkout ───────────────────────────────────────────────────────
        stage("Git: Code Checkout") {
            steps {
                script {
                    code_checkout("https://github.com/sanketire45/CartOps.git", "main")
                }
            }
        }

        // ── 4. Trivy filesystem scan (pre-build) ──────────────────────────────
        // Scans SOURCE CODE: pom.xml deps, Dockerfile misconfigs, hardcoded secrets.
        // Fails pipeline on CRITICAL/HIGH — no point building a vulnerable codebase.
        stage("Trivy: Filesystem Scan") {
            steps {
                script { trivy_scan() }
            }
        }

        // ── 5. OWASP dependency check ─────────────────────────────────────────
        stage("OWASP: Dependency Check") {
            steps {
                script { owasp_dependency() }
            }
        }

        // ── 6. SonarQube ──────────────────────────────────────────────────────
        stage("SonarQube: Code Analysis") {
            steps {
                script { sonarqube_analysis("Sonar", "ecom", "ecom") }
            }
        }

        stage("SonarQube: Quality Gate") {
            steps {
                script { sonarqube_code_quality() }
            }
        }

        // ── 7. Parallel build + Trivy image scan + ECR push ───────────────────
        // Each service: docker build → trivy image scan → aws ecr login → docker push
        // All 4 run simultaneously — total time = longest single build (~3 min)
        stage("Docker: Build + Scan + Push (parallel)") {
            parallel {

                stage("product-category") {
                    steps {
                        script {
                            dir('ProductAndCategoryMicroservice') {
                                docker_build("ecom-product-category", params.IMAGE_TAG, env.ECR_REGISTRY)
                                trivy_image_scan("${env.ECR_REGISTRY}/ecom-product-category:${params.IMAGE_TAG}")
                                ecr_push("ecom-product-category", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

                stage("order-service") {
                    steps {
                        script {
                            dir('orderMicroservice') {
                                docker_build("ecom-order-service", params.IMAGE_TAG, env.ECR_REGISTRY)
                                trivy_image_scan("${env.ECR_REGISTRY}/ecom-order-service:${params.IMAGE_TAG}")
                                ecr_push("ecom-order-service", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

                stage("eureka-server") {
                    steps {
                        script {
                            dir('Servicediscoverywitheureka') {
                                docker_build("ecom-eureka-server", params.IMAGE_TAG, env.ECR_REGISTRY)
                                trivy_image_scan("${env.ECR_REGISTRY}/ecom-eureka-server:${params.IMAGE_TAG}")
                                ecr_push("ecom-eureka-server", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

                stage("frontend") {
                    steps {
                        script {
                            dir('frontend') {
                                docker_build("ecom-frontend", params.IMAGE_TAG, env.ECR_REGISTRY)
                                trivy_image_scan("${env.ECR_REGISTRY}/ecom-frontend:${params.IMAGE_TAG}")
                                ecr_push("ecom-frontend", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

            }
        }

        // ── 8. Helm lint — validate templates render correctly before pushing ─────
        // Catches typos or bad template syntax early. Runs offline, no cluster needed.
        // stage("Helm: Lint + Template Check") {
        //     steps {
        //         script {
        //             sh """
        //                 helm lint helm/ecom/ -f helm/ecom/values-prod.yaml --set \
        //                     product.image=${env.ECR_REGISTRY}/ecom-product-category:${params.IMAGE_TAG} \
        //                     --set order.image=${env.ECR_REGISTRY}/ecom-order-service:${params.IMAGE_TAG} \
        //                     --set eureka.image=${env.ECR_REGISTRY}/ecom-eureka-server:${params.IMAGE_TAG} \
        //                     --set frontend.image=${env.ECR_REGISTRY}/ecom-frontend:${params.IMAGE_TAG}
        //                 helm template ecom helm/ecom/ -f helm/ecom/values-prod.yaml > /dev/null
        //                 echo "Helm lint + template render: OK"
        //             """
        //         }
        //     }
        // }

        // ── 9. GitOps trigger — update values-prod.yaml with new SHA ──────────
        // Replaces whatever :tag is in the file with the new SHA — works on every run,
        // not just the first one. The naive 's/:IMAGE_TAG/:sha/g' breaks after run #1
        // because the placeholder is gone. The -E regex below matches any existing tag.
        // ArgoCD watches the repo — detects this commit → runs helm upgrade → deploys.
        stage("GitOps: Update Image Tag") {
            steps {
                script {
                    withCredentials([gitUsernamePassword(credentialsId: 'github', gitToolName: 'Default')]) {
                        sh """
                            sed -i -E 's|(image: [^:]+:)[^[:space:]]+|\\1${params.IMAGE_TAG}|g' \
                                helm/ecom/values-prod.yaml

                            echo "--- Updated image tags ---"
                            grep 'image:' helm/ecom/values-prod.yaml

                            git config user.email "jenkins@ecom.local"
                            git config user.name  "Jenkins CI"
                            git add helm/ecom/values-prod.yaml
                            git commit -m "ci: bump image tag to ${params.IMAGE_TAG} [skip ci]"
                            git push origin main
                        """
                    }
                }
            }
        }

    }

    post {
        success {
            archiveArtifacts artifacts: '*.xml', allowEmptyArchive: true
            echo "Build ${params.IMAGE_TAG} pushed to ECR. ArgoCD will deploy shortly."
        }
        failure {
            emailext(
                attachLog: true,
                subject: "CartOps CI FAILED — build #${env.BUILD_NUMBER} tag ${params.IMAGE_TAG}",
                body: """Build #${env.BUILD_NUMBER} failed.
Tag     : ${params.IMAGE_TAG}
Console : ${env.BUILD_URL}

Check the attached log for the failing stage.""",
                to: 'swapnilyadavfy2526@gmail.com'
            )
        }
    }
}
