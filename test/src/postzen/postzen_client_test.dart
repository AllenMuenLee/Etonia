import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/src/postzen/postzen_cli.dart';
import 'package:greatnote/src/postzen/postzen_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('PostZenClient', () {
    test('lists accounts with bearer authentication', () async {
      late http.Request sent;
      final PostZenClient client = PostZenClient(
        apiKey: 'test-key',
        httpClient: MockClient((http.Request request) async {
          sent = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'accounts': <Object?>[
                <String, Object?>{
                  '_id': 'account-1',
                  'platform': 'twitter',
                  'username': 'etonia',
                  'displayName': 'Etonia',
                  'status': 'connected',
                },
              ],
            }),
            200,
          );
        }),
      );

      final List<PostZenAccount> accounts = await client.listAccounts();

      expect(sent.method, 'GET');
      expect(sent.url.toString(), 'https://api.postzen.dev/v1/accounts');
      expect(sent.headers['authorization'], 'Bearer test-key');
      expect(accounts.single.id, 'account-1');
      expect(accounts.single.platform, 'twitter');
    });

    test('creates an idempotent draft with the exact PostZen shape', () async {
      late http.Request sent;
      final PostZenClient client = PostZenClient(
        apiKey: 'test-key',
        httpClient: MockClient((http.Request request) async {
          sent = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'post': <String, Object?>{'_id': 'post-1', 'status': 'draft'},
              'message': 'Post created',
            }),
            201,
          );
        }),
      );

      final PostZenPost post = await client.createPost(
        content: 'Release notes',
        isDraft: true,
        requestId: 'release-42',
      );

      expect(sent.method, 'POST');
      expect(sent.headers['x-request-id'], 'release-42');
      expect(jsonDecode(sent.body), <String, Object?>{
        'content': 'Release notes',
        'isDraft': true,
      });
      expect(post.id, 'post-1');
      expect(post.status, 'draft');
    });

    test('accepts the existingPost idempotency response', () async {
      final PostZenClient client = PostZenClient(
        apiKey: 'test-key',
        httpClient: MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'existingPost': <String, Object?>{
                '_id': 'post-1',
                'status': 'scheduled',
              },
            }),
            200,
          );
        }),
      );

      final PostZenPost post = await client.createPost(
        content: 'Release notes',
        isDraft: true,
        requestId: 'release-42',
      );

      expect(post.id, 'post-1');
    });
  });

  group('PostZen CLI', () {
    test('fails closed when the API key is missing', () async {
      final List<String> errors = <String>[];

      final int code = await runPostZenCli(
        <String>['accounts'],
        environment: const <String, String>{},
        out: (_) {},
        errorOut: errors.add,
      );

      expect(code, 78);
      expect(errors.single, contains('POSTZEN_API_KEY'));
    });

    test('lists accounts as JSON without leaking the key', () async {
      late http.Request sent;
      final List<String> output = <String>[];
      final int code = await runPostZenCli(
        <String>['accounts', '--json'],
        environment: const <String, String>{'POSTZEN_API_KEY': 'secret-key'},
        httpClient: MockClient((http.Request request) async {
          sent = request;
          return http.Response(
            '{"accounts": [{"_id": "account-1", "platform": "linkedin"}]}',
            200,
          );
        }),
        out: output.add,
        errorOut: (_) {},
      );

      expect(code, 0);
      expect(sent.headers['authorization'], 'Bearer secret-key');
      expect(output.single, isNot(contains('secret-key')));
      expect(jsonDecode(output.single), <String, Object?>{
        'accounts': <Object?>[
          <String, Object?>{
            '_id': 'account-1',
            'platform': 'linkedin',
            'username': '',
            'displayName': '',
            'status': '',
          },
        ],
      });
    });

    test(
      'rejects publishing without a target before making a request',
      () async {
        final List<String> errors = <String>[];

        final int code = await runPostZenCli(
          <String>['create', '--content', 'Hello', '--publish-now'],
          environment: const <String, String>{'POSTZEN_API_KEY': 'secret-key'},
          httpClient: MockClient((http.Request request) async {
            fail('HTTP must not be called for invalid arguments.');
          }),
          out: (_) {},
          errorOut: errors.add,
        );

        expect(code, 64);
        expect(errors.first, contains('At least one --target'));
      },
    );
  });
}
