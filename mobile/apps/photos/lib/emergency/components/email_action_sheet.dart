import "package:ente_components/ente_components.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/email_util.dart";
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

Future<T?> showLegacyAlertSheet<T>(
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

Future<void> showLegacyErrorSheet(
  BuildContext context, {
  required Object? error,
}) async {
  final l10n = AppLocalizations.of(context);
  final errorBody = parseErrorForUI(
    context,
    l10n.itLooksLikeSomethingWentWrongPleaseRetryAfterSome,
    error: error,
  );
  await showErrorBottomSheetComponent<void>(
    context: context,
    title: l10n.error,
    message: errorBody,
    illustration: Image.asset("assets/warning-grey.png"),
    actionLabel: l10n.contactSupport,
    onActionTap: () async {
      await sendLogs(
        context,
        l10n.contactSupport,
        "support@ente.com",
        postShare: () {},
      );
    },
  );
}

Future<void> showLegacyInviteSheet(
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
