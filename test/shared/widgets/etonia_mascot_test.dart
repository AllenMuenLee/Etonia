import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/shared/widgets/etonia_mascot.dart';

String _shown(WidgetTester tester) {
  final Image image = tester.widget<Image>(find.byType(Image));
  return (image.image as AssetImage).assetName;
}

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('a lone clip loops at 12 fps', (tester) async {
    await tester.pumpWidget(
      _host(const EtoniaMascot(clip: EtoniaClip.lookAround)),
    );
    await tester.pump();
    expect(_shown(tester), EtoniaClip.lookAround.frameAsset(0));

    // 12 fps: one frame every 83.3 ms.
    await tester.pump(const Duration(milliseconds: 90));
    expect(_shown(tester), EtoniaClip.lookAround.frameAsset(1));
    await tester.pump(const Duration(milliseconds: 170));
    expect(_shown(tester), EtoniaClip.lookAround.frameAsset(3));

    // The loop is 1 s long, then it starts again.
    await tester.pump(const Duration(milliseconds: 750));
    expect(_shown(tester), EtoniaClip.lookAround.frameAsset(0));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('grading is a two second loop of 24 frames', (tester) async {
    await tester.pumpWidget(_host(const EtoniaMascot(clip: EtoniaClip.grade)));
    await tester.pump();
    expect(EtoniaClip.grade.duration, const Duration(seconds: 2));
    expect(_shown(tester), EtoniaClip.grade.frameAsset(0));
    await tester.pump(const Duration(milliseconds: 1950));
    expect(_shown(tester), EtoniaClip.grade.frameAsset(23));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_shown(tester), EtoniaClip.grade.frameAsset(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a clip with a follow-up plays once, then the follow-up loops', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EtoniaMascot(clip: EtoniaClip.popOut, then: EtoniaClip.attend),
      ),
    );
    await tester.pump();
    expect(_shown(tester), EtoniaClip.popOut.frameAsset(0));
    await tester.pump(const Duration(milliseconds: 950));
    expect(_shown(tester), EtoniaClip.popOut.frameAsset(11));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_shown(tester), EtoniaClip.attend.frameAsset(0));
    // ...and it never goes back to the spring.
    await tester.pump(const Duration(seconds: 1));
    expect(_shown(tester), EtoniaClip.attend.frameAsset(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a playlist plays each clip in turn, round and round', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EtoniaMascot.playlist(
          playlist: <EtoniaClip>[EtoniaClip.lookAround, EtoniaClip.hop],
        ),
      ),
    );
    await tester.pump();
    expect(_shown(tester), EtoniaClip.lookAround.frameAsset(0));
    await tester.pump(const Duration(milliseconds: 1010));
    expect(_shown(tester), EtoniaClip.hop.frameAsset(0));
    await tester.pump(const Duration(seconds: 1));
    expect(_shown(tester), EtoniaClip.lookAround.frameAsset(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('with a rest she plays in bursts and the screen can settle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EtoniaMascot.playlist(
          playlist: <EtoniaClip>[EtoniaClip.lookAround, EtoniaClip.hop],
          rest: Duration(seconds: 2),
        ),
      ),
    );
    // Nothing keeps asking for frames once the first clip is over, so a test
    // (or the device) is not kept awake by an idle screen.
    await tester.pumpAndSettle();
    expect(_shown(tester), EtoniaClip.hop.frameAsset(0));
    expect(tester.hasRunningAnimations, isFalse);

    // After the rest the next clip plays.
    await tester.pump(const Duration(milliseconds: 2100));
    await tester.pump(const Duration(milliseconds: 170));
    expect(_shown(tester), EtoniaClip.hop.frameAsset(2));
    await tester.pumpAndSettle();
    expect(_shown(tester), EtoniaClip.lookAround.frameAsset(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('holds a still when animations are disabled', (tester) async {
    await tester.pumpWidget(
      _host(
        const EtoniaMascot(clip: EtoniaClip.lookAround),
        reduceMotion: true,
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(_shown(tester), EtoniaClip.think.frameAsset(0));
  });

  testWidgets('a mirrored mascot is turned round', (tester) async {
    await tester.pumpWidget(
      _host(const EtoniaMascot(clip: EtoniaClip.run)),
    );
    final Transform turned = tester.widget<Transform>(
      find.descendant(
        of: find.byType(EtoniaMascot),
        matching: find.byType(Transform),
      ),
    );
    expect(turned.transform.storage[0], -1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the runner runs to the far edge, turns, and runs back', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: Stack(
              children: <Widget>[Positioned.fill(child: EtoniaRunner())],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    double left() => tester.getTopLeft(find.byType(EtoniaMascot)).dx;
    bool mirrored() =>
        tester.widget<EtoniaMascot>(find.byType(EtoniaMascot)).mirrored;

    final double start = left();
    // The frames face left, so running right she is turned round.
    expect(mirrored(), isTrue);
    await tester.pump(const Duration(seconds: 1));
    // One second is 12 whole steps along the edge.
    expect(left() - start, closeTo(EtoniaRunner.heightsPerSecond * 64, 1));
    // Long enough to have reached the right side and turned back.
    await tester.pump(const Duration(seconds: 3));
    expect(mirrored(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the runner turns back at its reach, short of the full width', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: EtoniaRunner(height: 28, reach: 100)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    double right = 0;
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      right = right < tester.getTopRight(find.byType(EtoniaMascot)).dx
          ? tester.getTopRight(find.byType(EtoniaMascot)).dx
          : right;
    }
    // Never further along than the reach, with the empty margin of the frame.
    expect(right, lessThan(100 + 28 * EtoniaClip.aspectRatio * 0.06));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the runner stays away when animations are disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: SizedBox(width: 400, height: 300, child: EtoniaRunner()),
        ),
      ),
    );
    expect(find.byType(EtoniaMascot), findsNothing);
  });

  testWidgets('the peek shows her only above the card edge', (tester) async {
    await tester.pumpWidget(_host(const EtoniaPeek(height: 100)));
    await tester.pump();
    expect(_shown(tester), EtoniaClip.popOut.frameAsset(0));
    expect(
      tester.getSize(find.byType(EtoniaPeek)).height,
      closeTo(100 * EtoniaPeek.hiddenFraction, 0.5),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('every frame of every clip is a bundled asset', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    for (final EtoniaClip clip in EtoniaClip.values) {
      expect(
        pubspec,
        contains('assets/animations/etonia_loops/ui/${clip.name}/'),
        reason: '${clip.name} is listed in pubspec.yaml',
      );
      for (int i = 0; i < clip.frames; i++) {
        final String path = clip.frameAsset(i);
        expect(
          path,
          matches(
            RegExp(r'^assets/animations/etonia_loops/ui/\w+/\w+_\d\d\.png$'),
          ),
        );
        expect(File(path).existsSync(), isTrue, reason: '$path exists');
      }
      expect(
        File(clip.frameAsset(clip.frames)).existsSync(),
        isFalse,
        reason: '${clip.name} has exactly ${clip.frames} frames',
      );
    }
  });
}
