import 'dart:math' as math;

import '../../shared/widgets/etonia_mascot.dart';

/// Where Etonia rests in the library, and what she does there.
///
/// She lives in one folder at a time: its card, among its neighbours, has her
/// head peeking over its back, and inside it she sits in the bottom left corner
/// playing one animation. The folder and the animation are chosen anew each
/// time the library is entered, as the app opens and as a note or the Study
/// Desk is left. A spot is a folder's id, or null for the library itself, so
/// someone with no folders yet still finds her.
class EtoniaRest {
  const EtoniaRest(this.spot, this.clip);

  /// The folder she rests in; null is the library itself.
  final String? spot;

  /// What she does there.
  final EtoniaClip clip;

  /// Whether she rests in the library at all. Tests that do not look for her
  /// turn it off, so she is never in their way.
  static bool enabled = true;

  /// Chooses among the spots and the clips; tests replace it.
  static math.Random random = math.Random();

  /// The clips that suit sitting still in a corner: the whole of her, in place.
  /// Running carries her off, and the other two are cut off behind a card.
  static const List<EtoniaClip> clips = <EtoniaClip>[
    EtoniaClip.lookAround,
    EtoniaClip.think,
    EtoniaClip.hop,
    EtoniaClip.write,
    EtoniaClip.grade,
  ];

  /// A spot among the library and each of [folders], every one as likely, and
  /// one of [clips] to play there.
  static EtoniaRest pick(Iterable<String> folders) {
    final List<String?> spots = <String?>[null, ...folders];
    return EtoniaRest(
      spots[random.nextInt(spots.length)],
      clips[random.nextInt(clips.length)],
    );
  }
}
