import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/database.dart';
import '../shared/providers.dart';

class FetchedFxRates {
  const FetchedFxRates({
    required this.usdUgx,
    required this.usdCad,
    required this.apiDate,
  });

  final double usdUgx;
  final double usdCad;
  final DateTime apiDate;

  double get cadUgx => usdUgx / usdCad;
}

/// Fetches USD-based rates for [date] and stores them with source=api.
///
/// Today's rate uses the current endpoint that has worked well for the app.
/// Older dates use Frankfurter's public historical endpoint. API rows do not
/// overwrite manual rows for the same date.
Future<String?> fetchRatesForDate(
  AppDatabase db,
  DateTime date, {
  http.Client? client,
  bool skipIfExists = false,
}) async {
  final day = DateTime.utc(date.year, date.month, date.day);
  if (skipIfExists && await db.getRateForDate(day) != null) {
    return null;
  }

  final closeClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    final fetched = _isToday(day)
        ? await _fetchLatestRates(httpClient)
        : await _fetchHistoricalRates(httpClient, day);
    await db.upsertRate(
      date: day,
      usdUgx: fetched.usdUgx,
      cadUgx: fetched.cadUgx,
      usdCad: fetched.usdCad,
      source: FxSource.api,
      newId: uuid.v4,
    );
    return null;
  } catch (e) {
    debugPrint('FX fetch failed: $e');
    return e.toString();
  } finally {
    if (closeClient) httpClient.close();
  }
}

Future<String?> fetchTodaysRates(AppDatabase db) {
  return fetchRatesForDate(db, DateTime.now());
}

Future<String?> fetchTodaysRatesIfMissing(AppDatabase db) {
  return fetchRatesForDate(db, DateTime.now(), skipIfExists: true);
}

bool _isToday(DateTime day) {
  final now = DateTime.now().toUtc();
  return day.year == now.year && day.month == now.month && day.day == now.day;
}

Future<FetchedFxRates> _fetchLatestRates(http.Client client) async {
  final response = await client
      .get(Uri.parse('https://open.er-api.com/v6/latest/USD'))
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw Exception('Rate server returned ${response.statusCode}');
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  if (body['result'] != 'success') {
    throw Exception('Rate server error: ${body['error-type'] ?? 'unknown'}');
  }
  final rates = body['rates'] as Map<String, dynamic>;
  final usdUgx = (rates['UGX'] as num?)?.toDouble();
  final usdCad = (rates['CAD'] as num?)?.toDouble();
  if (usdUgx == null || usdCad == null) {
    throw Exception('UGX or CAD missing from rate data');
  }
  return FetchedFxRates(
    usdUgx: usdUgx,
    usdCad: usdCad,
    apiDate: DateTime.now().toUtc(),
  );
}

Future<FetchedFxRates> _fetchHistoricalRates(
  http.Client client,
  DateTime date,
) async {
  final uri = Uri.https('api.frankfurter.dev', '/v2/rates', {
    'date': _dateOnly(date),
    'base': 'USD',
    'quotes': 'UGX,CAD',
  });
  final response = await client.get(uri).timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw Exception('Historical rate server returned ${response.statusCode}');
  }
  return parseFrankfurterRates(response.body);
}

@visibleForTesting
FetchedFxRates parseFrankfurterRates(String content) {
  final decoded = jsonDecode(content);
  if (decoded is List) {
    return _parseFrankfurterRows(decoded);
  }
  if (decoded is Map<String, dynamic>) {
    return _parseFrankfurterMap(decoded);
  }
  throw const FormatException('Unexpected historical rate response');
}

FetchedFxRates _parseFrankfurterRows(List rows) {
  double? usdUgx;
  double? usdCad;
  DateTime? apiDate;
  for (final row in rows.whereType<Map>()) {
    final quote = row['quote']?.toString().toUpperCase();
    final rate = (row['rate'] as num?)?.toDouble();
    final date = DateTime.tryParse(row['date']?.toString() ?? '');
    if (date != null) apiDate ??= date;
    if (quote == 'UGX') usdUgx = rate;
    if (quote == 'CAD') usdCad = rate;
  }
  return _validatedHistoricalRates(usdUgx, usdCad, apiDate);
}

FetchedFxRates _parseFrankfurterMap(Map<String, dynamic> body) {
  final rates = body['rates'];
  if (rates is! Map) {
    throw const FormatException('Historical rate response has no rates');
  }
  final usdUgx = (rates['UGX'] as num?)?.toDouble();
  final usdCad = (rates['CAD'] as num?)?.toDouble();
  final apiDate = DateTime.tryParse(body['date']?.toString() ?? '');
  return _validatedHistoricalRates(usdUgx, usdCad, apiDate);
}

FetchedFxRates _validatedHistoricalRates(
  double? usdUgx,
  double? usdCad,
  DateTime? apiDate,
) {
  if (usdUgx == null || usdCad == null) {
    throw const FormatException('UGX or CAD missing from historical rate data');
  }
  return FetchedFxRates(
    usdUgx: usdUgx,
    usdCad: usdCad,
    apiDate: apiDate ?? DateTime.now().toUtc(),
  );
}

String _dateOnly(DateTime value) {
  final utc = value.toUtc();
  final year = utc.year.toString().padLeft(4, '0');
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}
