#!/bin/bash
# Stop bij fouten of oningevulde variabelen, en log elke stap (handig voor debuggen)
set -euo pipefail
set -x

# Exporteer Auth0 secrets naar omgevingsvariabelen die door de app gelezen worden
export Auth0__M2MClientSecret="${M2MClientSecret}"
export Auth0__BlazorClientSecret="${BlazorClientSecret}"

# Stel de SQL connectiestring samen en exporteer deze.
export ConnectionStrings__SqlDatabase="Server=${DB_IP},${DB_PORT};Database=${DB_NAME};User Id=${DB_USERNAME};Password=${DB_PASSWORD};Encrypt=True;TrustServerCertificate=True;"

# Voer de EF Core migratiebundle uit om de database bij te werken
/app/migrations/migrations


# Start vervolgens de ASP.NET Core applicatie
exec dotnet /app/Server.dll --urls "http://0.0.0.0:${HTTP_PORT};https://0.0.0.0:${HTTPS_PORT}" --environment ${ENVIRONMENT}
