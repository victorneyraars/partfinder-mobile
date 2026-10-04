import 'dart:convert';
import 'package:http/http.dart' as http;

/// Decodifica el cuerpo de una respuesta HTTP como UTF-8.
///
/// El paquete `http` de Dart asume Latin-1 cuando el `Content-Type` no
/// declara `charset=utf-8`. FastAPI devuelve `application/json` a secas,
/// así que "Vehículo"/"Público"/"Región" llegaban como
/// "VehÃculo"/"PÃºblico"/"RegiÃ³n" a la UI.
///
/// Se decodifican los bytes crudos en UTF-8 explícito para evitar mojibake
/// en acentos y ñ en todo el JSON que devuelve el backend.
dynamic decodeJsonUtf8(http.Response resp) =>
    jsonDecode(utf8.decode(resp.bodyBytes));
