import 'dart:ui';
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

  test('serializes exclusionRects in NativeInkSurface.toMap', () {
    const NativeInkSurface surface = NativeInkSurface(
      id: 3,
      size: Size(100, 200),
      origin: Offset(10, 20),
      xBasis: Offset(1, 0),
      yBasis: Offset(0, 1),
      enabled: true,
      previewEnabled: true,
      color: Color(0xFF000000),
      width: 2.0,
      pressureSensitivity: 0.5,
      stabilization: 0.35,
      writingStyle: 'pen',
      exclusionRects: <Rect>[
        Rect.fromLTWH(0, 0, 50, 40),
        Rect.fromLTWH(10, 15, 30, 25),
      ],
    );

    final Map<String, Object> map = surface.toMap();
    expect(map['surfaceId'], 3);
    expect(map['enabled'], true);
    expect(map['previewEnabled'], true);
    expect(map['stabilization'], 0.35);
    expect(map['writingStyle'], 'pen');
    expect(map['exclusionRects'], <double>[0, 0, 50, 40, 10, 15, 40, 40]);
  });
}
