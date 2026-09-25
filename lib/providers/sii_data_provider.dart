import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cache/provider_cache.dart';
import 'vehicle_data_provider.dart';

/// Caja SII (Tasación Fiscal Oficial — motor local por Decreto Exento).
///
/// SIN modal ni scraping: el backend resuelve la tasación desde la tabla
/// `sii_tasaciones` (archivos oficiales liv2026.xlsx / pes2026.xlsx del
/// SII, normalizados sin tildes/uppercase).
///
/// Flujo:
///  1. GET /api/patente/{PLATE}?provider=sii → el backend identifica
///     marca/modelo/año (query → ficha base interna → Boostr) y consulta
///     las tablas oficiales:
///       - 1 fila  → exact_match: true  (montos + código exactos).
///       - N filas → exact_match: false (rangos + lista de versiones).
///       - 0 filas → 404 "Vehículo no tipificado en tablas oficiales SII".
///  2. Caché local aislada `sii_cache_<PLATE>.json` con TTL de 180 días
///     (el avalúo fiscal se fija por decreto anual); negativos 7 días.
///     `invalidate()` soporta el refresco forzado desde la UI.
class SiiDataProvider extends VehicleDataProvider {
  static const String _base = 'https://api.studiodigital360.com';

  @override
  String get id => 'sii';

  @override
  ProviderCache get cache => const ProviderCache(
        namespace: 'sii',
        ttl: Duration(days: 180),
        negativeTtl: Duration(days: 7),
      );

  static String _s(dynamic v) => (v ?? '').toString().trim();

  bool _hasTasacion(Map<String, dynamic> d) {
    final t = _s(d['tasacion_fiscal'] ?? d['monto_tasacion']);
    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isNotEmpty && int.tryParse(digits) != null;
  }

  @override
  Future<VehicleResult> fetch(String plate, {BuildContext? context}) async {
    final plateClean = plate.toUpperCase().trim();

    http.Response resp;
    try {
      resp = await http
          .get(Uri.parse('$_base/api/patente/$plateClean?provider=sii'))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ProviderException('SII: error de red ($e)');
    }

    switch (resp.statusCode) {
      case 200:
        final raw = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = (raw['data'] is Map)
            ? Map<String, dynamic>.from(raw['data'] as Map)
            : Map<String, dynamic>.from(raw);
        final unified = _unify(plateClean, data);
        await cache.write(plateClean,
            found: true,
            data: unified,
            source: 'sii',
            status: 'hit',
            ttlOverride: const Duration(days: 180));
        return VehicleResult(found: true, data: unified, source: 'sii', status: 'hit');
      case 404:
        return const VehicleResult(
            found: false, data: <String, dynamic>{}, source: 'sii', status: 'not_found');
      default:
        throw ProviderException('SII: error del servicio (HTTP ${resp.statusCode})',
            statusCode: resp.statusCode);
    }
  }

  /// Normaliza la respuesta del motor local al modelo unificado, con los
  /// campos ajenos al SII (RT, RNSTP/MTT) vacíos explícitos.
  static Map<String, dynamic> _unify(String plate, Map<String, dynamic> raw) {
    final versionesRaw = (raw['versiones'] is List)
        ? List<dynamic>.from(raw['versiones'] as List)
        : const <dynamic>[];
    final homoRaw = (raw['datos_homologacion'] is Map)
        ? Map<String, dynamic>.from(raw['datos_homologacion'] as Map)
        : const <String, dynamic>{};
    final marca = _s(raw['marca'] ?? homoRaw['marca']);
    final modelo = _s(raw['modelo'] ?? homoRaw['modelo']);
    final anio = _s(raw['anio'] ?? raw['anio_tasacion'] ?? homoRaw['anio']);

    return <String, dynamic>{
      'patente': plate,
      'fuente': 'SII',
      'exact_match': raw['exact_match'] == true,
      'tasacion_fiscal': _s(raw['tasacion_fiscal']),
      'permiso_circulacion': _s(raw['permiso_circulacion']),
      'codigo_sii': _s(raw['codigo_sii']),
      'anio_tasacion': _s(raw['anio_tasacion'] ?? anio),
      'anio_tributario': _s(raw['anio_tributario']),
      'categoria': _s(raw['categoria']),
      'rango_tasacion': (raw['rango_tasacion'] is Map)
          ? Map<String, dynamic>.from(raw['rango_tasacion'] as Map)
          : const <String, dynamic>{},
      'rango_permiso': (raw['rango_permiso'] is Map)
          ? Map<String, dynamic>.from(raw['rango_permiso'] as Map)
          : const <String, dynamic>{},
      'versiones': versionesRaw,
      'marca': marca,
      'modelo': modelo,
      'version': _s(raw['version'] ?? homoRaw['version']),
      'tipo_vehiculo': _s(raw['tipo_vehiculo']),
      'anio': anio,
      'datos_homologacion': <String, dynamic>{
        'marca': marca,
        'modelo': modelo,
        'version': _s(homoRaw['version'] ?? raw['version']),
        'anio': anio,
        'cilindrada': _s(homoRaw['cilindrada']),
        'combustible': _s(homoRaw['combustible']),
        'transmision': _s(homoRaw['transmision']),
      },
      // Campos ajenos al SII: vacíos explícitos.
      'rt_estado': '',
      'rt_vencimiento': '',
      'historial_rt': <dynamic>[],
      'rt_disponible': false,
      'es_transporte_publico': false,
      'tipo_servicio': '',
      'estado_servicio': '',
      'region': '',
      'folio_flota': '',
      'fecha_vencimiento_permiso': '',
      'secciones': <dynamic>[],
    };
  }
}
