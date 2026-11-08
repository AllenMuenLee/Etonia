import 'package:flutter/foundation.dart';

import 'ai_client.dart';
import 'ai_usage_gate.dart';

/// How long the assistant thinks before it answers. The user sets this, and
/// nothing else about which model answers: the server picks the cheapest
/// (model, effort) that is capable enough for the task.
enum AiEffort {
  auto(
    'auto',
    'Auto',
    'Thinks only as long as the question needs, on the cheapest model that '
        'can answer it well.',
  ),
  low('low', 'Low', 'Quick answers. Best for simple questions.'),
  medium('medium', 'Medium', 'Balanced. Good for most study questions.'),
  high(
    'high',
    'High',
    'Thinks longest. For hard derivations. Uses more credits.',
  );

  const AiEffort(this.wireName, this.label, this.description);

  /// What the server is sent.
  final String wireName;
  final String label;
  final String description;

  static AiEffort fromName(Object? name) {
    for (final AiEffort effort in values) {
      if (effort.name == name) return effort;
    }
    return auto;
  }
}

/// What a request is for. The server holds each task to a different bar and
/// price: a list of follow-up questions needs far less than a derivation.
enum AiRouteTask {
  studyAnswer('study.answer'),
  studyPlan('study.plan'),
  studyDescribe('study.describe'),
  studySuggestions('study.suggestions'),
  studyPractice('study.practice'),
  editorAnswer('editor.answer'),
  testGrading('test.grading');

  const AiRouteTask(this.wireName);

  final String wireName;
}

/// What the user chose in the settings: how hard to think, and which models
/// may be used at all. Both are the user's, and survive launches.
@immutable
class AiRoutingPreferences {
  const AiRoutingPreferences({
    this.effort = AiEffort.auto,
    this.disabledModels = const <AiModelId>{},
    this.showModelUsed = false,
  });

  factory AiRoutingPreferences.fromJson(Object? json) {
    if (json is! Map<Object?, Object?>) return const AiRoutingPreferences();
    final Object? disabled = json['disabledModels'];
    return AiRoutingPreferences(
      effort: AiEffort.fromName(json['effort']),
      disabledModels: <AiModelId>{
        if (disabled is List<Object?>)
          for (final AiModelId model in AiModelId.values)
            if (disabled.contains(model.name)) model,
      },
      showModelUsed: json['showModelUsed'] == true,
    );
  }

  final AiEffort effort;

  /// Models the user turned off. Never used, whatever the task.
  final Set<AiModelId> disabledModels;

  /// Whether each answer says which model wrote it.
  final bool showModelUsed;

  Set<AiModelId> get allowedModels => <AiModelId>{
    for (final AiModelId model in AiModelId.values)
      if (!disabledModels.contains(model)) model,
  };

  /// Whether every model is on, which is what the server assumes when told
  /// nothing.
  bool get allModelsEnabled => disabledModels.isEmpty;

  bool isEnabled(AiModelId model) => !disabledModels.contains(model);

  /// Whether any model of [provider] is on.
  bool isProviderEnabled(AiProvider provider) => AiModelId.values.any(
    (AiModelId model) => model.provider == provider && isEnabled(model),
  );

  AiRoutingPreferences copyWith({AiEffort? effort, bool? showModelUsed}) {
    return AiRoutingPreferences(
      effort: effort ?? this.effort,
      disabledModels: disabledModels,
      showModelUsed: showModelUsed ?? this.showModelUsed,
    );
  }

  AiRoutingPreferences withModel(AiModelId model, {required bool enabled}) {
    final Set<AiModelId> disabled = <AiModelId>{...disabledModels};
    enabled ? disabled.remove(model) : disabled.add(model);
    return AiRoutingPreferences(
      effort: effort,
      disabledModels: disabled,
      showModelUsed: showModelUsed,
    );
  }

  /// Turns every model of [provider] on or off, so that a user can keep their
  /// notes away from one provider with a single switch.
  AiRoutingPreferences withProvider(
    AiProvider provider, {
    required bool enabled,
  }) {
    final Set<AiModelId> disabled = <AiModelId>{...disabledModels};
    for (final AiModelId model in AiModelId.values) {
      if (model.provider != provider) continue;
      enabled ? disabled.remove(model) : disabled.add(model);
    }
    return AiRoutingPreferences(
      effort: effort,
      disabledModels: disabled,
      showModelUsed: showModelUsed,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'effort': effort.name,
    'disabledModels': <String>[
      for (final AiModelId model in AiModelId.values)
        if (disabledModels.contains(model)) model.name,
    ],
    'showModelUsed': showModelUsed,
  };

  @override
  bool operator ==(Object other) {
    return other is AiRoutingPreferences &&
        other.effort == effort &&
        other.showModelUsed == showModelUsed &&
        setEquals(other.disabledModels, disabledModels);
  }

  @override
  int get hashCode => Object.hash(
    effort,
    showModelUsed,
    Object.hashAllUnordered(disabledModels),
  );
}

/// What one request tells the server so that it can choose a model.
@immutable
class AiRouting {
  const AiRouting({
    required this.task,
    this.effort = AiEffort.auto,
    this.allowedModels,
    this.difficulty,
    this.needsVision,
    this.diagrams = false,
    this.previous,
    this.previousAge = Duration.zero,
  });

  final AiRouteTask task;
  final AiEffort effort;

  /// The models the user left on; null when they are all on.
  final Set<AiModelId>? allowedModels;

  /// 1 easy, 2 normal, 3 hard, when the app knows: the Study Desk planner has
  /// read the passages. The server assumes 2.
  final int? difficulty;

  /// Whether a picture has to be read. The server assumes it for the editor
  /// and for grading.
  final bool? needsVision;

  /// The picture is a diagram.
  final bool diagrams;

  /// The model that answered the previous turn, which the server keeps unless
  /// another is clearly cheaper (a warm prompt cache, a steady voice).
  final AiModelId? previous;
  final Duration previousAge;

  Map<String, Object?> toJson() => <String, Object?>{
    'task': task.wireName,
    'effort': effort.wireName,
    if (allowedModels != null)
      'allowedModels': <String>[
        for (final AiModelId model in AiModelId.values)
          if (allowedModels!.contains(model)) model.name,
      ],
    if (difficulty != null) 'difficulty': difficulty,
    if (needsVision != null) 'needsVision': needsVision,
    if (diagrams) 'diagrams': true,
    if (previous != null)
      'previous': <String, Object?>{
        'alias': previous!.name,
        'ageMs': previousAge.inMilliseconds,
      },
  };
}

/// What a chat needs of whatever holds the user's routing settings, so that
/// the Thinking control and the Advanced page can sit in any of them.
abstract interface class AiRoutingChooser implements Listenable {
  AiRoutingPreferences get routing;

  void setRouting(AiRoutingPreferences value);

  /// What the plan allows with [model]; null when nothing is metered.
  AiModelAccess? accessFor(AiModelId model);
}

/// One chat's side of routing: the settings it reads, the requests it builds
/// from them, and the model that answered last. The gate keeps the settings
/// across launches; without one, they last as long as the chat does.
class AiRoutingSession {
  AiRoutingSession(this._gate, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AiUsageGate? Function() _gate;
  final DateTime Function() _clock;

  AiRoutingPreferences _local = const AiRoutingPreferences();
  AiModelId? _previous;
  DateTime? _previousAt;

  AiRoutingPreferences get preferences => _gate()?.routing ?? _local;

  /// Keeps [value]; true when the gate was not there to tell its listeners.
  bool update(AiRoutingPreferences value) {
    final AiUsageGate? gate = _gate();
    if (gate != null) {
      gate.setRouting(value);
      return false;
    }
    if (value == _local) return false;
    _local = value;
    return true;
  }

  /// The routing for a request of [task], from the user's settings.
  AiRouting request(
    AiRouteTask task, {
    int? difficulty,
    bool? needsVision,
    bool diagrams = false,
  }) {
    final AiRoutingPreferences prefs = preferences;
    final DateTime? at = _previousAt;
    return AiRouting(
      task: task,
      effort: prefs.effort,
      allowedModels: prefs.allModelsEnabled ? null : prefs.allowedModels,
      difficulty: difficulty,
      needsVision: needsVision,
      diagrams: diagrams,
      previous: _previous,
      previousAge: at == null ? Duration.zero : _clock().difference(at),
    );
  }

  /// Why nothing can be sent now, or null when some allowed model can answer.
  /// A paid plan out of credits still can, on an unlimited model, so it is
  /// never told; a free plan with nothing left is.
  AiFailure? refusal() {
    final Set<AiModelId> allowed = preferences.allowedModels;
    if (allowed.isEmpty) return const AiFailure(AiFailureKind.noModelEnabled);
    final AiUsageGate? gate = _gate();
    return gate?.checkRouting(allowed);
  }

  /// The model to name when the server did not say who answered: the
  /// cheapest the user left on.
  AiModelId get cheapestAllowed {
    final List<AiModelId> allowed = preferences.allowedModels.toList()
      ..sort(
        (AiModelId a, AiModelId b) =>
            a.tokenMultiplier.compareTo(b.tokenMultiplier),
      );
    return allowed.isEmpty ? AiModelId.haiku : allowed.first;
  }

  /// The model a client that does not route should be sent: [preferred] when
  /// the user left it on, else the first they did.
  AiModelId directModel(AiModelId preferred, Iterable<AiModelId> offered) {
    final Set<AiModelId> allowed = preferences.allowedModels;
    if (allowed.contains(preferred)) return preferred;
    return offered.firstWhere(allowed.contains, orElse: () => preferred);
  }

  /// Remembers who answered, for the next request's stickiness.
  void served(AiModelId? model) {
    if (model == null) return;
    _previous = model;
    _previousAt = _clock();
  }
}
