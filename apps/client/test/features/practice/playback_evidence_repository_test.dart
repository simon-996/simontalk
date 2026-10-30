import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

import 'practice_fixtures.dart';

Map<String, Object?> emptyPlaybackPage() => {
  'source': 'client_reported',
  'account_id': accountId,
  'session_id': practiceId,
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'last_sequence': 0,
  'total_events': 0,
  'total_text_bytes': 0,
  'events': [],
  'next_after_sequence': 0,
  'has_more': false,
  'sealed': false,
  'recoverable': false,
};

void main() {
  test('playback repository is account scoped and only GETs original connection', () async {
    var requests = 0;
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/v1/practice-sessions/$practiceId/connections/$connectionId/playback-evidence',
        );
        expect(request.url.queryParameters, {
          'after_sequence': '0',
          'limit': '16',
        });
        expect(request.headers['X-Account-ID'], accountId);
        return response(emptyPlaybackPage());
      }),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    final repository = PracticeRepository(api, accountId: accountId);
    final connection = ConnectionReservation.fromJson(connectionJson());
    final page = await repository.loadPlaybackEvidence(connection);
    expect(requests, 1);
    expect(page.recoverable, isFalse);
    expect(page.sealed, isFalse);
  });

  test('invalid limits and account IDs never issue playback HTTP', () async {
    var requests = 0;
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async {
        requests++;
        return response(emptyPlaybackPage());
      }),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    final repository = PracticeRepository(api, accountId: accountId);
    final connection = ConnectionReservation.fromJson(connectionJson());
    for (final limit in [0, 17]) {
      await expectLater(
        repository.loadPlaybackEvidence(connection, limit: limit),
        throwsA(isA<ApiException>()),
      );
    }
    await expectLater(
      repository.loadPlaybackEvidence(connection, afterSequence: -1),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      PracticeRepository(
        api,
        accountId: 'bad',
      ).loadPlaybackEvidence(connection),
      throwsA(isA<ApiException>()),
    );
    expect(requests, 0);
  });

  test('another connection or claimed recoverable response cannot pass repository validation', () async {
    Map<String, Object?> page = emptyPlaybackPage();
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response(page)),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    final repository = PracticeRepository(api, accountId: accountId);
    final connection = ConnectionReservation.fromJson(connectionJson());
    for (final change in [
      {'connection_id': requestKey},
      {'epoch': 2},
      {'sealed': 1},
      {'recoverable': true},
    ]) {
      page = {...emptyPlaybackPage(), ...change};
      await expectLater(
        repository.loadPlaybackEvidence(connection),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invalid_response'),
        ),
      );
    }
    page = {...emptyPlaybackPage(), 'sealed': true};
    expect((await repository.loadPlaybackEvidence(connection)).sealed, true);
  });

  test(
    'late old account playback response is rejected after identity changes',
    () async {
      final pending = Completer<dynamic>();
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => await pending.future),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final repository = PracticeRepository(api, accountId: accountId);
      final task = repository.loadPlaybackEvidence(
        ConnectionReservation.fromJson(connectionJson()),
      );
      api.expectedAccountId = requestKey;
      pending.complete(response(emptyPlaybackPage()));
      await expectLater(
        task,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
        ),
      );
    },
  );
}
