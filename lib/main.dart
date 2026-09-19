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
  final TextEditingController _plateController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  
  late AnimationController _scannerController;
  late Animation<double> _scannerAnimation;
  
  bool _isLoading = false;
  Map<String, dynamic>? _vehicleData;
  String _activeFormat = "DESCONOCIDO";

  @override
  void initState() {
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
      final url = Uri.parse('http://91.99.145.70:8000/api/patente/$rawPlate');
      final request = await client.getUrl(url);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final json = jsonDecode(body);
        Map<String, dynamic>? raw;
        if (json is Map<String, dynamic>) {
          if (json['data'] is Map && json['data']['data'] is Map) {
            raw = Map<String, dynamic>.from(json['data']['data']);
          } else if (json['data'] is Map) {
            raw = Map<String, dynamic>.from(json['data']);
          } else {
            raw = json;
          }
        }

        if (raw != null && raw.isNotEmpty) {
          final Map<String, dynamic> v = {};
          final make = raw['make'] ?? raw['marca'] ?? '';
          final model = raw['model'] ?? raw['modelo'] ?? '';
          final version = raw['version'] ?? '';

          v['marca'] = make.toString().toUpperCase();
          v['modelo'] = ('$model $version').trim().toUpperCase();

          final plate = raw['plate'] ?? raw['patente'] ?? rawPlate;
          final dv = raw['dv'] != null && raw['dv'].toString().isNotEmpty ? '-${raw['dv']}' : '';
          v['patente'] = '$plate$dv'.toUpperCase();

          if (raw['year'] != null && raw['year'] != 0) v['año'] = raw['year'].toString();
          if (raw['type'] != null && raw['type'].toString().isNotEmpty) v['tipo_vehiculo'] = raw['type'].toString();
          if (raw['color'] != null && raw['color'].toString().trim().isNotEmpty) v['color'] = raw['color'].toString();
          if (raw['engine'] != null && raw['engine'].toString().trim().isNotEmpty) v['numero_motor'] = raw['engine'].toString();
          if (raw['engine_size'] != null && raw['engine_size'].toString().trim().isNotEmpty) v['cilindrada'] = '${raw['engine_size']} L';
          if (raw['chassis'] != null && raw['chassis'].toString().trim().isNotEmpty) v['chasis_vin'] = raw['chassis'].toString();
          if (raw['gas_type'] != null && raw['gas_type'].toString().trim().isNotEmpty) v['combustible'] = raw['gas_type'].toString();
          if (raw['transmission'] != null && raw['transmission'].toString().trim().isNotEmpty) v['transmision'] = raw['transmission'].toString();
          if (raw['kilometers'] != null && raw['kilometers'] != 0) v['kilometraje'] = '${raw['kilometers']} KM';
          if (raw['manufacturer'] != null && raw['manufacturer'].toString().trim().isNotEmpty) v['fabricante'] = raw['manufacturer'].toString();
          if (raw['country'] != null && raw['country'].toString().trim().isNotEmpty) v['pais_origen'] = raw['country'].toString();

          v['repuestos_compatibles'] = 'Repuestos compatibles con ${v['marca']} ${v['modelo']}';

          setState(() {
            _vehicleData = v;
          });
        } else {
          _showSnack('No se encontraron especificaciones para $rawPlate');
        }
      } else {
        _showSnack('Patente no encontrada en el registro oficial');
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
                                    var url = 'https://listado.mercadolibre.cl/' + q;
                                    if (meliAffiliateTag.isNotEmpty) {
                                      url += '?matt_tool=' + meliAffiliateTag;
                                    }
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

    final uri = Uri.parse('http://91.99.145.70:8000/api/patente/$rawPlate/pdf');
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF10B981)),
                ),
                child: const Text('VERIFICADO', style: TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.w800)),
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
