import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';

Map<String, Object?> _text() => <String, Object?>{
  'type': 'text',
  'text': 'x = 3',
  'x': 0.5,
  'y': 0.2,
  'size': 24,
  'ink': 'blue',
  'width': 2.5,
};

Map<String, Object?> _graph() => <String, Object?>{
  'type': 'graph',
  'formula': 'x^2 - 2',
  'x_from': -2,
  'x_to': 2,
  'y_from': null,
  'y_to': null,
  'left': 0.5,
  'top': 0.5,
  'right': 0.9,
  'bottom': 0.9,
  'axes': true,
  'ink': 'red',
  'width': 2,
};

Map<String, Object?> _path() => <String, Object?>{
  'type': 'path',
  'points': <Object?>[
    <String, Object?>{'x': 0.1, 'y': 0.6},
    <String, Object?>{'x': 0.2, 'y': 0.5},
    <String, Object?>{'x': 0.3, 'y': 0.6},
  ],
  'segments': <String>['curve', 'straight'],
  'closed': false,
  'line_style': 'dotted',
  'arrow': 'end',
  'ink': 'green',
  'width': 3,
};

Map<String, Object?> _line() => <String, Object?>{
  'type': 'line',
  'from': <String, Object?>{'x': 0.4, 'y': 0.3},
  'to': <String, Object?>{'x': 0.2, 'y': 0.25},
  'line_style': 'dashed',
  'arrow': 'both',
  'ink': 'orange',
  'width': 2,
};

Map<String, Object?> _shape() => <String, Object?>{
  'type': 'shape',
  'shape': 'right_triangle',
  'left': 0.1,
  'top': 0.1,
  'right': 0.3,
  'bottom': 0.2,
  'line_style': 'solid',
  'ink': 'purple',
  'width': 3,
};

Map<String, Object?> _stroke() => <String, Object?>{
  'type': 'stroke',
  'points': <Object?>[
    <String, Object?>{'x': 0.25, 'y': 0.5},
    <String, Object?>{'x': 0.75, 'y': 0.5},
  ],
  'ink': 'ink',
  'width': 3,
};

Map<String, Object?> _plot() => <String, Object?>{
  'type': 'plot',
  'left': 0.5,
  'top': 0.1,
  'right': 0.9,
  'bottom': 0.4,
  'x_from': -3,
  'x_to': 3,
  'y_from': -1,
  'y_to': 9,
  'axes': true,
  'ticks': true,
  'children': <Object?>[
    <String, Object?>{
      'type': 'function',
      'formula': 'x^2',
      'line_style': 'solid',
      'marks': <String>['roots', 'y_intercept'],
      'ink': 'blue',
    },
    <String, Object?>{
      'type': 'point',
      'x': 2,
      'y': 4,
      'label': '(2, 4)',
      'ink': 'red',
    },
    <String, Object?>{
      'type': 'segment',
      'from': <String, Object?>{'x': 2, 'y': 0},
      'to': <String, Object?>{'x': 2, 'y': 4},
      'line_style': 'dashed',
      'arrow': 'none',
      'ink': 'graphite',
    },
    <String, Object?>{
      'type': 'label',
      'x': -2.5,
      'y': 8,
      'text': 'y = x²',
      'ink': 'blue',
    },
    <String, Object?>{
      'type': 'shade',
      'formula': 'x^2',
      'base': '1',
      'from': 1,
      'to': 2,
      'ink': 'teal',
    },
    <String, Object?>{
      'type': 'intersections',
      'of': <String>['x^2', '2*x + 3'],
      'ink': 'purple',
    },
  ],
  'ink': 'graphite',
  'width': 2,
};

Map<String, Object?> _valid([List<Map<String, Object?>>? items]) {
  return <String, Object?>{
    'version': 2,
    'message': 'I solved it.',
    'notation': <String, Object?>{
      'label': 'Answer and graph',
      'coordinate_space': 'note_normalized',
      'items':
          items ??
          <Object?>[_text(), _graph(), _path(), _line(), _shape(), _stroke()],
    },
  };
}

/// [_valid] with its one item changed by [change].
String _withItem(
  Map<String, Object?> item,
  void Function(Map<String, Object?> item) change,
) {
  change(item);
  return jsonEncode(_valid(<Map<String, Object?>>[item]));
}

void main() {
  test('parses every kind of item, and serializes them back exactly', () {
    final AiAssistantResponse response = AiAssistantResponse.parse(
      jsonEncode(_valid()),
    );

    expect(response.message, 'I solved it.');
    expect(response.notationRejected, isFalse);
    final List<AiNotationItem> items = response.notation!.items;
    expect(items.map((AiNotationItem item) => item.type), <String>[
      'text',
      'graph',
      'path',
      'line',
      'shape',
      'stroke',
    ]);
    final AiNotationText text = items[0] as AiNotationText;
    expect((text.text, text.x, text.y, text.size), ('x = 3', 0.5, 0.2, 24.0));
    final AiNotationGraph graph = items[1] as AiNotationGraph;
    expect(graph.formula.evaluate(3), 7);
    expect(
      (graph.xFrom, graph.xTo, graph.yFrom, graph.yTo),
      (-2.0, 2.0, null, null),
    );
    expect(graph.axes, isTrue);
    final AiNotationPath path = items[2] as AiNotationPath;
    expect(path.segments, <AiPathSegment>[
      AiPathSegment.curve,
      AiPathSegment.straight,
    ]);
    expect(path.closed, isFalse);
    expect(path.lineStyle, AiLineStyle.dotted);
    expect(path.arrow, AiArrow.end);
    final AiNotationLine line = items[3] as AiNotationLine;
    expect((line.from.x, line.to.y), (0.4, 0.25));
    expect(line.lineStyle, AiLineStyle.dashed);
    expect(line.arrow, AiArrow.both);
    final AiNotationShape shape = items[4] as AiNotationShape;
    expect(shape.shape, AiShapeKind.rightTriangle);
    expect((shape.left, shape.bottom), (0.1, 0.2));
    expect((items[5] as AiNotationStroke).points, hasLength(2));
    expect(jsonDecode(response.toJsonString()), _valid());
  });

  group('plot', () {
    test('parses every child, and serializes them back exactly', () {
      final Map<String, Object?> envelope = _valid(<Map<String, Object?>>[
        _plot(),
      ]);
      final AiAssistantResponse response = AiAssistantResponse.parse(
        jsonEncode(envelope),
      );
      final AiNotationPlot plot =
          response.notation!.items.single as AiNotationPlot;
      expect(
        (plot.xFrom, plot.xTo, plot.yFrom, plot.yTo),
        (-3.0, 3.0, -1.0, 9.0),
      );
      expect((plot.axes, plot.ticks), (true, true));
      expect(plot.children.map((AiPlotChild child) => child.type), <String>[
        'function',
        'point',
        'segment',
        'label',
        'shade',
        'intersections',
      ]);
      final AiPlotFunction function = plot.children[0] as AiPlotFunction;
      expect(function.formula.evaluate(3), 9);
      expect(function.marks, <AiPlotMark>[
        AiPlotMark.roots,
        AiPlotMark.yIntercept,
      ]);
      final AiPlotDot dot = plot.children[1] as AiPlotDot;
      expect((dot.at.x, dot.at.y, dot.label), (2.0, 4.0, '(2, 4)'));
      final AiPlotSegment segment = plot.children[2] as AiPlotSegment;
      expect(segment.lineStyle, AiLineStyle.dashed);
      final AiPlotShade shade = plot.children[4] as AiPlotShade;
      expect(shade.base!.evaluate(5), 1);
      final AiPlotIntersections meet = plot.children[5] as AiPlotIntersections;
      expect(meet.second.evaluate(1), 5);
      expect(jsonDecode(response.toJsonString()), envelope);
    });

    test('a child may leave out its optional fields', () {
      final AiAssistantResponse response = AiAssistantResponse.parse(
        jsonEncode(
          _valid(<Map<String, Object?>>[
            _plot()
              ..['y_from'] = null
              ..['y_to'] = null
              ..['children'] = <Object?>[
                <String, Object?>{
                  'type': 'function',
                  'formula': 'sin(x)',
                  'ink': 'blue',
                },
                <String, Object?>{
                  'type': 'point',
                  'x': 0,
                  'y': 0,
                  'ink': 'red',
                },
                <String, Object?>{
                  'type': 'segment',
                  'from': <String, Object?>{'x': 0, 'y': 0},
                  'to': <String, Object?>{'x': 1, 'y': 1},
                  'ink': 'red',
                },
                <String, Object?>{
                  'type': 'shade',
                  'formula': 'sin(x)',
                  'from': 0,
                  'to': 3,
                  'ink': 'teal',
                },
              ],
          ]),
        ),
      );
      final AiNotationPlot plot =
          response.notation!.items.single as AiNotationPlot;
      final AiPlotFunction function = plot.children[0] as AiPlotFunction;
      expect(function.lineStyle, AiLineStyle.solid);
      expect(function.marks, isEmpty);
      expect((plot.children[1] as AiPlotDot).label, isNull);
      final AiPlotSegment segment = plot.children[2] as AiPlotSegment;
      expect(
        (segment.lineStyle, segment.arrow),
        (AiLineStyle.solid, AiArrow.none),
      );
      expect((plot.children[3] as AiPlotShade).base, isNull);
    });

    test('rejects a broken plot or child, whole', () {
      Map<String, Object?> child(Map<String, Object?> child) {
        return _plot()..['children'] = <Object?>[child];
      }

      for (final (String reason, Map<String, Object?> plot)
          in <(String, Map<String, Object?>)>[
            ('empty x range', _plot()..['x_to'] = -3),
            ('one y bound', _plot()..['y_to'] = null),
            ('inverted box', _plot()..['bottom'] = 0.05),
            ('ticks not bool', _plot()..['ticks'] = 'yes'),
            (
              'too many children',
              _plot()
                ..['children'] = <Object?>[
                  for (int i = 0; i < 17; i++)
                    <String, Object?>{
                      'type': 'point',
                      'x': i,
                      'y': 0,
                      'ink': 'red',
                    },
                ],
            ),
            (
              'unknown child',
              child(<String, Object?>{'type': 'bar', 'ink': 'red'}),
            ),
            (
              'unknown mark',
              child(<String, Object?>{
                'type': 'function',
                'formula': 'x',
                'marks': <String>['asymptotes'],
                'ink': 'red',
              }),
            ),
            (
              'bad formula',
              child(<String, Object?>{
                'type': 'function',
                'formula': 'x +* 2',
                'ink': 'red',
              }),
            ),
            (
              'one intersecting formula',
              child(<String, Object?>{
                'type': 'intersections',
                'of': <String>['x'],
                'ink': 'red',
              }),
            ),
            (
              'label the font cannot write',
              child(<String, Object?>{
                'type': 'label',
                'x': 0,
                'y': 0,
                'text': '∫',
                'ink': 'red',
              }),
            ),
            (
              'empty shade',
              child(<String, Object?>{
                'type': 'shade',
                'formula': 'x',
                'from': 2,
                'to': 1,
                'ink': 'red',
              }),
            ),
            (
              'note coordinates in a child',
              child(<String, Object?>{
                'type': 'point',
                'x': 0,
                'y': 0,
                'coordinate_space': 'note_normalized',
                'ink': 'red',
              }),
            ),
          ]) {
        final AiAssistantResponse response = AiAssistantResponse.parse(
          jsonEncode(_valid(<Map<String, Object?>>[plot])),
        );
        expect(response.notationRejected, isTrue, reason: reason);
      }
    });

    test('its labels count toward the notation text', () {
      final String json = jsonEncode(_valid(<Map<String, Object?>>[_plot()]));
      // '(2, 4)' and 'y = x²'.
      expect(
        AiAssistantResponse.parse(
          json,
          config: const AiNotationConfig(maxTotalTextRunes: 12),
        ).notation,
        isNotNull,
      );
      expect(
        AiAssistantResponse.parse(
          json,
          config: const AiNotationConfig(maxTotalTextRunes: 11),
        ).notationRejected,
        isTrue,
      );
    });
  });

  test('parses the null-notation envelope', () {
    final AiAssistantResponse response = AiAssistantResponse.parse(
      '{"version":2,"message":" Correct. ","notation":null}',
    );

    expect(response.message, 'Correct.');
    expect(response.notation, isNull);
    expect(response.notationRejected, isFalse);
  });

  test('accepts every palette ID, a closed path, and inclusive bounds', () {
    const List<String> inks = <String>[
      'ink',
      'graphite',
      'blue',
      'red',
      'green',
      'orange',
      'purple',
      'teal',
    ];
    final AiAssistantResponse response = AiAssistantResponse.parse(
      jsonEncode(
        _valid(<Map<String, Object?>>[
          for (int i = 0; i < inks.length; i++)
            _stroke()
              ..['ink'] = inks[i]
              ..['width'] = i.isEven ? 1 : 20
              ..['points'] = <Object?>[
                <String, Object?>{'x': 0, 'y': 0},
                <String, Object?>{'x': 1, 'y': 1},
              ],
          _text()
            ..['size'] = 8
            ..['text'] = 'a' * 120,
          _text()..['size'] = 120,
          _path()
            ..['closed'] = true
            ..['arrow'] = 'none'
            ..['segments'] = <String>['curve', 'curve', 'curve'],
          _graph()
            ..['y_from'] = -5
            ..['y_to'] = 5,
        ]),
      ),
    );

    expect(
      response.notation!.items.take(8).map((AiNotationItem item) => item.ink),
      inks,
    );
    final AiNotationPath path = response.notation!.items[10] as AiNotationPath;
    expect(path.closed, isTrue);
    expect(path.segments, hasLength(3));
    expect((response.notation!.items[11] as AiNotationGraph).yTo, 5);
  });

  test('accepts every shape, line style, and arrow', () {
    final AiAssistantResponse response = AiAssistantResponse.parse(
      jsonEncode(
        _valid(<Map<String, Object?>>[
          for (final AiShapeKind kind in AiShapeKind.values)
            _shape()..['shape'] = kind.wire,
          for (final AiLineStyle style in AiLineStyle.values)
            for (final AiArrow arrow in AiArrow.values)
              _line()
                ..['line_style'] = style.name
                ..['arrow'] = arrow.name,
        ]),
      ),
    );

    expect(
      response.notation!.items.whereType<AiNotationShape>().map(
        (AiNotationShape shape) => shape.shape,
      ),
      AiShapeKind.values,
    );
    expect(<String>{
      for (final AiNotationLine line
          in response.notation!.items.whereType<AiNotationLine>())
        '${line.lineStyle.name} ${line.arrow.name}',
    }, hasLength(AiLineStyle.values.length * AiArrow.values.length));
    expect(AiShapeKind.values.map((AiShapeKind kind) => kind.wire), <String>[
      'ellipse',
      'circle',
      'rectangle',
      'triangle',
      'triangle_down',
      'triangle_left',
      'triangle_right',
      'right_triangle',
      'diamond',
      'pentagon',
      'hexagon',
      'star',
    ]);
  });

  test('a broken envelope is not an answer', () {
    for (final Map<String, Object?> value in <Map<String, Object?>>[
      <String, Object?>{..._valid(), 'extra': true},
      <String, Object?>{..._valid(), 'version': 1},
      <String, Object?>{..._valid(), 'message': '  '},
      <String, Object?>{..._valid(), 'message': 3},
    ]) {
      expect(
        () => AiAssistantResponse.parse(jsonEncode(value)),
        throwsFormatException,
      );
    }
    expect(
      () => AiAssistantResponse.parse('```json\n${jsonEncode(_valid())}\n```'),
      throwsFormatException,
    );
    expect(
      () => AiAssistantResponse.parse('before ${jsonEncode(_valid())}'),
      throwsFormatException,
    );
    expect(
      () => AiAssistantResponse.parse(
        jsonEncode(_valid()),
        config: const AiNotationConfig(maxResponseBytes: 10),
      ),
      throwsFormatException,
    );
  });

  test('a broken notation is dropped whole, and the words kept', () {
    final Map<String, String> cases = <String, String>{
      'an unknown kind': _withItem(_stroke(), (Map<String, Object?> i) {
        i['type'] = 'image';
      }),
      'an extra field': _withItem(_text(), (Map<String, Object?> i) {
        i['font'] = 'serif';
      }),
      'a missing field': _withItem(_graph(), (Map<String, Object?> i) {
        i.remove('axes');
      }),
      'an unknown ink': _withItem(_stroke(), (Map<String, Object?> i) {
        i['ink'] = 'chartreuse';
      }),
      'a width over 20': _withItem(_stroke(), (Map<String, Object?> i) {
        i['width'] = 21;
      }),
      'a point off the note': _withItem(_stroke(), (Map<String, Object?> i) {
        i['points'] = <Object?>[
          <String, Object?>{'x': 1.1, 'y': 0.5},
        ];
      }),
      'a number as a string': _withItem(_text(), (Map<String, Object?> i) {
        i['x'] = '0.5';
      }),
      'a boolean as a number': _withItem(_text(), (Map<String, Object?> i) {
        i['y'] = true;
      }),
      'blank text': _withItem(_text(), (Map<String, Object?> i) {
        i['text'] = '  ';
      }),
      'text the font cannot write': _withItem(_text(), (
        Map<String, Object?> i,
      ) {
        i['text'] = 'naïve';
      }),
      'text too long': _withItem(_text(), (Map<String, Object?> i) {
        i['text'] = 'a' * 121;
      }),
      'text too small': _withItem(_text(), (Map<String, Object?> i) {
        i['size'] = 7;
      }),
      'a formula that does not read': _withItem(_graph(), (
        Map<String, Object?> i,
      ) {
        i['formula'] = 'x^^2';
      }),
      'a formula with an unknown name': _withItem(_graph(), (
        Map<String, Object?> i,
      ) {
        i['formula'] = 'print(x)';
      }),
      'a graph ending before it starts': _withItem(_graph(), (
        Map<String, Object?> i,
      ) {
        i['x_to'] = -3;
      }),
      'only one end of the y range': _withItem(_graph(), (
        Map<String, Object?> i,
      ) {
        i['y_from'] = 0;
      }),
      'an empty box': _withItem(_graph(), (Map<String, Object?> i) {
        i['right'] = i['left'];
      }),
      'a range too far out': _withItem(_graph(), (Map<String, Object?> i) {
        i['x_to'] = 1e7;
      }),
      'a segment too few': _withItem(_path(), (Map<String, Object?> i) {
        i['segments'] = <String>['curve'];
      }),
      'a closed path missing its last segment': _withItem(_path(), (
        Map<String, Object?> i,
      ) {
        i['closed'] = true;
      }),
      'an unknown segment': _withItem(_path(), (Map<String, Object?> i) {
        i['segments'] = <String>['curve', 'wiggly'];
      }),
      'an arrow on a closed path': _withItem(_path(), (Map<String, Object?> i) {
        i['closed'] = true;
        i['segments'] = <String>['curve', 'curve', 'curve'];
      }),
      'an unknown line style': _withItem(_line(), (Map<String, Object?> i) {
        i['line_style'] = 'wavy';
      }),
      'an unknown arrow': _withItem(_line(), (Map<String, Object?> i) {
        i['arrow'] = 'middle';
      }),
      'a line of no length': _withItem(_line(), (Map<String, Object?> i) {
        i['to'] = i['from'];
      }),
      'a line end off the note': _withItem(_line(), (Map<String, Object?> i) {
        i['to'] = <String, Object?>{'x': 0.5, 'y': -0.1};
      }),
      'an unknown shape': _withItem(_shape(), (Map<String, Object?> i) {
        i['shape'] = 'heart';
      }),
      'a shape named as in Dart': _withItem(_shape(), (Map<String, Object?> i) {
        i['shape'] = 'rightTriangle';
      }),
      'a shape with an empty box': _withItem(_shape(), (
        Map<String, Object?> i,
      ) {
        i['bottom'] = i['top'];
      }),
      'a shape with an arrow': _withItem(_shape(), (Map<String, Object?> i) {
        i['arrow'] = 'end';
      }),
      'a path missing its line style': _withItem(_path(), (
        Map<String, Object?> i,
      ) {
        i.remove('line_style');
      }),
      'a path of one point': _withItem(_path(), (Map<String, Object?> i) {
        i['points'] = <Object?>[
          <String, Object?>{'x': 0.5, 'y': 0.5},
        ];
        i['segments'] = <String>[];
      }),
      'no items': jsonEncode(_valid(<Map<String, Object?>>[])),
      'too many items': jsonEncode(
        _valid(<Map<String, Object?>>[for (int i = 0; i < 49; i++) _stroke()]),
      ),
      'too much text in all': jsonEncode(
        _valid(<Map<String, Object?>>[
          for (int i = 0; i < 10; i++) _text()..['text'] = 'a' * 101,
        ]),
      ),
      'a label too long': jsonEncode(
        _valid()
          ..['notation'] = <String, Object?>{
            ...(_valid()['notation']! as Map<String, Object?>),
            'label': 'a' * 81,
          },
      ),
      'another coordinate space': jsonEncode(
        _valid()
          ..['notation'] = <String, Object?>{
            ...(_valid()['notation']! as Map<String, Object?>),
            'coordinate_space': 'screen_pixels',
          },
      ),
      'a sticky note in note coordinates': jsonEncode(
        _valid()
          ..['notation'] = <String, Object?>{
            ...(_valid()['notation']! as Map<String, Object?>),
            'sticky': <String, Object?>{'width': 300, 'height': 200},
          },
      ),
      'sticky coordinates without a sticky note': jsonEncode(
        _valid()
          ..['notation'] = <String, Object?>{
            ...(_valid()['notation']! as Map<String, Object?>),
            'coordinate_space': 'sticky_normalized',
          },
      ),
      'a sticky note with no height': jsonEncode(
        _valid()
          ..['notation'] = <String, Object?>{
            ...(_valid()['notation']! as Map<String, Object?>),
            'coordinate_space': 'sticky_normalized',
            'sticky': <String, Object?>{'width': 300},
          },
      ),
      'the old strokes shape': jsonEncode(
        _valid()
          ..['notation'] = <String, Object?>{
            'label': 'Old',
            'coordinate_space': 'note_normalized',
            'strokes': <Object?>[_stroke()..remove('type')],
          },
      ),
    };

    for (final MapEntry<String, String> entry in cases.entries) {
      final AiAssistantResponse response = AiAssistantResponse.parse(
        entry.value,
      );
      expect(response.message, 'I solved it.', reason: entry.key);
      expect(response.notation, isNull, reason: entry.key);
      expect(response.notationRejected, isTrue, reason: entry.key);
      expect(
        jsonDecode(response.toJsonString()),
        <String, Object?>{
          'version': 2,
          'message': 'I solved it.',
          'notation': null,
        },
        reason: '${entry.key}: nothing of it is replayed',
      );
    }
  });

  test('a notation on a sticky note keeps its size, brought within the '
      'sizes a sticky note may be, and serializes back', () {
    final AiAssistantResponse response = AiAssistantResponse.parse(
      jsonEncode(
        _valid()
          ..['notation'] = <String, Object?>{
            ...(_valid()['notation']! as Map<String, Object?>),
            'coordinate_space': 'sticky_normalized',
            'sticky': <String, Object?>{'width': 900, 'height': 200},
          },
      ),
    );

    expect(response.notationRejected, isFalse);
    expect(response.notation!.sticky, const AiStickySize(640, 200));
    final Map<String, Object?> notation =
        (jsonDecode(response.toJsonString())
                as Map<String, Object?>)['notation']!
            as Map<String, Object?>;
    expect(notation['coordinate_space'], 'sticky_normalized');
    expect(notation['sticky'], <String, Object?>{'width': 640, 'height': 200});
    expect(
      AiAssistantResponse.parse(response.toJsonString()).notation!.sticky,
      const AiStickySize(640, 200),
    );
  });

  test('a notation without a label or coordinate space, with points as '
      '[x, y], is drawn: as Claude Haiku answered through the backend', () {
    const String answer =
        '{"version":2,"message":"The hypotenuse is **5**.","notation":'
        '{"coordinate_space":"note_normalized","items":[{"type":"text",'
        '"ink":"blue","width":2,"text":"c = √25 = 5","x":0.565,"y":0.528,'
        '"size":22},{"type":"line","ink":"red","width":2,"from":[0.565,0.562],'
        '"to":[0.78,0.562],"line_style":"solid","arrow":"none"}]}}';
    final AiAssistantResponse response = AiAssistantResponse.parse(answer);

    expect(response.notationRejected, isFalse);
    final AiNotation notation = response.notation!;
    expect(notation.label, AiAssistantResponse.defaultLabel);
    final AiNotationLine line = notation.items[1] as AiNotationLine;
    expect((line.from.x, line.from.y), (0.565, 0.562));
    expect((line.to.x, line.to.y), (0.78, 0.562));

    // No coordinate space at all is the paper's.
    final Map<String, Object?> bare =
        jsonDecode(answer) as Map<String, Object?>;
    (bare['notation']! as Map<String, Object?>).remove('coordinate_space');
    expect(AiAssistantResponse.parse(jsonEncode(bare)).notation, isNotNull);
    // A point of three numbers is still no point.
    expect(
      AiAssistantResponse.parse(
        answer.replaceFirst('[0.565,0.562]', '[0.565,0.562,1]'),
      ).notationRejected,
      isTrue,
    );
  });

  test('a notation on the paper has no sticky note', () {
    final AiAssistantResponse response = AiAssistantResponse.parse(
      jsonEncode(_valid()),
    );
    expect(response.notation!.sticky, isNull);
    expect(
      (jsonDecode(response.toJsonString()) as Map<String, Object?>)['notation'],
      isNot(contains('sticky')),
    );
  });

  test('points count over strokes and paths, not text or graphs', () {
    final String json = jsonEncode(_valid());
    // The stroke's 2 and the path's 3.
    expect(
      AiAssistantResponse.parse(
        json,
        config: const AiNotationConfig(maxTotalPoints: 5),
      ).notation,
      isNotNull,
    );
    expect(
      AiAssistantResponse.parse(
        json,
        config: const AiNotationConfig(maxTotalPoints: 4),
      ).notationRejected,
      isTrue,
    );
  });

  test('schema is closed and describes each kind of item', () {
    final Map<String, Object?> schema = aiResponseJsonSchema();
    expect(schema['additionalProperties'], isFalse);
    final properties = schema['properties']! as Map<String, Object?>;
    expect((properties['version']! as Map<String, Object?>)['enum'], <int>[2]);
    final notation =
        ((properties['notation']! as Map<String, Object?>)['anyOf']!
                as List<Object?>)[1]!
            as Map<String, Object?>;
    expect(notation['additionalProperties'], isFalse);
    final itemsSchema =
        (notation['properties']! as Map<String, Object?>)['items']!
            as Map<String, Object?>;
    expect(itemsSchema['minItems'], 1);
    final List<Object?> kinds =
        (itemsSchema['items']! as Map<String, Object?>)['anyOf']!
            as List<Object?>;
    final Map<String, Map<String, Object?>> byType =
        <String, Map<String, Object?>>{
          for (final Object? kind in kinds)
            (((kind! as Map<String, Object?>)['properties']!
                            as Map<String, Object?>)['type']!
                        as Map<String, Object?>)['enum']!
                    .toString():
                kind as Map<String, Object?>,
        };
    expect(byType.keys, <String>[
      '[text]',
      '[graph]',
      '[plot]',
      '[path]',
      '[line]',
      '[shape]',
      '[stroke]',
    ]);
    // Each kind is closed, requires exactly the fields the parser does, and
    // may also carry its optional step.
    for (final MapEntry<String, Map<String, Object?>> entry in byType.entries) {
      final Map<String, Object?> kind = entry.value;
      expect(kind['additionalProperties'], isFalse, reason: entry.key);
      final Map<String, Object?> properties =
          kind['properties']! as Map<String, Object?>;
      expect(properties.keys.toSet(), <Object?>{
        ...kind['required']! as List<Object?>,
        'step',
      }, reason: entry.key);
      final Map<String, Object?> step =
          properties['step']! as Map<String, Object?>;
      expect(step['type'], 'integer');
      expect((step['minimum'], step['maximum']), (1, 24));
    }
    expect(notation['required'], <String>[
      'label',
      'coordinate_space',
      'items',
    ]);
    expect((notation['properties']! as Map<String, Object?>).keys, <String>[
      'label',
      'coordinate_space',
      'items',
      'sticky',
    ]);
    final Map<String, Object?> sticky =
        (notation['properties']! as Map<String, Object?>)['sticky']!
            as Map<String, Object?>;
    expect(sticky['additionalProperties'], isFalse);
    expect(sticky['required'], <String>['width', 'height']);
    expect(jsonEncode(schema), isNot(contains('_ms')));
    expect(byType['[text]']!['required'], _text().keys);
    expect(byType['[graph]']!['required'], _graph().keys);
    expect(byType['[plot]']!['required'], _plot().keys);
    // Every plot child is closed too, and requires what the parser does.
    final List<Object?> children =
        ((((byType['[plot]']!['properties']!
                        as Map<String, Object?>)['children']!
                    as Map<String, Object?>)['items']!
                as Map<String, Object?>)['anyOf']!
            as List<Object?>);
    final Map<String, List<Object?>> childRequired = <String, List<Object?>>{
      for (final Object? child in children)
        (((child! as Map<String, Object?>)['properties']!
                        as Map<String, Object?>)['type']!
                    as Map<String, Object?>)['enum']
                .toString():
            (child as Map<String, Object?>)['required']! as List<Object?>,
    };
    expect(childRequired, <String, List<Object?>>{
      '[function]': <String>['type', 'formula', 'ink'],
      '[point]': <String>['type', 'x', 'y', 'ink'],
      '[segment]': <String>['type', 'from', 'to', 'ink'],
      '[label]': <String>['type', 'x', 'y', 'text', 'ink'],
      '[shade]': <String>['type', 'formula', 'from', 'to', 'ink'],
      '[intersections]': <String>['type', 'of', 'ink'],
    });
    for (final Object? child in children) {
      expect((child! as Map<String, Object?>)['additionalProperties'], false);
    }
    expect(byType['[path]']!['required'], _path().keys);
    expect(byType['[line]']!['required'], _line().keys);
    expect(byType['[shape]']!['required'], _shape().keys);
    expect(byType['[stroke]']!['required'], _stroke().keys);
    // Gemma rejects a schema with maxItems (400 or 500); the parser holds
    // the count limits instead.
    expect(jsonEncode(schema), isNot(contains('maxItems')));
  });

  group('partial message', () {
    (String, bool)? state(String source) {
      return AiAssistantResponse.partialMessageState(source);
    }

    test('is null until the message has begun', () {
      for (final String source in <String>[
        '',
        '{',
        '{"version": 2',
        '{"version": 2, "mess',
        '{"version": 2, "message"',
        '{"version": 2, "message": ',
      ]) {
        expect(state(source), isNull, reason: source);
      }
    });

    test('grows with the text, and is complete at its closing quote', () {
      expect(state('{"version":2,"message":"'), ('', false));
      expect(state('{"version":2,"message":"Hel'), ('Hel', false));
      expect(state('{"version":2,"message":"Hello"'), ('Hello', true));
      expect(state('{"version":2,"message":"Hello","notation":{"label":"L'), (
        'Hello',
        true,
      ));
    });

    test('decodes escapes, and leaves out one that is cut off', () {
      const String start = '{"version":2,"message":"';
      expect(state('${start}a\\nb \\"q\\" \\u00e9\\\\'), (
        'a\nb "q" é\\',
        false,
      ));
      expect(state('${start}a\\'), ('a', false));
      expect(state('${start}a\\u00'), ('a', false));
    });

    test('ignores keys and values that only look like it', () {
      // A label inside the notation, and a "message" string as a value.
      expect(
        state(
          '{"notation":{"message":"inner"},"version":2,'
          '"label":"message","message":"outer',
        ),
        ('outer', false),
      );
      expect(state('{"version":2,"note":"a \\"message\\": \\"x'), isNull);
    });

    test('matches what parse reads from the finished answer', () {
      final String full = jsonEncode(_valid());
      expect(
        AiAssistantResponse.partialMessage(full),
        AiAssistantResponse.parse(full).message,
      );
    });
  });
}
