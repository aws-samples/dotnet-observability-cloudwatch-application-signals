#See https://aka.ms/containerfastmode to understand how Visual Studio uses this Dockerfile to build your images for faster debugging.

FROM mcr.microsoft.com/dotnet/aspnet:8.0-alpine AS base
WORKDIR /app
EXPOSE 80
EXPOSE 443

FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS build
WORKDIR "/src/Simple.CartApi"
COPY "Simple.CartApi.csproj" .
RUN dotnet restore "Simple.CartApi.csproj"
COPY . .
RUN dotnet build "Simple.CartApi.csproj" -c Release --no-restore

FROM build AS publish
RUN dotnet publish "Simple.CartApi.csproj" -c Release -o /app/publish --no-build

FROM base AS final
WORKDIR /app
COPY --chown=$APP_UID:$APP_UID --from=publish /app/publish .
USER $APP_UID
ENTRYPOINT ["dotnet", "Simple.CartApi.dll"]