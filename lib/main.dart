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
  bool _isSaving = false;
  String _statusMessage = 'Toca la casilla para verificar';
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0F172A))
      ..setUserAgent("Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36")
      ..addJavaScriptChannel(
        'PrtBridge',
        onMessageReceived: (JavaScriptMessage message) {
          _handleBridge(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            SystemChannels.textInput.invokeMethod('TextInput.hide');
          },
          onPageFinished: (_) {
            SystemChannels.textInput.invokeMethod('TextInput.hide');
            _startBulletproofLoop();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.prt.cl/Paginas/RevisionTecnica.aspx'));
  }

  void _handleBridge(String raw) {
    if (raw == 'CAPTCHA_SOLVED') {
      if (mounted) {
        setState(() {
          _isSaving = true;
          _statusMessage = '¡Captcha verificado! Extrayendo vehículo...';
        });
      }
      return;
    }

    try {
      final Map<String, dynamic> data = json.decode(raw);
      _saveAndExit(data);
    } catch (_) {}
  }

  Future<void> _saveAndExit(Map<String, dynamic> scraped) async {
    if (!mounted) return;
    setState(() {
      _isSaving = true;
      _statusMessage = '¡Ficha obtenida! Guardando vehículo...';
    });

    try {
      scraped['patente'] = widget.targetPlate;
      scraped['data_source'] = 'PRT_SCRAPING';
      scraped.remove('revisions');

      await http.post(
        Uri.parse('http://91.99.145.70:8000/api/vehicle/cache'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'plate': widget.targetPlate, 'data': scraped}),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}

    if (mounted) {
      widget.onVehicleSaved(scraped);
      Navigator.pop(context);
    }
  }

  void _startBulletproofLoop() {
    final js = """
      (function() {
        var css = `
          html, body {
            background-color: #0F172A !important;
            margin: 0 !important;
            padding: 0 !important;
            width: 100vw !important;
            height: 100vh !important;
            overflow: hidden !important;
          }
          #s4-workspace, #s4-bodyContainer, header, nav, footer,
          .ms-main, img, table, .banner, div[id*="WebPartWPQ"] {
            display: none !important;
          }
          #pf-captcha-host {
            position: fixed !important;
            left: 50% !important;
            top: 45% !important;
            width: 304px !important;
            height: 78px !important;
            transform: translate(-50%, -50%) !important;
            -webkit-transform: translate(-50%, -50%) !important;
            z-index: 10000 !important;
            background: transparent !important;
            border-radius: 4px !important;
            box-shadow: 0 4px 18px rgba(0,0,0,0.5) !important;
            overflow: hidden !important;
            display: flex !important;
            justify-content: center !important;
            align-items: center !important;
          }
          #pf-captcha-host iframe {
            width: 304px !important;
            height: 78px !important;
            border: none !important;
          }
          div:has(iframe[src*="bframe"]),
          div:has(iframe[title*="challenge"]),
          div:has(iframe[title*="desafío"]),
          .pf-bframe-centered {
            position: fixed !important;
            left: 50% !important;
            top: 50% !important;
            transform: translate(-50%, -50%) scale(var(--pf-scale, 0.90)) !important;
            -webkit-transform: translate(-50%, -50%) scale(var(--pf-scale, 0.90)) !important;
            transform-origin: center center !important;
            z-index: 2147483647 !important;
            pointer-events: auto !important;
          }
        `;

        function applyCss() {
          var styleEl = document.getElementById('pf-bulletproof-style');
          if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = 'pf-bulletproof-style';
            (document.head || document.documentElement).appendChild(styleEl);
          }
          if (styleEl.innerHTML !== css) {
            styleEl.innerHTML = css;
          }
        }

        applyCss();

        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          (document.head || document.documentElement).appendChild(meta);
        }
        meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';

        document.querySelectorAll('input[type="text"]').forEach(function(inp) {
          if (inp.id.toLowerCase().includes('patente') || inp.name.toLowerCase().includes('patente')) {
            if (inp.value !== '${widget.targetPlate}') {
              inp.value = '${widget.targetPlate}';
              inp.dispatchEvent(new Event('input', { bubbles: true }));
              inp.dispatchEvent(new Event('change', { bubbles: true }));
            }
          }
        });

        function isolateCaptcha() {
          var anchor = document.querySelector('iframe[src*="anchor"]') || document.querySelector('.g-recaptcha');
          if (anchor) {
            var host = document.getElementById('pf-captcha-host');
            if (!host) {
              host = document.createElement('div');
              host.id = 'pf-captcha-host';
              document.body.appendChild(host);
            }
            var target = anchor.tagName === 'IFRAME' ? anchor : (anchor.querySelector('iframe') || anchor);
            if (target && target.parentElement !== host) {
              host.appendChild(target);
            }
          }
        }

        isolateCaptcha();

        function clickLupa() {
          var btn = document.querySelector('input[src*="lupa" i], input[src*="buscar" i], [id*="Buscar" i], a[title*="Buscar" i]');
          if (!btn) {
            var inp = document.querySelector('input[type="text"]');
            if (inp && inp.parentElement) {
              btn = inp.parentElement.querySelector('input[type="image"], input[type="submit"], button, a, img');
            }
          }
          if (btn) {
            btn = btn.closest('a') || btn.closest('button') || btn;
            try {
              btn.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
              if (typeof btn.click === 'function') btn.click();
            } catch(e) {}
          }
        }

        function expandVehicleTab() {
          var els = document.querySelectorAll('a, span, div, td, b');
          for (var i = 0; i < els.length; i++) {
            var t = (els[i].textContent || '').trim().toLowerCase();
            if (t.includes('información del vehículo') || t.includes('informacion del vehiculo')) {
              var target = els[i].closest('a') || els[i].closest('div[onclick]') || els[i].closest('td') || els[i];
              try {
                target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
                if (typeof target.click === 'function') target.click();
              } catch(e) {}
              return;
            }
          }
        }

        window.__pfData = { plate: '${widget.targetPlate}' };

        setInterval(function() {
          applyCss();
          isolateCaptcha();

          var bframe = document.querySelector('iframe[src*="bframe"]');
          if (bframe) {
            var c = bframe;
            while (c.parentElement && c.parentElement !== document.body && c.parentElement.tagName !== 'HTML') {
              c = c.parentElement;
            }
            if (c && c !== document.body && c.tagName !== 'FORM') {
              var winW = window.innerWidth || document.documentElement.clientWidth;
              var winH = window.innerHeight || document.documentElement.clientHeight;
              var scale = Math.min((winW - 16) / 400, (winH - 80) / 580);
              if (scale > 1.0) scale = 1.0;
              if (scale < 0.70) scale = 0.70;
              document.documentElement.style.setProperty('--pf-scale', scale.toFixed(3));
              if (!c.classList.contains('pf-bframe-centered')) {
                c.classList.add('pf-bframe-centered');
              }
            }
          }

          var token = '';
          try {
            if (window.grecaptcha && window.grecaptcha.getResponse) token = window.grecaptcha.getResponse();
          } catch(e) {}
          if (!token) {
            var ta = document.querySelector('textarea[name="g-recaptcha-response"], #g-recaptcha-response');
            if (ta && ta.value) token = ta.value;
          }

          if (token && token.length > 20 && !window.__pfSearched) {
            window.__pfSearched = true;
            if (window.PrtBridge) window.PrtBridge.postMessage('CAPTCHA_SOLVED');
            clickLupa();
            setTimeout(clickLupa, 400);
          }

          var d = window.__pfData;
          document.querySelectorAll('tr').forEach(function(r) {
            var cells = Array.from(r.querySelectorAll('td, th')).map(function(c) {
              return (c.textContent || '').trim().split(' ').filter(Boolean).join(' ');
            }).filter(Boolean);

            for (var i = 0; i < cells.length; i++) {
              var label = cells[i].toLowerCase();
              var val = (i + 1 < cells.length) ? cells[i + 1] : '';

              if (cells[i].indexOf(':') !== -1) {
                var parts = cells[i].split(':');
                label = parts[0].toLowerCase();
                val = parts.slice(1).join(':').trim();
              }

              if (label.indexOf('marca') !== -1 && label.indexOf('modelo') === -1) {
                if (val && !d.make) d.make = val;
              } else if (label.indexOf('modelo') !== -1) {
                if (val && !d.model) d.model = val;
              } else if (label.indexOf('año') !== -1 || label.indexOf('fabricaci') !== -1) {
                if (val && !d.year) d.year = val;
              } else if (label.indexOf('tipo') !== -1 && label.indexOf('sello') === -1) {
                if (val && !d.type) d.type = val;
              } else if (label.indexOf('motor') !== -1) {
                if (val && !d.engine_number) d.engine_number = val;
              } else if (label.indexOf('chasis') !== -1) {
                if (val && !d.chassis) d.chassis = val;
              } else if (label.indexOf('vin') !== -1) {
                if (val && !d.vin) d.vin = val;
              } else if (label.indexOf('sello') !== -1) {
                if (val && !d.seal_type) d.seal_type = val;
              }
            }
          });

          var bodyTxt = document.body.innerText || document.body.textContent || '';
          function findTxt(regex) {
            var match = bodyTxt.match(regex);
            return match && match[1] ? match[1].trim() : '';
          }

          if (!d.make) d.make = findTxt(/Marca\s*[:\t\n]+\s*([A-Za-z0-9\s\-]+)/i);
          if (!d.model) d.model = findTxt(/Modelo\s*[:\t\n]+\s*([A-Za-z0-9\s\-]+)/i);
          if (!d.year) d.year = findTxt(/A[ñn]o(?:\s+de\s+Fabricaci[oó]n)?\s*[:\t\n]+\s*([0-9]{4})/i);
          if (!d.type) d.type = findTxt(/Tipo(?:\s+de\s+Veh[ií]culo)?\s*[:\t\n]+\s*([A-Za-z0-9\s\-]+)/i);
          if (!d.engine_number) d.engine_number = findTxt(/Motor\s*[:\t\n]+\s*([A-Za-z0-9\s\-]+)/i);
          if (!d.chassis) d.chassis = findTxt(/Chasis\s*[:\t\n]+\s*([A-Za-z0-9\s\-]+)/i);
          if (!d.vin) d.vin = findTxt(/VIN\s*[:\t\n]+\s*([A-Za-z0-9\s\-]+)/i);
          if (!d.seal_type) d.seal_type = findTxt(/Sello(?:\s+Verde|\s+Rojo|\s+Amarillo)?/i);

          var onResults = bodyTxt.includes('Volver a Consultar') || bodyTxt.includes('Información del Vehículo');
          if (onResults && (!d.make || !d.model)) {
            if (!window.__pfTabOpened || Date.now() - window.__pfTabOpened > 1200) {
              window.__pfTabOpened = Date.now();
              expandVehicleTab();
            }
          }

          if (d.make || d.model) {
            if (window.PrtBridge && !window.__pfSent) {
              window.__pfSent = true;
              window.PrtBridge.postMessage(JSON.stringify(d));
            }
          }
        }, 100);
      })();
    """;
    _controller.runJavaScript(js);
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Container(
            color: const Color(0xFF1E293B),
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                if (_isSaving)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(color: Color(0xFF10B981), strokeWidth: 2),
                  )
                else
                  const Icon(Icons.touch_app_rounded, color: Color(0xFF38BDF8), size: 16),
                const SizedBox(width: 8),
                Text(
                  _statusMessage,
                  style: TextStyle(
                    color: _isSaving ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_isSaving)
              Container(
                color: const Color(0xFF0F172A),
                width: double.infinity,
                height: double.infinity,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    CircularProgressIndicator(color: Color(0xFF10B981), strokeWidth: 3),
                    SizedBox(height: 20),
                    Text(
                      'Extrayendo ficha técnica oficial...',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Guardando en base de datos permanente',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
