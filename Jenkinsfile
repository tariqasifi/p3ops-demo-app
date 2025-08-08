pipeline {
  agent any

  environment {
    REGISTRY               = 'ghcr.io'
    IMAGE_NAME             = 'tariqasifi/sportstore'

    // Lokaal
    APP_SERVER             = '192.168.30.20'
    SSH_CREDENTIALS        = 'ssh-appserver'
    LOCAL_USER             = 'vagrant'

    // Cloud
    CLOUD_APP_SERVER       = '4.231.232.243'
    CLOUD_USER             = 'azureuser'
    CLOUD_SSH_CREDENTIALS  = 'ssh-azure-appserver'
  }

  triggers { githubPush() }

  stages {
    stage('Checkout')       { steps { checkout scm } }
    stage('Restore')        { steps { sh 'dotnet restore src/Server/Server.csproj' } }
    stage('Build .NET')     { steps { sh 'dotnet build -c Release' } }

    stage('Test') {
      steps {
        sh '''
          dotnet restore tests/Domain.Tests/Domain.Tests.csproj
          dotnet test tests/Domain.Tests/Domain.Tests.csproj --configuration Release --no-build
        '''
      }
    }

    stage('Docker Login (CI)') {
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

    // ----------------- DEPLOY LOCAL -----------------
    stage('Deploy to Local Appserver via SSH') {
      environment {
        GITHUB_TOKEN = credentials('Token-GHCR')
        SA_PWD       = credentials('sql-sa-password')   // Jenkins Secret text deze moet ik nog maken in jenkins server
      }
      steps {
        sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
          sh '''#!/bin/bash
SSH_OPTS="-o StrictHostKeyChecking=no"
ssh $SSH_OPTS ${LOCAL_USER}@${APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN}; export REGISTRY=${REGISTRY}; export IMAGE_NAME=${IMAGE_NAME}; export IMAGE_TAG=${IMAGE_TAG}; export SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

CERT_DIR="$HOME/sportstore-certs"
mkdir -p "$CERT_DIR"

# ---- GHCR login ----
echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin

# ---- Netwerk ----
docker network create app-net || true

# ---- Oude containers weg (negeer errors) ----
docker rm -f sportstore-app || true
docker rm -f sqlserver || true

# ---- Certificaten (idempotent, in eigen map) ----
# SQL cert/key
[ -f "$CERT_DIR/sql.key" ] || openssl genrsa -out "$CERT_DIR/sql.key" 2048
if [ ! -f "$CERT_DIR/sql.crt" ]; then
  openssl req -new -key "$CERT_DIR/sql.key" -out "$CERT_DIR/sql.csr" -subj "/CN=localhost"
  openssl x509 -req -days 365 -in "$CERT_DIR/sql.csr" -signkey "$CERT_DIR/sql.key" -out "$CERT_DIR/sql.crt"
  rm -f "$CERT_DIR/sql.csr"
fi
chmod 600 "$CERT_DIR/sql.key" "$CERT_DIR/sql.crt" || true

# App cert/key (PEM + KEY voor Kestrel)
[ -f "$CERT_DIR/app.key" ] || openssl genrsa -out "$CERT_DIR/app.key" 2048
[ -f "$CERT_DIR/app.crt" ] || openssl req -x509 -new -nodes -key "$CERT_DIR/app.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/app.crt"
chmod 600 "$CERT_DIR/app.key" "$CERT_DIR/app.crt" || true

# ---- Image pull (immutable tag) ----
docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# ---- SQL Server ----
docker run -d --name sqlserver \
  -e "ACCEPT_EULA=Y" \
  -e "SA_PASSWORD=${SA_PWD}" \
  -v "$CERT_DIR/sql.crt":/var/opt/mssql/certs/sql.crt:ro \
  -v "$CERT_DIR/sql.key":/var/opt/mssql/certs/sql.key:ro \
  --network app-net -p 1433:1433 \
  --restart=always \
  mcr.microsoft.com/mssql/server:2022-latest

# ---- App (TLS mounts + immutable image tag) ----
docker run -d --name sportstore-app \
  -e DB_IP=sqlserver \
  -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa \
  -e DB_PASSWORD=${SA_PWD} \
  -e HTTP_PORT=80 \
  -e HTTPS_PORT=443 \
  -e ENVIRONMENT=Production \
  -v "$CERT_DIR/app.crt":/app/certificate.pem:ro \
  -v "$CERT_DIR/app.key":/app/certificate.key:ro \
  --network app-net -p 80:80 -p 443:443 \
  --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# ---- Veilig uitloggen van registry ----
docker logout ghcr.io || true
ENDSSH
'''
        }
      }
    }

    // ----------------- DEPLOY CLOUD -----------------
    stage('Deploy to Cloud Appserver via SSH') {
      environment {
        GITHUB_TOKEN = credentials('Token-GHCR')
        SA_PWD       = credentials('sql-sa-password')
      }
      steps {
        sshagent(credentials: ["${CLOUD_SSH_CREDENTIALS}"]) {
          sh '''#!/bin/bash
SSH_OPTS="-o StrictHostKeyChecking=no"
ssh $SSH_OPTS ${CLOUD_USER}@${CLOUD_APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN}; export REGISTRY=${REGISTRY}; export IMAGE_NAME=${IMAGE_NAME}; export IMAGE_TAG=${IMAGE_TAG}; export SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

CERT_DIR="$HOME/sportstore-certs"
mkdir -p "$CERT_DIR"

# ---- Docker installeren indien nodig ----
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi

# ---- GHCR login (sudo i.v.m. docker.sock) ----
echo "$GITHUB_TOKEN" | sudo docker login ghcr.io -u tariqasifi --password-stdin

# ---- Netwerk ----
sudo docker network create app-net || true

# ---- Oude containers weg ----
sudo docker rm -f sportstore-app || true
sudo docker rm -f sqlserver || true

# ---- Certificaten (idempotent, in eigen map) ----
# SQL cert/key
[ -f "$CERT_DIR/sql.key" ] || openssl genrsa -out "$CERT_DIR/sql.key" 2048
if [ ! -f "$CERT_DIR/sql.crt" ]; then
  openssl req -new -key "$CERT_DIR/sql.key" -out "$CERT_DIR/sql.csr" -subj "/CN=localhost"
  openssl x509 -req -days 365 -in "$CERT_DIR/sql.csr" -signkey "$CERT_DIR/sql.key" -out "$CERT_DIR/sql.crt"
  rm -f "$CERT_DIR/sql.csr"
fi
chmod 600 "$CERT_DIR/sql.key" "$CERT_DIR/sql.crt" || true

# App cert/key (PEM + KEY voor Kestrel)
[ -f "$CERT_DIR/app.key" ] || openssl genrsa -out "$CERT_DIR/app.key" 2048
[ -f "$CERT_DIR/app.crt" ] || openssl req -x509 -new -nodes -key "$CERT_DIR/app.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/app.crt"
chmod 600 "$CERT_DIR/app.key" "$CERT_DIR/app.crt" || true

# ---- Image pull (immutable tag) ----
sudo docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# ---- SQL Server ----
sudo docker run -d --name sqlserver \
  -e "ACCEPT_EULA=Y" \
  -e "SA_PASSWORD=${SA_PWD}" \
  -v "$CERT_DIR/sql.crt":/var/opt/mssql/certs/sql.crt:ro \
  -v "$CERT_DIR/sql.key":/var/opt/mssql/certs/sql.key:ro \
  --network app-net -p 1433:1433 \
  --restart=always \
  mcr.microsoft.com/mssql/server:2022-latest

# ---- App (TLS mounts + immutable image tag) ----
sudo docker run -d --name sportstore-app \
  -e DB_IP=sqlserver \
  -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa \
  -e DB_PASSWORD=${SA_PWD} \
  -e HTTP_PORT=80 \
  -e HTTPS_PORT=443 \
  -e ENVIRONMENT=Production \
  -v "$CERT_DIR/app.crt":/app/certificate.pem:ro \
  -v "$CERT_DIR/app.key":/app/certificate.key:ro \
  --network app-net -p 80:80 -p 443:443 \
  --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# ---- Veilig uitloggen ----
sudo docker logout ghcr.io || true
ENDSSH
'''
        }
      }
    }
  }

  post {
    always {
      sh 'docker logout ghcr.io || true'
    }
  }
}
