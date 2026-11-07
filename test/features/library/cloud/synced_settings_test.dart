import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/cloud/library_synced_settings.dart';
import 'package:greatnote/features/library/cloud/synced_settings.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';

import '../../../helpers/ai_fakes.dart';
import '../../../helpers/google_drive_fakes.dart';

/// A section that keeps one value, newest choice winning.
class _ValueSection extends SyncedSettingsSection {
  _ValueSection(this.value);

  String? value;

  @override
  String get id => 'value';

  @override
  Future<SettingsData?> read() async =>
      value == null ? null : <String, Object?>{'value': value};

  @override
  Future<void> write(SettingsData data) async =>
      value = data['value'] as String?;

  @override
  bool isPristine(SettingsData data) => data['value'] == 'default';
}

SyncedSettings _settings(
  _ValueSection section,
  DateTime Function() clock, {
  CloudStateStore? state,
}) => SyncedSettings(
  sections: <SyncedSettingsSection>[section],
  state: state,
  clock: clock,
);

StudySession _session(String id, int updated, {String text = 'hi'}) {
  return StudySession(
    id: id,
    created: DateTime.fromMillisecondsSinceEpoch(1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updated),
    messages: <StudyMessage>[StudyMessage.user(text)],
  );
}

void main() {
  group('SyncedSettings', () {
    test('a device that was set up wins over one that was not', () async {
      DateTime now = DateTime(2026, 11, 1);
      final _ValueSection setUp = _ValueSection('Cursive');
      final _ValueSection fresh = _ValueSection('default');
      final SyncedSettings a = _settings(setUp, () => now);
      final SyncedSettings b = _settings(fresh, () => now);

      now = now.add(const Duration(hours: 1));
      expect(await b.import((await a.export())!), 1);
      expect(fresh.value, 'Cursive');

      // The other way round: the default does not take Cursive away.
      final _ValueSection another = _ValueSection('default');
      final SyncedSettings c = _settings(another, () => now);
      expect(await a.import((await c.export())!), 0);
      expect(setUp.value, 'Cursive');
    });

    test(
      'the newest choice wins, and what came in is not sent back as new',
      () async {
        DateTime now = DateTime(2026, 11, 1);
        final _ValueSection one = _ValueSection('Print');
        final _ValueSection two = _ValueSection('Print');
        final SyncedSettings a = _settings(one, () => now);
        final SyncedSettings b = _settings(two, () => now);
        await b.import((await a.export())!);

        now = now.add(const Duration(minutes: 5));
        two.value = 'Rounded';
        final bytes = (await b.export())!;
        expect(await a.import(bytes), 1);
        expect(one.value, 'Rounded');

        // An older choice from the other device does not win back.
        now = now.add(const Duration(minutes: 5));
        expect(await b.import((await a.export())!), 0);
        expect(two.value, 'Rounded');
        // And what a sends is what b sent: the same file, not a newer one.
        expect(utf8.decode((await a.export())!), utf8.decode(bytes));
      },
    );

    test('a newer file than this version knows is left alone', () async {
      final _ValueSection section = _ValueSection('Print');
      final SyncedSettings sync = _settings(section, DateTime.now);
      final bytes = utf8.encode(
        jsonEncode(<String, Object?>{
          'schema': SyncedSettings.schema + 1,
          'sections': <String, Object?>{
            'value': <String, Object?>{
              'modified': 1 << 50,
              'data': <String, Object?>{'value': 'Quick'},
            },
          },
        }),
      );
      expect(await sync.import(bytes), 0);
      expect(section.value, 'Print');
    });

    test('nothing is sent while there is nothing to say', () async {
      final SyncedSettings sync = _settings(_ValueSection(null), DateTime.now);
      expect(await sync.export(), isNull);
    });
  });

  group('StudyChatsSection', () {
    final StudyChatsSection section = StudyChatsSection(
      () => throw StateError('no desk'),
      clock: () => DateTime.fromMillisecondsSinceEpoch(10000),
    );

    SettingsData data(
      List<StudySession> sessions, {
      Map<String, int> deleted = const <String, int>{},
    }) => <String, Object?>{
      'sessions': <Object?>[for (final StudySession s in sessions) s.toJson()],
      'courses': <Object?>[],
      'deleted': deleted,
    };

    Map<String, StudySession> sessionsOf(SettingsData? merged) =>
        <String, StudySession>{
          for (final Object? raw in merged!['sessions']! as List)
            (raw! as Map<String, Object?>)['id']! as String:
                StudySession.fromJson(raw as Map<String, Object?>),
        };

    test('chats from both devices are kept, the later version of one wins', () {
      final SettingsData? merged = section.merge(
        local: data(<StudySession>[
          _session('a', 100),
          _session('both', 100, text: 'old'),
        ]),
        localModified: 0,
        remote: data(<StudySession>[
          _session('b', 100),
          _session('both', 200, text: 'new'),
        ]),
        remoteModified: 0,
      );
      final Map<String, StudySession> sessions = sessionsOf(merged);
      expect(sessions.keys, <String>['a', 'b', 'both']);
      expect(sessions['both']!.messages.single.text, 'new');
    });

    test('a chat deleted elsewhere is deleted here, not brought back', () {
      final SettingsData? merged = section.merge(
        local: data(<StudySession>[
          _session('gone', 100),
          _session('kept', 100),
        ]),
        localModified: 0,
        remote: data(
          <StudySession>[_session('kept', 100)],
          deleted: <String, int>{'gone': 500},
        ),
        remoteModified: 0,
      );
      expect(sessionsOf(merged).keys, <String>['kept']);
      expect((merged!['deleted']! as Map).keys, <String>['gone']);

      // The device that deleted it hears of it from one that never did.
      final SettingsData? again = section.merge(
        local: merged,
        localModified: 0,
        remote: data(<StudySession>[_session('gone', 100)]),
        remoteModified: 0,
      );
      expect(sessionsOf(again).keys, <String>['kept']);
    });

    test('a chat written after it was deleted is back', () {
      final SettingsData? merged = section.merge(
        local: data(<StudySession>[], deleted: <String, int>{'back': 500}),
        localModified: 0,
        remote: data(<StudySession>[_session('back', 900)]),
        remoteModified: 0,
      );
      expect(sessionsOf(merged).keys, <String>['back']);
      expect((merged!['deleted']! as Map), isEmpty);
    });

    test('the same chats are the same data whichever device merges', () {
      final SettingsData one = data(<StudySession>[_session('a', 1)]);
      final SettingsData two = data(<StudySession>[_session('b', 2)]);
      expect(
        jsonEncode(
          section.merge(
            local: one,
            localModified: 0,
            remote: two,
            remoteModified: 0,
          ),
        ),
        jsonEncode(
          section.merge(
            local: two,
            localModified: 0,
            remote: one,
            remoteModified: 0,
          ),
        ),
      );
    });
  });

  group('the desk', () {
    test('takes in chats from elsewhere and tells of deleting one', () async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      int saved = 0;
      final StudyDeskController desk = StudyDeskController(
        repository: repository,
        client: FakeAiClient(),
        store: InMemoryStudyDeskStore(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(5000),
        onSaved: () => saved++,
      );
      addTearDown(desk.dispose);
      final StudyChatsSection section = StudyChatsSection(() => desk);

      expect(await section.read(), isNotNull);
      await section.write(<String, Object?>{
        'sessions': <Object?>[_session('from-phone', 100).toJson()],
        'courses': <Object?>[],
        'deleted': <String, int>{},
      });
      expect(saved, greaterThan(0));
      final chats = (await desk.syncedChats())!;
      expect(chats.sessions.map((StudySession s) => s.id), <String>[
        'from-phone',
      ]);

      desk.deleteSession('from-phone');
      final after = (await desk.syncedChats())!;
      expect(after.sessions, isEmpty);
      expect(after.deleted.keys, <String>['from-phone']);
    });
  });

  group('through a backup', () {
    test('settings travel with the library to another device', () async {
      final FakeGoogleDriveClient drive = FakeGoogleDriveClient(signedIn: true);
      final InMemoryNoteRepository repositoryA = InMemoryNoteRepository();
      final InMemoryNoteRepository repositoryB = InMemoryNoteRepository();
      addTearDown(repositoryA.dispose);
      addTearDown(repositoryB.dispose);
      DateTime now = DateTime(2026, 11, 1, 9);
      final _ValueSection mine = _ValueSection('Cursive');
      final _ValueSection theirs = _ValueSection('default');

      final GoogleDriveBackupService a = GoogleDriveBackupService(
        client: drive,
        repository: repositoryA,
        settings: _settings(mine, () => now),
        clock: () => now,
      );
      final GoogleDriveBackupService b = GoogleDriveBackupService(
        client: drive,
        repository: repositoryB,
        settings: _settings(theirs, () => now),
        clock: () => now,
      );

      await a.backUp();
      final Map<String, Object?> manifest =
          jsonDecode(
                utf8.decode(
                  drive.bytesOf(drive.itemAt('Etonia/manifest.json')!.id),
                ),
              )
              as Map<String, Object?>;
      expect(manifest['settings'], isA<Map<String, Object?>>());

      now = now.add(const Duration(hours: 1));
      final SyncSummary? summary = await b.pullIfChangedElsewhere();
      expect(summary?.settingsUpdated, 1);
      expect(theirs.value, 'Cursive');

      // A change on the second device comes back to the first.
      now = now.add(const Duration(hours: 1));
      theirs.value = 'Quick';
      await b.backUp();
      now = now.add(const Duration(hours: 1));
      await a.pullIfChangedElsewhere();
      expect(mine.value, 'Quick');
    });

    test('a restore brings the settings too', () async {
      final FakeGoogleDriveClient drive = FakeGoogleDriveClient(signedIn: true);
      final InMemoryNoteRepository repositoryA = InMemoryNoteRepository();
      final InMemoryNoteRepository repositoryB = InMemoryNoteRepository();
      addTearDown(repositoryA.dispose);
      addTearDown(repositoryB.dispose);
      DateTime now = DateTime(2026, 11, 1, 9);
      await GoogleDriveBackupService(
        client: drive,
        repository: repositoryA,
        settings: _settings(_ValueSection('Print'), () => now),
        clock: () => now,
      ).backUp();

      final _ValueSection restored = _ValueSection('default');
      now = now.add(const Duration(hours: 1));
      await GoogleDriveBackupService(
        client: drive,
        repository: repositoryB,
        settings: _settings(restored, () => now),
        clock: () => now,
      ).restore();
      expect(restored.value, 'Print');
    });

    test('a backup with no settings is still read', () async {
      final FakeGoogleDriveClient drive = FakeGoogleDriveClient(signedIn: true);
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      await GoogleDriveBackupService(
        client: drive,
        repository: repository,
      ).backUp();
      final _ValueSection section = _ValueSection('Print');
      await GoogleDriveBackupService(
        client: drive,
        repository: repository,
        settings: _settings(section, DateTime.now),
      ).backUp();
      expect(section.value, 'Print');
    });
  });
}
