import 'exceptions.dart';

/// Cooperative cancel flag for a write.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled({bool diskAlreadyErased = false, String? message}) {
    if (!_cancelled) {
      return;
    }
    throw WriteCancelledException(
      message ??
          (diskAlreadyErased
              ? 'Write cancelled. The USB was erased and may not be bootable.'
              : 'Write cancelled.'),
    );
  }
}

class WriteCancelledException extends UsbIsoException {
  WriteCancelledException(super.message);
}
