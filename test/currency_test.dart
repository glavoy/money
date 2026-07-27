import 'package:flutter_test/flutter_test.dart';
import 'package:money/shared/currency.dart';

void main() {
  group('trimmedAmount', () {
    test('preserves cents instead of truncating to a whole number', () {
      expect(trimmedAmount(143.28), '143.28');
    });

    test('drops insignificant trailing zeros', () {
      expect(trimmedAmount(143.0), '143');
      expect(trimmedAmount(0), '0');
    });

    test('rounds to 2 decimal places', () {
      expect(trimmedAmount(143.999), '144');
      expect(trimmedAmount(143.126), '143.13');
    });
  });
}
