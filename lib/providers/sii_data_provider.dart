import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../cache/provider_cache.dart';
import 'vehicle_data_provider.dart';

/// Caja SII (Tasación Fiscal Oficial — human-in-the-loop).
///
/// Flujo:
///  1. Caché local aislada `sii_cache_<PLATE>.json`: hits positivos con TTL
///     de 180 días (el avalúo fiscal y el permiso se fijan por decreto anual
///     y no varían dentro del año calendario); negativos con TTL de 7 días.
///  2. GET /api/patente/{PLATE}?provider=sii → si el backend ya tiene la
///     tasación en su base histórica (tasacion_fiscal presente), retorna
///     hit directo; además entrega `hints` (marca/modelo/año) del vehículo
///     para guiar el modal.
///  3. Si no hay dato (requiere_verificacion / 404), abre el modal WebView
///     oficial del SII (vehiculospubui) vía [openModal]; el humano resuelve
///     el captcha numérico del portal y el interceptor captura las filas de
///     tasación (código SII, montos de tasación y permiso).
///  4. Persiste en disco (ttlOverride 180d) y la capa superior sincroniza
///     con el backend (POST /api/vehicle/cache) para la base centralizada.
class SiiDataProvider extends VehicleDataProvider {
  SiiDataProvider({
    Future<Map<String, dynamic>?> Function(
            BuildContext context, String plate, Map<String, String> hints)?
        openModal,
  }) : _openModal = openModal;

  final Future<Map<String, dynamic>?> Function(
      BuildContext context, String plate, Map<String, String> hints)? _openModal;

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
    final t = _s(d['tasacion_fiscal'] ?? d['monto_tasacion'] ?? d['tasacion']);
    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isNotEmpty && int.tryParse(digits) != null;
  }

  @override
  Future<VehicleResult> fetch(String plate, {BuildContext? context}) async {
    final plateClean = plate.toUpperCase().trim();

    // 1) Base histórica del backend + hints del vehículo.
    final hints = <String, String>{};
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/patente/$plateClean?provider=sii'))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        final raw = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = (raw['data'] is Map)
            ? Map<String, dynamic>.from(raw['data'] as Map)
            : Map<String, dynamic>.from(raw);
        hints['marca'] = _s(data['marca'] ?? data['make']);
        hints['modelo'] = _s(data['modelo'] ?? data['model']);
        hints['anio'] = _s(data['anio'] ?? data['year']);
        if (_hasTasacion(data)) {
          return VehicleResult(found: true, data: data, source: 'sii', status: 'hit');
        }
      }
    } catch (_) {
      // Red caída o backend lento: pasar al flujo human-in-the-loop.
    }

    // 2) Modal WebView oficial SII (captcha + interceptor de resultados).
    if (context != null && _openModal != null) {
      final raw = await _openModal!(context, plateClean, hints);
      if (raw != null && (_hasTasacion(raw) || _hasFilaConTasacion(raw))) {
        final unified = _unify(plateClean, raw);
        await cache.write(plateClean,
            found: true,
            data: unified,
            source: 'sii',
            status: 'hit',
            ttlOverride: const Duration(days: 180));
        return VehicleResult(found: true, data: unified, source: 'sii', status: 'hit');
      }
    }

    return const VehicleResult(
        found: false, data: <String, dynamic>{}, source: 'sii', status: 'not_found');
  }

  bool _hasFilaConTasacion(Map<String, dynamic> raw) {
    final filas = raw['filas'];
    if (filas is! List || filas.isEmpty) return false;
    for (final f in filas) {
      if (f is Map) {
        final t = _s(f['monto_tasacion']);
        if (t.replaceAll(RegExp(r'[^0-9]'), '').isNotEmpty) return true;
      }
    }
    return false;
  }

  /// Normaliza el payload crudo del interceptor al modelo unificado.
  static Map<String, dynamic> _unify(String plate, Map<String, dynamic> raw) {
    Map<String, dynamic> row = <String, dynamic>{};
    final filas = raw['filas'];
    if (filas is List && filas.isNotEmpty && filas.first is Map) {
      row = Map<String, dynamic>.from(filas.first as Map);
    }
    // El modal promueve la mejor fila a nivel superior: esos campos mandan.
    for (final k in const [
      'codigo', 'marca', 'modelo', 'version', 'anio', 'tipo',
      'monto_tasacion', 'monto_permiso',
    ]) {
      if (raw[k] != null) row[k] = raw[k];
    }
    final marca = _s(row['marca'] ?? raw['marca']);
    final modelo = _s(row['modelo'] ?? raw['modelo'] ?? raw['model']);
    final version = _s(row['version'] ?? raw['version']);
    final anio = _s(row['anio'] ?? raw['anio'] ?? raw['anio_tasacion']);
    final tipo = _s(row['tipo'] ?? raw['tipo'] ?? raw['type']);

    return <String, dynamic>{
      'patente': plate,
      'fuente': 'SII',
      'tasacion_fiscal': _s(row['monto_tasacion'] ?? raw['tasacion_fiscal']),
      'permiso_circulacion': _s(row['monto_permiso'] ?? raw['permiso_circulacion']),
      'codigo_sii': _s(row['codigo'] ?? raw['codigo_sii'] ?? raw['code']),
      'anio_tasacion': anio,
      'marca': marca,
      'modelo': modelo,
      'version': version,
      'tipo_vehiculo': tipo,
      'anio': anio,
      'datos_homologacion': <String, dynamic>{
        'marca': marca,
        'modelo': modelo,
        'version': version,
        'anio': anio,
        'cilindrada': '',
        'combustible': '',
        'transmision': '',
      },
      // Campos ajenos al SII (RT, RNSTP/MTT): vacíos explícitos.
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
