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
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _DayChip(
          label: context.l10n.trashDaysLeft(count: 7),
          isSelected: selectedDays == 7,
          onTap: () => onDaysChanged(7),
        ),
        const SizedBox(width: Spacing.md),
        _DayChip(
          label: context.l10n.trashDaysLeft(count: 14),
          isSelected: selectedDays == 14,
          onTap: () => onDaysChanged(14),
        ),
        const SizedBox(width: Spacing.md),
        _DayChip(
          label: context.l10n.trashDaysLeft(count: 30),
          isSelected: selectedDays == 30,
          onTap: () => onDaysChanged(30),
        ),
      ],
    );
  }
}

class _DayChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _DayChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.standard,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(Spacing.lg),
        decoration: BoxDecoration(
          color: isSelected ? colors.primary : colors.fillDark,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyles.bodyBold.copyWith(
            color: isSelected ? colors.specialWhite : colors.textBase,
          ),
        ),
      ),
    );
  }
}
