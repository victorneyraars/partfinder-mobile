import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Caché local AISLADA por proveedor (archivos JSON con prefijo de
/// namespace: cache_prt_, cache_boostr_, cache_sii_).
///
/// Características:
///  - Almacena el payload completo con campos vacíos explícitos ('').
///  - Negative Caching: los resultados "no encontrado" también se persisten
///    con su propio TTL para no repetir consultas ni consumir cuotas/captchas.
///  - TTL configurable por registro positivo y negativo.
class ProviderCache {
  final String namespace;
  final Duration ttl;
  final Duration negativeTtl;

  const ProviderCache({
    required this.namespace,
    this.ttl = const Duration(days: 3),
    this.negativeTtl = const Duration(hours: 12),
  });

  Future<File> _file(String plate) async {
    final dir = await getApplicationDocumentsDirectory();
    final sub = Directory('${dir.path}/provider_cache');
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    return File('${sub.path}/cache_${namespace}_${plate.toUpperCase()}.json');
  }

  /// Devuelve `{found, data, source}` si el registro está vigente; null si
  /// no existe o su TTL expiró (los negativos usan [negativeTtl]).
  Future<Map<String, dynamic>?> read(String plate) async {
    try {
      final f = await _file(plate);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final ts = DateTime.tryParse((j['ts'] ?? '').toString());
      if (ts == null) return null;
      final isNegative = j['found'] != true;
      final limit = isNegative ? negativeTtl : ttl;
      if (DateTime.now().difference(ts) > limit) return null;
      return <String, dynamic>{
        'found': j['found'] == true,
        'data': (j['data'] is Map)
            ? Map<String, dynamic>.from(j['data'] as Map)
            : <String, dynamic>{},
        'source': (j['source'] ?? '').toString(),
      };
    } catch (_) {
      return null;
    }
  }

  /// Persiste el resultado (positivo o negativo) con campos vacíos intactos.
  Future<void> write(
    String plate, {
    required bool found,
    required Map<String, dynamic> data,
    required String source,
  }) async {
    try {
      final f = await _file(plate);
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'ts': DateTime.now().toIso8601String(),
        'found': found,
        'data': data,
        'source': source,
      }));
    } catch (_) {}
  }

  /// Invalida manualmente el registro de una patente.
  Future<void> invalidate(String plate) async {
    try {
      final f = await _file(plate);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
