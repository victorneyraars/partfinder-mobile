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

  const VehicleResult({
    required this.found,
    this.data = const <String, dynamic>{},
    required this.source,
  });

  Map<String, dynamic> toJson() => {
        'found': found,
        'data': data,
        'source': source,
      };

  static VehicleResult fromJson(Map<String, dynamic> j) => VehicleResult(
        found: j['found'] == true,
        data: (j['data'] is Map)
            ? Map<String, dynamic>.from(j['data'] as Map)
            : const <String, dynamic>{},
        source: (j['source'] ?? '').toString(),
      );
}

/// Interfaz abstracta del patrón Provider ("cajas").
///
/// Implementaciones: [PrtDataProvider] (Motor PRT P2P), BoostrDataProvider
/// (Boostr API) y, a futuro, SiiDataProvider. Cada implementación posee su
/// propio namespace de caché local ([ProviderCache]) aislado por proveedor.
abstract class VehicleDataProvider {
  /// Identificador del proveedor ('prt', 'boostr', 'sii').
  String get id;

  /// Caché local aislada del proveedor (prefijos cache_prt_, cache_boostr_,
  /// cache_sii_) con soporte de Negative Caching y TTL configurable.
  ProviderCache get cache;

  /// Consulta el vehículo por patente. [context] solo se usa en flujos
  /// human-in-the-loop (el modal reCAPTCHA del Motor PRT).
  Future<VehicleResult> fetch(String plate, {BuildContext? context});
}
