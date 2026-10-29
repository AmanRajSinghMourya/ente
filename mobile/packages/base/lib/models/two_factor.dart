import 'package:ente_frb/accounts.dart';

export 'package:ente_frb/accounts.dart'
    show
        AccountsClient,
        AccountsClientConfig,
        AccountsError,
        TwoFactorAuthorizationResponse,
        TwoFactorRecoveryResponse,
        TwoFactorType;

typedef CreateAccountsClient =
    AccountsClient Function({required AccountsClientConfig config});

extension TwoFactorAuthorizationResponseMap on TwoFactorAuthorizationResponse {
  Map<String, dynamic> toMap() => {
    'id': id.toInt(),
    'encryptedToken': encryptedToken,
    'keyAttributes': {
      'kekSalt': keyAttributes.kekSalt,
      'encryptedKey': keyAttributes.encryptedKey,
      'keyDecryptionNonce': keyAttributes.keyDecryptionNonce,
      'publicKey': keyAttributes.publicKey,
      'encryptedSecretKey': keyAttributes.encryptedSecretKey,
      'secretKeyDecryptionNonce': keyAttributes.secretKeyDecryptionNonce,
      'memLimit': keyAttributes.memLimit.toInt(),
      'opsLimit': keyAttributes.opsLimit,
      'masterKeyEncryptedWithRecoveryKey':
          keyAttributes.masterKeyEncryptedWithRecoveryKey,
      'masterKeyDecryptionNonce': keyAttributes.masterKeyDecryptionNonce,
      'recoveryKeyEncryptedWithMasterKey':
          keyAttributes.recoveryKeyEncryptedWithMasterKey,
      'recoveryKeyDecryptionNonce': keyAttributes.recoveryKeyDecryptionNonce,
    },
  };
}
