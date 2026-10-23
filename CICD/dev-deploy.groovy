@Library('Shared') _

// =============================================================================
//  dev-deploy.groovy — CartOps MANUAL PROMOTION / ROLLBACK pipeline
// =============================================================================
//  USE THIS WHEN:
//    • Rolling back a bad deploy: provide the last known-good IMAGE_TAG
//    • Promoting a specific build to prod without re-running full CI
//    • Testing a specific image tag on the cluster
//
//  NORMAL FLOW (automated):
//    dev-build.groovy handles the full CI + GitOps update automatically.
//    This pipeline is for MANUAL intervention only.
//
//  HOW IT WORKS:
//    1. Takes an IMAGE_TAG (git SHA, e.g. abc1234)
//    2. Updates helm/ecom/values-prod.yaml with that exact tag for all 4 services
//    3. Commits + pushes to main → ArgoCD detects → helm upgrade runs
//
//  ROLLBACK EXAMPLE:
//    Last good tag was abc1234, bad deploy is def5678.
//    Run this pipeline with IMAGE_TAG=abc1234 → ArgoCD rolls back.
// =============================================================================

pipeline {
    agent any

    environment {
        REPO_URL   = "https://github.com/sanketire45/CartOps.git"
        AWS_REGION = "us-east-2"
    }

    parameters {
        string(
            name: 'IMAGE_TAG',
            defaultValue: '',
            description: 'Git SHA tag to deploy/rollback to (e.g. abc1234). All 4 services will use this tag.'
        )
        choice(
            name: 'ACTION',
            choices: ['promote', 'rollback'],
            description: 'promote = deploy a new tag | rollback = revert to a previous known-good tag'
        )
    }

    stages {

        // ── 1. Validate ───────────────────────────────────────────────────────
        stage("Validate Parameters") {
            steps {
                script {
                    if (params.IMAGE_TAG == '') {
                        error("IMAGE_TAG is required. Use the git SHA of the image you want to deploy.")
                    }
                    echo "Action  : ${params.ACTION}"
                    echo "Tag     : ${params.IMAGE_TAG}"
                    echo "This will update all 4 service images in helm/ecom/values-prod.yaml"
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
                    code_checkout(env.REPO_URL, "main")
                }
            }
        }

        // ── 4. Verify the image tag exists in ECR before deploying ────────────
        // Prevents deploying a tag that was never pushed (typo, failed CI, etc.)
        stage("ECR: Verify Tag Exists") {
            steps {
                script {
                    def repos = [
                        "ecom-product-category",
                        "ecom-order-service",
                        "ecom-eureka-server",
                        "ecom-frontend"
                    ]
                    def accountId = sh(
                        script: "aws sts get-caller-identity --query Account --output text",
                        returnStdout: true
                    ).trim()

                    repos.each { repo ->
                        def exists = sh(
                            script: """
                                aws ecr describe-images \
                                    --repository-name ${repo} \
                                    --image-ids imageTag=${params.IMAGE_TAG} \
                                    --region ${env.AWS_REGION} \
                                    --query 'imageDetails[0].imageTags' \
                                    --output text 2>/dev/null || echo 'NOT_FOUND'
                            """,
                            returnStdout: true
                        ).trim()

                        if (exists == 'NOT_FOUND' || exists == '') {
                            error("Tag '${params.IMAGE_TAG}' not found in ECR repo '${repo}'. Aborting.")
                        }
                        echo "✅ ${repo}:${params.IMAGE_TAG} verified in ECR"
                    }
                }
            }
        }

        // ── 5. Update values-prod.yaml with the target tag ────────────────────
        // Replaces whatever tag is currently in the file with the target tag.
        // Works for both forward promotion and rollback — same operation.
        stage("GitOps: Update Image Tag") {
            steps {
                script {
                    sh """
                        # Replace any existing :<sha> tag in the ECR image lines
                        # Pattern matches: <account>.dkr.ecr.<region>.amazonaws.com/<repo>:<anything>
                        sed -i -E 's|(image: [^:]+:)[^[:space:]]+|\\1${params.IMAGE_TAG}|g' \
                            helm/ecom/values-prod.yaml

                        echo "--- Updated values-prod.yaml ---"
                        grep 'image:' helm/ecom/values-prod.yaml
                    """
                }
            }
        }

        // ── 6. Commit and push → ArgoCD picks up and deploys ─────────────────
        stage("Git: Commit + Push") {
            steps {
                script {
                    withCredentials([gitUsernamePassword(credentialsId: 'github', gitToolName: 'Default')]) {
                        sh """
                            git config user.email "jenkins@ecom.local"
                            git config user.name  "Jenkins CD"
                            git add helm/ecom/values-prod.yaml
                            git commit -m "cd: ${params.ACTION} image tag ${params.IMAGE_TAG} [skip ci]"
                            git push ${env.REPO_URL} main
                        """
                    }
                }
            }
        }

    }

    post {
        success {
            echo """
            ✅ ${params.ACTION.capitalize()} complete.
            Tag     : ${params.IMAGE_TAG}
            ArgoCD will detect this commit and run helm upgrade within ~30 seconds.
            Monitor: kubectl rollout status deployment/product-category -n ecom
            """
        }
        failure {
            echo "❌ ${params.ACTION.capitalize()} failed at tag ${params.IMAGE_TAG}. No changes were pushed. Check stage logs above."
        }
    }
}
