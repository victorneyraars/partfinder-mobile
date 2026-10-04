# PartFinder 360 - App Publica

App movil Flutter que consulta informacion oficial de vehiculos
chilenos por patente.

## Que hace

- Consulta ficha tecnica (Boostr), Revision Tecnica (PRT), MTT
  (transporte publico), SII (tasacion) y AutoSeguro (encargo por robo)
- Multiples fuentes en una sola consulta
- WebView con captcha humano para PRT y AutoSeguro
- Cache local de resultados
- Modo oscuro nativo

## Stack

- Flutter 3.19.6 (Android)
- Backend: api.studiodigital360.com
- Distribucion: Google Play Console (Internal Testing)

## Documentacion

- ARQUITECTURA.md - Arquitectura del ecosistema completo
- CONTRIBUTING.md - Guia de contribucion
- PENDIENTES.md - Roadmap priorizado
- CHANGELOG.md - Historial de versiones

## Branches

- main - Produccion (Play Store)
- dev - Desarrollo y pruebas (pre-releases)

## Build local

    flutter pub get
    flutter build apk --release

En produccion el build corre en GitHub Actions al hacer push.

## Instalacion para testers

Bajar el APK del ultimo pre-release en GitHub Releases o via Play
Console (Internal Testing).

## Version actual

- Produccion: v1.0.0 (versionCode 3)
- Desarrollo: v1.1.0-dev (con tracking de uso, pendiente merge)
