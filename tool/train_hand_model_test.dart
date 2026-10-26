// Learns the bundled HandModel from UJI Pen Characters v2 and measures it
// on writers it never saw.
//
// Download the dataset (see uji_handwriting_model_test.dart), then:
//
//   $env:UJI_PEN_CHARACTERS='.../ujipenchars2.txt'
//   flutter test tool/train_hand_model_test.dart
//
// prints, for each setting, how many letters built for held-out writers
// match their own (as uji_handwriting_model_test.dart counts them), with
// six folds of ten writers each learned from the other fifty. With
// HAND_MODEL_WRITE=1 it then learns from all sixty writers and writes
// lib/features/editor/handwriting/hand_model_data.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/handwriting/glyph_builder.dart';
import 'package:greatnote/features/editor/handwriting/hand_glyphs.dart';
import 'package:greatnote/features/editor/handwriting/hand_model.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration.dart';

import 'hand_model_trainer.dart';
import 'uji_data.dart';

/// The letters built rather than written, compared with each writer's own,
/// as the UJI benchmark compares them.
const String _heldOut = 'bcfjklmnpquvxyz0D';

const int _folds = 6;

void main() {
  test(
    'a model of other writers builds held-out writers\' letters',
    () {
      final String? path = Platform.environment['UJI_PEN_CHARACTERS'];
      if (path == null || !File(path).existsSync()) {
        fail('Set UJI_PEN_CHARACTERS to the extracted ujipenchars2.txt file.');
      }
      final Map<String, Map<int, Map<String, UjiStrokes>>> uji = readUji(
        File(path),
      );
      final List<String> names = uji.keys.toList()..sort();

      HandModel.debugDisabled = true;
      final Map<String, List<Hand>> hands = <String, List<Hand>>{
        for (final String name in names)
          name: <Hand>[
            for (final Map<String, UjiStrokes> samples in uji[name]!.values)
              if (handOf(samples) case final Hand hand) hand,
          ],
      };
      HandModel.debugDisabled = false;

      final List<int> dimensions = _ints('HAND_MODEL_DIMENSIONS', <int>[8]);
      // Fixed fallbacks for every letter, to compare with those chosen per
      // letter.
      final List<double> fallbacks = _doubles(
        'HAND_MODEL_FALLBACKS',
        <double>[],
      );

      /// [some] of the writers' hands, and which writer each is.
      (List<Hand>, List<int>) handsOf(Iterable<String> some) {
        final List<Hand> out = <Hand>[];
        final List<int> writers = <int>[];
        for (final String name in some) {
          for (final Hand hand in hands[name]!) {
            out.add(hand);
            writers.add(names.indexOf(name));
          }
        }
        return (out, writers);
      }

      HandModel.debugDisabled = true;
      final _Score alone = _score(uji, names);
      HandModel.debugDisabled = false;
      // ignore: avoid_print
      print('builder alone: $alone');

      for (final int q in dimensions) {
        final Map<String, HandModel> byWriter = <String, HandModel>{};
        for (int fold = 0; fold < _folds; fold++) {
          final Set<String> test = <String>{
            for (int i = fold; i < names.length; i += _folds) names[i],
          };
          final (List<Hand> train, List<int> writers) = handsOf(
            names.where((String name) => !test.contains(name)),
          );
          final HandModel model = trainHandModel(
            train,
            writers: writers,
            dimensions: q,
          );
          for (final String name in test) {
            byWriter[name] = model;
          }
        }
        // How far held-out writers' key letters lie from the hand found for
        // them, against the model's noise: where HandModel.misfitLimit
        // should sit.
        final List<double> misfits = <double>[
          for (final String name in names)
            if (hands[name]!.isNotEmpty)
              if (byWriter[name]!.estimate(<String, UjiStrokes>{
                    for (final String c in keyLetters.split(''))
                      if (hands[name]!.first[c] case final UjiStrokes s) c: s,
                  })
                  case final HandEstimate e)
                e.misfit / byWriter[name]!.noise,
        ]..sort();
        // ignore: avoid_print
        print(
          'q=$q held-out misfit / noise: '
          '${<double>[0, 0.5, 0.9, 0.95, 1].map((double p) => misfits[((misfits.length - 1) * p).round()].toStringAsFixed(2)).join(' / ')} '
          '(min / median / 90% / 95% / max)',
        );
        for (final double? fallback in <double?>[null, ...fallbacks]) {
          HandModel.debugFallback = fallback;
          final _Score score = _score(
            uji,
            names,
            modelFor: (String name) => byWriter[name],
          );
          // ignore: avoid_print
          print('q=$q fallback=${fallback ?? 'per letter'}: $score');
        }
        HandModel.debugFallback = null;
        // ignore: avoid_print
        print(
          'q=$q fallbacks chosen per fold: ${<String>[for (final HandModel m in byWriter.values.toSet()) m.fallbacks.entries.map((MapEntry<String, double> e) => '${e.key}${e.value == 0
                ? 'P'
                : e.value > 1
                ? 'B'
                : 'M'}').join()].join(' / ')}',
        );
      }
      HandModel.debugOverride = null;

      if (Platform.environment['HAND_MODEL_WRITE'] == '1') {
        final int q = dimensions.first;
        final (List<Hand> all, List<int> writers) = handsOf(names);
        final HandModel model = trainHandModel(
          all,
          writers: writers,
          dimensions: q,
        );
        File(
          'lib/features/editor/handwriting/hand_model_data.dart',
        ).writeAsStringSync(_dataFile(model.encode()));
        // ignore: avoid_print
        print('wrote the bundled model: q=$q, ${model.slots.length} slots');
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// How the letters built for each writer from their key page match their
/// own, with [modelFor] the model to build with for each (none without).
_Score _score(
  Map<String, Map<int, Map<String, UjiStrokes>>> uji,
  List<String> names, {
  HandModel? Function(String name)? modelFor,
}) {
  final _Score score = _Score();
  for (final String name in names) {
    final Map<String, UjiStrokes>? samples = uji[name]![1];
    if (samples == null || !keyLetters.split('').every(samples.containsKey)) {
      continue;
    }
    HandModel.debugOverride = modelFor?.call(name);
    final UjiScale scale = ujiScale(samples);
    final HandGlyphs? glyphs = readCustomFont(<UjiStrokes>[
      calibrationPage(samples, scale),
    ]).style?.glyphs;
    if (glyphs == null) continue;
    for (final String letter in _heldOut.split('')) {
      if (keyLetters.contains(letter)) continue;
      final UjiStrokes? actual = samples[letter];
      final HandGlyph? generated = glyphs[letter];
      if (actual == null || generated == null) continue;
      score.add(
        letter,
        shapeDistance(generated.strokes, gridGlyph(actual, scale)),
      );
    }
  }
  HandModel.debugOverride = null;
  return score;
}

class _Score {
  final Map<String, List<double>> _distances = <String, List<double>>{};

  void add(String letter, double distance) =>
      (_distances[letter] ??= <double>[]).add(distance);

  @override
  String toString() {
    final List<double> all = _distances.values
        .expand((List<double> d) => d)
        .toList();
    final int matched = all.where((double d) => d <= 0.16).length;
    final double mean =
        all.fold(0.0, (double a, double b) => a + b) / all.length;
    final String letters = <String>[
      for (final MapEntry<String, List<double>> e in _distances.entries)
        '${e.key} ${(100 * e.value.where((double d) => d <= 0.16).length / e.value.length).round()}',
    ].join(' ');
    return '${(100 * matched / all.length).toStringAsFixed(1)}% '
        '($matched/${all.length}), mean ${(100 * mean).toStringAsFixed(1)}; '
        '$letters';
  }
}

List<int> _ints(String name, List<int> fallback) =>
    Platform.environment[name]?.split(',').map(int.parse).toList() ?? fallback;

List<double> _doubles(String name, List<double> fallback) =>
    Platform.environment[name]?.split(',').map(double.parse).toList() ??
    fallback;

String _dataFile(String encoded) {
  final String header = encoded.substring(0, encoded.indexOf('\n'));
  final String data = encoded.substring(encoded.indexOf('\n') + 1);
  final StringBuffer out = StringBuffer()
    ..writeln('// Generated by tool/train_hand_model_test.dart. Do not edit.')
    ..writeln('//')
    ..writeln('// Learned from UJI Pen Characters v2 (Prat, Castro, Llorens,')
    ..writeln('// Marzal & Vilar; UCI Machine Learning Repository,')
    ..writeln(
      '// https://archive.ics.uci.edu/dataset/177), licensed CC BY 4.0:',
    )
    ..writeln('// https://creativecommons.org/licenses/by/4.0/')
    ..writeln()
    ..writeln(
      '/// The bundled [HandModel], encoded; empty when none is bundled.',
    )
    ..writeln('const String handModelData =')
    ..writeln(
      "    '${header.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}\\n'",
    );
  for (int i = 0; i < data.length; i += 72) {
    final String chunk = data.substring(
      i,
      i + 72 > data.length ? data.length : i + 72,
    );
    out.writeln("    '$chunk'${i + 72 >= data.length ? ';' : ''}");
  }
  return out.toString();
}
