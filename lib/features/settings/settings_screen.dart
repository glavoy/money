import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../shared/providers.dart';
import '../../shared/widgets.dart';
import '../import/import_screen.dart';
import 'accounts_manage_screen.dart';
import 'categories_screen.dart';
import 'fx_rates_screen.dart';
import 'ledgers_screen.dart';
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
          child: SectionLabel('Appearance'),
        ),
        const _ThemeModeTile(),
        const Padding(
          padding: EdgeInsets.only(left: 4, top: 16, bottom: 4),
          child: SectionLabel('Organise'),
        ),
        _SettingsTile(
          icon: Icons.library_books_outlined,
          title: 'Ledgers',
          subtitle: 'Switch, add, or rename separate tracking sets',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LedgersScreen()),
          ),
        ),
        _SettingsTile(
          icon: Icons.category_outlined,
          title: 'Categories',
          subtitle: 'Add, rename, or archive categories',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CategoriesScreen()),
          ),
        ),
        _SettingsTile(
          icon: Icons.account_balance_wallet_outlined,
          title: 'Accounts',
          subtitle: 'Add, edit, archive, or delete accounts',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AccountsManageScreen()),
          ),
        ),
        _SettingsTile(
          icon: Icons.currency_exchange_outlined,
          title: 'Exchange rates',
          subtitle: 'View, fetch, or enter UGX/USD/CAD rates',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FxRatesScreen()),
          ),
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
            context,
            MaterialPageRoute(builder: (_) => const SyncScreen()),
          ),
        ),
        _SettingsTile(
          icon: Icons.upload_file_outlined,
          title: 'Import data',
          subtitle: 'Import CSV files produced by import_xlsx.py',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ImportScreen()),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 4, top: 16, bottom: 4),
          child: SectionLabel('App'),
        ),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final info = snapshot.data;
            final version = info == null
                ? 'Loading...'
                : '${info.version}+${info.buildNumber}';
            return _SettingsTile(
              icon: Icons.info_outline,
              title: 'Version',
              subtitle: version,
            );
          },
        ),
      ],
    );
  }
}

class _ThemeModeTile extends ConsumerWidget {
  const _ThemeModeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          foregroundColor: scheme.onSecondaryContainer,
          child: const Icon(Icons.contrast, size: 20),
        ),
        title: const Text(
          'Theme',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto_outlined),
                label: Text('System'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_outlined),
                label: Text('Light'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text('Dark'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (selected) {
              ref.read(themeModeProvider.notifier).set(selected.single);
            },
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

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
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
