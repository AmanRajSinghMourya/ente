class UnauthorizedError extends Error {}

class StorageLimitExceededError extends Error {}

class NoActiveSubscriptionError extends Error {}

class FileLimitReachedError extends Error {}

class FileTooLargeForPlanError extends Error {}

class SharingNotPermittedForFreeAccountsError extends Error {}

class InvalidFileError extends ArgumentError {
  final InvalidReason reason;

  InvalidFileError(String super.message, this.reason);

  @override
  String toString() {
    return 'InvalidFileError: $message (reason: $reason)';
  }
}

enum InvalidReason { tooLargeFile }
