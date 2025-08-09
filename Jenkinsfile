pipeline {
  agent any

  environment {
    REGISTRY               = 'ghcr.io'
    IMAGE_NAME             = 'tariqasifi/sportstore'

    // Local
    APP_SERVER             = '192.168.30.20'
    SSH_CREDENTIALS        = 'ssh-appserver'
    LOCAL_USER             = 'vagrant'

    // Cloud
    CLOUD_APP_SERVER       = '4.231.232.243'
    CLOUD_USER             = 'azureuser'
    CLOUD_SSH_CREDENTIALS  = 'ssh-azure-appserver'

    // voorkom signing prompts
    DOCKER_CONTENT_TRUST   = '0'
  }

  triggers { githubPush() }

  options {
    timestamps()
    ansiColor('xterm')
  }

  stages {
    stage('Checkout')       { steps { checkout scm } }

    stage('Restore')        { steps { sh 'dotnet restore src/Server/Server.csproj' } }

    stage('Build .NET')     { steps { sh 'dotnet build -c Release' } }

    stage('Test') {
      steps {
        sh '''
          set -e
          dotnet restore tests/Domain.Tests/Domain.Tests.csproj
          dotnet test tests/Domain.Tests/Domain.Tests.csproj \
            --configuration Release --no-build \
            --logger "trx;LogFileName=test-results.trx"
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
          def tz = TimeZone.getTimeZone('Europe/Brussels')
          def date = new Date().format("yyyyMMdd-HHmmss", tz)
          def branch = (env.BRANCH_NAME ?: env.GIT_BRANCH ?: 'main').replaceAll('origin/','')
          env.IMAGE_TAG = "${branch}-${date}"
          echo "Generated image tag: ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Docker Build & Push') {
      steps {
        sh """
          set -euo pipefail
          export DOCKER_BUILDKIT=1
          docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} -f src/Dockerfile .
          docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
          docker tag  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest
          docker push ${REGISTRY}/${IMAGE_NAME}:latest
        """
      }
    }

    // ----------------- ZERO-DOWNTIME DEPLOY (LOCAL) -----------------
    stage('Deploy to Local (Zero-Downtime)') {
      environment {
        GITHUB_TOKEN = credentials('Token-GHCR')
        SA_PWD       = credentials('sql-sa-password')
      }
      steps {
        sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
          sh '''#!/bin/bash
set -euo pipefail
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ssh $SSH_OPTS ${LOCAL_USER}@${APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN} REGISTRY=${REGISTRY} IMAGE_NAME=${IMAGE_NAME} IMAGE_TAG=${IMAGE_TAG} SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

BASE_DIR="/opt/sportstore"
CERT_DIR="$BASE_DIR/certs"
NGINX_DIR="$BASE_DIR/nginx"
ACTIVE_FILE="$BASE_DIR/active_color"
mkdir -p "$BASE_DIR" "$CERT_DIR" "$NGINX_DIR"

# Login & netwerk
echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin
docker network inspect app-net >/dev/null 2>&1 || docker network create app-net

# Self-signed certs (dev)
[ -f "$CERT_DIR/tls.key" ] || openssl genrsa -out "$CERT_DIR/tls.key" 2048
[ -f "$CERT_DIR/tls.crt" ] || openssl req -x509 -new -nodes -key "$CERT_DIR/tls.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/tls.crt" || true
chmod 600 "$CERT_DIR/"* || true

# SQL Server
if ! docker ps --format '{{.Names}}' | grep -q '^sqlserver$'; then
  if ! docker ps -a --format '{{.Names}}' | grep -q '^sqlserver$'; then
    docker run -d --name sqlserver \
      -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=$SA_PWD" \
      --network app-net -p 1433:1433 --restart=always \
      mcr.microsoft.com/mssql/server:2022-latest
  else
    docker start sqlserver
  fi
fi

# Nginx config files (eenmalig genereren)
[ -f "$NGINX_DIR/nginx.conf" ] || cat > "$NGINX_DIR/nginx.conf" <<'NGX'
user  nginx;
worker_processes  auto;
events { worker_connections 1024; }
http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  sendfile        on;
  keepalive_timeout  65;
  include /etc/nginx/conf.d/*.conf;
}
NGX

[ -f "$NGINX_DIR/app.conf" ] || cat > "$NGINX_DIR/app.conf" <<'NGX'
upstream app_upstream { server sportstore-blue:80; }
server {
  listen 80;
  server_name _;
  location / {
    proxy_pass http://app_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
server {
  listen 443 ssl;
  server_name _;
  ssl_certificate     /etc/nginx/certs/tls.crt;
  ssl_certificate_key /etc/nginx/certs/tls.key;
  location / {
    proxy_pass http://app_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
NGX

# EDGE: alleen aanmaken als hij nog niet bestaat; anders enkel reload (geen downtime)
if ! docker ps -a --format '{{.Names}}' | grep -q '^sportstore-edge$'; then
  # poging tot eerste start (kan falen als 80/443 door iets anders gebruikt worden)
  set +e
  docker run -d --name sportstore-edge \
    --network app-net \
    -p 80:80 -p 443:443 \
    -v "$NGINX_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$NGINX_DIR/app.conf":/etc/nginx/conf.d/app.conf:rw \
    -v "$CERT_DIR":/etc/nginx/certs:ro \
    --restart=always nginx:1.25-alpine
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "ERROR: sportstore-edge kon niet starten. Waarschijnlijk houden andere services/containers poort 80/443 vast."
    echo "Los dit éénmalig op (stop oude publisher) en run de pipeline opnieuw."
    exit 1
  fi
else
  # bestaat al -> enkel reload (zero-downtime)
  if docker ps --format '{{.Names}}' | grep -q '^sportstore-edge$'; then
    docker exec sportstore-edge nginx -t
    docker exec sportstore-edge nginx -s reload || true
  else
    # bestaat maar draait niet -> start zonder poorten te wisselen
    docker start sportstore-edge
    docker exec sportstore-edge nginx -t
    docker exec sportstore-edge nginx -s reload || true
  fi
fi

# Blue/Green
ACTIVE="blue"; [ -f "$ACTIVE_FILE" ] && ACTIVE="$(cat "$ACTIVE_FILE" || echo blue)"
NEXT="green"; [ "$ACTIVE" = "green" ] && NEXT="blue"

docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

NEW_NAME="sportstore-$NEXT"
OLD_NAME="sportstore-$ACTIVE"
docker rm -f "$NEW_NAME" >/dev/null 2>&1 || true

docker run -d --name "$NEW_NAME" \
  -e DB_IP=sqlserver -e DB_PORT=1433 -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa -e DB_PASSWORD="$SA_PWD" -e ENVIRONMENT=Production \
  --network app-net --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# readiness
for i in {1..60}; do
  if docker run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://$NEW_NAME:80/" >/dev/null 2>&1; then
    echo "New app is ready"; break
  fi
  echo "Waiting for new app ($i/60)..."; sleep 2
done

# switch upstream + reload
sed -i "s/server sportstore-.*:80;/server $NEW_NAME:80;/" "$NGINX_DIR/app.conf"
docker exec sportstore-edge nginx -t
docker exec sportstore-edge nginx -s reload
echo "$NEXT" > "$ACTIVE_FILE"

# opruimen
docker rm -f "$OLD_NAME" >/dev/null 2>&1 || true
docker logout ghcr.io || true
ENDSSH
'''
        }
      }
    }

    // ----------------- ZERO-DOWNTIME DEPLOY (CLOUD) -----------------
    stage('Deploy to Cloud (Zero-Downtime)') {
      environment {
        GITHUB_TOKEN = credentials('Token-GHCR')
        SA_PWD       = credentials('sql-sa-password')
      }
      steps {
        sshagent(credentials: ["${CLOUD_SSH_CREDENTIALS}"]) {
          sh '''#!/bin/bash
set -euo pipefail
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ssh $SSH_OPTS ${CLOUD_USER}@${CLOUD_APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN} REGISTRY=${REGISTRY} IMAGE_NAME=${IMAGE_NAME} IMAGE_TAG=${IMAGE_TAG} SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

# Docker installeren indien nodig
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi

# Helper die automatisch sudo gebruikt als nodig
DOCKER="docker"
if ! $DOCKER info >/dev/null 2>&1; then
  DOCKER="sudo docker"
fi

BASE_DIR="/opt/sportstore"
CERT_DIR="$BASE_DIR/certs"
NGINX_DIR="$BASE_DIR/nginx"
ACTIVE_FILE="$BASE_DIR/active_color"
sudo mkdir -p "$BASE_DIR" "$CERT_DIR" "$NGINX_DIR"
sudo chown -R "$USER:$USER" "$BASE_DIR"

# Login & network
echo "$GITHUB_TOKEN" | $DOCKER login ghcr.io -u tariqasifi --password-stdin
$DOCKER network inspect app-net >/dev/null 2>&1 || $DOCKER network create app-net

# Certs
[ -f "$CERT_DIR/tls.key" ] || openssl genrsa -out "$CERT_DIR/tls.key" 2048
[ -f "$CERT_DIR/tls.crt" ] || openssl req -x509 -new -nodes -key "$CERT_DIR/tls.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/tls.crt" || true
chmod 600 "$CERT_DIR/"* || true

# SQL Server
if ! $DOCKER ps --format '{{.Names}}' | grep -q '^sqlserver$'; then
  if ! $DOCKER ps -a --format '{{.Names}}' | grep -q '^sqlserver$'; then
    $DOCKER run -d --name sqlserver \
      -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=$SA_PWD" \
      --network app-net -p 1433:1433 --restart=always \
      mcr.microsoft.com/mssql/server:2022-latest
  else
    $DOCKER start sqlserver
  fi
fi

# Nginx configs (eenmalig)
[ -f "$NGINX_DIR/nginx.conf" ] || cat > "$NGINX_DIR/nginx.conf" <<'NGX'
user  nginx;
worker_processes  auto;
events { worker_connections 1024; }
http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  sendfile        on;
  keepalive_timeout  65;
  include /etc/nginx/conf.d/*.conf;
}
NGX

[ -f "$NGINX_DIR/app.conf" ] || cat > "$NGINX_DIR/app.conf" <<'NGX'
upstream app_upstream { server sportstore-blue:80; }
server {
  listen 80;
  server_name _;
  location / {
    proxy_pass http://app_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
server {
  listen 443 ssl;
  server_name _;
  ssl_certificate     /etc/nginx/certs/tls.crt;
  ssl_certificate_key /etc/nginx/certs/tls.key;
  location / {
    proxy_pass http://app_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
NGX

# EDGE: alleen creëren als niet bestaat; anders enkel reload
if ! $DOCKER ps -a --format '{{.Names}}' | grep -q '^sportstore-edge$'; then
  set +e
  $DOCKER run -d --name sportstore-edge \
    --network app-net \
    -p 80:80 -p 443:443 \
    -v "$NGINX_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$NGINX_DIR/app.conf":/etc/nginx/conf.d/app.conf:rw \
    -v "$CERT_DIR":/etc/nginx/certs:ro \
    --restart=always nginx:1.25-alpine
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "ERROR: sportstore-edge kon niet starten (poort 80/443 bezet)."
    echo "Los dit éénmalig op en run de pipeline opnieuw. Daarna zijn deploys zero-downtime."
    exit 1
  fi
else
  if $DOCKER ps --format '{{.Names}}' | grep -q '^sportstore-edge$'; then
    $DOCKER exec sportstore-edge nginx -t
    $DOCKER exec sportstore-edge nginx -s reload || true
  else
    $DOCKER start sportstore-edge
    $DOCKER exec sportstore-edge nginx -t
    $DOCKER exec sportstore-edge nginx -s reload || true
  fi
fi

# Blue/Green
ACTIVE="blue"; [ -f "$ACTIVE_FILE" ] && ACTIVE="$(cat "$ACTIVE_FILE" || echo blue)"
NEXT="green"; [ "$ACTIVE" = "green" ] && NEXT="blue"

$DOCKER pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

NEW_NAME="sportstore-$NEXT"
OLD_NAME="sportstore-$ACTIVE"
$DOCKER rm -f "$NEW_NAME" >/dev/null 2>&1 || true

$DOCKER run -d --name "$NEW_NAME" \
  -e DB_IP=sqlserver -e DB_PORT=1433 -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa -e DB_PASSWORD="$SA_PWD" -e ENVIRONMENT=Production \
  --network app-net --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# readiness
for i in {1..60}; do
  if $DOCKER run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://$NEW_NAME:80/" >/dev/null 2>&1; then
    echo "New app is ready"; break
  fi
  echo "Waiting for new app ($i/60)..."; sleep 2
done

# switch upstream + reload
sed -i "s/server sportstore-.*:80;/server $NEW_NAME:80;/" "$NGINX_DIR/app.conf"
$DOCKER exec sportstore-edge nginx -t
$DOCKER exec sportstore-edge nginx -s reload
echo "$NEXT" > "$ACTIVE_FILE"

# opruimen
$DOCKER rm -f "$OLD_NAME" >/dev/null 2>&1 || true
$DOCKER logout ghcr.io || true
ENDSSH
'''
        }
      }
    }
  }

  post {
    always {
      sh 'docker logout ghcr.io || true'
      junit allowEmptyResults: true, testResults: '**/test-results.trx'
    }
  }
}
