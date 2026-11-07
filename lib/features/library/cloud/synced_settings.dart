import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'cloud_sync_state.dart';

/// What one kind of setting keeps, as JSON.
typedef SettingsData = Map<String, Object?>;

/// One kind of setting that follows the person to every device: the chats,
/// the AI they configured, the handwriting fonts.
abstract class SyncedSettingsSection {
  /// Names the section in the backup; never changes.
  String get id;

  /// What this device holds now, as the same data on every device would be
  /// (same order, nothing that belongs to this device alone); null when it
  /// holds nothing, or cannot say yet. Null is never sent.
  Future<SettingsData?> read();

  /// Makes this device hold [data], and whatever shows it, as it is.
  Future<void> write(SettingsData data);

  /// Whether [data] is what a device starts with, so that it never wins over
  /// what another device has chosen.
  bool isPristine(SettingsData data) => false;

  /// What this device should hold given its own and another device's, or null
  /// to keep its own. The newest choice wins unless a section knows better.
  SettingsData? merge({
    required SettingsData? local,
    required int localModified,
    required SettingsData remote,
    required int remoteModified,
  }) => remoteModified > localModified ? remote : null;
}

/// Keeps the settings of every [SyncedSettingsSection] in step through a
/// backup: [export] makes the file a backup carries, and [import] takes in
/// the file another device's backup carries.
///
/// When a section last changed here is worked out, not told: its content is
/// compared with what it was when it last came from, or went to, a backup. So
/// no setter needs to know about backups, and a device that has only ever
/// held the defaults never overrides one that has been set up.
class SyncedSettings {
  SyncedSettings({
    required this.sections,
    CloudStateStore? state,
    DateTime Function()? clock,
  }) : state = state ?? InMemoryCloudStateStore(),
       _clock = clock ?? DateTime.now;

  /// The file's own format.
  static const int schema = 1;

  static const String _key = 'sections';

  final List<SyncedSettingsSection> sections;
  final CloudStateStore state;
  final DateTime Function() _clock;

  /// Exports and imports take turns, so that one never reads what the other
  /// is half way through writing.
  Future<void> _queue = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() work) {
    final Future<T> result = _queue.then((_) => work());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// The file to send, or null when there is nothing to send yet.
  Future<Uint8List?> export() => _exclusive(() async {
    final Map<String, Object?> out = <String, Object?>{};
    for (final SyncedSettingsSection section in sections) {
      final _Held held = await _held(section);
      if (held.data == null) continue;
      out[section.id] = <String, Object?>{
        'modified': held.modified,
        'data': held.data,
      };
    }
    if (out.isEmpty) return null;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{'schema': schema, 'sections': out}),
      ),
    );
  });

  /// Takes in [bytes] from a backup, and how many sections changed here.
  /// Sections this version does not know are left alone, so a newer version
  /// can add its own.
  Future<int> import(Uint8List bytes) => _exclusive(() async {
    final Object? json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?>) return 0;
    final Object? version = json['schema'];
    if (version is! int || version > schema) return 0;
    final Object? incoming = json['sections'];
    if (incoming is! Map<String, Object?>) return 0;
    int changed = 0;
    for (final SyncedSettingsSection section in sections) {
      final Object? entry = incoming[section.id];
      if (entry is! Map<String, Object?>) continue;
      final Object? data = entry['data'];
      final Object? modified = entry['modified'];
      if (data is! Map<String, Object?> || modified is! int) continue;
      final _Held local = await _held(section);
      final SettingsData? merged = section.merge(
        local: local.data,
        localModified: local.modified,
        remote: data,
        remoteModified: modified,
      );
      if (merged == null) continue;
      if (local.data != null && _hash(merged) == _hash(local.data!)) continue;
      await section.write(merged);
      changed++;
      // As it is now, whatever the section made of what it was given.
      final SettingsData? written = await section.read();
      if (written != null) {
        await _remember(
          section,
          written,
          modified > local.modified ? modified : local.modified,
        );
      }
    }
    return changed;
  });

  /// What [section] holds, and when it last changed here.
  Future<_Held> _held(SyncedSettingsSection section) async {
    final SettingsData? data = await section.read();
    if (data == null) return const _Held(null, 0);
    final String hash = _hash(data);
    final Object? saved = ((await state.read())[_key] as Map?)?[section.id];
    if (saved is Map && saved['hash'] == hash && saved['modified'] is int) {
      return _Held(data, saved['modified']! as int);
    }
    // Never synced, and still as a new device has it: nothing to prefer.
    if (saved == null && section.isPristine(data)) return _Held(data, 0);
    final int now = _clock().millisecondsSinceEpoch;
    await _remember(section, data, now);
    return _Held(data, now);
  }

  Future<void> _remember(
    SyncedSettingsSection section,
    SettingsData data,
    int modified,
  ) {
    return state.update((Map<String, Object?> values) {
      final Object? existing = values[_key];
      final Map<String, Object?> all = existing is Map<String, Object?>
          ? existing
          : <String, Object?>{};
      all[section.id] = <String, Object?>{
        'hash': _hash(data),
        'modified': modified,
      };
      values[_key] = all;
    });
  }

  static String _hash(SettingsData data) =>
      sha256.convert(utf8.encode(jsonEncode(data))).toString();
}

class _Held {
  const _Held(this.data, this.modified);

  final SettingsData? data;
  final int modified;
}
