import 'package:flutter/widgets.dart';

import '../cache/provider_cache.dart';

/// Resultado normalizado de una consulta a un proveedor ("caja").
class VehicleResult {
  /// false cuando la patente no existe en la fuente (o el proveedor no
  /// devolvió datos de vehículo).
  final bool found;

  /// Payload completo con el esquema fijo (campos vacíos incluidos como '').
  final Map<String, dynamic> data;

  /// Identificador de la fuente: 'prt' | 'boostr' | 'sii'.
  final String source;

  /// 'hit' (datos), 'empty' (200 sin datos de vehículo) o 'not_found' (404).
  final String status;

  const VehicleResult({
    required this.found,
    this.data = const <String, dynamic>{},
    required this.source,
    this.status = 'hit',
  });

  Map<String, dynamic> toJson() => {
        'found': found,
        'data': data,
        'source': source,
        'status': found ? 'hit' : status,
      };

  static VehicleResult fromJson(Map<String, dynamic> j) => VehicleResult(
        found: j['found'] == true,
        data: (j['data'] is Map)
            ? Map<String, dynamic>.from(j['data'] as Map)
            : const <String, dynamic>{},
        source: (j['source'] ?? '').toString(),
        status: (j['status'] ?? 'hit').toString(),
      );
}

/// Excepción controlada de proveedor: permite que la capa superior decida
/// un fallback o muestre un aviso específico (cuota, red, 5xx).
class ProviderException implements Exception {
  final String message;
  final int? statusCode;

  const ProviderException(this.message, {this.statusCode});

  @override
  String toString() => 'ProviderException($statusCode): $message';
}

/// Interfaz abstracta del patrón Provider ("cajas").
///
/// Implementaciones: [PrtDataProvider] (Motor PRT P2P), BoostrDataProvider
/// (Boostr API) y, a futuro, SiiDataProvider. Cada implementación posee su
/// propio namespace de caché local ([ProviderCache]) aislado por proveedor.
abstract class VehicleDataProvider {
  /// Identificador del proveedor ('prt', 'boostr', 'sii').
  String get id;

  /// Caché local aislada del proveedor (prefijos prt_cache_, boostr_cache_,
  /// sii_cache_) con Negative Caching y TTL configurable.
  ProviderCache get cache;

  /// Consulta el vehículo por patente. [context] solo se usa en flujos
  /// human-in-the-loop (el modal reCAPTCHA del Motor PRT).
  Future<VehicleResult> fetch(String plate, {BuildContext? context});
}
