# Pendientes y Roadmap

Ideas priorizadas para futuras versiones. No son urgentes — se ejecutan cuando hay feedback real y capacidad.

---

## 1. Lector de patentes por cámara (ALTA prioridad)

**Objetivo:** el usuario apunta la cámara al vehículo, el sistema detecta la patente en tiempo real, el usuario confirma y se rellena automáticamente el campo.

**Decisiones tomadas:**
- Proveedor: Plate Recognizer (API comercial)
  - 95%+ precision out-of-the-box
  - ~2.500 escaneos gratis/mes
  - ~USD 0.001 por escaneo despues del free tier
- Arquitectura: contenedor `pf_vision` como capa de abstraccion
- Reutilizable: cualquier proyecto del ecosistema puede llamar a `pf_vision`
- Migracion futura: si el volumen crece, migrar a PaddleOCR self-hosted dentro del mismo contenedor (sin cambiar endpoints)

**Razon de la eleccion:**
- Servidor actual (4 cores, 7.6 GB RAM) no tiene GPU real
- PaddleOCR saturaria el CPU en cada escaneo
- Plate Recognizer no consume CPU del servidor
- Tiempo de implementacion: 3-5 dias vs 2-3 semanas

**Plan de ejecucion (cuando arranque):**

Fase 1 - Backend (3-5 dias):
- Crear /opt/partfinder360/vision/main.py (FastAPI)
- Anadir contenedor pf_vision a docker-compose.yml
- Endpoint POST /api/vision/scan -> proxy a Plate Recognizer
- Endpoint GET /api/vision/health
- Cache de resultados por hash de imagen (evita escaneos duplicados)

Fase 2 - Flutter (1 semana):
- Branch feature/plate-scanner en dev
- Pantalla PlateScannerScreen con preview de camara
- Captura cada 500ms, envia al backend
- Overlay con texto detectado + boton "Confirmar"
- Validacion regex: ^[A-Z]{4}[0-9]{2}$ o ^[A-Z]{2}[0-9]{4}$
- Relleno automatico del campo de patente

Fase 3 - Refinamiento (1 semana):
- ML Kit para bounding box on-device (reduce datos enviados)
- Manejo de baja luz, movimiento, angulos extremos
- Tests en dispositivos variados

**Impacto en Play Console:**
- Anadir permiso CAMERA al manifest
- Actualizar Data Safety (acceso a camara)
- Actualizar descripcion mencionando escaneo
- Nueva version con versionCode incrementado

**Decision previa necesaria:** definir cuando arranca segun feedback de testers con v1.0.0

---

## 2. Migracion a flutter_inappwebview (MEDIA prioridad)

**Objetivo:** eliminar el teclado breve (~300ms) que aparece tras resolver el captcha de PRT.

**Contexto:** es deuda tecnica conocida. Los fixes a nivel Android (windowSoftInputMode, MainActivity custom) rompen el WebView. La solucion real es migrar a flutter_inappwebview, que tiene control explicito del IME.

**Estimacion:** 2-3 semanas.

---

## 3. Refactor de main.dart a capas (MEDIA prioridad)

**Objetivo:** partir el main.dart (~7800 lineas) en Domain/Data/Presentation.

**Contexto:** el archivo actual mezcla UI, JS embebido y logica de negocio. Dificulta el mantenimiento y la incorporacion de nuevos devs.

**Estimacion:** 2-3 semanas (proyecto de develop-v2, no de feature branch).

---

## 4. Tests automatizados (MEDIA prioridad)

**Objetivo:** agregar flutter test para flujos criticos.

**Estimacion:** 1-2 semanas.

---

## 5. Firebase Crashlytics (BAJA prioridad)

**Objetivo:** monitoreo de crashes en produccion.

**Estimacion:** 2-3 dias.

---

## 6. Cache por fuente con TTL (BAJA prioridad)

**Objetivo:** TTL independiente por proveedor (PRT 7d, Boostr 30d, SII 15d, MTT 15d, AutoSeguro nunca).

**Contexto:** hoy hay un solo cache por patente. Se puede separar para ahorrar cuota de APIs externas.

**Estimacion:** 3-5 dias.

---

## 7. Auditoria del JS de AutoSeguro para eliminar el WebView (BAJA prioridad)

**Objetivo:** si el sitio de autoseguro.gob.cl tiene un endpoint JSON interno, se puede reemplazar el WebView por una llamada directa al backend.

**Contexto:** requiere investigar el sitio. Si existe endpoint, se elimina el captcha del flujo.

**Estimacion:** 1-2 semanas (incluye investigacion).

---

Ultima actualizacion: 2026-10-02
