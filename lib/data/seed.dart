import 'package:drift/drift.dart';

import 'database.dart';

/// Seed rows use fixed ids so that two devices seeding independently and
/// then syncing to the same Supabase project agree on the same rows.

class SeedAccount {
  const SeedAccount(this.id, this.name, this.type, this.currency);
  final String id;
  final String name;
  final String type;
  final String currency;
}

/// Hidden account that historical spreadsheet imports are booked against,
/// so that real accounts start clean from their opening balances.
const historyAccountId = 'acc-history';

const seedAccounts = [
  SeedAccount('acc-cash', 'Cash', AccountType.cash, 'UGX'),
  SeedAccount('acc-stanbic', 'Stanbic Bank', AccountType.bank, 'UGX'),
  SeedAccount('acc-usd-bank', 'USD Bank', AccountType.bank, 'USD'),
  SeedAccount('acc-mtn', 'MTN Mobile Money', AccountType.mobileMoney, 'UGX'),
  SeedAccount('acc-mtn-x', 'MTN Mobile Money X', AccountType.mobileMoney, 'UGX'),
  SeedAccount('acc-airtel', 'Airtel Money', AccountType.mobileMoney, 'UGX'),
  SeedAccount('acc-visa', 'Visa', AccountType.creditCard, 'USD'),
  SeedAccount(historyAccountId, 'Imported history', AccountType.cash, 'UGX'),
];

/// Expense categories in the same order as the spreadsheet columns.
const seedExpenseCategories = [
  'food',
  'food_r',
  'beer',
  'beer_r',
  'house',
  'petrol',
  'car',
  'motorcycle',
  'health',
  'clothes',
  'recreation',
  'jose',
  'misc',
  'kids',
  'airtime',
  'bigticket',
  'water',
  'rent',
  'electricity',
  'Internet',
  'guard',
  'Dog',
  'Buziga',
  'Munyonyo',
  'DSTV',
  'worker',
];

const seedIncomeCategories = [
  'Salary',
  'Rent income',
  'Interest',
  'Refund',
  'Other income',
];

String seedCategoryId(String name, String kind) =>
    'cat-$kind-${name.toLowerCase().replaceAll(' ', '-')}';

Future<void> seedDatabase(AppDatabase db) async {
  final now = DateTime.now().toUtc();
  await db.batch((batch) {
    batch.insertAll(
      db.accounts,
      [
        for (var i = 0; i < seedAccounts.length; i++)
          AccountsCompanion.insert(
            id: seedAccounts[i].id,
            name: seedAccounts[i].name,
            type: seedAccounts[i].type,
            currency: seedAccounts[i].currency,
            sortOrder: Value(i),
            archived: Value(seedAccounts[i].id == historyAccountId),
            createdAt: now,
            updatedAt: now,
          ),
      ],
      mode: InsertMode.insertOrIgnore,
    );
    batch.insertAll(
      db.categories,
      [
        for (var i = 0; i < seedExpenseCategories.length; i++)
          CategoriesCompanion.insert(
            id: seedCategoryId(seedExpenseCategories[i], CategoryKind.expense),
            name: seedExpenseCategories[i],
            kind: CategoryKind.expense,
            sortOrder: Value(i),
            createdAt: now,
            updatedAt: now,
          ),
        for (var i = 0; i < seedIncomeCategories.length; i++)
          CategoriesCompanion.insert(
            id: seedCategoryId(seedIncomeCategories[i], CategoryKind.income),
            name: seedIncomeCategories[i],
            kind: CategoryKind.income,
            sortOrder: Value(i),
            createdAt: now,
            updatedAt: now,
          ),
      ],
      mode: InsertMode.insertOrIgnore,
    );
  });
}
