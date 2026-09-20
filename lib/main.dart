import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  String _selectedEngine = 'boostr';
  final TextEditingController _plateController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  
  late AnimationController _scannerController;
  late Animation<double> _scannerAnimation;
  
  bool _isLoading = false;
  Map<String, dynamic>? _vehicleData;
  String _activeFormat = "DESCONOCIDO";

  
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
            _vehicleData = v;
          });
          _fetchBoostrTelemetry();
        } else {
          _showSnack('No se encontraron especificaciones para $rawPlate');
        }
      } else if (response.statusCode == 404) {
        try {
          final dynamic errJson = jsonDecode(body);
          if (errJson is Map && (errJson['require_prt_solve'] == true || (errJson['detail'] is Map && errJson['detail']['require_prt_solve'] == true))) {
            _openPrtVerificationScreen(rawPlate);
            return;
          }
        } catch (_) {}
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
          onVehicleSaved: (scraped) {
            setState(() {
              _vehicleData = scraped;
            });
            _fetchBoostrTelemetry();
            _showSnack('¡Vehículo verificado en PRT y guardado en caché permanente!');
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
            return k != 'marca' && k != 'modelo' && k != 'repuestos_compatibles';
          }).map((e) {
            final label = e.key.replaceAll('_', ' ').toUpperCase();
            final isHighlight = e.key.toLowerCase() == 'patente';
            return _specRow(label, e.value?.toString() ?? '---', isHighlight: isHighlight);
          }),
          const SizedBox(height: 16),
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
  final Function(Map<String, dynamic>) onVehicleSaved;

  const PrtVerificationScreen({
    super.key,
    required this.targetPlate,
    required this.onVehicleSaved,
  });

  @override
  State<PrtVerificationScreen> createState() => _PrtVerificationScreenState();
}

class _PrtVerificationScreenState extends State<PrtVerificationScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent("Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36")
      ..addJavaScriptChannel(
        'PrtBridge',
        onMessageReceived: (JavaScriptMessage message) {
          _handleAutoScraped(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (String url) {
            setState(() => _isLoading = false);
            SystemChannels.textInput.invokeMethod('TextInput.hide');
            _injectPrecisionEngine();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.prt.cl/Paginas/RevisionTecnica.aspx'));
  }

  void _injectPrecisionEngine() {
    final js = """
      (function() {
        // 1. Viewport estándar de alta fidelidad
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          document.head.appendChild(meta);
        }
        meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes';

        // 2. CSS Maestro: Limpieza y accesibilidad táctil impecable
        var style = document.getElementById('pf-precision-style');
        if (!style) {
          style = document.createElement('style');
          style.id = 'pf-precision-style';
          document.head.appendChild(style);
        }
        style.innerHTML = `
          /* Suprimir decoraciones de SharePoint */
          header, nav, footer, #suiteBar, #s4-titlerow, #titleAreaBox, .banner,
          [id*="Logo"], [id*="siteIcon"], [class*="logo"],
          img[src*="logo"], img[src*="Logo"], img[src*="prt"], img[src*="PRT"],
          img[src*="afiche"], img[src*="banner"], img[src*="auto"],
          table[id*="calendario"], .ms-core-navigation, #sideNavBox,
          div[class*="footer"], .footer {
            display: none !important;
          }

          html, body, #s4-workspace, #s4-bodyContainer {
            width: 100% !important;
            max-width: 100vw !important;
            overflow-x: hidden !important;
            margin: 0 !important;
            padding: 4px !important;
            background-color: #F8FAFC !important;
            box-sizing: border-box !important;
          }

          /* Input patente */
          input[type="text"] {
            font-size: 24px !important;
            height: 48px !important;
            font-weight: 900 !important;
            text-align: center !important;
            background-color: #FFFFFF !important;
            color: #0284C7 !important;
            border: 2px solid #0284C7 !important;
            border-radius: 8px !important;
            margin: 6px auto !important;
            display: block !important;
            max-width: 250px !important;
          }

          /* ÁREA TÁCTIL GARANTIZADA PARA EL BOTÓN DE LA LUPA */
          input[type="image"], input[src*="lupa"], input[src*="buscar"], 
          img[src*="lupa"], img[src*="buscar"], a[id*="Buscar"], button[id*="Buscar"] {
            min-width: 50px !important;
            min-height: 50px !important;
            cursor: pointer !important;
            touch-action: manipulation !important;
            position: relative !important;
            z-index: 1000 !important;
          }

          .g-recaptcha {
            display: flex !important;
            justify-content: center !important;
            margin: 8px auto !important;
          }

          /* Centrado simétrico solo cuando esté activo */
          .pf-centered-active {
            position: fixed !important;
            left: 50% !important;
            right: auto !important;
            top: 48% !important;
            transform: translate(-50%, -50%) scale(var(--pf-scale, 0.88)) !important;
            -webkit-transform: translate(-50%, -50%) scale(var(--pf-scale, 0.88)) !important;
            transform-origin: center center !important;
            z-index: 2147483647 !important;
            pointer-events: auto !important;
          }

          /* Desactivar capas invisibles de reCAPTCHA cuando no hay fotos */
          .pf-centered-inactive {
            pointer-events: none !important;
            z-index: -1 !important;
          }

          /* Estilización de alto contraste para las tablas oficiales */
          .pf-result-card {
            width: 100% !important;
            margin: 10px 0 !important;
            background-color: #FFFFFF !important;
            border: 1px solid #CBD5E1 !important;
            border-radius: 12px !important;
            box-shadow: 0 4px 10px rgba(0,0,0,0.08) !important;
            overflow: hidden !important;
            border-collapse: collapse !important;
          }
          .pf-result-card td, .pf-result-card th {
            padding: 10px 14px !important;
            border-bottom: 1px solid #E2E8F0 !important;
            font-size: 14px !important;
          }
          .pf-result-card td:first-child {
            font-weight: 700 !important;
            color: #334155 !important;
            width: 40% !important;
            background-color: #F1F5F9 !important;
          }
          .pf-result-card td:last-child {
            font-weight: 800 !important;
            color: #0284C7 !important;
            background-color: #FFFFFF !important;
          }
          .pf-result-card th {
            background-color: #0284C7 !important;
            color: #FFFFFF !important;
            font-weight: bold !important;
          }
        `;

        // 3. Autocompletar la patente objetivo
        var inputs = document.querySelectorAll('input[type="text"]');
        inputs.forEach(function(inp) {
          if (inp.id.toLowerCase().includes('patente') || inp.name.toLowerCase().includes('patente')) {
            if (inp.value !== '${widget.targetPlate}') {
              inp.value = '${widget.targetPlate}';
              inp.dispatchEvent(new Event('input', { bubbles: true }));
              inp.dispatchEvent(new Event('change', { bubbles: true }));
            }
          }
        });

        // 4. Control reactivo estricto
        setInterval(function() {
          // A) Control de visibilidad de reCAPTCHA
          var bframe = document.querySelector('iframe[src*="bframe"]');
          if (bframe) {
            var container = bframe;
            while (container.parentElement && container.parentElement !== document.body && container.parentElement.tagName !== 'HTML') {
              container = container.parentElement;
            }
            if (container && container !== document.body) {
              var topVal = parseInt(container.style.top || '0', 10);
              var styleObj = window.getComputedStyle(container);
              var isVisible = topVal > -1000 &&
                              styleObj.display !== 'none' &&
                              styleObj.visibility !== 'hidden' &&
                              styleObj.opacity !== '0';

              if (isVisible) {
                var winW = window.innerWidth || document.documentElement.clientWidth;
                var winH = window.innerHeight || document.documentElement.clientHeight;
                var scaleW = (winW * 0.94) / 400;
                var scaleH = (winH * 0.84) / 580;
                var scale = Math.min(scaleW, scaleH);
                if (scale > 0.90) scale = 0.90;
                if (scale < 0.60) scale = 0.60;
                document.documentElement.style.setProperty('--pf-scale', scale.toFixed(3));

                container.classList.remove('pf-centered-inactive');
                container.classList.add('pf-centered-active');
              } else {
                container.classList.remove('pf-centered-active');
                container.classList.add('pf-centered-inactive');
              }
            }
          }

          // B) Extracción cuando el usuario presiona la lupa y llegan los datos
          var res = {};
          var vehicleTable = null;
          var inspectionTable = null;

          document.querySelectorAll('table').forEach(function(tbl) {
            var tText = tbl.innerText || '';
            if (tText.includes('Marca') && (tText.includes('Patente') || tText.includes('Modelo'))) {
              vehicleTable = tbl;
            }
            if (tText.includes('Cod.Planta') || (tText.includes('Planta') && tText.includes('Fecha'))) {
              inspectionTable = tbl;
            }
          });

          if (vehicleTable) {
            var rows = vehicleTable.querySelectorAll('tr');
            rows.forEach(function(r) {
              var cells = Array.from(r.querySelectorAll('td, th')).map(function(c) {
                return c.innerText.trim();
              }).filter(Boolean);

              if (cells.length >= 2) {
                var k = cells[0].toLowerCase();
                var v = cells[cells.length - 1];
                if (k.includes('patente')) res['plate'] = v;
                else if (k.includes('tipo') && !k.includes('sello')) res['type'] = v;
                else if (k.includes('marca')) res['make'] = v;
                else if (k.includes('modelo')) res['model'] = v;
                else if (k.includes('año') || k.includes('fabricaci')) res['year'] = v;
                else if (k.includes('motor')) res['engine_number'] = v;
                else if (k.includes('chasis')) res['chassis'] = v;
                else if (k.includes('vin')) res['vin'] = v;
                else if (k.includes('sello')) res['seal_type'] = v;
              }
            });
          }

          if (inspectionTable) {
            var iRows = inspectionTable.querySelectorAll('tr');
            if (iRows.length > 1) {
              var firstDataRow = Array.from(iRows[1].querySelectorAll('td')).map(function(c) {
                return c.innerText.trim();
              });
              if (firstDataRow.length >= 3) {
                res['rt_date'] = firstDataRow[0];
                res['rt_plant_code'] = firstDataRow[1];
                res['rt_plant'] = firstDataRow[2];
                if (firstDataRow.length >= 4) res['rt_certificate'] = firstDataRow[3];
              }
            }
          }

          // C) Si los datos pertenecen a la patente consultada:
          var validPlate = (res['plate'] || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
          var expectedPlate = '${widget.targetPlate}'.toUpperCase().replace(/[^A-Z0-9]/g, '');

          if ((validPlate === expectedPlate || validPlate.length >= 4) && (res.make || res.model)) {
            // Ocultar formulario de búsqueda y elementos residuales
            document.querySelectorAll('input, .g-recaptcha, img, p, h1, h2, h3').forEach(function(el) {
              var p = el.closest('table') || el.closest('div') || el;
              if (p && p !== vehicleTable && p !== inspectionTable && (!vehicleTable || !vehicleTable.contains(p)) && p !== document.body) {
                p.style.setProperty('display', 'none', 'important');
              }
            });

            // Resaltar tablas con contraste nítido
            if (vehicleTable && !vehicleTable.classList.contains('pf-result-card')) {
              vehicleTable.classList.add('pf-result-card');
              vehicleTable.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
            if (inspectionTable && !inspectionTable.classList.contains('pf-result-card')) {
              inspectionTable.classList.add('pf-result-card');
            }

            // Notificar a Flutter
            if (window.PrtBridge && !window.__pfScrapedSent) {
              window.__pfScrapedSent = true;
              window.PrtBridge.postMessage(JSON.stringify(res));
            }
          }
        }, 120);
      })();
    """;
    _controller.runJavaScript(js);
  }

  void _handleAutoScraped(String rawJson) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final Map<String, dynamic> scraped = json.decode(rawJson);
      scraped['patente'] = widget.targetPlate;
      scraped['data_source'] = 'PRT_SCRAPING';

      final res = await http.post(
        Uri.parse('http://91.99.145.70:8000/api/vehicle/cache'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'plate': widget.targetPlate,
          'data': scraped,
        }),
      );

      if (res.statusCode == 200 && mounted) {
        widget.onVehicleSaved(scraped);
        Navigator.pop(context);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _manualExtract() async {
    setState(() => _isSaving = true);
    try {
      final jsScraper = """
        (function() {
          var res = {};
          var vehicleTable = null;
          var inspectionTable = null;

          document.querySelectorAll('table').forEach(function(tbl) {
            var tText = tbl.innerText || '';
            if (tText.includes('Marca') && (tText.includes('Patente') || tText.includes('Modelo'))) vehicleTable = tbl;
            if (tText.includes('Cod.Planta') || (tText.includes('Planta') && tText.includes('Fecha'))) inspectionTable = tbl;
          });

          if (vehicleTable) {
            var rows = vehicleTable.querySelectorAll('tr');
            rows.forEach(function(r) {
              var cells = Array.from(r.querySelectorAll('td, th')).map(function(c) { return c.innerText.trim(); }).filter(Boolean);
              if (cells.length >= 2) {
                var k = cells[0].toLowerCase();
                var v = cells[cells.length - 1];
                if (k.includes('patente')) res['plate'] = v;
                else if (k.includes('tipo') && !k.includes('sello')) res['type'] = v;
                else if (k.includes('marca')) res['make'] = v;
                else if (k.includes('modelo')) res['model'] = v;
                else if (k.includes('año') || k.includes('fabricaci')) res['year'] = v;
                else if (k.includes('motor')) res['engine_number'] = v;
                else if (k.includes('chasis')) res['chassis'] = v;
                else if (k.includes('vin')) res['vin'] = v;
                else if (k.includes('sello')) res['seal_type'] = v;
              }
            });
          }

          if (inspectionTable) {
            var iRows = inspectionTable.querySelectorAll('tr');
            if (iRows.length > 1) {
              var firstDataRow = Array.from(iRows[1].querySelectorAll('td')).map(function(c) { return c.innerText.trim(); });
              if (firstDataRow.length >= 3) {
                res['rt_date'] = firstDataRow[0];
                res['rt_plant_code'] = firstDataRow[1];
                res['rt_plant'] = firstDataRow[2];
                if (firstDataRow.length >= 4) res['rt_certificate'] = firstDataRow[3];
              }
            }
          }
          return JSON.stringify(res);
        })();
      """;

      final rawResult = await _controller.runJavaScriptReturningResult(jsScraper);
      String cleanJson = rawResult.toString();
      if (cleanJson.startsWith('"') && cleanJson.endsWith('"')) {
        cleanJson = json.decode(cleanJson);
      }
      final Map<String, dynamic> scraped = json.decode(cleanJson);

      if (scraped.isEmpty || (scraped['make'] == null && scraped['model'] == null)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se detectó la tabla de información. Pulsa la lupa en el portal antes de extraer.')),
        );
        return;
      }

      _handleAutoScraped(json.encode(scraped));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error en extracción: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Verificación Oficial PRT',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              'Patente: ${widget.targetPlate}',
              style: const TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _isSaving ? null : _manualExtract,
            icon: _isSaving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.save, color: Color(0xFF10B981), size: 18),
            label: const Text('Extraer', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
          ),
        ],
        bottom: _isLoading || _isSaving
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(color: Color(0xFF10B981), backgroundColor: Color(0xFF1E293B)),
              )
            : null,
      ),
      body: SafeArea(
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
