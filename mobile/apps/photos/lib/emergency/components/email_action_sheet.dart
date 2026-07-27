import "package:ente_components/ente_components.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/utils/share_util.dart";

Future<T?> showEmailActionSheet<T>(
  BuildContext context, {
  required String email,
  required String message,
  required List<Widget> buttons,
  String? title,
}) {
  return showBottomSheetComponent<T>(
    context: context,
    builder: (_) => BottomSheetComponent(
      title: title ?? email,
      content: Text(
        message,
        style: TextStyles.body.copyWith(
          color: context.componentColors.textLight,
        ),
      ),
      actions: buttons,
    ),
  );
}

Future<T?> showRecoveryAlertSheet<T>(
  BuildContext context, {
  required String title,
  required String message,
  String assetPath = "assets/warning-grey.png",
  List<Widget> actions = const [],
}) {
  return showBottomSheetComponent<T>(
    context: context,
    builder: (_) => BottomSheetComponent(
      title: title,
      message: message,
      illustration: Image.asset(assetPath),
      actions: actions,
    ),
  );
}

Future<void> showRecoveryContactInviteSheet(
  BuildContext context, {
  required String email,
}) async {
  final l10n = AppLocalizations.of(context);
  await showBottomSheetComponent<void>(
    context: context,
    builder: (sheetContext) => BottomSheetComponent(
      title: l10n.inviteToEnte,
      message: l10n.emailNoEnteAccount(email: email),
      actions: [
        ButtonComponent(
          label: l10n.sendInvite,
          leading: const HugeIcon(
            icon: HugeIcons.strokeRoundedShare08,
            size: IconSizes.small,
          ),
          shouldShowSuccessState: false,
          onTap: () async {
            await shareText(
              l10n.shareTextRecommendUsingEnte,
              context: sheetContext,
            );
          },
        ),
      ],
    ),
  );
}
