pipeline {
  agent any

  environment {
    REGISTRY      = 'ghcr.io'
    IMAGE_NAME    = 'tariqasifi/sportstore'
    APP_SERVER    = '192.168.30.20'
    SSH_CREDENTIALS = 'ssh-appserver'
  }

  triggers {
    githubPush()
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Restore') {
      steps { sh 'dotnet restore src/Server/Server.csproj' }
    }

    stage('Build .NET') {
      steps { sh 'dotnet build' }
    }

    stage('Test') {
      steps {
        sh '''
          dotnet restore tests/Domain.Tests/Domain.Tests.csproj
          dotnet test tests/Domain.Tests/Domain.Tests.csproj
        '''
      }
    }

    stage('Docker Login') {
      steps {
        withCredentials([string(credentialsId: 'Token-GHCR', variable: 'GITHUB_TOKEN')]) {
          sh 'echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin'
        }
      }
    }

    stage('Generate Tag') {
      steps {
        script {
          def date = new Date().format("yyyyMMdd-HHmmss", TimeZone.getTimeZone('Europe/Brussels'))
          def branch = env.GIT_BRANCH?.replaceAll('origin/', '') ?: 'main'
          env.IMAGE_TAG = "${branch}-${date}"
          echo "Generated image tag: ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Docker Build & Push') {
      steps {
        script {
          sh """
            docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} -f src/Dockerfile .

            docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} --disable-content-trust=true

            docker tag ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest
            docker push ${REGISTRY}/${IMAGE_NAME}:latest --disable-content-trust=true
          """
        }
      }
    }

    stage('Deploy to Appserver via SSH') {
      environment { GITHUB_TOKEN = credentials('Token-GHCR') }
      steps {
        sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
          // Let op: we exporteren env vars naar de remote sessie.
          sh '''#!/bin/bash
set -euo pipefail
ssh -o StrictHostKeyChecking=no vagrant@${APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN}; export REGISTRY=${REGISTRY}; export IMAGE_NAME=${IMAGE_NAME}; bash -s" << 'ENDSSH'
set -euo pipefail

echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin || {
  echo "Docker login to GHCR failed"; exit 1;
}

docker rm -f sportstore-app || true
docker rm -f sqlserver || true

docker network create app-net || true

docker pull ${REGISTRY}/${IMAGE_NAME}:latest

docker run -d --name sqlserver \
  -e "ACCEPT_EULA=Y" \
  -e "SA_PASSWORD=Hogent2425" \
  --network app-net \
  -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2022-latest

docker run -d \
  -e DB_IP=sqlserver \
  -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa \
  -e DB_PASSWORD=Hogent2425 \
  -e HTTP_PORT=80 \
  -e HTTPS_PORT=443 \
  -e ENVIRONMENT=Production \
  -p 80:80 -p 443:443 \
  --name sportstore-app \
  --network app-net \
  ${REGISTRY}/${IMAGE_NAME}:latest
ENDSSH
'''
        }
      }
    }
  }
}
