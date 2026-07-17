import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../sync/sync_config.dart';
import '../../sync/sync_service.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _status;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await initSupabaseNow();
      await Supabase.instance.client.auth.signInWithPassword(
        email: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      setState(() => _status = 'Signed in. You can sync now.');
    } catch (e) {
      setState(() => _status = 'Sign-in failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _status = 'Syncing…';
    });
    final result = await ref.read(syncServiceProvider).sync();
    _showSyncResult(result);
  }

  void _showSyncResult(SyncResult result) {
    final message = _formatSyncResult(result);
    setState(() {
      _busy = false;
      _status = message;
    });
  }

  String _formatSyncResult(SyncResult result) {
    final details = result.tables
        .where((table) => table.pushed > 0 || table.pulled > 0)
        .map(
          (table) =>
              '${table.name}: pushed ${table.pushed}, pulled ${table.pulled}',
        )
        .join('\n');
    return result.ok
        ? [
            'Sync complete: pushed ${result.pushed}, pulled ${result.pulled} rows.',
            if (details.isNotEmpty) details,
          ].join('\n')
        : 'Sync failed: ${result.error}';
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(syncStateProvider);
    final syncService = ref.watch(syncServiceProvider);
    final signedIn = syncService.isSignedIn;
    final status = syncService.isRunning
        ? 'Syncing…'
        : _status ??
              (syncService.lastResult == null
                  ? null
                  : _formatSyncResult(syncService.lastResult!));
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            signedIn
                ? 'Connected to Supabase.'
                : SyncConfig.isConfigured
                ? 'Sign in to sync with your configured Supabase project.'
                : 'Create config/sync_config.json, then run the app normally.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _usernameController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _connect,
            child: const Text('Sign in'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy || syncService.isRunning || !signedIn
                ? null
                : _syncNow,
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                status,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          const SizedBox(height: 16),
          Text(
            'Notes:\n'
            '• Project URL and publishable key come from config/sync_config.json.\n'
            '• A restart is needed if you change the sync config after launching.\n'
            '• Sync runs automatically when the app starts; use Sync now after big changes.\n'
            '• All devices must sign in with the same user.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
