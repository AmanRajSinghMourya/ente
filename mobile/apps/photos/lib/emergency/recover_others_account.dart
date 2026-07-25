import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:ente_components/ente_components.dart";
import "package:ente_crypto/ente_crypto.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:password_strength/password_strength.dart';
import "package:photos/emergency/components/email_action_sheet.dart";
import "package:photos/emergency/emergency_service.dart";
import "package:photos/emergency/model.dart";
import "package:photos/gateways/users/models/key_attributes.dart";
import "package:photos/gateways/users/models/set_keys_request.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/ui/settings/components/settings_page_scaffold.dart";

class RecoverOthersAccount extends StatefulWidget {
  final String recoveryKey;
  final KeyAttributes attributes;
  final RecoverySessions sessions;

  const RecoverOthersAccount(
    this.recoveryKey,
    this.attributes,
    this.sessions, {
    super.key,
  });

  @override
  State<RecoverOthersAccount> createState() => _RecoverOthersAccountState();
}

class _RecoverOthersAccountState extends State<RecoverOthersAccount> {
  static const kMildPasswordStrengthThreshold = 0.4;
  static const kStrongPasswordStrengthThreshold = 0.7;

  final _logger = Logger((_RecoverOthersAccountState).toString());
  final _passwordController1 = TextEditingController();
  final _passwordController2 = TextEditingController();
  String _passwordInInputBox = '';
  String _passwordInInputConfirmationBox = '';
  double _passwordStrength = 0.0;

  bool _passwordsMatch = false;
  bool _isPasswordValid = false;
  bool _showPasswordStrength = false;
  bool _isProgressSheetOpen = false;
  Timer? _passwordStrengthTimer;

  @override
  void dispose() {
    _passwordStrengthTimer?.cancel();
    _passwordController1.dispose();
    _passwordController2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = AppLocalizations.of(context).resetPasswordTitle;
    final isFormValid = _passwordsMatch && _isPasswordValid;

    return SettingsPageScaffold(
      title: title,
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.sm,
          Spacing.lg,
          Spacing.lg,
        ),
        child: ButtonComponent(
          label: title,
          isDisabled: !isFormValid,
          shouldShowSuccessState: false,
          onTap: isFormValid
              ? () async {
                  await _updatePassword();
                  if (!context.mounted) return;
                  FocusScope.of(context).unfocus();
                }
              : null,
        ),
      ),
      children: [_getBody()],
    );
  }

  Widget _getBody() {
    final email = widget.sessions.user.email;
    String? passwordMessage;
    var passwordMessageType = TextInputComponentMessageType.helper;

    if (_passwordInInputBox.isNotEmpty && _showPasswordStrength) {
      if (_passwordStrength > kStrongPasswordStrengthThreshold) {
        passwordMessage = AppLocalizations.of(context).strongPassword;
        passwordMessageType = TextInputComponentMessageType.success;
      } else if (_passwordStrength <= kMildPasswordStrengthThreshold) {
        passwordMessage = AppLocalizations.of(context).weakStrength;
        passwordMessageType = TextInputComponentMessageType.alert;
      }
    }

    String? confirmPasswordMessage;
    var confirmPasswordMessageType = TextInputComponentMessageType.helper;

    if (_passwordInInputConfirmationBox.isNotEmpty &&
        _passwordInInputBox.isNotEmpty) {
      if (_passwordsMatch) {
        confirmPasswordMessage = AppLocalizations.of(context).passwordsMatch;
        confirmPasswordMessageType = TextInputComponentMessageType.success;
      } else {
        confirmPasswordMessage = AppLocalizations.of(
          context,
        ).passwordsDontMatch;
        confirmPasswordMessageType = TextInputComponentMessageType.error;
      }
    }

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Enter new password for $email account. You will be able "
            "to use this password to login into $email account.",
            style: TextStyles.body.copyWith(
              color: context.componentColors.textLight,
            ),
          ),
          const SizedBox(height: Spacing.xxl),
          Visibility(
            visible: false,
            child: TextInputComponent(
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              initialValue: email,
              textInputAction: TextInputAction.next,
            ),
          ),
          TextInputComponent(
            label: AppLocalizations.of(context).password,
            hintText: AppLocalizations.of(context).password,
            controller: _passwordController1,
            isPasswordInput: true,
            isRequired: true,
            autocorrect: false,
            autofillHints: const [AutofillHints.newPassword],
            message: passwordMessage,
            messageType: passwordMessageType,
            onChanged: (password) {
              if (password != _passwordInInputBox) {
                _passwordStrengthTimer?.cancel();
                setState(() {
                  _passwordInInputBox = password;
                  _passwordStrength = estimatePasswordStrength(password);
                  _isPasswordValid =
                      _passwordStrength >= kMildPasswordStrengthThreshold;
                  _passwordsMatch =
                      _passwordInInputBox == _passwordInInputConfirmationBox;
                  _showPasswordStrength = false;
                });
                _passwordStrengthTimer = Timer(const Duration(seconds: 1), () {
                  if (mounted) {
                    setState(() {
                      _showPasswordStrength = true;
                    });
                  }
                });
              }
            },
          ),
          const SizedBox(height: Spacing.lg),
          TextInputComponent(
            label: AppLocalizations.of(context).confirmPassword,
            hintText: AppLocalizations.of(context).confirmPassword,
            controller: _passwordController2,
            isPasswordInput: true,
            isRequired: true,
            autocorrect: false,
            autofillHints: const [AutofillHints.newPassword],
            finishAutofillContextOnEditingComplete: true,
            message: confirmPasswordMessage,
            messageType: confirmPasswordMessageType,
            onChanged: (confirmPassword) {
              setState(() {
                _passwordInInputConfirmationBox = confirmPassword;
                if (_passwordInInputBox.isNotEmpty) {
                  _passwordsMatch =
                      _passwordInInputBox == _passwordInInputConfirmationBox;
                }
              });
            },
          ),
          const SizedBox(height: Spacing.xxl),
        ],
      ),
    );
  }

  Future<void> _updatePassword() async {
    _showProgressSheet();
    try {
      final String password = _passwordController1.text;
      final KeyAttributes attributes = widget.attributes;
      Uint8List? masterKey;
      try {
        // Decrypt the master key that was earlier encrypted with the recovery key
        masterKey = await CryptoUtil.decrypt(
          CryptoUtil.base642bin(attributes.masterKeyEncryptedWithRecoveryKey!),
          CryptoUtil.hex2bin(widget.recoveryKey),
          CryptoUtil.base642bin(attributes.masterKeyDecryptionNonce!),
        );
      } catch (e) {
        _logger.severe(e, "Failed to get master key using recoveryKey");
        rethrow;
      }

      // Derive a key from the password that will be used to encrypt and
      // decrypt the master key
      final kekSalt = CryptoUtil.getSaltToDeriveKey();
      final derivedKeyResult = await CryptoUtil.deriveSensitiveKey(
        utf8.encode(password),
        kekSalt,
      );
      final loginKey = await CryptoUtil.deriveLoginKey(derivedKeyResult.key);
      // Encrypt the key with this derived key
      final encryptedKeyData = CryptoUtil.encryptSync(
        masterKey,
        derivedKeyResult.key,
      );

      final updatedAttributes = attributes.copyWith(
        kekSalt: CryptoUtil.bin2base64(kekSalt),
        encryptedKey: CryptoUtil.bin2base64(encryptedKeyData.encryptedData!),
        keyDecryptionNonce: CryptoUtil.bin2base64(encryptedKeyData.nonce!),
        memLimit: derivedKeyResult.memLimit,
        opsLimit: derivedKeyResult.opsLimit,
      );
      final setKeyRequest = SetKeysRequest(
        kekSalt: updatedAttributes.kekSalt,
        encryptedKey: updatedAttributes.encryptedKey,
        keyDecryptionNonce: updatedAttributes.keyDecryptionNonce,
        memLimit: updatedAttributes.memLimit!,
        opsLimit: updatedAttributes.opsLimit!,
      );
      await EmergencyContactService.instance.changePasswordForOther(
        loginKey,
        setKeyRequest,
        widget.sessions,
      );
      _closeProgressSheet();
      if (!mounted) return;
      await showBottomSheetComponent<void>(
        context: context,
        builder: (_) => BottomSheetComponent(
          title: AppLocalizations.of(context).passwordChangedSuccessfully,
          actions: [
            ButtonComponent(
              label: AppLocalizations.of(context).ok,
              dismissModalOnSuccess: true,
              shouldShowSuccessState: false,
              onTap: () async {},
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e, s) {
      _logger.severe("Failed to recover account", e, s);
      _closeProgressSheet();
      if (!mounted) return;
      await showLegacyErrorSheet(context, error: e);
    }
  }

  void _showProgressSheet() {
    _isProgressSheetOpen = true;
    unawaited(
      showBottomSheetComponent<void>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => BottomSheetComponent(
          title: AppLocalizations.of(context).generatingEncryptionKeys,
          showCloseButton: false,
          content: Row(
            children: [
              SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.componentColors.primary,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).pleaseWait,
                  style: TextStyles.body.copyWith(
                    color: context.componentColors.textLight,
                  ),
                ),
              ),
            ],
          ),
        ),
      ).whenComplete(() {
        _isProgressSheetOpen = false;
      }),
    );
  }

  void _closeProgressSheet() {
    if (!_isProgressSheetOpen || !mounted) {
      return;
    }
    _isProgressSheetOpen = false;
    Navigator.of(context).pop();
  }
}
