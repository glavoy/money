# Repository Guidelines

## Project Structure & Module Organization

This is a Flutter money tracker for Android, Windows, and macOS. Main Dart code lives in `lib/`. Use `lib/features/<feature>/` for screen-level UI such as `quick_add`, `transactions`, `accounts`, `reports`, `settings`, and `import`. Shared app services belong in `lib/shared/`, sync code in `lib/sync/`, and Drift database code in `lib/data/`. The generated Drift file is `lib/data/database.g.dart`; regenerate it after schema changes. Tests live in `test/` and mirror user flows or data modules, for example `quick_add_flow_test.dart` and `database_test.dart`. Platform folders (`android/`, `windows/`, `macos/`) should only change for platform integration work. Supabase setup SQL is in `supabase/schema.sql`, and spreadsheet import tooling is in `tools/import_xlsx.py`.

## Build, Test, and Development Commands

- `flutter pub get`: install Dart and Flutter dependencies.
- `dart run build_runner build`: regenerate Drift code after database schema edits.
- `flutter analyze`: run static analysis with `flutter_lints`.
- `flutter test`: run all unit and widget tests.
- `flutter run -d windows`: launch the app locally on Windows; replace the device id for Android or macOS.
- `flutter build apk`, `flutter build windows`, `flutter build macos`: create release builds for supported platforms.

## Coding Style & Naming Conventions

Follow Dart defaults and the rules in `analysis_options.yaml`, which includes `package:flutter_lints/flutter.yaml`. Format Dart files with `dart format .` before committing. Use two-space indentation, `lower_snake_case.dart` file names, `UpperCamelCase` classes and widgets, and `lowerCamelCase` methods, fields, and providers. Keep feature UI inside its feature folder; put reusable currency, provider, and conversion logic in `lib/shared/`.

## Testing Guidelines

Use `flutter_test` for widget and unit coverage. Add or update tests whenever changing import logic, database behavior, sync behavior, reports, or primary user flows. Name tests by behavior or module with a `_test.dart` suffix. Prefer focused tests that can run with `flutter test` without requiring Supabase credentials or external services.

## Commit & Pull Request Guidelines

This checkout does not expose Git history, so use clear imperative commit subjects such as `Add CSV import validation` or `Fix account balance calculation`. Keep commits scoped to one logical change. Pull requests should include a concise description, test results (`flutter analyze`, `flutter test`), linked issues when applicable, and screenshots or short recordings for visible UI changes.

## Security & Configuration Tips

Do not commit Supabase secrets, local device config, generated build output, or personal spreadsheet files. Use the publishable/anon Supabase key only through app settings, and keep schema changes reproducible in `supabase/schema.sql`.
