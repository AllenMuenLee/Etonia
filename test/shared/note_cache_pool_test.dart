import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/shared/memory/note_cache_pool.dart';

void main() {
  test('default cache budget stays within the conservative mobile range', () {
    const CacheBudget budget = CacheBudget();
    expect(budget.totalBytes, inInclusiveRange(64 << 20, 128 << 20));
    expect(budget.notesBytes, lessThanOrEqualTo(128 << 20));
  });

  /// Keeps 100 bytes for [page] of [scope], logging `<name>` when it goes.
  NoteCacheItem keep(
    NoteCacheScope scope,
    Object page,
    List<String> popped,
    String name, {
    bool Function()? inUse,
  }) {
    scope.touch(page);
    return scope.add(
      page: page,
      bytes: 100,
      onPop: () => popped.add(name),
      inUse: inUse,
    );
  }

  test('the budget gives a tenth to the home page, the rest to notes', () {
    const CacheBudget budget = CacheBudget(totalBytes: 1000);
    expect(budget.homeBytes, 100);
    expect(budget.notesBytes, 900);
  });

  test('the page of the note used longest ago goes, not the oldest page', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 300);
    final NoteCacheScope note1 = pool.scope();
    final NoteCacheScope note2 = pool.scope();
    final List<String> popped = <String>[];

    keep(note1, 4, popped, 'note1 p4');
    keep(note2, 5, popped, 'note2 p5');
    keep(note1, 5, popped, 'note1 p5');
    expect(popped, isEmpty);

    keep(note1, 6, popped, 'note1 p6');
    expect(popped, <String>['note2 p5']);
    expect(pool.usedBytes, 300);

    // With note 2 empty, note 1 gives up its own oldest page.
    keep(note1, 7, popped, 'note1 p7');
    expect(popped, <String>['note2 p5', 'note1 p4']);
  });

  test('coming back to a note makes the other one go first', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 200);
    final NoteCacheScope note1 = pool.scope();
    final NoteCacheScope note2 = pool.scope();
    final List<String> popped = <String>[];

    keep(note1, 0, popped, 'note1 p0');
    keep(note2, 0, popped, 'note2 p0');
    note1.touch(0);
    keep(note1, 1, popped, 'note1 p1');
    expect(popped, <String>['note2 p0']);
  });

  test('a page goes with everything kept for it', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 300);
    final NoteCacheScope note = pool.scope();
    final List<String> popped = <String>[];

    keep(note, 0, popped, 'pdf');
    keep(note, 0, popped, 'picture');
    keep(note, 1, popped, 'other');
    keep(note, 2, popped, 'last');
    expect(popped, <String>['pdf', 'picture']);
    expect(pool.usedBytes, 200);
  });

  test(
    'pages on screen stay, even over the limit, and go once out of sight',
    () {
      final NoteCachePool pool = NoteCachePool(maxBytes: 100);
      final NoteCacheScope note = pool.scope();
      final List<String> popped = <String>[];
      int told = 0;

      final NoteCachePageHold hold = note.hold(0, () => told++)..shown = true;
      keep(note, 0, popped, 'shown');
      final NoteCachePageHold other = note.hold(1, () {})..shown = true;
      keep(note, 1, popped, 'also shown');
      expect(popped, isEmpty);
      expect(pool.usedBytes, 200);

      hold.shown = false;
      expect(popped, <String>['shown']);
      expect(told, 1);
      expect(pool.usedBytes, 100);
      other.release();
    },
  );

  test('what is in use stays until it is not', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 100);
    final NoteCacheScope note = pool.scope();
    final List<String> popped = <String>[];
    bool busy = true;

    keep(note, 0, popped, 'busy', inUse: () => busy);
    keep(note, 1, popped, 'newest');
    expect(popped, <String>['newest']);

    busy = false;
    keep(note, 2, popped, 'next');
    expect(popped, <String>['newest', 'busy']);
  });

  test('what a note shares goes after its pages, its document last', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 250);
    final NoteCacheScope note1 = pool.scope();
    final NoteCacheScope note2 = pool.scope();
    final List<String> popped = <String>[];

    note1.setDocument(
      bytes: 100,
      canPutAway: () => true,
      putAway: () => popped.add('document'),
    );
    note1.add(bytes: 50, onPop: () => popped.add('pdf bytes'));
    keep(note1, 0, popped, 'page');
    note2.touch(0);

    note2.add(page: 0, bytes: 100, onPop: () => popped.add('note 2'));
    expect(popped, <String>['page']);
    note2.add(page: 0, bytes: 40, onPop: () => popped.add('note 2'));
    expect(popped, <String>['page', 'pdf bytes']);
    note2.add(page: 0, bytes: 100, onPop: () => popped.add('note 2'));
    expect(popped, <String>['page', 'pdf bytes', 'document']);
    expect(pool.usedBytes, 240);
  });

  test('a document that cannot be put away stays', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 50);
    final NoteCacheScope note = pool.scope();
    int putAway = 0;
    note.setDocument(
      bytes: 100,
      canPutAway: () => false,
      putAway: () => putAway++,
    );
    expect(putAway, 0);
    expect(pool.usedBytes, 100);
  });

  test('a closed note gives everything back and hears nothing more', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 1000);
    final NoteCacheScope note = pool.scope();
    final List<String> popped = <String>[];
    final NoteCacheItem item = keep(note, 0, popped, 'page');
    note.add(bytes: 50, onPop: () => popped.add('bytes'));
    note.setDocument(bytes: 10, canPutAway: () => true, putAway: () {});

    note.close();
    expect(pool.usedBytes, 0);
    expect(popped, isEmpty);

    item.resize(500);
    item.remove();
    expect(pool.usedBytes, 0);
    note.add(page: 1, bytes: 10, onPop: () => popped.add('late'));
    expect(pool.usedBytes, 0);
  });

  test('low memory lets go of idle pages, not what is shown or documents', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 10000);
    final NoteCacheScope note = pool.scope();
    final List<String> popped = <String>[];
    note.setDocument(
      bytes: 10,
      canPutAway: () => true,
      putAway: () => popped.add('document'),
    );
    final NoteCachePageHold hold = note.hold(0, () {})..shown = true;
    keep(note, 0, popped, 'shown');
    keep(note, 1, popped, 'idle');
    note.add(bytes: 5, onPop: () => popped.add('shared'));

    pool.releaseIdle();
    expect(popped, <String>['idle']);
    expect(pool.usedBytes, 115);
    hold.release();
  });

  test('a picture moved to another page goes with that page', () {
    final NoteCachePool pool = NoteCachePool(maxBytes: 200);
    final NoteCacheScope note = pool.scope();
    final List<String> popped = <String>[];
    final NoteCacheItem picture = keep(note, 0, popped, 'picture');
    note.touch(1);
    picture.moveTo(1);
    keep(note, 2, popped, 'page 2');
    keep(note, 3, popped, 'page 3');
    expect(popped, <String>['picture']);
  });
}
