import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData;
import 'package:flutter_svg/flutter_svg.dart';

import '../../app/theme/app_tokens.dart';
import 'line_icon_map.dart';
import 'pencil_texture.dart';

/// The one line weight of every icon, in logical pixels, whatever size the
/// icon is drawn at.
const double kIconStrokeWidth = 1.3;

/// The one size of every icon, in logical pixels: 1.2 times the 20 it was.
const double kIconSize = 24;

/// An icon drawn larger than this is an illustration (an empty state, a
/// confirmation mark), not a control glyph, and keeps its size.
const double kIllustrationSize = 24;

/// [tint] as every icon wears it: the quiet icon color, with [tint]'s own
/// opacity (a dimmed, disabled icon stays dimmed). A color that is not one of
/// the theme's own is returned as it is.
Color _uniformTint(AppColors colors, Color? tint) {
  if (tint == null) return colors.textSecondary;
  final int rgb = tint.toARGB32() & 0xFFFFFF;
  final bool themed = <Color>[
    colors.textPrimary,
    colors.textSecondary,
    colors.textTertiary,
    colors.accent,
    colors.accentText,
    colors.brandHover,
    colors.brandPressed,
    colors.danger,
    colors.success,
    colors.warning,
  ].any((Color c) => c.toARGB32() & 0xFFFFFF == rgb);
  return themed ? colors.textSecondary.withValues(alpha: tint.a) : tint;
}

/// The color a hand-painted icon (a [CustomPainter] glyph) is drawn in, so it
/// matches every [AppIcon]: the quiet icon color for any theme color, at the
/// opacity [requested] carries (a disabled icon stays dimmed), else the
/// enclosing [IconTheme]'s color treated the same way.
Color iconTint(BuildContext context, [Color? requested]) {
  return _uniformTint(
    AppColors.resolve(context),
    requested ?? IconTheme.of(context).color,
  );
}

/// Loads an icon's SVG with every stroke set so that it is drawn
/// [kIconStrokeWidth] logical pixels wide at [size]: the SVG is on a 24 unit
/// grid, so a larger icon needs a thinner stroke in its own units.
class _LineIconLoader extends SvgAssetLoader {
  const _LineIconLoader(super.assetName, {required this.size});

  final double size;

  /// The stroke, in the SVG's own units, that comes out as the icon weight.
  double get _units =>
      double.parse((kIconStrokeWidth * 24 / size).toStringAsFixed(3));

  @override
  String provideSvg(ByteData? message) {
    return super
        .provideSvg(message)
        .replaceAll(RegExp(r'stroke-width="[^"]*"'), 'stroke-width="$_units"');
  }

  @override
  SvgCacheKey cacheKey(BuildContext? context) {
    final SvgCacheKey base = super.cacheKey(context);
    return SvgCacheKey(
      theme: base.theme,
      colorMapper: base.colorMapper,
      keyData: (base.keyData, _units),
    );
  }

  @override
  int get hashCode => Object.hash(super.hashCode, _units);

  @override
  bool operator ==(Object other) =>
      other is _LineIconLoader && super == other && other._units == _units;
}

/// An Etonia line icon, drawn from an SVG on a 24 x 24 grid with a 2px safe
/// margin and straight, architectural strokes with round ends, always
/// [kIconStrokeWidth] wide. It is tinted
/// with `currentColor`, so it takes [color], or else the primary text color,
/// and with [applyPencilTexture] the straight lines pick up the grain of
/// graphite (see [PencilTexture]) without their geometry moving.
class EtoniaIcon extends StatelessWidget {
  const EtoniaIcon(
    this.name, {
    super.key,
    this.size = 22,
    this.color,
    this.applyPencilTexture = false,
  });

  /// The asset under `assets/icons/`, without its extension: `tools/pen`.
  final String name;
  final double size;
  final Color? color;
  final bool applyPencilTexture;

  @override
  Widget build(BuildContext context) {
    final Color tint = color ?? AppColors.resolve(context).textSecondary;
    return PencilMask(
      enabled: applyPencilTexture,
      child: SvgPicture(
        _LineIconLoader('assets/icons/$name.svg', size: size),
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      ),
    );
  }
}

/// The Etonia SVG icons as [IconData], so every `IconData` field and
/// parameter keeps working. Each is a code point in a private family that no
/// font backs: draw it with [AppIcon], because a plain [Icon] would show an
/// empty glyph.
abstract final class EtoniaGlyphs {
  static const String family = 'EtoniaIcons';
  static const int _first = 0xE000;

  /// The asset of each glyph under `assets/icons/`, in code point order.
  static const List<String> assets = <String>[
    'actions/check',
    'actions/copy',
    'actions/plus',
    'actions/share',
    'actions/sparkle',
    'library/folder',
    'library/folder_open',
    'library/new_folder',
    'library/new_note',
    'library/note',
    'library/search',
    'library/sort',
    'library/trash',
    'navigation/back',
    'navigation/close',
    'navigation/forward',
    'navigation/more',
    'navigation/settings',
    'navigation/sidebar',
    'tools/eraser',
    'tools/highlighter',
    'tools/lasso',
    'tools/pen',
    'tools/pencil_sprout',
    'tools/redo',
    'tools/ruler',
    'tools/undo',
    'tools/erase_area',
    'library/books',
    'library/blackboard',
  ];

  static const IconData check = IconData(0xE000, fontFamily: family);
  static const IconData copy = IconData(0xE001, fontFamily: family);
  static const IconData plus = IconData(0xE002, fontFamily: family);
  static const IconData share = IconData(0xE003, fontFamily: family);
  static const IconData sparkle = IconData(0xE004, fontFamily: family);
  static const IconData folder = IconData(0xE005, fontFamily: family);
  static const IconData folderOpen = IconData(0xE006, fontFamily: family);
  static const IconData newFolder = IconData(0xE007, fontFamily: family);
  static const IconData newNote = IconData(0xE008, fontFamily: family);
  static const IconData note = IconData(0xE009, fontFamily: family);
  static const IconData search = IconData(0xE00A, fontFamily: family);
  static const IconData sort = IconData(0xE00B, fontFamily: family);
  static const IconData trash = IconData(0xE00C, fontFamily: family);
  static const IconData back = IconData(0xE00D, fontFamily: family);
  static const IconData close = IconData(0xE00E, fontFamily: family);
  static const IconData forward = IconData(0xE00F, fontFamily: family);
  static const IconData more = IconData(0xE010, fontFamily: family);
  static const IconData settings = IconData(0xE011, fontFamily: family);
  static const IconData sidebar = IconData(0xE012, fontFamily: family);
  static const IconData eraser = IconData(0xE013, fontFamily: family);
  static const IconData highlighter = IconData(0xE014, fontFamily: family);
  static const IconData lasso = IconData(0xE015, fontFamily: family);
  static const IconData pen = IconData(0xE016, fontFamily: family);
  static const IconData pencilSprout = IconData(0xE017, fontFamily: family);
  static const IconData redo = IconData(0xE018, fontFamily: family);
  static const IconData ruler = IconData(0xE019, fontFamily: family);
  static const IconData undo = IconData(0xE01A, fontFamily: family);
  static const IconData eraseArea = IconData(0xE01B, fontFamily: family);

  /// Two books standing, a third leaning on them: the Library.
  static const IconData books = IconData(0xE01C, fontFamily: family);

  /// A blackboard on a stand: Classes in Study Desk.
  static const IconData blackboard = IconData(0xE01D, fontFamily: family);

  /// The asset [icon] stands for, or null for an ordinary font icon.
  static String? assetOf(IconData icon) {
    if (icon.fontFamily != family) return null;
    final int index = icon.codePoint - _first;
    return index >= 0 && index < assets.length ? assets[index] : null;
  }
}

/// An [Icon] that also draws [EtoniaGlyphs], and draws the Material and
/// Cupertino glyphs listed in [LineIcons] as 1.3px line drawings too. Anything
/// else is an ordinary [Icon], so it is a drop-in replacement and finders for
/// [Icon] still match.
///
/// Unless [uniform] is false, every icon is drawn the same: [kIconSize] wide,
/// [kIconStrokeWidth] thick, and in the quiet icon color, whatever size or
/// theme color the caller asked for. Two things stay as asked: a color that is
/// not one of the theme's own (a color the user picked, or the contrast color
/// on a filled button), and an illustration larger than [kIllustrationSize].
/// The close button on a tab passes `uniform: false`.
class AppIcon extends Icon {
  const AppIcon(
    super.icon, {
    super.key,
    super.size,
    super.color,
    super.semanticLabel,
    super.fill,
    super.weight,
    super.grade,
    super.opticalSize,
    super.applyTextScaling,
    super.textDirection,
    super.shadows,
    super.blendMode,
    this.uniform = true,
  });

  /// Whether this icon takes the one size and color every icon shares.
  final bool uniform;

  @override
  Widget build(BuildContext context) {
    final IconData? data = icon;
    final String? asset = data == null
        ? null
        : EtoniaGlyphs.assetOf(data) ?? LineIcons.assetOf(data);
    if (asset == null) return super.build(context);
    final IconThemeData theme = IconTheme.of(context);
    double dimension = size ?? theme.size ?? 24;
    Color? tint = color ?? theme.color;
    if (uniform) {
      if (dimension <= kIllustrationSize) dimension = kIconSize;
      tint = _uniformTint(AppColors.resolve(context), tint);
    }
    final double? opacity = theme.opacity;
    if (tint != null && opacity != null && opacity != 1) {
      tint = tint.withValues(alpha: tint.a * opacity);
    }
    return Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      excludeSemantics: true,
      child: EtoniaIcon(asset, size: dimension, color: tint),
    );
  }
}
