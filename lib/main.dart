import 'dart:math';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'providers/vehicle_data_provider.dart';
import 'providers/prt_data_provider.dart';
import 'providers/boostr_data_provider.dart';
import 'providers/mtt_data_provider.dart';
import 'providers/sii_data_provider.dart';
import 'models/vehicle_model.dart';
import 'models/prt_model.dart';
import 'utils/plate_validator.dart';


String _getFreshRandomChileanPlate() {
  const letters = 'BCDFGHJKLPRSTVWXYZ';
  final rand = Random();
  String p = '';
  for (int i = 0; i < 4; i++) {
    p += letters[rand.nextInt(letters.length)];
  }
  int num = 10 + rand.nextInt(90);
  return '$p$num';
}


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const PartFinderApp());
}

class PartFinderApp extends StatelessWidget {
  const PartFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PartFinder 360',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF070A10),
        primaryColor: const Color(0xFF00E5FF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFF3B82F6),
          surface: Color(0xFF0F172A),
        ),
      ),
      home: const LicensePlateDashboard(),
    );
  }
}

class LicensePlateDashboard extends StatefulWidget {
  const LicensePlateDashboard({super.key});

  @override
  State<LicensePlateDashboard> createState() => _LicensePlateDashboardState();
}

class _LicensePlateDashboardState extends State<LicensePlateDashboard>
    with TickerProviderStateMixin {
  String _selectedEngine = 'prt';
  final TextEditingController _plateController = TextEditingController(text: _getFreshRandomChileanPlate());
  final FocusNode _focusNode = FocusNode();

  // ===== ARQUITECTURA DE PROVEEDORES ("cajas") =====
  // Cada caja tiene su propio namespace de caché local (cache_prt_,
  // cache_boostr_, cache_sii_ a futuro) con Negative Caching + TTL.
  late final Map<String, VehicleDataProvider> _providers;
  
  late AnimationController _scannerController;
  late Animation<double> _scannerAnimation;

  // ===== MOTOR NORMATIVO DE PATENTES + UI REACTIVA =====
  PlateValidationResult _plateValidation = const PlateValidationResult(
      valid: false, format: null, formatLabel: 'SIN FORMATO');
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  late AnimationController _bannerController;
  late Animation<double> _bannerFade;
  
  bool _isLoading = false;
  bool _isRefreshingMtt = false;
  bool _isRefreshingSii = false;
  bool _isRefreshingBoostr = false;
  bool _isRefreshingPrt = false;
  Map<String, dynamic>? _siiData;

  // ===== DASHBOARD MULTIPROVEEDOR (consulta simultánea) =====
  Map<String, Map<String, dynamic>>? _dashboard;
  Map<String, bool> _dashboardOk = const {};
  bool _dashboardQueued = false;
  bool _dashboardMode = false;
  // Degradación elegante de PRT (reCAPTCHA Enterprise saturado / timeout).
  String? _lastPrtEvent;
  bool _prtQuotaExceeded = false;
  // Estados formales del pipeline estricto PRT-FIRST:
  //  · _prtSinRegistro: el sistema ministerial respondió SIN historial de
  //    revisiones (homologado/exento) — tile formal, no es fallo de red.
  //  · _prtOmitido: el usuario descartó el modal, pulsó CONTINUAR SIN PRT
  //    o se agotó el timeout humano — tile de verificación pendiente.
  bool _prtSinRegistro = false;
  bool _prtOmitido = false;
  bool _isLoadingSii = false;

  Map<String, dynamic>? _vehicleData;
  String _activeFormat = "AUTO NUEVO (4L+2N)";

  
  Map<String, dynamic>? _boostrStatus;

  Future<void> _fetchBoostrTelemetry() async {
    try {
      final res = await http.get(
        Uri.parse('https://api.studiodigital360.com/api/boostr/status'),
      ).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        setState(() {
          _boostrStatus = json.decode(utf8.decode(res.bodyBytes));
        });
      }
    } catch (_) {}
  }

  @override
  void initState() {
    _fetchBoostrTelemetry();
    super.initState();
    // Registro de proveedores: el Motor PRT recibe el abridor del modal
    // (human-in-the-loop) y Boostr consume la API orquestada del backend.
    _providers = <String, VehicleDataProvider>{
      'prt': PrtDataProvider(openModal: _openPrtModalAndAwait),
      'boostr': BoostrDataProvider(),
      'mtt': MttDataProvider(),
      'sii': SiiDataProvider(),
    };
    _scannerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _scannerAnimation = Tween<double>(begin: -1.0, end: 1.0).animate(
      CurvedAnimation(parent: _scannerController, curve: Curves.easeInOut),
    );

    // Shake normativo de la placa (letra prohibida).
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: -10), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: -10, end: 10), weight: 2),
      TweenSequenceItem(tween: Tween<double>(begin: 10, end: -7), weight: 2),
      TweenSequenceItem(tween: Tween<double>(begin: -7, end: 7), weight: 2),
      TweenSequenceItem(tween: Tween<double>(begin: 7, end: -3), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: -3, end: 0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeController, curve: Curves.linear));

    // Banner explicativo animado (AnimatedSize + FadeTransition).
    _bannerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _bannerFade =
        CurvedAnimation(parent: _bannerController, curve: Curves.easeOut);

    final initPlate = _getFreshRandomChileanPlate();
    _plateController.text = initPlate;
    _evalPlateFormat();
    _plateController.addListener(_evalPlateFormat);
  }

  @override
  void dispose() {
    _scannerController.dispose();
    _shakeController.dispose();
    _bannerController.dispose();
    _plateController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _evalPlateFormat() {
    final result = ChileanPlateEngine.validate(_plateController.text);
    setState(() {
      _plateValidation = result;
      _activeFormat = result.formatLabel;
    });

    if (result.hasError) {
      // Letra prohibida (vocal/M/Q/Ñ en territorio nuevo): shake + haptic
      // + banner explicativo animado.
      HapticFeedback.lightImpact();
      if (!_shakeController.isAnimating) {
        _shakeController.forward(from: 0);
      }
      if (_bannerController.status != AnimationStatus.forward &&
          _bannerController.status != AnimationStatus.completed) {
        _bannerController.forward();
      }
    } else {
      // Sin error normativo: desvanecer el banner.
      if (_bannerController.status == AnimationStatus.completed ||
          _bannerController.status == AnimationStatus.forward) {
        _bannerController.reverse();
      }
    }
  }

  
  Future<void> _fetchSiiTasacion(String? marca, String? modelo, dynamic anio) async {
    if (marca == null || modelo == null || anio == null) return;
    // Normalización robusta del año (int, '2021', '2021-01-01', etc.).
    final anioStr = anio.toString().trim();
    final anioClean = RegExp(r'(\d{4})').firstMatch(anioStr)?.group(1) ?? anioStr;
    setState(() => _isLoadingSii = true);
    try {
      final uri = Uri.parse('https://api.studiodigital360.com/api/tasacion?marca=${Uri.encodeComponent(marca)}&modelo=${Uri.encodeComponent(modelo)}&anio=$anioClean');
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded['status'] == 'SUCCESS') {
          setState(() {
            _siiData = decoded;
            _isLoadingSii = false;
          });
          return;
        }
      }
    } catch (_) {}
    setState(() => _isLoadingSii = false);
  }

  /// CONSULTA MULTIPROVEEDOR — PIPELINE SECUENCIAL ESTRICTO "PRT-FIRST".
  ///
  /// Al pulsar CONSULTAR VEHÍCULO (única entrada; sin tarjetas intermedias):
  ///  A. PASO OBLIGATORIO — PRT PRIMERO:
  ///     1) Si existe historial PRT válido (caché local con revisiones o
  ///        backend vigente) se usa directamente, SIN abrir el modal.
  ///     2) Si NO existe: se abre DE INMEDIATO el modal interactivo P2P de
  ///        PRT y se espera su resolución explícita:
  ///        · Éxito con inspecciones → estado 'ok' (tarjeta PRT + Timeline).
  ///        · "Sin registro" (PRT responde sin historial) → estado
  ///          'sin_registro' (tile formal ministerial).
  ///        · Descartar / CONTINUAR SIN PRT / timeout → estado 'omitido'
  ///          (tile de verificación pendiente con reintento).
  ///  B. SOLO DESPUÉS de resolver el paso A, se disparan EN PARALELO
  ///     Boostr + MTT + SII (endpoint /full) y se renderiza el dashboard
  ///     integrado UNA sola vez.
  Future<void> _searchPlate() async {
    final rawPlate = _plateController.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (rawPlate.length < 5) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFFEF4444),
          content: Text('Por favor ingrese una patente válida de Chile', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    HapticFeedback.lightImpact();

    setState(() {
      _isLoading = true;
      _vehicleData = null;
      _dashboard = null;
      _dashboardOk = const {};
      _dashboardQueued = false;
      _dashboardMode = false;
      _prtQuotaExceeded = false;
      _prtSinRegistro = false;
      _prtOmitido = false;
      _lastPrtEvent = null;
    });
    _scannerController.repeat(reverse: true);

    try {
      // ===== A) PASO OBLIGATORIO: PRT-FIRST =====
      final prtProvider = _providers['prt'];
      String prtStatus = 'pendiente';
      Map<String, dynamic>? prtPayload;
      bool prtQuota = false;

      if (prtProvider != null) {
        // A1) Caché local válida con revisiones (histórico previo).
        final cached = await prtProvider.cache.read(rawPlate);
        if (cached != null && cached['found'] == true && cached['data'] is Map) {
          final map = Map<String, dynamic>.from(cached['data'] as Map);
          if (_prtDataCompleto(map)) {
            prtPayload = map;
            prtStatus = 'ok';
          }
        }

        if (prtStatus != 'ok') {
          try {
            // A2) Caché del backend con política de vigencia; si no hay
            //     registro vigente, el proveedor abre EL MODAL P2P en esta
            //     misma llamada (sin banners ni pasos intermedios).
            final result = await prtProvider.fetch(rawPlate, context: context);
            if (result.found && _prtDataCompleto(result.data)) {
              prtPayload = Map<String, dynamic>.from(result.data);
              prtStatus = 'ok';
              await prtProvider.cache.write(rawPlate, found: true, data: prtPayload, source: 'prt');
            } else if (result.found) {
              // El backend entregó ficha SIN revisiones (falso positivo
              // prohibido): forzar la verificación P2P directa.
              final raw = await _openPrtModalAndAwait(context, rawPlate);
              final evt = _lastPrtEvent;
              _lastPrtEvent = null;
              if (raw != null && _prtDataCompleto(raw)) {
                prtPayload = raw;
                prtStatus = 'ok';
                await prtProvider.cache.write(rawPlate, found: true, data: prtPayload, source: 'prt');
              } else {
                prtStatus = _prtEventToStatus(evt);
                prtQuota = evt == 'RECAPTCHA_QUOTA_EXCEEDED';
              }
            } else {
              // El modal ya se resolvió dentro de fetch(): mapear su evento.
              final evt = _lastPrtEvent;
              _lastPrtEvent = null;
              prtStatus = _prtEventToStatus(evt);
              prtQuota = evt == 'RECAPTCHA_QUOTA_EXCEEDED';
            }
          } catch (e) {
            debugPrint('[PRT-FIRST] $e');
            prtStatus = 'omitido';
          }
        }
      } else {
        prtStatus = 'omitido';
      }

      // A3) Persistir en el backend el historial recién extraído (async).
      if (prtStatus == 'ok' && prtPayload != null) {
        _persistPrtToBackend(rawPlate, prtPayload);
      }

      // ===== B) FUENTES SECUNDARIAS EN PARALELO (Boostr + MTT + SII) =====
      final full = await _fetchFullDashboard(rawPlate);

      final dash = <String, Map<String, dynamic>>{};
      final ok = <String, bool>{};

      void add(String key, dynamic block) {
        if (block is! Map) {
          ok[key] = false;
          return;
        }
        final status = (block['status'] ?? 'error').toString();
        final data = (block['data'] is Map)
            ? Map<String, dynamic>.from(block['data'] as Map)
            : <String, dynamic>{};
        dash[key] = data;
        ok[key] = status == 'ok';
      }

      if (full != null) {
        add('boostr', full['boostr']);
        add('mtt', full['mtt']);
        add('sii', full['sii']);
      } else {
        ok['boostr'] = false;
        ok['mtt'] = false;
        ok['sii'] = false;
      }

      // PRT: SOLO manda el resultado del pipeline PRT-First (paso A).
      if (prtStatus == 'ok' && prtPayload != null) {
        dash['prt'] = prtPayload;
        ok['prt'] = true;
      } else {
        dash['prt'] = const {};
        ok['prt'] = false;
      }

      Map<String, dynamic>? first;
      for (final k in const ['prt', 'boostr', 'mtt', 'sii']) {
        if (ok[k] == true) {
          first = dash[k];
          break;
        }
      }

      setState(() {
        _dashboard = dash;
        _dashboardOk = ok;
        _dashboardQueued = full != null &&
            full['boostr'] is Map &&
            (((full['boostr'] as Map)['status'] == 'queued') ||
                ((full['boostr'] as Map)['status'] == 'exhausted'));
        _prtQuotaExceeded = prtQuota;
        _prtSinRegistro = prtStatus == 'sin_registro';
        _prtOmitido = prtStatus == 'omitido';
        _dashboardMode = true;
        _vehicleData = first;
      });

      if (first != null) {
        final firstD = first;
        _fetchSiiTasacion(
          (firstD['marca'] ?? firstD['make'])?.toString(),
          (firstD['modelo'] ?? firstD['model'])?.toString(),
          firstD['anio'] ?? firstD['year'],
        );
      }
      _fetchBoostrTelemetry();
      final snack = switch (prtStatus) {
        'ok' => 'Auditoría completa para $rawPlate: PRT verificado + Padrón, MTT y SII',
        'sin_registro' => 'PRT sin revisiones registradas para $rawPlate — fuentes secundarias cargadas',
        _ => 'PRT omitido para $rawPlate — reintenta la verificación desde la tarjeta',
      };
      _showSnack(snack);
    } catch (e) {
      _showSnack('Error de conexión con el servidor ($e)');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _scannerController.stop();
        _scannerController.reset();
        HapticFeedback.mediumImpact();
      }
    }
  }

  /// Mapea el evento del modal PRT al estado formal del pipeline PRT-First.
  /// 'sin_registro' solo cuando el sistema ministerial respondió sin
  /// historial; descartes, timeouts y cuotas degradan a 'omitido'.
  String _prtEventToStatus(String? evt) {
    switch (evt) {
      case 'PRT_SIN_REGISTRO':
        return 'sin_registro';
      case 'RECAPTCHA_TIMEOUT':
      case 'RECAPTCHA_QUOTA_EXCEEDED':
      default:
        return 'omitido';
    }
  }

  /// Persiste en el backend el historial PRT recién extraído del modal
  /// (fire-and-forget: un fallo aquí no bloquea el dashboard).
  void _persistPrtToBackend(String plate, Map<String, dynamic> data) {
    unawaited(() async {
      try {
        final res = await http
            .post(
              Uri.parse('https://api.studiodigital360.com/api/vehicle/cache'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'plate': plate, 'data': data}),
            )
            .timeout(const Duration(seconds: 8));
        debugPrint('[PRT-FIRST] persistencia backend: ${res.statusCode}');
      } catch (e) {
        debugPrint('[PRT-FIRST] persistencia backend error: $e');
      }
    }());
  }


  /// PRT "completo": tiene historial de revisiones o estado/vigencia reales.
  /// Evita el falso positivo "Sin registro" del fallback sin inspecciones.
  bool _prtDataCompleto(Map<String, dynamic> d) {
    final hist = d['historial_rt'];
    final hasHist = hist is List && hist.isNotEmpty;
    final hasEstado = (d['rt_estado']?.toString().trim().isNotEmpty ?? false) ||
        (d['rt_vencimiento']?.toString().trim().isNotEmpty ?? false);
    return hasHist || hasEstado;
  }

  /// Descarga el dashboard agregado (/full) para Boostr/MTT/SII en paralelo.
  Future<Map<String, dynamic>?> _fetchFullDashboard(String rawPlate) async {
    try {
      final res = await http
          .get(Uri.parse('https://api.studiodigital360.com/api/patente/$rawPlate/full'))
          .timeout(const Duration(seconds: 35));
      if (res.statusCode == 200) {
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[DASH-FULL] $e');
    }
    return null;
  }

  /// Actualización en segundo plano de las fuentes (tras renderizar desde
  /// caché PRT): completa el dashboard sin tocar la tarjeta PRT de caché.
  Future<void> _refreshDashboardSources(String rawPlate) async {
    final full = await _fetchFullDashboard(rawPlate);
    if (!mounted || full == null || _dashboard == null) return;
    setState(() {
      void add(String key, dynamic block) {
        if (block is! Map) {
          _dashboardOk[key] = false;
          return;
        }
        final status = (block['status'] ?? 'error').toString();
        final data = (block['data'] is Map)
            ? Map<String, dynamic>.from(block['data'] as Map)
            : <String, dynamic>{};
        if (status == 'ok') {
          _dashboard![key] = data;
          _dashboardOk[key] = true;
        }
      }

      add('boostr', full['boostr']);
      add('mtt', full['mtt']);
      add('sii', full['sii']);
      if (full['prt'] is Map) {
        final prtBlock = full['prt'] as Map;
        final prtStatus = (prtBlock['status'] ?? 'error').toString();
        final prtPayload = (prtBlock['data'] is Map)
            ? Map<String, dynamic>.from(prtBlock['data'] as Map)
            : <String, dynamic>{};
        // Nunca reemplazar la caché local PRT por un fallback sin revisiones.
        if (prtStatus == 'ok' && _prtDataCompleto(prtPayload)) {
          _dashboard!['prt'] = prtPayload;
          _dashboardOk['prt'] = true;
        }
      }
      _dashboardQueued = full['boostr'] is Map &&
          (((full['boostr'] as Map)['status'] == 'queued') ||
              ((full['boostr'] as Map)['status'] == 'exhausted'));
    });
  }


Future<void> _searchPlateLegacy({bool forceNetwork = false, String? plateOverride}) async {
    final rawPlate = (plateOverride ?? _plateController.text)
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toUpperCase();
    if (rawPlate.length < 5) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFFEF4444),
          content: Text('Por favor ingrese una patente válida de Chile', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    HapticFeedback.lightImpact();

    setState(() {
      _isLoading = true;
      _vehicleData = null;
    });
    _scannerController.repeat(reverse: true);

    try {
      // ===== ARQUITECTURA DE PROVEEDORES: selector de caja =====
      final provider = _providers[_selectedEngine] ?? _providers['prt']!;

      // 1) Caché local aislada del proveedor (positive + negative caching).
      //    Con forceNetwork (botón "Refrescar Caché") se omite la caché
      //    local y se consulta directamente la fuente.
      if (!forceNetwork) {
        final cached = await provider.cache.read(rawPlate);
        if (cached != null) {
          if (cached['found'] == true) {
          final v = Map<String, dynamic>.from(cached['data'] as Map? ?? const {});
          v['data_source'] = 'CACHE_LOCAL_${provider.id}';
          v['patente'] = v['patente'] ?? rawPlate;
          setState(() {
            _vehicleData = v;
          });
          _fetchSiiTasacion(
            (v['marca'] ?? v['make'])?.toString(),
            (v['modelo'] ?? v['model'])?.toString(),
            v['anio'] ?? v['year'],
          );
          _fetchBoostrTelemetry();
          _showSnack('Vehículo $rawPlate cargado desde caché local (${provider.id})');
          return;
        } else {
          // Negative cache vigente: no repetir la consulta ni gastar cuota.
          _showSnack('Patente no encontrada (caché reciente de ${provider.id}). Intenta más tarde.');
          return;
        }
        }
      }

      // 2) Consulta fresca al proveedor seleccionado.
      final result = await provider.fetch(rawPlate, context: context);

      if (result.found) {
        final v = Map<String, dynamic>.from(result.data);
        v['data_source'] = result.source == 'boostr'
            ? 'BOOSTR_API'
            : (result.source == 'mtt'
                ? 'MTT_REGISTRO'
                : (result.source == 'sii' ? 'SII_TASACION' : 'PRT_SCRAPING'));
        v['patente'] = v['patente'] ?? rawPlate;

        // Persistir en la caché local del proveedor (payload completo,
        // campos vacíos incluidos). MTT y SII ya persistieron dentro de su
        // fetch() (TTL dinámico 30/60d y 180d respectivamente), por lo que
        // no se reescriben aquí.
        if (result.source != 'mtt' && result.source != 'sii') {
          await provider.cache.write(rawPlate, found: true, data: v, source: result.source);
        }

        setState(() {
          _vehicleData = v;
        });
        final sMarca = (v['marca'] ?? v['make'])?.toString();
        final sModelo = (v['modelo'] ?? v['model'])?.toString();
        final sAnio = v['anio'] ?? v['year'];
        _fetchSiiTasacion(sMarca, sModelo, sAnio);

        // Persistencia en el backend (PRT recién extraído). Los datos de
        // Boostr y MTT ya fueron persistidos por el endpoint orquestado.
        if (result.source == 'prt') {
          try {
            final res = await http.post(
              Uri.parse('https://api.studiodigital360.com/api/vehicle/cache'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'plate': rawPlate, 'data': v}),
            );
            if (res.statusCode == 200) {
              _showSnack('¡Vehículo $rawPlate sincronizado en la base de datos!');
            }
          } catch (e) {
            debugPrint('Error persistiendo en backend: $e');
          }
        } else if (result.source == 'boostr' && !forceNetwork) {
          _showSnack('Vehículo $rawPlate recuperado vía Boostr (RT no disponible)');
        } else if (result.source == 'sii') {
          // El backend ya persistió la tasación (merge en vehicle_cache)
          // dentro del motor local: solo informar al usuario.
          _showSnack(v['exact_match'] == true
              ? 'Tasación fiscal oficial de $rawPlate obtenida (tablas SII)'
              : 'Tasación con múltiples versiones: selecciona la tuya en la tarjeta');
        } else if (!forceNetwork) {
          _showSnack(v['isPublicTransport'] == true
              ? 'Vehículo $rawPlate inscrito como transporte público/escolar (MTT)'
              : 'Vehículo $rawPlate particular: sin registro en el RNSTP (MTT)');
        }
        _fetchBoostrTelemetry();
        return;
      }

      // 3) Sin datos: Negative Caching local + aviso.
      await provider.cache.write(rawPlate,
          found: false, data: const {}, source: result.source, status: result.status);
      _showSnack(result.status == 'not_found'
          ? 'Patente no encontrada en el registro oficial'
          : 'Sin datos de vehículo para $rawPlate');
    } on ProviderException catch (e) {
      // Excepción controlada del proveedor (cuota 429, red, 5xx): permite
      // decidir fallback o informar al usuario sin romper el flujo.
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Error de conexión con el servidor ($e)');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _scannerController.stop();
        _scannerController.reset();
        HapticFeedback.mediumImpact();
      }
    }
  }

  /// Abre el modal PRT (human-in-the-loop) y devuelve el payload crudo del
  /// pop, conservando el aviso/refoco del flujo de no-encontrada.
  Future<Map<String, dynamic>?> _openPrtModalAndAwait(BuildContext modalContext, String plate) async {
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => PrtVerificationScreen(
          targetPlate: plate,
          onErrorNotFound: () {
            try { _focusNode.requestFocus(); } catch (_) {}
            if (mounted) {
              ScaffoldMessenger.of(this.context).showSnackBar(
                const SnackBar(
                  backgroundColor: Color(0xFF1E293B),
                  content: Text(
                    'Patente no encontrada en PRT. Verifica e intenta nuevamente',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  duration: Duration(seconds: 4),
                ),
              );
            }
          },
        ),
      ),
    );
    if (result is Map) {
      final evt = result['__prtEvent'];
      if (evt is String) _lastPrtEvent = evt;
      return Map<String, dynamic>.from(result);
    }
    if (result is Map<String, dynamic>) return result;
    return null;
  }

  
  // ==========================================
  // MODAL INTERACTIVO PRT (HUMAN-IN-THE-LOOP)
  // ==========================================
  void _openPrtVerificationScreen(String targetPlate) {
    // Cerrar el teclado ANTES de abrir el modal: al retornar (éxito o cierre)
    // no debe quedar foco residual en el TextField que reabra el IME.
    try { _focusNode.unfocus(); } catch (e) {}
    try {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (e) {}
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PrtVerificationScreen(
          targetPlate: targetPlate,
          onErrorNotFound: () {
            // Devolver el foco al campo de patente de la pantalla principal.
            try { _focusNode.requestFocus(); } catch (e) {}
            // Aviso estilizado (fondo oscuro, texto claro).
            if (mounted) {
              ScaffoldMessenger.of(this.context).showSnackBar(
                const SnackBar(
                  backgroundColor: Color(0xFF1E293B),
                  content: Text(
                    'Patente no encontrada en PRT. Verifica e intenta nuevamente',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  duration: Duration(seconds: 4),
                ),
              );
            }
          },
          onVehicleSaved: (scraped) async {
            // Consulta EXITOSA: NUNCA pedir foco al input de patente en esta
            // rama. Solo onErrorNotFound refocaliza (para reintentar).
            setState(() {
              _vehicleData = scraped;
            });

            // 1. Guardar en PostgreSQL via backend (endpoint de ingesta directa).
            //    Si el dato vino del FALLBACK BOOSTR, el backend ya lo
            //    persistió (fuente: 'Boostr'): no re-persistir para no
            //    sobrescribir la fuente.
            final plateClean = _plateController.text.trim().toUpperCase();
            final esBoostr = scraped['fuente'] == 'Boostr';
            if (!esBoostr) {
              try {
                final cacheUri = Uri.parse("https://api.studiodigital360.com/api/vehicle/cache");
                final res = await http.post(
                  cacheUri,
                  headers: {"Content-Type": "application/json"},
                  body: jsonEncode({
                    "plate": plateClean,
                    "data": scraped,
                  }),
                );
                if (res.statusCode == 200) {
                  _showSnack("¡Vehículo $plateClean sincronizado en la base de datos!");
                }
              } catch (e) {
                debugPrint("Error persistiendo en backend: $e");
              }
            } else {
              _showSnack("Vehículo $plateClean recuperado vía Boostr (RT no disponible)");
            }
            _fetchBoostrTelemetry();

            // 2. Consultar tasacion oficial SII
            final sMarca = scraped["marca"] ?? scraped["make"];
            final sModelo = scraped["modelo"] ?? scraped["model"];
            final sAnio = scraped["anio"] ?? scraped["year"];
            _fetchSiiTasacion(sMarca?.toString(), sModelo?.toString(), sAnio);
          },
        ),
      ),
    );
  }

  void _openPartsMarketplace() {
    // Claves normalizadas: funciona igual con PRT (marca/modelo) o con
    // Boostr (make/model). Sin fallos silenciosos.
    final make = ((_vehicleData?['marca'] ?? _vehicleData?['make'])?.toString() ?? '')
        .trim()
        .toUpperCase();
    final model = ((_vehicleData?['modelo'] ?? _vehicleData?['model'])?.toString() ?? '')
        .trim()
        .toUpperCase();
    final vehicleTitle = ('$make $model').trim();

    if (vehicleTitle.isEmpty) {
      _showSnack('No hay datos de vehículo disponibles para abrir el catálogo');
      return;
    }

    HapticFeedback.mediumImpact();

    // Identificadores de Afiliado (reemplazar cuando tengas los tags oficiales)
    const String meliAffiliateTag = ''; 
    const String aliAffiliateTag = '';

    final categories = [
      {
        'title': 'Filtros y Mantenimiento',
        'subtitle': 'Aceite, aire motor y cabina polen',
        'icon': Icons.filter_alt_rounded,
        'meliQuery': 'filtro aceite $vehicleTitle',
        'aliQuery': 'oil filter $vehicleTitle',
      },
      {
        'title': 'Frenos y Seguridad',
        'subtitle': 'Pastillas delanteras, traseras y discos',
        'icon': Icons.disc_full_rounded,
        'meliQuery': 'pastillas freno $vehicleTitle',
        'aliQuery': 'brake pads $vehicleTitle',
      },
      {
        'title': 'Sensores y Escáner OBD2',
        'subtitle': 'Oxígeno, MAF, ABS y diagnóstico',
        'icon': Icons.memory_rounded,
        'meliQuery': 'sensor oxigeno $vehicleTitle',
        'aliQuery': 'sensor $vehicleTitle obd2',
      },
      {
        'title': 'Llaves con Chip y Tecomandos',
        'subtitle': 'Carcasas, telemandos y chips vírgenes',
        'icon': Icons.key_rounded,
        'meliQuery': 'llave chip $vehicleTitle',
        'aliQuery': 'car key remote $vehicleTitle',
      },
      {
        'title': 'Pantallas Android y Car Play',
        'subtitle': 'Radios específicas y cámaras de retroceso',
        'icon': Icons.tv_rounded,
        'meliQuery': 'radio android $vehicleTitle',
        'aliQuery': 'android radio carplay $vehicleTitle',
      },
      {
        'title': 'Amortiguadores y Tren Delantero',
        'subtitle': 'Suspensión, bujes y terminales de dirección',
        'icon': Icons.swap_vertical_circle_rounded,
        'meliQuery': 'amortiguadores $vehicleTitle',
        'aliQuery': 'shock absorber $vehicleTitle',
      },
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        side: BorderSide(color: Color(0xFF00E5FF), width: 1.2),
      ),
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF334155),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(Icons.storefront_rounded, color: Color(0xFF00E5FF), size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'REPUESTOS: ' + vehicleTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Elige el repuesto y la plataforma de compra:',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView.separated(
                  itemCount: categories.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final cat = categories[i];
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00E5FF).withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(cat['icon'] as IconData, color: const Color(0xFF00E5FF), size: 20),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      cat['title'] as String,
                                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                    ),
                                    Text(
                                      cat['subtitle'] as String,
                                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              // Botón Mercado Libre Chile
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    Navigator.pop(ctx);
                                    final q = Uri.encodeComponent(cat['meliQuery'] as String);
                                    final url = 'https://api.studiodigital360.com/api/r/meli?q=' + q;
                                    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFE600).withOpacity(0.12),
                                      border: Border.all(color: const Color(0xFFFFE600).withOpacity(0.5)),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text('🇨🇱 MercadoLibre', style: TextStyle(color: Color(0xFFFFE600), fontSize: 11, fontWeight: FontWeight.w900)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Botón AliExpress
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    Navigator.pop(ctx);
                                    final q = Uri.encodeComponent(cat['aliQuery'] as String);
                                    var url = 'https://es.aliexpress.com/wholesale?SearchText=' + q;
                                    if (aliAffiliateTag.isNotEmpty) {
                                      url += '&aff_platform=' + aliAffiliateTag;
                                    }
                                    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF4747).withOpacity(0.12),
                                      border: Border.all(color: const Color(0xFFFF4747).withOpacity(0.5)),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text('📦 AliExpress', style: TextStyle(color: Color(0xFFFF6B6B), fontSize: 11, fontWeight: FontWeight.w900)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(backgroundColor: const Color(0xFFEF4444), content: Text(message)),
    );
  }

  void _mockFallbackData(String plate) {
    _vehicleData = {
      "patente": plate,
      "marca": "TOYOTA",
      "modelo": "RAV4 HYBRID LIMITED 4WD AUTOMÁTICO",
      "anio": "2023",
      "tipo_vehiculo": "STATION WAGON / SUV",
      "color": "GRIS GRAFITO METALIZADO",
      "configuracion_motor": "2.5L DOHC 16V 4-CILINDROS VVT-iE",
      "numero_motor": "A25A-FXS-9182740",
      "traccion": "ALL WHEEL DRIVE (AWD-i)",
      "combustible": "HÍBRIDO / BENCINA",
      "cilindrada": "2.487 CC",
      "vin": "JTMDJREV9PD018274",
      "repuestos_compatibles": "48 repuestos verificados en catálogo",
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.4),
            radius: 1.2,
            colors: [
              Color(0xFF131D31),
              Color(0xFF070A10),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildHeader(),
                const SizedBox(height: 24),
                // Placa con shake normativo (letra prohibida) + banner
                // explicativo animado (AnimatedSize + FadeTransition).
                AnimatedBuilder(
                  animation: _shakeAnimation,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(_shakeAnimation.value, 0),
                    child: child,
                  ),
                  child: _buildPhysicalPlate(),
                ),
                _buildPlateErrorBanner(),
                const SizedBox(height: 12),
                _buildFormatPills(),
                const SizedBox(height: 24),
                _buildScanButton(),
                const SizedBox(height: 28),
                if (_dashboardMode && _dashboard != null)
                  _buildDashboard()
                else if (_vehicleData != null)
                  (_isMttResult
                          ? _buildMttCard()
                          : (_isSiiResult
                              ? _buildSiiCard()
                              : (_isBoostrResult
                                  ? _buildBoostrCard()
                                  : (_isPrtResult
                                      ? _buildPrtCard()
                                      : _buildVehicleSpecsCard())))),
            _buildSiiEstimateCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withOpacity(0.1),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
              ),
              child: const Icon(Icons.speed_rounded, color: Color(0xFF00E5FF), size: 28),
            ),
            const SizedBox(width: 12),
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Color(0xFFFFFFFF), Color(0xFF00E5FF)],
              ).createShader(bounds),
              child: const Text(
                'PARTFINDER 360',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'RED AUTOMOTRIZ INTELIGENTE · CHILE',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.5,
            color: Color(0xFF64748B),
          ),
        ),
      ],
    );
  }


  
  Widget _buildPhysicalPlate() {

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 360),
      height: 140,
      decoration: BoxDecoration(
        color: const Color(0xFFECEFF1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B), width: 6),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withOpacity(_isLoading ? 0.35 : 0.1),
            blurRadius: _isLoading ? 24 : 12,
            spreadRadius: _isLoading ? 2 : 0,
          ),
          const BoxShadow(
            color: Colors.black54,
            blurRadius: 10,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          _buildRivet(top: 8, left: 10),
          _buildRivet(top: 8, right: 10),
          _buildRivet(bottom: 8, left: 10),
          _buildRivet(bottom: 8, right: 10),

          Positioned(
            top: 10,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 12,
                  height: 9,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.blue, Colors.white, Colors.red],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  'CHILE',
                  style: TextStyle(
                    color: Color(0xFF1E293B),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                controller: _plateController,
                focusNode: _focusNode,
                autofocus: false,
                textAlign: TextAlign.center,
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                  ChileanPlateFormatter(),
                ],
                style: const TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 8,
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  counterText: "",
                  border: InputBorder.none,
                  hintText: 'ABCD12',
                  hintStyle: TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 8,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),

          if (_isLoading)
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _scannerAnimation,
                builder: (context, child) {
                  return Align(
                    alignment: Alignment(_scannerAnimation.value, 0.0),
                    child: Container(
                      width: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E5FF),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00E5FF).withOpacity(0.9),
                            blurRadius: 12,
                            spreadRadius: 3,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRivet({double? top, double? bottom, double? left, double? right}) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: const Color(0xFF94A3B8),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF475569), width: 1.5),
        ),
      ),
    );
  }

  /// Banner explicativo animado (AnimatedSize + FadeTransition) que aparece
  /// bajo la placa cuando se detecta un error normativo (vocal / M / Q / Ñ).
  Widget _buildPlateErrorBanner() {
    final show = _plateValidation.hasError;
    final message = show ? _plateValidation.message : '';
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: show
          ? FadeTransition(
              opacity: _bannerFade,
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxWidth: 360),
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFF59E0B).withOpacity(0.5),
                    width: 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        color: Color(0xFFF59E0B), size: 15),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        message,
                        softWrap: true,
                        style: const TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontSize: 11.5,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _buildFormatPills() {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        _pill("AUTO NUEVO (4L+2N)", _activeFormat.contains("NUEVO")),
        _pill("CLÁSICO (2L+4N)", _activeFormat.contains("CLÁSICO")),
        _pill("MOTO", _activeFormat.contains("MOTO")),
      ],
    );
  }

  Widget _pill(String label, bool isSelected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF00E5FF).withOpacity(0.15) : const Color(0xFF1E293B).withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF334155),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF94A3B8),
          fontSize: 10,
          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildScanButton() {
    // Motor normativo: si la patente no valida (formato incompleto o letra
    // prohibida), el botón queda bloqueado para no consumir cuota de API.
    final bloqueado = !_plateValidation.valid;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: (_isLoading || !bloqueado) ? 1.0 : 0.45,
      child: Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 360),
      height: 54,
      child: ElevatedButton(
        onPressed: (_isLoading || bloqueado) ? null : _searchPlate,
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 8,
          shadowColor: const Color(0xFF00E5FF).withOpacity(0.4),
        ),
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF00E5FF), Color(0xFF2563EB)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Container(
            alignment: Alignment.center,
            child: _isLoading
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      ),
                      SizedBox(width: 12),
                      Text(
                        'ESCANEANDO TELEMETRÍA...',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: Colors.white),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.radar_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _plateValidation.valid
                              ? 'CONSULTAR VEHÍCULO'
                              : 'FORMATO INVÁLIDO — REVISA LA PLACA',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
      ),
    );
  }

  Future<void> _openPdfReport() async {
    // Patente normalizada desde la ficha o desde el input (PRT y Boostr).
    final rawPlate = ((_vehicleData?['patente'] ?? _vehicleData?['plate'] ?? _plateController.text)
            .toString()
            .split('-')
            .first
            .trim()
            .toUpperCase());
    if (rawPlate.isEmpty) {
      _showSnack('No hay patente disponible para generar el informe');
      return;
    }

    final uri = Uri.parse('https://api.studiodigital360.com/api/patente/$rawPlate/pdf');
    try {
      HapticFeedback.mediumImpact();

      // Descarga binaria del PDF (NO esperar JSON ni abortar por
      // application/pdf): se leen los bytes y se escriben en el
      // almacenamiento local antes de abrir el visor.
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        _showSnack('No se pudo generar el informe (HTTP ${res.statusCode})');
        debugPrint('[PRT-PDF] error HTTP ${res.statusCode} para $rawPlate');
        return;
      }
      if (res.bodyBytes.isEmpty) {
        _showSnack('El informe llegó vacío. Intenta nuevamente.');
        return;
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/informe_${rawPlate}.pdf');
      await file.writeAsBytes(res.bodyBytes, flush: true);
      debugPrint('[PRT-PDF] guardado: ${file.path} (${res.bodyBytes.length} bytes)');

      // Visor local del sistema (open_filex); si falla, navegador externo.
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done) {
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!launched) {
          _showSnack('No se pudo abrir el visor del PDF');
        }
      }
    } catch (e) {
      _showSnack('Error al intentar abrir el PDF ($e)');
    }
  }

  
  Widget _buildSiiEstimateCard() {
    // 1) Estado IDLE (sin consulta activa): no pintar absolutamente nada.
    if (_vehicleData == null && _dashboard == null) {
      return const SizedBox.shrink();
    }
    // 2) Consulta en curso: no mostrar avisos prematuros.
    if (_isLoading) {
      return const SizedBox.shrink();
    }
    // 3) Limpieza de banner residual: si el dashboard SII ya entregó 1 o
    //    más variantes válidas (p. ej. las 8 del Morning 2022), ocultar por
    //    completo la tarjeta de "no disponible".
    if (_dashboardMode && _dashboard != null) {
      final siiVersiones = _dashboard!['sii']?['versiones'];
      if (siiVersiones is List && siiVersiones.isNotEmpty) {
        return const SizedBox.shrink();
      }
    }
    final sii = _vehicleData?["sii"] ??
        _siiData?["summary"] ??
        (_siiData?["data"] is Map ? _siiData?["data"]?["summary"] : null);
    if (sii == null && !_isLoadingSii) {
      // Estado de no disponibilidad: la tarjeta nunca desaparece en
      // silencio (PRT o Boostr), muestra el aviso correspondiente.
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF64748B).withOpacity(0.35)),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline_rounded, color: Color(0xFF94A3B8), size: 18),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Tasación fiscal SII no disponible para este modelo',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    if (_isLoadingSii) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.2)),
        ),
        child: const Row(
          children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8))),
            SizedBox(width: 12),
            Text("Sincronizando tasación fiscal SII 2026...", style: TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      );
    }

    final tMin = sii?["tasacion_min"];
    final tMax = sii?["tasacion_max"];
    final pMin = sii?["permiso_min"];
    final pMax = sii?["permiso_max"];
    final codSii = _vehicleData?["sii"]?["codigo_sii"] ?? "HOMOLOGADO";
    final traccion = _vehicleData?["sii"]?["traccion"] ?? _vehicleData?["traccion"];
    final transmision = _vehicleData?["sii"]?["transmision"] ?? _vehicleData?["transmision"];

    String fmt(dynamic n) {
      if (n == null) return "N/D";
      final s = n.toString();
      return r"$" + s.replaceAllMapped(RegExp(r"(\d{1,3})(?=(\d{3})+(?!\d))"), (m) => "${m[1]}.");
    }

    final tasacionStr = (tMin != null && tMax != null && tMin != tMax) ? "${fmt(tMin)} - ${fmt(tMax)}" : fmt(tMin ?? tMax);
    final permisoStr = (pMin != null && pMax != null && pMin != pMax) ? "${fmt(pMin)} - ${fmt(pMax)}" : fmt(pMin ?? pMax);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.35)),
        boxShadow: [
          BoxShadow(color: const Color(0xFF38BDF8).withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0284C7).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.4)),
                ),
                child: const Text("SII TRIBUTARIO 2026", style: TextStyle(color: Color(0xFF38BDF8), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
              ),
              const Spacer(),
              Text("CÓD: $codSii", style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: "monospace")),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Avalúo Fiscal Oficial", style: TextStyle(color: Colors.white54, fontSize: 11)),
                    const SizedBox(height: 3),
                    Text(tasacionStr, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              Container(width: 1, height: 32, color: Colors.white12),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Permiso Circulación", style: TextStyle(color: Colors.white54, fontSize: 11)),
                    const SizedBox(height: 3),
                    Text(permisoStr, style: const TextStyle(color: Color(0xFF4ADE80), fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
          if (traccion != null || transmision != null) ...[
            const SizedBox(height: 12),
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 10),
            Row(
              children: [
                if (transmision != null)
                  Expanded(
                    child: Row(
                      children: [
                        const Icon(Icons.settings_suggest_rounded, size: 14, color: Color(0xFF38BDF8)),
                        const SizedBox(width: 6),
                        Flexible(child: Text("$transmision", style: const TextStyle(color: Colors.white70, fontSize: 11), overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                if (traccion != null)
                  Expanded(
                    child: Row(
                      children: [
                        const Icon(Icons.all_inclusive_rounded, size: 14, color: Color(0xFF38BDF8)),
                        const SizedBox(width: 6),
                        Flexible(child: Text("$traccion", style: const TextStyle(color: Colors.white70, fontSize: 11), overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVehicleSpecsCard() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withOpacity(0.08),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.directions_car_filled_rounded, color: Color(0xFF00E5FF), size: 22),
                    const SizedBox(width: 8),
                    Text(
                      _vehicleData!['marca']?.toString().toUpperCase() ?? '',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF00E5FF), letterSpacing: 1.2),
                    ),
                  ],
                ),
              ),
              Builder(
                          builder: (context) {
                            final src = _vehicleData?['data_source']?.toString().toUpperCase() ?? '';
                            Color bColor = const Color(0xFF10B981);
                            IconData bIcon = Icons.verified_user;
                            String bText = 'PRT CHILE';

                            if (src.contains('CACHE')) {
                              bColor = const Color(0xFFA855F7);
                              bIcon = Icons.save;
                              bText = 'CACHÉ LOCAL';
                            } else if (src.contains('BOOSTR')) {
                              bColor = const Color(0xFF38BDF8);
                              bIcon = Icons.bolt;
                              bText = 'Datos vía Boostr API';
                            }

                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: bColor.withOpacity(0.18),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: bColor, width: 0.9),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(bIcon, color: bColor, size: 12),
                                  const SizedBox(width: 4),
                                  Text(
                                    bText,
                                    style: TextStyle(
                                      color: bColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ],
          ),
          if (_vehicleData!['modelo'] != null) ...[
            const SizedBox(height: 6),
            Text(
              _vehicleData!['modelo'].toString().toUpperCase(),
              softWrap: true,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Colors.white, height: 1.2),
            ),
          ],
          const Divider(color: Color(0xFF334155), height: 22),
          ..._vehicleData!.entries.where((e) {
            final k = e.key.toLowerCase();
            return k != 'marca' && k != 'modelo' && k != 'repuestos_compatibles' && k != 'historial_rt' && !k.startsWith('rt_');
          }).map((e) {
            final label = e.key.replaceAll('_', ' ').toUpperCase();
            final isHighlight = e.key.toLowerCase() == 'patente';
            return _specRow(label, e.value?.toString() ?? '---', isHighlight: isHighlight);
          }),
          const SizedBox(height: 16),
            // SECCIÓN DE HISTORIAL COMPLETO DE REVISIÓN TÉCNICA
            if (_vehicleData!['historial_rt'] != null &&
                (_vehicleData!['historial_rt'] is List) &&
                (_vehicleData!['historial_rt'] as List).isNotEmpty) ...[
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history, color: Color(0xFF38BDF8), size: 22),
                  title: Text(
                    'Historial de Revisiones (${(_vehicleData!['historial_rt'] as List).length} registros)',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF38BDF8),
                      letterSpacing: 0.5,
                    ),
                  ),
                  children: (_vehicleData!['historial_rt'] as List).map<Widget>((item) {
                    final rt = item as Map<String, dynamic>;
                    final rawEstado = (rt['estado'] ?? '').toString().toUpperCase();
                          final bool isApproved = rawEstado.contains('APROB');
                          final bool isRechazado = rawEstado.contains('RECHAZ');
                          final cert = (rt['certificado'] ?? '').toString().toLowerCase();
                          
                          String displayEstado = rawEstado;
                          if (isRechazado) {
                            if (cert.contains('(g)') || cert.contains('gases')) {
                              displayEstado = 'RECHAZADO: GASES';
                            } else {
                              displayEstado = 'RECHAZADO: MECÁNICA';
                            }
                          }
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isApproved ? const Color(0xFF10B981).withOpacity(0.35) : Colors.redAccent.withOpacity(0.35),
                          width: 0.8,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Control: ' + (rt['fecha']?.toString() ?? '-'),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isApproved ? const Color(0xFF10B981).withOpacity(0.2) : Colors.redAccent.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  displayEstado,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isApproved ? const Color(0xFF10B981) : Colors.redAccent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Vence: ' + (rt['vencimiento']?.toString() ?? '-'),
                                style: const TextStyle(fontSize: 12, color: Color(0xFF38BDF8), fontWeight: FontWeight.w600),
                              ),
                              Text(
                                rt['cod_planta']?.toString() ?? '',
                                style: const TextStyle(fontSize: 11, color: Colors.white38),
                              ),
                            ],
                          ),
                          if (rt['planta'] != null && rt['planta'].toString().isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              rt['planta'].toString(),
                              style: const TextStyle(fontSize: 11, color: Colors.white70),
                            ),
                          ],
                          if (rt['certificado'] != null && rt['certificado'].toString().isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Cert: ' + rt['certificado'].toString(),
                              style: const TextStyle(fontSize: 10, color: Colors.white38),
                            ),
                          ],
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),
            ],
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _openPdfReport,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF).withOpacity(0.15),
                foregroundColor: const Color(0xFF00E5FF),
                side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              icon: const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFF00E5FF), size: 22),
              label: const Text(
                'DESCARGAR INFORME OFICIAL (PDF)',
                style: TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openPartsMarketplace,
              borderRadius: BorderRadius.circular(12),
              splashColor: const Color(0xFF00E5FF).withOpacity(0.2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.6), width: 1.2),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.storefront_rounded, color: Color(0xFF00E5FF), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _vehicleData!['repuestos_compatibles'] ?? 'Ver catálogo de repuestos compatibles',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFFE2E8F0)),
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF00E5FF), size: 14),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool get _isMttResult {
    final d = _vehicleData;
    if (d == null) return false;
    final src = (d['data_source']?.toString() ?? '').toUpperCase();
    final fuente = (d['fuente']?.toString() ?? '').toUpperCase();
    return src.contains('MTT') || fuente == 'MTT';
  }

  /// Tarjeta de resultado del Registro Nacional de Servicios de Transporte
  /// de Pasajeros y Escolar (RNSTP - MTT). Reemplaza la tarjeta de
  /// especificaciones cuando la caja activa es MTT.
  Widget _buildMttCard({Map<String, dynamic>? data}) {
    final Map<String, dynamic> d = data ?? _vehicleData!;
    final bool isPublic = d['isPublicTransport'] == true;
    final Color accent = isPublic ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8);
    final String patente =
        _sanitizeMttText(d['patente']?.toString() ?? '').toUpperCase();

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.45), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.10),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(Icons.directions_bus_filled_rounded, color: accent, size: 22),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        patente,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: accent, letterSpacing: 1.2),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withOpacity(0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFF59E0B), width: 0.9),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.account_balance, color: Color(0xFFF59E0B), size: 12),
                        SizedBox(width: 4),
                        Text(
                          'MTT / RNSTP',
                          style: TextStyle(color: Color(0xFFF59E0B), fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.6),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  Tooltip(
                    message: 'Actualizar datos desde MTT',
                    child: _isRefreshingMtt
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFFF59E0B),
                              ),
                            ),
                          )
                        : IconButton(
                            onPressed: () => _refreshMttData(patente),
                            icon: const Icon(Icons.refresh, size: 20, color: Color(0xFFF59E0B)),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                            visualDensity: VisualDensity.compact,
                          ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accent.withOpacity(0.55), width: 1),
            ),
            child: Row(
              children: [
                Icon(
                  isPublic ? Icons.verified_user : Icons.directions_car_filled_rounded,
                  color: accent,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isPublic
                        ? 'TRANSPORTE PÚBLICO / ESCOLAR AUTORIZADO'
                        : 'VEHÍCULO PARTICULAR',
                    style: TextStyle(
                      color: accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (isPublic)
            ..._buildMttSections(data: d)
          else ...[
            Text(
              'El vehículo no pertenece al Registro Nacional de Servicios de '
              'Transporte de Pasajeros y Escolar (RNSTP) del Ministerio de '
              'Transportes y Telecomunicaciones.',
              style: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 12,
                height: 1.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, color: Color(0xFF64748B), size: 15),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'No está inscrito como transporte público, privado de pasajeros ni escolar. '
                    'Resultado oficial consultado en apps.mtt.cl.',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 11, height: 1.4),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Botón "Refrescar Caché" de la tarjeta MTT: invalida la caché local de
  /// la patente mostrada y fuerza una consulta fresca a la fuente. Los
  /// datos limpios recién obtenidos sobreescriben la entrada en disco
  /// (dentro del fetch del proveedor) y el setState refresca la pantalla
  /// al instante.
  Future<void> _refreshMttData(String plate) async {
    if (_isRefreshingMtt) return;
    setState(() => _isRefreshingMtt = true);
    try {
      final provider = _providers['mtt'];
      if (provider != null) {
        await provider.cache.invalidate(plate);
      }
      await _searchPlateLegacy(forceNetwork: true, plateOverride: plate);
      if (mounted) {
        _showSnack('Datos de MTT actualizados exitosamente');
      }
    } finally {
      if (mounted) setState(() => _isRefreshingMtt = false);
    }
  }

  bool get _isSiiResult {
    final d = _vehicleData;
    if (d == null) return false;
    final src = (d['data_source']?.toString() ?? '').toUpperCase();
    final fuente = (d['fuente']?.toString() ?? '').toUpperCase();
    return src.contains('SII') || fuente == 'SII';
  }

  bool get _isBoostrResult {
    final d = _vehicleData;
    if (d == null) return false;
    final src = (d['data_source']?.toString() ?? '').toUpperCase();
    final fuente = (d['fuente']?.toString() ?? '').toUpperCase();
    return src.contains('BOOSTR') || fuente == 'BOOSTR';
  }

  bool get _isPrtResult {
    final d = _vehicleData;
    if (d == null) return false;
    final src = (d['data_source']?.toString() ?? '').toUpperCase();
    final fuente = (d['fuente']?.toString() ?? '').toUpperCase();
    return src.contains('PRT') || fuente.contains('PRT');
  }

  /// Refresco en caliente del Motor PRT: invalida la caché central del
  /// backend y la caché local, y fuerza una nueva consulta. Si la vigencia
  /// exige verificación, el flujo reabre el modal reCAPTCHA (re-scraping).
  Future<void> _refreshPrtData(String plate) async {
    if (_isRefreshingPrt) return;
    setState(() => _isRefreshingPrt = true);
    try {
      final provider = _providers['prt'];
      if (provider != null) {
        await provider.cache.invalidate(plate);
      }
      try {
        await http
            .delete(Uri.parse('https://api.studiodigital360.com/api/vehicle/cache/$plate'))
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('PRT: error invalidando caché backend: $e');
      }
      await _searchPlateLegacy(forceNetwork: true, plateOverride: plate);
      if (mounted) {
        _showSnack('Datos de PRT actualizados exitosamente');
      }
    } finally {
      if (mounted) setState(() => _isRefreshingPrt = false);
    }
  }

  /// Refresco en caliente de la ficha Boostr: invalida la caché central del
  /// backend (DELETE /api/vehicle/cache/{plate}, para forzar una nueva
  /// llamada con ?include=owner) y la caché local, y consulta la fuente.
  Future<void> _refreshBoostrData(String plate) async {
    if (_isRefreshingBoostr) return;
    setState(() => _isRefreshingBoostr = true);
    try {
      final provider = _providers['boostr'];
      if (provider != null) {
        await provider.cache.invalidate(plate);
      }
      try {
        await http
            .delete(Uri.parse('https://api.studiodigital360.com/api/vehicle/cache/$plate'))
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('Boostr: error invalidando caché backend: $e');
      }
      await _searchPlateLegacy(forceNetwork: true, plateOverride: plate);
      if (mounted) {
        _showSnack('Datos de Boostr actualizados exitosamente');
      }
    } finally {
      if (mounted) setState(() => _isRefreshingBoostr = false);
    }
  }

  /// Formatea un monto CLP crudo (con/sin $ y puntos) a '$X.XXX.XXX'.
  String _formatClp(dynamic raw) {
    final digits = (raw ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '—';
    final n = int.tryParse(digits);
    if (n == null || n <= 0) return '—';
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final rem = s.length - i;
      buf.write(s[i]);
      if (rem > 1 && (rem - 1) % 3 == 0) buf.write('.');
    }
    return '\$$buf';
  }

  /// Botón "Refrescar Caché" de la tarjeta SII: invalida la caché local de
  /// la patente mostrada y fuerza una consulta fresca (los datos limpios
  /// sobreescriben la entrada en disco y el setState repinta al instante).
  Future<void> _refreshSiiData(String plate) async {
    if (_isRefreshingSii) return;
    setState(() => _isRefreshingSii = true);
    try {
      final provider = _providers['sii'];
      if (provider != null) {
        await provider.cache.invalidate(plate);
      }
      await _searchPlateLegacy(forceNetwork: true, plateOverride: plate);
      if (mounted) {
        _showSnack('Datos de SII actualizados exitosamente');
      }
    } finally {
      if (mounted) setState(() => _isRefreshingSii = false);
    }
  }

  /// Tarjeta de resultado de la caja SII (Tasación Fiscal Oficial).
  /// Cabecera esmeralda/verde fiscal + tarjetas destacadas de montos y
  /// ficha técnica tributaria desde datos_homologacion.
  /// Tarjeta de resultado de la caja SII (Tasación Fiscal Oficial).
  /// Motor local por Decreto Exento: sin modal ni scraping.
  ///
  /// - exact_match == true  → montos y código exactos.
  /// - exact_match == false → rangos ($MIN - $MAX) + selector desplegable
  ///   de versiones: al elegir una, los montos y el código se actualizan
  ///   al instante en pantalla.
  /// Tarjeta de resultado de la caja SII (Tasación Fiscal Oficial —
  /// motor local por Decreto Exento). SIN selector: desglose completo.
  ///
  /// - 1 variante  → tarjeta destacada con montos exactos + ficha técnica.
  /// - N variantes → badge con conteo, resumen de rangos y tarjetas
  ///   individuales por versión homologada (código, especificaciones,
  ///   equipamiento, tasación y permiso).
  /// - 0 variantes → estado informativo con botón de reintento.
  Widget _buildSiiCard({Map<String, dynamic>? data}) {
    const Color accent = Color(0xFF34D399);
    final Map<String, dynamic> d = data ?? _vehicleData!;
    final String patente =
        _sanitizeMttText(d['patente']?.toString() ?? '').toUpperCase();
    final bool exact = d['exact_match'] == true;

    final List<dynamic> versiones = (d['versiones'] is List)
        ? List<dynamic>.from(d['versiones'] as List)
        : const <dynamic>[];
    final int nVariantes = versiones.length;

    final Map<String, dynamic> rangoT = (d['rango_tasacion'] is Map)
        ? Map<String, dynamic>.from(d['rango_tasacion'] as Map)
        : const <String, dynamic>{};
    final Map<String, dynamic> rangoP = (d['rango_permiso'] is Map)
        ? Map<String, dynamic>.from(d['rango_permiso'] as Map)
        : const <String, dynamic>{};

    final String badgeText = (nVariantes > 1)
        ? 'SII / TASACIÓN OFICIAL: $nVariantes VARIANTES HOMOLOGADAS'
        : 'SII / TASACIÓN OFICIAL';

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.45), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.10),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.account_balance_rounded, color: accent, size: 22),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        patente,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: accent, letterSpacing: 1.2),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: accent, width: 0.9),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.verified_rounded, color: accent, size: 12),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            badgeText,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  Tooltip(
                    message: 'Actualizar datos desde SII',
                    child: _isRefreshingSii
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                            ),
                          )
                        : IconButton(
                            onPressed: () => _refreshSiiData(patente),
                            icon: const Icon(Icons.refresh, size: 20, color: accent),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                            visualDensity: VisualDensity.compact,
                          ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          if (nVariantes == 0)
            // ===== 0 variantes: estado limpio + reintento =====
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _mttEmptyBadge(
                    'Vehículo no tipificado en las tablas oficiales del Decreto Exento 2026.'),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: () => _refreshSiiData(patente),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent.withOpacity(0.15),
                      foregroundColor: accent,
                      side: const BorderSide(color: accent, width: 1.2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text(
                      'REINTENTAR / SINCRONIZAR DECRETO 2026',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.6),
                    ),
                  ),
                ),
              ],
            )
          else if (nVariantes == 1)
            // ===== 1 variante: tarjeta destacada exacta =====
            _buildSiiSingleVariant(d, versiones.first, accent)
          else ...[
            // ===== N variantes: resumen de rangos + desglose completo =====
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: accent.withOpacity(0.45), width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'RANGO AVALÚO FISCAL',
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${_formatClp(rangoT['min'])} - ${_formatClp(rangoT['max'])}',
                          softWrap: true,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF334155), width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'RANGO PERMISO CIRCULACIÓN',
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${_formatClp(rangoP['min'])} - ${_formatClp(rangoP['max'])}',
                          softWrap: true,
                          style: const TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (int i = 0; i < versiones.length; i++) ...[
              _buildSiiVariantCard(versiones[i], accent),
              if (i < versiones.length - 1) const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }

  /// Tarjeta destacada cuando existe UNA sola variante homologada.
  Widget _buildSiiSingleVariant(Map<String, dynamic> d, dynamic raw, Color accent) {
    final v = (raw is Map) ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final String tasacion = _sanitizeMttText(
        (v['tasacion_formateada'] ?? v['tasacion'] ?? d['tasacion_fiscal'])?.toString() ?? '');
    final String permiso = _sanitizeMttText(
        (v['permiso_formateada'] ?? v['permiso'] ?? d['permiso_circulacion'])?.toString() ?? '');
    final String codigo = _sanitizeMttText(
        (v['codigo_sii'] ?? d['codigo_sii'])?.toString() ?? '');
    final String anio = _sanitizeMttText(
        (v['anio_fabricacion'] ?? d['anio_tasacion'])?.toString() ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withOpacity(0.5), width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('AVALÚO FISCAL OFICIAL',
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                    const SizedBox(height: 6),
                    Text(tasacion, softWrap: true,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
                    if (anio.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('Año: $anio',
                          style: const TextStyle(color: Color(0xFF6EE7B7), fontSize: 10, fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF334155), width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('VALOR PERMISO DE CIRCULACIÓN',
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                    const SizedBox(height: 6),
                    Text(permiso, softWrap: true,
                        style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    const Text('Base imponible del permiso anual',
                        style: TextStyle(color: Color(0xFF64748B), fontSize: 10, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF052E22).withOpacity(0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withOpacity(0.45), width: 1),
          ),
          child: Row(
            children: [
              Icon(Icons.qr_code_2_rounded, color: accent, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('CÓDIGO HOMOLOGACIÓN SII',
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                    const SizedBox(height: 4),
                    SelectableText(
                      codigo.isEmpty ? '—' : codigo,
                      style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w900, fontFamily: 'monospace', letterSpacing: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildSiiVariantCard(raw, accent, highlighted: true),
      ],
    );
  }

  /// Tarjeta individual de una variante homologada (desglose exhaustivo).
  Widget _buildSiiVariantCard(dynamic raw, Color accent, {bool highlighted = false}) {
    final v = (raw is Map) ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final String version = _sanitizeMttText(v['version']?.toString() ?? '');
    final String descripcion = _sanitizeMttText(v['descripcion']?.toString() ?? '');
    final String modelo = _sanitizeMttText(v['modelo']?.toString() ?? '');
    final String codigo = _sanitizeMttText(v['codigo_sii']?.toString() ?? '');
    final String cilindrada = _sanitizeMttText(v['cilindrada']?.toString() ?? '');
    final String combustible = _sanitizeMttText(v['combustible']?.toString() ?? '');
    final String transmision = _sanitizeMttText(v['transmision']?.toString() ?? '');
    final String equipamiento = _sanitizeMttText(v['equipamiento']?.toString() ?? '');
    final String puertas = _sanitizeMttText(v['puertas']?.toString() ?? '');
    final bool ccMatch = v['cilindrada_match'] == true;
    final String titulo = descripcion.isNotEmpty
        ? descripcion
        : (version.isNotEmpty ? '$modelo $version'.trim() : modelo);

    final specs = <String>[
      if (cilindrada.isNotEmpty && cilindrada != '0') 'Cilindrada: $cilindrada cc',
      if (combustible.isNotEmpty) 'Combustible: $combustible',
      if (transmision.isNotEmpty) 'Transmisión: $transmision',
      if (puertas.isNotEmpty && puertas != '0') 'Puertas: $puertas',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF101B2D).withOpacity(highlighted ? 1.0 : 0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: highlighted ? accent.withOpacity(0.65) : const Color(0xFF1E293B),
          width: highlighted ? 1.2 : 0.9,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(ccMatch ? Icons.check_circle : Icons.directions_car_filled_rounded,
                  color: accent, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  softWrap: true,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800, height: 1.3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.qr_code_2_rounded, color: Color(0xFF94A3B8), size: 13),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(
                  codigo.isEmpty ? '—' : codigo,
                  style: const TextStyle(color: Color(0xFF6EE7B7), fontSize: 12, fontWeight: FontWeight.w800, fontFamily: 'monospace', letterSpacing: 1.1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (specs.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in specs)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF334155), width: 0.8),
                    ),
                    child: Text(
                      s,
                      softWrap: true,
                      style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 10, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
          if (equipamiento.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF334155), width: 0.6),
              ),
              child: Text(
                'Equipamiento: $equipamiento',
                softWrap: true,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('TASACIÓN FISCAL',
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    const SizedBox(height: 3),
                    Text(
                      _sanitizeMttText((v['tasacion_formateada'] ?? v['tasacion'] ?? '').toString()),
                      softWrap: true,
                      style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('PERMISO DE CIRCULACIÓN',
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    const SizedBox(height: 3),
                    Text(
                      _sanitizeMttText((v['permiso_formateada'] ?? v['permiso'] ?? '').toString()),
                      softWrap: true,
                      style: TextStyle(color: accent, fontSize: 13.5, fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }



  /// Tarjeta Boostr / Ficha Base Exhaustiva con 4 bloques:
  ///  A) Identificación y Propietario (destacado)
  ///  B) Especificaciones y Ficha Técnica
  ///  C) Motor, Combustible y Desgaste
  ///  D) Fabricación y Procedencia
  /// Layout responsivo (Wrap/Expanded + softWrap), sin truncar texto.
  Widget _buildBoostrCard({Map<String, dynamic>? data}) {
    const Color accent = Color(0xFF38BDF8);
    final Map<String, dynamic> d = data ?? _vehicleData!;
    final VehicleBaseModel v = VehicleBaseModel.fromJson(d);
    final String plateDv = [
      v.plate ?? '',
      if ((v.dv ?? '').isNotEmpty) v.dv!,
    ].join('-');

    String info(String? value, [String fallback = 'No informado']) {
      final s = (value ?? '').toString().trim();
      return s.isEmpty ? fallback : s;
    }

    String doorsText() => (v.doors ?? 0) > 0 ? '${v.doors} puertas' : 'No informado';
    String kmText() => (v.kilometers ?? 0) > 0
        ? '${_formatThousands(v.kilometers!)} Km'
        : '0 Km / No registrado';

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.45), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.10),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.bolt, color: accent, size: 22),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        plateDv,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: accent, letterSpacing: 1.2),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: accent, width: 0.9),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified_user, color: accent, size: 12),
                        SizedBox(width: 4),
                        Text(
                          'BOOSTR / PADRÓN CIVIL',
                          style: TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  Tooltip(
                    message: 'Actualizar datos desde Boostr',
                    child: _isRefreshingBoostr
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                            ),
                          )
                        : IconButton(
                            onPressed: () => _refreshBoostrData(v.plate ?? ''),
                            icon: const Icon(Icons.refresh, size: 20, color: accent),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                            visualDensity: VisualDensity.compact,
                          ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ===== Bloque A: Identificación y Propietario =====
          _boostrBlockHeader(Icons.badge_outlined, 'IDENTIFICACIÓN Y PROPIETARIO'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withOpacity(0.4), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PLACA PATENTE ${plateDv}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.6,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 8),
                if ((v.ownerName ?? '').isNotEmpty) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.person, color: accent, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          v.ownerName!,
                          softWrap: true,
                          style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12.5, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.badge, color: Color(0xFF94A3B8), size: 15),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'RUT: ${v.ownerRut ?? 'No informado'}',
                          softWrap: true,
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  const Row(
                    children: [
                      Icon(Icons.badge, color: Color(0xFF64748B), size: 16),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Titular: No registrado en padrón',
                          softWrap: true,
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5, fontWeight: FontWeight.w600, fontStyle: FontStyle.italic),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ===== Bloque B: Especificaciones y Ficha Técnica =====
          _boostrBlockHeader(Icons.settings_suggest_rounded, 'ESPECIFICACIONES Y FICHA TÉCNICA'),
          _boostrInfoRow('Marca y Modelo', '${info(v.make)} ${info(v.model)}'.trim()),
          _boostrInfoRow('Tipo de Carrocería / Uso', info(v.type)),
          _boostrInfoRow('Año de Fabricación', v.year != null ? '${v.year}' : 'No informado'),
          _boostrInfoRow('Versión', info(v.version, 'No informada')),
          _boostrInfoRow('Color', info(v.color)),
          _boostrInfoRow('Puertas', doorsText()),
          _boostrInfoRow('Transmisión', info(v.transmission, 'No informada')),
          const SizedBox(height: 12),

          // ===== Bloque C: Motor, Combustible y Desgaste =====
          _boostrBlockHeader(Icons.speed_rounded, 'MOTOR, COMBUSTIBLE Y DESGASTE'),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: accent.withOpacity(0.45), width: 1),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.speed, color: accent, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'KILOMETRAJE',
                              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              kmText(),
                              softWrap: true,
                              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _boostrInfoRow('Combustible', info(v.gasType)),
          _boostrInfoRow('N° de Motor', info(v.engine)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text(
                        'N° de Chasis / VIN',
                        softWrap: true,
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 6,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Flexible(
                            child: SelectableText(
                              info(v.chassis),
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                color: (v.chassis ?? '').isEmpty ? const Color(0xFF64748B) : Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          if ((v.chassis ?? '').isNotEmpty) ...[
                            const SizedBox(width: 4),
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () async {
                                await Clipboard.setData(ClipboardData(text: v.chassis!));
                                if (mounted) _showSnack('VIN copiado al portapapeles');
                              },
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.copy_rounded, size: 15, color: accent),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Divider(color: const Color(0xFF1E293B).withOpacity(0.5), height: 1),
              ],
            ),
          ),
          _boostrInfoRow('Cilindrada', info(v.engineSize, 'No informada')),
          if (v.valuation != null && v.valuation.toString().isNotEmpty && v.valuation != 0)
            _boostrInfoRow('Valuación', _formatClp(v.valuation)),
          const SizedBox(height: 12),

          // ===== Bloque D: Fabricación y Procedencia =====
          _boostrBlockHeader(Icons.factory_rounded, 'FABRICACIÓN Y PROCEDENCIA'),
          _boostrInfoRow('Fabricante', info(v.manufacturer)),
          _boostrInfoRow(
            'País y Región',
            [
              info(v.country, 'No informado'),
              if ((v.region ?? '').isNotEmpty) v.region!,
            ].join(' — '),
          ),
        ],
      ),
    );
  }

  /// Cabecera de sub-bloque de la tarjeta Boostr.
  Widget _boostrBlockHeader(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF38BDF8), size: 15),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              softWrap: true,
              style: const TextStyle(
                color: Color(0xFF38BDF8),
                fontSize: 11.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.9,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Fila etiqueta→valor de la tarjeta Boostr (sin truncado).
  Widget _boostrInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Text(
                  label,
                  softWrap: true,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 6,
                child: SelectableText(
                  value,
                  textAlign: TextAlign.end,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Divider(color: const Color(0xFF1E293B).withOpacity(0.5), height: 1),
        ],
      ),
    );
  }

  /// Separador de miles chileno: 283961 → '283.961'.
  String _formatThousands(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final rem = s.length - i;
      buf.write(s[i]);
      if (rem > 1 && (rem - 1) % 3 == 0) buf.write('.');
    }
    return buf.toString();
  }



  /// Tarjeta del Motor PRT (Información del Vehículo + Revisión Técnica).
  /// Usa el modelo tipificado [PrtVehicleData]: el VIN vacío se pinta como
  /// "No informado" (nunca "Tipo"), el combustible vacío como "No
  /// registrado" (nunca una fecha) y la fecha de vencimiento general se
  /// muestra en su tarjeta destacada de vigencia oficial.
  Widget _buildPrtCard({Map<String, dynamic>? data}) {
    const Color accent = Color(0xFF10B981);
    final Map<String, dynamic> d = data ?? _vehicleData!;
    final PrtVehicleData v = PrtVehicleData.fromJson(d);
    final String patente = v.patente.toUpperCase();

    final String vinTxt = v.vinSeguro;
    final String combTxt = v.combustibleSeguro;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.45), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.10),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.precision_manufacturing, color: accent, size: 22),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        patente,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: accent, letterSpacing: 1.2),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: accent, width: 0.9),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified_user, color: accent, size: 12),
                        SizedBox(width: 4),
                        Text(
                          'PRT / CONSULTA OFICIAL',
                          style: TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  Tooltip(
                    message: 'Actualizar datos desde PRT',
                    child: _isRefreshingPrt
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                            ),
                          )
                        : IconButton(
                            onPressed: () => _refreshPrtData(patente),
                            icon: const Icon(Icons.refresh, size: 20, color: accent),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                            visualDensity: VisualDensity.compact,
                          ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ===== Tarjeta destacada de VIGENCIA OFICIAL =====
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [accent.withOpacity(0.22), accent.withOpacity(0.08)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withOpacity(0.55), width: 1.2),
            ),
            child: Row(
              children: [
                const Icon(Icons.event_available_rounded, color: accent, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'VIGENCIA OFICIAL REVISIÓN TÉCNICA',
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        v.rtEstado.isEmpty ? 'Sin registro' : v.rtEstado.toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900),
                      ),
                      if (v.rtVencimiento.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          'Vence: ${v.rtVencimiento}',
                          style: const TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ===== Ficha técnica clave-valor (valores nunca desplazados) =====
          Row(
            children: [
              const Icon(Icons.segment, color: accent, size: 15),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'INFORMACIÓN DEL VEHÍCULO',
                  softWrap: true,
                  style: const TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (v.tipo.isNotEmpty) _mttPairRow('TIPO', v.tipo),
          if (v.marca.isNotEmpty) _mttPairRow('MARCA', v.marca),
          if (v.modelo.isNotEmpty) _mttPairRow('MODELO', v.modelo),
          if (v.anio.isNotEmpty) _mttPairRow('AÑO FAB.', v.anio),
          if (v.nroMotor.isNotEmpty) _mttPairRow('N° MOTOR', v.nroMotor),
          if (v.chasis.isNotEmpty) _mttPairRow('N° CHASIS', v.chasis),
          _mttPairRow('N° VIN', vinTxt),
          if (v.color.isNotEmpty) _mttPairRow('COLOR', v.color),
          _mttPairRow('COMBUSTIBLE', combTxt),
          if (v.pbv.isNotEmpty) _mttPairRow('PBV', v.pbv),
          if (v.sello.isNotEmpty) _mttPairRow('TIPO SELLO', v.sello),
          const SizedBox(height: 12),

          // ===== Historial completo de Revisión Técnica =====
          if (v.historial.isNotEmpty) ...[
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                leading: const Icon(Icons.history, color: Color(0xFF38BDF8), size: 22),
                title: Text(
                  'Historial de Revisiones (${v.historial.length} registros)',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8), letterSpacing: 0.5),
                ),
                children: v.historial.map<Widget>((rt) => _prtTimelineCard(rt)).toList(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _openPdfReport,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF).withOpacity(0.15),
                foregroundColor: const Color(0xFF00E5FF),
                side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              icon: const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFF00E5FF), size: 22),
              label: const Text(
                'DESCARGAR INFORME OFICIAL (PDF)',
                style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.1),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openPartsMarketplace,
              borderRadius: BorderRadius.circular(12),
              splashColor: const Color(0xFF00E5FF).withOpacity(0.2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.6), width: 1.2),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.storefront_rounded, color: Color(0xFF00E5FF), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        d['repuestos_compatibles'] ?? 'Ver catálogo de repuestos compatibles',
                        softWrap: true,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFFE2E8F0)),
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF00E5FF), size: 14),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }



  /// Timeline Card premium de una inspección histórica: cabecera con fecha
  /// y badges adaptativos (GASES + estado), sub-línea de vigencia, planta y
  /// certificado limpio. Borde izquierdo acentuado según el resultado.
  Widget _prtTimelineCard(PrtHistoryEntry rt) {
    final rawEstado = rt.estado.trim().toUpperCase();
    final isApproved = rawEstado.contains('APROB');
    final isRechazado = rawEstado.contains('RECHAZ');
    final accent = isApproved
        ? const Color(0xFF10B981)
        : (isRechazado ? const Color(0xFFF87171) : const Color(0xFF64748B));

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF14223C), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: accent, width: 3),
          top: BorderSide(color: const Color(0xFF1E293B), width: 0.8),
          right: BorderSide(color: const Color(0xFF1E293B), width: 0.8),
          bottom: BorderSide(color: const Color(0xFF1E293B), width: 0.8),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // a) Cabecera: fecha + badges adaptativos (sin overflow).
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.calendar_today_rounded,
                    size: 15, color: Colors.white38),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Control: ${rt.fecha.isEmpty ? '-' : rt.fecha}',
                    softWrap: true,
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    children: [
                      if (rt.esGases) _prtGasesBadge(),
                      _prtEstadoBadge(rt),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // b) Sub-línea de vigencia histórica (peso visual bajo).
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Vigencia otorgada: ${rt.vencimiento.isEmpty ? '-' : rt.vencimiento}',
                    softWrap: true,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF94A3B8)),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Planta: ${rt.codPlanta.isEmpty ? '-' : rt.codPlanta}',
                    softWrap: true,
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: Colors.white38,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // c) Planta (mayúsculas sobrias) + certificado limpio.
            if (rt.planta.isNotEmpty)
              Text(
                rt.planta.toUpperCase(),
                softWrap: true,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                  letterSpacing: 0.3,
                ),
              ),
            if (rt.certificadoLimpio.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.description_outlined,
                      size: 12, color: Colors.white38),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Certificado: ${rt.certificadoLimpio}',
                      softWrap: true,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Colors.white54,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Badge de estado APROBADA / RECHAZADA (· causa) con icono y colores
  /// translúcidos, blindado contra overflow (Flexible + ellipsis).
  Widget _prtEstadoBadge(PrtHistoryEntry rt) {
    final raw = rt.estado.trim().toUpperCase();
    final isApproved = raw.contains('APROB');
    final isRechazado = raw.contains('RECHAZ');

    String label;
    Color color;
    IconData icon;
    if (isApproved) {
      label = 'APROBADA';
      color = const Color(0xFF10B981);
      icon = Icons.check_circle_outline;
    } else if (isRechazado) {
      String causa = '';
      if (raw.contains('GASES')) {
        causa = 'GASES';
      } else if (raw.contains('MECAN')) {
        causa = 'MECÁNICA';
      }
      label = causa.isNotEmpty ? 'RECHAZADA · $causa' : 'RECHAZADA';
      color = const Color(0xFFF87171);
      icon = Icons.cancel_outlined;
    } else {
      label = raw.isEmpty ? '—' : raw;
      color = const Color(0xFF94A3B8);
      icon = Icons.info_outline_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.55), width: 0.9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Badge [ GASES ] cian atenuado con borde sutil.
  Widget _prtGasesBadge() {
    const color = Color(0xFF22D3EE);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.45), width: 0.9),
      ),
      child: const Text(
        '[ GASES ]',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
          color: color,
        ),
      ),
    );
  }



  /// Dashboard unificado: tarjetas continuas de las 4 fuentes oficiales
  /// (PRT → Boostr → MTT → SII) con transiciones suaves y estados por
  /// fuente (ok / queued / no disponible).
  Widget _buildDashboard() {
    final dash = _dashboard!;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: Column(
        key: ValueKey('dash-${_vehicleData?['patente'] ?? 'empty'}'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 380),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withOpacity(0.85),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.35), width: 1),
            ),
            child: const Row(
              children: [
                Icon(Icons.dashboard_rounded, color: Color(0xFF00E5FF), size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'DASHBOARD MULTIPROVEEDOR — 4 FUENTES OFICIALES',
                    softWrap: true,
                    style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11.5, fontWeight: FontWeight.w900, letterSpacing: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_dashboardOk['prt'] == true) ...[
            _buildPrtCard(data: dash['prt']),
            const SizedBox(height: 16),
          ] else
            _dashSourceTile('prt'),
          if (_dashboardOk['boostr'] == true) ...[
            _buildBoostrCard(data: dash['boostr']),
            const SizedBox(height: 16),
          ] else if (_dashboardQueued)
            _boostrQueueBanner()
          else
            _dashSourceTile('boostr'),
          if (_dashboardOk['mtt'] == true) ...[
            _buildMttCard(data: dash['mtt']),
            const SizedBox(height: 16),
          ] else
            _dashSourceTile('mtt'),
          if (_dashboardOk['sii'] == true) ...[
            _buildSiiCard(data: dash['sii']),
            const SizedBox(height: 16),
          ] else
            _dashSourceTile('sii'),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Tile compacto de fuente no disponible (con acción de reintento por
  /// motor: PRT reabre el flujo reCAPTCHA; las demás re-consultan).
  Widget _dashSourceTile(String engine) {
    // Degradación elegante: PRT saturado por cuota reCAPTCHA Enterprise.
    if (engine == 'prt' && _prtQuotaExceeded) {
      return Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 380),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF59E0B).withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.5), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_off_rounded, color: Color(0xFFF59E0B), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '[ PRT: SERVIDOR OFICIAL SATURADO ]',
                    softWrap: true,
                    style: const TextStyle(
                      color: Color(0xFFF59E0B),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'La plataforma ministerial prt.cl presenta congestión en su verificador. El resto de las fuentes opera normalmente.',
              softWrap: true,
              style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, height: 1.4, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 38,
              child: ElevatedButton.icon(
                onPressed: () => unawaited(_solvePrtForDashboard(_currentPlateValue())),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B).withOpacity(0.15),
                  foregroundColor: const Color(0xFFF59E0B),
                  side: const BorderSide(color: Color(0xFFF59E0B), width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('REINTENTAR',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
              ),
            ),
          ],
        ),
      );
    }

    // PRT-FIRST — estado formal "SIN REGISTRO": la verificación ministerial
    // respondió sin historial de revisiones (homologado o exento). No es un
    // fallo de red: es un resultado oficial del pipeline.
    if (engine == 'prt' && _prtSinRegistro) {
      return Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 380),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withOpacity(0.75),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF64748B).withOpacity(0.65), width: 1.1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.verified_user_rounded, color: Color(0xFF94A3B8), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '[ PRT: SIN REVISIONES REGISTRADAS ]',
                        softWrap: true,
                        style: TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.7,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Vehículo sin historial de revisiones técnicas en el sistema ministerial (homologado o exento).',
                        softWrap: true,
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11.5,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 38,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_solvePrtForDashboard(_currentPlateValue())),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF94A3B8),
                  side: const BorderSide(color: Color(0xFF64748B), width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.replay_rounded, size: 16),
                label: const Text(
                  'REINTENTAR VERIFICACIÓN',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.6),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // PRT-FIRST — estado 'omitido': el usuario descartó el modal, pulsó
    // CONTINUAR SIN PRT o se agotó el timeout humano. Tile neutro de
    // verificación pendiente con reintento explícito (sin penalizar el
    // resto del dashboard).
    if (engine == 'prt' && _prtOmitido) {
      return Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 380),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withOpacity(0.75),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF475569).withOpacity(0.8), width: 1.1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.hourglass_empty_rounded, color: Color(0xFF00E5FF), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '[ PRT: VERIFICACIÓN PENDIENTE ]',
                        softWrap: true,
                        style: TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.7,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Se omitió la verificación ministerial para esta patente. Puedes ejecutar la auditoría PRT completa cuando quieras.',
                        softWrap: true,
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11.5,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_solvePrtForDashboard(_currentPlateValue())),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF00E5FF),
                  side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.gavel_rounded, size: 16),
                label: const Text(
                  'REINTENTAR PRT',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, letterSpacing: 0.6),
                ),
              ),
            ),
          ],
        ),
      );
    }

    const names = {
      'prt': 'PRT (Revisión Técnica)',
      'boostr': 'BOOSTR (Padrón Civil)',
      'mtt': 'MTT (Transporte Público / RNSTP)',
      'sii': 'SII (Tasación Fiscal)',
    };
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 380),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155), width: 0.9),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: Color(0xFF64748B), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${names[engine] ?? engine.toUpperCase()}: fuente no disponible',
              softWrap: true,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () {
              if (engine == 'prt') {
                // PRT: abrir directamente el modal reCAPTCHA (human-in-the-loop).
                unawaited(_solvePrtForDashboard(_currentPlateValue()));
                return;
              }
              setState(() {
                _selectedEngine = engine;
                _dashboardMode = false;
                _vehicleData = null;
              });
              _searchPlateLegacy();
            },
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF00E5FF),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('REINTENTAR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
          ),
        ],
      ),
    );
  }

  /// Banner interactivo ámbar de cuota Boostr agotada (patente en cola).
  Widget _boostrQueueBanner() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 380),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.55), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.hourglass_bottom_rounded, color: Color(0xFFF59E0B), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'BOOSTR / PADRÓN CIVIL — EN COLA',
                  style: TextStyle(color: Color(0xFFF59E0B), fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.6),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Cuota mensual de padrón en espera de renovación. Patente agendada para sincronización automática.',
                  softWrap: true,
                  style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, height: 1.4, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Patente normalizada actual (ficha visible o input).
  String _currentPlateValue() {
    final fromData = (_vehicleData?['patente'] ?? _vehicleData?['plate'])?.toString().trim() ?? '';
    if (fromData.isNotEmpty) return fromData.toUpperCase();
    return _plateController.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  }

  /// Resuelve la fuente PRT dentro del dashboard: ejecuta el flujo P2P
  /// (modal reCAPTCHA) con la patente actual e integra el resultado en la
  /// tarjeta PRT del dashboard sin salir de la vista unificada.
  Future<void> _solvePrtForDashboard(String plate) async {
    if (plate.isEmpty) return;
    try {
      final provider = _providers['prt'];
      if (provider == null) return;
      final result = await provider.fetch(plate, context: context);
      if (!mounted) return;
      final evt = _lastPrtEvent;
      _lastPrtEvent = null;
      if (evt == 'RECAPTCHA_QUOTA_EXCEEDED') {
        setState(() {
          _prtQuotaExceeded = true;
          _prtSinRegistro = false;
          _prtOmitido = true;
        });
        _showSnack(
            'Portal oficial de PRT temporalmente saturado (límite de cuota Google excedido en prt.cl). Mostrando datos de Padrón, MTT y SII.');
        return;
      }
      if (evt == 'RECAPTCHA_TIMEOUT') {
        setState(() {
          _prtQuotaExceeded = false;
          _prtSinRegistro = false;
          _prtOmitido = true;
        });
        _showSnack('Verificación PRT agotada por tiempo. Reintenta la auditoría cuando quieras.');
        return;
      }
      if (evt == 'PRT_SIN_REGISTRO') {
        setState(() {
          _prtQuotaExceeded = false;
          _prtSinRegistro = true;
          _prtOmitido = false;
        });
        _showSnack(
            'PRT: sin revisiones técnicas registradas para esta patente (homologado o exento).');
        return;
      }
      if (result.found && _prtDataCompleto(result.data)) {
        setState(() {
          _prtQuotaExceeded = false;
          _prtSinRegistro = false;
          _prtOmitido = false;
          _dashboard?['prt'] = Map<String, dynamic>.from(result.data);
          _dashboardOk['prt'] = true;
          _vehicleData ??= result.data;
        });
        _showSnack('Datos PRT integrados al dashboard');
      } else if (result.found) {
        // Fallback sin inspecciones: NO se marca como completado.
        _showSnack('PRT: la fuente no entregó revisiones — reintenta la verificación P2P');
      } else {
        // Modal descartado voluntariamente (X / CONTINUAR SIN PRT).
        setState(() {
          _prtSinRegistro = false;
          _prtOmitido = true;
        });
        _showSnack('PRT: verificación descartada — reintenta desde la tarjeta');
      }
    } catch (e) {
      debugPrint('[PRT-DASH] $e');
    }
  }

  /// Selección de motor: si el dashboard ya cargó esa fuente, la muestra al
  /// instante (vista segmentada); si no, dispara el flujo clásico del motor.



  /// Sanitización profunda anti-mojibake (misma política que el backend):
  /// reemplazos explícitos + barrido genérico de pares 'Ã'+byte, para que
  /// TODO texto se pinte con acentos y ñ perfectos aunque provenga de una
  /// caché local vieja o de una respuesta corrupta.
  String _sanitizeMttText(String text) {
    var t = text;
    const fixes = <String, String>{
      '\u00c3\u008d': 'Í', // Ã + 0x8D (SHY invisible)
      '\u00c3\u00cd': 'Í',
      '\u00c3\u00ed': 'í',
      '\u00c3\u009a': 'Ú', // Ã + 0x9A
      '\u00c3\u0161': 'Ú', // Ã + š (cp1252)
      '\u00c3\u00da': 'Ú',
      '\u00c3\u00fa': 'ú',
      '\u00c3\u0081': 'Á', // Ã + 0x81
      '\u00c3\u00a1': 'á',
      '\u00c3\u2030': 'É', // Ã + ‰ (cp1252)
      '\u00c3\u00c9': 'É',
      '\u00c3\u00e9': 'é',
      '\u00c3\u201c': 'Ó', // Ã + “ (cp1252)
      '\u00c3\u00d3': 'Ó',
      '\u00c3\u00f3': 'ó',
      '\u00c3\u2018': 'Ñ', // Ã + ‘ (cp1252)
      '\u00c3\u00d1': 'Ñ',
      '\u00c3\u00f1': 'ñ',
      'P\u00c3\u0161BLICO': 'PÚBLICO',
      'P\u00c3\u009aBLICO': 'PÚBLICO',
      'B\u00c3\u0081SICO': 'BÁSICO',
      'B\u00c3\u00a1SICO': 'BÁSICO',
      'VEH\u00c3\u008dCULO': 'VEHÍCULO',
      'VEH\u00c3\u00cdCULO': 'VEHÍCULO',
      'ACOMPA\u00c3\u2018ANTES': 'ACOMPAÑANTES',
      'ACOMPA\u00c3\u0091ANTES': 'ACOMPAÑANTES',
    };
    fixes.forEach((k, v) {
      t = t.replaceAll(k, v);
    });
    // Barrido genérico: par 'Ã' + byte-latino → carácter correcto vía
    // round-trip latin-1 → utf-8 (p. ej. 'RegiÃ³n' → 'Región').
    t = t.replaceAllMapped(
      RegExp(r'Ã[\x80-\xbf\u0161\u2030\u201c\u201d\u2018\u2019\u2122\u017d\u017e\u0152\u0153\u009a]'),
      (m) {
        final pair = m.group(0)!;
        try {
          return utf8.decode(latin1.encode(pair));
        } catch (_) {
          return pair;
        }
      },
    );
    return t.trim();
  }

  /// Normaliza la estructura dinámica de secciones que entrega el backend
  /// (`secciones: [{titulo, tipo: pares|lista, items: [...]}]`).
  /// Si la entrada de caché local es antigua (solo campos planos), sintetiza
  /// una sección de pares para mantener la UI uniforme.
  List<dynamic> _mttSections({Map<String, dynamic>? data}) {
    final Map<String, dynamic> d = data ?? _vehicleData!;
    final raw = d['secciones'];
    if (raw is List && raw.isNotEmpty) return raw;
    final pairs = <Map<String, String>>[];
    void add(String key, dynamic v) {
      final s = _sanitizeMttText(v?.toString() ?? '');
      if (s.isNotEmpty) pairs.add({'etiqueta': key, 'valor': s});
    }

    add('Tipo de Servicio', d['tipo_servicio']);
    add('Estado del Servicio', d['estado_servicio']);
    add('Región', d['region']);
    add('Folio Flota', d['folio_flota']);
    add('Vencimiento Permiso', d['fecha_vencimiento_permiso']);
    if (pairs.isEmpty) return const <dynamic>[];
    return <dynamic>[
      <String, dynamic>{'titulo': 'DATOS DEL SERVICIO', 'tipo': 'pares', 'items': pairs},
    ];
  }

  /// Renderizado 100% dinámico de `secciones`: títulos en ámbar, pares
  /// etiqueta/valor sin truncar (softWrap) y listas como tarjetas destacadas.
  List<Widget> _buildMttSections({Map<String, dynamic>? data}) {
    final Map<String, dynamic> d = data ?? _vehicleData!;
    final widgets = <Widget>[];
    final secciones = _mttSections(data: d);
    if (secciones.isEmpty) {
      widgets.add(_mttEmptyBadge('No registra datos'));
      return widgets;
    }
    for (final sec in secciones) {
      if (sec is! Map) continue;
      final titulo =
          _sanitizeMttText(sec['titulo']?.toString() ?? 'INFORMACIÓN').toUpperCase();
      final tipo = (sec['tipo']?.toString() ?? 'pares').toLowerCase();
      final rawItems = (sec['items'] is List) ? (sec['items'] as List) : const <dynamic>[];

      widgets.add(const SizedBox(height: 6));
      widgets.add(_mttSectionHeader(titulo));

      if (rawItems.isEmpty) {
        widgets.add(_mttEmptyBadge());
        continue;
      }
      if (tipo == 'lista') {
        for (final it in rawItems) {
          var txt = _sanitizeMttText(it is Map
              ? (it['valor'] ?? it['texto'] ?? '').toString()
              : it.toString());
          // Limpieza defensiva para entradas de caché antiguas: quitar el
          // título de sección repetido y conceptos ya presentes en el
          // encabezado (misma política que el backend).
          final upper = txt.toUpperCase();
          if (upper == titulo) {
            txt = '';
          } else if (upper.startsWith('$titulo ')) {
            txt = txt.substring(titulo.length).trim();
          }
          txt = txt
              .replaceFirst(
                RegExp(r'^RENOVACI[OÓ]N\s*POR\s*CANCELACI[OÓ]N\s*[:.\-–—]?\s*', caseSensitive: false),
                '',
              )
              .trim();
          widgets.add(txt.isEmpty ? _mttEmptyBadge() : _mttListItem(txt, titulo));
        }
      } else {
        for (final it in rawItems) {
          final label = _sanitizeMttText(
              it is Map ? (it['etiqueta']?.toString() ?? 'Dato') : 'Dato');
          final value = _sanitizeMttText(
              it is Map ? (it['valor']?.toString() ?? '') : it.toString());
          widgets.add(_mttPairRow(label, value));
        }
      }
    }
    return widgets;
  }

  Widget _mttSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.segment, color: Color(0xFFF59E0B), size: 15),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              softWrap: true,
              style: const TextStyle(
                color: Color(0xFFF59E0B),
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Fila de par etiqueta→valor con wrap total: sin ellipsis ni truncado.
  Widget _mttPairRow(String label, String value) {
    final noData = value.isEmpty || value.toLowerCase() == 'no registra';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Text(
                  label,
                  softWrap: true,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 6,
                child: SelectableText(
                  noData ? 'No registra' : value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: noData ? const Color(0xFF64748B) : Colors.white,
                    fontSize: 12,
                    fontWeight: noData ? FontWeight.w500 : FontWeight.w700,
                    fontStyle: noData ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Divider(color: const Color(0xFF1E293B).withOpacity(0.5), height: 1),
        ],
      ),
    );
  }

  /// Tarjeta destacada por elemento de lista (conductores, notas, etc.),
  /// con icono según el tipo de sección y texto completo sin truncar.
  Widget _mttListItem(String text, String sectionTitle) {
    final t = sectionTitle.toUpperCase();
    IconData icon = Icons.badge;
    if (t.contains('CONDUCT') || t.contains('ACOMPA')) {
      icon = Icons.person;
    } else if (t.contains('NOTA')) {
      icon = Icons.sticky_note_2_rounded;
    } else if (t.contains('RESULTADO')) {
      icon = Icons.search_rounded;
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.35), width: 0.9),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFFF59E0B), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              text,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 12.5,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Badge neutro para secciones/listas sin datos.
  Widget _mttEmptyBadge([String text = 'No registra datos']) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF94A3B8).withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF64748B).withOpacity(0.4), width: 0.8),
      ),
      child: Row(
        children: [
          const Icon(Icons.remove_circle_outline, color: Color(0xFF64748B), size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              softWrap: true,
              style: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _specRow(String label, String? value, {bool isHighlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Text(label, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 6,
                child: SelectableText(
                  value ?? '---',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: isHighlight ? const Color(0xFF00E5FF) : Colors.white,
                    fontSize: 12,
                    fontWeight: isHighlight ? FontWeight.w900 : FontWeight.w700,
                    fontFamily: isHighlight || label.contains('VIN') || label.contains('MOTOR') ? 'monospace' : null,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Divider(color: const Color(0xFF1E293B).withOpacity(0.5), height: 1),
        ],
      ),
    );
  }
}

class ChileanPlateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    // La Ñ se deja pasar para que el Motor Normativo la detecte y muestre
    // el banner educativo (no se bloquea en silencio).
    String clean = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9Ñ]'), '');
    if (clean.length > 6) clean = clean.substring(0, 6);
    StringBuffer valid = StringBuffer();
    for (int i = 0; i < clean.length; i++) {
      String char = clean[i];
      bool isLetter = RegExp(r'[A-ZÑ]').hasMatch(char);
      bool isDigit = RegExp(r'[0-9]').hasMatch(char);
      if (i == 0 || i == 1) {
        if (isLetter) valid.write(char); else break;
      } else if (i == 2) {
        if (isLetter || isDigit) valid.write(char); else break;
      } else if (i == 3) {
        bool isClassic = RegExp(r'[0-9]').hasMatch(valid.toString()[2]);
        if (isClassic) {
          if (isDigit) valid.write(char); else break;
        } else {
          if (isLetter || isDigit) valid.write(char); else break;
        }
      } else if (i >= 4) {
        if (isDigit) valid.write(char); else break;
      }
    }
    final res = valid.toString();
    return TextEditingValue(text: res, selection: TextSelection.collapsed(offset: res.length));
  }
}
class OldFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

// ============================================================================
// PANTALLA COMPLETA DEDICADA DE VERIFICACIÓN PRT (ESTÁNDAR DE LA INDUSTRIA)
// ============================================================================

/// Modelo fuertemente tipado del payload de extracción de PRT.
///
/// Esquema FIJO y homogéneo: todas las claves existen siempre (vacías como
/// ''), listo para persistir en base de datos. Se construye desde el JSON
/// crudo del script de inyección mediante [PrtVehiclePayload.fromJson].
class PrtVehiclePayload {
  final String patente;
  final String tipo;
  final String marca;
  final String modelo;
  final String anio;
  final String nroMotor;
  final String chasis;
  final String vin;
  final String color;
  final String combustible;
  final String pbv;
  final String sello;
  final List<Map<String, dynamic>> historialRt;
  final String rtVencimiento;
  final String rtEstado;
  final String fuente;
  final String extraidoEn;

  PrtVehiclePayload({
    this.patente = '',
    this.tipo = '',
    this.marca = '',
    this.modelo = '',
    this.anio = '',
    this.nroMotor = '',
    this.chasis = '',
    this.vin = '',
    this.color = '',
    this.combustible = '',
    this.pbv = '',
    this.sello = '',
    this.historialRt = const [],
    this.rtVencimiento = '',
    this.rtEstado = '',
    this.fuente = '',
    this.extraidoEn = '',
  });

  static String _s(dynamic v) => (v is String) ? v : '';

  factory PrtVehiclePayload.fromJson(Map<String, dynamic> j) {
    return PrtVehiclePayload(
      patente: _s(j['patente']),
      tipo: _s(j['tipo']),
      marca: _s(j['marca']),
      modelo: _s(j['modelo']),
      anio: _s(j['anio']),
      nroMotor: _s(j['nro_motor']),
      chasis: _s(j['chasis']),
      vin: _s(j['vin']),
      color: _s(j['color']),
      combustible: _s(j['combustible']),
      pbv: _s(j['pbv']),
      sello: _s(j['sello']),
      historialRt: (j['historial_rt'] is List)
          ? (j['historial_rt'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList()
          : const [],
      rtVencimiento: _s(j['rt_vencimiento']),
      rtEstado: _s(j['rt_estado']),
      fuente: _s(j['fuente']),
      extraidoEn: _s(j['extraido_en']),
    );
  }

  Map<String, dynamic> toJson() => {
        'patente': patente,
        'tipo': tipo,
        'marca': marca,
        'modelo': modelo,
        'anio': anio,
        'nro_motor': nroMotor,
        'chasis': chasis,
        'vin': vin,
        'color': color,
        'combustible': combustible,
        'pbv': pbv,
        'sello': sello,
        'historial_rt': historialRt,
        'rt_vencimiento': rtVencimiento,
        'rt_estado': rtEstado,
        'fuente': fuente,
        'extraido_en': extraidoEn,
      };
}

/// Servicio desacoplado de datos PRT con CACHÉ INTELIGENTE y ciclo de vida
/// autónomo.
///
/// REGLA DE CACHÉ (Cache-First condicional):
///  - Registro con RT VIGENTE (resultado aprobado Y fecha_vigencia >= hoy)
///    → se resuelve al instante desde caché, SIN WebView ni reCAPTCHA.
///  - Registro VENCIDO, RECHAZADO o INEXISTENTE → consulta técnica
///    obligatoria (modal P2P) y persistencia del resultado crudo completo.
///  - Un resultado vencido/rechazado NUNCA bloquea consultas futuras: no se
///    trata como hit, por lo que cada consulta posterior vuelve a verificar
///    hasta que el vehículo pase a VIGENTE (y [forceRefresh] fuerza siempre).
class PrtService {
  static final PrtService instance = PrtService._();
  PrtService._();

  static const String baseUrl = 'https://api.studiodigital360.com';

  /// Parsea fechas es-ES: dd/mm/yyyy o dd-mm-yyyy. Null si es inválida.
  static DateTime? parseFechaEs(String? s) {
    final t = (s ?? '').trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(t);
    if (m == null) return null;
    final d = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final y = int.tryParse(m.group(3)!);
    if (d == null || mo == null || y == null) return null;
    final dt = DateTime(y, mo, d);
    if (dt.day != d || dt.month != mo) return null; // 31/02 → inválida
    return dt;
  }

  /// VIGENTE = resultado aprobado/vigente Y fecha de vigencia >= hoy.
  static bool isVigente(PrtVehiclePayload p) {
    final estado = p.rtEstado.toLowerCase();
    final aprobado = estado.contains('aprobad') || estado.contains('vigente');
    if (!aprobado) return false;
    final vig = parseFechaEs(p.rtVencimiento);
    if (vig == null) return false;
    final hoy = DateTime.now();
    final hoyIni = DateTime(hoy.year, hoy.month, hoy.day);
    return !vig.isBefore(hoyIni);
  }

  /// Método unificado: cache-first condicional + consulta fresca + persistencia.
  Future<PrtVehiclePayload?> getOrFetch(
    BuildContext context,
    String patente, {
    bool forceRefresh = false,
  }) async {
    final plateClean = patente.toUpperCase().trim();
    if (!forceRefresh) {
      final cached = await getCachedVigente(plateClean);
      if (cached != null) return cached;
    }
    final raw = await fetchFreshViaModal(context, plateClean);
    if (raw == null) return null;
    final payload = PrtVehiclePayload.fromJson(raw);
    await persist(plateClean, raw);
    return payload;
  }

  /// Devuelve el payload SOLO si está VIGENTE en caché; null si no existe,
  /// está vencido o fue rechazado (dispara consulta fresca).
  Future<PrtVehiclePayload?> getCachedVigente(String patente) async {
    try {
      final resp = await http
          .get(Uri.parse('$baseUrl/api/patente/${patente.toUpperCase()}?provider=prt'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final raw = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = (raw['data'] is Map<String, dynamic>)
          ? Map<String, dynamic>.from(raw['data'] as Map)
          : Map<String, dynamic>.from(raw);
      if (data.isEmpty) return null;
      final payload = PrtVehiclePayload.fromJson(data);
      return isVigente(payload) ? payload : null;
    } catch (e) {
      debugPrint('[PRT-CACHE] error leyendo caché: $e');
      return null;
    }
  }

  /// Presenta el modal P2P y espera el resultado crudo del pop.
  Future<Map<String, dynamic>?> fetchFreshViaModal(
    BuildContext context,
    String patente,
  ) async {
    try {
      FocusManager.instance.primaryFocus?.unfocus();
    } catch (_) {}
    try {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {}
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => PrtVerificationScreen(targetPlate: patente),
      ),
    );
    if (result is Map<String, dynamic>) return result;
    if (result is Map) return Map<String, dynamic>.from(result);
    return null;
  }

  /// Persiste el objeto CRUDO COMPLETO (claves vacías incluidas e historial
  /// íntegro) en PostgreSQL vía el endpoint de ingesta P2P.
  Future<void> persist(String patente, Map<String, dynamic> raw) async {
    try {
      await http
          .post(
            Uri.parse('$baseUrl/api/vehicle/cache'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'plate': patente, 'data': raw}),
          )
          .timeout(const Duration(seconds: 15));
      debugPrint('[PRT-CACHE] persistido $patente');
    } catch (e) {
      debugPrint('[PRT-CACHE] error persistiendo: $e');
    }
  }
}

/// Componente AISLADO y reutilizable de verificación PRT.
///
/// CONTRATO:
///  - Entrada única: [targetPlate] (patente normalizada).
///  - Salida limpia: al capturar los datos hace `Navigator.pop(context,
///    Map<String,dynamic>)` con el payload completo (envolver con
///    [PrtVehiclePayload.fromJson] para acceso tipado). Callbacks opcionales
///    [onVehicleSaved] / [onErrorNotFound] para integraciones de conveniencia.
///  - Sin dependencias rígidas: no referencia pantallas concretas; el
///    resultado se entrega por el pop o por los callbacks.
class PrtVerificationScreen extends StatefulWidget {
  final String targetPlate;
  final Function(Map<String, dynamic>)? onVehicleSaved;
  final VoidCallback? onErrorNotFound;

  const PrtVerificationScreen({
    super.key,
    required this.targetPlate,
    this.onVehicleSaved,
    this.onErrorNotFound,
  });

  @override
  State<PrtVerificationScreen> createState() => _PrtVerificationScreenState();
}

class _PrtVerificationScreenState extends State<PrtVerificationScreen> {
  late final WebViewController _controller;
  bool _pageLoaded = false;
  // Evita navegar repetidamente al mismo iframe detectado (anti-loop).
  bool _autoNavigatedToIframe = false;
  // Evita enviar el dump de diagnóstico más de una vez por pantalla.
  bool _debugSent = false;
  // Overlay nativo: mientras false se muestra el indicador de carga.
  bool _isReady = false;
  // Blindaje nativo anti-parpadeo: mientras true, un contenedor Flutter
  // 100% opaco (Color(0xFF0B132B) + spinner) cubre TODO el WebView. Se
  // activa con POSTBACK_START (justo antes del clic) y permanece hasta que
  // llegan los datos o el error, tapando la recarga completa de ASP.NET.
  bool _isProcessingPostback = false;
  // Popup de imágenes de Google abierto: oculta temporalmente la tarjeta de
  // la placa para que el desafío tenga todo el alto sin solaparse.
  bool _challengeOpen = false;
  // Temporizador de seguridad: si pasan 12s desde POSTBACK_START sin
  // respuesta (DATA/ERROR), cierra el modal. La app jamás queda congelada.
  Timer? _postbackSafetyTimer;
  Timer? _readyFallbackTimer;
  // TIMEOUT DE SEGURIDAD humano: 45s sin resolución exitosa del reCAPTCHA
  // (bucles infinitos de imágenes de Google) → emitir RECAPTCHA_TIMEOUT.
  Timer? _humanTimeout;
  // Watchdog de 6s para 'READY': si el script dinámico no completa el
  // aislamiento (CSS anti-flicker + isolateForm) y despacha 'READY', se
  // reintenta inyección/recarga automáticamente (máx. 2); si todo falla,
  // se muestra el botón nativo de reintentar. La pantalla de carga JAMÁS
  // se apaga sin el READY explícito del script.
  Timer? _readyWatchdog;
  int _readyReloads = 0;
  // Tras 15s sin READY, muestra botón de reintentar (no expone pantalla en blanco).
  bool _showRetryButton = false;
  // Evita que el timeout humano cierre un modal que ya emitió DATA/ERROR.
  bool _dataOrErrorSent = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted && !_pageLoaded) {
        setState(() => _pageLoaded = true);
      }
    });
    // Si tras 15s no llega 'READY', mostrar un botón nativo de reintentar;
    // el overlay SÍ se mantiene cubriendo (no se expone la pantalla en blanco).
    _readyFallbackTimer = Timer(const Duration(seconds: 15), () {
      if (mounted && !_isReady) {
        setState(() => _showRetryButton = true);
      }
    });
    // Timeout humano de 45s: si el modal sigue abierto sin DATA/ERROR, se
    // cierra con el evento RECAPTCHA_TIMEOUT (degrada con elegancia).
    _humanTimeout = Timer(const Duration(seconds: 45), () {
      if (mounted && !_dataOrErrorSent) {
        try {
          Navigator.of(context).pop(<String, dynamic>{
            '__prtEvent': 'RECAPTCHA_TIMEOUT',
          });
        } catch (_) {}
      }
    });
    // Crear el WebView con el modo de composición híbrido clásico forzado más
    // abajo (en el widget), que evita el lienzo en blanco del SurfaceTexture.
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0B132B))
      ..setUserAgent("Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36")
      ..enableZoom(false)
      ..addJavaScriptChannel(
        'PrtBridge',
        onMessageReceived: (JavaScriptMessage message) {
          final msg = message.message;
          if (msg.startsWith('{')) {
            try {
              final obj = jsonDecode(msg);
              if (obj is Map && obj['type'] == 'RECAPTCHA_QUOTA_EXCEEDED') {
                _humanTimeout?.cancel();
                if (mounted) {
                  Navigator.of(context).pop(<String, dynamic>{
                    '__prtEvent': 'RECAPTCHA_QUOTA_EXCEEDED',
                  });
                }
              }
            } catch (_) {}
          } else if (msg.startsWith('DATA:')) {
            try {
              _dataOrErrorSent = true;
              _humanTimeout?.cancel();
              _postbackSafetyTimer?.cancel();
              // Cierre OBLIGATORIO del teclado del SO antes de cerrar el
              // modal: el autofocus nativo de PRT puede levantar el teclado
              // al aterrizar la página de resultados; esto lo apaga al
              // instante en la misma llamada.
              if (mounted) {
                try {
                  FocusScope.of(context).unfocus();
                } catch (e) {
                  debugPrint('unfocus error: $e');
                }
                try {
                  SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
                } catch (e) {
                  debugPrint('TextInput.hide error: $e');
                }
                // Soltar también el foco nativo del PlatformView/WebView.
                try {
                  FocusManager.instance.primaryFocus?.unfocus();
                } catch (e) {
                  debugPrint('FocusManager unfocus error: $e');
                }
                // Trío completo: mover el foco a un FocusNode vacío para que
                // Android oculte el IME a nivel de ventana.
                try {
                  FocusScope.of(context).requestFocus(FocusNode());
                } catch (e) {
                  debugPrint('requestFocus error: $e');
                }
              }
              final jsonStr = msg.substring(5);
              final map = jsonDecode(jsonStr) as Map<String, dynamic>;

              // ===== VALIDACIÓN DE CONTENIDO → SIN REGISTRO =====
              // Si el payload PRT llega sin datos de vehículo (marca/modelo
              // vacíos), el sistema ministerial no registra la patente:
              // estado formal 'sin_registro' del pipeline PRT-First.
              final marca = (map['marca'] ?? '').toString().trim();
              final modelo = (map['modelo'] ?? '').toString().trim();
              if (marca.isEmpty && modelo.isEmpty) {
                debugPrint('[PRT] DATA sin datos de vehículo → sin registro');
                _humanTimeout?.cancel();
                if (mounted) {
                  Navigator.of(context).pop(<String, dynamic>{
                    '__prtEvent': 'PRT_SIN_REGISTRO',
                  });
                }
                return;
              }

              if (widget.onVehicleSaved != null) {
                widget.onVehicleSaved!(map);
              }
              if (mounted) {
                Navigator.of(context).pop(map);
              }
            } catch (e) {
              debugPrint('Error parsing PRT payload: $e');
            }
          } else if (msg.startsWith('ERROR:')) {
            _dataOrErrorSent = true;
            _humanTimeout?.cancel();
            debugPrint('[PRT] ${msg}');
          } else if (msg.startsWith('DEBUG:')) {
            // Reporte de depuración desde el JS inyectado (cross-frame prefill).
            debugPrint('[PRT-PREFILL] ${msg.substring(6)}');
          } else if (msg.startsWith('LOG:')) {
            // Consola remota en vivo: reenviar al backend para `docker logs -f`.
            debugPrint('[PRT-LOG] ${msg.substring(4)}');
            _sendRemoteLog(msg.substring(4));
          } else if (msg == 'READY') {
            // CONTRATO DE REVELADO: 'Preparando consulta técnica...' solo se
            // apaga aquí, con el READY explícito del script dinámico (patente
            // escrita + contenedor del captcha extraído a body y visible).
            _readyWatchdog?.cancel();
            if (!_isReady && mounted) {
              setState(() => _isReady = true);
            }
          } else if (msg == 'CHALLENGE_OPEN') {
            // Desafío de fotos abierto: ocultar la placa nativa (todo el
            // alto disponible para el popup de Google).
            if (mounted && !_challengeOpen) {
              setState(() => _challengeOpen = true);
            }
          } else if (msg == 'CHALLENGE_CLOSE') {
            if (mounted && _challengeOpen) {
              setState(() => _challengeOpen = false);
            }
          } else if (msg.startsWith('DISCOVER_IFRAME:')) {
            // Auto-descubrimiento de iframes del formulario PRT.
            final iframeUrl = msg.substring('DISCOVER_IFRAME:'.length).trim();
            debugPrint('[PRT-DISCOVER] $iframeUrl');
            _handleDiscoveredIframe(iframeUrl);
          } else if (msg == 'POSTBACK_START') {
            // El JS está a punto de hacer clic en Buscar: activar de inmediato
            // el contenedor nativo opaco que cubre el WebView durante todo el
            // postback + recarga completa (cero parpadeo de la web de PRT).
            if (mounted) {
              setState(() {
                _isProcessingPostback = true;
                _challengeOpen = false;
              });
            }
            // Forzar a Android a cerrar el teclado virtual POR COMPLETO en
            // esta misma llamada (no dejar que asome sobre el overlay).
            if (mounted) {
              try {
                FocusScope.of(context).unfocus();
              } catch (e) {
                debugPrint('unfocus error: $e');
              }
              try {
                SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
              } catch (e) {
                debugPrint('TextInput.hide error: $e');
              }
              // Soltar el foco nativo del PlatformView (el teclado que abrió
              // el WebView no responde a TextInput.hide de Flutter).
              try {
                FocusManager.instance.primaryFocus?.unfocus();
              } catch (e) {
                debugPrint('FocusManager unfocus error: $e');
              }
              try {
                FocusScope.of(context).requestFocus(FocusNode());
              } catch (e) {
                debugPrint('requestFocus error: $e');
              }
            }
            // Temporizador de seguridad: si en 12s no llega DATA/ERROR,
            // cerrar el modal (nunca quedar congelado en la animación).
            _postbackSafetyTimer?.cancel();
            _postbackSafetyTimer = Timer(const Duration(seconds: 12), () {
              if (mounted) {
                debugPrint('[PRT] timeout de seguridad del postback: cerrando modal');
                Navigator.of(context).pop();
              }
            });
          } else if (msg == 'ERROR:NOT_FOUND') {
            // Patente sin historial en el sistema ministerial PRT: cerrar el
            // modal con el estado formal 'sin_registro' (tile ministerial
            // del pipeline PRT-First).
            _postbackSafetyTimer?.cancel();
            _dataOrErrorSent = true;
            _humanTimeout?.cancel();
            if (mounted) {
              Navigator.of(context).pop(<String, dynamic>{
                '__prtEvent': 'PRT_SIN_REGISTRO',
              });
            }
          } else if (msg == 'ERROR:RATE_LIMIT') {
            // Google limitó temporalmente las verificaciones reCAPTCHA
            // ("Vuelve a intentarlo más tarde"): informar amigablemente y
            // cerrar de inmediato, sin dejar al usuario esperando.
            _postbackSafetyTimer?.cancel();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  backgroundColor: Color(0xFF1E293B),
                  content: Text(
                    'Google limitó temporalmente la verificación. Activa modo avión unos segundos o cambia de red e intenta nuevamente.',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  duration: Duration(seconds: 5),
                ),
              );
              Navigator.of(context).pop();
            }
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (progress > 60 && !_pageLoaded && mounted) {
              setState(() => _pageLoaded = true);
            }
          },
          onPageFinished: (url) {
            // Doble inyección DESACTIVADA: el bridge y la escritura mínima
            // hardcodeadas competían con el script dinámico del servidor.
            // Sólo se inyecta la versión dinámica (prt_injection.js).
            // _injectStableBridge();

            // IMPORTANTE (contrato anti-flicker): aquí NO se revela el
            // WebView. El overlay nativo solo se apaga con el mensaje
            // explícito 'READY' de PrtBridge, emitido por el script tras
            // inyectar el CSS anti-flicker y completar isolateForm().

            // Inyección dinámica desde el servidor (script editable sin rebuild).
            _fetchAndInjectDynamicScript();
            // Hook de consola: forward console.log/error/warn/info al backend.
            _controller.runJavaScript(
              "(function(){if(!window.__pfConsoleHooked){window.__pfConsoleHooked=true;"
              "['log','error','warn','info'].forEach(function(m){"
              "var orig=console[m];"
              "console[m]=function(){try{orig.apply(console,arguments);}catch(e){}"
              "try{var s=Array.prototype.map.call(arguments,function(a){return String(a);}).join(' ');"
              "if(window.PrtBridge)window.PrtBridge.postMessage('LOG:[console.'+m+'] '+s);}catch(e){}};"
              "});}})();"
            );
            // Retrasar la telemetría 4s para capturar el estado estabilizado
            // tras el prefill y los partial postbacks de ASP.NET.
            Future.delayed(const Duration(seconds: 4), () {
              if (mounted) _dumpDomToBackend();
            });
            if (mounted) {
              setState(() => _pageLoaded = true);
            }
          },
          onPageStarted: (url) {
            // Sin inyección de estilos/opacidad: dejar que la página pinte naturalmente.
          },
          onWebResourceError: (error) {
            // Uso de toString() para ser robusto ante diferencias de versión
            // del tipo WebResourceError (evita getters que pueden no existir).
            final desc = 'WEBRESOURCE_ERROR ${error.toString()}';
            debugPrint('[PRT-NET-ERROR] $desc');
            _sendRemoteLog('[PRT-NET-ERROR] $desc');
            if (mounted) {
              setState(() => _pageLoaded = true);
            }
          },
          onHttpError: (error) {
            final desc = 'HTTP_ERROR ${error.toString()}';
            debugPrint('[PRT-HTTP-ERROR] $desc');
            _sendRemoteLog('[PRT-HTTP-ERROR] $desc');
          },
        ),
      );

    // Limpieza preventiva de caché/cookies y carga inicial.
    _clearAndLoad();
    // Armado del watchdog de 6s para 'READY' (nunca revelar la web cruda).
    _armReadyWatchdog();
  }

  Future<void> _clearAndLoad() async {
    try {
      await _controller.clearCache();
      await _controller.clearLocalStorage();
      await WebViewCookieManager().clearCookies();
    } catch (e) {
      debugPrint('clearCache/cookies error: $e');
    }
    try {
      await _controller.loadRequest(Uri.parse('https://www.prt.cl/Paginas/RevisionTecnica.aspx'));
    } catch (e) {
      debugPrint('loadRequest error: $e');
      _sendRemoteLog('[PRT-LOAD-ERROR] $e');
    }
  }

  /// Maneja una URL de iframe descubierta desde el JS inyectado.
  ///
  /// Si la URL apunta al formulario real (contiene términos como 'consulta',
  /// 'revision', 'mtt', 'aspx', 'prt', etc.), navega el WebView directamente a
  /// ese iframe para que el formulario sea el documento raíz y elimine la
  /// restricción cross-origin. Se controla con [_autoNavigatedToIframe] para
  /// no volver a navegar si ya se redirigió una vez.
  void _handleDiscoveredIframe(String iframeUrl) {
    if (_autoNavigatedToIframe) return;
    if (iframeUrl.isEmpty) return;

    final lower = iframeUrl.toLowerCase();
    final keywords = ['consulta', 'revision', 'revisiontecnica', 'mtt', 'aspx', 'prt', 'patente', 'ppu', 'form'];
    final isFormUrl = keywords.any((k) => lower.contains(k));

    // Descarta explícitamente iframes que no son el formulario (recaptcha, ads, etc.).
    final isNoise = lower.contains('recaptcha') || lower.contains('google') || lower.contains('bframe');

    if (isFormUrl && !isNoise) {
      _autoNavigatedToIframe = true;
      debugPrint('[PRT-DISCOVER] Navegando a formulario directo: $iframeUrl');
      try {
        final uri = Uri.parse(iframeUrl);
        if (uri.hasScheme) {
          _controller.loadRequest(uri);
        }
      } catch (e) {
        debugPrint('[PRT-DISCOVER] Error navegando: $e');
        _autoNavigatedToIframe = false;
      }
    }
  }

  /// Envía un mensaje a la consola remota del backend (/api/debug/log).
  Future<void> _sendRemoteLog(String message) async {
    try {
      await http.post(
        Uri.parse('https://api.studiodigital360.com/api/debug/log'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'message': message}),
      ).timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('[PRT-LOG] error enviando: $e');
    }
  }

  /// Descarga el script de inyección dinámica del backend, reemplaza
  /// {{PLATE}} por la patente y lo ejecuta en el WebView. Si falla la red,
  /// usa un fallback mínimo de emergencia.
  Future<void> _fetchAndInjectDynamicScript() async {
    try {
      final resp = await http
          .get(Uri.parse(
              'https://api.studiodigital360.com/api/debug/prt-script.js?v=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode == 200) {
        final script = utf8.decode(resp.bodyBytes);
        final plate = widget.targetPlate.trim().toUpperCase();
        final filled = script.replaceAll('{{PLATE}}', plate);
        await _controller.runJavaScript(filled);
        debugPrint('[PRT-DYN] script inyectado (${filled.length} chars)');
      } else {
        debugPrint('[PRT-DYN] backend respondió ${resp.statusCode}, usando fallback');
        _runEmergencyFallback();
      }
    } catch (e) {
      debugPrint('[PRT-DYN] error descargando script: $e — usando fallback');
      _runEmergencyFallback();
    }
  }

  /// Fallback mínimo de emergencia si no se puede descargar el script dinámico.
  /// Escribe la patente y hace scroll (SharePoint #s4-workspace), pero NUNCA
  /// envía 'READY': sin el CSS anti-flicker + isolateForm del script dinámico
  /// está prohibido revelar el WebView (quedaría expuesta la web cruda de PRT).
  /// El watchdog de 6s reintentará la inyección/recarga; si todo falla, se
  /// muestra el botón nativo de reintentar.
  void _runEmergencyFallback() {
    final plate = widget.targetPlate.trim().toUpperCase();
    _controller.runJavaScript(
      "(function(){try{"
      // 1) Escribir patente.
      "var inp=document.getElementById('ContentPlaceHolder1_patenteInput');"
      "if(!inp){var all=document.querySelectorAll('input[type=text]');for(var i=0;i<all.length;i++){if(((all[i].id||'')+'|'+(all[i].name||'')).toLowerCase().indexOf('patente')!==-1){inp=all[i];break;}}}"
      "if(inp){"
      "try{var s=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;if(s){s.call(inp,'$plate');}else{inp.value='$plate';}}catch(e){inp.value='$plate';}"
      "inp.setAttribute('value','$plate');"
      "inp.dispatchEvent(new Event('input',{bubbles:true}));"
      "inp.dispatchEvent(new Event('change',{bubbles:true}));"
      "try{inp.focus();}catch(e){}"
      "}"
      // 2) Scroll solo en #s4-workspace (sin scrollIntoView).
      "try{window.scrollTo(0,0);document.documentElement.scrollTop=0;document.body.scrollTop=0;"
      "var ws=document.getElementById('s4-workspace');"
      "var t=document.getElementById('ContentPlaceHolder1_patenteInput');"
      "if(ws&&t){ws.scrollTop=Math.max(0,t.getBoundingClientRect().top+ws.scrollTop-80);}}catch(e){}"
      // 3) Forzar repintado (SIN liberar el overlay nativo).
      "try{window.dispatchEvent(new Event('resize'));}catch(e){}"
      "})();",
    );
  }

  /// Volca el DOM actual del WebView (URL, iframes, inputs y un preview del
  /// HTML) al backend de diagnóstico para su inspección remota.
  Future<void> _dumpDomToBackend() async {
    // Guarda anti-doble-reporte: una vez por pantalla.
    if (_debugSent) return;
    _debugSent = true;

    const String collectJs = r'''
      (function() {
        function safe(fn) { try { return fn(); } catch (e) { return null; } }
        var iframes = [];
        safe(function() {
          document.querySelectorAll('iframe').forEach(function(f) {
            iframes.push({ src: f.currentSrc || f.src || '', id: f.id || '', name: f.name || '' });
          });
        });
        var inputs = [];
        safe(function() {
          document.querySelectorAll('input').forEach(function(i) {
            inputs.push({
              id: i.id || '', name: i.name || '', type: i.type || '',
              className: (i.className && typeof i.className === 'string') ? i.className : '',
              placeholder: i.placeholder || ''
            });
          });
        });
        var html = '';
        safe(function() {
          html = document.documentElement ? document.documentElement.outerHTML : '';
          if (html.length > 50000) html = html.substring(0, 50000);
        });
        var url = '';
        safe(function() { url = window.location.href || ''; });

        // Lectura robusta del input de patente: por #id, por name exacto
        // (con doble escape de $ imposible; aquí el $ es literal al ser raw),
        // y finalmente por filtrado del texto visible. Lee la property .value.
        var plateInput = null;
        safe(function() {
          var el = null;
          try { el = document.getElementById('ContentPlaceHolder1_patenteInput'); } catch (e) {}
          if (!el) {
            try {
              var all = document.querySelectorAll('input');
              for (var i = 0; i < all.length; i++) {
                var nm = (all[i].name || '');
                var id = (all[i].id || '');
                if (all[i].type === 'text' &&
                    (nm.indexOf('patenteInput') !== -1 || id.indexOf('patenteInput') !== -1 || id.indexOf('ContentPlaceHolder1_patenteInput') !== -1)) {
                  el = all[i];
                  break;
                }
              }
            } catch (e) {}
          }
          if (el) {
            plateInput = {
              id: el.id || '',
              name: el.name || '',
              type: el.type || '',
              value: el.value || '',
              valueAttr: el.getAttribute('value') || '',
              visible: !!(el.offsetWidth || el.offsetHeight),
              maxlength: el.maxLength > 0 ? el.maxLength : (el.getAttribute('maxlength') || '')
            };
          }
        });
        return JSON.stringify({ url: url, iframes: iframes, inputs: inputs, html: html, plateInput: plateInput, prefillDone: !!window.__pfPrefillDone, injected: !!window.__pfInjected, injectionError: window.__pfInjectionError || null, steps: window.__pfSteps || [], minimalWrite: !!window.__pfMinimalWrite, minimalError: window.__pfMinimalError || null });
      })();
    ''';

    try {
      final result = await _controller.runJavaScriptReturningResult(collectJs);
      final String raw = result.toString();
      // El resultado viene como string JSON; si llega con comillas envolventes, limpiar.
      String decoded = raw;
      if (decoded.length >= 2 && decoded.startsWith('"') && decoded.endsWith('"')) {
        try { decoded = jsonDecode(decoded) as String; } catch (_) {}
      }
      final Map<String, dynamic> data = jsonDecode(decoded) as Map<String, dynamic>;

      final payload = {
        'tag': 'prt-dom-${widget.targetPlate}',
        'url': data['url'] ?? '',
        'iframes': data['iframes'] ?? [],
        'inputs': data['inputs'] ?? [],
        'html': data['html'] ?? '',
        // Campo extra para confirmar el prefill (no es parte del modelo base,
        // se ignora si el backend no lo conoce).
        'plate_input': data['plateInput'],
        'prefill_done': data['prefillDone'] ?? false,
        'injected': data['injected'] ?? false,
        'injection_error': data['injectionError'],
        'steps': data['steps'] ?? [],
        'minimal_write': data['minimalWrite'] ?? false,
        'minimal_error': data['minimalError'],
      };

      final resp = await http.post(
        Uri.parse('https://api.studiodigital360.com/api/debug/dump'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 8));
      debugPrint('[PRT-DUMP] backend status=${resp.statusCode} '
          'iframes=${(data['iframes'] as List?)?.length ?? 0} '
          'inputs=${(data['inputs'] as List?)?.length ?? 0} '
          'htmlLen=${(data['html'] as String?)?.length ?? 0}');
    } catch (e) {
      debugPrint('[PRT-DUMP] error: $e');
    }
  }

  void _injectStableBridge() {
    final plate = widget.targetPlate.trim().toUpperCase();
    final js = r"""
      (function(targetPlate) {
        try {
        // Marcadores de trazabilidad (ver _dumpDomToBackend).
        window.__pfInjected = true;
        window.__pfSteps = window.__pfSteps || [];
        window.__pfSteps.push('bridge_start');
        // 1. Meta viewport para anular zoom
        try {
          var meta = document.querySelector('meta[name="viewport"]');
          if (!meta) {
            meta = document.createElement('meta');
            meta.name = 'viewport';
            document.head.appendChild(meta);
          }
          meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
        } catch(e) {}
        window.__pfSteps = window.__pfSteps || [];
        window.__pfSteps.push('viewport_ok');

        // 1b. Auto-descubrimiento de iframes del formulario PRT.
        //     Reporta cada <iframe> (src/currentSrc) a Flutter vía PrtBridge
        //     para que el WebView navegue directo al formulario si aplica.
        var __pfReportedIframes = {};
        function discoverIframes() {
          try {
            var iframes = Array.from(document.querySelectorAll('iframe'));
            for (var i = 0; i < iframes.length; i++) {
              var src = '';
              try { src = iframes[i].currentSrc || iframes[i].src || ''; } catch (e) {}
              if (!src) continue;
              // Normalizar URLs relativas a absolutas.
              try { src = new URL(src, document.baseURI).href; } catch (e) {}
              if (!src || __pfReportedIframes[src]) continue;
              __pfReportedIframes[src] = true;
              if (window.PrtBridge && window.PrtBridge.postMessage) {
                window.PrtBridge.postMessage('DISCOVER_IFRAME:' + src);
              }
            }
          } catch (e) {}
        }
        discoverIframes();
        window.__pfSteps.push('discover_ok');
        // Reintentar descubrimiento ante cambios dinámicos del DOM.
        var __pfDiscoverTimer = setInterval(discoverIframes, 1000);
        setTimeout(function() { clearInterval(__pfDiscoverTimer); }, 15000);

        // 2. Función de limpieza y centrado indestructible (resistente a recargas de SharePoint)
        function applyCardIsolation() {
          var styleId = "pf-invincible-shield";
          var existing = document.getElementById(styleId);
          if (!existing) {
            var st = document.createElement("style");
            st.id = styleId;
            st.innerHTML = `
              /* Fondo general de la app */
              html, body {
                background-color: #0F172A !important;
                margin: 0 !important;
                padding: 0 !important;
                overflow: hidden !important;
                touch-action: none !important;
                user-select: none !important;
                width: 100vw !important;
                height: 100vh !important;
              }

              /* Ocultar solo el chrome irrelevante de SharePoint (NO el panel
                 de consulta ni el input, que viven dentro de #paginas) */
              #s4-workspace, #s4-bodyContainer, #banner, #menu,
              #DeltaPlaceHolderUtilityContent, div[id*="UtilityContent"],
              .ms-standardheader, .auto-style1 {
                display: none !important;
              }

              /* Fijar y centrar la caja de reCAPTCHA como tarjeta única flotante */
              #ContentPlaceHolder1_divcaptcha {
                display: flex !important;
                position: fixed !important;
                top: 0 !important;
                left: 0 !important;
                width: 100vw !important;
                height: 100vh !important;
                z-index: 2147483647 !important;
                background: #0F172A !important;
                justify-content: center !important;
                align-items: center !important;
                margin: 0 !important;
                padding: 0 !important;
                visibility: visible !important;
              }

              #ReCaptchContainer, .g-recaptcha, iframe[src*="recaptcha"] {
                display: block !important;
                visibility: visible !important;
                transform: scale(1.18) !important;
                transform-origin: center center !important;
                box-shadow: 0 10px 30px -5px rgba(0, 0, 0, 0.8) !important;
                border-radius: 6px !important;
              }
            `;
            if (document.head) {
              document.head.appendChild(st);
            }
          }

          // Si el contenedor del captcha está dentro de la jerarquía oculta de SharePoint,
          // forzar su visibilidad al nivel de body
          var cap = document.getElementById("ContentPlaceHolder1_divcaptcha");
          if (cap && cap.parentElement !== document.body) {
            document.body.appendChild(cap);
          }
        }

        // Aplicar inmediatamente y mantener activo contra recargas de SharePoint
        applyCardIsolation();
        var shieldInterval = setInterval(applyCardIsolation, 150);
        setTimeout(function() { clearInterval(shieldInterval); }, 20000);

        // 3. Rellenar la patente de forma 100% dinámica y resiliente,
        //    atravesando marcos (iframe) de forma recursiva.
        var KEYWORDS = ['patente', 'plate', 'ppr', 'placa', 'ppu', 'valor'];
        var plateValue = targetPlate.toUpperCase();

        function dbg(txt) {
          try {
            if (window.PrtBridge && window.PrtBridge.postMessage) {
              window.PrtBridge.postMessage('DEBUG:' + txt);
            }
          } catch (e) {}
        }

        function isVisible(el, win) {
          if (!el) return false;
          var w = win || window;
          try {
            var rect = el.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) return false;
            var style = w.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
            return true;
          } catch (e) { return false; }
        }

        function tokenize(attrs) {
          return (attrs || '').toLowerCase();
        }

        function matchScore(input) {
          var id = input.id || '';
          var name = input.name || '';
          var placeholder = input.placeholder || '';
          var aria = input.getAttribute('aria-label') || '';
          var cls = input.className || '';
          var haystack = tokenize(id + ' ' + name + ' ' + placeholder + ' ' + aria + ' ' + cls);
          var score = 0;
          for (var i = 0; i < KEYWORDS.length; i++) {
            if (haystack.indexOf(KEYWORDS[i]) !== -1) score += 2;
          }
          return score;
        }

        // Describe un input para los logs de depuración.
        function describeInput(el) {
          try {
            return (
              (el.tagName ? el.tagName.toLowerCase() : 'input') +
              '[id=' + (el.id || '') +
              ',name=' + (el.name || '') +
              ',placeholder=' + (el.placeholder || '') +
              ',aria=' + (el.getAttribute('aria-label') || '') +
              ',class=' + (el.className ? String(el.className).slice(0, 40) : '') +
              ']'
            );
          } catch (e) { return 'input?'; }
        }

        function findPlateInputInDoc(doc, win) {
          if (!doc) return null;
          try {
            // 0) Prioridad máxima: IDs exactos conocidos del formulario PRT
            //    (confirmados por el dump real del móvil). No exige visibilidad
            //    porque el CSS de aislamiento puede ocultar contenedores padre.
            var exactSelectors = [
              'input#ContentPlaceHolder1_patenteInput',
              'input[name="ctl00$ContentPlaceHolder1$patenteInput"]',
              'input[name="ctl00\x24ContentPlaceHolder1\x24patenteInput"]'
            ];
            for (var s = 0; s < exactSelectors.length; s++) {
              try {
                var exact = doc.querySelector(exactSelectors[s]);
                if (exact) return exact;
              } catch (e) {}
            }
            // También por coincidencia parcial de id/name en inputs de texto.
            var allTextInputs = Array.from(doc.querySelectorAll('input[type="text"], input[type="search"], input:not([type])'));
            for (var t = 0; t < allTextInputs.length; t++) {
              var inTxt = allTextInputs[t];
              var hayExact = ((inTxt.id || '') + ' ' + (inTxt.name || '')).toLowerCase();
              if (hayExact.indexOf('patenteinput') !== -1) return inTxt;
            }

            var candidates = allTextInputs.filter(function(el) { return isVisible(el, win); });

            var scored = candidates
              .map(function(el) { return { el: el, score: matchScore(el) }; })
              .filter(function(x) { return x.score > 0; })
              .sort(function(a, b) { return b.score - a.score; });

            if (scored.length > 0) return scored[0].el;

            var forms = Array.from(doc.querySelectorAll('form'));
            for (var f = 0; f < forms.length; f++) {
              var ins = Array.from(forms[f].querySelectorAll('input[type="text"], input[type="search"], input:not([type])'));
              for (var i = 0; i < ins.length; i++) {
                if (isVisible(ins[i], win)) return ins[i];
              }
            }
            return candidates[0] || null;
          } catch (e) { return null; }
        }

        // Contextos de búsqueda: documento raíz + todos los iframes (recursivo).
        function collectContexts() {
          var contexts = [{ doc: document, win: window, label: 'root' }];
          var seen = new Set();
          try { seen.add(window); } catch (e) {}

          function addFrameContext(win, label) {
            if (!win) return;
            try {
              if (seen.has(win)) return;
              seen.add(win);
            } catch (e) {}
            var doc = null;
            try { doc = win.document; } catch (e) { return; } // cross-origin / acceso denegado
            if (!doc) return;
            contexts.push({ doc: doc, win: win, label: label || 'iframe' });
            // Recurrir en sub-frames.
            try {
              for (var i = 0; i < win.frames.length; i++) {
                addFrameContext(win.frames[i], (label || 'iframe') + '>' + i);
              }
            } catch (e) {}
          }

          // 1) window.frames
          try {
            for (var f = 0; f < window.frames.length; f++) {
              addFrameContext(window.frames[f], 'frame[' + f + ']');
            }
          } catch (e) {}
          // 2) iframes del documento
          try {
            var iframes = Array.from(document.querySelectorAll('iframe'));
            for (var j = 0; j < iframes.length; j++) {
              try {
                var cw = iframes[j].contentWindow;
                if (cw) addFrameContext(cw, 'iframe#' + (iframes[j].id || iframes[j].src || j));
              } catch (e) {}
            }
          } catch (e) {}

          return contexts;
        }

        function setInputValueViaFrame(inp, win) {
          // Escritura a bajo nivel y robusta para ASP.NET/jQuery.
          // 1) Asignar la propiedad .value (vía setter de prototipo del frame).
          try {
            var proto = (win && win.HTMLInputElement) ? win.HTMLInputElement.prototype : window.HTMLInputElement.prototype;
            var protoSetter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            if (protoSetter) {
              protoSetter.call(inp, plateValue);
            } else {
              inp.value = plateValue;
            }
          } catch (e) {
            try { inp.value = plateValue; } catch (e2) {}
          }

          // 2) Asignar también el atributo HTML value (reflejo en el markup).
          try { inp.setAttribute('value', plateValue); } catch (e) {}

          // 3) Disparar la secuencia completa de eventos de teclado nativos,
          //    para que cualquier listener (jQuery/ASP.NET) valide el campo.
          function fire(type) {
            try {
              var ev = document.createEvent('Event');
              ev.initEvent(type, true, true);
              inp.dispatchEvent(ev);
            } catch (e) {}
          }
          fire('focus');
          fire('keydown');
          fire('keypress');
          fire('input');
          fire('keyup');
          fire('change');
          fire('blur');

          // 4) Compatibilidad jQuery: forzar valor y evento change.
          try {
            if (window.jQuery && window.jQuery.fn && window.jQuery.fn.val) {
              window.jQuery(inp).val(plateValue).trigger('change');
            }
          } catch (e) {}

          // 5) Foco directo y selección (confirma visualmente el valor).
          try { inp.focus(); inp.select(); } catch (e) {}

          try { inp.setAttribute('data-pf-prefilled', '1'); } catch (e) {}
        }

        // Recorre TODOS los contextos y aplica el valor. Devuelve info de debug.
        function fillAcrossFrames() {
          var contexts = collectContexts();
          var found = null;
          var bestScore = -1;

          for (var c = 0; c < contexts.length; c++) {
            var ctx = contexts[c];
            var inp = findPlateInputInDoc(ctx.doc, ctx.win);
            if (inp) {
              var sc = matchScore(inp);
              if (sc > bestScore) {
                bestScore = sc;
                found = { inp: inp, ctx: ctx, score: sc };
              }
            }
          }

          if (found) {
            setInputValueViaFrame(found.inp, found.ctx.win);
            var ok = false;
            try { ok = found.inp.value.toUpperCase() === plateValue; } catch (e) {}
            if (ok) {
              try { window.__pfPrefillDone = true; } catch (e) {}
            }
            dbg('OK frame=' + found.ctx.label +
                ' selector=' + describeInput(found.inp) +
                ' score=' + found.score +
                ' valueSet=' + ok);
            return found.ctx.label + ' | ' + describeInput(found.inp);
          }

          dbg('NOT_FOUND contexts=' + contexts.length);
          return null;
        }

        // ===== Bucle agresivo de escritura anti-limpieza =====
        window.__pfSteps.push('before_write');
        // Escribe directamente en el documento raíz (donde vive el input).
        function writePlateOnce() {
          var inp = findPlateInputInDoc(document, window);
          if (inp) {
            setInputValueViaFrame(inp, window);
          }
          return inp;
        }

        var startTime = Date.now();
        var REAPPLY_FOR_MS = 8000;
        var REAPPLY_EVERY_MS = 400;

        function reapplyLoop() {
          var inp = writePlateOnce();
          var stillEmpty = false;
          if (inp) {
            try { stillEmpty = inp.value.toUpperCase() !== plateValue; } catch (e) {}
          }
          var elapsed = Date.now() - startTime;
          // Continuar mientras no se cumpla la ventana o el campo siga vacío.
          if (elapsed < REAPPLY_FOR_MS || stillEmpty) {
            setTimeout(reapplyLoop, REAPPLY_EVERY_MS);
          } else {
            dbg('DONE windowElapsed=' + elapsed + 'ms value=' + (inp ? inp.value : 'nula'));
          }
        }
        reapplyLoop();

        // Enganche al ciclo de vida de ASP.NET AJAX (Sys.WebForms): reescribir
        // la patente cada vez que un UpdatePanel termine de procesar/redibujar.
        try {
          if (window.Sys && window.Sys.WebForms && window.Sys.WebForms.PageRequestManager) {
            var prm = window.Sys.WebForms.PageRequestManager.getInstance();
            if (prm && prm.add_endRequest) {
              prm.add_endRequest(function() {
                writePlateOnce();
              });
            }
          }
        } catch (e) {}

        // Listener sobre el propio input: si un evento lo deja en blanco,
        // reasignar de inmediato.
        function attachInputGuard() {
          var inp = findPlateInputInDoc(document, window);
          if (!inp) return false;
          var guard = function() {
            try {
              if (inp.value.toUpperCase() !== plateValue) {
                setInputValueViaFrame(inp, window);
              }
            } catch (e) {}
          };
          try {
            inp.addEventListener('change', guard);
            inp.addEventListener('input', guard);
            inp.addEventListener('blur', guard);
          } catch (e) {}
          return true;
        }
        // Reintentar adjuntar el guard ya que el input puede aparecer más tarde.
        var guardTimer = setInterval(function() {
          if (attachInputGuard()) clearInterval(guardTimer);
        }, 400);
        setTimeout(function() { clearInterval(guardTimer); }, 8000);

        // MutationObserver: reintentar ante cambios dinámicos del DOM (frame raíz).
        if (window.MutationObserver) {
          var observer = new MutationObserver(function() {
            writePlateOnce();
          });
          try {
            observer.observe(document.body || document.documentElement, {
              childList: true,
              subtree: true,
            });
          } catch (e) {}
          setTimeout(function() { try { observer.disconnect(); } catch (e) {} }, 12000);
        }

        // Scroll automático suave hacia el reCAPTCHA si ya está renderizado.
        function scrollToCaptchaIfReady() {
          var cap = null;
          try {
            cap = document.querySelector(
              '.g-recaptcha, iframe[src*="recaptcha"], [id*="captcha"], #ContentPlaceHolder1_divcaptcha'
            );
          } catch (e) {}
          if (cap && isVisible(cap)) {
            try { cap.scrollIntoView({ behavior: 'smooth', block: 'center' }); }
            catch (e) { try { cap.scrollIntoView(); } catch (e2) {} }
            return true;
          }
          return false;
        }
        scrollToCaptchaIfReady();

        // 4. Polling extractor de datos de Revisión Técnica
        if (!window.__prtWatcherActive) {
          window.__prtWatcherActive = true;
          var pollInterval = setInterval(function() {
            var bodyText = document.body.innerText || '';
            if (bodyText.includes('La placa ingresada no existe') || bodyText.includes('no existe registro')) {
              clearInterval(pollInterval);
              if (window.PrtBridge) {
                window.PrtBridge.postMessage('ERROR:NOT_FOUND');
              }
              return;
            }

            var container = document.getElementById('ContentPlaceHolder1_lblDatosVehiculo');
            if (!container) return;

            var labels = Array.from(container.querySelectorAll('label'));
            var spans = Array.from(container.querySelectorAll('span'));
            if (labels.length === 0 && spans.length === 0) return;

            var map = {};
            for (var i = 0; i < labels.length; i++) {
              var key = labels[i].innerText.replace(':', '').replace('.', '').trim().toLowerCase();
              var val = spans[i] ? spans[i].innerText.trim() : '';
              if (key) {
                map[key] = val;
              }
            }

            var marca = map['marca'] || '';
            var modelo = map['modelo'] || '';
            var motor = map['n° motor'] || map['n motor'] || map['motor'] || '';
            var chasis = map['n° chasis'] || map['n chasis'] || map['chasis'] || '';

            if (marca !== '' || modelo !== '' || motor !== '' || chasis !== '') {
              var rtTable = Array.from(document.querySelectorAll('table')).find(function(t) {
                return t.innerText.includes('Fecha') && t.innerText.includes('Nro.Certificado');
              });

              var historial = [];
              if (rtTable) {
                var allRows = Array.from(rtTable.querySelectorAll('tr')).slice(1);
                allRows.forEach(function(row) {
                  var tds = Array.from(row.querySelectorAll('td')).map(function(c) { return c.innerText.trim(); });
                  if (tds.length >= 6) {
                    historial.push({
                      fecha: tds[0],
                      cod_planta: tds[1],
                      planta: tds[2],
                      certificado: tds[3].replace(/
/g, ' ').trim(),
                      vencimiento: tds[4],
                      estado: tds[5]
                    });
                  }
                });
              }

              clearInterval(pollInterval);
              var payload = {
                patente: targetPlate,
                tipo: map['tipo'] || '',
                marca: marca,
                modelo: modelo,
                anio: map['año fab'] || map['año de fabricacion'] || map['año'] || '',
                nro_motor: motor,
                chasis: chasis,
                vin: map['n° vin'] || map['n vin'] || map['vin'] || '',
                sello: map['tipo sello'] || map['sello'] || '',
                historial_rt: historial,
                rt_vencimiento: historial.length > 0 ? historial[0].vencimiento : '',
                rt_estado: historial.length > 0 ? historial[0].estado : '',
                fuente: 'PRT Oficial'
              };

              if (window.PrtBridge) {
                window.PrtBridge.postMessage('DATA:' + JSON.stringify(payload));
              }
            }
          }, 300);
        }
        window.__pfSteps.push('bridge_end');
        } catch (err) {
          try {
            window.__pfInjectionError = String(err) + ' | ' + String(err && err.stack ? err.stack : '');
          } catch (e2) {}
          try { window.__pfSteps.push('error:' + String(err)); } catch (e3) {}
        }
      })('""" + plate + r"""');
    """;
    _controller.runJavaScript(js);
  }

  @override
  void dispose() {
    _readyFallbackTimer?.cancel();
    _humanTimeout?.cancel();
    _readyWatchdog?.cancel();
    _postbackSafetyTimer?.cancel();
    super.dispose();
  }

  /// Construye los params de creación del WebViewWidget usando la composición
  /// virtual de textura nativa por defecto de Flutter (displayWithHybridComposition
  /// = false), para evitar el freeze de renderizado del compositor en algunos
  /// dispositivos Android.
  PlatformWebViewWidgetCreationParams _hybridCompositionParams() {
    PlatformWebViewWidgetCreationParams params = PlatformWebViewWidgetCreationParams(
      controller: _controller.platform,
      layoutDirection: TextDirection.ltr,
    );
    if (WebViewPlatform.instance is AndroidWebViewPlatform) {
      params = AndroidWebViewWidgetCreationParams.fromPlatformWebViewWidgetCreationParams(
        params,
        displayWithHybridComposition: false,
      );
    }
    return params;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      // La pantalla de verificación NUNCA redimensiona su viewport ante la
      // presencia del teclado: el IME no puede desplazar ni invadir el layout.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Consulta Técnica PRT',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            Text(
              'Patente: ' + widget.targetPlate,
              style: const TextStyle(fontSize: 12, color: Color(0xFF38BDF8)),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        // Botón secundario visible: omitir la verificación sin demoras.
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF94A3B8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              child: const Text(
                'CONTINUAR SIN PRT',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.6),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Fondo nativo del modal.
          const ColoredBox(color: Color(0xFF0B132B)),

          // Columna limpia: banner nativo arriba + WebView ocupando TODO el
          // resto del espacio de forma transparente. Sin marcos decorativos
          // ni lucha geométrica entre capas: Flutter solo muestra la patente
          // nativa; el WebView centra el reCAPTCHA orgánicamente (JS flex).
          Column(
            children: [
              // Banner nativo: instrucción + placa patente estilizada. Se
              // oculta durante el desafío de fotos (CHALLENGE_OPEN) para que
              // el popup de Google tenga todo el alto sin solaparse.
              if (!_challengeOpen)
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Confirma la verificación para consultar',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Contenedor nativo tipo placa premium, ancho completo.
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFF38BDF8).withOpacity(0.45),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF38BDF8).withOpacity(0.18),
                                blurRadius: 20,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Text(
                            widget.targetPlate,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 6,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // WebView siempre a tamaño real (nunca 0x0), ocupando el
              // espacio restante bajo la placa.
              Expanded(
                child: WebViewWidget.fromPlatformCreationParams(
                  params: _hybridCompositionParams(),
                ),
              ),
            ],
          ),

          // Blindaje nativo anti-parpadeo: cubre absolutamente todo el
          // WebView (por encima de él) mientras ASP.NET hace el postback y
          // la recarga completa de página. Hace físicamente imposible ver
          // la web de PRT o el teclado durante la transición. El interior es
          // la telemetría ejecutiva premium (pulso cian/verde + estados).
          if (_isProcessingPostback) const _ExecutiveTelemetryOverlay(),

          // Capa de carga inicial (telemetría premium) que se DESVANECE por
          // encima del WebView al recibir READY: fundido suave de 350ms sin
          // saltos, mientras el WebView mantiene siempre su tamaño real.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _isReady,
              child: AnimatedOpacity(
                opacity: _isReady ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 350),
                child: _ExecutiveTelemetryOverlay(
                  states: const ['Estableciendo enlace seguro PRT...'],
                  rotateStates: false,
                  showRetry: _showRetryButton,
                  onRetry: _retryLoad,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _retryLoad() {
    setState(() {
      _showRetryButton = false;
      _isReady = false;
    });
    // Reiniciar contadores del watchdog de READY.
    _readyReloads = 0;
    _armReadyWatchdog();
    // Recargar la página PRT y reiniciar la inyección.
    try {
      _controller.loadRequest(Uri.parse('https://www.prt.cl/Paginas/RevisionTecnica.aspx'));
    } catch (e) {
      debugPrint('Error reintentando: $e');
    }
    // Reiniciar el temporizador de reintento.
    _readyFallbackTimer?.cancel();
    _readyFallbackTimer = Timer(const Duration(seconds: 15), () {
      if (mounted && !_isReady) {
        setState(() => _showRetryButton = true);
      }
    });
  }

  /// Watchdog de 6 segundos para 'READY': si el script dinámico no ha
  /// completado el aislamiento (CSS anti-flicker + isolateForm) y despachado
  /// 'READY', se reintenta la inyección y se recarga la página. La pantalla
  /// nativa de carga JAMÁS se apaga sin el READY explícito del script.
  void _armReadyWatchdog() {
    _readyWatchdog?.cancel();
    _readyWatchdog = Timer(const Duration(seconds: 6), () {
      if (!mounted || _isReady) return;
      debugPrint('[PRT] 6s sin READY: reintento ${_readyReloads + 1}/2');
      if (_readyReloads < 2) {
        _readyReloads++;
        // Reinyectar el script y recargar para partir de un estado limpio.
        _fetchAndInjectDynamicScript();
        _controller.loadRequest(Uri.parse('https://www.prt.cl/Paginas/RevisionTecnica.aspx'));
        _armReadyWatchdog();
      } else {
        setState(() => _showRetryButton = true);
      }
    });
  }
}

/// Telemetría ejecutiva premium mostrada sobre el WebView durante el
/// postback de PRT: isotipo con halo de pulso cian/verde, título corporativo,
/// rotación de estados técnicos con fade y barra de progreso con gradiente.
class _ExecutiveTelemetryOverlay extends StatefulWidget {
  const _ExecutiveTelemetryOverlay({
    this.title = 'PARTFINDER 360 INTELLIGENCE',
    this.states = const [
      'Estableciendo enlace seguro PRT...',
      'Decodificando historial y ficha técnica...',
      'Sincronizando especificaciones del vehículo...',
    ],
    this.rotateStates = true,
    this.showRetry = false,
    this.onRetry,
  });

  /// Título corporativo mostrado bajo el isotipo.
  final String title;

  /// Estados técnicos rotativos del subtítulo.
  final List<String> states;

  /// Si false, el subtítulo queda fijo en [states].first.
  final bool rotateStates;

  /// Muestra el botón nativo de reintentar (pantalla de carga inicial).
  final bool showRetry;

  /// Acción del botón de reintentar.
  final VoidCallback? onRetry;

  @override
  State<_ExecutiveTelemetryOverlay> createState() =>
      _ExecutiveTelemetryOverlayState();
}

class _ExecutiveTelemetryOverlayState extends State<_ExecutiveTelemetryOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  int _stateIndex = 0;
  Timer? _stateTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    if (widget.rotateStates && widget.states.length > 1) {
      _stateTimer = Timer.periodic(const Duration(milliseconds: 2300), (_) {
        if (mounted) {
          setState(() => _stateIndex = (_stateIndex + 1) % widget.states.length);
        }
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _stateTimer?.cancel();
    super.dispose();
  }

  /// Anillo expansivo del halo de pulso. [phase] intercala las ondas:
  /// 0.0 para el cian, 0.5 para el verde (desfasadas medio período).
  Widget _pulseRing(Color color, double phase) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final t = (_pulseController.value + phase) % 1.0;
        final scale = 1.0 + t * 1.9;
        final opacity = (1.0 - t) * 0.45;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color.withOpacity(opacity), width: 2),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0B132B),
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Isotipo con halo de pulso cian + verde intercalados.
            SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _pulseRing(const Color(0xFF38BDF8), 0.0),
                  _pulseRing(const Color(0xFF10B981), 0.5),
                  Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF38BDF8), Color(0xFF10B981)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF38BDF8).withOpacity(0.45),
                          blurRadius: 30,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.speed, color: Colors.white, size: 36),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            // Título corporativo en negrita.
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 14),
            // Subtítulo rotativo con fade entre estados técnicos.
            SizedBox(
              height: 44,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: Text(
                    widget.states[_stateIndex],
                    key: ValueKey<int>(_stateIndex),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 13,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            // Barra de progreso lineal delgada, bordes redondeados y
            // gradiente cian/azul (ShaderMask sobre LinearProgressIndicator).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 3,
                  child: ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(
                      colors: [Color(0xFF38BDF8), Color(0xFF2563EB)],
                    ).createShader(rect),
                    blendMode: BlendMode.srcIn,
                    child: const LinearProgressIndicator(
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            // Botón nativo de reintentar (solo en la pantalla de carga).
            if (widget.showRetry) ...[
              const SizedBox(height: 22),
              ElevatedButton.icon(
                onPressed: widget.onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
