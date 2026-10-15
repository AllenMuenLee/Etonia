import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/greatnote_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize();
  runApp(const GreatnoteApp());
}
