import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Tracking anonimo de uso. Genera un device_id persistente y envia
/// eventos al backend. NUNCA bloquea la app: todos los errores son silenciosos.
class UsageTracker {
  static const String _baseUrl = 'https://api.studiodigital360.com';
  static const String _deviceIdKey = 'pf_device_id';
  static const String _appVersion = '1.0.0';

  static final UsageTracker _instance = UsageTracker._internal();
  factory UsageTracker() => _instance;
  UsageTracker._internal();

  String? _deviceId;
  String? _platform;
  bool _initialized = false;

  /// Inicializa el tracker. Idempotente: llamar varias veces no genera
  /// device_id nuevo.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_deviceIdKey);
      if (id == null || id.isEmpty) {
        id = const Uuid().v4();
        await prefs.setString(_deviceIdKey, id);
      }
      _deviceId = id;

      if (Platform.isAndroid) {
        _platform = 'android';
      } else if (Platform.isIOS) {
        _platform = 'ios';
      } else {
        _platform = Platform.operatingSystem;
      }

      _initialized = true;
      debugPrint('[USAGE] init device=$_deviceId platform=$_platform');
    } catch (e) {
      debugPrint('[USAGE] init error: $e');
    }
  }

  /// Envia un evento. Nunca lanza excepcion.
  Future<void> track(
    String eventType, {
    String? plate,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_initialized) {
      await init();
    }
    if (_deviceId == null) return;

    try {
      final body = <String, dynamic>{
        'device_id': _deviceId,
        'event_type': eventType,
        'platform': _platform,
        'app_version': _appVersion,
      };
      if (plate != null && plate.isNotEmpty) body['plate'] = plate;
      if (metadata != null && metadata.isNotEmpty) body['metadata'] = metadata;

      await http
          .post(
            Uri.parse('$_baseUrl/api/usage/track'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[USAGE] track error: $e');
    }
  }

  String? get deviceId => _deviceId;
}
