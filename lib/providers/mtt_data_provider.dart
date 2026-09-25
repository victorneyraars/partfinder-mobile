import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../cache/provider_cache.dart';
import 'vehicle_data_provider.dart';

/// Caja conectora del Ministerio de Transportes y Telecomunicaciones (MTT)
/// — Registro Nacional de Servicios de Transporte de Pasajeros y Escolar
/// (RNSTP).
///
/// Consulta orquestada por el backend (scraping ASP.NET WebForms de
/// apps.mtt.cl/consultaweb/default.aspx):
///   GET /api/patente/{PLATE}?provider=mtt
///
/// Resultado unificado en [VehicleResult]:
///  - `es_transporte_publico` (bool)
///  - `tipo_servicio`, `estado_servicio`, `region`, `folio_flota`,
///    `fecha_vencimiento_permiso`
///  - alias camelCase para la UI: `isPublicTransport`, `mttServiceType`,
///    `mttStatus`, `mttRegion`.
///
/// Caché aislada `mtt_cache_<PLATE>.json` con TTL DINÁMICO:
///  - Particular (sin registro): 60 días.
///  - Transporte público: 30 días (sigue la vigencia del servicio).
class MttDataProvider extends VehicleDataProvider {
  MttDataProvider({ProviderCache? cache})
      : _cache = cache ??
            const ProviderCache(
              namespace: 'mtt',
              ttl: Duration(days: 60),
              negativeTtl: Duration(days: 7),
            );

  static const String _base = 'https://api.studiodigital360.com';

  final ProviderCache _cache;

  @override
  String get id => 'mtt';

  @override
  ProviderCache get cache => _cache;

  static String normalizePlate(String plate) =>
      plate.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();

  static String _s(dynamic v) => (v == null) ? '' : v.toString().trim();

  @override
  Future<VehicleResult> fetch(String plate, {BuildContext? context}) async {
    final plateClean = normalizePlate(plate);
    if (plateClean.isEmpty) {
      return const VehicleResult(
          found: false, data: <String, dynamic>{}, source: 'mtt', status: 'empty');
    }

    http.Response resp;
    try {
      resp = await http
          .get(Uri.parse('$_base/api/patente/$plateClean?provider=mtt'))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw ProviderException('MTT: error de red ($e)');
    }

    switch (resp.statusCode) {
      case 200:
        final raw = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = (raw['data'] is Map)
            ? Map<String, dynamic>.from(raw['data'] as Map)
            : Map<String, dynamic>.from(raw);
        final isPublic = data['es_transporte_publico'] == true;

        // Mapeo al modelo unificado + alias camelCase para la UI.
        final unified = <String, dynamic>{
          'patente': _s(data['patente'] ?? plateClean),
          'fuente': 'MTT',
          'es_transporte_publico': isPublic,
          'isPublicTransport': isPublic,
          'tipo_servicio': _s(data['tipo_servicio']),
          'mttServiceType': _s(data['tipo_servicio']),
          'estado_servicio': _s(data['estado_servicio']),
          'mttStatus': _s(data['estado_servicio']),
          'region': _s(data['region']),
          'mttRegion': _s(data['region']),
          'folio_flota': _s(data['folio_flota']),
          'fecha_vencimiento_permiso': _s(data['fecha_vencimiento_permiso']),
          // Estructura dinámica de secciones (titulo/tipo/items) parseada
          // por el backend: cualquier campo nuevo que MTT publique llega
          // aquí sin cambios de código.
          'secciones': (data['secciones'] is List)
              ? List<dynamic>.from(data['secciones'] as List)
              : const <dynamic>[],
          'rt_estado': '',
          'rt_vencimiento': '',
          'historial_rt': <dynamic>[],
        };

        // TTL dinámico: particular 60 días, transporte público 30 días.
        final ttl = isPublic ? const Duration(days: 30) : const Duration(days: 60);
        await _cache.write(plateClean,
            found: true, data: unified, source: 'mtt', status: 'hit', ttlOverride: ttl);

        return VehicleResult(found: true, data: unified, source: 'mtt', status: 'hit');
      case 404:
        return const VehicleResult(
            found: false, data: <String, dynamic>{}, source: 'mtt', status: 'not_found');
      default:
        throw ProviderException('MTT: error del servicio (HTTP ${resp.statusCode})',
            statusCode: resp.statusCode);
    }
  }
}
