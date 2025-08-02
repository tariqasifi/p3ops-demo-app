# Gebruik de officiële .NET 8 runtime als base image
FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS base
WORKDIR /app

# Build stage met .NET 8 SDK
FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /src

# Kopieer de volledige solution/source
COPY . /src

# Zorg dat EF Core en Design op exact dezelfde versie staan
RUN dotnet add /src/Persistence/Persistence.csproj package Microsoft.EntityFrameworkCore --version 6.0.25
RUN dotnet add /src/Persistence/Persistence.csproj package Microsoft.EntityFrameworkCore.Design --version 6.0.25

# Installeer de EF Core CLI tool (dotnet-ef)
RUN dotnet tool install --global dotnet-ef --version 6.0.25

# Zet pad zodat dotnet-ef beschikbaar is
ENV PATH="$PATH:/root/.dotnet/tools"

# Build de app
RUN dotnet build "/src/Server/Server.csproj" -c Release



# Bundle de migraties in een uitvoerbaar bestand (self-contained voor Linux)
RUN dotnet ef migrations bundle \
    -o /app/migrations \
    --project /src/Persistence \
    --startup-project /src/Server \
    --configuration Release \
    --verbose \
    --no-build

# Publish stage (gebruik de build output)
FROM build AS publish
RUN dotnet publish "src/Server/Server.csproj" -c Release -o /app/publish --no-build

# Genereer een ontwikkelcertificaat voor HTTPS
RUN dotnet dev-certs https --export-path /app/publish/certificate.pem --no-password --format PEM

# Final stage - runtime image met alleen benodigde bestanden
FROM base AS final
WORKDIR /app

# Kopieer gepubliceerde app-bestanden en de migratie bundle + script
COPY --from=publish /app/publish . 
COPY --from=publish /app/migrations .
COPY --from=publish /src/dockerrunner.sh .
# Geef non-root gebruiker (app) eigenaarrechten op bestanden
RUN chmod +x /app/dockerrunner.sh
# Schakel over naar non-root user 'app' (voor security)
USER app

# Configureer om de HTTPS certificaat bestanden te gebruiken
ENV ASPNETCORE_Kestrel__Certificates__Default__Path="/app/certificate.pem" 
ENV ASPNETCORE_Kestrel__Certificates__Default__KeyPath="/app/certificate.key"

WORKDIR /app
# Stel de entrypoint in naar de bash opstartscript
ENTRYPOINT ["bash","/app/dockerrunner.sh"]
