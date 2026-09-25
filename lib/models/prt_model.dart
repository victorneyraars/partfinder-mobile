/// Modelo tipificado del Motor PRT (Información del Vehículo + Revisión
/// Técnica oficial de prt.cl).
///
/// El parser clave-valor del backend/WebView garantiza que los valores no se
/// desplacen cuando una celda viene vacía (p. ej. N° Vin vacío en SJFX87):
///  - vin vacío        → null (la UI muestra "No informado", nunca "Tipo").
///  - combustible null → null (la UI muestra "No registrado", nunca una
///    fecha de vencimiento).
///  - La fecha de vencimiento general viaja en rt_vencimiento y se pinta en
///    la tarjeta destacada de vigencia oficial.
class PrtHistoryEntry {
  final String fecha;
  final String codPlanta;
  final String planta;
  final String certificado;
  final String vencimiento;
  final String estado;
  final String kilometraje;
  final String observaciones;
  final bool esGases;

  const PrtHistoryEntry({
    this.fecha = '',
    this.codPlanta = '',
    this.planta = '',
    this.certificado = '',
    this.vencimiento = '',
    this.estado = '',
    this.kilometraje = '',
    this.observaciones = '',
    this.esGases = false,
  });

  factory PrtHistoryEntry.fromJson(dynamic j) {
    if (j is! Map) {
      return const PrtHistoryEntry();
    }
    return PrtHistoryEntry(
      fecha: _s(j['fecha']),
      codPlanta: _s(j['cod_planta']),
      planta: _s(j['planta']),
      certificado: _s(j['certificado']),
      vencimiento: _s(j['vencimiento']),
      estado: _s(j['estado']),
      kilometraje: _s(j['kilometraje']),
      observaciones: _s(j['observaciones']),
      esGases: j['es_gases'] == true || (j['observaciones'] ?? '').toString().toLowerCase().contains('gas'),
    );
  }

  static String _s(dynamic v) => (v == null) ? '' : v.toString().trim();
}

class PrtVehicleData {
  final String patente;
  final String tipo;
  final String marca;
  final String modelo;
  final String anio;
  final String nroMotor;
  final String chasis;
  final String vin;
  final String color;
  final String combustible;
  final String pbv;
  final String sello;
  final String rtEstado;
  final String rtVencimiento;
  final List<PrtHistoryEntry> historial;

  const PrtVehicleData({
    this.patente = '',
    this.tipo = '',
    this.marca = '',
    this.modelo = '',
    this.anio = '',
    this.nroMotor = '',
    this.chasis = '',
    this.vin = '',
    this.color = '',
    this.combustible = '',
    this.pbv = '',
    this.sello = '',
    this.rtEstado = '',
    this.rtVencimiento = '',
    this.historial = const [],
  });

  /// fromJson tolerante: "" se preserva como "" (nunca lanza casteos).
  factory PrtVehicleData.fromJson(Map<String, dynamic> j) {
    final historialRaw = (j['historial_rt'] is List)
        ? (j['historial_rt'] as List)
        : const <dynamic>[];
    return PrtVehicleData(
      patente: _s(j['patente'] ?? j['plate']),
      tipo: _s(j['tipo'] ?? j['tipo_vehiculo'] ?? j['type']),
      marca: _s(j['marca'] ?? j['make']),
      modelo: _s(j['modelo'] ?? j['model']),
      anio: _s(j['anio'] ?? j['year']),
      nroMotor: _s(j['nro_motor'] ?? j['engine']),
      chasis: _s(j['chasis']),
      vin: _s(j['vin']),
      color: _s(j['color']),
      combustible: _s(j['combustible'] ?? j['gas_type']),
      pbv: _s(j['pbv']),
      sello: _s(j['sello'] ?? j['seal_type']),
      rtEstado: _s(j['rt_estado']),
      rtVencimiento: _s(j['rt_vencimiento']),
      historial: historialRaw
          .whereType<Map>()
          .map((e) => PrtHistoryEntry.fromJson(e))
          .toList(),
    );
  }

  static String _s(dynamic v) => (v == null) ? '' : v.toString().trim();

  /// true si el valor parece una fecha (protege contra datos desplazados).
  static bool looksLikeDate(String v) =>
      RegExp(r'^\d{1,2}[/-]\d{1,2}[/-]\d{2,4}$').hasMatch(v.trim());

  /// VIN seguro para UI: nunca otro atributo desplazado.
  String get vinSeguro {
    final v = vin;
    if (v.isEmpty || looksLikeDate(v)) return '';
    return v;
  }

  /// Combustible seguro para UI: nunca una fecha de vencimiento.
  String get combustibleSeguro {
    final v = combustible;
    if (v.isEmpty || looksLikeDate(v)) return '';
    return v;
  }
}
