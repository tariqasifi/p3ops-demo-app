# STAP 1: Gebruik een .NET SDK image om de applicatie te bouwen
FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /app

# Kopieer alleen de projectbestanden (voor een snellere build-cache)
COPY ["src/Server/Server.csproj", "src/Server/"]
WORKDIR /app/src/Server
RUN dotnet restore

# Kopieer de volledige code en bouw de release-versie
COPY src/Server/ ./src/Server/
WORKDIR /app/src/Server
RUN dotnet publish -c Release -o /app/publish

# STAP 2: Gebruik een runtime image voor productie
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
