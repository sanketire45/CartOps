@Library('Shared') _

// =============================================================================
//  dev-build.groovy — ecom CI pipeline (Phase 2)
// =============================================================================
//  FLOW:
//    validate → checkout → trivy (filesystem) → OWASP → SonarQube →
//    parallel build+scan+push (4 services) → update values-dev.yaml → git push
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
        SONAR_HOME       = tool "Sonar"
        ECR_REGISTRY     = "656022989575.dkr.ecr.us-east-2.amazonaws.com"
        AWS_REGION       = "us-east-2"
        ECR_ROLE_ARN     = "arn:aws:iam::656022989575:role/CartOps-Jenkins-CI-Role"
        DOCKER_BUILDKIT  = "1"   // required for --mount=type=cache in Dockerfiles
    }

    parameters {
        string(
            name: 'IMAGE_TAG',
            defaultValue: 'v0.0.0',
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
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    script { owasp_dependency() }
                }
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

        // ── 7a. Parallel build (all 5 services) ──────────────────────────────────
        // Build all images first. If ANY build fails the pipeline stops here —
        // nothing is pushed to ECR, so there is no partial-push state to clean up.
        stage("Docker: Build (parallel)") {
            parallel {

                stage("product-category") {
                    steps {
                        script {
                            dir('ProductAndCategoryMicroservice') {
                                docker_build("ecom-product-category", params.IMAGE_TAG, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

                stage("order-service") {
                    steps {
                        script {
                            dir('orderMicroservice') {
                                docker_build("ecom-order-service", params.IMAGE_TAG, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

                stage("eureka-server") {
                    steps {
                        script {
                            dir('Servicediscoverywitheureka') {
                                docker_build("ecom-eureka-server", params.IMAGE_TAG, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

                stage("frontend") {
                    steps {
                        script {
                            dir('frontend') {
                                docker_build("ecom-frontend", params.IMAGE_TAG, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

                stage("notification-worker") {
                    steps {
                        script {
                            dir('notificationWorker') {
                                docker_build("ecom-notification-worker", params.IMAGE_TAG, env.ECR_REGISTRY)
                            }
                        }
                    }
                }

            }
        }

        // ── 7b. Parallel ECR push (all 5 services) ───────────────────────────────
        // Only reached when all 5 builds above succeeded.
        // Pushes atomically — ArgoCD never sees a tag that exists in Git but is
        // missing from ECR.
        stage("Docker: Push to ECR (parallel)") {
            parallel {

                stage("product-category") {
                    steps {
                        script {
                            ecr_push("ecom-product-category", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
                        }
                    }
                }

                stage("order-service") {
                    steps {
                        script {
                            ecr_push("ecom-order-service", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
                        }
                    }
                }

                stage("eureka-server") {
                    steps {
                        script {
                            ecr_push("ecom-eureka-server", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
                        }
                    }
                }

                stage("frontend") {
                    steps {
                        script {
                            ecr_push("ecom-frontend", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
                        }
                    }
                }

                stage("notification-worker") {
                    steps {
                        script {
                            ecr_push("ecom-notification-worker", params.IMAGE_TAG, env.AWS_REGION, env.ECR_REGISTRY)
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
        //                 helm lint helm/ecom/ -f helm/ecom/values-dev.yaml --set \
        //                     product.image=${env.ECR_REGISTRY}/ecom-product-category:${params.IMAGE_TAG} \
        //                     --set order.image=${env.ECR_REGISTRY}/ecom-order-service:${params.IMAGE_TAG} \
        //                     --set eureka.image=${env.ECR_REGISTRY}/ecom-eureka-server:${params.IMAGE_TAG} \
        //                     --set frontend.image=${env.ECR_REGISTRY}/ecom-frontend:${params.IMAGE_TAG}
        //                 helm template ecom helm/ecom/ -f helm/ecom/values-dev.yaml > /dev/null
        //                 echo "Helm lint + template render: OK"
        //             """
        //         }
        //     }
        // }

        // ── 9. GitOps trigger — update values-dev.yaml with new SHA ───────────
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
                                helm/ecom/values-dev.yaml

                            echo "--- Updated image tags ---"
                            grep 'image:' helm/ecom/values-dev.yaml

                            git config user.email "jenkins@ecom.local"
                            git config user.name  "Jenkins CI"
                            git add helm/ecom/values-dev.yaml
                            if git diff --cached --quiet; then
                                echo "No tag change — values-dev.yaml already at ${params.IMAGE_TAG}, skipping commit"
                            else
                                git commit -m "ci: bump image tag to ${params.IMAGE_TAG} [skip ci]"
                                git push origin main
                            fi
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
                to: 'sanketire97@gmail.com'
            )
        }
    }
}
