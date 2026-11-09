import '../../editor/ai/ai_models.dart';
import '../../editor/ai/ai_routing.dart';
import '../../editor/handwriting/handwriting_calibration.dart';
import '../../editor/ink/ink_sample.dart';
import '../../payment/subscription_controller.dart';
import '../study_desk/study_desk_controller.dart';
import '../study_desk/study_desk_models.dart';
import 'synced_settings.dart';

/// How long a deleted chat is remembered as deleted. A device that has not
/// been back by then gets the chat again, which is the lesser harm.
const Duration _tombstoneKeeps = Duration(days: 180);

/// The Study Desk's chats and courses.
///
/// Devices add to one another: a chat is on every device that has ever seen
/// it, in the version last written, until it is deleted on one of them.
class StudyChatsSection extends SyncedSettingsSection {
  StudyChatsSection(this.desk, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final StudyDeskController Function() desk;
  final DateTime Function() _clock;

  @override
  String get id => 'chats';

  @override
  Future<SettingsData?> read() async {
    final chats = await desk().syncedChats();
    if (chats == null) return null;
    return _encode(
      sessions: chats.sessions,
      courses: chats.courses,
      deleted: chats.deleted,
    );
  }

  @override
  Future<void> write(SettingsData data) async {
    final _Chats chats = _decode(data);
    await desk().applySyncedChats(
      sessions: chats.sessions.values.toList(),
      courses: chats.courses.values.toList(),
      deleted: chats.deleted,
    );
  }

  @override
  bool isPristine(SettingsData data) {
    final _Chats chats = _decode(data);
    return chats.sessions.isEmpty &&
        chats.courses.isEmpty &&
        chats.deleted.isEmpty;
  }

  @override
  SettingsData? merge({
    required SettingsData? local,
    required int localModified,
    required SettingsData remote,
    required int remoteModified,
  }) {
    final _Chats mine = local == null ? _Chats() : _decode(local);
    final _Chats theirs = _decode(remote);
    final Map<String, int> deleted = <String, int>{...mine.deleted};
    for (final MapEntry<String, int> entry in theirs.deleted.entries) {
      final int? known = deleted[entry.key];
      if (known == null || entry.value > known) {
        deleted[entry.key] = entry.value;
      }
    }
    final int cutoff = _clock()
        .subtract(_tombstoneKeeps)
        .millisecondsSinceEpoch;
    deleted.removeWhere((String _, int at) => at < cutoff);

    final Map<String, StudySession> sessions = <String, StudySession>{
      ...mine.sessions,
    };
    for (final StudySession other in theirs.sessions.values) {
      final StudySession? have = sessions[other.id];
      if (have == null || other.updatedAt.isAfter(have.updatedAt)) {
        sessions[other.id] = other;
      }
    }
    // Deleted after it was last written: gone.
    sessions.removeWhere((String id, StudySession session) {
      final int? at = deleted[id];
      return at != null && at >= session.updatedAt.millisecondsSinceEpoch;
    });
    // A chat written after it was deleted was brought back.
    deleted.removeWhere((String id, int at) {
      final StudySession? session = sessions[id];
      return session != null && at < session.updatedAt.millisecondsSinceEpoch;
    });

    // A class changed on another device, its color included, is taken in the
    // version last changed, as a chat is.
    final Map<String, StudyCourse> courses = <String, StudyCourse>{
      ...mine.courses,
    };
    for (final StudyCourse other in theirs.courses.values) {
      final StudyCourse? have = courses[other.id];
      if (have == null || other.changedAt.isAfter(have.changedAt)) {
        courses[other.id] = other;
      }
    }

    return _encode(
      sessions: sessions.values,
      courses: courses.values.where(
        (StudyCourse c) => !deleted.containsKey(c.id),
      ),
      deleted: deleted,
    );
  }

  static SettingsData _encode({
    required Iterable<StudySession> sessions,
    required Iterable<StudyCourse> courses,
    required Map<String, int> deleted,
  }) {
    // Sorted, so that the same chats are the same data on every device.
    final List<StudySession> chats = sessions.toList()
      ..sort((StudySession a, StudySession b) => a.id.compareTo(b.id));
    final List<StudyCourse> classes = courses.toList()
      ..sort((StudyCourse a, StudyCourse b) => a.id.compareTo(b.id));
    final List<String> gone = deleted.keys.toList()..sort();
    return <String, Object?>{
      'sessions': <Object?>[for (final StudySession s in chats) s.toJson()],
      'courses': <Object?>[for (final StudyCourse c in classes) c.toJson()],
      'deleted': <String, Object?>{
        for (final String id in gone) id: deleted[id],
      },
    };
  }

  static _Chats _decode(SettingsData data) {
    final _Chats chats = _Chats();
    for (final Object? raw
        in (data['sessions'] as List?) ?? const <Object?>[]) {
      if (raw is! Map<String, Object?>) continue;
      try {
        final StudySession session = StudySession.fromJson(raw);
        chats.sessions[session.id] = session;
      } on Object {
        // One chat this version cannot read does not cost the others.
      }
    }
    for (final Object? raw in (data['courses'] as List?) ?? const <Object?>[]) {
      if (raw is! Map<String, Object?>) continue;
      try {
        final StudyCourse course = StudyCourse.fromJson(raw);
        chats.courses[course.id] = course;
      } on Object {
        // As above.
      }
    }
    final Object? deleted = data['deleted'];
    if (deleted is Map<Object?, Object?>) {
      for (final MapEntry<Object?, Object?> entry in deleted.entries) {
        if (entry.key case final String id) {
          if (entry.value case final int at) chats.deleted[id] = at;
        }
      }
    }
    return chats;
  }
}

class _Chats {
  final Map<String, StudySession> sessions = <String, StudySession>{};
  final Map<String, StudyCourse> courses = <String, StudyCourse>{};
  final Map<String, int> deleted = <String, int>{};
}

/// How the assistant is configured: how hard it thinks, which models may be
/// used, whether answers name their model, and the model last picked.
class AiSettingsSection extends SyncedSettingsSection {
  AiSettingsSection(this.subscription);

  final SubscriptionController Function() subscription;

  @override
  String get id => 'ai';

  @override
  Future<SettingsData?> read() async {
    final SubscriptionController controller = subscription();
    // Until what was kept is read, the defaults would pass for a choice.
    if (!controller.isLoaded) return null;
    return <String, Object?>{
      'routing': controller.routing.toJson(),
      if (controller.preferredModel != null)
        'preferredModel': controller.preferredModel!.name,
    };
  }

  @override
  Future<void> write(SettingsData data) async {
    final SubscriptionController controller = subscription();
    controller.setRouting(AiRoutingPreferences.fromJson(data['routing']));
    final Object? name = data['preferredModel'];
    for (final AiModelId model in AiModelId.values) {
      if (model.name == name) controller.setPreferredModel(model);
    }
    await controller.saved;
  }

  @override
  bool isPristine(SettingsData data) =>
      AiRoutingPreferences.fromJson(data['routing']) ==
          const AiRoutingPreferences() &&
      data['preferredModel'] == null;
}

/// The handwriting the assistant writes in, and how large: the font chosen,
/// or the writer's own made from their letters, and the choices around it.
class HandwritingFontsSection extends SyncedSettingsSection {
  HandwritingFontsSection(this.store);

  /// The store itself, not one that tells of its writes: what comes from
  /// another device is not a change to send back.
  final HandwritingProfileStore Function() store;

  @override
  String get id => 'fonts';

  @override
  Future<SettingsData?> read() async => (await store().read())?.toJson();

  @override
  Future<void> write(SettingsData data) =>
      store().write(HandwritingCalibrationState.fromJson(data));
}

/// A handwriting profile store that tells when it is written to, so that the
/// change can be backed up.
class ObservedHandwritingProfileStore implements HandwritingProfileStore {
  ObservedHandwritingProfileStore(this.inner, this.onWritten);

  final HandwritingProfileStore inner;
  final void Function() onWritten;

  @override
  Future<HandwritingCalibrationState?> read() => inner.read();

  @override
  Future<void> write(HandwritingCalibrationState state) async {
    await inner.write(state);
    onWritten();
  }

  @override
  Future<List<List<List<InkVector>>>> readDraft() => inner.readDraft();

  @override
  Future<void> writeDraft(List<List<List<InkVector>>> pages) =>
      inner.writeDraft(pages);
}
