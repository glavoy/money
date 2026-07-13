import 'package:flutter/material.dart';

import '../data/database.dart';

/// Small uppercase section heading used above form groups and list sections.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Tinted circular icon for a transaction kind (expense/income/transfer).
class KindAvatar extends StatelessWidget {
  const KindAvatar({super.key, required this.kind, this.small = false});

  final String kind;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, background, foreground) = switch (kind) {
      TxKind.income => (Icons.south_west, scheme.tertiaryContainer, scheme.onTertiaryContainer),
      TxKind.transfer => (Icons.swap_horiz, scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      _ => (Icons.north_east, scheme.errorContainer, scheme.onErrorContainer),
    };
    final radius = small ? 14.0 : 18.0;
    return CircleAvatar(
      radius: radius,
      backgroundColor: background,
      child: Icon(icon, size: radius, color: foreground),
    );
  }
}

/// Horizontal magnitude bar for category breakdowns: a thin rounded track
/// with a single-hue fill proportional to [fraction].
class MagnitudeBar extends StatelessWidget {
  const MagnitudeBar({super.key, required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 12,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }
}
