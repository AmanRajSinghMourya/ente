import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:locker/ui/settings/widgets/change_log_strings.dart";

Future<void> showChangeLogSheet(BuildContext context) {
  final strings = ChangeLogStrings.forLocale(Localizations.localeOf(context));
  return showBottomSheetComponent<void>(
    context: context,
    builder: (sheetContext) => BottomSheetComponent(
      header: _ChangeLogHeader(title: context.strings.whatsNew),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      actionsTopSpacing: Spacing.lg,
      content: Flexible(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: _ChangeLogEntryTile(
            title: strings.title,
            description: strings.description,
          ),
        ),
      ),
      actions: [
        ButtonComponent(
          variant: ButtonComponentVariant.primary,
          size: ButtonComponentSize.large,
          label: context.strings.continueLabel,
          shouldSurfaceExecutionStates: false,
          onTap: () => Navigator.of(sheetContext).pop(),
        ),
      ],
    ),
  );
}

class _ChangeLogEntryTile extends StatelessWidget {
  final String title;
  final String description;

  const _ChangeLogEntryTile({required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          textAlign: TextAlign.left,
          style: TextStyles.large.copyWith(color: colors.textBase),
        ),
        const SizedBox(height: Spacing.md),
        Text(
          description,
          textAlign: TextAlign.left,
          style: TextStyles.body.copyWith(color: colors.textLight),
        ),
      ],
    );
  }
}

class _ChangeLogHeader extends StatelessWidget {
  const _ChangeLogHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButtonComponent(
            tooltip: "Close",
            variant: IconButtonComponentVariant.circular,
            shouldSurfaceExecutionStates: false,
            icon: const HugeIcon(
              icon: HugeIcons.strokeRoundedCancel01,
              size: IconSizes.small,
            ),
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Image.asset(
          "assets/whats_new_illustration.png",
          width: 115,
          height: 108,
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyles.display2.copyWith(color: colors.textBase),
        ),
      ],
    );
  }
}
