# STAP 1: Gebruik een .NET SDK image voor het bouwen van de applicatie
FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /src

# Kopieer projectbestanden en restore dependencies
COPY . . 
RUN dotnet restore src/Server/Server.csproj

# Build en publiceer de release-versie
RUN dotnet publish src/Server/Server.csproj -c Release -o /app/publish

# STAP 2: Gebruik een kleinere runtime image voor productie
FROM mcr.microsoft.com/dotnet/aspnet:6.0
WORKDIR /app

# Kopieer de build-output naar de runtime-container
COPY --from=build /app/publish .

# Open de poort waarop de app draait
EXPOSE 5000

# Zorg dat de juiste omgevingsvariabelen ingesteld worden
ENV ASPNETCORE_ENVIRONMENT=Production

# Start de applicatie wanneer de container opstart
ENTRYPOINT ["dotnet", "Server.dll"]
