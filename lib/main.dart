import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/greatnote_app.dart';
import 'backend/backend_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  await BackendService.initialize();
  runApp(const GreatnoteApp());
}
