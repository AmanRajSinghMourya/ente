import "package:ente_components/ente_components.dart";
import "package:flutter/material.dart";
import "package:photos/l10n/l10n.dart";

class RecoveryDateSelector extends StatelessWidget {
  final int selectedDays;
  final ValueChanged<int> onDaysChanged;

  const RecoveryDateSelector({
    required this.selectedDays,
    required this.onDaysChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [7, 14, 30]
          .map((days) {
            final isSelected = selectedDays == days;
            return FilterChipComponent(
              label: context.l10n.trashDaysLeft(count: days),
              state: isSelected
                  ? FilterChipComponentState.selected
                  : FilterChipComponentState.unselected,
              trailing: isSelected ? const Icon(Icons.check_rounded) : null,
              onChanged: (_) => onDaysChanged(days),
            );
          })
          .toList(growable: false),
    );
  }
}
