import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../cache/provider_cache.dart';
import 'vehicle_data_provider.dart';

/// Proveedor Boostr API (comercial).
///
/// Consume el endpoint orquestado del backend:
/// GET /api/patente/{plate}?provider=boostr → el servidor consulta Boostr,
/// homologa el payload (fuente: 'Boostr', RT vacía explícita) y lo cachea.
/// Sin datos → VehicleResult(found:false) (Negative Caching local).
class BoostrDataProvider extends VehicleDataProvider {
  static const String _base = 'https://api.studiodigital360.com';

  @override
  String get id => 'boostr';

  @override
  ProviderCache get cache => const ProviderCache(namespace: 'boostr');

  bool _hasVehicleData(Map<String, dynamic> d) {
    final marca = (d['marca'] ?? d['make'] ?? '').toString().trim();
    final modelo = (d['modelo'] ?? d['model'] ?? '').toString().trim();
    return marca.isNotEmpty || modelo.isNotEmpty;
  }

  @override
  Future<VehicleResult> fetch(String plate, {BuildContext? context}) async {
    final plateClean = plate.toUpperCase().trim();
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/patente/$plateClean?provider=boostr'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final raw = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = (raw['data'] is Map)
            ? Map<String, dynamic>.from(raw['data'] as Map)
            : Map<String, dynamic>.from(raw);
        if (_hasVehicleData(data)) {
          return VehicleResult(found: true, data: data, source: 'boostr');
        }
      }
    } catch (_) {}

    // Intento de recuperación por el endpoint de fallback explícito.
    try {
      final resp = await http
          .post(
            Uri.parse('$_base/api/patente/fallback-boostr'),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{'patente': plateClean}),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final raw = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = (raw['data'] is Map)
            ? Map<String, dynamic>.from(raw['data'] as Map)
            : Map<String, dynamic>.from(raw);
        if (_hasVehicleData(data)) {
          return VehicleResult(found: true, data: data, source: 'boostr');
        }
      }
    } catch (_) {}

    return const VehicleResult(found: false, data: <String, dynamic>{}, source: 'boostr');
  }
}
