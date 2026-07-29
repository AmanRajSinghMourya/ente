import 'package:email_validator/email_validator.dart';
import "package:ente_components/ente_components.dart";
import 'package:flutter/material.dart';
import "package:logging/logging.dart";
import 'package:photos/core/configuration.dart';
import "package:photos/emergency/components/recovery_date_selector.dart";
import "package:photos/emergency/emergency_service.dart";
import "package:photos/emergency/model.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/models/api/collection/user.dart";
import "package:photos/services/account/user_service.dart";
import 'package:photos/services/collections_service.dart';
import "package:photos/services/contacts/contact_identity_resolver.dart";
import "package:photos/ui/components/alert_bottom_sheet.dart";
import "package:photos/ui/components/buttons/button_widget_v2.dart";
import 'package:photos/ui/sharing/user_avator_widget.dart';
import "package:photos/ui/sharing/verify_identity_dialog.dart";

Future<bool?> showAddContactSheet(
  BuildContext context, {
  required EmergencyInfo emergencyInfo,
}) {
  return showBottomSheetComponent<bool>(
    context: context,
    builder: (context) => BottomSheetComponent(
      title: context.l10n.addTrustedContact,
      padding: const EdgeInsets.all(16),
      contentSpacing: 20,
      isKeyboardAware: true,
      content: AddContactSheet(emergencyInfo: emergencyInfo),
    ),
  );
}

class AddContactSheet extends StatefulWidget {
  final EmergencyInfo emergencyInfo;

  const AddContactSheet({required this.emergencyInfo, super.key});

  @override
  State<AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<AddContactSheet> {
  final Set<String> _selectedEmails = <String>{};
  String _email = "";
  bool _emailIsValid = false;
  int _selectedRecoveryDays = 14;
  late final Logger _logger = Logger("AddContactSheet");

  final textFieldFocusNode = FocusNode();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _textController.dispose();
    textFieldFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final List<User> suggestedUsers = _getSuggestedUser();
    final List<String> emailsToAdd = _emailsToAdd;
    final bool canAdd = emailsToAdd.isNotEmpty;
    final String? emailForVerification = _emailForVerification;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextInputComponent(
            hintText: AppLocalizations.of(context).enterEmail,
            controller: _textController,
            focusNode: textFieldFocusNode,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            isClearable: true,
            shouldUnfocusOnClearOrSubmit: true,
            autofillHints: const [AutofillHints.email],
            onChanged: (value) {
              _email = value.trim();
              _emailIsValid = EmailValidator.validate(_email);
              setState(() {});
            },
          ),
          if (suggestedUsers.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              context.l10n.chooseFromAnExistingContact,
              style: TextStyles.body.copyWith(color: colors.textLight),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: suggestedUsers.length > 2,
                thickness: 4,
                radius: const Radius.circular(3),
                child: ListView(
                  controller: _scrollController,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    MenuGroupComponent(
                      showDividers: true,
                      items: [
                        for (final user in suggestedUsers)
                          MenuComponent(
                            title: resolveDisplayName(user),
                            titleColor: colors.textLight,
                            leading: UserAvatarWidget(
                              user,
                              type: AvatarType.medium,
                              currentUserID: Configuration.instance
                                  .getUserID()!,
                            ),
                            trailing: _selectedEmails.contains(user.email)
                                ? Icon(
                                    Icons.check_rounded,
                                    color: colors.primary,
                                    size: IconSizes.small,
                                  )
                                : null,
                            onTap: () {
                              textFieldFocusNode.unfocus();
                              if (_selectedEmails.contains(user.email)) {
                                _selectedEmails.remove(user.email);
                              } else {
                                _selectedEmails.add(user.email);
                              }
                              setState(() {});
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            context.l10n.chooseARecoveryTime,
            style: TextStyles.body.copyWith(color: colors.textLight),
          ),
          const SizedBox(height: 12),
          RecoveryDateSelector(
            selectedDays: _selectedRecoveryDays,
            onDaysChanged: (days) {
              setState(() {
                _selectedRecoveryDays = days;
              });
            },
          ),
          const SizedBox(height: 20),
          ButtonComponent(
            label: context.l10n.addTrustedContact,
            isDisabled: !canAdd,
            onTap: canAdd ? _onAddContactTap : null,
            shouldSurfaceExecutionStates: false,
          ),
          const SizedBox(height: 12),
          Center(
            child: ButtonComponent(
              label: AppLocalizations.of(context).verifyIDLabel,
              variant: ButtonComponentVariant.link,
              size: ButtonComponentSize.small,
              isDisabled: emailForVerification == null,
              shouldSurfaceExecutionStates: false,
              onTap: emailForVerification == null
                  ? null
                  : () async {
                      await _onVerifyTap(emailForVerification);
                    },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onAddContactTap() async {
    final sheetContext = context;
    final emailsToAdd = _emailsToAdd;
    if (emailsToAdd.isEmpty) {
      return;
    }
    final confirmed = await _showAddContactConfirmationSheet(
      emailsToAdd,
      _selectedRecoveryDays,
    );
    if (confirmed != true) {
      return;
    }

    final failures = <String>[];
    var hasSuccess = false;
    for (final email in emailsToAdd) {
      try {
        late final bool success;
        if (sheetContext.mounted) {
          success = await EmergencyContactService.instance.addContact(
            sheetContext,
            email,
            recoveryNoticeInDays: _selectedRecoveryDays,
          );
        } else {
          success = await EmergencyContactService.instance.addContact(
            null,
            email,
            recoveryNoticeInDays: _selectedRecoveryDays,
          );
        }
        if (success) {
          hasSuccess = true;
        } else {
          failures.add(email);
        }
      } catch (e) {
        _logger.severe("Failed to add contact for $email", e);
        failures.add(email);
      }
    }

    if (hasSuccess && mounted) {
      Navigator.of(context).pop(true);
    } else if (failures.isNotEmpty && mounted) {
      await showAlertBottomSheet(
        context,
        title: AppLocalizations.of(context).error,
        message: AppLocalizations.of(context).somethingWentWrong,
        assetPath: "assets/warning-grey.png",
      );
    }
  }

  Future<bool?> _showAddContactConfirmationSheet(
    List<String> emails,
    int recoveryDays,
  ) {
    final l10n = AppLocalizations.of(context);
    final message = emails.length == 1
        ? l10n.confirmAddingTrustedContact(
            email: emails.first,
            numOfDays: recoveryDays,
          )
        : l10n.confirmAddingTrustedContacts(
            count: emails.length,
            numOfDays: recoveryDays,
          );

    return showAlertBottomSheet<bool>(
      context,
      title: l10n.warning,
      message: message,
      assetPath: "assets/warning-grey.png",
      buttons: [
        ButtonWidgetV2(
          buttonType: ButtonTypeV2.critical,
          labelText: l10n.proceed,
          onTap: () async => Navigator.of(context).pop(true),
          shouldSurfaceExecutionStates: false,
        ),
      ],
    );
  }

  Future<void> _onVerifyTap(String emailToAdd) async {
    if (!_emailsToAdd.contains(emailToAdd)) {
      await showAlertBottomSheet(
        context,
        title: AppLocalizations.of(context).invalidEmailAddress,
        message: AppLocalizations.of(context).enterValidEmail,
        assetPath: "assets/warning-grey.png",
      );
      return;
    }

    await showVerifyIdentitySheet(context, self: false, email: emailToAdd);
  }

  List<User> _getSuggestedUser() {
    final List<User> suggestedUsers = [];
    final Set<String> existingEmails = {};
    final int ownerID = Configuration.instance.getUserID()!;
    existingEmails.add(Configuration.instance.getEmail()!);

    for (final contact in widget.emergencyInfo.othersEmergencyContact) {
      if (!existingEmails.contains(contact.user.email)) {
        existingEmails.add(contact.user.email);
        suggestedUsers.add(contact.user);
      }
    }

    for (final c in CollectionsService.instance.getActiveCollections()) {
      if (c.owner.id == ownerID) {
        for (final User u in c.sharees) {
          if (u.id != null &&
              u.email.isNotEmpty &&
              !existingEmails.contains(u.email)) {
            existingEmails.add(u.email);
            suggestedUsers.add(u);
          }
        }
      } else if (c.owner.id != null &&
          c.owner.email.isNotEmpty &&
          !existingEmails.contains(c.owner.email)) {
        existingEmails.add(c.owner.email);
        suggestedUsers.add(c.owner);
      }
    }

    final cachedUserDetails = UserService.instance.getCachedUserDetails();
    if (cachedUserDetails != null &&
        (cachedUserDetails.familyData?.members?.isNotEmpty ?? false)) {
      for (final member in cachedUserDetails.familyData!.members!) {
        if (!existingEmails.contains(member.email)) {
          existingEmails.add(member.email);
          suggestedUsers.add(User(email: member.email));
        }
      }
    }
    if (_textController.text.trim().isNotEmpty) {
      suggestedUsers.removeWhere(
        (element) => !element.email.toLowerCase().contains(
          _textController.text.trim().toLowerCase(),
        ),
      );
    }
    suggestedUsers.sort((a, b) => a.email.compareTo(b.email));

    return suggestedUsers;
  }

  List<String> get _emailsToAdd {
    final lowerCaseToEmail = <String, String>{};

    for (final email in _selectedEmails) {
      lowerCaseToEmail[email.toLowerCase()] = email;
    }
    if (_emailIsValid) {
      lowerCaseToEmail[_email.toLowerCase()] = _email;
    }

    return lowerCaseToEmail.values.toList()..sort();
  }

  String? get _emailForVerification {
    final emailsToAdd = _emailsToAdd;
    if (emailsToAdd.length == 1) {
      return emailsToAdd.first;
    }
    return null;
  }
}
