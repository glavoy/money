import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/currency.dart';
import '../../shared/providers.dart';
import 'report_data.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  ReportPeriod _period = ReportPeriod.month;
  DateTime _anchor = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final currency = ref.watch(displayCurrencyProvider);
    final db = ref.watch(databaseProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<ReportPeriod>(
                      segments: const [
                        ButtonSegment(value: ReportPeriod.month, label: Text('Month')),
                        ButtonSegment(value: ReportPeriod.quarter, label: Text('Quarter')),
                        ButtonSegment(value: ReportPeriod.year, label: Text('Year')),
                      ],
                      selected: {_period},
                      onSelectionChanged: (s) => setState(() => _period = s.first),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<Currency>(
                    segments: const [
                      ButtonSegment(value: Currency.ugx, label: Text('UGX')),
                      ButtonSegment(value: Currency.usd, label: Text('USD')),
                      ButtonSegment(value: Currency.cad, label: Text('CAD')),
                    ],
                    selected: {currency},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        ref.read(displayCurrencyProvider.notifier).set(s.first),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () =>
                        setState(() => _anchor = shiftAnchor(_period, _anchor, -1)),
                  ),
                  Text(reportTitle(_period, _anchor),
                      style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () =>
                        setState(() => _anchor = shiftAnchor(_period, _anchor, 1)),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<ReportData>(
            // Recomputes when period/anchor/currency change; the key also
            // makes edits elsewhere refresh on tab switch.
            key: ValueKey('$_period-$_anchor-$currency'),
            future: computeReport(
                db: db, period: _period, anchor: _anchor, currency: currency),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snapshot.data!;
              return _ReportBody(data: data, currency: currency, period: _period);
            },
          ),
        ),
      ],
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.data, required this.currency, required this.period});

  final ReportData data;
  final Currency currency;
  final ReportPeriod period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxCategory =
        data.byCategory.isEmpty ? 0.0 : data.byCategory.first.value;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Spent',
                value: formatMoney(data.expenseTotal, currency),
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Income',
                value: formatMoney(data.incomeTotal, currency),
                color: Colors.green,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Net',
                value: formatMoney(data.incomeTotal - data.expenseTotal, currency),
                color: data.incomeTotal >= data.expenseTotal
                    ? Colors.green
                    : theme.colorScheme.error,
              ),
            ),
          ],
        ),
        if (data.missingRates)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Some entries were skipped: no exchange rate available.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          period == ReportPeriod.month ? 'Spending by day' : 'Spending by month',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SizedBox(height: 200, child: _BucketChart(data: data, currency: currency)),
        const SizedBox(height: 20),
        Text('By category', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (data.byCategory.isEmpty) const Text('No expenses in this period.'),
        for (final entry in data.byCategory)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(entry.key,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxCategory == 0 ? 0 : entry.value / maxCategory,
                      minHeight: 14,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: Text(
                    formatMoney(entry.value, currency, withCode: false),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        if (period != ReportPeriod.month) ...[
          const SizedBox(height: 20),
          Text('Monthly summary', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Table(
                columnWidths: const {0: FixedColumnWidth(56)},
                children: [
                  TableRow(
                    children: [
                      const SizedBox(),
                      Text('Spent',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelLarge),
                      Text('Income',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelLarge),
                    ],
                  ),
                  for (final b in data.buckets)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(b.label),
                        ),
                        Text(formatMoney(b.expense, currency, withCode: false),
                            textAlign: TextAlign.right),
                        Text(formatMoney(b.income, currency, withCode: false),
                            textAlign: TextAlign.right),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: color, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BucketChart extends StatelessWidget {
  const _BucketChart({required this.data, required this.currency});

  final ReportData data;
  final Currency currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buckets = data.buckets;
    if (buckets.isEmpty) return const SizedBox.shrink();
    final many = buckets.length > 15;
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
              '${buckets[group.x].label}\n${formatMoney(rod.toY, currency)}',
              TextStyle(color: theme.colorScheme.onInverseSurface),
            ),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          topTitles: const AxisTitles(),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
                if (many && i % 5 != 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(buckets[i].label,
                      style: theme.textTheme.bodySmall),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < buckets.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: buckets[i].expense,
                  color: theme.colorScheme.primary,
                  width: many ? 6 : 14,
                  borderRadius: BorderRadius.circular(2),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
