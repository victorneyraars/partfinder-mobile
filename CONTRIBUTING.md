# Contribuir a PartFinder 360

Guia de traspaso para desarrolladores.

## 1. Que es PartFinder 360

App movil Flutter que consulta informacion oficial de vehiculos chilenos por patente. Fuentes: PRT, Boostr, MTT, SII, AutoSeguro.

## 2. Stack

- Frontend: Flutter 3.19.6 (Android)
- Backend: Python 3.11 + FastAPI (contenedor pf_api)
- BD: PostgreSQL 15 (contenedor pf_database)
- Scraper PRT: Node.js puerto 3090 (servicio host)
- CI/CD: GitHub Actions
- Distribucion: Google Play Console (Internal Testing)

## 3. Infra produccion

- Servidor: 91.99.145.70
- Contenedores: pf_api (8000), pf_database (5432 interno)
- Servicio host: prt-service (Node.js, 3090)
- Dominio: api.studiodigital360.com -> Cloudflare -> pf_api

## 4. Flujo PRT

1. Usuario abre pantalla PRT en Flutter
2. Flutter descarga JS: GET /api/debug/prt-script.js
3. Lo inyecta en WebView que carga prt.cl
4. JS pre-llena patente, usuario resuelve reCAPTCHA
5. JS click en Buscar, espera postback de ASP.NET
6. JS extrae tabla, emite JSON via PrtBridge
7. Flutter muestra el resultado

## 5. Flujo AutoSeguro

1. Usuario abre pantalla AutoSeguro
2. Flutter descarga JS: GET /api/debug/auto-seguro-script.js
3. Lo inyecta en WebView que carga autoseguro.gob.cl
4. JS pre-llena patente, usuario resuelve reCAPTCHA
5. JS hace submit automatico
6. JS detecta resultado via regex, emite JSON
7. Flutter muestra el resultado

## 6. Archivos criticos

- /opt/partfinder360/prt_injection.js (PRT, V122)
- /opt/partfinder360/auto_seguro_injection.js (AutoSeguro, V37b)
- /opt/partfinder360/partfinder/main.py (backend FastAPI)
- /opt/partfinder-mobile/lib/main.dart (Flutter, ~7800 lineas)
- /opt/partfinder-mobile/patch_android.py (config Android build)
- /opt/partfinder-mobile/.github/workflows/build_apk.yml (CI/CD)
- /opt/partfinder-mobile/keystore/upload-keystore.jks (firma)

## 7. Flujo Git

Branches permanentes:
- main: produccion. Solo merge desde dev.
- dev: desarrollo. Push directo OK.

Feature branch:
1. git checkout dev && git pull origin dev
2. git checkout -b feature/mi-cambio
3. Editar, commit, push
4. git checkout dev && git merge feature/mi-cambio
5. git push origin dev (dispara pre-release automatico)

Promover a produccion:
1. git checkout main && git pull origin main
2. git merge dev --no-ff -m "release: vX.Y.Z"
3. git push origin main

Convenciones de commits:
- feat: nueva funcionalidad
- fix: correccion de bug
- chore: mantenimiento
- ci: cambios en workflow
- docs: documentacion
- perf: mejora de performance

## 8. Versionado

En pubspec.yaml: version: 1.0.0+3

- versionName (1.0.0): visible al usuario
- versionCode (+3): para Play Store. SIEMPRE incrementa.

Regla de oro: versionCode nunca se repite. Si subes +3, proximo +4 o mayor.

Tipos de bump:
- Bug fix: 1.0.0 -> 1.0.1, versionCode +3 -> +4
- Nueva feature: 1.0.1 -> 1.1.0, +4 -> +5
- Breaking: 1.1.0 -> 2.0.0, +5 -> +6

Releases en GitHub:
- Tecnico (auto en main): v1.2.NNNN, NO marca Latest
- Pre-release (auto en dev): v1.2.NNNN-dev, NO marca Latest
- Oficial (manual): v1.0.0, SI marca Latest

## 9. Proceso release oficial

1. Editar pubspec.yaml: version: 1.0.1+4
2. git add pubspec.yaml && git commit -m "chore(release): 1.0.1+4"
3. git push origin main
4. Esperar build (~5 min): sleep 240 && gh run list --limit 1
5. Descargar AAB/APK del release tecnico mas reciente
6. git tag -a v1.0.1 -m "Release 1.0.1" && git push origin v1.0.1
7. gh release create v1.0.1 AAB APK --title "PartFinder 360 v1.0.1" --notes "..." --latest
8. Subir AAB a Play Console -> Internal Testing -> Crear nueva version

## 10. CI/CD

Workflow: .github/workflows/build_apk.yml

Disparadores:
- Push a main: build + release tecnico (NO Latest)
- Push a dev: build + pre-release
- PR a main: solo valida

Pasos:
1. Checkout + Java 17 + Flutter 3.19.6
2. flutter create --platforms=android (regenera android/)
3. git checkout -- lib/ pubspec.yaml (restaura codigo real)
4. Copia keystore
5. python3 patch_android.py (firma + minSdk 24)
6. flutter pub get + iconos
7. flutter build apk + appbundle
8. Publica en GitHub Releases

Notas:
- android/ NO se versiona, se genera en cada build
- Keystore si esta en el repo

## 11. Backend (pf_api)

Ubicacion host: /opt/partfinder360/partfinder/main.py
Contenedor: /app/main.py
Volumen: /opt/partfinder360/partfinder -> /app
Corre con --reload (autorecarga al editar main.py)

Reiniciar:
  docker restart pf_api
  docker logs -f pf_api --tail 50

Rollback emergencia:
  cp main.py.v117.bak main.py
  docker restart pf_api

Endpoints utiles:
- GET /api/debug/prt-script.js
- GET /api/debug/auto-seguro-script.js
- GET /api/patente/PLATE/full
- POST /api/vehicle/cache
- POST /api/debug/log

### 11.1 Encoding UTF-8 - Regla obligatoria

El backend tiene un middleware que fuerza application/json; charset=utf-8
en todas las respuestas JSON (ver _force_utf8_charset en main.py).

Por que existe: FastAPI/Starlette devuelve application/json sin charset,
y varios clientes HTTP (Dart http, curl viejo, apps iOS nativas) asumen
Latin-1 por default. Sin el middleware, Vehículo/Público/Región llegan
como VehÃculo/PÃºblico/RegiÃ³n a la UI (bug de mojibake).

Regla al agregar un endpoint nuevo: no hay que hacer nada especial. El
middleware cubre todas las respuestas automaticamente. Solo no devolver
Response con un content-type custom que incluya charset distinto, o el
middleware no lo pisara.

### 11.2 Encoding UTF-8 en clientes Dart (Flutter)

Regla obligatoria al parsear JSON desde Flutter: usar
utf8.decode(resp.bodyBytes) en vez de resp.body.

El paquete http de Dart asume Latin-1 cuando el Content-Type no declara
charset=utf-8. Aunque el backend ya lo declare, algunos proxies/CDN pueden
comerlo, y la app movil debe ser defensiva.

Helpers existentes:

- partfinder-mobile: lib/utils/http_json.dart

    import 'utils/http_json.dart';
    final raw = decodeJsonUtf8(resp) as Map<String, dynamic>;

- partfinder-admin: metodo _decodeJson en lib/core/api_client.dart
  (uso interno, no exportado)

Si agregas un nuevo provider o llamada HTTP: siempre usar el helper.
Nunca jsonDecode(resp.body) directo.


## 12. JS Injection

Ubicacion:
- /opt/partfinder360/prt_injection.js (V122)
- /opt/partfinder360/auto_seguro_injection.js (V37b)

main.py lee el archivo del disco en cada request. Editar el JS = cambio instantaneo en produccion (sin rebuild APK, sin restart backend).

Reglas:
1. SIEMPRE hacer backup: cp archivo.js archivo.js.pre-cambio.bak
2. Validar sintaxis: node --check archivo.js
3. Verificar endpoint sirve la version nueva
4. Probar en 1 dispositivo antes de dejar el cambio
5. NUNCA aplicar cambios no probados
6. NUNCA eliminar el backup antes de confirmar

Rollback instantaneo:
  cp archivo.js.pre-cambio.bak archivo.js

Bridge (JS -> Flutter via window.PrtBridge.postMessage):
PRT: READY, POSTBACK_START, CHALLENGE_OPEN, CHALLENGE_CLOSE, DEBUG, DATA, ERROR
AutoSeguro: READY, {status:"ok", encargo:bool, plate, mensaje}

Historial:
- PRT V117: baseline
- PRT V118: POSTBACK_START, CHALLENGE, telon persistente
- PRT V122: poll 200ms optimizado
- AutoSeguro V36: baseline
- AutoSeguro V37: rollback (rompia captcha)
- AutoSeguro V37b: fix regex "mantiene encargo policial"

## 13. Base de datos

Conectar:
  docker exec pf_database psql -U pf_user -d partfinder

Credenciales: en /opt/partfinder360/docker-compose.yml

Tablas:
- vehicle_cache: cache por patente (PRT/Boostr/MTT/SII)
- api_quota: rate limiting APIs
- boostr_pending_queue: cola Boostr
- sii_tasaciones: tasaciones SII

Reglas cache:
- AutoSeguro NUNCA se cachea (riesgo seguridad)
- PRT: 7 dias
- Boostr: 30 dias
- SII: 15 dias
- MTT: 15 dias

Consultas:
  SELECT plate, source, created_at FROM vehicle_cache ORDER BY created_at DESC LIMIT 10;
  SELECT jsonb_pretty(data) FROM vehicle_cache WHERE plate = 'ABCD12';

## 14. Play Console

Package: com.studiodigital360.partfinder360
Track: Internal Testing
Ultima version: 1.0.0 (versionCode 3)

Requisitos:
- minSdkVersion: 24
- targetSdkVersion: 36
- compileSdkVersion: 36
- Formato: .aab
- Firma: keystore/upload-keystore.jks

REGLA CRITICA: Play rechaza AAB con versionCode menor o igual al ultimo publicado. Verificar en Play Console -> Internal Testing -> Versiones.

Subir AAB:
1. Descargar app-release.aab del release oficial GitHub
2. Play Console -> Internal Testing -> Crear nueva version
3. Subir AAB
4. Agregar notas de la version
5. Siguiente -> Revisar version -> Iniciar lanzamiento

## 15. Troubleshooting

Sintoma: Portal PRT sin respuesta
  Diagnostico: docker logs -f pf_api --tail 100 | grep PRT-CONSOLE

Sintoma: teclado aparece brevemente tras captcha
  Deuda tecnica conocida. Solucion futura: flutter_inappwebview

Sintoma: bucle infinito de carga
  Causa: watchdog reinjecta JS durante postback
  Fix: V123 (_postbackStarted en main.dart)
  Verificar: grep -c _postbackStarted lib/main.dart

Sintoma: versionCode already used
  Fix: sed -i s/^version: .*/version: 1.0.1+5/ pubspec.yaml

Sintoma: AndroidWebResourceError masivos
  Causa: algun fix de IME/Activity rompiendo WebView
  Fix: revisar patch_android.py (no listener custom, no adjustNothing)

Verificacion rapida:
  curl -s https://api.studiodigital360.com/api/debug/prt-script.js | head -3
  docker ps | grep pf_api
  docker exec pf_database psql -U pf_user -d partfinder -c SELECT 1;
  gh run list --limit 3

## 16. Comandos utiles

Git:
  git status
  git branch --show-current
  git log --oneline -5
  git checkout dev && git pull origin dev

GitHub:
  gh release list --limit 10
  gh run list --limit 5
  gh run watch

Docker:
  docker ps
  docker logs -f pf_api --tail 100
  docker restart pf_api
  docker exec -it pf_api bash

DB:
  docker exec pf_database psql -U pf_user -d partfinder -c SELECT
  docker exec pf_database pg_dump -U pf_user partfinder > backup.sql

JS:
  nano /opt/partfinder360/prt_injection.js
  node --check /opt/partfinder360/prt_injection.js
  cp prt_injection.js prt_injection.js.pre-cambio.bak

APK servicio temporal:
  cd /tmp/apk-dir && python3 -m http.server 8095 --bind 0.0.0.0
  Desde movil: http://91.99.145.70:8095/app-release.apk

## 17. Deuda tecnica

1. Teclado breve (~300ms) tras captcha PRT. Solucion: flutter_inappwebview
2. main.dart monolitico (~7800 lineas). Refactor a capas.
3. JS embebido en Dart (fallback). Unificar en archivo externo.
4. Sin tests automatizados. Agregar flutter test.
5. Sin monitoreo crashes. Firebase Crashlytics.
6. minSdk 24 excluye Android 5-6 (~2%). Aceptable.

## 18. Checklist nuevo desarrollador

- Acceso SSH a 91.99.145.70
- Acceso repo GitHub victorneyraars/partfinder-mobile
- Acceso Play Console
- Leer este documento completo
- Probar: docker logs -f pf_api --tail 50
- Probar: gh run list --limit 5
- Probar: docker exec pf_database psql -U pf_user -d partfinder -c SELECT 1;
- Clonar repo y flutter pub get
- Revisar JS de PRT y AutoSeguro
- Hacer cambio trivial en dev y verificar pre-release

---

Ultima actualizacion: 2026-10-02

---

## 9. Microservicios

El ecosistema tiene 3 microservicios propios (aparte de pf_api):

### 9.1 mtt-service (Docker, puerto 3091)

- Repo: victorneyraars/mtt-service
- Path: /opt/servicios/mtt-service
- Hace: scraping de apps.mtt.cl con cache SQLite (TTL 15 dias)
- Beneficio: primera consulta ~7s, siguientes ~0.15s
- Como se usa desde pf_api:

    MTT_SERVICE_URL=http://mtt-service:3091
    result = _fetch_mtt_from_service(plate)  # si None, fallback al scraper local

- Modificar el scraper: editar /opt/servicios/mtt-service/src/mtt_scraper.py
- Rebuild despues de cambios:

    cd /opt/servicios/mtt-service
    docker build -t mtt-service:1.0.0 .
    cd /opt/partfinder360
    docker compose up -d --force-recreate mtt-service

### 9.2 prt-service (systemd, puerto 3090)

- Path: /opt/servicios/prt-service
- Hace: scraping de prt.cl (modo actual: mock)
- Modos: mock / prt (real) / verifik (API comercial)
- Cambiar modo:

    systemctl edit prt-service
    # Ajustar: Environment=PRT_PROVIDER=prt
    systemctl daemon-reload && systemctl restart prt-service

- Logs:

    journalctl -u prt-service -f

### 9.3 boostr-service (Docker, puerto 3092)

- Repo: victorneyraars/boostr-service
- Path: /opt/servicios/boostr-service
- Hace: consulta a api.boostr.cl (API comercial) con cache SQLite (TTL 15 dias)
- Beneficio: primera consulta ~500ms + 1 cuota, siguientes ~7ms + 0 cuota
- Como se usa desde pf_api:

    BOOSTR_SERVICE_URL=http://boostr-service:3092
    r = requests.get(f"{BOOSTR_SERVICE_URL}/api/v1/boostr/{plate}")
    # pf_api propaga el ratelimit a Postgres (api_quota) desde la respuesta

- Endpoints del micro:

    GET    /health                        # estado + api_key_configured
    GET    /api/v1/boostr/{plate}         # consulta con cache (?force=true bypasea)
    GET    /api/v1/boostr/{plate}/cache   # info cache (no consume cuota)
    DELETE /api/v1/boostr/{plate}/cache   # invalidar cache de una patente

- Modificar el cliente: editar /opt/servicios/boostr-service/src/boostr_client.py
- Rebuild despues de cambios:

    cd /opt/servicios/boostr-service
    docker build -t boostr-service:1.0.0 .
    cd /opt/partfinder360
    docker compose up -d --force-recreate boostr-service

- Formato de respuesta (importante para integrar):
    El campo `ratelimit` SOLO viene en cache miss (cuando se llamo a Boostr).
    Trae los headers ratelimit-remaining/limit/reset, que pf_api propaga a
    la tabla api_quota en Postgres.
    El campo `status` puede ser: ok | not_found (V-02) | queued (429) | error.

### 9.4 Como agregar un servicio nuevo

Patron recomendado (usado por mtt-service y boostr-service):

1. Crear directorio en /opt/servicios/{nombre}-service/
2. Incluir: Dockerfile, main.py (o server.js), requirements.txt, src/
3. Exponer un /health para healthcheck
4. Agregar variable de entorno en pf_api via docker-compose.yml
5. Integrar en main.py con fallback al metodo local
6. Crear repo en GitHub (victorneyraars/{nombre}-service)
7. Agregar servicio al docker-compose.yml

---

## 10. Troubleshooting rapido

### El /full tarda mucho (>2s)

Verificar cache de MTT:

    docker exec pf_mtt_service python3 -c "import sqlite3; conn=sqlite3.connect('/data/mtt_cache.db'); print(conn.execute('SELECT COUNT(*) FROM mtt_cache').fetchone())"

Si tiene <10 patentes, es normal (cache miss). Despues de algunas consultas deberia bajar a <0.5s.

### Boostr muestra cuota 0 o desactualizada

    curl -s http://localhost:8000/api/boostr/status | python3 -m json.tool

Si el updated_at es viejo, hacer cualquier consulta para forzar la actualizacion:

    curl -s "http://localhost:8000/api/patente/KHFF35/full" -o /dev/null

### mtt-service no responde

    docker logs pf_mtt_service --tail 20
    docker restart pf_mtt_service

### prt-service devuelve datos mock

    curl -s http://localhost:3090/health
    # Si provider=mock, cambiar a PRT_PROVIDER=prt

### Reiniciar todo el stack

    cd /opt/partfinder360
    docker compose down
    docker compose up -d
    # prt-service (systemd):
    systemctl restart prt-service

---

## 11. Estado actual de servicios

| Servicio | Tipo | Estado | Puerto |
|---|---|---|---|
| pf_api | Docker | Activo | 8000 |
| pf_database | Docker | Activo | 5432 (interno) |
| pf_mtt_service | Docker | Activo | 3091 (interno) |
| pf_boostr_service | Docker | Activo | 3092 (interno) |
| prt-service | systemd | Activo | 3090 |

---

## 12. Repos GitHub

| Repo | Contenido |
|---|---|
| victorneyraars/partfinder-mobile | App publica Flutter |
| victorneyraars/partfinder-admin | App admin Flutter |
| victorneyraars/partfinder360 | Backend FastAPI |
| victorneyraars/mtt-service | Microservicio MTT con cache |
| victorneyraars/boostr-service | Microservicio Boostr con cache |

---

## 19. Tests de servicios (admin)

El panel admin tiene una pantalla ServiceTestScreen (icono llave inglesa
en el dashboard) con tabs para verificar cada servicio/container del stack.

### Arquitectura

- Backend: partfinder/admin_tests.py (router /api/admin/test/*)
- UI admin: lib/features/services/service_test_screen.dart
- API client: metodos test*Service() en lib/core/api_client.dart

Cada endpoint devuelve un formato comun:
  {service, endpoint, status, latency_ms, checks[], warnings[], errors[], response{}}

### Tests implementados

| Tab      | Endpoint                              | Consume cuota  | Requiere patente |
|----------|---------------------------------------|----------------|------------------|
| MTT      | GET /api/admin/test/mtt-service       | No             | Si               |
| BOOSTR   | GET /api/admin/test/boostr-service    | Solo cache miss| Si               |
| DATABASE | GET /api/admin/test/pf-database       | No             | No               |

Pendiente: agregar tab PRT (endpoint /api/admin/test/prt-service).

### Agregar un test nuevo (patron)

1. En admin_tests.py: funcion _test_<nombre>() que devuelve dict con
   el formato comun (usar _empty(service, endpoint) como base).
2. En admin_tests.py: @router.get("/<nombre>") con Depends(_auth_dep())
   que llame a la funcion.
3. En api_client.dart: metodo test<Nombre>Service() que hace
   _getJson("/api/admin/test/<nombre>").
4. En service_test_screen.dart: agregar caso al enum ServiceKind,
   la extension ServiceKindX (label, title, buttonText, note, needsPlate)
   y el switch en _runTest().

---
Ultima actualizacion: 2026-10-04
