# Changelog

Todas las versiones notables de PartFinder 360.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/),
versionado según [Semantic Versioning](https://semver.org/lang/es/).

## [1.1.0] - 2026-10-04 (versionCode 4)

### Añadido
- Tracking de uso anonimo por device_id (UUID persistente)
- Eventos: app_open, prt_query_start, prt_query_success, prt_query_fail
- Endpoint publico POST /api/usage/track
- Cache de MTT en microservicio (mtt-service, 20-40x mas rapido)
- Admin API con JWT (login, health, quota, stats, usage)
- Panel admin con auto-refresh (dashboard 45s, metricas 60s)
- Deteccion de cuota Boostr real (headers ratelimit-*)

### Cambiado
- PRT: prioriza vehicle_cache antes que el microservicio
- MTT: timeout reducido de 20s/25s a 5s (mas responsivo)
- /full: mejor manejo de errores por fuente (metadata en evento)
- Orden de /full: cache local primero, microservicio despues

### Mejorado
- Tiempo de /full: de 3-12s a 0.15-0.30s en cache hit
- Tiempo de mtt-service: 7s primera vez, 0.15s en cache
- Arquitectura de microservicios (mtt-service reutilizable)
- Documentacion completa (ARQUITECTURA.md, CONTRIBUTING.md)

### Conocido
- Teclado virtual breve (~200-500ms) tras resolver el captcha de PRT.
  Deuda tecnica conocida por limitaciones de la combinacion
  webview_flutter 4.x + PlatformView + autofocus de ASP.NET.
  Solucion futura: migrar a flutter_inappwebview o AndroidView directo.

## [1.0.0] - 2026-10-01 (versionCode 3)

### Añadido
- Consulta Técnica PRT con prellenado automático de patente
- Extracción silenciosa de datos del vehículo desde el portal oficial
- Overlay nativo anti-flicker durante el postback de ASP.NET
- Bridge JavaScript optimizado (JS V118 + optimizaciones V122/V123)
- Fallback multi-proveedor: Boostr, MTT, SII, PRT
- Cache local de resultados para consultas repetidas
- Pantalla de encargo por robo (AutoSeguro)
- HUD de auditoría en vivo (red + progreso)
- Diálogo estricto de "sin respuesta" con reintento manual

### Conocido
- Teclado virtual breve (~200-500ms) tras resolver el captcha de PRT.
  Deuda técnica conocida por limitaciones de la combinación
  `webview_flutter 4.x` + PlatformView + autofocus de ASP.NET.
  Solución futura: migrar a `flutter_inappwebview` o `AndroidView` directo.

## [Unreleased]

### Por hacer
- Migrar a `flutter_inappwebview` para control explícito del IME
- Internacionalización (i18n)
- Modo oscuro/claro configurable
