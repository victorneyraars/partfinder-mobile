# Changelog

Todas las versiones notables de PartFinder 360.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/),
versionado según [Semantic Versioning](https://semver.org/lang/es/).

## [1.0.0] - 2026-10-01

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
