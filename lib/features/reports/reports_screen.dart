import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/currency.dart';
import '../../shared/providers.dart';
import '../../shared/widgets.dart';
import 'report_data.dart';

/// CVD-validated categorical palette (fixed slot order — the ordering is the
/// colourblind-safety mechanism). Categories past the 8th fold into "Other".
const _seriesLight = [
  Color(0xFF2A78D6), // blue
  Color(0xFF1BAF7A), // aqua
  Color(0xFFEDA100), // yellow
  Color(0xFF008300), // green
  Color(0xFF4A3AA7), // violet
  Color(0xFFE34948), // red
  Color(0xFFE87BA4), // magenta
  Color(0xFFEB6834), // orange
];
const _seriesDark = [
  Color(0xFF3987E5),
  Color(0xFF199E70),
  Color(0xFFC98500),
  Color(0xFF008300),
  Color(0xFF9085E9),
  Color(0xFFE66767),
  Color(0xFFD55181),
  Color(0xFFD95926),
];

List<Color> seriesColors(Brightness brightness) =>
    brightness == Brightness.dark ? _seriesDark : _seriesLight;

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
    final theme = Theme.of(context);
    final currency = ref.watch(displayCurrencyProvider);
    final db = ref.watch(databaseProvider);
    final ledgerId = ref.watch(selectedLedgerProvider);
    final isAll = _period == ReportPeriod.all;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Column(
            children: [
              SegmentedButton<ReportPeriod>(
                segments: const [
                  ButtonSegment(
                    value: ReportPeriod.month,
                    label: Text('Month'),
                  ),
                  ButtonSegment(
                    value: ReportPeriod.quarter,
                    label: Text('Quarter'),
                  ),
                  ButtonSegment(value: ReportPeriod.year, label: Text('Year')),
                  ButtonSegment(value: ReportPeriod.all, label: Text('All')),
                ],
                selected: {_period},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _period = s.first),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: isAll
                        ? null
                        : () => setState(
                            () => _anchor = shiftAnchor(_period, _anchor, -1),
                          ),
                  ),
                  Expanded(
                    child: Text(
                      reportTitle(_period, _anchor),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: isAll
                        ? null
                        : () => setState(
                            () => _anchor = shiftAnchor(_period, _anchor, 1),
                          ),
                  ),
                  SegmentedButton<Currency>(
                    segments: const [
                      ButtonSegment(value: Currency.ugx, label: Text('UGX')),
                      ButtonSegment(value: Currency.usd, label: Text('USD')),
                      ButtonSegment(value: Currency.cad, label: Text('CAD')),
                    ],
                    selected: {currency},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity(
                        horizontal: -3,
                        vertical: -3,
                      ),
                    ),
                    onSelectionChanged: (s) =>
                        ref.read(displayCurrencyProvider.notifier).set(s.first),
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
            key: ValueKey('$ledgerId-$_period-$_anchor-$currency'),
            future: computeReport(
              db: db,
              ledgerId: ledgerId,
              period: _period,
              anchor: _anchor,
              currency: currency,
            ),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snapshot.data!;
              return _ReportBody(
                data: data,
                currency: currency,
                period: _period,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({
    required this.data,
    required this.currency,
    required this.period,
  });

  final ReportData data;
  final Currency currency;
  final ReportPeriod period;

  /// Sub-periods that have started, so averages for the current period are
  /// not diluted by days/months/years that have not happened yet.
  int get _elapsedUnits {
    final today = DateTime.utc(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    final n = data.buckets.where((b) => !b.from.isAfter(today)).length;
    return n == 0 ? 1 : n;
  }

  String get _unitName => switch (period) {
    ReportPeriod.month => 'day',
    ReportPeriod.quarter || ReportPeriod.year => 'month',
    ReportPeriod.all => 'year',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = seriesColors(theme.brightness);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Spent',
                value: formatMoney(
                  data.expenseTotal,
                  currency,
                  withCode: false,
                ),
                color: theme.colorScheme.error,
                delta: _delta(data.expenseTotal, data.prevExpenseTotal),
                downIsGood: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Income',
                value: formatMoney(data.incomeTotal, currency, withCode: false),
                color: theme.colorScheme.tertiary,
                delta: _delta(data.incomeTotal, data.prevIncomeTotal),
                downIsGood: false,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Net',
                value: formatMoney(
                  data.incomeTotal - data.expenseTotal,
                  currency,
                  withCode: false,
                ),
                color: data.incomeTotal >= data.expenseTotal
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.error,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Average spend '
          '${formatMoney(data.expenseTotal / _elapsedUnits, currency, withCode: false)}'
          ' per $_unitName',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (data.missingRates)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Some entries were skipped: no exchange rate available.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 20),
        SectionLabel(switch (period) {
          ReportPeriod.month => 'Spending by day',
          ReportPeriod.quarter || ReportPeriod.year => 'Cash flow by month',
          ReportPeriod.all => 'Cash flow by year',
        }),
        const SizedBox(height: 8),
        if (period != ReportPeriod.month) ...[
          _ChartLegend(
            entries: [
              ('Spent', theme.colorScheme.primary),
              ('Income', theme.colorScheme.tertiary),
            ],
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          height: 200,
          child: _BucketChart(
            data: data,
            currency: currency,
            showIncome: period != ReportPeriod.month,
          ),
        ),
        const SizedBox(height: 24),
        const SectionLabel('By category'),
        const SizedBox(height: 8),
        if (data.byCategory.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No expenses in this period.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          _CategoryDonut(data: data, currency: currency, colors: colors),
          const SizedBox(height: 12),
          _CategoryList(data: data, currency: currency, colors: colors),
        ],
        if (period != ReportPeriod.month) ...[
          const SizedBox(height: 24),
          SectionLabel(
            period == ReportPeriod.all ? 'Yearly summary' : 'Monthly summary',
          ),
          const SizedBox(height: 8),
          _SummaryTable(data: data, currency: currency),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  double? _delta(double current, double? previous) {
    if (previous == null || previous <= 0) return null;
    return (current - previous) / previous;
  }
}

/// Colour of the slice for the category at [rank], honouring an explicit
/// category colour when the ranked entry carries one.
Color sliceColor(int rank, List<Color> colors, ColorScheme scheme) =>
    rank < colors.length ? colors[rank] : scheme.outline;

class _CategoryDonut extends StatelessWidget {
  const _CategoryDonut({
    required this.data,
    required this.currency,
    required this.colors,
  });

  final ReportData data;
  final Currency currency;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = data.byCategory.take(colors.length).toList();
    final otherTotal = data.byCategory
        .skip(colors.length)
        .fold(0.0, (sum, e) => sum + e.value);

    return SizedBox(
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 56,
              startDegreeOffset: -90,
              sections: [
                for (var i = 0; i < top.length; i++)
                  PieChartSectionData(
                    value: top[i].value,
                    color: sliceColor(i, colors, theme.colorScheme),
                    radius: 34,
                    showTitle: false,
                  ),
                if (otherTotal > 0)
                  PieChartSectionData(
                    value: otherTotal,
                    color: theme.colorScheme.outlineVariant,
                    radius: 34,
                    showTitle: false,
                  ),
              ],
            ),
          ),
          // Centre label: what the donut adds up to.
          SizedBox(
            width: 96,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SPENT',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.6,
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatMoney(data.expenseTotal, currency, withCode: false),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ranked category rows: colour dot, name, share bar, percentage, amount.
class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.data,
    required this.currency,
    required this.colors,
  });

  final ReportData data;
  final Currency currency;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxCategory = data.byCategory.first.value;
    final total = data.expenseTotal;

    return Column(
      children: [
        for (var i = 0; i < data.byCategory.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < colors.length
                        ? sliceColor(i, colors, theme.colorScheme)
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 86,
                  child: Text(
                    data.byCategory[i].key,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Expanded(
                  child: MagnitudeBar(
                    fraction: maxCategory == 0
                        ? 0
                        : data.byCategory[i].value / maxCategory,
                    color: i < colors.length
                        ? sliceColor(i, colors, theme.colorScheme)
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    total == 0
                        ? ''
                        : '${(data.byCategory[i].value / total * 100).toStringAsFixed(0)}%',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 92,
                  child: Text(
                    formatMoney(
                      data.byCategory[i].value,
                      currency,
                      withCode: false,
                    ),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.entries});

  final List<(String, Color)> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        for (final (label, color) in entries) ...[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
        ],
      ],
    );
  }
}

/// Spent / Income / Net per sub-period, with a totals-aware layout for the
/// yearly (all-time) view.
class _SummaryTable extends StatelessWidget {
  const _SummaryTable({required this.data, required this.currency});

  final ReportData data;
  final Currency currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    TextStyle? netStyle(double net) => theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: net >= 0 ? theme.colorScheme.tertiary : theme.colorScheme.error,
    );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Table(
          columnWidths: const {0: FixedColumnWidth(48)},
          children: [
            TableRow(
              children: [
                const SizedBox(),
                Text(
                  'Spent',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelLarge,
                ),
                Text(
                  'Income',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelLarge,
                ),
                Text(
                  'Net',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelLarge,
                ),
              ],
            ),
            for (final b in data.buckets)
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(b.label),
                  ),
                  Text(
                    formatMoney(b.expense, currency, withCode: false),
                    textAlign: TextAlign.right,
                  ),
                  Text(
                    formatMoney(b.income, currency, withCode: false),
                    textAlign: TextAlign.right,
                  ),
                  Text(
                    formatMoney(
                      b.income - b.expense,
                      currency,
                      withCode: false,
                    ),
                    textAlign: TextAlign.right,
                    style: netStyle(b.income - b.expense),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    this.delta,
    this.downIsGood = true,
  });

  final String label;
  final String value;
  final Color color;

  /// Fractional change vs the previous period (0.12 = +12%); null hides it.
  final double? delta;
  final bool downIsGood;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = delta;
    final up = d != null && d >= 0;
    final good = d != null && (up != downIsGood);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (d != null) ...[
              const SizedBox(height: 2),
              Text(
                '${up ? '▲' : '▼'} ${(d.abs() * 100).toStringAsFixed(0)}% vs prev',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: good
                      ? theme.colorScheme.tertiary
                      : theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BucketChart extends StatelessWidget {
  const _BucketChart({
    required this.data,
    required this.currency,
    required this.showIncome,
  });

  final ReportData data;
  final Currency currency;
  final bool showIncome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buckets = data.buckets;
    if (buckets.isEmpty) return const SizedBox.shrink();
    final many = buckets.length > 15;
    final barWidth = showIncome ? (many ? 4.0 : 8.0) : (many ? 6.0 : 14.0);
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => theme.colorScheme.inverseSurface,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final series = showIncome
                  ? (rodIndex == 0 ? 'Spent ' : 'Income ')
                  : '';
              return BarTooltipItem(
                '${buckets[group.x].label}\n$series${formatMoney(rod.toY, currency)}',
                TextStyle(color: theme.colorScheme.onInverseSurface),
              );
            },
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
                if (i < 0 || i >= buckets.length) {
                  return const SizedBox.shrink();
                }
                if (many && i % 5 != 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    buckets[i].label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < buckets.length; i++)
            BarChartGroupData(
              x: i,
              barsSpace: 2,
              barRods: [
                BarChartRodData(
                  toY: buckets[i].expense,
                  color: theme.colorScheme.primary,
                  width: barWidth,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
                if (showIncome)
                  BarChartRodData(
                    toY: buckets[i].income,
                    color: theme.colorScheme.tertiary,
                    width: barWidth,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
