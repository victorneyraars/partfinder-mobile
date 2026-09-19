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

  final String baseUrl = "http://91.99.145.70:8000";

  Future<void> _consultarPatente() async {
    final patente = _controller.text.trim().toUpperCase();
    if (patente.isEmpty) return;

    setState(() {
      _isLoading = true;
      _vehicleData = null;
      _errorMessage = null;
      _source = null;
    });

    try {
      final response = await http.get(Uri.parse("$baseUrl/api/patente/$patente"));
      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);
        setState(() {
          _source = jsonResponse["source"];
          _vehicleData = jsonResponse["data"]["data"];
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
      body: Padding(
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
            const SizedBox(height: 20),
            if (_isLoading)
              const CircularProgressIndicator()
            else if (_errorMessage != null)
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red, fontSize: 16),
                textAlign: TextAlign.center,
              )
            else if (_vehicleData != null)
              Expanded(
                child: ListView(
                  children: [
                    Card(
                      elevation: 3,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "${_vehicleData!["make"] ?? ''} ${_vehicleData!["model"] ?? ''}".trim(),
                                  style: const TextStyle(
                                      fontSize: 20, fontWeight: FontWeight.bold),
                                ),
                                Chip(
                                  label: Text(
                                    _source == "database" ? "Caché (BD)" : "API Boostr",
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  backgroundColor: _source == "database"
                                      ? Colors.green
                                      : Colors.orange,
                                ),
                              ],
                            ),
                            const Divider(),
                            // Renderizar dinámicamente todas las llaves devueltas por la API
                            ..._vehicleData!.entries.where((entry) {
                              final key = entry.key.toLowerCase();
                              return !['make', 'model'].contains(key);
                            }).map((entry) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3.0),
                                child: Text(
                                  "${entry.key.toUpperCase()}: ${entry.value ?? 'No disponible'}",
                                  style: const TextStyle(fontSize: 14),
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
    );
  }
}
