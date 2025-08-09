pipeline {
  agent any

  environment {
    REGISTRY               = 'ghcr.io'
    IMAGE_NAME             = 'tariqasifi/sportstore'
    DOCKER_CONTENT_TRUST   = '0'   // voorkom signing prompts bij push

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
          def date   = new Date().format("yyyyMMdd-HHmmss", TimeZone.getTimeZone('Europe/Brussels'))
          def branch = (env.BRANCH_NAME ?: (env.GIT_BRANCH?.replaceAll('^origin/','') ?: 'main'))
          env.IMAGE_TAG = "${branch}-${date}"
          echo "Generated image tag: ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Docker Build & Push') {
      steps {
        sh """
          docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} -f src/Dockerfile .
          DOCKER_CONTENT_TRUST=0 docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
          docker tag ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest
          DOCKER_CONTENT_TRUST=0 docker push ${REGISTRY}/${IMAGE_NAME}:latest
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
SSH_OPTS="-o StrictHostKeyChecking=no"

ssh $SSH_OPTS ${LOCAL_USER}@${APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN}; export REGISTRY=${REGISTRY}; export IMAGE_NAME=${IMAGE_NAME}; export IMAGE_TAG=${IMAGE_TAG}; export SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

# --- Vars & dirs ---
BASE_DIR="/opt/sportstore"
CERT_DIR="$BASE_DIR/certs"
NGINX_DIR="$BASE_DIR/nginx"
ACTIVE_FILE="$BASE_DIR/active_color"
sudo mkdir -p "$BASE_DIR" "$CERT_DIR" "$NGINX_DIR"
sudo chown -R $USER:$USER "$BASE_DIR"

# --- Login & network ---
echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin
docker network inspect app-net >/dev/null 2>&1 || docker network create app-net

# --- Certificaten (self-signed) ---
[ -f "$CERT_DIR/tls.key" ] || openssl genrsa -out "$CERT_DIR/tls.key" 2048
if [ ! -f "$CERT_DIR/tls.crt" ]; then
  openssl req -x509 -new -nodes -key "$CERT_DIR/tls.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/tls.crt"
fi
chmod 600 "$CERT_DIR/tls.key" "$CERT_DIR/tls.crt" || true

# --- SQL Server (éénmalig) ---
if ! docker ps --format '{{.Names}}' | grep -q '^sqlserver$'; then
  if ! docker ps -a --format '{{.Names}}' | grep -q '^sqlserver$'; then
    docker run -d --name sqlserver \
      -e "ACCEPT_EULA=Y" \
      -e "SA_PASSWORD=$SA_PWD" \
      --network app-net \
      -p 1433:1433 \
      --restart=always \
      mcr.microsoft.com/mssql/server:2022-latest
  else
    docker start sqlserver
  fi
fi

# --- Nginx reverse proxy (zero-downtime) ---
# Genereer configs indien nodig
if [ ! -f "$NGINX_DIR/nginx.conf" ]; then
  cat > "$NGINX_DIR/nginx.conf" <<'NGX'
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
fi

if [ ! -f "$NGINX_DIR/app.conf" ]; then
  cat > "$NGINX_DIR/app.conf" <<'NGX'
upstream app_upstream {
  server sportstore-blue:80;
}
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
fi

# Start edge ALLEEN als hij nog niet bestaat; anders running houden
if ! docker ps -a --format '{{.Names}}' | grep -q '^sportstore-edge$'; then
  docker run -d --name sportstore-edge \
    --network app-net \
    -p 80:80 -p 443:443 \
    -v "$NGINX_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$NGINX_DIR/app.conf":/etc/nginx/conf.d/app.conf:rw \
    -v "$CERT_DIR":/etc/nginx/certs:ro \
    --restart=always \
    nginx:1.25-alpine
else
  docker start sportstore-edge >/dev/null 2>&1 || true
fi

# --- Blue/Green roll-out ---
ACTIVE="blue"; [ -f "$ACTIVE_FILE" ] && ACTIVE="$(cat "$ACTIVE_FILE" || echo blue)"
NEXT="green"; [ "$ACTIVE" = "green" ] && NEXT="blue"

docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

NEW_NAME="sportstore-$NEXT"
OLD_NAME="sportstore-$ACTIVE"
docker rm -f "$NEW_NAME" >/dev/null 2>&1 || true

docker run -d --name "$NEW_NAME" \
  -e DB_IP=sqlserver -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb -e DB_USERNAME=sa -e DB_PASSWORD="$SA_PWD" \
  -e ENVIRONMENT=Production \
  --network app-net \
  --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# Readiness check
for i in {1..60}; do
  if docker run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://$NEW_NAME:80/" >/dev/null 2>&1; then
    echo "New app is ready"
    break
  fi
  echo "Waiting for new app ($i/60)..."
  sleep 2
done

# Upstream switch + reload (GEEN stop van edge)
sed -i "s/server sportstore-.*:80;/server $NEW_NAME:80;/" "$NGINX_DIR/app.conf"
docker exec sportstore-edge nginx -t
docker exec sportstore-edge nginx -s reload

echo "$NEXT" > "$ACTIVE_FILE"
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
SSH_OPTS="-o StrictHostKeyChecking=no"

ssh $SSH_OPTS ${CLOUD_USER}@${CLOUD_APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN}; export REGISTRY=${REGISTRY}; export IMAGE_NAME=${IMAGE_NAME}; export IMAGE_TAG=${IMAGE_TAG}; export SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

# --- Docker installatie ---
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi
sudo usermod -aG docker $USER || true
alias docker='sudo docker'

# --- Dirs/rights ---
BASE_DIR="/opt/sportstore"
CERT_DIR="$BASE_DIR/certs"
NGINX_DIR="$BASE_DIR/nginx"
ACTIVE_FILE="$BASE_DIR/active_color"
sudo mkdir -p "$BASE_DIR" "$CERT_DIR" "$NGINX_DIR"
sudo chown -R $USER:$USER "$BASE_DIR"

# --- Login & network ---
echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin
docker network inspect app-net >/dev/null 2>&1 || docker network create app-net

# --- Certs ---
[ -f "$CERT_DIR/tls.key" ] || openssl genrsa -out "$CERT_DIR/tls.key" 2048
if [ ! -f "$CERT_DIR/tls.crt" ]; then
  openssl req -x509 -new -nodes -key "$CERT_DIR/tls.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/tls.crt"
fi
chmod 600 "$CERT_DIR/tls.key" "$CERT_DIR/tls.crt" || true

# --- SQL Server ---
if ! docker ps --format '{{.Names}}' | grep -q '^sqlserver$'; then
  if ! docker ps -a --format '{{.Names}}' | grep -q '^sqlserver$'; then
    docker run -d --name sqlserver \
      -e "ACCEPT_EULA=Y" \
      -e "SA_PASSWORD=$SA_PWD" \
      --network app-net \
      -p 1433:1433 \
      --restart=always \
      mcr.microsoft.com/mssql/server:2022-latest
  else
    docker start sqlserver
  fi
fi

# --- Nginx reverse proxy (zero-downtime) ---
if [ ! -f "$NGINX_DIR/nginx.conf" ]; then
  cat > "$NGINX_DIR/nginx.conf" <<'NGX'
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
fi

if [ ! -f "$NGINX_DIR/app.conf" ]; then
  cat > "$NGINX_DIR/app.conf" <<'NGX'
upstream app_upstream {
  server sportstore-blue:80;
}
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
fi

# Start edge ALLEEN als hij nog niet bestaat; anders running houden
if ! docker ps -a --format '{{.Names}}' | grep -q '^sportstore-edge$'; then
  docker run -d --name sportstore-edge \
    --network app-net \
    -p 80:80 -p 443:443 \
    -v "$NGINX_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$NGINX_DIR/app.conf":/etc/nginx/conf.d/app.conf:rw \
    -v "$CERT_DIR":/etc/nginx/certs:ro \
    --restart=always \
    nginx:1.25-alpine
else
  docker start sportstore-edge >/dev/null 2>&1 || true
fi

# --- Blue/Green ---
ACTIVE="blue"; [ -f "$ACTIVE_FILE" ] && ACTIVE="$(cat "$ACTIVE_FILE" || echo blue)"
NEXT="green"; [ "$ACTIVE" = "green" ] && NEXT="blue"

docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

NEW_NAME="sportstore-$NEXT"
OLD_NAME="sportstore-$ACTIVE"
docker rm -f "$NEW_NAME" >/dev/null 2>&1 || true

docker run -d --name "$NEW_NAME" \
  -e DB_IP=sqlserver -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb -e DB_USERNAME=sa -e DB_PASSWORD="$SA_PWD" \
  -e ENVIRONMENT=Production \
  --network app-net \
  --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

# Readiness
for i in {1..60}; do
  if docker run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://$NEW_NAME:80/" >/dev/null 2>&1; then
    echo "New app is ready"
    break
  fi
  echo "Waiting for new app ($i/60)..."
  sleep 2
done

# Upstream switch + reload
sed -i "s/server sportstore-.*:80;/server $NEW_NAME:80;/" "$NGINX_DIR/app.conf"
docker exec sportstore-edge nginx -t
docker exec sportstore-edge nginx -s reload

echo "$NEXT" > "$ACTIVE_FILE"
docker rm -f "$OLD_NAME" >/dev/null 2>&1 || true

docker logout ghcr.io || true
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
