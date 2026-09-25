/// Modelo tipificado de la Ficha Base del Vehículo (Boostr / Padrón Civil).
///
/// `fromJson` es tolerante a valores vacíos, `0`, `null` y tipos mixtos
/// (int/string) — nunca lanza excepciones de casteo:
///  - strings  → `String?` ("" se conserva como "" para distinguirlo de
///    null; la UI decide mostrar "No informado").
///  - ints     → `int?` (0 se conserva como 0).
///  - dynamic  → se conserva el valor crudo (p. ej. valuation).
class VehicleBaseModel {
  final String? plate;
  final String? dv;
  final String? make;
  final String? model;
  final String? version;
  final int? year;
  final String? type;
  final String? engine;
  final String? engineSize;
  final String? chassis;
  final String? color;
  final int? doors;
  final String? transmission;
  final int? kilometers;
  final dynamic valuation;
  final String? gasType;
  final String? manufacturer;
  final String? region;
  final String? country;
  final String? ownerName;
  final String? ownerRut;
  final Map<String, dynamic>? owner;

  const VehicleBaseModel({
    this.plate,
    this.dv,
    this.make,
    this.model,
    this.version,
    this.year,
    this.type,
    this.engine,
    this.engineSize,
    this.chassis,
    this.color,
    this.doors,
    this.transmission,
    this.kilometers,
    this.valuation,
    this.gasType,
    this.manufacturer,
    this.region,
    this.country,
    this.ownerName,
    this.ownerRut,
    this.owner,
  });

  /// Lee un string sin casteos frágiles: null → null, resto → toString().trim().
  static String? _str(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s;
  }

  /// Lee un int tolerante: 0 → 0, "283961" → 283961, "" → null.
  static int? _int(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? null;
  }

  factory VehicleBaseModel.fromJson(Map<String, dynamic> j) {
    final ownerRaw = (j['owner'] is Map)
        ? Map<String, dynamic>.from(j['owner'] as Map)
        : null;
    return VehicleBaseModel(
      plate: _str(j['plate'] ?? j['patente']),
      dv: _str(j['dv']),
      make: _str(j['make'] ?? j['marca']),
      model: _str(j['model'] ?? j['modelo']),
      version: _str(j['version'] ?? j['version_modelo']),
      year: _int(j['year'] ?? j['anio']),
      type: _str(j['type'] ?? j['tipo'] ?? j['body_type']),
      engine: _str(j['engine'] ?? j['nro_motor']),
      engineSize: _str(j['engine_size'] ?? j['cilindrada']),
      chassis: _str(j['chassis'] ?? j['chasis'] ?? j['vin']),
      color: _str(j['color']),
      doors: _int(j['doors']),
      transmission: _str(j['transmission'] ?? j['transmision']),
      kilometers: _int(j['kilometers'] ?? j['kilometraje']),
      valuation: j['valuation'],
      gasType: _str(j['gas_type'] ?? j['combustible']),
      manufacturer: _str(j['manufacturer'] ?? j['fabricante']),
      region: _str(j['region']),
      country: _str(j['country'] ?? j['pais']),
      ownerName: _str(j['owner_name'] ?? ownerRaw?['fullname']),
      ownerRut: _str(j['owner_rut'] ?? ownerRaw?['documentNumber']),
      owner: ownerRaw,
    );
  }

  /// Convierte el modelo de vuelta al esquema unificado (payload completo,
  /// campos vacíos incluidos) para persistir en la caché local.
  Map<String, dynamic> toUnified() {
    return <String, dynamic>{
      'plate': plate ?? '',
      'patente': plate ?? '',
      'dv': dv ?? '',
      'make': make ?? '',
      'marca': make ?? '',
      'model': model ?? '',
      'modelo': model ?? '',
      'version': version ?? '',
      'version_modelo': version ?? '',
      'year': year ?? '',
      'anio': year ?? '',
      'type': type ?? '',
      'tipo': type ?? '',
      'engine': engine ?? '',
      'nro_motor': engine ?? '',
      'engine_size': engineSize ?? '',
      'cilindrada': engineSize ?? '',
      'chassis': chassis ?? '',
      'chasis': chassis ?? '',
      'vin': chassis ?? '',
      'color': color ?? '',
      'doors': doors ?? 0,
      'transmission': transmission ?? '',
      'transmision': transmission ?? '',
      'kilometers': kilometers ?? 0,
      'kilometraje': kilometers ?? 0,
      'valuation': valuation ?? 0,
      'gas_type': gasType ?? '',
      'combustible': gasType ?? '',
      'manufacturer': manufacturer ?? '',
      'fabricante': manufacturer ?? '',
      'region': region ?? '',
      'country': country ?? '',
      'pais': country ?? '',
      'owner': owner ?? <String, dynamic>{},
      'owner_name': ownerName ?? '',
      'owner_rut': ownerRut ?? '',
      'fuente': 'Boostr',
      'rt_estado': '',
      'rt_vencimiento': '',
      'historial_rt': <dynamic>[],
      'rt_disponible': false,
    };
  }
}
