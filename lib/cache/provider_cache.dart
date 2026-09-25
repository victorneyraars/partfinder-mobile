import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Caché local AISLADA por proveedor (archivos JSON con prefijo
/// `<namespace>_cache_`: prt_cache_, boostr_cache_, sii_cache_).
///
/// Estructura almacenada por patente:
///   {
///     "timestamp": ISO8601,
///     "status": "hit" | "empty" | "not_found",
///     "data": { ... }  // payload completo (campos vacíos incluidos)
///   }
///
/// Política de TTL:
///  - Datos válidos (hit): [ttl] (Boostr 30-90 días: datos de padrón
///    estáticos; PRT más corto por la vigencia de la revisión).
///  - Negative Caching (empty/not_found): [negativeTtl] para no repetir
///    llamadas que consuman cuota.
class ProviderCache {
  final String namespace;
  final Duration ttl;
  final Duration negativeTtl;

  const ProviderCache({
    required this.namespace,
    this.ttl = const Duration(days: 60),
    this.negativeTtl = const Duration(days: 7),
  });

  Future<File> _file(String plate) async {
    final dir = await getApplicationDocumentsDirectory();
    final sub = Directory('${dir.path}/provider_cache');
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    return File('${sub.path}/${namespace}_cache_${plate.toUpperCase()}.json');
  }

  /// Devuelve `{found, status, data, source}` si el registro está vigente;
  /// null si no existe o su TTL expiró (negativos usan [negativeTtl]).
  /// Si la entrada guardó [ttlOverride], se respeta su `expires_at`.
  Future<Map<String, dynamic>?> read(String plate) async {
    try {
      final f = await _file(plate);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final status = (j['status'] ?? '').toString();
      final isNegative = status != 'hit';
      final expiresRaw = (j['expires_at'] ?? '').toString();
      final DateTime? expires = expiresRaw.isEmpty ? null : DateTime.tryParse(expiresRaw);
      if (expires != null) {
        if (DateTime.now().isAfter(expires)) return null;
      } else {
        final ts = DateTime.tryParse((j['timestamp'] ?? j['ts'] ?? '').toString());
        if (ts == null) return null;
        final limit = isNegative ? negativeTtl : ttl;
        if (DateTime.now().difference(ts) > limit) return null;
      }
      return <String, dynamic>{
        'found': status == 'hit',
        'status': status,
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
  /// [ttlOverride] permite TTL dinámico por tipo de dato (p. ej. MTT:
  /// particular 60d vs transporte público 30d).
  Future<void> write(
    String plate, {
    required bool found,
    required Map<String, dynamic> data,
    required String source,
    String status = 'hit',
    Duration? ttlOverride,
  }) async {
    try {
      final f = await _file(plate);
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'timestamp': DateTime.now().toIso8601String(),
        'status': found ? 'hit' : (status == 'hit' ? 'empty' : status),
        'data': data,
        'source': source,
        'expires_at': ttlOverride == null
            ? null
            : DateTime.now().add(ttlOverride).toIso8601String(),
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
