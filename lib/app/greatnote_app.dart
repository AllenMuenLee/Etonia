import 'package:flutter/material.dart';

import '../features/library/library_screen.dart';
import '../features/library/note_repository.dart';
import '../shared/widgets/motion_warm_up.dart';
import 'theme/app_theme.dart';
import 'theme/app_tokens.dart';

class GreatnoteApp extends StatelessWidget {
  const GreatnoteApp({
    super.key,
    this.themeMode = ThemeMode.system,
    this.home,
    this.repository,
  });

  static const String title = 'Etonia';

  final ThemeMode themeMode;

  /// Replaces the default screen. Used by tests and development harnesses.
  final Widget? home;

  /// The library the home screen shows. Without one, the library on this
  /// device is opened.
  final NoteRepository? repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      builder: (BuildContext context, Widget? child) => MotionWarmUp(
        child: GlassBackdrop(child: child ?? const SizedBox.shrink()),
      ),
      home: home ?? LibraryHome(repository: repository),
    );
  }
}
