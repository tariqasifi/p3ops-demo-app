# Gebruik de officiële .NET 8 runtime als base image
FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS base
WORKDIR /app

# Build stage met .NET 8 SDK
FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /src

# Kopieer de volledige solution/source
COPY . . 

# Zorg dat EF Core en Design op exact dezelfde versie staan
RUN dotnet add ./src/Persistence/Persistence.csproj package Microsoft.EntityFrameworkCore --version 6.0.25
RUN dotnet add ./src/Persistence/Persistence.csproj package Microsoft.EntityFrameworkCore.Design --version 6.0.25

# Installeer de EF Core CLI tool (dotnet-ef)
RUN dotnet tool install --global dotnet-ef --version 6.0.25

# Zet pad zodat dotnet-ef beschikbaar is
ENV PATH="$PATH:/root/.dotnet/tools"


# Build de app
RUN dotnet build "./src/Server/Server.csproj" -c Release

# In build stage
RUN dotnet dev-certs https --export-path /app/publish/certificate.pem --no-password --format PEM

RUN dotnet publish ./src/Server/Server.csproj \
    -c Release \
    -r linux-x64 \
    --self-contained true \
    -o /app/publish


RUN mkdir -p /app/migrations

# Bundle de migraties in een uitvoerbaar bestand (self-contained voor Linux)
RUN dotnet ef migrations bundle \
    -o /app/migrations \
    --project ./src/Persistence \
    --startup-project ./src/Server \
    --verbose \
    --runtime linux-x64 \
    --no-build \
    --configuration Release \
    -f


# Final stage - runtime image met alleen benodigde bestanden
FROM base AS final
WORKDIR /app


#COPY ./create-user.sh /create-user.sh
#RUN chmod +x /create-user.sh && /create-user.sh

# Kopieer gepubliceerde app-bestanden en de migratie bundle + script
COPY --from=build /app/publish .
COPY --from=build /app/migrations .
COPY --from=build /src/src/dockerrunner.sh .

# Schakel over naar non-root user 'app' (voor security)
RUN chmod +x /app/dockerrunner.sh
RUN adduser --disabled-password --gecos "" app
RUN chown -R app:app /app/*
USER app


# Configureer om de HTTPS certificaat bestanden te gebruiken
ENV ASPNETCORE_Kestrel__Certificates__Default__Path="/app/certificate.pem" 
ENV ASPNETCORE_Kestrel__Certificates__Default__KeyPath="/app/certificate.key"

WORKDIR /app
# Stel de entrypoint in naar de bash opstartscript
ENTRYPOINT ["bash","/app/dockerrunner.sh"]
