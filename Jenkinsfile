pipeline {
  agent any

  environment {
    REGISTRY               = 'ghcr.io'
    IMAGE_NAME             = 'tariqasifi/sportstore'

    // Lokaal
    APP_SERVER             = '192.168.30.20'
    SSH_CREDENTIALS        = 'ssh-appserver'

    // Cloud
    CLOUD_APP_SERVER       = '4.231.232.243'
    CLOUD_USER             = 'azureuser'
    CLOUD_SSH_CREDENTIALS  = 'ssh-azure-appserver'
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
        sh """
          docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} -f src/Dockerfile .
          docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} --disable-content-trust=true
          docker tag ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest
          docker push ${REGISTRY}/${IMAGE_NAME}:latest --disable-content-trust=true
        """
      }
    }

    // --------- DEPLOY LOCAL ----------
    stage('Deploy to Local Appserver via SSH') {
      environment { GITHUB_TOKEN = credentials('Token-GHCR') }
      steps {
        sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
          sh '''#!/bin/bash
ssh -o StrictHostKeyChecking=no vagrant@${APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN}; export REGISTRY=${REGISTRY}; export IMAGE_NAME=${IMAGE_NAME}; bash -s" << 'ENDSSH'
set -euo pipefail

# Login GHCR
echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin

# Containers opruimen (negeer als ze niet bestaan)
docker rm -f sportstore-app || true
docker rm -f sqlserver || true

# Netwerk aanmaken indien nodig
docker network create app-net || true

# === Certificaten (idempotent) ===
# SQL cert/key
[ -f sql.key ] || openssl genrsa -out sql.key 2048
[ -f sql.crt ] || (openssl req -new -key sql.key -out sql.csr -subj "/CN=localhost" && openssl x509 -req -days 365 -in sql.csr -signkey sql.key -out sql.crt && rm -f sql.csr)
chmod 600 sql.key sql.crt || true

# App cert/key (PEM + KEY voor Kestrel)
[ -f app.key ] || openssl genrsa -out app.key 2048
[ -f app.crt ] || openssl req -x509 -new -nodes -key app.key -sha256 -days 365 -subj "/CN=localhost" -out app.crt
chmod 600 app.key app.crt || true

# Image ophalen
docker pull ${REGISTRY}/${IMAGE_NAME}:latest

# SQL Server container
docker run -d --name sqlserver \
  -e "ACCEPT_EULA=Y" \
  -e "SA_PASSWORD=Hogent2425" \
  -v $PWD/sql.crt:/var/opt/mssql/certs/sql.crt:ro \
  -v $PWD/sql.key:/var/opt/mssql/certs/sql.key:ro \
  --network app-net -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2022-latest

# .NET app met TLS files gemount (paden die je image verwacht)
docker run -d --name sportstore-app \
  -e DB_IP=sqlserver \
  -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa \
  -e DB_PASSWORD=Hogent2425 \
  -e HTTP_PORT=80 \
  -e HTTPS_PORT=443 \
  -e ENVIRONMENT=Production \
  -v $PWD/app.crt:/app/certificate.pem:ro \
  -v $PWD/app.key:/app/certificate.key:ro \
  --network app-net -p 80:80 -p 443:443 \
  ${REGISTRY}/${IMAGE_NAME}:latest
ENDSSH
'''
        }
      }
    }

    // --------- DEPLOY CLOUD ----------
    stage('Deploy to Cloud Appserver via SSH') {
      environment { GITHUB_TOKEN = credentials('Token-GHCR') }
      steps {
        sshagent(credentials: ["${CLOUD_SSH_CREDENTIALS}"]) {
          sh '''#!/bin/bash
ssh -o StrictHostKeyChecking=no ${CLOUD_USER}@${CLOUD_APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN}; export REGISTRY=${REGISTRY}; export IMAGE_NAME=${IMAGE_NAME}; bash -s" << 'ENDSSH'
set -euo pipefail

# Docker installeren & starten indien nodig
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi

# Login GHCR (sudo ivm docker.sock permissies)
echo "$GITHUB_TOKEN" | sudo docker login ghcr.io -u tariqasifi --password-stdin

# Containers opruimen
sudo docker rm -f sportstore-app || true
sudo docker rm -f sqlserver || true

# Netwerk aanmaken indien nodig
sudo docker network create app-net || true

# === Certificaten (idempotent) ===
# SQL cert/key
[ -f sql.key ] || openssl genrsa -out sql.key 2048
[ -f sql.crt ] || (openssl req -new -key sql.key -out sql.csr -subj "/CN=localhost" && openssl x509 -req -days 365 -in sql.csr -signkey sql.key -out sql.crt && rm -f sql.csr)
chmod 600 sql.key sql.crt || true

# App cert/key (PEM + KEY voor Kestrel)
[ -f app.key ] || openssl genrsa -out app.key 2048
[ -f app.crt ] || openssl req -x509 -new -nodes -key app.key -sha256 -days 365 -subj "/CN=localhost" -out app.crt
chmod 600 app.key app.crt || true

# Image ophalen
sudo docker pull ${REGISTRY}/${IMAGE_NAME}:latest

# SQL Server container
sudo docker run -d --name sqlserver \
  -e "ACCEPT_EULA=Y" \
  -e "SA_PASSWORD=Hogent2425" \
  -v $PWD/sql.crt:/var/opt/mssql/certs/sql.crt:ro \
  -v $PWD/sql.key:/var/opt/mssql/certs/sql.key:ro \
  --network app-net -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2022-latest

# .NET app met TLS files gemount (paden die je image verwacht)
sudo docker run -d --name sportstore-app \
  -e DB_IP=sqlserver \
  -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa \
  -e DB_PASSWORD=Hogent2425 \
  -e HTTP_PORT=80 \
  -e HTTPS_PORT=443 \
  -e ENVIRONMENT=Production \
  -v $PWD/app.crt:/app/certificate.pem:ro \
  -v $PWD/app.key:/app/certificate.key:ro \
  --network app-net -p 80:80 -p 443:443 \
  ${REGISTRY}/${IMAGE_NAME}:latest
ENDSSH
'''
        }
      }
    }
  }
}
