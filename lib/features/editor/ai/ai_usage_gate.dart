import 'package:flutter/foundation.dart';

import 'ai_client.dart';

/// What the user's plan allows with one model.
enum AiModelAccess {
  /// Included without limit.
  unlimited,

  /// Paid for from the plan's AI credits.
  metered,

  /// Included, but the credits are spent.
  outOfCredits,

  /// Not on the user's plan; a higher plan includes it.
  locked,

  /// No plan is active.
  noPlan;

  bool get canSend => this == unlimited || this == metered;
}

/// Decides which models the assistant may use, and is told what each
/// answer cost. The editor depends on this alone, so tests, and builds that
/// meter on a server, can supply their own.
abstract mixin class AiUsageGate implements Listenable {
  AiModelAccess accessFor(AiModelId model);

  /// Why a request to [model] cannot be sent now, or null when it can.
  AiFailure? checkAccess(AiModelId model) {
    return switch (accessFor(model)) {
      AiModelAccess.unlimited || AiModelAccess.metered => null,
      AiModelAccess.outOfCredits => const AiFailure(
        AiFailureKind.insufficientCredits,
      ),
      AiModelAccess.locked ||
      AiModelAccess.noPlan => const AiFailure(AiFailureKind.planRequired),
    };
  }

  /// Why nothing can be sent now with any of the [allowed] models, or null
  /// when one can. A paid plan out of credits can still use its unlimited
  /// models, so it is never refused here; a free plan with nothing left is.
  AiFailure? checkRouting(Set<AiModelId> allowed) {
    AiFailure? first;
    AiFailure? credits;
    for (final AiModelId model in allowed) {
      final AiFailure? refused = checkAccess(model);
      if (refused == null) return null;
      first ??= refused;
      if (refused.kind == AiFailureKind.insufficientCredits) {
        credits ??= refused;
      }
    }
    return credits ?? first;
  }

  /// Charges an answer from [model] that took [usage].
  void recordUsage(AiModelId model, AiTokenUsage usage);

  /// A few words for the token pill: `100% tokens`, or `Upgrade`.
  String get creditsLabel;

  /// Fraction (`0.0` to `1.0`) of the active token allowance remaining.
  double get tokenFraction => 0;

  /// Whether the metered token allowance has reached zero.
  bool get isOutOfTokens => tokenFraction <= 0;

  /// How hard to think and which models may be used, remembered across
  /// launches.
  AiRoutingPreferences get routing => const AiRoutingPreferences();

  void setRouting(AiRoutingPreferences value) {}

  /// The model last picked, remembered across launches. Only a client that
  /// does not choose models for itself uses it.
  AiModelId? get preferredModel;

  void setPreferredModel(AiModelId model);
}
