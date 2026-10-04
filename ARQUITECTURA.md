# Arquitectura PartFinder 360

Documento consolidado de la arquitectura del ecosistema PartFinder.

---

## 1. Vision general

Ecosistema que consulta informacion oficial de vehiculos chilenos por
patente. Consiste en:

- App publica (Flutter Android) - usuarios finales
- App admin (Flutter Android) - uso interno
- Backend API (FastAPI) - cerebro del sistema
- Microservicios de scraping - fuentes oficiales
- Bases de datos (Postgres + SQLite)

---

## 2. Servicios

### 2.1 pf_api (backend principal)

- Tipo: Docker container
- Puerto: 8000 (expuesto via Cloudflare)
- Repo: victorneyraars/partfinder360
- Path: /opt/partfinder360/partfinder
- Stack: Python 3.11 + FastAPI + Postgres

Responsabilidades:
- API REST para app publica y admin
- Orquestacion de fuentes (PRT, Boostr, MTT, SII, AutoSeguro)
- Cache de resultados (tabla vehicle_cache)
- Tracking de uso (tabla usage_events)
- Admin API con JWT

### 2.2 pf_database (PostgreSQL)

- Tipo: Docker container
- Puerto: 5432 (interno, no expuesto)
- Imagen: postgres:15-alpine
- Volumen: /opt/partfinder360/database

Tablas principales:
- vehicle_cache - Cache de fichas tecnicas
- usage_events - Tracking de uso
- api_quota - Cuotas de APIs externas
- sii_tasaciones - Base de tasaciones SII
- boostr_pending_queue - Cola de Boostr

### 2.3 mtt-service (scraper MTT con cache)

- Tipo: Docker container
- Puerto: 3091 (interno, solo accesible por otros contenedores)
- Repo: victorneyraars/mtt-service
- Path: /opt/servicios/mtt-service
- Stack: Python 3.11 + FastAPI + SQLite

Responsabilidades:
- Scraping de apps.mtt.cl (RNSTP)
- Cache SQLite con TTL 15 dias
- Reduccion de 7s a 0.15s en cache hit

Endpoints:
- GET /health
- GET /api/v1/mtt/{plate}
- GET /api/v1/mtt/{plate}/cache
- DELETE /api/v1/mtt/{plate}/cache

Variables de entorno:
- MTT_CACHE_DB=/data/mtt_cache.db
- MTT_CACHE_TTL_DAYS=15

### 2.4 prt-service (scraper PRT)

- Tipo: systemd service (no Docker)
- Puerto: 3090 (expuesto via host.docker.internal)
- Path: /opt/servicios/prt-service
- Stack: Node.js + Fastify + Cheerio

Modos (variable PRT_PROVIDER):
- mock - datos simulados (actual)
- prt - scraper real de prt.cl
- verifik - API comercial

Endpoints:
- GET /health
- GET /api/v1/prt/{patente}

Nota: migracion a Docker pendiente (ver PENDIENTES.md)

### 2.5 boostr-service (API Boostr con cache)

- Tipo: Docker container
- Puerto: 3092 (interno, solo accesible por otros contenedores)
- Repo: victorneyraars/boostr-service
- Path: /opt/servicios/boostr-service
- Stack: Python 3.11 + FastAPI + SQLite

Responsabilidades:
- Envolver la API externa Boostr (api.boostr.cl)
- Cache SQLite con TTL 15 dias (patente cacheada = 0 cuota)
- Devolver el payload enriquecido (_boostr_enrich) al backend
- Exponer headers ratelimit-* en el JSON para que pf_api los propague

Endpoints:
- GET /health
- GET /api/v1/boostr/{plate}          (query ?force=true bypasea cache)
- GET /api/v1/boostr/{plate}/cache    (no consume cuota)
- DELETE /api/v1/boostr/{plate}/cache (invalida cache)

Variables de entorno:
- BOOSTR_CACHE_DB=/data/boostr_cache.db
- BOOSTR_CACHE_TTL_DAYS=15
- BOOSTR_API_KEY (via env_file .env)

Beneficio medido:
- Primera consulta: ~500ms + 1 cuota Boostr
- Cache hit: ~7ms + 0 cuota

### 2.6 APIs externas

- Boostr - Ficha tecnica (api.boostr.cl)
  - 100 consultas/dia
  - Expone headers ratelimit-*
  - Consulta a traves del microservicio boostr-service (con cache SQLite)
  - pf_api propaga el ratelimit a la tabla api_quota en Postgres
  
- SII - Tasacion fiscal
  - Consulta via base local sii_tasaciones
  - Actualizada con archivos xlsx anuales
  
- AutoSeguro - Encargo por robo
  - Via WebView en la app publica con captcha humano
  - JS inyectado en autoseguro.gob.cl
  
- PRT - Revision tecnica
  - Via WebView en la app publica con captcha humano
  - JS inyectado en prt.cl
  - Fallback: cache en vehicle_cache
  
- MTT - RNSTP (transporte publico)
  - Via mtt-service con cache SQLite

---

## 3. Flujos de datos

### 3.1 Consulta completa desde la app publica

1. Usuario ingresa patente en la pantalla principal
2. App llama a GET /api/patente/{plate}/full
3. pf_api ejecuta en paralelo:
   - _full_prt: cache vehicle_cache -> prt-service (fallback)
   - _full_boostr: API Boostr (con cuota rastreada)
   - _full_mtt: mtt-service (cache SQLite) -> scraper local (fallback)
   - _full_sii: base local sii_tasaciones
   - _full_fuel_efficiency: API Boostr
   - _full_auto_seguro: idle (espera confirmacion usuario)
4. pf_api ensambla respuesta y registra evento dashboard_query
5. App recibe todo en 1 request (<300ms si hay cache)

### 3.2 Flujo PRT con captcha humano

1. Usuario toca tarjeta PRT en el dashboard
2. App abre WebView con prt.cl
3. JS inyectado pre-llena patente
4. Usuario resuelve reCAPTCHA
5. JS hace click en Buscar, espera postback ASP.NET
6. JS extrae tabla y emite JSON via PrtBridge
7. App guarda en vehicle_cache via POST /api/vehicle/cache
8. App actualiza dashboard

### 3.3 Flujo MTT

Cache hit (mayoria de casos):
- App -> pf_api -> mtt-service -> SQLite
- Respuesta: ~150ms

Cache miss (primera vez o TTL expirado):
- App -> pf_api -> mtt-service -> apps.mtt.cl (scraping)
- Respuesta: ~7s
- Se guarda en SQLite para proximas consultas

### 3.4 Flujo Boostr

Cache hit en el micro (mayoria de casos):
- App -> pf_api -> boostr-service -> SQLite
- Respuesta: ~7ms, 0 cuota consumida
- pf_api NO propaga ratelimit (no viene en cache hits)

Cache miss en el micro (primera vez o TTL expirado):
- App -> pf_api -> boostr-service -> api.boostr.cl
- Respuesta: ~500ms, 1 cuota consumida
- boostr-service guarda en su SQLite + devuelve ratelimit en el JSON
- pf_api propaga ratelimit a tabla api_quota (Postgres)
- pf_api guarda el payload en vehicle_cache (para futuras consultas)

Cache hit en pf_api (Postgres):
- App -> pf_api -> vehicle_cache (ni siquiera toca boostr-service)
- Respuesta: ~10ms, 0 cuota

Sobre cuota agotada (429 / PLAN_LIMIT_EXCEEDED):
- boostr-service devuelve status=queued
- pf_api encola la patente en boostr_pending_queue
- El worker procesa la cola cuando vuelve a haber cuota

### 3.5 Tracking de uso

- App publica envia eventos a POST /api/usage/track
- Eventos: app_open, prt_query_start, prt_query_success, prt_query_fail
- pf_api registra dashboard_query con duracion y estado de fuentes
- Admin consulta via GET /api/admin/usage/*

---

## 4. Bases de datos

### 4.1 PostgreSQL (pf_database)

Path: /opt/partfinder360/database
Credenciales: ver /opt/partfinder360/docker-compose.yml

Tablas:
- vehicle_cache (plate, dv, make, model, year, raw_data, source, data, created_at, updated_at)
- usage_events (id, device_id, event_type, plate, platform, app_version, metadata, created_at)
- api_quota (provider, total_limit, remaining, updated_at)
- sii_tasaciones (codigo, marca, modelo, anio, tasacion, ...)
- boostr_pending_queue (id, plate, status, created_at)

### 4.2 SQLite (mtt-service + boostr-service)

Cada microservicio tiene su propio SQLite con cache de patentes.

**mtt-service:**
- Path: /data/mtt_cache.db (dentro del contenedor)
- Volumen: /opt/servicios/mtt-service/data
- Tabla: mtt_cache (plate, data TEXT JSON, updated_at TIMESTAMP)
- TTL: 15 dias (MTT_CACHE_TTL_DAYS)

**boostr-service:**
- Path: /data/boostr_cache.db (dentro del contenedor)
- Volumen: /opt/servicios/boostr-service/data
- Tabla: boostr_cache (plate, data TEXT JSON, updated_at TIMESTAMP)
- TTL: 15 dias (BOOSTR_CACHE_TTL_DAYS)

---

## 5. Integracion entre servicios

### 5.1 Comunicacion pf_api <-> mtt-service

pf_api tiene la variable:
  MTT_SERVICE_URL=http://mtt-service:3091

Codigo en pf_api:
  def _fetch_mtt_from_service(plate):
      url = f"{MTT_SERVICE_URL}/api/v1/mtt/{plate}"
      r = requests.get(url, timeout=15)
      if r.status_code != 200:
          return None
      return r.json().get("data")

Fallback: si el microservicio falla, pf_api usa el scraper local
(_scrape_mtt) para no romper la app.

### 5.2 Comunicacion pf_api <-> prt-service

pf_api tiene la variable:
  PRT_SERVICE_URL=http://host.docker.internal:3090

Usado via prt_client.consultar_revision_tecnica(patente).

Nota: 'host.docker.internal' apunta al host (172.18.0.1) porque
prt-service corre como systemd, no como contenedor.

### 5.3 Comunicacion pf_api <-> boostr-service

pf_api tiene la variable:
  BOOSTR_SERVICE_URL=http://boostr-service:3092

Codigo en pf_api (patron comun a los 4 sitios migrados):
  r = requests.get(f"{BOOSTR_SERVICE_URL}/api/v1/boostr/{plate}", timeout=20)
  payload = r.json()
  # Propagar ratelimit a Postgres si viene (solo en cache miss)
  if payload.get("ratelimit"):
      _update_boostr_quota_from_response(payload["ratelimit"])
  # status: ok | not_found | queued | error
  return {"status": payload["status"], "data": payload.get("data", {})}

Sitios donde pf_api consume boostr-service:
- _full_boostr() (dashboard /full)
- Fallback SII en /api/tasacion
- provider=boostr en /api/patente/{patente}
- Fallback Boostr en /api/patente/{patente}/pdf
- /api/patente/fallback-boostr

Nota: fuel_efficiency sigue llamando api.boostr.cl directo (endpoint distinto,
uso bajo, no es de vehiculos).

### 5.4 Comunicacion app publica <-> pf_api

HTTPS via Cloudflare:
  api.studiodigital360.com -> 91.99.145.70:8000

Endpoints usados por la app:
- GET /api/patente/{plate}/full
- GET /api/patente/{plate}?provider=mtt
- POST /api/usage/track
- POST /api/vehicle/cache
- GET /api/debug/prt-script.js
- GET /api/debug/auto-seguro-script.js

### 5.5 Comunicacion app admin <-> pf_api

Mismos endpoints HTTPS pero con JWT en el header Authorization.
Endpoints admin:
- POST /api/admin/auth/login
- GET /api/admin/health
- GET /api/admin/quota
- GET /api/admin/plates/stats
- GET /api/admin/plates/recent
- GET /api/admin/usage/overview
- GET /api/admin/usage/activity
- GET /api/admin/usage/events
- GET /api/admin/usage/top_devices

---

## 6. CI/CD (GitHub Actions)

### 6.1 partfinder-mobile

Workflow: .github/workflows/build_apk.yml
Disparadores: push a main (release oficial) y dev (pre-release)
Trigger: cada push o PR
Proceso:
1. flutter create --platforms=android (regenera android/)
2. git checkout -- lib/ pubspec.yaml
3. Copia keystore de keystore/upload-keystore.jks
4. python3 patch_android.py
5. flutter pub get + iconos
6. flutter build apk + appbundle
7. Publica release en GitHub

### 6.2 partfinder-admin

Workflow: .github/workflows/build_admin.yml
Disparadores: push a main
Firma: usa secretos GitHub (keystore base64) en vez de archivo en repo
Proceso similar pero con firma via ANDROID_KEYSTORE_BASE64

### 6.3 Microservicios (mtt-service, boostr-service)

Sin CI/CD todavia (deploy manual con docker build + compose up)
Pendiente: agregar workflow para build automatico de ambos

---

## 7. Troubleshooting

### 7.1 pf_api no arranca

  docker logs pf_api --tail 30
  docker exec pf_api python3 -m py_compile /app/main.py

### 7.2 mtt-service no responde

  docker logs pf_mtt_service --tail 20
  docker exec pf_api python3 -c "import requests; print(requests.get('http://mtt-service:3091/health').json())"

### 7.3 PRT devuelve datos mock

  curl -s http://localhost:3090/health
  # Ver 'provider' en la respuesta. Si dice 'mock', esta en modo datos falsos.
  # Cambiar: systemctl edit prt-service y ajustar PRT_PROVIDER=prt

### 7.4 Cuota Boostr desactualizada

  docker exec pf_database psql -U pf_user -d partfinder -c "SELECT provider, remaining, updated_at FROM api_quota WHERE provider='boostr';"
  # Deberia tener updated_at reciente. Si no, hacer una consulta para forzar actualizacion.
  # NOTA: la cuota solo se actualiza en cache miss del boostr-service.
  #       Cache hits (SQLite) NO tocan Boostr ni Postgres.

### 7.5 Cache MTT

  # Ver cache
  docker exec pf_mtt_service python3 -c "import sqlite3; conn=sqlite3.connect('/data/mtt_cache.db'); print(conn.execute('SELECT plate, updated_at FROM mtt_cache ORDER BY updated_at DESC LIMIT 10').fetchall())"

  # Limpiar una patente especifica
  curl -X DELETE http://localhost:3091/api/v1/mtt/BBCC12/cache

### 7.6 boostr-service no responde

  docker logs pf_boostr_service --tail 20
  docker exec pf_api python3 -c "import urllib.request; print(urllib.request.urlopen('http://boostr-service:3092/health').read().decode())"

### 7.7 Cache Boostr

  # Ver cache
  docker exec pf_boostr_service python3 -c "import sqlite3; conn=sqlite3.connect('/data/boostr_cache.db'); print(conn.execute('SELECT plate, updated_at FROM boostr_cache ORDER BY updated_at DESC LIMIT 10').fetchall())"

  # Info de una patente (no consume cuota)
  docker exec pf_api python3 -c "import urllib.request; print(urllib.request.urlopen('http://boostr-service:3092/api/v1/boostr/KHFF35/cache').read().decode())"

  # Invalidar cache
  docker exec pf_api python3 -c "import urllib.request; req=urllib.request.Request('http://boostr-service:3092/api/v1/boostr/KHFF35/cache', method='DELETE'); print(urllib.request.urlopen(req).read().decode())"

---

## 8. Comandos utiles

### 8.1 Docker

  docker ps                                      # Ver contenedores activos
  docker logs -f pf_api                          # Logs en vivo
  docker logs -f pf_mtt_service                  # Logs del mtt-service
  docker logs -f pf_boostr_service               # Logs del boostr-service
  cd /opt/partfinder360 && docker compose up -d  # Levantar todo el stack
  cd /opt/partfinder360 && docker compose restart partfinder-api

  # Rebuild de un microservicio tras cambio de codigo
  cd /opt/servicios/mtt-service && docker build -t mtt-service:1.0.0 .
  cd /opt/servicios/boostr-service && docker build -t boostr-service:1.0.0 .
  cd /opt/partfinder360 && docker compose up -d boostr-service

### 8.2 Backend

  curl -s http://localhost:8000/api/boostr/status
  curl -s "http://localhost:8000/api/patente/KHFF35/full"
  curl -s http://localhost:8000/api/admin/health -H "Authorization: Bearer ..."

### 8.3 DB

  docker exec pf_database psql -U pf_user -d partfinder
  docker exec pf_database psql -U pf_user -d partfinder -c "SELECT COUNT(*) FROM vehicle_cache"

### 8.4 Git

  cd /opt/partfinder-mobile && git log --oneline -5
  cd /opt/partfinder-admin && git log --oneline -5
  cd /opt/partfinder360/partfinder && git log --oneline -5
  cd /opt/servicios/mtt-service && git log --oneline -5
  cd /opt/servicios/boostr-service && git log --oneline -5

---

Ultima actualizacion: 2026-10-04
