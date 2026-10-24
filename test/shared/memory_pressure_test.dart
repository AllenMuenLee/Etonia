import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/shared/memory/memory_pressure.dart';

void main() {
  testWidgets('low memory reaches each listener until it stops listening', (
    WidgetTester tester,
  ) async {
    final List<String> calls = <String>[];
    void first() => calls.add('first');
    void second() {
      calls.add('second');
      // A listener may stop listening as it lets go.
      MemoryPressure.instance.removeListener(second);
    }

    MemoryPressure.instance
      ..addListener(first)
      ..addListener(second);
    tester.binding.handleMemoryPressure();
    expect(calls, <String>['first', 'second']);

    tester.binding.handleMemoryPressure();
    expect(calls, <String>['first', 'second', 'first']);

    MemoryPressure.instance.removeListener(first);
    tester.binding.handleMemoryPressure();
    expect(calls, hasLength(3));
  });
}
