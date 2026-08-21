/// Errors thrown by USB ISO Mount operations.
class UsbIsoException implements Exception {
  UsbIsoException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UnsafeDiskException extends UsbIsoException {
  UnsafeDiskException(super.message);
}

class InvalidIsoException extends UsbIsoException {
  InvalidIsoException(super.message);
}

class DependencyMissingException extends UsbIsoException {
  DependencyMissingException(super.message);
}

class UnsupportedPlatformException extends UsbIsoException {
  UnsupportedPlatformException(super.message);
}

class ConfirmationRequiredException extends UsbIsoException {
  ConfirmationRequiredException(super.message);
}
