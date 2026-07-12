import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../import/import_screen.dart';
import 'accounts_manage_screen.dart';
import 'categories_screen.dart';
import 'fx_rates_screen.dart';
import 'sync_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      children: [
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.category_outlined),
          title: const Text('Categories'),
          subtitle: const Text('Add, rename, or archive categories'),
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const CategoriesScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.account_balance_wallet_outlined),
          title: const Text('Accounts'),
          subtitle: const Text('Manage accounts and opening balances'),
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const AccountsManageScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.currency_exchange_outlined),
          title: const Text('Exchange rates'),
          subtitle: const Text('View, fetch, or enter UGX/USD/CAD rates'),
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const FxRatesScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.sync_outlined),
          title: const Text('Sync'),
          subtitle: const Text('Supabase connection and manual sync'),
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const SyncScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.upload_file_outlined),
          title: const Text('Import data'),
          subtitle: const Text('Import CSV files produced by import_xlsx.py'),
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const ImportScreen())),
        ),
      ],
    );
  }
}
