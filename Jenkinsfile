// ==============================================================================
// Pockit Finance - Jenkins Declarative CI/CD Pipeline (Hermes QA / Zeus PROD)
// ==============================================================================

pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
    }

    parameters {
        choice(
            name: 'TARGET_ENV',
            choices: ['hermes', 'zeus'],
            description: 'Ambiente destino en OCI (hermes = QA, zeus = Produccion)'
        )
        choice(
            name: 'SERVICE',
            choices: ['all', 'pockit-ms-auth-user', 'pockit-api-gateway'],
            description: 'Microservicio a compilar, analizar y desplegar'
        )
    }

    environment {
        GIT_BRANCH_DEFAULT  = "${params.TARGET_ENV == 'zeus' ? 'main' : 'develop'}"
        OCI_DEPLOY_PATH     = '/opt/pockit-finance'
        SONAR_SERVER_NAME   = 'SonarQube'
        IMAGE_TAG           = "${params.TARGET_ENV}-${env.BUILD_NUMBER}"
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    def targetServices = params.SERVICE == 'all'
                        ? ['pockit-ms-auth-user', 'pockit-api-gateway']
                        : [params.SERVICE]

                    env.TARGET_SERVICES = targetServices.join(',')
                    echo "=== Pockit Finance CI/CD | Ambiente: ${params.TARGET_ENV} | Servicios: ${env.TARGET_SERVICES} ==="

                    checkout scm

                    withCredentials([string(credentialsId: 'pockit-git-org-url', variable: 'GIT_ORG_URL')]) {
                        for (String svc : targetServices) {
                            dir("../${svc}") {
                                checkout([
                                    $class: 'GitSCM',
                                    branches: [[name: "*/${env.GIT_BRANCH_DEFAULT}"]],
                                    userRemoteConfigs: [[
                                        url: "${GIT_ORG_URL}/${svc}.git",
                                        credentialsId: 'pockit-git-credentials'
                                    ]]
                                ])
                            }
                        }
                    }
                }
            }
        }

        stage('Build, Unit Tests & JaCoCo (>= 80%)') {
            steps {
                script {
                    def targetServices = env.TARGET_SERVICES.split(',')
                    for (String svc : targetServices) {
                        echo ">>> Ejecutando ./mvnw clean verify (Tests + JaCoCo >= 80%) en ${svc}"
                        dir("../${svc}") {
                            sh 'chmod +x ./mvnw'
                            sh './mvnw -B clean verify'
                            junit allowEmptyResults: false, testResults: 'target/surefire-reports/*.xml'
                            jacoco(
                                execPattern: 'target/jacoco.exec',
                                classPattern: 'target/classes',
                                sourcePattern: 'src/main/java',
                                changeBuildStatus: true,
                                minimumLineCoverage: '80',
                                minimumBranchCoverage: '80'
                            )
                        }
                    }
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                script {
                    def targetServices = env.TARGET_SERVICES.split(',')
                    for (String svc : targetServices) {
                        echo ">>> Ejecutando analisis SonarQube en ${svc}"
                        dir("../${svc}") {
                            withSonarQubeEnv("${env.SONAR_SERVER_NAME}") {
                                sh """
                                    ./mvnw -B sonar:sonar \
                                      -Dsonar.projectKey=${svc} \
                                      -Dsonar.projectName=${svc} \
                                      -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
                                """
                            }
                        }
                        timeout(time: 5, unit: 'MINUTES') {
                            waitForQualityGate abortPipeline: true
                        }
                    }
                }
            }
        }

        stage('Docker Multi-Stage Build (JRE 21 Alpine)') {
            steps {
                script {
                    def targetServices = env.TARGET_SERVICES.split(',')
                    for (String svc : targetServices) {
                        echo ">>> Construyendo imagen Docker multi-stage (JRE 21 Alpine) para ${svc}:${env.IMAGE_TAG}"
                        dir("../${svc}") {
                            sh """
                                docker build \
                                  --pull \
                                  --tag ${svc}:${env.IMAGE_TAG} \
                                  --tag ${svc}:${params.TARGET_ENV} \
                                  -f Dockerfile .
                            """
                        }
                    }
                }
            }
        }

        stage('SSH Deploy OCI') {
            steps {
                script {
                    def sshCredId  = "oci-${params.TARGET_ENV}-ssh-key"
                    def hostCredId = "oci-${params.TARGET_ENV}-host"
                    def composeFile = "docker-compose.${params.TARGET_ENV}.yml"
                    def envFile     = ".env.${params.TARGET_ENV}"
                    def composeServices = params.SERVICE == 'all' ? '' : params.SERVICE

                    withCredentials([
                        string(credentialsId: hostCredId, variable: 'OCI_HOST'),
                        sshUserPrivateKey(
                            credentialsId: sshCredId,
                            keyFileVariable: 'SSH_KEY_FILE',
                            usernameVariable: 'OCI_USER'
                        )
                    ]) {
                        echo ">>> Desplegando en OCI (${params.TARGET_ENV}) usando ${composeFile}"
                        sh """
                            set -euo pipefail
                            SSH_OPTS="-i \${SSH_KEY_FILE} -o StrictHostKeyChecking=no -o BatchMode=yes"

                            # Sincronizar archivos de infraestructura al servidor OCI
                            rsync -avz -e "ssh \${SSH_OPTS}" \
                              --exclude='.git' \
                              --exclude='.env*' \
                              --exclude='certs/generated' \
                              ./ "\${OCI_USER}@\${OCI_HOST}:${env.OCI_DEPLOY_PATH}/pockit-infra-devops/"

                            # Ejecutar despliegue Docker Compose en OCI
                            ssh \${SSH_OPTS} "\${OCI_USER}@\${OCI_HOST}" "
                              set -euo pipefail
                              cd ${env.OCI_DEPLOY_PATH}/pockit-infra-devops
                              chmod +x certs/generate-mtls-certs.sh
                              docker compose --env-file ${envFile} -f ${composeFile} up -d --build ${composeServices}
                              docker image prune -f --filter 'until=72h'
                            "
                        """
                    }
                }
            }
        }

        stage('Smoke Check /actuator/health') {
            steps {
                script {
                    def healthUrlCredId = "oci-${params.TARGET_ENV}-gateway-url"
                    withCredentials([string(credentialsId: healthUrlCredId, variable: 'GATEWAY_BASE_URL')]) {
                        echo ">>> Validando Smoke Check en ${GATEWAY_BASE_URL}/actuator/health"
                        sh """
                            set -euo pipefail
                            curl -fsS --retry 10 --retry-delay 5 --retry-connrefused \
                              "\${GATEWAY_BASE_URL}/actuator/health"
                            echo ""
                            echo "[OK] Smoke Check /actuator/health superado en ${params.TARGET_ENV}."
                        """
                    }
                }
            }
        }
    }

    post {
        always {
            echo "Pipeline finalizado para ambiente '${params.TARGET_ENV}' y servicio '${params.SERVICE}' con estado: ${currentBuild.currentResult}"
        }
        success {
            echo "[SUCCESS] Despliegue verificado correctamente en OCI (${params.TARGET_ENV})."
        }
        failure {
            echo "[FAILURE] El pipeline fallo en ambiente '${params.TARGET_ENV}'. Revisar logs de etapa."
        }
    }
}
