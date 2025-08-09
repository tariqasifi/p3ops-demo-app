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
//
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

    // ----------------- DEPLOY LOCAL (blue/green + nginx edge) -----------------
    stage('Deploy to Local (Zero-Downtime)') {
      environment {
        GITHUB_TOKEN = credentials('Token-GHCR')
        SA_PWD       = credentials('sql-sa-password')
      }
      steps {
        sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
          sh '''#!/bin/bash
set -euo pipefail
SSH_OPTS="-o StrictHostKeyChecking=no"

ssh $SSH_OPTS ${LOCAL_USER}@${APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN} REGISTRY=${REGISTRY} IMAGE_NAME=${IMAGE_NAME} IMAGE_TAG=${IMAGE_TAG} SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

CERT_DIR="$HOME/sportstore-certs"
EDGE_DIR="$HOME/sportstore-edge"
mkdir -p "$CERT_DIR" "$EDGE_DIR"

# ---- Docker login + netwerk ----
echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin
docker network create app-net || true

# ---- Certificaten (idempotent) ----
[ -f "$CERT_DIR/sql.key" ] || openssl genrsa -out "$CERT_DIR/sql.key" 2048
if [ ! -f "$CERT_DIR/sql.crt" ]; then
  openssl req -new -key "$CERT_DIR/sql.key" -out "$CERT_DIR/sql.csr" -subj "/CN=localhost"
  openssl x509 -req -days 365 -in "$CERT_DIR/sql.csr" -signkey "$CERT_DIR/sql.key" -out "$CERT_DIR/sql.crt"
  rm -f "$CERT_DIR/sql.csr"
fi
chmod 600 "$CERT_DIR/sql.key" "$CERT_DIR/sql.crt" || true

[ -f "$CERT_DIR/app.key" ] || openssl genrsa -out "$CERT_DIR/app.key" 2048
[ -f "$CERT_DIR/app.crt" ] || openssl req -x509 -new -nodes -key "$CERT_DIR/app.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/app.crt"
chmod 600 "$CERT_DIR/app.key" "$CERT_DIR/app.crt" || true

# ---- SQL Server (alleen starten als hij nog niet draait) ----
if ! docker ps --format '{{.Names}}' | grep -q '^sqlserver$'; then
  if ! docker ps -a --format '{{.Names}}' | grep -q '^sqlserver$'; then
    docker run -d --name sqlserver \
      -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=${SA_PWD}" \
      -v "$CERT_DIR/sql.crt":/var/opt/mssql/certs/sql.crt:ro \
      -v "$CERT_DIR/sql.key":/var/opt/mssql/certs/sql.key:ro \
      --network app-net -p 1433:1433 \
      --restart=always \
      mcr.microsoft.com/mssql/server:2022-latest
  else
    docker start sqlserver
  fi
fi

# ---- Edge proxy (nginx via stream, 80/443 -> sportstore-<color>) ----
ACTIVE_COLOR="blue"
if [ -f "$EDGE_DIR/nginx.conf" ] && grep -q 'sportstore-green' "$EDGE_DIR/nginx.conf"; then
  ACTIVE_COLOR="green"
fi
NEW_COLOR="green"; [ "$ACTIVE_COLOR" = "green" ] && NEW_COLOR="blue"

cat > "$EDGE_DIR/nginx.conf.$NEW_COLOR" <<EOF
stream {
  upstream http_upstream   { server sportstore-$NEW_COLOR:80; }
  server { listen 80;  proxy_pass http_upstream; }
  upstream https_upstream  { server sportstore-$NEW_COLOR:443; }
  server { listen 443; proxy_pass https_upstream; }
}
EOF

# Edge container aanwezig?
if ! docker ps --format '{{.Names}}' | grep -q '^edge$'; then
  # als edge-bestond: remove oude edge (met oude mount) veilig
  docker rm -f edge 2>/dev/null || true
  # start edge met bind mount naar nginx.conf (initieel op active color of op new)
  if [ ! -f "$EDGE_DIR/nginx.conf" ]; then
    cp "$EDGE_DIR/nginx.conf.$ACTIVE_COLOR" "$EDGE_DIR/nginx.conf"
  fi
  docker run -d --name edge \
    --network app-net \
    -p 80:80 -p 443:443 \
    -v "$EDGE_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    --restart=always \
    nginx:alpine
fi

# ---- Image pull (immutable tag) ----
docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# ---- Nieuwe app container (blue/green) zonder host-poorten; edge blijft op 80/443 ----
APP_NAME="sportstore-${NEW_COLOR}"
OLD_APP="sportstore-${ACTIVE_COLOR}"

# Verwijder eventueel gefaalde oude instantie van NEW_COLOR
docker rm -f "$APP_NAME" 2>/dev/null || true

docker run -d --name "$APP_NAME" \
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
  --network app-net \
  --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# ---- Wachten tot nieuwe container intern reageert (curl in netwerk) ----
READY=0
for i in $(seq 1 60); do
  CODE=$(docker run --rm --network app-net curlimages/curl:8.8.0 -sS -o /dev/null -w "%{http_code}" http://$APP_NAME:80/ || true)
  if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then READY=1; break; fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then
  echo "Nieuwe app ($APP_NAME) kwam niet online. Logs:"
  docker logs "$APP_NAME" | tail -n 200 || true
  exit 1
fi

# ---- Switchen van edge naar nieuwe kleur (near-zero downtime) ----
cp "$EDGE_DIR/nginx.conf.$NEW_COLOR" "$EDGE_DIR/nginx.conf"
docker exec edge nginx -t
docker exec edge nginx -s reload || docker restart edge

# ---- Oude app na korte grace periode weg ----
sleep 5
docker rm -f "$OLD_APP" 2>/dev/null || true

# ---- netjes uitloggen ----
docker logout ghcr.io || true
ENDSSH
'''
        }
      }
    }

    // ----------------- DEPLOY CLOUD (Zero-Downtime) -----------------
    stage('Deploy to Cloud (Zero-Downtime)') {
      environment {
        GITHUB_TOKEN = credentials('Token-GHCR')
        SA_PWD       = credentials('sql-sa-password')
      }
      steps {
        sshagent(credentials: ["${CLOUD_SSH_CREDENTIALS}"]) {
          sh '''#!/bin/bash
set -euo pipefail
SSH_OPTS="-o StrictHostKeyChecking=no"

ssh $SSH_OPTS ${CLOUD_USER}@${CLOUD_APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN} REGISTRY=${REGISTRY} IMAGE_NAME=${IMAGE_NAME} IMAGE_TAG=${IMAGE_TAG} SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

CERT_DIR="$HOME/sportstore-certs"
EDGE_DIR="$HOME/sportstore-edge"
mkdir -p "$CERT_DIR" "$EDGE_DIR"

# ---- Docker installeren indien nodig ----
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi

# ---- GHCR login + netwerk ----
echo "$GITHUB_TOKEN" | sudo docker login ghcr.io -u tariqasifi --password-stdin
sudo docker network create app-net || true

# ---- Certificaten (idempotent) ----
[ -f "$CERT_DIR/sql.key" ] || openssl genrsa -out "$CERT_DIR/sql.key" 2048
if [ ! -f "$CERT_DIR/sql.crt" ]; then
  openssl req -new -key "$CERT_DIR/sql.key" -out "$CERT_DIR/sql.csr" -subj "/CN=localhost"
  openssl x509 -req -days 365 -in "$CERT_DIR/sql.csr" -signkey "$CERT_DIR/sql.key" -out "$CERT_DIR/sql.crt"
  rm -f "$CERT_DIR/sql.csr"
fi
chmod 600 "$CERT_DIR/sql.key" "$CERT_DIR/sql.crt" || true

[ -f "$CERT_DIR/app.key" ] || openssl genrsa -out "$CERT_DIR/app.key" 2048
[ -f "$CERT_DIR/app.crt" ] || openssl req -x509 -new -nodes -key "$CERT_DIR/app.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/app.crt"
chmod 600 "$CERT_DIR/app.key" "$CERT_DIR/app.crt" || true

# ---- SQL Server (alleen starten als hij nog niet draait) ----
if ! sudo docker ps --format '{{.Names}}' | grep -q '^sqlserver$'; then
  if ! sudo docker ps -a --format '{{.Names}}' | grep -q '^sqlserver$'; then
    sudo docker run -d --name sqlserver \
      -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=${SA_PWD}" \
      -v "$CERT_DIR/sql.crt":/var/opt/mssql/certs/sql.crt:ro \
      -v "$CERT_DIR/sql.key":/var/opt/mssql/certs/sql.key:ro \
      --network app-net -p 1433:1433 \
      --restart=always \
      mcr.microsoft.com/mssql/server:2022-latest
  else
    sudo docker start sqlserver
  fi
fi

# ---- Edge proxy (nginx) ----
ACTIVE_COLOR="blue"
if [ -f "$EDGE_DIR/nginx.conf" ] && grep -q 'sportstore-green' "$EDGE_DIR/nginx.conf"; then
  ACTIVE_COLOR="green"
fi
NEW_COLOR="green"; [ "$ACTIVE_COLOR" = "green" ] && NEW_COLOR="blue"

cat > "$EDGE_DIR/nginx.conf.$NEW_COLOR" <<EOF
stream {
  upstream http_upstream   { server sportstore-$NEW_COLOR:80; }
  server { listen 80;  proxy_pass http_upstream; }
  upstream https_upstream  { server sportstore-$NEW_COLOR:443; }
  server { listen 443; proxy_pass https_upstream; }
}
EOF

if ! sudo docker ps --format '{{.Names}}' | grep -q '^edge$'; then
  sudo docker rm -f edge 2>/dev/null || true
  if [ ! -f "$EDGE_DIR/nginx.conf" ]; then
    cp "$EDGE_DIR/nginx.conf.$ACTIVE_COLOR" "$EDGE_DIR/nginx.conf"
  fi
  sudo docker run -d --name edge \
    --network app-net \
    -p 80:80 -p 443:443 \
    -v "$EDGE_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    --restart=always \
    nginx:alpine
fi

# ---- Image pull (immutable tag) ----
sudo docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# ---- Nieuwe app container (blue/green) ----
APP_NAME="sportstore-${NEW_COLOR}"
OLD_APP="sportstore-${ACTIVE_COLOR}"

sudo docker rm -f "$APP_NAME" 2>/dev/null || true

sudo docker run -d --name "$APP_NAME" \
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
  --network app-net \
  --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# ---- Wachten tot nieuwe container live is ----
READY=0
for i in $(seq 1 60); do
  CODE=$(sudo docker run --rm --network app-net curlimages/curl:8.8.0 -sS -o /dev/null -w "%{http_code}" http://$APP_NAME:80/ || true)
  if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then READY=1; break; fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then
  echo "Nieuwe app ($APP_NAME) kwam niet online. Logs:"
  sudo docker logs "$APP_NAME" | tail -n 200 || true
  exit 1
fi

# ---- Switch edge naar nieuwe kleur ----
cp "$EDGE_DIR/nginx.conf.$NEW_COLOR" "$EDGE_DIR/nginx.conf"
sudo docker exec edge nginx -t
sudo docker exec edge nginx -s reload || sudo docker restart edge

# ---- Oude app opruimen ----
sleep 5
sudo docker rm -f "$OLD_APP" 2>/null || true

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
