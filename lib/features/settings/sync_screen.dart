import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/providers.dart';
import '../../sync/sync_service.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    _urlController.text = await db.getSetting(SyncKeys.url) ?? '';
    _keyController.text = await db.getSetting(SyncKeys.anonKey) ?? '';
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final db = ref.read(databaseProvider);
    try {
      final url = _urlController.text.trim();
      final key = _keyController.text.trim();
      await db.setSetting(SyncKeys.url, url);
      await db.setSetting(SyncKeys.anonKey, key);
      await initSupabaseNow(url, key);
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
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
    setState(() {
      _busy = false;
      _status = result.ok
          ? 'Sync complete: pushed ${result.pushed}, pulled ${result.pulled} rows.'
          : 'Sync failed: ${result.error}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.read(syncServiceProvider).isSignedIn;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            signedIn
                ? 'Connected to Supabase.'
                : 'Enter your Supabase project details (see supabase/schema.sql for one-time setup), then sign in.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'Supabase URL',
              hintText: 'https://xxxx.supabase.co',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyController,
            decoration: const InputDecoration(
              labelText: 'Publishable (or anon) key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email',
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
            child: const Text('Connect & sign in'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy || !ref.read(syncServiceProvider).isSignedIn ? null : _syncNow,
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
            ),
          const SizedBox(height: 16),
          Text(
            'Notes:\n'
            '• A restart is needed if you change the Supabase URL after connecting once.\n'
            '• Sync runs automatically when the app starts; use Sync now after big changes.\n'
            '• All devices must sign in with the same user.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
