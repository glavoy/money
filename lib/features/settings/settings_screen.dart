import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets.dart';
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 4),
          child: SectionLabel('Organise'),
        ),
        _SettingsTile(
          icon: Icons.category_outlined,
          title: 'Categories',
          subtitle: 'Add, rename, or archive categories',
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const CategoriesScreen())),
        ),
        _SettingsTile(
          icon: Icons.account_balance_wallet_outlined,
          title: 'Accounts',
          subtitle: 'Manage accounts and opening balances',
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const AccountsManageScreen())),
        ),
        _SettingsTile(
          icon: Icons.currency_exchange_outlined,
          title: 'Exchange rates',
          subtitle: 'View, fetch, or enter UGX/USD/CAD rates',
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const FxRatesScreen())),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 4, top: 16, bottom: 4),
          child: SectionLabel('Data'),
        ),
        _SettingsTile(
          icon: Icons.sync_outlined,
          title: 'Sync',
          subtitle: 'Supabase connection and manual sync',
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const SyncScreen())),
        ),
        _SettingsTile(
          icon: Icons.upload_file_outlined,
          title: 'Import data',
          subtitle: 'Import CSV files produced by import_xlsx.py',
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const ImportScreen())),
        ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          foregroundColor: scheme.onSecondaryContainer,
          child: Icon(icon, size: 20),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
