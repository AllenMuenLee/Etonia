import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:http/http.dart' as http;

import 'postzen_client.dart';

const int _success = 0;
const int _usage = 64;
const int _unavailable = 69;
const int _configuration = 78;

typedef LineWriter = void Function(String line);

Future<int> runPostZenCli(
  List<String> arguments, {
  Map<String, String>? environment,
  http.Client? httpClient,
  LineWriter? out,
  LineWriter? errorOut,
}) async {
  final LineWriter writeOut = out ?? stdout.writeln;
  final LineWriter writeError = errorOut ?? stderr.writeln;
  final _PostZenRunner runner = _PostZenRunner(
    environment: environment ?? Platform.environment,
    httpClient: httpClient,
    out: writeOut,
  );
  try {
    return await runner.run(arguments) ?? _success;
  } on UsageException catch (error) {
    writeError(error.message);
    writeError(error.usage);
    return _usage;
  } on FormatException catch (error) {
    writeError(error.message);
    return _usage;
  } on PostZenException catch (error) {
    writeError(error.message);
    return _unavailable;
  } on _ConfigurationException catch (error) {
    writeError(error.message);
    return _configuration;
  }
}

final class _PostZenRunner extends CommandRunner<int> {
  _PostZenRunner({
    required Map<String, String> environment,
    required http.Client? httpClient,
    required LineWriter out,
  }) : super('postzen', 'Publish and schedule social posts with PostZen.') {
    addCommand(
      _AccountsCommand(
        environment: environment,
        httpClient: httpClient,
        out: out,
      ),
    );
    addCommand(
      _CreateCommand(
        environment: environment,
        httpClient: httpClient,
        out: out,
      ),
    );
  }
}

abstract base class _PostZenCommand extends Command<int> {
  _PostZenCommand({
    required this.environment,
    required this.httpClient,
    required this.out,
  }) {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Write machine-readable JSON to stdout.',
    );
  }

  final Map<String, String> environment;
  final http.Client? httpClient;
  final LineWriter out;

  bool get jsonOutput => argResults!.flag('json');

  PostZenClient openClient() {
    final String key = environment['POSTZEN_API_KEY']?.trim() ?? '';
    if (key.isEmpty) {
      throw const _ConfigurationException(
        'POSTZEN_API_KEY is not set. Export it before running this command.',
      );
    }
    return PostZenClient(apiKey: key, httpClient: httpClient);
  }
}

final class _AccountsCommand extends _PostZenCommand {
  _AccountsCommand({
    required super.environment,
    required super.httpClient,
    required super.out,
  });

  @override
  String get name => 'accounts';

  @override
  String get description =>
      'List the social accounts available to the API key.';

  @override
  Future<int> run() async {
    final PostZenClient client = openClient();
    try {
      final List<PostZenAccount> accounts = await client.listAccounts();
      if (jsonOutput) {
        out(
          jsonEncode(<String, Object?>{
            'accounts': accounts
                .map((PostZenAccount account) => account.toJson())
                .toList(growable: false),
          }),
        );
      } else if (accounts.isEmpty) {
        out('No connected accounts. Connect one at https://app.postzen.dev.');
      } else {
        for (final PostZenAccount account in accounts) {
          final String label = account.username.isNotEmpty
              ? account.username
              : account.displayName;
          out('${account.id}\t${account.platform}\t$label\t${account.status}');
        }
      }
      return _success;
    } finally {
      client.close();
    }
  }
}

final class _CreateCommand extends _PostZenCommand {
  _CreateCommand({
    required super.environment,
    required super.httpClient,
    required super.out,
  }) {
    argParser
      ..addOption(
        'content',
        abbr: 'c',
        mandatory: true,
        help: 'Post text.',
        valueHelp: 'text',
      )
      ..addFlag(
        'draft',
        negatable: false,
        help: 'Save a draft without publishing.',
      )
      ..addFlag('publish-now', negatable: false, help: 'Publish immediately.')
      ..addOption(
        'scheduled-for',
        help: 'UTC ISO-8601 time at least 60 seconds in the future.',
        valueHelp: '2026-11-01T15:00:00Z',
      )
      ..addMultiOption(
        'target',
        abbr: 't',
        help: 'Target as platform:accountId. Repeat for multiple accounts.',
        valueHelp: 'platform:accountId',
      )
      ..addOption(
        'request-id',
        help: 'Idempotency key. Reuse it to avoid duplicate posts.',
        valueHelp: 'unique-id',
      );
  }

  @override
  String get name => 'create';

  @override
  String get description =>
      'Create a draft, scheduled post, or immediate post.';

  @override
  Future<int> run() async {
    final bool draft = argResults!.flag('draft');
    final bool publishNow = argResults!.flag('publish-now');
    final String? scheduledText = argResults!.option('scheduled-for');
    final int modes =
        (draft ? 1 : 0) +
        (publishNow ? 1 : 0) +
        (scheduledText == null ? 0 : 1);
    if (modes != 1) {
      throw UsageException(
        'Choose exactly one of --draft, --publish-now, or --scheduled-for.',
        usage,
      );
    }

    final List<PostZenTarget> targets = argResults!
        .multiOption('target')
        .map(_parseTarget)
        .toList(growable: false);
    if (!draft && targets.isEmpty) {
      throw UsageException(
        'At least one --target is required unless --draft is used.',
        usage,
      );
    }

    DateTime? scheduledFor;
    if (scheduledText != null) {
      scheduledFor = DateTime.tryParse(scheduledText);
      if (scheduledFor == null || !scheduledText.endsWith('Z')) {
        throw UsageException(
          '--scheduled-for must be an ISO-8601 UTC timestamp ending in Z.',
          usage,
        );
      }
      if (!scheduledFor.isAfter(
        DateTime.now().toUtc().add(const Duration(seconds: 60)),
      )) {
        throw UsageException(
          '--scheduled-for must be more than 60 seconds in the future.',
          usage,
        );
      }
    }

    final PostZenClient client = openClient();
    try {
      final PostZenPost post = await client.createPost(
        content: argResults!.option('content')!,
        platforms: targets,
        publishNow: publishNow,
        scheduledFor: scheduledFor,
        isDraft: draft,
        requestId: argResults!.option('request-id'),
      );
      if (jsonOutput) {
        out(jsonEncode(<String, Object?>{'post': post.toJson()}));
      } else {
        out('${post.id}\t${post.status}');
      }
      return _success;
    } finally {
      client.close();
    }
  }

  PostZenTarget _parseTarget(String value) {
    final int separator = value.indexOf(':');
    if (separator <= 0 || separator == value.length - 1) {
      throw UsageException(
        'Invalid target "$value"; expected platform:accountId.',
        usage,
      );
    }
    final String platform = value.substring(0, separator).toLowerCase();
    if (!postZenPlatforms.contains(platform)) {
      throw UsageException('Unsupported PostZen platform "$platform".', usage);
    }
    return PostZenTarget(
      platform: platform,
      accountId: value.substring(separator + 1),
    );
  }
}

final class _ConfigurationException implements Exception {
  const _ConfigurationException(this.message);

  final String message;
}
