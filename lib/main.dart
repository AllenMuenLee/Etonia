import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/greatnote_app.dart';
import 'backend/backend_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // AI notation writes with glyphs from EMS Readability.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(<String>[
      'EMS Readability',
    ], await rootBundle.loadString('third_party/ems_readability/OFL.txt'));
  });
  await pdfrxFlutterInitialize();
  await BackendService.initialize();
  runApp(const GreatnoteApp());
}
