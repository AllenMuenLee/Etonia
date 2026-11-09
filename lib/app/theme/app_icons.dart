import 'package:flutter/cupertino.dart';

import '../../shared/widgets/etonia_icon.dart';

export '../../shared/widgets/etonia_icon.dart'
    show AppIcon, EtoniaGlyphs, EtoniaIcon, iconTint, kIconSize, kIconStrokeWidth;

/// Every glyph the app shows, in one place. The core set is Etonia's own
/// hand-drawn SVG line icons ([EtoniaGlyphs], drawn by [AppIcon]); the
/// rest are light [CupertinoIcons] of a matching weight, so the chrome reads
/// as one family. Widgets name what an icon means here, never the glyph.
abstract final class AppIcons {
  // Navigation.
  static const IconData back = EtoniaGlyphs.back;
  static const IconData forward = EtoniaGlyphs.forward;
  static const IconData previous = EtoniaGlyphs.back;
  static const IconData next = EtoniaGlyphs.forward;
  static const IconData disclosure = CupertinoIcons.chevron_right;
  static const IconData expand = CupertinoIcons.chevron_down;
  static const IconData sidebar = EtoniaGlyphs.sidebar;
  static const IconData close = EtoniaGlyphs.close;
  static const IconData clear = CupertinoIcons.xmark_circle_fill;
  static const IconData more = EtoniaGlyphs.more;
  static const IconData settings = EtoniaGlyphs.settings;
  static const IconData fullscreen = CupertinoIcons.fullscreen;
  static const IconData exitFullscreen = CupertinoIcons.fullscreen_exit;

  // Marks.
  static const IconData check = EtoniaGlyphs.check;
  static const IconData add = EtoniaGlyphs.plus;
  static const IconData remove = CupertinoIcons.minus;

  // Library.
  static const IconData library = EtoniaGlyphs.books;
  static const IconData studyDesk = CupertinoIcons.book;
  static const IconData chat = CupertinoIcons.chat_bubble;
  static const IconData folder = EtoniaGlyphs.folder;
  static const IconData folderOpen = EtoniaGlyphs.folderOpen;
  static const IconData newFolder = EtoniaGlyphs.newFolder;
  static const IconData blackboard = EtoniaGlyphs.blackboard;
  static const IconData move = CupertinoIcons.folder;
  static const IconData rename = EtoniaGlyphs.pencilSprout;
  static const IconData color = CupertinoIcons.paintbrush;
  static const IconData duplicate = EtoniaGlyphs.copy;
  static const IconData share = EtoniaGlyphs.share;
  static const IconData delete = EtoniaGlyphs.trash;
  static const IconData trash = EtoniaGlyphs.trash;
  static const IconData restore = CupertinoIcons.arrow_counterclockwise;
  static const IconData deleteForever = CupertinoIcons.trash_slash;
  static const IconData search = EtoniaGlyphs.search;
  static const IconData sort = EtoniaGlyphs.sort;
  static const IconData listView = CupertinoIcons.list_bullet;
  static const IconData gridView = CupertinoIcons.square_grid_2x2;
  static const IconData select = CupertinoIcons.checkmark_circle;
  static const IconData selectAll = CupertinoIcons.checkmark_square;
  static const IconData deselectAll = CupertinoIcons.square;
  static const IconData note = EtoniaGlyphs.note;
  static const IconData newNote = EtoniaGlyphs.newNote;
  static const IconData template = CupertinoIcons.rectangle_stack;
  static const IconData pdf = CupertinoIcons.doc;
  static const IconData goodnotes = CupertinoIcons.pencil_outline;
  static const IconData emptyLibrary = EtoniaGlyphs.newNote;
  static const IconData noResults = EtoniaGlyphs.search;

  // Google Drive.
  static const IconData cloud = CupertinoIcons.cloud;
  static const IconData cloudUpload = CupertinoIcons.cloud_upload;
  static const IconData cloudDownload = CupertinoIcons.cloud_download;
  static const IconData account = CupertinoIcons.person_crop_circle;
  static const IconData warning = CupertinoIcons.exclamationmark_triangle;

  // Plans and AI models.
  static const IconData plans = EtoniaGlyphs.sparkle;
  static const IconData sparkle = EtoniaGlyphs.sparkle;
  static const IconData lock = CupertinoIcons.lock_fill;
  static const IconData model = CupertinoIcons.chevron_down;

  // Editor.
  static const IconData pen = EtoniaGlyphs.pen;
  static const IconData highlighter = EtoniaGlyphs.highlighter;
  static const IconData stickyNote = CupertinoIcons.square_on_square;
  static const IconData lasso = CupertinoIcons.lasso;
  static const IconData eraseArea = EtoniaGlyphs.eraseArea;
  static const IconData eraseStroke = CupertinoIcons.scribble;
  static const IconData notation = CupertinoIcons.hand_draw;
  static const IconData animation = CupertinoIcons.play_circle;
  // The palette's extension toggle: along a row it points right to open and
  // left to close; down a column, down and up.
  static const IconData toolsExpandAcross = CupertinoIcons.chevron_right;
  static const IconData toolsCollapseAcross = CupertinoIcons.chevron_left;
  static const IconData toolsExpandDown = CupertinoIcons.chevron_down;
  static const IconData toolsCollapseDown = CupertinoIcons.chevron_up;
  static const IconData customizeToolbar = EtoniaGlyphs.settings;
  static const IconData dragHandle = CupertinoIcons.line_horizontal_3;
  static const IconData undo = EtoniaGlyphs.undo;
  static const IconData redo = EtoniaGlyphs.redo;
  static const IconData copy = EtoniaGlyphs.copy;
  static const IconData cut = CupertinoIcons.scissors;
  static const IconData paste = CupertinoIcons.doc_on_clipboard;
  static const IconData tune = CupertinoIcons.slider_horizontal_3;
  static const IconData insertImage = CupertinoIcons.photo;
  static const IconData camera = CupertinoIcons.camera;
  static const IconData addPage = EtoniaGlyphs.note;
  static const IconData infinite = CupertinoIcons.infinite;
  static const IconData grows = CupertinoIcons.arrow_up_left_arrow_down_right;
  static const IconData show = CupertinoIcons.eye;
  static const IconData hide = CupertinoIcons.eye_slash;
  static const IconData send = CupertinoIcons.arrow_up;
  static const IconData microphone = CupertinoIcons.mic;
  static const IconData microphoneActive = CupertinoIcons.mic_fill;
  static const IconData play = CupertinoIcons.play_fill;
  static const IconData pause = CupertinoIcons.pause_fill;
  static const IconData stop = CupertinoIcons.stop_fill;
  static const IconData transcribe = CupertinoIcons.captions_bubble;
  static const IconData transcript = CupertinoIcons.captions_bubble_fill;
  static const IconData backward15 = CupertinoIcons.gobackward_15;
  static const IconData forward15 = CupertinoIcons.goforward_15;
  static const IconData up = CupertinoIcons.arrow_up;
  static const IconData panelLeft = EtoniaGlyphs.sidebar;
  static const IconData panelRight = CupertinoIcons.sidebar_right;
}
