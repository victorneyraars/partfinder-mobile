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
