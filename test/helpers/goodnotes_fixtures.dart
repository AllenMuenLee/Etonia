import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A small `.goodnotes` notebook: one plain page with one pen stroke from
/// (80, 80) to (160, 80) in page units, made the way the extractor's own
/// tests make theirs.
Uint8List syntheticGoodnotesNotebook() {
  return _zip(<String, List<int>>{
    'schema.pb': <int>[0x08, 26],
    'index.notes.pb': _delimitedMessages(<List<int>>[
      _fields(<int, Object>{1: 'P1-STREAM', 2: 'notes/P1-STREAM'}),
    ]),
    'notes/P1-STREAM': _delimitedMessages(<List<int>>[
      _penPayload(
        'A',
        start: <double>[110, 110, 1, 1],
        segments: <double>[165, 110, 1, 220, 110, 1, 1, 1, 0.6],
      ),
    ]),
  }, deflate: true);
}

List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

List<int> _varint(int value) {
  final List<int> out = <int>[];
  do {
    int byte = value & 0x7F;
    value >>= 7;
    if (value != 0) byte |= 0x80;
    out.add(byte);
  } while (value != 0);
  return out;
}

/// A protobuf message: [int] values are varints, [double]s fixed32
/// floats, [String]s and byte lists length-delimited.
List<int> _fields(Map<int, Object> fields) => <int>[
  for (final MapEntry<int, Object> field in fields.entries)
    ...switch (field.value) {
      final int v => <int>[..._varint(field.key << 3), ..._varint(v)],
      final double v => <int>[
        ..._varint(field.key << 3 | 5),
        ...(ByteData(4)..setFloat32(0, v, Endian.little)).buffer.asUint8List(),
      ],
      final String v => <int>[
        ..._varint(field.key << 3 | 2),
        ..._varint(utf8.encode(v).length),
        ...utf8.encode(v),
      ],
      final List<int> v => <int>[
        ..._varint(field.key << 3 | 2),
        ..._varint(v.length),
        ...v,
      ],
      _ => throw ArgumentError(field.value),
    },
];

Uint8List _delimitedMessages(List<List<int>> messages) =>
    Uint8List.fromList(<int>[
      for (final List<int> m in messages) ...<int>[..._varint(m.length), ...m],
    ]);

class _TplWriter {
  final BytesBuilder out = BytesBuilder();

  void v(int value) => out.add(
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u32(int value) => out.add(_u32(value));
  void f(double value) => out.add(
    (ByteData(4)..setFloat32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void vs(List<int> values) {
    u32(values.length);
    values.forEach(v);
  }

  void fs(List<double> values) {
    u32(values.length);
    values.forEach(f);
  }
}

Uint8List _tpl(String format, void Function(_TplWriter) write) {
  final _TplWriter writer = _TplWriter();
  write(writer);
  final List<int> body = <int>[
    ...ascii.encode(format),
    0,
    ...writer.out.takeBytes(),
  ];
  return Uint8List.fromList(<int>[
    ...ascii.encode('tpl'),
    0,
    ..._u32(body.length + 8),
    ...body,
  ]);
}

/// A stroke record: `{7: StrokePayload}` with the pen `tpl` schema, stored
/// in a `bv4-` block.
List<int> _penPayload(
  String id, {
  required List<double> start,
  required List<double> segments,
}) {
  final Uint8List tpl = _tpl('vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)', (
    _TplWriter w,
  ) {
    w
      ..v(2)
      ..vs(<int>[
        if (start.isNotEmpty) 4,
        for (int i = 0; i < segments.length ~/ 9; i++) 5,
      ])
      ..fs(start)
      ..fs(segments)
      ..vs(<int>[])
      ..vs(<int>[])
      ..fs(<double>[])
      ..fs(<double>[])
      ..fs(<double>[])
      ..fs(<double>[])
      ..vs(<int>[]);
  });
  final List<int> stored = <int>[
    ...ascii.encode('bv4-'),
    ..._u32(tpl.length),
    ...tpl,
    ...ascii.encode(r'bv4$'),
  ];
  return _fields(<int, Object>{
    7: _fields(<int, Object>{
      1: id,
      2: stored,
      3: 1,
      4: _fields(<int, Object>{1: 0.0, 2: 0.0, 3: 0.0, 4: 1.0}),
    }),
  });
}

/// A ZIP archive of [entries], stored or deflated.
Uint8List _zip(Map<String, List<int>> entries, {bool deflate = false}) {
  final BytesBuilder out = BytesBuilder();
  final BytesBuilder directory = BytesBuilder();
  List<int> u16(int v) =>
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
  for (final MapEntry<String, List<int>> entry in entries.entries) {
    final List<int> name = utf8.encode(entry.key);
    final List<int> data = deflate
        ? ZLibCodec(raw: true).encode(entry.value)
        : entry.value;
    final int offset = out.length;
    final List<int> common = <int>[
      ...u16(20), ...u16(0), ...u16(deflate ? 8 : 0), ...u16(0), ...u16(0),
      ..._u32(0), // CRC, which the reader does not check.
      ..._u32(data.length), ..._u32(entry.value.length),
      ...u16(name.length), ...u16(0),
    ];
    out
      ..add(_u32(0x04034B50))
      ..add(common)
      ..add(name)
      ..add(data);
    directory
      ..add(_u32(0x02014B50))
      ..add(u16(20))
      ..add(common)
      ..add(<int>[...u16(0), ...u16(0), ...u16(0), ..._u32(0)])
      ..add(_u32(offset))
      ..add(name);
  }
  final int directoryOffset = out.length;
  final Uint8List dir = directory.takeBytes();
  out
    ..add(dir)
    ..add(_u32(0x06054B50))
    ..add(<int>[...u16(0), ...u16(0)])
    ..add(u16(entries.length))
    ..add(u16(entries.length))
    ..add(_u32(dir.length))
    ..add(_u32(directoryOffset))
    ..add(u16(0));
  return out.takeBytes();
}
