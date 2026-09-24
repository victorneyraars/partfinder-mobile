import 'dart:math';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


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
    with SingleTickerProviderStateMixin {
  String _selectedEngine = 'prt';
  final TextEditingController _plateController = TextEditingController(text: _getFreshRandomChileanPlate());
  final FocusNode _focusNode = FocusNode();
  
  late AnimationController _scannerController;
  late Animation<double> _scannerAnimation;
  
  bool _isLoading = false;
  Map<String, dynamic>? _siiData;
  bool _isLoadingSii = false;

  Map<String, dynamic>? _vehicleData;
  String _activeFormat = "AUTO NUEVO (4L+2N)";

  
  Map<String, dynamic>? _boostrStatus;

  Future<void> _fetchBoostrTelemetry() async {
    try {
      final res = await http.get(
        Uri.parse('http://91.99.145.70:8000/api/boostr/status'),
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
    final initPlate = _getFreshRandomChileanPlate();
    _plateController.text = initPlate;
    _evalPlateFormat();
    
    
    _scannerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _scannerAnimation = Tween<double>(begin: -1.0, end: 1.0).animate(
      CurvedAnimation(parent: _scannerController, curve: Curves.easeInOut),
    );
    _plateController.addListener(_evalPlateFormat);
  }

  @override
  void dispose() {
    _scannerController.dispose();
    _plateController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _evalPlateFormat() {
    final text = _plateController.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    setState(() {
      if (RegExp(r'^[B-DF-HJ-NP-TV-Z]{4}\d{2}$').hasMatch(text)) {
        _activeFormat = "AUTO NUEVO (4L+2N)";
      } else if (RegExp(r'^[A-Z]{2}\d{4}$').hasMatch(text)) {
        _activeFormat = "CLÁSICO (2L+4N)";
      } else if (RegExp(r'^[A-Z]{3}\d{2,3}$').hasMatch(text)) {
        _activeFormat = "MOTO";
      } else if (text.isNotEmpty) {
        _activeFormat = "INGRESANDO...";
      } else {
        _activeFormat = "SIN FORMATO";
      }
    });
  }

  
  Future<void> _fetchSiiTasacion(String? marca, String? modelo, dynamic anio) async {
    if (marca == null || modelo == null || anio == null) return;
    setState(() => _isLoadingSii = true);
    try {
      final uri = Uri.parse('http://91.99.145.70:8000/api/tasacion?marca=${Uri.encodeComponent(marca)}&modelo=${Uri.encodeComponent(modelo)}&anio=$anio');
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
    });
    _scannerController.repeat(reverse: true);

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final url = Uri.parse('http://91.99.145.70:8000/api/patente/$rawPlate?provider=$_selectedEngine');
      final request = await client.getUrl(url);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final Map<String, dynamic> raw = json.decode(body);
        final v = raw['data'] != null && raw['data'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(raw['data'])
            : Map<String, dynamic>.from(raw);

        if (v.isNotEmpty && (v['make'] != null || v['marca'] != null || v['modelo'] != null)) {
          v['data_source'] = raw['data_source'] ?? (raw['source'] == 'database' ? 'CACHE_LOCAL' : (_selectedEngine == 'prt' ? 'PRT_SCRAPING' : 'BOOSTR_API'));
          final plate = raw['plate'] ?? raw['patente'] ?? rawPlate;
          v['patente'] = plate;

          // ===== CACHÉ INTELIGENTE (regla condicional) =====
          // Registro PRT en caché PERO VENCIDO/RECHAZADO → la política exige
          // consulta técnica fresca obligatoria (el modal re-abre el WebView).
          // VIGENTE → se usa el registro cacheado sin consumir reCAPTCHA.
          final isPrtRecord = (v['fuente'] == 'PRT Oficial') ||
              (v['rt_estado'] != null && v['rt_estado'].toString().isNotEmpty) ||
              (v['rt_vencimiento'] != null && v['rt_vencimiento'].toString().isNotEmpty);
          if (isPrtRecord && !PrtService.isVigente(PrtVehiclePayload.fromJson(v))) {
            _openPrtVerificationScreen(rawPlate);
            return;
          }

          setState(() {
            
      // Consultar tasacion fiscal SII
      final sMarca = v['marca']?.toString();
      final sModelo = v['modelo']?.toString();
      final sAnio = v['anio'] ?? v['year'];
      _fetchSiiTasacion(sMarca, sModelo, sAnio);
_vehicleData = v;
          });
          _fetchBoostrTelemetry();
        } else {
          _showSnack('No se encontraron especificaciones para $rawPlate');
        }
      } else if (response.statusCode == 404) {
        // Contrato formal frontend-backend: el backend responde con
        //   { detail: { error: "not_cached", message: ..., require_prt_solve: true } }
        // para indicar que la patente NO está cacheada y debe resolverse P2P
        // desde el navegador del móvil (IP residencial), no desde el backend.
        bool requirePrtSolve = false;
        try {
          final dynamic errJson = jsonDecode(body);
          if (errJson is Map) {
            final detail = errJson['detail'];
            requirePrtSolve =
                errJson['require_prt_solve'] == true ||
                (detail is Map && detail['require_prt_solve'] == true);
          }
        } catch (_) {}

        // Abrir el resolver P2P si el motor es PRT o si el backend lo solicita
        // explícitamente (require_prt_solve), independientemente del switch.
        if (requirePrtSolve || _selectedEngine == 'prt') {
          _openPrtVerificationScreen(rawPlate);
          return;
        }
        _showSnack('Patente no encontrada en el registro oficial');
      } else {
        _showSnack('Error del servidor (${response.statusCode})');
      }
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

            // 1. Guardar en PostgreSQL via backend (endpoint de ingesta directa)
            final plateClean = _plateController.text.trim().toUpperCase();
            try {
              final cacheUri = Uri.parse("http://91.99.145.70:8000/api/vehicle/cache");
              final res = await http.post(
                cacheUri,
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({
                  "plate": plateClean,
                  "data": scraped,
                }),
              );
              if (res.statusCode == 200) {
                _fetchBoostrTelemetry();
                _showSnack("¡Vehículo $plateClean sincronizado en la base de datos!");
              }
            } catch (e) {
              debugPrint("Error persistiendo en backend: $e");
            }

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
    final make = _vehicleData?['marca']?.toString().toUpperCase() ?? '';
    final model = _vehicleData?['modelo']?.toString().toUpperCase() ?? '';
    final vehicleTitle = ('$make $model').trim();

    if (vehicleTitle.isEmpty) return;

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
                                    final url = 'http://91.99.145.70:8000/api/r/meli?q=' + q;
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
                _buildPhysicalPlate(),
                const SizedBox(height: 16),
                _buildFormatPills(),
                const SizedBox(height: 24),
                _buildScanButton(),
                const SizedBox(height: 28),
                if (_vehicleData != null) _buildVehicleSpecsCard(),
            _buildSiiCard(),
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
        _buildBoostrTelemetryHud(),
              _buildEngineSelector(),
      ],
    );
  }


  
  Widget _buildEngineSelector() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _selectedEngine = 'boostr'),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _selectedEngine == 'boostr' ? const Color(0xFF1E293B) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: _selectedEngine == 'boostr' ? Border.all(color: const Color(0xFF38BDF8), width: 1.2) : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.bolt, size: 16, color: Color(0xFF38BDF8)),
                    SizedBox(width: 6),
                    Text(
                      'Boostr API (Pro)',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _selectedEngine = 'prt'),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _selectedEngine == 'prt' ? const Color(0xFF1E293B) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: _selectedEngine == 'prt' ? Border.all(color: const Color(0xFF10B981), width: 1.2) : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.precision_manufacturing, size: 16, color: Color(0xFF10B981)),
                    SizedBox(width: 6),
                    Text(
                      'Motor PRT (Local)',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

    Widget _buildBoostrTelemetryHud() {
    final bool isBoostr = _selectedEngine == 'boostr';
    final bool isOnline = _boostrStatus?['status'] == 'ONLINE';
    final String plan = _boostrStatus?['plan']?.toString().toUpperCase() ?? 'PRO';
    final String dailyLimit = _boostrStatus?['daily_limit']?.toString() ?? '100';
    final String remaining = _boostrStatus?['remaining']?.toString() ?? dailyLimit;
    final String cached = _boostrStatus?['cached_plates']?.toString() ?? '0';

    final Color accentColor = isBoostr ? const Color(0xFF38BDF8) : const Color(0xFF10B981);
    final Color dotColor = isBoostr 
        ? (isOnline ? const Color(0xFF10B981) : const Color(0xFFF59E0B))
        : const Color(0xFF10B981);

    final String titleText = isBoostr 
        ? 'BOOSTR API $plan: ${isOnline ? "ONLINE" : "CONECTANDO"}'
        : 'MOTOR PRT CHILE: ACTIVO';

    final String metricsText = isBoostr
        ? 'Cuota: $remaining/$dailyLimit   •   Caché: $cached'
        : 'Modo: Directo (P2P)   •   Caché: $cached';

    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.35), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: dotColor.withOpacity(0.6),
                  blurRadius: 6,
                  spreadRadius: 2,
                )
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  titleText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  metricsText,
                  style: TextStyle(
                    color: accentColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 360),
      height: 54,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _searchPlate,
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
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.radar_rounded, color: Colors.white, size: 22),
                      SizedBox(width: 10),
                      Text(
                        'CONSULTAR VEHÍCULO',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Colors.white),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _openPdfReport() async {
    final rawPlate = _vehicleData?['patente']?.toString().split('-').first.trim().toUpperCase() ?? '';
    if (rawPlate.isEmpty) return;

    final uri = Uri.parse('http://91.99.145.70:8000/api/patente/$rawPlate?provider=$_selectedEngine');
    try {
      HapticFeedback.mediumImpact();
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        _showSnack('No se pudo abrir el navegador para descargar el PDF');
      }
    } catch (e) {
      _showSnack('Error al intentar abrir el PDF ($e)');
    }
  }

  
  Widget _buildSiiCard() {
    final sii = _vehicleData?["sii"] ?? _siiData?["summary"];
    if (sii == null && !_isLoadingSii) {
      return const SizedBox.shrink();
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
                              bText = 'BOOSTR API';
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
    String clean = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (clean.length > 6) clean = clean.substring(0, 6);
    StringBuffer valid = StringBuffer();
    for (int i = 0; i < clean.length; i++) {
      String char = clean[i];
      bool isLetter = RegExp(r'[A-Z]').hasMatch(char);
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

  static const String baseUrl = 'http://91.99.145.70:8000';

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
  // Watchdog de 6s para 'READY': si el script dinámico no completa el
  // aislamiento (CSS anti-flicker + isolateForm) y despacha 'READY', se
  // reintenta inyección/recarga automáticamente (máx. 2); si todo falla,
  // se muestra el botón nativo de reintentar. La pantalla de carga JAMÁS
  // se apaga sin el READY explícito del script.
  Timer? _readyWatchdog;
  int _readyReloads = 0;
  // Tras 15s sin READY, muestra botón de reintentar (no expone pantalla en blanco).
  bool _showRetryButton = false;

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
    // Crear el WebView con el modo de composición híbrido clásico forzado más
    // abajo (en el widget), que evita el lienzo en blanco del SurfaceTexture.
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setUserAgent("Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36")
      ..enableZoom(false)
      ..addJavaScriptChannel(
        'PrtBridge',
        onMessageReceived: (JavaScriptMessage message) {
          final msg = message.message;
          if (msg.startsWith('DATA:')) {
            try {
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
              if (widget.onVehicleSaved != null) {
                widget.onVehicleSaved!(map);
              }
              if (mounted) {
                Navigator.of(context).pop(map);
              }
            } catch (e) {
              debugPrint('Error parsing PRT payload: $e');
            }
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
            // Patente no existe en PRT: volver de inmediato a la pantalla
            // principal, avisar al usuario y devolver el foco al input.
            _postbackSafetyTimer?.cancel();
            if (mounted) {
              if (widget.onErrorNotFound != null) {
                widget.onErrorNotFound!();
              }
              Navigator.of(context).pop();
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
        Uri.parse('http://91.99.145.70:8000/api/debug/log'),
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
          .get(Uri.parse('http://91.99.145.70:8000/api/debug/prt-script.js'))
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
        Uri.parse('http://91.99.145.70:8000/api/debug/dump'),
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
          if (_isProcessingPostback)
            const _ExecutiveTelemetryOverlay(),

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
