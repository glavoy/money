import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/database.dart';
import '../shared/providers.dart';

/// Fetches today's USD-based rates from the free open.er-api.com endpoint
/// (supports UGX and CAD) and stores them with source=api, which never
/// overwrites a manual entry for the same day.
///
/// Returns null on success, or an error message.
Future<String?> fetchTodaysRates(AppDatabase db) async {
  try {
    final response = await http
        .get(Uri.parse('https://open.er-api.com/v6/latest/USD'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      return 'Rate server returned ${response.statusCode}';
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['result'] != 'success') {
      return 'Rate server error: ${body['error-type'] ?? 'unknown'}';
    }
    final rates = body['rates'] as Map<String, dynamic>;
    final usdUgx = (rates['UGX'] as num?)?.toDouble();
    final usdCad = (rates['CAD'] as num?)?.toDouble();
    if (usdUgx == null || usdCad == null) {
      return 'UGX or CAD missing from rate data';
    }
    final cadUgx = usdUgx / usdCad;
    await db.upsertRate(
      date: DateTime.now(),
      usdUgx: usdUgx,
      cadUgx: cadUgx,
      usdCad: usdCad,
      source: FxSource.api,
      newId: uuid.v4,
    );
    return null;
  } catch (e) {
    debugPrint('FX fetch failed: $e');
    return e.toString();
  }
}
