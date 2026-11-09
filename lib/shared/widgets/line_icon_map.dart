import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// The line drawing that stands in for each font glyph the app asks for.
///
/// Font glyphs are filled shapes with no line weight of their own, so
/// [AppIcon] draws these SVGs instead (every one at the same 1.3px stroke) for
/// every [Icons] and [CupertinoIcons] glyph named here. An asset is under
/// `assets/icons/`, as in `EtoniaGlyphs.assets`.
abstract final class LineIcons {
  static String _key(IconData icon) =>
      '${icon.fontFamily}/${icon.fontPackage}/${icon.codePoint}';

  static final Map<String, String> _assets = <String, String>{
    // Marks and navigation.
    _key(Icons.check_rounded): 'actions/check',
    _key(Icons.close_rounded): 'navigation/close',
    _key(Icons.chevron_left_rounded): 'navigation/back',
    _key(Icons.chevron_right_rounded): 'navigation/forward',
    _key(CupertinoIcons.chevron_right): 'system/chevron_right',
    _key(CupertinoIcons.chevron_left): 'system/chevron_left',
    _key(CupertinoIcons.chevron_down): 'system/chevron_down',
    _key(CupertinoIcons.chevron_up): 'system/chevron_up',
    _key(CupertinoIcons.xmark_circle_fill): 'system/x_circle',
    _key(CupertinoIcons.minus): 'system/minus',
    _key(CupertinoIcons.fullscreen): 'system/fullscreen',
    _key(CupertinoIcons.fullscreen_exit): 'system/fullscreen_exit',
    _key(CupertinoIcons.arrow_up): 'system/arrow_up',
    _key(CupertinoIcons.arrow_up_left_arrow_down_right): 'system/expand_diag',
    _key(CupertinoIcons.line_horizontal_3): 'system/grip',
    _key(CupertinoIcons.sidebar_right): 'system/sidebar_right',

    // Library.
    _key(CupertinoIcons.book): 'system/book',
    _key(CupertinoIcons.chat_bubble): 'system/chat',
    _key(CupertinoIcons.folder): 'library/folder',
    _key(Icons.folder_rounded): 'library/folder',
    _key(Icons.local_library_rounded): 'library/books',
    _key(CupertinoIcons.paintbrush): 'system/paintbrush',
    _key(CupertinoIcons.arrow_counterclockwise): 'tools/undo',
    _key(CupertinoIcons.trash_slash): 'system/trash_off',
    _key(CupertinoIcons.list_bullet): 'system/list',
    _key(Icons.view_list_rounded): 'system/list',
    _key(CupertinoIcons.square_grid_2x2): 'system/grid',
    _key(Icons.grid_view_rounded): 'system/grid',
    _key(CupertinoIcons.checkmark_circle): 'system/check_circle',
    _key(Icons.check_circle_rounded): 'system/check_circle',
    _key(CupertinoIcons.checkmark_square): 'system/check_square',
    _key(CupertinoIcons.square): 'system/square',
    _key(CupertinoIcons.rectangle_stack): 'system/layers',
    _key(CupertinoIcons.doc): 'system/doc',
    _key(CupertinoIcons.pencil_outline): 'tools/pen',
    _key(Icons.assignment_rounded): 'system/clipboard',
    _key(Icons.assignment_turned_in_rounded): 'system/clipboard_check',

    // Google Drive and account.
    _key(CupertinoIcons.cloud): 'system/cloud',
    _key(CupertinoIcons.cloud_upload): 'system/cloud_up',
    _key(CupertinoIcons.cloud_download): 'system/cloud_down',
    _key(CupertinoIcons.person_crop_circle): 'system/user_circle',
    _key(CupertinoIcons.exclamationmark_triangle): 'system/warning',
    _key(Icons.warning_amber_rounded): 'system/warning',
    _key(CupertinoIcons.lock_fill): 'system/lock',

    // Editor.
    _key(CupertinoIcons.square_on_square): 'system/sticky',
    _key(CupertinoIcons.lasso): 'tools/lasso',
    _key(CupertinoIcons.scribble): 'system/scribble',
    _key(CupertinoIcons.hand_draw): 'tools/pen',
    _key(CupertinoIcons.play_circle): 'system/play_circle',
    _key(CupertinoIcons.scissors): 'system/scissors',
    _key(CupertinoIcons.doc_on_clipboard): 'system/clipboard',
    _key(CupertinoIcons.slider_horizontal_3): 'system/sliders',
    _key(CupertinoIcons.photo): 'system/image',
    _key(CupertinoIcons.camera): 'system/camera',
    _key(CupertinoIcons.infinite): 'system/infinity',
    _key(CupertinoIcons.eye): 'system/eye',
    _key(CupertinoIcons.eye_slash): 'system/eye_off',
    _key(CupertinoIcons.mic): 'system/mic',
    _key(CupertinoIcons.mic_fill): 'system/mic',
    _key(CupertinoIcons.play_fill): 'system/play',
    _key(CupertinoIcons.pause_fill): 'system/pause',
    _key(CupertinoIcons.stop_fill): 'system/stop',
    _key(CupertinoIcons.captions_bubble): 'system/captions',
    _key(CupertinoIcons.captions_bubble_fill): 'system/captions',
    _key(CupertinoIcons.gobackward_15): 'system/back_15',
    _key(CupertinoIcons.goforward_15): 'system/forward_15',
    _key(Icons.copy_rounded): 'actions/copy',
    _key(Icons.format_list_bulleted_rounded): 'system/list',
    _key(Icons.format_list_numbered_rounded): 'system/list_numbers',
    _key(Icons.format_align_left_rounded): 'system/align_left',
    _key(Icons.format_align_center_rounded): 'system/align_center',
    _key(Icons.format_align_right_rounded): 'system/align_right',

    // Study desk and answers.
    _key(Icons.zoom_in_rounded): 'system/zoom_in',
    _key(Icons.schema_rounded): 'system/schema',
    _key(Icons.push_pin_rounded): 'system/pin',
    _key(Icons.school_rounded): 'system/school',
    _key(Icons.functions_rounded): 'system/sigma',
    _key(Icons.info_outline_rounded): 'system/info',
    _key(Icons.error_rounded): 'system/alert_circle',
    _key(Icons.refresh_rounded): 'system/refresh',
    _key(Icons.radio_button_off_rounded): 'system/radio_off',
    _key(Icons.radio_button_checked_rounded): 'system/radio_on',
    _key(Icons.circle_rounded): 'system/dot',
  };

  /// The asset that draws [icon] as a line, or null when it has none.
  static String? assetOf(IconData icon) => _assets[_key(icon)];

  /// Every asset named, for checking that each exists.
  static Iterable<String> get assets => _assets.values.toSet();
}
