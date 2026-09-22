import 'dart:math';
import 'package:webview_flutter/webview_flutter.dart';
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
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PrtVerificationScreen(
          targetPlate: targetPlate,
          onVehicleSaved: (scraped) async {
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
class PrtVerificationScreen extends StatefulWidget {
  final String targetPlate;
  final Function(Map<String, dynamic>)? onVehicleSaved;

  const PrtVerificationScreen({
    super.key,
    required this.targetPlate,
    this.onVehicleSaved,
  });

  @override
  State<PrtVerificationScreen> createState() => _PrtVerificationScreenState();
}

class _PrtVerificationScreenState extends State<PrtVerificationScreen> {
  late final WebViewController _controller;
  bool _pageLoaded = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted && !_pageLoaded) {
        setState(() => _pageLoaded = true);
      }
    });
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent("Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36")
      ..addJavaScriptChannel(
        'PrtBridge',
        onMessageReceived: (JavaScriptMessage message) {
          final msg = message.message;
          if (msg.startsWith('DATA:')) {
            try {
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
          } else if (msg == 'ERROR:NOT_FOUND') {
            if (mounted) {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  backgroundColor: Color(0xFF0F2B48),
                  content: Row(
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent)),
                      SizedBox(width: 12),
                      Expanded(child: Text("Vehículo sin registro PRT. Consultando padrón...", style: TextStyle(color: Colors.white, fontSize: 13))),
                    ],
                  ),
                  duration: Duration(seconds: 4),
                ),
              );
              Future.microtask(() async {
                try {
                  final resp = await http.post(
                    Uri.parse("https://api.partfinder360.com/api/patente/fallback-boostr"),
                    headers: {"Content-Type": "application/json"},
                    body: jsonEncode({"patente": widget.targetPlate}),
                  );
                  if (resp.statusCode == 200) {
                    final dataRes = jsonDecode(resp.body) as Map<String, dynamic>;
                    final vData = dataRes["data"] as Map<String, dynamic>?;
                    if (vData != null && widget.onVehicleSaved != null) {
                      widget.onVehicleSaved!(vData);
                    }
                  }
                } catch (e) {
                  debugPrint("Error fallback automatico: $e");
                }
              });
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
            _injectStableBridge();
            if (mounted) {
              setState(() => _pageLoaded = true);
            }
          },
          onPageStarted: (url) {
            _controller.runJavaScript(
              'var s=document.createElement("style");s.id="pf-init";s.innerHTML="html,body{background:#0F172A!important;opacity:0!important;}";document.head.appendChild(s);'
            );
          },
          onWebResourceError: (error) {
            if (mounted) {
              setState(() => _pageLoaded = true);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.prt.cl/Paginas/RevisionTecnica.aspx'));
  }

  void _injectStableBridge() {
    final plate = widget.targetPlate.trim().toUpperCase();
    final js = r"""
      (function(targetPlate) {
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

              /* Ocultar todo el sitio SharePoint original */
              #s4-workspace, #s4-bodyContainer, #paginas, #banner, #menu, #rightCol,
              #pie, footer, header, img, table, div[id*="acordeon"], div[id*="Enlaces"],
              #DeltaPlaceHolderUtilityContent, div[id*="UtilityContent"],
              .ms-standardheader, a, h1, h2, h3, p {
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
            var candidates = Array.from(doc.querySelectorAll(
              'input[type="text"], input[type="search"], input:not([type])'
            ));
            candidates = candidates.filter(function(el) { return isVisible(el, win); });

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
          // Usar el setter de prototipo del HTMLInputElement del contexto de ese
          // frame (React/SPA), con fallback a asignación directa.
          try {
            var proto = (win && win.HTMLInputElement) ? win.HTMLInputElement.prototype : window.HTMLInputElement.prototype;
            var protoSetter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            protoSetter.call(inp, plateValue);
          } catch (e) {
            try { inp.value = plateValue; } catch (e2) {}
          }
          try {
            inp.dispatchEvent(new Event('input', { bubbles: true }));
            inp.dispatchEvent(new Event('change', { bubbles: true }));
            var evBlur = new Event('blur', { bubbles: true });
            inp.dispatchEvent(evBlur);
          } catch (e) {}
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
            dbg('OK frame=' + found.ctx.label +
                ' selector=' + describeInput(found.inp) +
                ' score=' + found.score +
                ' valueSet=' + ok);
            return found.ctx.label + ' | ' + describeInput(found.inp);
          }

          dbg('NOT_FOUND contexts=' + contexts.length);
          return null;
        }

        // Aplicar repetidamente durante 5s (cada 500ms) para neutralizar
        // scripts ASP.NET que limpian el campo tras inicializar reCAPTCHA.
        var startTime = Date.now();
        var REAPPLY_FOR_MS = 5000;
        var REAPPLY_EVERY_MS = 500;

        function reapplyLoop() {
          var info = fillAcrossFrames();
          if (info) {
            // Encontró el input; continuar reescribiendo hasta cumplir ventana.
          }
          if (Date.now() - startTime >= REAPPLY_FOR_MS) {
            dbg('DONE windowElapsed=' + (Date.now() - startTime) + 'ms lastInfo=' + (info || 'null'));
            return;
          }
          setTimeout(reapplyLoop, REAPPLY_EVERY_MS);
        }
        reapplyLoop();

        // MutationObserver: reintentar ante cambios dinámicos del DOM (frame raíz).
        if (window.MutationObserver) {
          var observer = new MutationObserver(function() {
            fillAcrossFrames();
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
      })('""" + plate + r"""');
    """;
    _controller.runJavaScript(js);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
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
          WebViewWidget(controller: _controller),
          if (!_pageLoaded)
            Container(
              color: const Color(0xFF0F172A),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF38BDF8)),
                    SizedBox(height: 16),
                    Text(
                      'Cargando portal PRT...',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
