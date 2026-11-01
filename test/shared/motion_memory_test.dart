import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/memory/memory_pressure.dart';
import 'package:greatnote/shared/motion/motion_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final MotionMemory memory = MotionMemory.instance;
  setUp(memory.reset);

  test('the first showing is slow, every later one quick', () {
    expect(memory.recall(('folder', 'a')), MotionPace.first);
    expect(memory.recall(('folder', 'a')), MotionPace.revisit);
    expect(memory.recall(('folder', 'a')), MotionPace.revisit);
    expect(memory.recall(('folder', 'b')), MotionPace.first);
  });

  test('peeking does not count as showing', () {
    expect(memory.peek('menu'), MotionPace.first);
    expect(memory.peek('menu'), MotionPace.first);
    memory.remember('menu');
    expect(memory.peek('menu'), MotionPace.revisit);
  });

  test('a forgotten key is a first showing again', () {
    memory.recall('page');
    memory.forget('page');
    expect(memory.recall('page'), MotionPace.first);
  });

  test('nothing is let go until memory runs low', () {
    for (int i = 0; i < 10000; i++) {
      memory.recall(('note', i));
    }
    expect(memory.hasSeen(('note', 0)), isTrue);
    MemoryPressure.instance.didHaveMemoryPressure();
    expect(memory.hasSeen(('note', 0)), isFalse);
    expect(memory.recall(('note', 9999)), MotionPace.first);
  });

  test('a first look is slower; a revisit is a slight fade, not a rush', () {
    const Duration token = Duration(milliseconds: 300);
    expect(AppMotion.paced(token, MotionPace.first), greaterThan(token));
    expect(AppMotion.paced(token, MotionPace.standard), token);
    // Whatever the token, a revisit is the same gentle fade, never shorter.
    expect(AppMotion.paced(token, MotionPace.revisit), AppMotion.glance);
    expect(
      AppMotion.paced(AppMotion.fadeIn, MotionPace.revisit),
      greaterThanOrEqualTo(AppMotion.fadeIn),
    );
    expect(AppMotion.travels(MotionPace.revisit), isFalse);
    expect(AppMotion.travels(MotionPace.first), isTrue);

    final SpringDescription spring = AppMotion.pacedSpring(
      AppMotion.bouncy,
      MotionPace.first,
    );
    expect(spring.duration, greaterThan(AppMotion.bouncy.duration));
    expect(spring.bounce, closeTo(AppMotion.bouncy.bounce, 1e-9));
    // Sheets and menus cannot fade instead of moving: not rushed either.
    expect(AppMotion.pacedSheetStyle(MotionPace.revisit), AppMotion.sheetStyle);
    expect(AppMotion.pacedPopupStyle(MotionPace.revisit), AppMotion.popupStyle);
  });
}
