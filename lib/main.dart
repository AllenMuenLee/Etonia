import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/greatnote_app.dart';
import 'backend/backend_service.dart';
import 'features/library/file_note_repository.dart';
import 'features/library/library_screen.dart';
import 'shared/widgets/processing.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // AI notation writes with glyphs from EMS Readability.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(<String>[
      'EMS Readability',
    ], await rootBundle.loadString('third_party/ems_readability/OFL.txt'));
  });
  runApp(const GreatnoteApp(home: _StartupHome()));
}

class _StartupHome extends StatefulWidget {
  const _StartupHome();

  @override
  State<_StartupHome> createState() => _StartupHomeState();
}

class _StartupHomeState extends State<_StartupHome> {
  /// The device's library, read from disk while the platform services
  /// start rather than after them.
  late final Future<FileNoteRepository> _library;
  late final Future<void> _ready = _initializeAfterFirstFrame();

  Future<void> _initializeAfterFirstFrame() async {
    // Put a real Flutter frame on screen before platform services start.
    await WidgetsBinding.instance.endOfFrame;
    // Its failure is the library's to show, once it is asked for.
    _library = FileNoteRepository.openDefault()..ignore();
    // PDF and account bootstrapping are independent. Starting them together
    // keeps readiness on the longer path instead of paying both serially.
    await Future.wait<void>(<Future<void>>[
      pdfrxFlutterInitialize(),
      BackendService.initialize(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
        // While Etonia starts, its name comes forward; the library then
        // comes forward over it.
        return LoadingReveal(
          effect: RevealEffect.zoom,
          timing: LoadTimings.startup,
          semanticsLabel: 'Starting Etonia',
          placeholder: const StartupWordmark(),
          child: switch (snapshot.connectionState) {
            ConnectionState.done when !snapshot.hasError => LibraryHome(
              key: const ValueKey<String>('library-home'),
              opening: _library,
            ),
            ConnectionState.done => const Scaffold(
              key: ValueKey<String>('startup-error'),
              body: Center(child: Text("Etonia couldn't finish starting.")),
            ),
            _ => null,
          },
        );
      },
    );
  }
}

/// The app's logo, quietly, while it starts.
class StartupWordmark extends StatelessWidget {
  const StartupWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      key: ValueKey<String>('startup-loading'),
      backgroundColor: Colors.black,
      body: Center(
        child: ExcludeSemantics(
          child: Image(
            image: AssetImage('assets/icon/etonia.png'),
            width: 200,
            height: 200,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
