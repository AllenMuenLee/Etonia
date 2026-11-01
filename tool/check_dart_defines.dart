// Fails a release build whose dart_defines.json is missing what the app
// needs, rather than shipping an app whose sign-in or backend is not set up.
// Release pipelines decode the file from a secret, which can fall behind the
// local one; this runs right after it is written:
//   dart run tool/check_dart_defines.dart --platform ios dart_defines.json
import 'dart:convert';
import 'dart:io';

const List<String> _shared = <String>[
  'SUPABASE_URL',
  'SUPABASE_PUBLISHABLE_KEY',
  'GOOGLE_OAUTH_SERVER_CLIENT_ID',
];

const Map<String, List<String>> _required = <String, List<String>>{
  'ios': <String>[..._shared, 'GOOGLE_OAUTH_IOS_CLIENT_ID'],
  'android': _shared,
};

/// Debug and development-only keys a store build must not carry.
const List<String> _forbidden = <String>['IAP_DEBUG_PLAN', 'GEMINI_API_KEY'];

const String _clientIdSuffix = '.apps.googleusercontent.com';

void main(List<String> args) {
  final int platformFlag = args.indexOf('--platform');
  final String? platform = platformFlag >= 0 && platformFlag + 1 < args.length
      ? args[platformFlag + 1]
      : null;
  final List<String> paths = <String>[
    for (int i = 0; i < args.length; i++)
      if (i != platformFlag && i != platformFlag + 1) args[i],
  ];
  if (platform == null || !_required.containsKey(platform)) {
    _fail('Usage: --platform ${_required.keys.join('|')} <dart_defines.json>');
  }
  final File file = File(paths.isEmpty ? 'dart_defines.json' : paths.first);
  if (!file.existsSync() || file.lengthSync() == 0) {
    _fail('${file.path} is missing or empty; is DART_DEFINES_B64 set?');
  }

  final Map<String, Object?> defines;
  try {
    defines = (jsonDecode(file.readAsStringSync()) as Map)
        .cast<String, Object?>();
  } on Object catch (error) {
    _fail('${file.path} is not a JSON object: $error');
  }

  String value(String key) => (defines[key] ?? '').toString().trim();

  final List<String> problems = <String>[
    for (final String key in _required[platform]!)
      if (value(key).isEmpty) '$key is missing or empty',
    for (final String key in _forbidden)
      if (value(key).isNotEmpty) '$key must not be set in a release build',
    for (final String key in defines.keys)
      if (key.startsWith('GOOGLE_OAUTH_') &&
          value(key).isNotEmpty &&
          !value(key).endsWith(_clientIdSuffix))
        '$key does not look like an OAuth client ID',
  ];

  // iOS returns from Google's sign-in page through the reversed client ID,
  // so it must be a URL scheme of the app.
  final String iosClientId = value('GOOGLE_OAUTH_IOS_CLIENT_ID');
  if (platform == 'ios' && iosClientId.endsWith(_clientIdSuffix)) {
    final String scheme =
        'com.googleusercontent.apps.'
        '${iosClientId.substring(0, iosClientId.length - _clientIdSuffix.length)}';
    final File plist = File('ios/Runner/Info.plist');
    if (!plist.existsSync() || !plist.readAsStringSync().contains(scheme)) {
      problems.add(
        'ios/Runner/Info.plist has no URL scheme $scheme for '
        'GOOGLE_OAUTH_IOS_CLIENT_ID',
      );
    }
  }

  if (problems.isNotEmpty) {
    _fail(
      '${file.path} is not ready for a $platform release:\n'
      '${problems.map((String p) => '  - $p').join('\n')}',
    );
  }
  stdout.writeln(
    '${file.path}: ${defines.length} defines, ready for a $platform release.',
  );
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
