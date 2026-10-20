import 'package:flutter/cupertino.dart';

/// Every glyph the app shows, in one place: SF Symbols–style line icons
/// from [CupertinoIcons], light and evenly weighted, so the chrome reads as
/// one family. Widgets name what an icon means here, never the glyph.
abstract final class AppIcons {
  // Navigation.
  static const IconData back = CupertinoIcons.chevron_back;
  static const IconData forward = CupertinoIcons.chevron_right;
  static const IconData previous = CupertinoIcons.chevron_left;
  static const IconData next = CupertinoIcons.chevron_right;
  static const IconData disclosure = CupertinoIcons.chevron_right;
  static const IconData expand = CupertinoIcons.chevron_down;
  static const IconData sidebar = CupertinoIcons.sidebar_left;
  static const IconData close = CupertinoIcons.xmark;
  static const IconData clear = CupertinoIcons.xmark_circle_fill;
  static const IconData more = CupertinoIcons.ellipsis;
  static const IconData settings = CupertinoIcons.gear;

  // Marks.
  static const IconData check = CupertinoIcons.checkmark;
  static const IconData add = CupertinoIcons.plus;

  // Library.
  static const IconData library = CupertinoIcons.book;
  static const IconData folder = CupertinoIcons.folder_fill;
  static const IconData folderOpen = CupertinoIcons.folder_open;
  static const IconData newFolder = CupertinoIcons.folder_badge_plus;
  static const IconData move = CupertinoIcons.folder;
  static const IconData rename = CupertinoIcons.pencil;
  static const IconData color = CupertinoIcons.paintbrush;
  static const IconData duplicate = CupertinoIcons.plus_square_on_square;
  static const IconData share = CupertinoIcons.square_arrow_up;
  static const IconData delete = CupertinoIcons.trash;
  static const IconData trash = CupertinoIcons.trash;
  static const IconData restore = CupertinoIcons.arrow_counterclockwise;
  static const IconData deleteForever = CupertinoIcons.trash_slash;
  static const IconData search = CupertinoIcons.search;
  static const IconData sort = CupertinoIcons.arrow_up_arrow_down;
  static const IconData listView = CupertinoIcons.list_bullet;
  static const IconData gridView = CupertinoIcons.square_grid_2x2;
  static const IconData select = CupertinoIcons.checkmark_circle;
  static const IconData selectAll = CupertinoIcons.checkmark_square;
  static const IconData deselectAll = CupertinoIcons.square;
  static const IconData note = CupertinoIcons.doc_text;
  static const IconData newNote = CupertinoIcons.square_pencil;
  static const IconData pdf = CupertinoIcons.doc;
  static const IconData goodnotes = CupertinoIcons.pencil_outline;
  static const IconData emptyLibrary = CupertinoIcons.square_pencil;
  static const IconData noResults = CupertinoIcons.search;

  // Google Drive.
  static const IconData cloud = CupertinoIcons.cloud;
  static const IconData cloudUpload = CupertinoIcons.cloud_upload;
  static const IconData cloudDownload = CupertinoIcons.cloud_download;
  static const IconData account = CupertinoIcons.person_crop_circle;
  static const IconData warning = CupertinoIcons.exclamationmark_triangle;

  // Plans and AI models.
  static const IconData plans = CupertinoIcons.sparkles;
  static const IconData lock = CupertinoIcons.lock_fill;
  static const IconData model = CupertinoIcons.chevron_down;

  // Editor.
  static const IconData pen = CupertinoIcons.pencil_outline;
  static const IconData highlighter = CupertinoIcons.paintbrush;
  static const IconData stickyNote = CupertinoIcons.square_on_square;
  static const IconData lasso = CupertinoIcons.lasso;
  static const IconData undo = CupertinoIcons.arrow_uturn_left;
  static const IconData redo = CupertinoIcons.arrow_uturn_right;
  static const IconData copy = CupertinoIcons.doc_on_doc;
  static const IconData cut = CupertinoIcons.scissors;
  static const IconData paste = CupertinoIcons.doc_on_clipboard;
  static const IconData tune = CupertinoIcons.slider_horizontal_3;
  static const IconData insertImage = CupertinoIcons.photo;
  static const IconData camera = CupertinoIcons.camera;
  static const IconData addPage = CupertinoIcons.doc_text;
  static const IconData infinite = CupertinoIcons.infinite;
  static const IconData grows = CupertinoIcons.arrow_up_left_arrow_down_right;
  static const IconData show = CupertinoIcons.eye;
  static const IconData hide = CupertinoIcons.eye_slash;
  static const IconData send = CupertinoIcons.arrow_up;
  static const IconData microphone = CupertinoIcons.mic;
  static const IconData microphoneActive = CupertinoIcons.mic_fill;
  static const IconData up = CupertinoIcons.arrow_up;
  static const IconData panelLeft = CupertinoIcons.sidebar_left;
  static const IconData panelRight = CupertinoIcons.sidebar_right;
}
