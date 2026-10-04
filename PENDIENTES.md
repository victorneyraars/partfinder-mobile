# Pendientes y Roadmap

Ideas priorizadas para futuras versiones. No son urgentes - se ejecutan
cuando hay feedback real y capacidad.

---

## Completados recientemente (2026-10-04)

- [x] Auto-refresh del panel admin (dashboard cada 45s, metricas 60s)
- [x] Pausa de auto-refresh en background (ahorro de bateria)
- [x] Tracking de uso por device_id (app_open, dashboard_query, prt_query_*)
- [x] Endpoints admin de metricas (usage/overview, activity, events, top_devices)
- [x] Fix de cuota Boostr (captura real desde headers ratelimit-*)
- [x] Microservicio mtt-service con cache SQLite (20-40x mas rapido)
- [x] Integracion pf_api <-> mtt-service con fallback al scraper local
- [x] PRT: priorizar vehicle_cache antes que el microservicio
- [x] Reduccion de timeout MTT (20s/25s -> 5s)
- [x] Documentacion completa (ARQUITECTURA.md, CONTRIBUTING.md actualizado)
- [x] Fix mojibake UTF-8 (3 capas: middleware backend + utf8.decode en admin + mobile)
- [x] Microservicio boostr-service con cache SQLite (15d TTL, patron mtt-service)
- [x] Refactor backend: 4 sitios de Boostr directo migrados al microservicio
- [x] docker-compose.yml versionado en repo (partfinder/deploy/ + symlink)
- [x] Test MTT end-to-end validado en APK admin (cache hit 9ms)

---

## Pendientes activos

### 1. Lector de patentes por camara (ALTA prioridad)

**Objetivo:** el usuario apunta la camara al vehiculo, el sistema detecta
la patente en tiempo real, el usuario confirma y se rellena
automaticamente el campo.

**Decisiones tomadas:**
- Proveedor: Plate Recognizer (API comercial)
  - 95%+ precision out-of-the-box
  - ~2.500 escaneos gratis/mes
  - ~USD 0.001 por escaneo despues del free tier
- Arquitectura: contenedor pf_vision como capa de abstraccion
- Reutilizable: cualquier proyecto del ecosistema puede llamar a pf_vision
- Migracion futura: si el volumen crece, migrar a PaddleOCR self-hosted
  dentro del mismo contenedor (sin cambiar endpoints)

**Razon de la eleccion:**
- Servidor actual (4 cores, 7.6 GB RAM) no tiene GPU real
- PaddleOCR saturaria el CPU en cada escaneo
- Plate Recognizer no consume CPU del servidor
- Tiempo de implementacion: 3-5 dias vs 2-3 semanas

**Plan de ejecucion (cuando arranque):**
Fase 1 - Backend (3-5 dias):
- Crear /opt/servicios/vision-service/
- Anadir contenedor pf_vision a docker-compose.yml
- Endpoint POST /api/vision/scan -> proxy a Plate Recognizer
- Endpoint GET /api/vision/health
- Cache de resultados por hash de imagen

Fase 2 - Flutter (1 semana):
- Branch feature/plate-scanner en dev
- Pantalla PlateScannerScreen con preview de camara
- Captura cada 500ms, envia al backend
- Overlay con texto detectado + boton "Confirmar"
- Validacion regex: ^[A-Z]{4}[0-9]{2}$ o ^[A-Z]{2}[0-9]{4}$

Fase 3 - Refinamiento:
- ML Kit para bounding box on-device
- Manejo de baja luz, angulos extremos
- Tests en dispositivos variados

### 2. Migrar prt-service a Docker (MEDIA prioridad)

**Objetivo:** unificar la arquitectura. Hoy corre como systemd.

**Beneficio:**
- Consistencia con mtt-service (mismo patron)
- Portabilidad entre servidores
- Versionado de imagen

**Tiempo:** 2-3 horas.

### 3. Cache de Boostr con TTL — COMPLETADO 2026-10-04
**Implementado:**
- Microservicio boostr-service (repo victorneyraars/boostr-service)
- FastAPI puerto 3092 + cache SQLite TTL 15 dias
- Endpoints: /health, /api/v1/boostr/{plate}, /{plate}/cache, DELETE /{plate}/cache
- Backend pf_api: 4 sitios migrados (dashboard /full, /api/tasacion,
  provider=boostr, /pdf, fallback-boostr)
- Ratelimit propagado a Postgres (api_quota) via headers del micro
- Medido: 493ms (scraper) -> 7ms (cache hit) + 0 cuota en hits
**Pendiente menor:** fuel_efficiency sigue llamando Boostr directo (uso bajo).

### 4. Push notifications para alertas (MEDIA prioridad)

**Objetivo:** enterarte de eventos criticos sin abrir la app admin.

**Eventos a notificar:**
- Cuota Boostr < 20%
- PRT falla 3 veces seguidas
- MTT falla > 50% en 1 hora
- Nuevo device empieza a usar la app

**Stack:** Firebase Cloud Messaging (gratis)
**Tiempo:** 4-6 horas.

### 5. Tests de servicios en admin (MEDIA prioridad)
**Estado:** pantalla ServiceTestScreen funcional para MTT.
**Pendiente:**
- Agregar test de prt-service (endpoint backend + boton/tab en admin)
- Agregar test de pf_database (SELECT 1, pg_stat_activity, version, tamaño)
- Agregar test de boostr-service (ahora 0 cuota en cache hits)
- Refactor UI: TabBar por servicio en vez de cards apiladas
