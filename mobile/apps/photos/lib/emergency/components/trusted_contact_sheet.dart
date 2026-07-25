import "package:ente_components/ente_components.dart";
import "package:flutter/material.dart";
import "package:photos/emergency/components/recovery_date_selector.dart";
import "package:photos/emergency/model.dart";
import "package:photos/generated/l10n.dart";

Future<TrustedContactResult?> showTrustedContactSheet(
  BuildContext context, {
  required EmergencyContact contact,
}) {
  return showBottomSheetComponent<TrustedContactResult>(
    context: context,
    builder: (_) => BottomSheetComponent(
      title: contact.emergencyContact.email,
      content: TrustedContactSheet(contact: contact),
    ),
  );
}

enum TrustedContactAction { revoke, updateTime }

class TrustedContactResult {
  final TrustedContactAction action;
  final int? selectedDays;

  const TrustedContactResult({required this.action, this.selectedDays});
}

class TrustedContactSheet extends StatefulWidget {
  final EmergencyContact contact;

  const TrustedContactSheet({required this.contact, super.key});

  @override
  State<TrustedContactSheet> createState() => _TrustedContactSheetState();
}

class _TrustedContactSheetState extends State<TrustedContactSheet> {
  late int _selectedRecoveryDays;
  late int _originalRecoveryDays;

  @override
  void initState() {
    super.initState();
    _originalRecoveryDays = widget.contact.recoveryNoticeInDays;
    _selectedRecoveryDays = _originalRecoveryDays;
  }

  bool get _hasChanges => _selectedRecoveryDays != _originalRecoveryDays;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final isPending = widget.contact.isPendingInvite();
    final email = widget.contact.emergencyContact.email;
    final description = isPending
        ? l10n.trustedContactInvitePending(email: email)
        : l10n.trustedContactAccepted(email: email);
    final removeLabel = isPending ? l10n.revokeInvite : l10n.remove;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          description,
          style: TextStyles.body.copyWith(
            color: context.componentColors.textLight,
          ),
        ),
        const SizedBox(height: Spacing.xl),
        RecoveryDateSelector(
          selectedDays: _selectedRecoveryDays,
          onDaysChanged: (days) {
            setState(() {
              _selectedRecoveryDays = days;
            });
          },
        ),
        const SizedBox(height: Spacing.xl),
        ButtonComponent(
          label: l10n.updateTime,
          isDisabled: !_hasChanges,
          onTap: !_hasChanges
              ? null
              : () async {
                  Navigator.of(context).pop(
                    TrustedContactResult(
                      action: TrustedContactAction.updateTime,
                      selectedDays: _selectedRecoveryDays,
                    ),
                  );
                },
          shouldShowSuccessState: false,
        ),
        const SizedBox(height: Spacing.lg),
        Center(
          child: ButtonComponent(
            variant: ButtonComponentVariant.tertiaryCritical,
            size: ButtonComponentSize.small,
            label: removeLabel,
            onTap: () async {
              Navigator.of(context).pop(
                const TrustedContactResult(action: TrustedContactAction.revoke),
              );
            },
            shouldShowSuccessState: false,
          ),
        ),
      ],
    );
  }
}
