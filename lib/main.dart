import "dart:convert";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;

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

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;
  Map<String, dynamic>? _vehicleData;
  String? _source;
  String? _errorMessage;
  String _rateRemaining = '';
  String _rateLimit = '';

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
    });

    try {
      final response = await http.get(Uri.parse("$baseUrl/api/patente/$patente"));
      if (response.statusCode == 200) {
        final jsonResponse = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _source = jsonResponse["source"];
          _vehicleData = jsonResponse["data"]["data"];
          _rateRemaining = jsonResponse["rate_remaining"]?.toString() ?? 'N/D';
          _rateLimit = jsonResponse["rate_limit"]?.toString() ?? 'N/D';
        });
      } else if (response.statusCode == 404) {
        setState(() {
          _errorMessage = "Vehículo no encontrado para la patente ingresada.";
        });
      } else {
        setState(() {
          _errorMessage = "Error en el servidor: ${response.statusCode}";
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
                decoration: InputDecoration(
                  labelText: "Ingrese Patente (Ej: CPRL32)",
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.directions_car),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: _consultarPatente,
                  ),
                ),
                onSubmitted: (_) => _consultarPatente(),
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
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 16),
                      textAlign: TextAlign.center,
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
                              // Encabezado adaptable (Responsive Wrap) para evitar desbordes
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
                              // Filtrar campos nulos, vacíos o redundantes para una vista limpia
                              ..._vehicleData!.entries.where((entry) {
                                final key = entry.key.toLowerCase();
                                final value = entry.value;
                                if (['make', 'model'].contains(key)) return false;
                                if (value == null || value.toString().trim().isEmpty) return false;
                                return true;
                              }).map((entry) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          "${entry.key.toUpperCase()}:",
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
                                        child: Text(
                                          entry.value.toString(),
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
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
