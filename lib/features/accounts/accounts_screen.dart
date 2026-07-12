import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../shared/currency.dart';
import '../../shared/providers.dart';
import '../transactions/transactions_screen.dart' show showEditTransactionSheet;

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balances = ref.watch(balancesProvider).value ?? [];
    final latestRate = ref.watch(latestRateProvider).value;

    double totalUgx = 0;
    for (final b in balances) {
      if (b.account.type == AccountType.creditCard) continue;
      final c = CurrencyX.fromCode(b.account.currency);
      totalUgx += convertWithRate(b.balance, c, Currency.ugx, latestRate) ?? 0;
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Total (excl. credit card)',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(formatMoney(totalUgx, Currency.ugx),
                    style: Theme.of(context).textTheme.headlineSmall),
                if (latestRate?.usdUgx != null)
                  Text(
                    '≈ ${formatMoney(convertWithRate(totalUgx, Currency.ugx, Currency.usd, latestRate) ?? 0, Currency.usd)}'
                    '${latestRate?.cadUgx != null ? '  ·  ${formatMoney(convertWithRate(totalUgx, Currency.ugx, Currency.cad, latestRate) ?? 0, Currency.cad)}' : ''}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                if (latestRate != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Rate of ${DateFormat('d MMM yyyy').format(latestRate.date)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        for (final b in balances)
          Card(
            child: ListTile(
              leading: Icon(switch (b.account.type) {
                AccountType.cash => Icons.payments_outlined,
                AccountType.bank => Icons.account_balance_outlined,
                AccountType.mobileMoney => Icons.phone_android_outlined,
                _ => Icons.credit_card_outlined,
              }),
              title: Text(b.account.name),
              subtitle: b.account.currency == 'UGX'
                  ? null
                  : Text(
                      '≈ ${formatMoney(convertWithRate(b.balance, CurrencyX.fromCode(b.account.currency), Currency.ugx, latestRate) ?? 0, Currency.ugx)}'),
              trailing: Text(
                formatMoney(b.balance, CurrencyX.fromCode(b.account.currency)),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AccountLedgerScreen(account: b.account),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Ledger for one account — replaces the per-account spreadsheet tabs.
class AccountLedgerScreen extends ConsumerWidget {
  const AccountLedgerScreen({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final currency = CurrencyX.fromCode(account.currency);
    final accounts = ref.watch(accountsProvider).value ?? [];
    final categories = ref.watch(allCategoriesProvider).value ?? [];
    final accountById = {for (final a in accounts) a.id: a};
    final categoryById = {for (final c in categories) c.id: c};

    return Scaffold(
      appBar: AppBar(title: Text(account.name)),
      body: StreamBuilder<List<Transaction>>(
        stream: db.watchTransactions(accountId: account.id, limit: 2000),
        builder: (context, snapshot) {
          final txs = snapshot.data ?? [];
          // Compute running balance from oldest to newest.
          final asc = txs.reversed.toList();
          var running = account.openingBalance;
          final runningAfter = <String, double>{};
          for (final t in asc) {
            running += _effect(t, account.id);
            runningAfter[t.id] = running;
          }
          return Column(
            children: [
              ListTile(
                title: const Text('Current balance'),
                trailing: Text(
                  formatMoney(running, currency),
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: txs.isEmpty
                    ? const Center(child: Text('No transactions on this account'))
                    : ListView.builder(
                        itemCount: txs.length,
                        itemBuilder: (context, i) {
                          final t = txs[i];
                          final effect = _effect(t, account.id);
                          final title = switch (t.kind) {
                            TxKind.transfer => t.accountId == account.id
                                ? 'To ${accountById[t.toAccountId]?.name ?? '?'}'
                                : 'From ${accountById[t.accountId]?.name ?? '?'}',
                            _ => categoryById[t.categoryId]?.name ?? t.kind,
                          };
                          return ListTile(
                            dense: true,
                            title: Text(title),
                            subtitle: Text([
                              DateFormat('d MMM yyyy').format(t.date),
                              if (t.note != null) t.note!,
                            ].join(' · ')),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${effect >= 0 ? '+' : ''}${formatMoney(effect, currency, withCode: false)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: effect >= 0
                                        ? Colors.green
                                        : Theme.of(context).colorScheme.error,
                                  ),
                                ),
                                Text(
                                  formatMoney(runningAfter[t.id] ?? 0, currency,
                                      withCode: false),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            onTap: () => showEditTransactionSheet(context, ref, t),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Signed effect of a transaction on [accountId]'s balance.
  static double _effect(Transaction t, String accountId) {
    if (t.kind == TxKind.transfer) {
      if (t.accountId == accountId) return -t.amount;
      if (t.toAccountId == accountId) return t.toAmount ?? 0;
      return 0;
    }
    if (t.accountId != accountId) return 0;
    return t.kind == TxKind.income ? t.amount : -t.amount;
  }
}
