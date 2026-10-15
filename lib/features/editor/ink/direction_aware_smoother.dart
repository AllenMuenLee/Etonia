// Compatibility shim for code that imported the old custom smoother.
// New code should import `one_euro_smoother.dart` and use [OneEuroSmoother].
export 'one_euro_smoother.dart';

import 'one_euro_smoother.dart';

@Deprecated('Use OneEuroSmoother. The direction-aware filter was replaced.')
typedef DirectionAwareSmoother = OneEuroSmoother;
