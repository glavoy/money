import 'dart:convert';

import 'package:flutter/services.dart';

class SyncConfig {
  const SyncConfig._({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
  });

  static const path = 'config/sync_config.json';

  final String supabaseUrl;
  final String supabasePublishableKey;

  static SyncConfig? _current;

  static bool get isConfigured => _current != null;

  static Future<SyncConfig> load() async {
    final current = _current;
    if (current != null) return current;

    final raw = await rootBundle.loadString(path);
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Sync config must be a JSON object.');
    }

    final url = _readString(json, 'SUPABASE_URL', 'supabaseUrl');
    final publishableKey = _readString(
      json,
      'SUPABASE_PUBLISHABLE_KEY',
      'SUPABASE_ANON_KEY',
      'supabasePublishableKey',
      'supabaseAnonKey',
    );

    if (url == null || publishableKey == null) {
      throw const FormatException(
        'Sync config must include SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.',
      );
    }

    return _current = SyncConfig._(
      supabaseUrl: url,
      supabasePublishableKey: publishableKey,
    );
  }

  static String? _readString(
    Map<String, dynamic> json,
    String key1, [
    String? key2,
    String? key3,
    String? key4,
    String? key5,
  ]) {
    for (final key in [key1, key2, key3, key4, key5]) {
      final value = key == null ? null : json[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }
}
