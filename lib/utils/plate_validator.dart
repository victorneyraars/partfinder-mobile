/// Motor Normativo de Patentes Chilenas (Registro Civil).
///
/// Formatos oficiales:
///  - NUEVO   (4 letras + 2 dígitos): solo las 18 consonantes autorizadas
///    B C D F G H J K L P R S T V W X Y Z (sin vocales, sin M, sin Q, sin Ñ).
///  - CLÁSICO (2 letras + 4 dígitos): cualquier letra A-Z salvo Ñ.
///  - MOTO    (3 letras + 2 dígitos): cualquier letra A-Z salvo Ñ.
library;

class PlateValidationResult {
  /// true solo cuando el texto completo es una patente válida.
  final bool valid;

  /// 'NUEVO' | 'CLASICO' | 'MOTO' | null (aún incompleto/desconocido).
  final String? format;

  /// Etiqueta legible para la UI del selector de formato.
  final String formatLabel;

  /// Mensaje educativo (vacío si no hay error normativo que explicar).
  final String message;

  /// Posición (0-based sobre el texto limpio) de la letra problemática.
  final int? errorPos;

  const PlateValidationResult({
    required this.valid,
    required this.format,
    required this.formatLabel,
    this.message = '',
    this.errorPos,
  });

  bool get hasError => message.isNotEmpty && !valid;
}

class ChileanPlateEngine {
  ChileanPlateEngine._();

  /// Las 18 consonantes autorizadas en el formato nuevo (AA-BB-00 moderno).
  static const String consonantesNuevo = 'BCDFGHJKLPRSTVWXYZ';

  /// Limpia la entrada: mayúsculas, sin espacios/guiones/puntos.
  static String clean(String input) =>
      input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9Ñ]'), '');

  static String _formatLabel(String text) {
    if (RegExp(r'^[A-ZÑ]{4}\d{2}$').hasMatch(text)) return 'AUTO NUEVO (4L+2N)';
    if (RegExp(r'^[A-ZÑ]{2}\d{4}$').hasMatch(text)) return 'CLÁSICO (2L+4N)';
    if (RegExp(r'^[A-ZÑ]{3}\d{2}$').hasMatch(text)) return 'MOTO';
    return text.isEmpty ? 'SIN FORMATO' : 'INGRESANDO...';
  }

  static String _forbiddenMessage(String ch) {
    if ('AEIOU'.contains(ch)) {
      return 'La letra "$ch" es una vocal. El formato nuevo (4 letras + 2 '
          'dígitos) solo usa consonantes: B C D F G H J K L P R S T V W X Y Z.';
    }
    if (ch == 'M') {
      return 'La letra "M" está excluida de las patentes chilenas nuevas '
          '(evita confusiones con N y W).';
    }
    if (ch == 'Q') {
      return 'La letra "Q" está excluida: no forma parte de las patentes '
          'chilenas vigentes.';
    }
    if (ch == 'Ñ') {
      return 'La "Ñ" no se usa en las patentes chilenas (norma de lectura '
          'internacional).';
    }
    return 'La letra "$ch" no está autorizada en el formato nuevo.';
  }

  /// Valida la patente completa o en progreso de escritura.
  ///
  /// Devuelve:
  ///  - `valid: true` + `format` cuando el texto es una patente íntegra
  ///    (NUEVO / CLASICO / MOTO).
  ///  - `valid: false` + `message`/`errorPos` cuando se detecta una letra
  ///    prohibida en territorio del formato nuevo (para shake + banner).
  ///  - `valid: false` sin mensaje para textos incompletos pero sin errores.
  static PlateValidationResult validate(String plate) {
    final text = clean(plate);
    if (text.isEmpty) {
      return const PlateValidationResult(
          valid: false, format: null, formatLabel: 'SIN FORMATO');
    }

    // ===== Formatos completos =====
    if (RegExp(r'^[A-Z]{2}\d{4}$').hasMatch(text)) {
      return PlateValidationResult(
          valid: true, format: 'CLASICO', formatLabel: 'CLÁSICO (2L+4N)');
    }
    if (RegExp(r'^[A-Z]{3}\d{2}$').hasMatch(text)) {
      return PlateValidationResult(
          valid: true, format: 'MOTO', formatLabel: 'MOTO');
    }
    if (RegExp(r'^[A-Z]{4}\d{2}$').hasMatch(text)) {
      final letters = text.substring(0, 4);
      for (int i = 0; i < 4; i++) {
        final ch = letters[i];
        if (!consonantesNuevo.contains(ch)) {
          return PlateValidationResult(
            valid: false,
            format: 'NUEVO',
            formatLabel: 'AUTO NUEVO (4L+2N)',
            message: _forbiddenMessage(ch),
            errorPos: i,
          );
        }
      }
      return const PlateValidationResult(
          valid: true, format: 'NUEVO', formatLabel: 'AUTO NUEVO (4L+2N)');
    }

    // ===== Ñ excluida en TODOS los formatos (clásico/moto incluidos) =====
    final nIdx = text.indexOf('Ñ');
    if (nIdx >= 0) {
      final isClassicShape = RegExp(r'^[A-ZÑ]{2}\d{0,4}$').hasMatch(text);
      final isMotoShape = RegExp(r'^[A-ZÑ]{3}\d{0,2}$').hasMatch(text);
      if (isClassicShape || isMotoShape) {
        return PlateValidationResult(
          valid: false,
          format: null,
          formatLabel: _formatLabel(text),
          message: _forbiddenMessage('Ñ'),
          errorPos: nIdx,
        );
      }
    }

    // ===== En progreso: detectar letras prohibidas en territorio nuevo =====
    // El territorio "nuevo" comienza cuando hay 3+ letras al inicio, o bien
    // 4 letras seguidas de dígitos; los prefijos de 1-2 letras se reservan
    // para el formato clásico (donde las vocales SÍ existen).
    final leading = RegExp(r'^[A-ZÑ]{1,4}').firstMatch(text);
    if (leading != null) {
      final letters = leading.group(0)!;
      final digits = text.length - letters.length;
      final isClassicProgress =
          RegExp(r'^[A-ZÑ]{0,2}\d{1,4}$').hasMatch(text);
      final isMotoProgress = RegExp(r'^[A-ZÑ]{3}\d{1,2}$').hasMatch(text);

      if (!isClassicProgress && !isMotoProgress) {
        // Revisar solo las posiciones de letra que exceden el espacio del
        // clásico (>= índice 2) o el bloque completo si ya hay dígitos.
        for (int i = 0; i < letters.length; i++) {
          if (i < 2 && digits == 0 && letters.length < 4) continue;
          final ch = letters[i];
          if (ch == 'Ñ' ||
              (!consonantesNuevo.contains(ch) && letters.length >= 3)) {
            return PlateValidationResult(
              valid: false,
              format: null,
              formatLabel: _formatLabel(text),
              message: _forbiddenMessage(ch),
              errorPos: i,
            );
          }
        }
      }
    }

    return PlateValidationResult(
        valid: false, format: null, formatLabel: _formatLabel(text));
  }

  /// Hint rápido del formato para el selector animado (auto-switch).
  static String formatHint(String plate) {
    final text = clean(plate);
    return _formatLabel(text);
  }
}
