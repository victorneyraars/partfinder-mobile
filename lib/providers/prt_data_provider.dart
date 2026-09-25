import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../cache/provider_cache.dart';
import 'vehicle_data_provider.dart';

/// Motor PRT (P2P human-in-the-loop).
///
/// Flujo:
///  1. GET /api/patente/{plate}?provider=prt → si el backend responde con
///     registro VIGENTE (requiere_verificacion=false), devuelve los datos.
///  2. Si requiere verificación (vencida/rechazada/no existe), abre el modal
///     reCAPTCHA vía [openModal] y espera el payload crudo del pop.
///  3. Sin datos → VehicleResult(found:false) (Negative Caching en la capa
///     de caché).
class PrtDataProvider extends VehicleDataProvider {
  PrtDataProvider({Future<Map<String, dynamic>?> Function(BuildContext context, String plate)? openModal})
      : _openModal = openModal;

  final Future<Map<String, dynamic>?> Function(BuildContext context, String plate)? _openModal;

  static const String _base = 'https://api.studiodigital360.com';

  @override
  String get id => 'prt';

  @override
  ProviderCache get cache => const ProviderCache(
        namespace: 'prt',
        ttl: Duration(days: 3),
        negativeTtl: Duration(hours: 12),
      );

  bool _hasVehicleData(Map<String, dynamic> d) {
    final marca = (d['marca'] ?? d['make'] ?? '').toString().trim();
    final modelo = (d['modelo'] ?? d['model'] ?? '').toString().trim();
    return marca.isNotEmpty || modelo.isNotEmpty;
  }

  @override
  Future<VehicleResult> fetch(String plate, {BuildContext? context}) async {
    final plateClean = plate.toUpperCase().trim();

    // 1) Caché del servidor con política de vigencia autónoma.
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/patente/$plateClean?provider=prt'))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        final raw = jsonDecode(resp.body) as Map<String, dynamic>;
        final requiere = raw['requiere_verificacion'] == true;
        final data = (raw['data'] is Map)
            ? Map<String, dynamic>.from(raw['data'] as Map)
            : Map<String, dynamic>.from(raw);
        if (!requiere && _hasVehicleData(data)) {
          return VehicleResult(found: true, data: data, source: 'prt', status: 'hit');
        }
      }
    } catch (_) {
      // Red caída o backend lento: pasar al flujo P2P si hay modal.
    }

    // 2) Verificación fresca P2P (modal reCAPTCHA).
    if (context != null && _openModal != null) {
      final raw = await _openModal!(context, plateClean);
      if (raw != null && _hasVehicleData(raw)) {
        return VehicleResult(found: true, data: raw, source: 'prt', status: 'hit');
      }
    }

    return const VehicleResult(found: false, data: <String, dynamic>{}, source: 'prt', status: 'not_found');
  }
}
