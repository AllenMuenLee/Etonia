import 'dart:ui';

import '../document_io/document_models.dart';
import '../ink/stroke.dart';
import '../sticky/sticky_note.dart';
import '../text/note_text.dart';

/// The box round everything on a page, in page units, or null when the
/// page is empty.
Rect? pageContentBounds({
  Iterable<Stroke> strokes = const <Stroke>[],
  Iterable<NoteImageElement> images = const <NoteImageElement>[],
  Iterable<StickyNoteElement> stickies = const <StickyNoteElement>[],
  Iterable<NoteTextElement> texts = const <NoteTextElement>[],
}) {
  Rect? reach;
  void include(Rect bounds) {
    if (!bounds.isFinite) return;
    reach = reach?.expandToInclude(bounds) ?? bounds;
  }

  strokes.map((Stroke s) => s.bounds).forEach(include);
  images.map((NoteImageElement e) => e.bounds).forEach(include);
  stickies.map((StickyNoteElement e) => e.bounds).forEach(include);
  texts.map((NoteTextElement e) => e.bounds).forEach(include);
  return reach;
}
