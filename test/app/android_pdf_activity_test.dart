import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test('incoming PDFs reuse the main activity and its PDFium worker', () {
    final manifest = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final activities = manifest
        .findAllElements('activity')
        .where(
          (activity) =>
              activity.getAttribute('android:name') == '.MainActivity',
        );
    expect(activities, hasLength(1));
    final main = activities.single;
    // A second FlutterEngine installs isolate-local font callbacks into
    // process-global PDFium. Returning to the first engine can then SIGABRT.
    // singleTop only reuses the activity at the top of the caller's task.
    expect(main.getAttribute('android:launchMode'), 'singleTask');
    final actions = main
        .findAllElements('action')
        .map((action) => action.getAttribute('android:name'));
    expect(
      actions,
      containsAll(<String>[
        'android.intent.action.MAIN',
        'android.intent.action.VIEW',
        'android.intent.action.SEND',
        'android.intent.action.SEND_MULTIPLE',
      ]),
    );
  });
}
