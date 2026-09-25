/// Modelo tipificado del Motor PRT (Información del Vehículo + Revisión
/// Técnica oficial de prt.cl).
///
/// El parser clave-valor del backend/WebView garantiza que los valores no se
/// desplacen cuando una celda viene vacía (p. ej. N° Vin vacío en SJFX87):
///  - vin vacío        → la UI muestra "No informado", nunca "Tipo".
///  - combustible null → la UI muestra "No registrado", nunca una fecha.
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

  /// Bandera cruda enviada por el parser (es_gases del WebView).
  final bool _esGasesRaw;

  const PrtHistoryEntry({
    this.fecha = '',
    this.codPlanta = '',
    this.planta = '',
    this.certificado = '',
    this.vencimiento = '',
    this.estado = '',
    this.kilometraje = '',
    this.observaciones = '',
    bool esGasesRaw = false,
  }) : _esGasesRaw = esGasesRaw;

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
      esGasesRaw: j['es_gases'] == true,
    );
  }

  static String _s(dynamic v) => (v == null) ? '' : v.toString().trim();

  /// true si la planta, el certificado o el estado contienen "(g)" o
  /// "Gases" (case-insensitive), o el parser ya lo marcó.
  bool get esGases {
    if (_esGasesRaw) return true;
    final blob = '$planta $certificado $estado $observaciones'.toUpperCase();
    return blob.contains('(G)') || blob.contains('GASES');
  }

  /// Número oficial limpio del certificado: descarta sufijos de gases
  /// pegados ("(g)", "Revisión de Gases", "Sólo Gases") y devuelve solo el
  /// número (ej. "B1354000000274772").
  String get certificadoLimpio {
    var c = certificado.trim();
    if (c.isEmpty) return '';
    c = c.replaceAll(RegExp(r'\(\s*g\s*\)', caseSensitive: false), '');
    c = c.replaceAll(RegExp(r'revisi[oó]n\s+de\s+gases', caseSensitive: false), '');
    c = c.replaceAll(RegExp(r's[oó]lo\s+gases', caseSensitive: false), '');
    c = c.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Si tras la limpieza queda texto residual, extraer el número largo.
    final num = RegExp(r'[A-Z]{0,3}\d{7,}').firstMatch(c);
    if (num != null) return num.group(0)!;
    return c;
  }
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

  /// VIN seguro para UI: descarta encabezados residuales y texto de
  /// etiquetas ("Tipo", "N° VIN", "VIN"); nunca otro atributo desplazado.
  String get vinSeguro {
    final v = (vin ?? '').trim();
    if (v.isEmpty ||
        v.toUpperCase() == 'TIPO' ||
        v.toUpperCase() == 'N° VIN' ||
        v.toUpperCase() == 'Nº VIN' ||
        v.toUpperCase() == 'VIN' ||
        looksLikeDate(v)) {
      return 'No informado';
    }
    return v;
  }

  /// Combustible seguro para UI: descarta fechas o strings anómalos.
  String get combustibleSeguro {
    final c = (combustible ?? '').trim();
    if (c.isEmpty || RegExp(r'^\d{2}[-/]\d{2}[-/]\d{4}').hasMatch(c)) {
      return 'No registrado';
    }
    return c;
  }
}
