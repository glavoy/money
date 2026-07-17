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
    final theme = Theme.of(context);
    final balances = ref.watch(balancesProvider).value ?? [];
    final latestRate = ref.watch(latestRateProvider).value;

    double totalUgx = 0;
    for (final b in balances) {
      if (b.account.type == AccountType.creditCard) continue;
      final c = CurrencyX.fromCode(b.account.currency);
      totalUgx += convertWithRate(b.balance, c, Currency.ugx, latestRate) ?? 0;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        // Hero total.
        Card(
          color: theme.colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TOTAL BALANCE',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  formatMoney(totalUgx, Currency.ugx),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (latestRate?.usdUgx != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '≈ ${formatMoney(convertWithRate(totalUgx, Currency.ugx, Currency.usd, latestRate) ?? 0, Currency.usd)}'
                    '${latestRate?.cadUgx != null ? '   ·   ${formatMoney(convertWithRate(totalUgx, Currency.ugx, Currency.cad, latestRate) ?? 0, Currency.cad)}' : ''}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
                ],
                if (latestRate != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Excludes credit card · rate of ${DateFormat('d MMM yyyy').format(latestRate.date)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer.withValues(
                        alpha: 0.7,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final b in balances)
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.secondaryContainer,
                foregroundColor: theme.colorScheme.onSecondaryContainer,
                child: Icon(switch (b.account.type) {
                  AccountType.cash => Icons.payments_outlined,
                  AccountType.bank => Icons.account_balance_outlined,
                  AccountType.mobileMoney => Icons.phone_android_outlined,
                  _ => Icons.credit_card_outlined,
                }, size: 20),
              ),
              title: Text(
                b.account.name,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: b.account.currency == 'UGX'
                  ? null
                  : Text(
                      '≈ ${formatMoney(convertWithRate(b.balance, CurrencyX.fromCode(b.account.currency), Currency.ugx, latestRate) ?? 0, Currency.ugx)}',
                    ),
              trailing: Text(
                formatMoney(b.balance, CurrencyX.fromCode(b.account.currency)),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: b.balance < 0 ? theme.colorScheme.error : null,
                ),
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
    final theme = Theme.of(context);
    final db = ref.watch(databaseProvider);
    final currency = CurrencyX.fromCode(account.currency);
    final accounts = ref.watch(accountsProvider).value ?? [];
    final categories = ref.watch(allCategoriesProvider).value ?? [];
    final accountById = {for (final a in accounts) a.id: a};
    final categoryById = {for (final c in categories) c.id: c};

    return Scaffold(
      appBar: AppBar(title: Text(account.name)),
      body: StreamBuilder<List<Transaction>>(
        stream: db.watchTransactions(
          ledgerId: account.ledgerId,
          accountId: account.id,
          limit: 2000,
        ),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Card(
                  color: theme.colorScheme.secondaryContainer,
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Current balance',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                        Text(
                          formatMoney(running, currency),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: txs.isEmpty
                    ? Center(
                        child: Text(
                          'No transactions on this account',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: txs.length,
                        itemBuilder: (context, i) {
                          final t = txs[i];
                          final effect = _effect(t, account.id);
                          final title = switch (t.kind) {
                            TxKind.transfer =>
                              t.accountId == account.id
                                  ? 'To ${accountById[t.toAccountId]?.name ?? '?'}'
                                  : 'From ${accountById[t.accountId]?.name ?? '?'}',
                            _ => categoryById[t.categoryId]?.name ?? t.kind,
                          };
                          return ListTile(
                            dense: true,
                            title: Text(title),
                            subtitle: Text(
                              [
                                DateFormat('d MMM yyyy').format(t.date),
                                if (t.note != null) t.note!,
                              ].join(' · '),
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${effect >= 0 ? '+' : '−'}${formatMoney(effect.abs(), currency, withCode: false)}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: effect >= 0
                                        ? theme.colorScheme.tertiary
                                        : theme.colorScheme.error,
                                  ),
                                ),
                                Text(
                                  formatMoney(
                                    runningAfter[t.id] ?? 0,
                                    currency,
                                    withCode: false,
                                  ),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                            onTap: () =>
                                showEditTransactionSheet(context, ref, t),
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
