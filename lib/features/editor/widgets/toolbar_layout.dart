import 'package:flutter/foundation.dart';

/// One button the tool palette can show.
enum PaletteItem {
  pen('Pen'),
  eraser('Eraser'),
  select('Select'),
  ai('AI'),
  image('Insert image'),
  sticky('Sticky note'),
  recording('Recordings'),
  text('Text'),
  ruler('Ruler'),
  customize('Customize toolbar');

  const PaletteItem(this.label);

  /// How the item is named where the toolbar is arranged.
  final String label;

  /// Whether it may be taken off the palette. The customize button may not:
  /// it alone brings hidden tools back.
  bool get canHide => this != customize;

  static PaletteItem? byName(Object? name) {
    for (final PaletteItem item in values) {
      if (item.name == name) return item;
    }
    return null;
  }
}

/// Where each of the palette's buttons goes, in order: always [shown],
/// [folded] away behind the arrow at the palette's end, or hidden, the
/// ones in neither.
@immutable
class ToolbarLayout {
  const ToolbarLayout({required this.shown, required this.folded});

  /// What the palette shows out of the box.
  static const ToolbarLayout standard = ToolbarLayout(
    shown: <PaletteItem>[
      PaletteItem.pen,
      PaletteItem.eraser,
      PaletteItem.select,
      PaletteItem.ai,
      PaletteItem.image,
    ],
    folded: <PaletteItem>[
      PaletteItem.sticky,
      PaletteItem.recording,
      PaletteItem.text,
      PaletteItem.ruler,
      PaletteItem.customize,
    ],
  );

  final List<PaletteItem> shown;
  final List<PaletteItem> folded;

  /// What is on neither the palette nor behind its arrow.
  List<PaletteItem> get hidden => <PaletteItem>[
    for (final PaletteItem item in PaletteItem.values)
      if (!shown.contains(item) && !folded.contains(item)) item,
  ];

  /// [item] taken off the palette, if it [PaletteItem.canHide].
  ToolbarLayout hide(PaletteItem item) => item.canHide ? _without(item) : this;

  ToolbarLayout _without(PaletteItem item) => ToolbarLayout(
    shown: <PaletteItem>[...shown.where((PaletteItem i) => i != item)],
    folded: <PaletteItem>[...folded.where((PaletteItem i) => i != item)],
  );

  /// [item] put back, at the end of the always-shown tools.
  ToolbarLayout show(PaletteItem item) {
    final ToolbarLayout without = _without(item);
    return ToolbarLayout(
      shown: <PaletteItem>[...without.shown, item],
      folded: without.folded,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'shown': <String>[for (final PaletteItem item in shown) item.name],
    'folded': <String>[for (final PaletteItem item in folded) item.name],
    'hidden': <String>[for (final PaletteItem item in hidden) item.name],
  };

  /// Reads what [toJson] wrote. Names it does not know are dropped, and a
  /// button it says nothing of, one added since, goes where [standard] has
  /// it, as does one marked hidden that cannot be.
  factory ToolbarLayout.fromJson(Object? json) {
    if (json is! Map) return standard;
    final Set<PaletteItem> seen = <PaletteItem>{};
    List<PaletteItem> read(Object? names) => <PaletteItem>[
      if (names is List)
        for (final Object? name in names)
          if (PaletteItem.byName(name) case final PaletteItem item
              when seen.add(item))
            item,
    ];
    final List<PaletteItem> shown = read(json['shown']);
    final List<PaletteItem> folded = read(json['folded']);
    for (final PaletteItem item in read(json['hidden'])) {
      if (!item.canHide) seen.remove(item);
    }
    for (final PaletteItem item in PaletteItem.values) {
      if (seen.contains(item)) continue;
      if (standard.folded.contains(item)) {
        folded.add(item);
      } else {
        shown.add(item);
      }
    }
    return ToolbarLayout(shown: shown, folded: folded);
  }

  @override
  bool operator ==(Object other) =>
      other is ToolbarLayout &&
      listEquals(other.shown, shown) &&
      listEquals(other.folded, folded);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(shown), Object.hashAll(folded));
}
