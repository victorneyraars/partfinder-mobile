import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../cache/provider_cache.dart';
import '../models/vehicle_model.dart';
import 'vehicle_data_provider.dart';

/// Caja conectora de Boostr API (Pro).
///
/// Endpoint orquestado (la API KEY vive en el servidor, NUNCA en el APK):
///   GET https://api.studiodigital360.com/api/patente/{PLATE}?provider=boostr
///   (el backend consume https://api.boostr.cl/vehicle/{PLATE}.json con
///   'X-API-KEY' configurada en el entorno del servidor y homologa el payload).
///
/// Manejo HTTP:
///  - 200 con datos      → VehicleResult(found:true, status:'hit') mapeado al
///                          esquema unificado (marca/modelo/anio/motor/chasis...).
///  - 200 sin datos      → VehicleResult(found:false, status:'empty').
///  - 404                → VehicleResult(found:false, status:'not_found')
///                          (la capa de caché lo guarda como negative cache).
///  - 429                → ProviderException (límite de cuota) para que la UI
///                          notifique al usuario.
///  - Red / 5xx          → ProviderException controlada para permitir fallback.
///
/// Caché aislada: namespace `boostr` → archivos `boostr_cache_<PLATE>.json`
/// con TTL de 60 días para hits y 7 días para negativos.
class BoostrDataProvider extends VehicleDataProvider {
  BoostrDataProvider({
    ProviderCache? cache,
  }) : _cache = cache ??
            const ProviderCache(
              namespace: 'boostr',
              ttl: Duration(days: 60),
              negativeTtl: Duration(days: 7),
            );

  static const String _base = 'https://api.studiodigital360.com';

  final ProviderCache _cache;

  @override
  String get id => 'boostr';

  @override
  ProviderCache get cache => _cache;

  /// Limpieza de patente: mayúsculas, sin guiones ni espacios.
  static String normalizePlate(String plate) =>
      plate.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();

  /// Mapeo Boostr → esquema unificado con el 100% de los campos expuestos
  /// por la API (incluyendo ?include=owner): plate, dv, make, model,
  /// version, year, type, engine, engine_size, chassis, color, doors,
  /// transmission, kilometers, valuation, gas_type, manufacturer, region,
  /// country y owner (owner_name / owner_rut). Los valores vacíos ("", 0,
  /// null) se preservan tal cual para la ficha exhaustiva.
  static Map<String, dynamic> mapToUnified(Map<String, dynamic> b) {
    final model = VehicleBaseModel.fromJson(b);
    return model.toUnified();
  }

  bool _hasVehicleData(Map<String, dynamic> d) {
    final marca = (d['marca'] ?? d['make'] ?? '').toString().trim();
    final modelo = (d['modelo'] ?? d['model'] ?? '').toString().trim();
    return marca.isNotEmpty || modelo.isNotEmpty;
  }

  @override
  Future<VehicleResult> fetch(String plate, {BuildContext? context}) async {
    final plateClean = normalizePlate(plate);
    if (plateClean.isEmpty) {
      return const VehicleResult(found: false, data: <String, dynamic>{}, source: 'boostr', status: 'empty');
    }

    http.Response resp;
    try {
      resp = await http
          .get(Uri.parse('$_base/api/patente/$plateClean?provider=boostr'))
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw ProviderException('Boostr: error de red ($e)');
    }

    switch (resp.statusCode) {
      case 200:
        final raw = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = (raw['data'] is Map)
            ? Map<String, dynamic>.from(raw['data'] as Map)
            : Map<String, dynamic>.from(raw);
        if (!_hasVehicleData(data)) {
          return const VehicleResult(
              found: false, data: <String, dynamic>{}, source: 'boostr', status: 'empty');
        }
        return VehicleResult(
          found: true,
          data: mapToUnified(data),
          source: 'boostr',
          status: 'hit',
        );
      case 404:
        return const VehicleResult(
            found: false, data: <String, dynamic>{}, source: 'boostr', status: 'not_found');
      case 429:
        throw const ProviderException('Boostr: límite de cuota alcanzado. Intenta nuevamente en unos minutos.',
            statusCode: 429);
      default:
        throw ProviderException('Boostr: error del servicio (HTTP ${resp.statusCode})',
            statusCode: resp.statusCode);
    }
  }
}
