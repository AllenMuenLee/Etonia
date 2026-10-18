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

  /// Charges an answer from [model] that took [usage].
  void recordUsage(AiModelId model, AiTokenUsage usage);

  /// A few words for the credits pill: `$1.20 left`, or `Upgrade`.
  String get creditsLabel;

  /// The model last picked, remembered across launches.
  AiModelId? get preferredModel;

  void setPreferredModel(AiModelId model);
}
