import 'handwriting_style.dart';
import 'stroke_profile.dart';

/// The hands the assistant can write notes in: five made from the
/// built-in font, and the writer's own, made from every letter written out.
enum HandwritingFont {
  normal('Normal', 'An easy, everyday hand', HandwritingStyle.standard),
  cursive(
    'Cursive',
    'Slanted, looped and joined up',
    HandwritingStyle(
      slant: 0.3,
      widthScale: 1.08,
      xHeight: 0.56,
      descenderScale: 1.1,
      descenderHook: 2.4,
      descenderLoop: 1,
      loopAspect: 0.9,
      wordSpacing: 6,
      baselineJitter: 0.08,
      sizeJitter: 0.02,
      joined: true,
    ),
  ),
  print(
    'Print',
    'Upright and neat, each letter on its own',
    HandwritingStyle(
      slant: 0,
      widthScale: 1.08,
      xHeight: 0.66,
      descenderHook: 0.8,
      loopAspect: 1.05,
      lineProfile: StrokeProfile(<double>[0.004]),
      wordSpacing: 5.6,
      baselineJitter: 0.04,
      sizeJitter: 0.01,
    ),
  ),
  rounded(
    'Rounded',
    'Wide, round and friendly',
    HandwritingStyle(
      slant: -0.03,
      widthScale: 1.22,
      xHeight: 0.72,
      descenderScale: 0.85,
      descenderHook: 1.8,
      loopAspect: 1.4,
      wordSpacing: 6.2,
      baselineJitter: 0.1,
      sizeJitter: 0.02,
    ),
  ),
  quick(
    'Quick',
    'Small and fast, like notes in a lecture',
    HandwritingStyle(
      slant: 0.24,
      widthScale: 0.95,
      xHeight: 0.52,
      descenderScale: 1.1,
      descenderHook: 2.2,
      loopAspect: 0.8,
      lineProfile: StrokeProfile(<double>[0.03, -0.012]),
      crossTilt: -0.12,
      wordSpacing: 4.4,
      baselineJitter: 0.35,
      sizeJitter: 0.07,
    ),
  ),

  /// The writer's own letters; its style is whatever they wrote.
  custom('Your handwriting', 'Write 15 letters to make your own', null);

  const HandwritingFont(this.label, this.description, this.style);

  final String label;
  final String description;

  /// The hand this font writes in; null for [custom], which is the
  /// writer's.
  final HandwritingStyle? style;

  /// The fonts ready to choose, without writing anything.
  static List<HandwritingFont> get presets => <HandwritingFont>[
    for (final HandwritingFont font in values)
      if (font != custom) font,
  ];

  static HandwritingFont? byName(Object? name) {
    for (final HandwritingFont font in values) {
      if (font.name == name) return font;
    }
    return null;
  }
}
