import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/smoothing_config.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

/// The native wet ink on Android and iOS runs a port of Flutter's pen model,
/// so the preview is the very stroke Flutter commits. This fixture holds
/// Flutter's answer for strokes across the pen's advanced settings; the
/// Kotlin port is checked against it by NativeInkModelTest.
///
/// After changing the pen model, port the change to NativeInkModel.kt and
/// NativeInkChannel.swift, then regenerate:
///
///     UPDATE_NATIVE_INK_FIXTURE=1 flutter test test/features/editor/ink/native_ink_parity_test.dart
const String _fixturePath = 'test/fixtures/native_ink_parity.txt';

class _Case {
  const _Case(
    this.name, {
    required this.pen,
    required this.samples,
  });

  final String name;
  final PenSettings pen;
  final List<RawInkSample> samples;
}

/// A wavy line written at [hz], its speed and pressure changing along it.
List<RawInkSample> _wave({
  required int count,
  double hz = 240,
  double speed = 1,
  bool millisecondTimes = false,
  bool jitterTimes = false,
}) {
  final List<RawInkSample> samples = <RawInkSample>[];
  double t = 0;
  for (int i = 0; i < count; i++) {
    final double s = i / count;
    // Slow at the ends, fast in the middle, as a hand writes.
    final double pace = 0.4 + 1.6 * math.sin(math.pi * s);
    t += 1 / hz * (jitterTimes && i % 7 == 3 ? 0 : 1);
    final double x = 20 + 300 * s * speed;
    final double y = 80 + 40 * math.sin(s * 9) + 6 * math.sin(s * 47) * pace;
    int micros = (t * 1e6).round();
    if (millisecondTimes) {
      micros = (micros ~/ 1000) * 1000;
    }
    samples.add(
      RawInkSample(
        position: InkVector(x, y),
        timestamp: Duration(microseconds: micros),
        pressure: (0.5 + 0.45 * math.sin(s * 5 + 0.3)).clamp(0.0, 1.0),
      ),
    );
  }
  return samples;
}

/// A sharp zigzag, for the corners.
List<RawInkSample> _zigzag() {
  final List<RawInkSample> samples = <RawInkSample>[];
  for (int i = 0; i < 90; i++) {
    final int leg = i ~/ 15;
    final double along = (i % 15) / 15;
    final double x = 50 + leg * 30 + along * 30;
    final double y = leg.isEven ? 50 + along * 60 : 110 - along * 60;
    samples.add(
      RawInkSample(
        position: InkVector(x, y),
        timestamp: Duration(microseconds: (i * 8333.3).round()),
        pressure: i.isEven ? 0.2 : 0.9,
      ),
    );
  }
  return samples;
}

List<_Case> _cases() {
  final PenSettings base = PenSettings.defaults();
  return <_Case>[
    _Case('default-pen', pen: base, samples: _wave(count: 160)),
    _Case(
      'unstabilized',
      pen: base.copyWith(stabilization: 0),
      samples: _wave(count: 120),
    ),
    _Case(
      'full-everything',
      pen: base.copyWith(
        stabilization: 1,
        tipSharpness: 1,
        pressureSensitivity: 1,
        width: 12,
      ),
      samples: _wave(count: 200, speed: 0.6),
    ),
    _Case(
      'mid-settings-zigzag',
      pen: base.copyWith(
        stabilization: 0.5,
        tipSharpness: 0.4,
        pressureSensitivity: 0.6,
        width: 8,
      ),
      samples: _zigzag(),
    ),
    _Case(
      'android-millisecond-history',
      pen: base.copyWith(
        stabilization: 0.75,
        tipSharpness: 0.7,
        pressureSensitivity: 0.3,
        width: 5,
      ),
      samples: _wave(count: 140, millisecondTimes: true, jitterTimes: true),
    ),
    _Case(
      'pressure-only-fast',
      pen: base.copyWith(pressureSensitivity: 0.8, width: 6),
      samples: _wave(count: 40, hz: 120, speed: 2),
    ),
    _Case(
      'short-tapered',
      pen: base.copyWith(tipSharpness: 1, width: 10),
      samples: <RawInkSample>[
        for (int i = 0; i < 6; i++)
          RawInkSample(
            position: InkVector(10 + i * 0.6, 10 + i * 0.2),
            timestamp: Duration(microseconds: i * 4167),
            pressure: 0.5,
          ),
      ],
    ),
    _Case(
      'dot',
      pen: base.copyWith(tipSharpness: 0.5, pressureSensitivity: 1),
      samples: <RawInkSample>[
        for (int i = 0; i < 4; i++)
          RawInkSample(
            position: const InkVector(40, 40),
            timestamp: Duration(microseconds: i * 4167),
            pressure: 0.9,
          ),
      ],
    ),
    _Case(
      'highlighter',
      pen: base.copyWith(
        style: WritingStyle.highlighter,
        tipSharpness: 1,
        pressureSensitivity: 1,
      ),
      samples: _wave(count: 80),
    ),
  ];
}

String _n(double value) => value.toString();

String _fixture() {
  final SmoothingConfig controllerSmoothing = InkController().smoothing;
  final StringBuffer out = StringBuffer()
    ..writeln('# Generated by test/features/editor/ink/native_ink_parity_test.dart')
    ..writeln('# Flutter pen-model output that the native wet ink must match.');
  for (final _Case c in _cases()) {
    final SmoothingConfig config = c.pen.smoothing(controllerSmoothing);
    final StrokeStyle style = c.pen.strokeStyle();
    final StrokeDynamics dynamics = c.pen.dynamics;
    final ActiveStroke active = ActiveStroke(
      style: StrokeStyle(ink: InkPalette.ink, width: style.width),
      first: c.samples.first,
      config: config,
      dynamics: dynamics,
    );
    for (final RawInkSample sample in c.samples.skip(1)) {
      active.add(sample);
    }
    final List<InkVector> livePoints = List<InkVector>.of(active.points);
    final List<double> liveWidths =
        active.widths?.toList() ??
        List<double>.filled(livePoints.length, 1);
    final ({List<InkVector> points, List<double> widths}) live =
        flattenInkSamples(livePoints, liveWidths);
    final Stroke stroke = active.finish();
    final List<double> widths =
        stroke.widths ?? List<double>.filled(stroke.points.length, 1);
    final ({List<InkVector> points, List<double> widths}) committed =
        stroke.isDot
        ? (points: <InkVector>[stroke.points.first], widths: <double>[1])
        : flattenInkSamples(stroke.points, widths);

    out
      ..writeln('case ${c.name}')
      ..writeln(
        'smoothing ${<num>[config.minCutoff, config.beta, config.derivativeCutoff, config.minDtSeconds, config.maxDtSeconds, config.maxFinalizationPoints, config.finalizationSpacing, config.endpointTolerance, config.slowSpeed, config.fastSpeed, config.slowCutoffScale].map((num v) => v is int ? '$v' : _n(v.toDouble())).join(' ')}',
      )
      ..writeln(
        'pen ${_n(style.width)} ${_n(dynamics.taper)} ${_n(dynamics.pressure)}',
      )
      ..writeln('samples ${c.samples.length}');
    for (final RawInkSample s in c.samples) {
      out.writeln(
        '${_n(s.position.x)} ${_n(s.position.y)} '
        '${s.timestamp.inMicroseconds} ${_n(s.pressure!)}',
      );
    }
    out.writeln('live ${live.points.length}');
    for (int i = 0; i < live.points.length; i++) {
      out.writeln(
        '${_n(live.points[i].x)} ${_n(live.points[i].y)} ${_n(live.widths[i])}',
      );
    }
    out.writeln('final ${committed.points.length}');
    for (int i = 0; i < committed.points.length; i++) {
      out.writeln(
        '${_n(committed.points[i].x)} ${_n(committed.points[i].y)} '
        '${_n(committed.widths[i])}',
      );
    }
    out.writeln('dot ${stroke.isDot ? 1 : 0}');
  }
  return out.toString();
}

void main() {
  test('the native wet-ink parity fixture is Flutter\'s current pen model', () {
    final String expected = _fixture();
    final File file = File(_fixturePath);
    if (Platform.environment['UPDATE_NATIVE_INK_FIXTURE'] == '1') {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(expected);
    }
    expect(
      file.existsSync(),
      isTrue,
      reason: 'Generate it with UPDATE_NATIVE_INK_FIXTURE=1.',
    );
    expect(
      file.readAsStringSync().replaceAll('\r\n', '\n'),
      expected,
      reason:
          'The pen model changed. Port the change to the native wet ink '
          '(NativeInkModel.kt, NativeInkChannel.swift), then regenerate the '
          'fixture with UPDATE_NATIVE_INK_FIXTURE=1.',
    );
  });

  test('every case exercises what it is named for', () {
    final List<_Case> cases = _cases();
    expect(cases.where((c) => c.pen.dynamics.isNone), hasLength(3));
    expect(
      cases.map((c) => c.pen.stabilization).toSet(),
      containsAll(<double>[0, 0.25, 0.5, 0.75, 1]),
    );
  });
}
