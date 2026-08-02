import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../shared/providers.dart';
import '../../shared/widgets.dart';
import '../export/export_screen.dart';
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
          subtitle: 'Import transactions.csv or x-rates.csv',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ImportScreen()),
          ),
        ),
        _SettingsTile(
          icon: Icons.download_outlined,
          title: 'Export data',
          subtitle: 'Download transactions.csv and fx_rates.csv',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ExportScreen()),
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
        // A trailing dropdown rather than a segmented button: three
        // icon+label segments do not fit a phone's subtitle width and wrap
        // mid-word ("Sys te m").
        trailing: DropdownButtonHideUnderline(
          child: DropdownButton<ThemeMode>(
            value: mode,
            borderRadius: BorderRadius.circular(12),
            items: const [
              DropdownMenuItem(
                value: ThemeMode.system,
                child: _ThemeOption(
                  icon: Icons.brightness_auto_outlined,
                  label: 'System',
                ),
              ),
              DropdownMenuItem(
                value: ThemeMode.light,
                child: _ThemeOption(
                  icon: Icons.light_mode_outlined,
                  label: 'Light',
                ),
              ),
              DropdownMenuItem(
                value: ThemeMode.dark,
                child: _ThemeOption(
                  icon: Icons.dark_mode_outlined,
                  label: 'Dark',
                ),
              ),
            ],
            onChanged: (selected) {
              if (selected != null) {
                ref.read(themeModeProvider.notifier).set(selected);
              }
            },
          ),
        ),
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 18), const SizedBox(width: 8), Text(label)],
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
