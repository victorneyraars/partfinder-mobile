import "dart:convert";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:http/http.dart" as http;
import "package:url_launcher/url_launcher.dart";

void main() {
  runApp(const PartFinderApp());
}

class PartFinderApp extends StatelessWidget {
  const PartFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "PartFinder 360",
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const SearchScreen(),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

// Formateador inteligente para restringir la escritura según los patrones oficiales de patentes en Chile
class ChileanPlateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    String text = newValue.text.toUpperCase();
    
    if (text.length > 6) {
      return oldValue;
    }

    int len = text.length;
    for (int i = 0; i < len; i++) {
      bool isLetter = RegExp(r'[A-Z]').hasMatch(text[i]);
      bool isNumber = RegExp(r'[0-9]').hasMatch(text[i]);

      if (!isLetter && !isNumber) return oldValue;

      // Las primeras 2 posiciones siempre deben ser letras
      if (i < 2 && !isLetter) return oldValue;
    }

    // Validación progresiva de prefijos válidos en Chile
    bool isValidPartial = true;
    if (len == 1) {
      isValidPartial = RegExp(r'^[A-Z]$').hasMatch(text);
    } else if (len == 2) {
      isValidPartial = RegExp(r'^[A-Z]{2}$').hasMatch(text);
    } else if (len == 3) {
      isValidPartial = RegExp(r'^([A-Z]{2}[0-9]|[A-Z]{3})$').hasMatch(text);
    } else if (len == 4) {
      isValidPartial = RegExp(r'^([A-Z]{2}[0-9]{2}|[A-Z]{3}[0-9]|[A-Z]{4})$').hasMatch(text);
    } else if (len == 5) {
      isValidPartial = RegExp(r'^([A-Z]{2}[0-9]{3}|[A-Z]{3}[0-9]{2}|[A-Z]{4}[0-9])$').hasMatch(text);
    } else if (len == 6) {
      isValidPartial = RegExp(r'^([A-Z]{2}[0-9]{4}|[A-Z]{3}[0-9]{3}|[A-Z]{4}[0-9]{2})$').hasMatch(text);
    }

    if (!isValidPartial) {
      return oldValue;
    }

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;
  Map<String, dynamic>? _vehicleData;
  String? _source;
  String? _errorMessage;
  String _rateRemaining = '';
  String _rateLimit = '';
  String _currentPlate = '';

  final String baseUrl = "http://91.99.145.70:8000";

  Future<void> _consultarPatente() async {
    final patente = _controller.text.trim().toUpperCase();
    if (patente.isEmpty) return;

    setState(() {
      _isLoading = true;
      _vehicleData = null;
      _errorMessage = null;
      _source = null;
      _rateRemaining = '';
      _rateLimit = '';
      _currentPlate = patente;
    });

    try {
      final response = await http.get(Uri.parse("$baseUrl/api/patente/$patente"));
      final jsonResponse = json.decode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200) {
        setState(() {
          _source = jsonResponse["source"];
          _vehicleData = jsonResponse["data"]["data"];
          _rateRemaining = jsonResponse["rate_remaining"]?.toString() ?? 'N/D';
          _rateLimit = jsonResponse["rate_limit"]?.toString() ?? 'N/D';
        });
      } else {
        setState(() {
          _errorMessage = jsonResponse["detail"] ?? "Error en el servidor: ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = "Error de red: No se pudo conectar al servidor.";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _copiarCampo(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("¡$label copiado: $value!"),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _copiarAlPortapapeles() {
    if (_vehicleData == null) return;
    final buffer = StringBuffer();
    buffer.writeln("=== PartFinder 360 - Ficha Técnica ===");
    buffer.writeln("Patente: $_currentPlate");
    _vehicleData!.forEach((key, value) {
      if (value != null && value.toString().trim().isNotEmpty) {
        buffer.writeln("${key.toUpperCase()}: $value");
      }
    });

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("¡Ficha técnica completa copiada al portapapeles!"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _descargarPdf() async {
    if (_currentPlate.isEmpty) return;
    final pdfUrl = Uri.parse("$baseUrl/api/patente/$_currentPlate/pdf");
    if (await canLaunchUrl(pdfUrl)) {
      await launchUrl(pdfUrl, mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No se pudo abrir el enlace del PDF.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("PartFinder 360 - Chile"),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.characters,
                maxLength: 6,
                inputFormatters: [
                  ChileanPlateFormatter(),
                ],
                decoration: const InputDecoration(
                  labelText: "Ingrese Patente (Ej: ABCD12)",
                  helperText: "Formatos oficiales en Chile:\n• Autos nuevos: 4 Letras y 2 Números (ABCD12)\n• Autos antiguos: 2 Letras y 4 Números (AB1234)\n• Motos / Otros: 3 Letras y 2-3 Números (ABC12 / ABC123)",
                  helperMaxLines: 4,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.directions_car),
                  counterText: "",
                ),
                onSubmitted: (_) => _consultarPatente(),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _consultarPatente,
                  icon: const Icon(Icons.search),
                  label: const Text("Consultar Patente"),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_rateRemaining.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Chip(
                    avatar: const Icon(Icons.bolt, color: Colors.orange, size: 18),
                    label: Text(
                      "Consultas Boostr restantes hoy: $_rateRemaining / $_rateLimit",
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    backgroundColor: Colors.orange.shade50,
                  ),
                ),
              if (_isLoading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_errorMessage != null)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red, fontSize: 15, fontWeight: FontWeight.w500),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                )
              else if (_vehicleData != null)
                Expanded(
                  child: ListView(
                    children: [
                      Card(
                        elevation: 3,
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8.0,
                                runSpacing: 8.0,
                                children: [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 220),
                                    child: Text(
                                      "${_vehicleData!["make"] ?? ''} ${_vehicleData!["model"] ?? ''}".trim(),
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Chip(
                                    label: Text(
                                      _source == "database" ? "Caché (BD)" : "API Boostr",
                                      style: const TextStyle(color: Colors.white, fontSize: 12),
                                    ),
                                    backgroundColor: _source == "database"
                                        ? Colors.green
                                        : Colors.orange,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                              const Divider(height: 24),
                              ..._vehicleData!.entries.where((entry) {
                                final key = entry.key.toLowerCase();
                                final value = entry.value;
                                if (['make', 'model'].contains(key)) return false;
                                if (value == null || value.toString().trim().isEmpty) return false;
                                return true;
                              }).map((entry) {
                                final fieldLabel = entry.key.toUpperCase();
                                final fieldValue = entry.value.toString();
                                return InkWell(
                                  onTap: () => _copiarCampo(fieldLabel, fieldValue),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 4.0),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          flex: 2,
                                          child: Text(
                                            "$fieldLabel:",
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13,
                                              color: Colors.grey,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          flex: 3,
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  fieldValue,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                              const Icon(Icons.copy_rounded, size: 14, color: Colors.grey),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                              const SizedBox(height: 20),
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: _copiarAlPortapapeles,
                                      icon: const Icon(Icons.copy, size: 16),
                                      label: const Text("Copiar Ficha"),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.grey.shade200,
                                        foregroundColor: Colors.black87,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: _descargarPdf,
                                      icon: const Icon(Icons.picture_as_pdf, size: 16),
                                      label: const Text("Reporte PDF"),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red.shade600,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
