import "package:collection/collection.dart";
import "package:ente_components/ente_components.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/core/configuration.dart";
import "package:photos/emergency/components/email_action_sheet.dart";
import "package:photos/emergency/emergency_service.dart";
import "package:photos/emergency/model.dart";
import "package:photos/emergency/recover_others_account.dart";
import "package:photos/gateways/users/models/key_attributes.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/ui/settings/components/settings_page_scaffold.dart";
import "package:photos/utils/dialog_util.dart";

// OtherContactPage is used to start recovery process for other user's account
// Based on the state of the contact & recovery session, it will show
// different UI
class OtherContactPage extends StatefulWidget {
  final EmergencyContact contact;
  final EmergencyInfo emergencyInfo;

  const OtherContactPage({
    required this.contact,
    required this.emergencyInfo,
    super.key,
  });

  @override
  State<OtherContactPage> createState() => _OtherContactPageState();
}

class _OtherContactPageState extends State<OtherContactPage> {
  late String accountEmail = widget.contact.user.email;
  RecoverySessions? recoverySession;
  String? waitTill;
  final Logger _logger = Logger("_OtherContactPageState");
  late EmergencyInfo emergencyInfo = widget.emergencyInfo;

  @override
  void initState() {
    super.initState();
    recoverySession = widget.emergencyInfo.othersRecoverySession
        .firstWhereOrNull((session) => session.user.email == accountEmail);
    _fetchData();
  }

  Future<void> _fetchData() async {
    try {
      final result = await EmergencyContactService.instance.getInfo();
      if (mounted) {
        setState(() {
          recoverySession = result.othersRecoverySession.firstWhereOrNull(
            (session) => session.user.email == accountEmail,
          );
        });
      }
    } catch (e) {
      _logger.severe("Error fetching data", e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (recoverySession != null) {
      final dateTime = DateTime.now().add(
        Duration(microseconds: recoverySession!.waitTill),
      );
      waitTill = getFormattedTime(dateTime, context: context);
    }
    final colors = context.componentColors;
    return SettingsPageScaffold(
      title: context.l10n.recoverAccount,
      subtitle: accountEmail,
      children: [
        if (recoverySession == null)
          Text(
            context.l10n.recoverAccountDesc(
              email: accountEmail,
              days: widget.contact.recoveryNoticeInDays,
            ),
            style: TextStyles.body.copyWith(color: colors.textLight),
          ),
        if (recoverySession != null && recoverySession!.status == "READY")
          Text(
            context.l10n.recoveryReady(email: accountEmail),
            style: TextStyles.body.copyWith(color: colors.textLight),
          ),
        if (recoverySession != null && recoverySession!.status == "WAITING")
          Text(
            context.l10n.recoverAccountAfter(
              email: accountEmail,
              time: waitTill!,
            ),
            style: TextStyles.body.copyWith(color: colors.textLight),
          ),
        const SizedBox(height: Spacing.xxl),
        if (recoverySession == null)
          ButtonComponent(
            label: context.l10n.startRecovery,
            isDisabled: widget.contact.isPendingInvite(),
            shouldShowSuccessState: false,
            onTap: widget.contact.isPendingInvite() ? null : _startRecovery,
          ),
        if (recoverySession != null && recoverySession!.status == "READY")
          ButtonComponent(
            label: context.l10n.recoverAccount,
            shouldShowSuccessState: false,
            onTap: _recoverAccount,
          ),
        if (recoverySession != null && recoverySession!.status == "WAITING")
          ButtonComponent(
            variant: ButtonComponentVariant.secondary,
            label: context.l10n.cancelRecovery,
            shouldShowSuccessState: false,
            onTap: _showCancelRecoverySheet,
          ),
        if (recoverySession != null && recoverySession!.status == "READY") ...[
          const SizedBox(height: Spacing.xl),
          ButtonComponent(
            variant: ButtonComponentVariant.tertiaryCritical,
            label: context.l10n.cancelRecovery,
            shouldShowSuccessState: false,
            onTap: _showCancelRecoverySheet,
          ),
          const SizedBox(height: Spacing.xxl),
          Text(
            context.l10n.orRemoveYourself(email: accountEmail),
            style: TextStyles.body.copyWith(color: colors.textLight),
          ),
          const SizedBox(height: Spacing.md),
          ButtonComponent(
            variant: ButtonComponentVariant.tertiaryCritical,
            label: context.l10n.removeContact,
            shouldShowSuccessState: false,
            onTap: showRemoveSheet,
          ),
        ],
        if (recoverySession == null || recoverySession!.status != "READY") ...[
          const SizedBox(height: Spacing.xl),
          ButtonComponent(
            variant: ButtonComponentVariant.tertiaryCritical,
            label: context.l10n.removeContact,
            shouldShowSuccessState: false,
            onTap: showRemoveSheet,
          ),
        ],
      ],
    );
  }

  Future<void> _startRecovery() async {
    final confirmed = await showRecoveryAlertSheet<bool>(
      context,
      title: context.l10n.startRecovery,
      message: context.l10n.startRecoveryDesc(email: accountEmail),
      actions: [
        ButtonComponent(
          label: context.l10n.startRecovery,
          onTap: () async => Navigator.of(context).pop(true),
          shouldShowSuccessState: false,
        ),
      ],
    );
    if (confirmed != true) {
      return;
    }
    try {
      await EmergencyContactService.instance.startRecovery(widget.contact);
      if (!mounted) return;
      await _fetchData();
      if (!mounted) return;
      await showRecoveryAlertSheet(
        context,
        title: context.l10n.recoveryInitiated,
        message: context.l10n.recoveryInitiatedDesc(
          days: widget.contact.recoveryNoticeInDays,
          email: Configuration.instance.getEmail()!,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      await showGenericErrorBottomSheet(context: context, error: e);
    }
  }

  Future<void> _recoverAccount() async {
    try {
      final (
        String key,
        KeyAttributes attributes,
      ) = await EmergencyContactService.instance.getRecoveryInfo(
        recoverySession!,
      );
      if (!mounted) return;
      await routeToPage(
        context,
        RecoverOthersAccount(key, attributes, recoverySession!),
      );
      if (mounted) {
        await _fetchData();
      }
    } catch (e) {
      if (!mounted) return;
      await showGenericErrorBottomSheet(context: context, error: e);
    }
  }

  Future<void> _showCancelRecoverySheet() async {
    final confirmed = await showRecoveryAlertSheet<bool>(
      context,
      title: context.l10n.cancelRecovery,
      message: context.l10n.cancelRecoveryDesc(email: accountEmail),
      actions: [
        ButtonComponent(
          variant: ButtonComponentVariant.critical,
          label: context.l10n.cancelRecovery,
          onTap: () async => Navigator.of(context).pop(true),
          shouldShowSuccessState: false,
        ),
      ],
    );
    if (confirmed == true) {
      try {
        await EmergencyContactService.instance.stopRecovery(recoverySession!);
        if (mounted) {
          recoverySession = null;
          setState(() {});
          await _fetchData();
        }
      } catch (e) {
        if (!mounted) return;
        await showGenericErrorBottomSheet(context: context, error: e);
      }
    }
  }

  Future<void> showRemoveSheet() async {
    final confirmed = await showRecoveryAlertSheet<bool>(
      context,
      title: context.l10n.removeContact,
      message: context.l10n.removeYourselfDesc(email: accountEmail),
      actions: [
        ButtonComponent(
          variant: ButtonComponentVariant.critical,
          label: context.l10n.removeContact,
          onTap: () async => Navigator.of(context).pop(true),
          shouldShowSuccessState: false,
        ),
      ],
    );
    if (confirmed == true) {
      try {
        await EmergencyContactService.instance.updateContact(
          widget.contact,
          ContactState.contactLeft,
        );
        if (mounted) {
          Navigator.of(context).pop();
        }
      } catch (e) {
        if (!mounted) return;
        await showGenericErrorBottomSheet(context: context, error: e);
      }
    }
  }
}
