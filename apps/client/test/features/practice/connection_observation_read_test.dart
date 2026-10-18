import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

import 'practice_fixtures.dart';
import 'recovery_fixtures.dart';

void main() {
  late ApiClient api;
  late PracticeRepository repository;
  late Map<String, dynamic> data;
  final connection = ConnectionReservation.fromJson(connectionJson());
  setUp(() {
    data = pageJson();
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.headers['X-Account-ID'], accountId);
        expect(request.headers.containsKey('X-CSRF-Token'), isFalse);
        expect(
          request.url.path,
          '/v1/practice-sessions/$practiceId/connections/$connectionId/observations',
        );
        expect(request.url.queryParameters, {
          'after_sequence': '0',
          'limit': '32',
        });
        return response(data);
      }),
    )..expectedAccountId = accountId;
    repository = PracticeRepository(api, accountId: accountId);
  });
  tearDown(() => api.close());
  final invalid = throwsA(
    isA<ApiException>().having((e) => e.code, 'code', 'invalid_response'),
  );

  test(
    'reads bound original identity, keeps gaps and immutable facts',
    () async {
      final result = await repository.loadConnectionObservations(connection);
      expect(result.events.map((e) => e.sequence), [1, 3]);
      expect(result.events.first.code, 'muted');
      expect(result.events.first.receivedAt.isUtc, isTrue);
      expect(result.nextAfterSequence, 3);
      expect(result.hasMore, isFalse);
      expect(() => result.events.clear(), throwsUnsupportedError);
    },
  );

  test(
    'accepts no observations without manufacturing a closing fact',
    () async {
      data = pageJson(sequences: []);
      final result = await repository.loadConnectionObservations(connection);
      expect(result.events, isEmpty);
      expect(result.totalEvents, 0);
    },
  );

  final changes = <String, void Function(Map<String, dynamic>)>{
    'untrusted source': (j) => j['source'] = 'provider_confirmed',
    'other connection': (j) => j['connection_id'] = requestKey,
    'other client': (j) => j['client_instance_id'] = requestKey,
    'other epoch': (j) => j['epoch'] = 2,
    'fractional epoch': (j) => j['epoch'] = 1.0,
    'wrong cursor': (j) => j['next_after_sequence'] = 2,
    'false has_more': (j) => j['has_more'] = true,
    'invalid has_more type': (j) => j['has_more'] = 'false',
    'oversized total': (j) => j['total_events'] = 257,
    'total below page': (j) => j['total_events'] = 1,
    'watermark below page': (j) => j['last_sequence'] = 2,
    'duplicate id': (j) =>
        j['events'][1]['event_id'] = j['events'][0]['event_id'],
    'duplicate sequence': (j) => j['events'][1]['sequence'] = 1,
    'unknown code': (j) => j['events'][0]['code'] = 'confirmed',
    'private reason': (j) => j['events'][0]['reason'] = 'private SDK failure',
    'reason on nonclose': (j) => j['events'][0]['reason'] = 'user_stop',
    'elapsed above cap': (j) => j['events'][0]['elapsed_ms'] = 86400001,
    'no timestamp zone': (j) =>
        j['events'][0]['received_at'] = '2026-10-18T00:00:00',
    'empty page hides facts': (j) => j['events'] = [],
    'first page skips facts': (j) => j['total_events'] = 3,
  };
  for (final change in changes.entries) {
    test('rejects ${change.key}', () async {
      change.value(data);
      await expectLater(
        repository.loadConnectionObservations(connection),
        invalid,
      );
    });
  }

  test('validates query before HTTP and stops on changed identity', () async {
    await expectLater(
      repository.loadConnectionObservations(connection, limit: 33),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'invalid_request'),
      ),
    );
    api.expectedAccountId = requestKey;
    await expectLater(
      repository.loadConnectionObservations(connection),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
      ),
    );
  });

  test('has_more cannot claim a page after the total is exhausted', () async {
    data = pageJson(
      sequences: List.generate(32, (i) => i + 1),
      total: 32,
      last: 40,
      more: true,
    );
    await expectLater(
      repository.loadConnectionObservations(connection),
      invalid,
    );
  });
}
