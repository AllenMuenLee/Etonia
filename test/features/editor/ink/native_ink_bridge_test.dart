import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/native_ink_bridge.dart';

void main() {
  test('decodes a full native coalesced sample batch', () {
    final NativeInkPacket packet = NativeInkPacket.fromMap(<Object?, Object?>{
      'surfaceId': 7,
      'pointer': 12,
      'phase': 'move',
      'kind': 'stylus',
      'samples': <Object?>[10.5, 20.25, 1000000, 0.2, 11, 22, 1001000, 0.8],
    });

    expect(packet.surfaceId, 7);
    expect(packet.pointer, 12);
    expect(packet.phase, NativeInkPhase.move);
    expect(packet.kind, NativeInkKind.stylus);
    expect(packet.samples, hasLength(2));
    expect(packet.samples.first.position.dx, 10.5);
    expect(packet.samples.first.position.dy, 20.25);
    expect(packet.samples.first.timestamp, const Duration(seconds: 1));
    expect(packet.samples.first.pressure, 0.2);
    expect(
      packet.samples.last.timestamp,
      const Duration(microseconds: 1001000),
    );
    expect(packet.samples.last.pressure, 0.8);
  });

  test('preserves missing pressure and inverted stylus kind', () {
    final NativeInkPacket packet = NativeInkPacket.fromMap(<Object?, Object?>{
      'surfaceId': 1,
      'pointer': 2,
      'phase': 'down',
      'kind': 'invertedStylus',
      'samples': <Object?>[1, 2, 3, null],
    });

    expect(packet.kind, NativeInkKind.invertedStylus);
    expect(packet.samples.single.pressure, isNull);
  });
}
