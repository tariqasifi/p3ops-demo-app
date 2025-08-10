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
        // Gebruik bash zodat pipefail werkt
        sh(script: '''
          set -euo pipefail
          dotnet restore tests/Domain.Tests/Domain.Tests.csproj
          dotnet test tests/Domain.Tests/Domain.Tests.csproj --configuration Release --no-build
        ''', shell: '/bin/bash')
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
        // Ook hier bash gebruiken
        sh(script: """
          set -euo pipefail
          docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} -f src/Dockerfile .
          docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} --disable-content-trust=true
          docker tag ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest
          docker push ${REGISTRY}/${IMAGE_NAME}:latest --disable-content-trust=true
        """, shell: '/bin/bash')
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
          sh '''#!/usr/bin/env bash
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

# --- Docker login & network ---
echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin
docker network inspect app-net >/dev/null 2>&1 || docker network create app-net

# --- Certificaten voor Nginx (TLS termination) ---
[ -f "$CERT_DIR/tls.key" ] || openssl genrsa -out "$CERT_DIR/tls.key" 2048
if [ ! -f "$CERT_DIR/tls.crt" ]; then
  openssl req -x509 -new -nodes -key "$CERT_DIR/tls.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/tls.crt"
fi
chmod 600 "$CERT_DIR/tls.key" "$CERT_DIR/tls.crt" || true

# --- SQL Server: start eenmaal, blijf draaien ---
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

# --- Nginx reverse proxy (host 80/443) ---

# Host-services die 80/443 gebruiken uitschakelen
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true
sudo systemctl stop apache2 || true
sudo systemctl disable apache2 || true

# Containers die 80/443 bezetten opruimen (behalve sportstore-edge)
for P in 80 443; do
  for CID in $(docker ps -q --filter "publish=$P"); do
    NAME=$(docker inspect -f '{{.Name}}' "$CID" | sed 's#^/##')
    if [ "$NAME" != "sportstore-edge" ]; then
      echo "Port $P in gebruik door container $NAME ($CID) – stop/verwijder..."
      docker stop "$CID" || true
      docker rm "$CID" || true
    fi
  done
done

# Config genereren indien nodig
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

# Start of herlaad edge-proxy
if ! docker ps --format '{{.Names}}' | grep -q '^sportstore-edge$'; then
  docker rm -f sportstore-edge >/dev/null 2>&1 || true
  docker run -d --name sportstore-edge \
    --network app-net \
    -p 80:80 -p 443:443 \
    -v "$NGINX_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$NGINX_DIR/app.conf":/etc/nginx/conf.d/app.conf:rw \
    -v "$CERT_DIR":/etc/nginx/certs:ro \
    --restart=always \
    nginx:1.25-alpine
else
  docker exec sportstore-edge nginx -t && docker exec sportstore-edge nginx -s reload || true
fi

# --- Bepaal blue/green ---
ACTIVE="blue"
if [ -f "$ACTIVE_FILE" ]; then
  ACTIVE="$(cat "$ACTIVE_FILE" || echo blue)"
fi
NEXT="green"
[ "$ACTIVE" = "green" ] && NEXT="blue"

# Pull nieuwe image en start NEXT
docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

NEW_NAME="sportstore-$NEXT"
OLD_NAME="sportstore-$ACTIVE"
docker rm -f "$NEW_NAME" >/dev/null 2>&1 || true

docker run -d --name "$NEW_NAME" \
  -e DB_IP=sqlserver \
  -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa \
  -e DB_PASSWORD="$SA_PWD" \
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

# Switch Nginx upstream
sed -i "s/server sportstore-.*:80;/server $NEW_NAME:80;/" "$NGINX_DIR/app.conf"
docker exec sportstore-edge nginx -t
docker exec sportstore-edge nginx -s reload

# Markeer & opruimen
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
          sh '''#!/usr/bin/env bash
set -euo pipefail
SSH_OPTS="-o StrictHostKeyChecking=no"

ssh $SSH_OPTS ${CLOUD_USER}@${CLOUD_APP_SERVER} \
  "export GITHUB_TOKEN=${GITHUB_TOKEN}; export REGISTRY=${REGISTRY}; export IMAGE_NAME=${IMAGE_NAME}; export IMAGE_TAG=${IMAGE_TAG}; export SA_PWD='${SA_PWD}'; bash -s" << 'ENDSSH'
set -euo pipefail

# --- Vereiste packages / docker ---
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi
if ! docker run --rm hello-world >/dev/null 2>&1; then
  sudo usermod -aG docker $USER || true
fi

# Gebruik sudo consistent op cloud
alias docker='sudo docker'

# --- Vars & dirs ---
BASE_DIR="/opt/sportstore"
CERT_DIR="$BASE_DIR/certs"
NGINX_DIR="$BASE_DIR/nginx"
ACTIVE_FILE="$BASE_DIR/active_color"
sudo mkdir -p "$BASE_DIR" "$CERT_DIR" "$NGINX_DIR"
sudo chown -R $USER:$USER "$BASE_DIR"

# --- Docker login & network ---
echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin
docker network inspect app-net >/dev/null 2>&1 || docker network create app-net

# --- Certificaten voor Nginx ---
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

# --- Nginx reverse proxy (host 80/443) ---

# Host services die poorten claimen uitschakelen
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true
sudo systemctl stop apache2 || true
sudo systemctl disable apache2 || true

# Containers die 80/443 bezetten opruimen (behalve sportstore-edge)
for P in 80 443; do
  for CID in $(docker ps -q --filter "publish=$P"); do
    NAME=$(docker inspect -f '{{.Name}}' "$CID" | sed 's#^/##')
    if [ "$NAME" != "sportstore-edge" ]; then
      echo "Port $P in gebruik door container $NAME ($CID) – stop/verwijder..."
      docker stop "$CID" || true
      docker rm "$CID" || true
    fi
  done
done

# Config genereren indien nodig
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

# Start of herlaad edge-proxy
if ! docker ps --format '{{.Names}}' | grep -q '^sportstore-edge$'; then
  docker rm -f sportstore-edge >/dev/null 2>&1 || true
  docker run -d --name sportstore-edge \
    --network app-net \
    -p 80:80 -p 443:443 \
    -v "$NGINX_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$NGINX_DIR/app.conf":/etc/nginx/conf.d/app.conf:rw \
    -v "$CERT_DIR":/etc/nginx/certs:ro \
    --restart=always \
    nginx:1.25-alpine
else
  docker exec sportstore-edge nginx -t && docker exec sportstore-edge nginx -s reload || true
fi

# --- Blue/Green switch ---
ACTIVE="blue"
if [ -f "$ACTIVE_FILE" ]; then
  ACTIVE="$(cat "$ACTIVE_FILE" || echo blue)"
fi
NEXT="green"
[ "$ACTIVE" = "green" ] && NEXT="blue"

docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

NEW_NAME="sportstore-$NEXT"
OLD_NAME="sportstore-$ACTIVE"
docker rm -f "$NEW_NAME" >/devnull 2>&1 || true

docker run -d --name "$NEW_NAME" \
  -e DB_IP=sqlserver \
  -e DB_PORT=1433 \
  -e DB_NAME=SportStoreDb \
  -e DB_USERNAME=sa \
  -e DB_PASSWORD="$SA_PWD" \
  -e ENVIRONMENT=Production \
  --network app-net \
  --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

for i in {1..60}; do
  if docker run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://$NEW_NAME:80/" >/dev/null 2>&1; then
    echo "New app is ready"
    break
  fi
  echo "Waiting for new app ($i/60)..."
  sleep 2
done

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
