import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_repository.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_models.dart';

import 'transcript_fixtures.dart';

void main() {
  late ApiClient api;
  late SavedTranscriptRepository repo;
  final requests = <http.Request>[];
  late Future<http.Response> Function(http.Request) handler;
  setUp(() {
    requests.clear();
    handler = (_) async => response(pageJson());
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((r) {
        requests.add(r);
        return handler(r);
      }),
    )..expectedAccountId = accountId;
    repo = SavedTranscriptRepository(
      api,
      accountId: accountId,
      sessionId: practiceId,
    );
  });
  tearDown(() => api.close());
  test(
    'only GET, explicit owner, sealed query and no mutable action',
    () async {
      await repo.readPage(target(), offset: 0);
      expect(requests.single.method, 'GET');
      expect(requests.single.headers['X-Account-ID'], accountId);
      expect(requests.single.url.queryParameters, {
        'input_revision': '1',
        'input_hash': 'a' * 64,
        'limit': '16',
        'offset': '0',
      });
      expect(requests.single.body, isEmpty);
    },
  );
  test('actual raw response byte cap rejects excess whitespace before JSON parsing', () async {
    handler = (_) async => http.Response(
      '${' ' * savedTranscriptMaxBytes}${jsonEncode(pageJson())}',
      200,
    );
    await expectLater(
      repo.readPage(target()),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'invalid_response'),
      ),
    );
  });
  test(
    'existing API requests without a cap retain their default behavior',
    () async {
      handler = (_) async => http.Response(
        '${' ' * savedTranscriptMaxBytes}${jsonEncode(pageJson())}',
        200,
      );
      final json = await api.request(
        'GET',
        '/existing-path',
        accountId: accountId,
      );
      expect(json['schema_version'], 'saved_transcript_v1');
    },
  );
  test('UTF8 response and strict parsed shape; nullable required', () async {
    handler = (_) async {
      final j = pageJson();
      j['items'][0]['final_text'] = '你好';
      return http.Response.bytes(utf8.encode(jsonEncode(j)), 200);
    };
    expect((await repo.readPage(target())).items.first.finalText, '你好');
    handler = (_) async {
      final j = pageJson();
      j.remove('focus');
      return response(j);
    };
    await expectLater(
      repo.readPage(target()),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'invalid_response'),
      ),
    );
  });
  test('invalid scope and item do not issue HTTP', () async {
    await expectLater(
      repo.readPage(target(), reviewItemId: 'bad'),
      throwsA(isA<ApiException>()),
    );
    expect(requests, isEmpty);
  });
}
