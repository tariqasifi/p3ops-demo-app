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
        sh '''#!/usr/bin/env bash
set -euo pipefail
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
        sh '''#!/usr/bin/env bash
set -euo pipefail
docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} -f src/Dockerfile .
docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} --disable-content-trust=true
docker tag ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest
docker push ${REGISTRY}/${IMAGE_NAME}:latest --disable-content-trust=true
'''
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

BASE_DIR="/opt/sportstore"
CERT_DIR="$BASE_DIR/certs"
NGINX_DIR="$BASE_DIR/nginx"
ACTIVE_FILE="$BASE_DIR/active_color"
sudo mkdir -p "$BASE_DIR" "$CERT_DIR" "$NGINX_DIR"
sudo chown -R $USER:$USER "$BASE_DIR"

echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin
docker network inspect app-net >/dev/null 2>&1 || docker network create app-net

# Certs (self-signed)
[ -f "$CERT_DIR/tls.key" ] || openssl genrsa -out "$CERT_DIR/tls.key" 2048
if [ ! -f "$CERT_DIR/tls.crt" ]; then
  openssl req -x509 -new -nodes -key "$CERT_DIR/tls.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/tls.crt"
fi
chmod 600 "$CERT_DIR/tls.key" "$CERT_DIR/tls.crt" || true

# SQL Server persistent
if ! docker ps --format '{{.Names}}' | grep -q '^sqlserver$'; then
  if ! docker ps -a --format '{{.Names}}' | grep -q '^sqlserver$'; then
    docker run -d --name sqlserver \
      -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=$SA_PWD" \
      --network app-net -p 1433:1433 --restart=always \
      mcr.microsoft.com/mssql/server:2022-latest
  else docker start sqlserver; fi
fi

# Stop/disable host nginx/apache2 indien aanwezig
if systemctl list-unit-files | grep -q '^nginx\\.service'; then
  systemctl is-active --quiet nginx && sudo systemctl stop nginx || true
  systemctl is-enabled --quiet nginx && sudo systemctl disable nginx || true
fi
if systemctl list-unit-files | grep -q '^apache2\\.service'; then
  systemctl is-active --quiet apache2 && sudo systemctl stop apache2 || true
  systemctl is-enabled --quiet apache2 && sudo systemctl disable apache2 || true
fi

# Free host ports 80/443 (behalve edge)
for P in 80 443; do
  for CID in $(docker ps -q); do
    NAME=$(docker inspect -f '{{.Name}}' "$CID" | sed 's#^/##')
    HOSTBINDS=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Ports}}{{if $v}}{{range $v}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}{{end}}' "$CID")
    if echo "$HOSTBINDS" | grep -qE "(^| )0\\.0\\.0\\.0:${P}|(^| ):::${P}"; then
      [ "$NAME" != "sportstore-edge" ] && docker rm -f "$CID" >/dev/null 2>&1 || true
    fi
  done
done

# Genereer Nginx config indien nodig
[ -f "$NGINX_DIR/nginx.conf" ] || cat > "$NGINX_DIR/nginx.conf" <<'NGX'
user  nginx;
worker_processes  auto;
events { worker_connections 1024; }
http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  sendfile on;
  keepalive_timeout 65;
  include /etc/nginx/conf.d/*.conf;
}
NGX

[ -f "$NGINX_DIR/app.conf" ] || cat > "$NGINX_DIR/app.conf" <<'NGX'
upstream app_upstream { server sportstore-blue:80; }
server {
  listen 80; server_name _;
  location / {
    proxy_pass http://app_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
server {
  listen 443 ssl; server_name _;
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

# --- Self-heal vóór deploy: zet upstream op een draaiende kleur ---
RUNNING_TARGET=""
docker ps --format '{{.Names}}' | grep -q '^sportstore-blue$'  && RUNNING_TARGET="sportstore-blue"
docker ps --format '{{.Names}}' | grep -q '^sportstore-green$' && RUNNING_TARGET="${RUNNING_TARGET:-sportstore-green}"
if [ -n "$RUNNING_TARGET" ]; then
  sed -i -E "s/server sportstore-[a-z]+:80;/server ${RUNNING_TARGET}:80;/" "$NGINX_DIR/app.conf" || true
fi

# (Re)create edge met read-only mounts zodat we enkel hostfile aanpassen
docker rm -f sportstore-edge >/dev/null 2>&1 || true
docker run -d --name sportstore-edge \
  --network app-net -p 80:80 -p 443:443 \
  -v "$NGINX_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
  -v "$NGINX_DIR/app.conf":/etc/nginx/conf.d/app.conf:ro \
  -v "$CERT_DIR":/etc/nginx/certs:ro \
  --restart=always nginx:1.25-alpine

# Bepaal actieve kleur & NEXT
ACTIVE="blue"; [ -f "$ACTIVE_FILE" ] && ACTIVE="$(cat "$ACTIVE_FILE" || echo blue)"
NEXT="green";  [ "$ACTIVE" = "green" ] && NEXT="blue"

docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

NEW_NAME="sportstore-$NEXT"
OLD_NAME="sportstore-$ACTIVE"
docker rm -f "$NEW_NAME" >/dev/null 2>&1 || true

# Start app zonder migrations (entrypoint override)
docker run -d --name "$NEW_NAME" \
  --entrypoint /bin/sh \
  -e ASPNETCORE_URLS=http://+:80 \
  -e ENVIRONMENT=Production \
  -e ConnectionStrings__SqlDatabase="Server=sqlserver,1433;Database=SportStoreDb;User Id=sa;Password=$SA_PWD;Encrypt=True;TrustServerCertificate=True;" \
  -e DB_IP=sqlserver -e DB_PORT=1433 -e DB_NAME=SportStoreDb -e DB_USERNAME=sa -e DB_PASSWORD="$SA_PWD" \
  --network app-net --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} \
  -c 'set -eu; for p in /app/Server.dll /app/Server/Server.dll /app/publish/Server.dll; do [ -f "$p" ] && exec dotnet "$p"; done; echo "Server.dll not found"; ls -R /app || true; exit 1'

# Wacht tot nieuwe app klaar is
READY=false
for i in {1..60}; do
  if docker run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://$NEW_NAME:80/" >/dev/null 2>&1; then READY=true; break; fi
  echo "Waiting for new app ($i/60)..."; sleep 2
done
if [ "$READY" != "true" ]; then
  echo "ERROR: new app not ready"; docker logs --tail=200 "$NEW_NAME" || true; exit 1
fi

# Switch: pas host app.conf aan op NEW_NAME en reload edge
sed -i -E "s/server sportstore-[a-z]+:80;/server ${NEW_NAME}:80;/" "$NGINX_DIR/app.conf"
docker exec sportstore-edge nginx -t && docker exec sportstore-edge nginx -s reload

# E2E check via edge
docker run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://sportstore-edge:80/" >/dev/null \
  || { echo "Edge proxy not routing to app"; docker exec sportstore-edge nginx -T || true; exit 1; }

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

# Docker (indien nodig)
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi
alias docker='sudo docker'

BASE_DIR="/opt/sportstore"
CERT_DIR="$BASE_DIR/certs"
NGINX_DIR="$BASE_DIR/nginx"
ACTIVE_FILE="$BASE_DIR/active_color"
sudo mkdir -p "$BASE_DIR" "$CERT_DIR" "$NGINX_DIR"
sudo chown -R $USER:$USER "$BASE_DIR"

echo "$GITHUB_TOKEN" | docker login ghcr.io -u tariqasifi --password-stdin
docker network inspect app-net >/dev/null 2>&1 || docker network create app-net

# Certs
[ -f "$CERT_DIR/tls.key" ] || openssl genrsa -out "$CERT_DIR/tls.key" 2048
if [ ! -f "$CERT_DIR/tls.crt" ]; then
  openssl req -x509 -new -nodes -key "$CERT_DIR/tls.key" -sha256 -days 365 -subj "/CN=localhost" -out "$CERT_DIR/tls.crt"
fi
chmod 600 "$CERT_DIR/tls.key" "$CERT_DIR/tls.crt" || true

# SQL
if ! docker ps --format '{{.Names}}' | grep -q '^sqlserver$'; then
  if ! docker ps -a --format '{{.Names}}' | grep -q '^sqlserver$'; then
    docker run -d --name sqlserver \
      -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=$SA_PWD" \
      --network app-net -p 1433:1433 --restart=always \
      mcr.microsoft.com/mssql/server:2022-latest
  else docker start sqlserver; fi
fi

# Genereer Nginx config indien nodig
[ -f "$NGINX_DIR/nginx.conf" ] || cat > "$NGINX_DIR/nginx.conf" <<'NGX'
user  nginx;
worker_processes  auto;
events { worker_connections 1024; }
http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  sendfile on;
  keepalive_timeout 65;
  include /etc/nginx/conf.d/*.conf;
}
NGX

[ -f "$NGINX_DIR/app.conf" ] || cat > "$NGINX_DIR/app.conf" <<'NGX'
upstream app_upstream { server sportstore-blue:80; }
server {
  listen 80; server_name _;
  location / {
    proxy_pass http://app_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
server {
  listen 443 ssl; server_name _;
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

# Self-heal vóór deploy
RUNNING_TARGET=""
docker ps --format '{{.Names}}' | grep -q '^sportstore-blue$'  && RUNNING_TARGET="sportstore-blue"
docker ps --format '{{.Names}}' | grep -q '^sportstore-green$' && RUNNING_TARGET="${RUNNING_TARGET:-sportstore-green}"
[ -n "$RUNNING_TARGET" ] && sed -i -E "s/server sportstore-[a-z]+:80;/server ${RUNNING_TARGET}:80;/" "$NGINX_DIR/app.conf" || true

# Recreate edge met read-only mounts
docker rm -f sportstore-edge >/dev/null 2>&1 || true
docker run -d --name sportstore-edge \
  --network app-net -p 80:80 -p 443:443 \
  -v "$NGINX_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
  -v "$NGINX_DIR/app.conf":/etc/nginx/conf.d/app.conf:ro \
  -v "$CERT_DIR":/etc/nginx/certs:ro \
  --restart=always nginx:1.25-alpine

# Blue/Green
ACTIVE="blue"; [ -f "$ACTIVE_FILE" ] && ACTIVE="$(cat "$ACTIVE_FILE" || echo blue)"
NEXT="green";  [ "$ACTIVE" = "green" ] && NEXT="blue"

docker pull ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

NEW_NAME="sportstore-$NEXT"
OLD_NAME="sportstore-$ACTIVE"
docker rm -f "$NEW_NAME" >/dev/null 2>&1 || true

docker run -d --name "$NEW_NAME" \
  --entrypoint /bin/sh \
  -e ASPNETCORE_URLS=http://+:80 \
  -e ENVIRONMENT=Production \
  -e ConnectionStrings__SqlDatabase="Server=sqlserver,1433;Database=SportStoreDb;User Id=sa;Password=$SA_PWD;Encrypt=True;TrustServerCertificate=True;" \
  -e DB_IP=sqlserver -e DB_PORT=1433 -e DB_NAME=SportStoreDb -e DB_USERNAME=sa -e DB_PASSWORD="$SA_PWD" \
  --network app-net --restart=always \
  ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} \
  -c 'set -eu; for p in /app/Server.dll /app/Server/Server.dll /app/publish/Server.dll; do [ -f "$p" ] && exec dotnet "$p"; done; echo "Server.dll not found"; ls -R /app || true; exit 1'

READY=false
for i in {1..60}; do
  if docker run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://$NEW_NAME:80/" >/dev/null 2>&1; then READY=true; break; fi
  echo "Waiting for new app ($i/60)..."; sleep 2
done
if [ "$READY" != "true" ]; then
  echo "ERROR: new app not ready"; docker logs --tail=200 "$NEW_NAME" || true; exit 1
fi

sed -i -E "s/server sportstore-[a-z]+:80;/server ${NEW_NAME}:80;/" "$NGINX_DIR/app.conf"
docker exec sportstore-edge nginx -t && docker exec sportstore-edge nginx -s reload

docker run --rm --network app-net curlimages/curl:8.8.0 -fsS "http://sportstore-edge:80/" >/dev/null \
  || { echo "Edge proxy not routing to app"; docker exec sportstore-edge nginx -T || true; exit 1; }

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
