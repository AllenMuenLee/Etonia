/// Tuning values for the One Euro pen filter. Distances are logical pixels.
class SmoothingConfig {
  const SmoothingConfig({
    this.minCutoff = 1,
    this.beta = 0.02,
    this.derivativeCutoff = 1,
    this.minDtSeconds = 0.001,
    this.maxDtSeconds = 0.1,
    this.maxFinalizationPoints = 8,
    this.finalizationSpacing = 2,
    this.endpointTolerance = 0.01,
  }) : assert(minCutoff > 0 && minCutoff < double.infinity),
       assert(beta >= 0 && beta < double.infinity),
       assert(derivativeCutoff > 0 && derivativeCutoff < double.infinity),
       assert(minDtSeconds > 0 && minDtSeconds < double.infinity),
       assert(maxDtSeconds >= minDtSeconds && maxDtSeconds < double.infinity),
       assert(maxFinalizationPoints >= 1),
       assert(finalizationSpacing > 0 && finalizationSpacing < double.infinity),
       assert(endpointTolerance >= 0 && endpointTolerance < double.infinity);

  /// Minimum position cutoff in hertz. Lower values remove more slow jitter
  /// but add more lag at low speed.
  final double minCutoff;

  /// Speed coefficient in hertz per logical pixel/second. Higher values
  /// reduce lag during fast motion at the cost of passing more noise.
  final double beta;

  /// Cutoff in hertz for the derivative low-pass filter. The paper recommends
  /// 1 Hz and notes that it rarely needs tuning.
  final double derivativeCutoff;

  /// Lower clamp for time between samples. Guards duplicate timestamps.
  final double minDtSeconds;

  /// Upper clamp for time between samples. Guards long event gaps.
  final double maxDtSeconds;

  /// Hard cap on points appended when a stroke ends to reach the raw endpoint.
  final int maxFinalizationPoints;

  /// Target distance between finalization points.
  final double finalizationSpacing;

  /// No finalization tail is added within this distance of the raw endpoint.
  final double endpointTolerance;
}
