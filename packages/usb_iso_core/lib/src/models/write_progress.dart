enum WriteStep {
  validating,
  preparing,
  erasing,
  mounting,
  copying,
  writing,
  splitting,
  verifying,
  ejecting,
  done,
  error,
}

class WriteProgress {
  const WriteProgress({
    required this.step,
    required this.message,
    this.percent,
  });

  final WriteStep step;
  final String message;

  /// 0.0–1.0 when known.
  final double? percent;

  bool get isTerminal => step == WriteStep.done || step == WriteStep.error;
}
