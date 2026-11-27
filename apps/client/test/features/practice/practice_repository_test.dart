import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

import 'practice_fixtures.dart';

void main() {
  test('redacted topic recovery still carries an unknown connection', () {
    final practice = {
      ...practiceJson(status: 'completed', epoch: 1),
      'mode': 'daily_topic',
      'state_reason': 'content_deleted',
    };
    final recovery = PracticeRecovery.fromJson({
      'practice': practice,
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
    expect(recovery.practice!.configuration.topic, isNull);
    expect(recovery.connection!.terminationStatus, TerminationStatus.unknown);
    expect(
      () => PracticePreparation.fromJson({...practice, 'state_reason': null}),
      throwsFormatException,
    );
  });

  late ApiClient api;
  late PracticeRepository repository;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;

  setUp(() {
    requests = [];
    handler = (_) async => response(practiceJson(), 201);
    api = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8000'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/v1/auth/csrf') {
          return response({'csrf_token': 'csrf-test'});
        }
        return handler(request);
      }),
    )..expectedAccountId = accountId;
    repository = PracticeRepository(api, accountId: accountId);
  });
  tearDown(() => api.close());

  Matcher code(String value) =>
      throwsA(isA<ApiException>().having((e) => e.code, 'code', value));

  test('create binds account, CSRF and caller idempotency key', () async {
    final result = await repository.createPractice(
      key: requestKey,
      difficulty: Difficulty.advanced,
    );
    final request = requests.last;
    expect(request.url.path, '/v1/practice-sessions');
    expect(request.headers['X-Account-ID'], accountId);
    expect(request.headers['X-CSRF-Token'], 'csrf-test');
    expect(request.headers['Idempotency-Key'], requestKey);
    expect(request.headers.containsKey('authorization'), isFalse);
    expect(jsonDecode(request.body), {
      'mode': 'free_chat',
      'difficulty_override': 'advanced',
    });
    expect(result.configuration.preferences.difficulty, Difficulty.beginner);
    expect(result.connectionEpoch, 0);
  });

  test('all seven operations use real paths and fixed control identity', () async {
    final practice = PracticePreparation.fromJson(practiceJson());
    final connection = ConnectionReservation.fromJson(connectionJson());
    handler = (r) async => response(
      r.url.path.contains('/connections') ? connectionJson() : practiceJson(),
    );
    await repository.loadPractice(practiceId);
    await repository.cancelPractice(practiceId);
    await repository.createConnection(
      practice,
      key: requestKey,
      clientInstanceId: clientId,
    );
    await repository.loadConnection(practiceId, connectionId);
    await repository.renewConnection(connection);
    await repository.cancelConnection(connection);
    final business = requests
        .where((r) => r.url.path != '/v1/auth/csrf')
        .toList();
    expect(business.map((r) => r.method), [
      'GET',
      'POST',
      'POST',
      'GET',
      'POST',
      'POST',
    ]);
    expect(
      business.every((r) => r.headers['X-Account-ID'] == accountId),
      isTrue,
    );
    expect(jsonDecode(business[2].body), {
      'client_instance_id': clientId,
      'expected_epoch': 0,
    });
    expect(jsonDecode(business[4].body), {
      'client_instance_id': clientId,
      'epoch': 1,
    });
    expect(
      business[5].url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/cancel-preparation',
    );
  });

  test('503 is preserved without retries or follow-up requests', () async {
    handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    await expectLater(
      repository.createPractice(key: requestKey),
      code('realtime_unavailable'),
    );
    expect(requests.length, 2);
  });

  test(
    'account change before invocation prevents every network request',
    () async {
      api.expectedAccountId = 'another-account';
      await expectLater(
        repository.createPractice(key: requestKey),
        code('account_changed'),
      );
      expect(requests, isEmpty);
    },
  );

  test('account change while CSRF loads prevents old mutation', () async {
    api.close();
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((r) async {
        requests.add(r);
        api.expectedAccountId = 'another-account';
        return response({'csrf_token': 'changed'});
      }),
    )..expectedAccountId = accountId;
    repository = PracticeRepository(api, accountId: accountId);
    await expectLater(
      repository.createPractice(key: requestKey),
      code('account_changed'),
    );
    expect(requests.single.url.path, '/v1/auth/csrf');
  });

  test('late response from old account is discarded', () async {
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    final result = repository.loadPractice(practiceId);
    final assertion = expectLater(result, code('account_changed'));
    await Future<void>.delayed(Duration.zero);
    api.expectedAccountId = null;
    pending.complete(response(practiceJson()));
    await assertion;
  });

  test('invalid UUID cannot change the request path', () async {
    await expectLater(
      repository.loadPractice('../me'),
      code('invalid_request'),
    );
    await expectLater(
      repository.createPractice(key: 'bad-key'),
      code('invalid_request'),
    );
    expect(requests, isEmpty);
  });

  test(
    'connection identity and configuration must match requested attempt',
    () async {
      final practice = PracticePreparation.fromJson(practiceJson());
      for (final change in [
        {'session_id': requestKey},
        {'client_instance_id': requestKey},
        {'epoch': 2},
        {
          'configuration': {...providerJson, 'model': 'other'},
        },
      ]) {
        handler = (_) async => response({...connectionJson(), ...change});
        await expectLater(
          repository.createConnection(
            practice,
            key: requestKey,
            clientInstanceId: clientId,
          ),
          code('invalid_response'),
        );
      }
    },
  );

  test('detail and controls reject a mismatched returned identifier', () async {
    handler = (_) async => response({...practiceJson(), 'id': requestKey});
    await expectLater(
      repository.loadPractice(practiceId),
      code('invalid_response'),
    );
    handler = (_) async => response({...connectionJson(), 'id': requestKey});
    await expectLater(
      repository.loadConnection(practiceId, connectionId),
      code('invalid_response'),
    );
    await expectLater(
      repository.renewConnection(
        ConnectionReservation.fromJson(connectionJson()),
      ),
      code('invalid_response'),
    );
  });

  test('malformed JSON fields become a stable API error', () async {
    handler = (_) async =>
        response({...practiceJson(), 'connection_epoch': 0.5});
    await expectLater(
      repository.createPractice(key: requestKey),
      code('invalid_response'),
    );
  });

  test('model rejects impossible evidence and missing timezone', () {
    for (final invalid in [
      connectionJson(status: 'ready'),
      connectionJson(status: 'closed', termination: 'unknown'),
      {...connectionJson(), 'ended_at': '2026-10-17T00:00:01Z'},
      {...connectionJson(), 'epoch': 0},
      {...connectionJson(), 'lease_expires_at': '2026-10-17T00:00:45'},
      {...connectionJson(), 'status': 'invented'},
    ]) {
      expect(
        () => ConnectionReservation.fromJson(invalid),
        throwsFormatException,
      );
    }
    expect(
      ConnectionReservation.fromJson(
        connectionJson(status: 'unknown', termination: 'unknown'),
      ).canCancel,
      isFalse,
    );
  });

  test(
    'current recovery is one account-bound GET with no CSRF, keys or mutations',
    () async {
      handler = (_) async => response({'practice': null, 'connection': null});
      final result = await repository.loadCurrentPreparation();
      expect(result.practice, isNull);
      expect(result.connection, isNull);
      expect(requests.length, 1);
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/v1/practice-sessions/current');
      expect(requests.single.headers['X-Account-ID'], accountId);
      expect(requests.single.headers.containsKey('Idempotency-Key'), isFalse);
      expect(requests.single.body, isEmpty);
    },
  );

  test(
    'current recovery preserves other client identity without taking ownership',
    () async {
      handler = (_) async => response({
        'practice': practiceJson(status: 'connecting', epoch: 1),
        'connection': connectionJson(instance: requestKey),
      });
      final result = await repository.loadCurrentPreparation();
      expect(result.practice!.connectionEpoch, 1);
      expect(result.connection!.clientInstanceId, requestKey);
      expect(requests.length, 1);
    },
  );

  test('recovery rejects malformed shape, unrelated connection, future epoch and configuration', () async {
    for (final invalid in [
      <String, dynamic>{},
      {'practice': null, 'connection': connectionJson()},
      {
        'practice': practiceJson(epoch: 1),
        'connection': {...connectionJson(), 'session_id': requestKey},
      },
      {'practice': practiceJson(), 'connection': connectionJson()},
      {
        'practice': practiceJson(epoch: 1),
        'connection': {
          ...connectionJson(),
          'configuration': {...providerJson, 'model': 'other'},
        },
      },
    ]) {
      handler = (_) async => response(invalid);
      await expectLater(
        repository.loadCurrentPreparation(),
        code('invalid_response'),
      );
    }
  });

  test('recovery exposes expired preparation reason and unknown occupancy under terminal parent', () async {
    handler = (_) async => response({
      'practice': {
        ...practiceJson(status: 'cancelled', epoch: 1),
        'state_reason': 'preparation_expired',
      },
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
    final result = await repository.loadCurrentPreparation();
    expect(result.practice!.stateReason, 'preparation_expired');
    expect(result.connection!.status, ConnectionStatus.unknown);
    expect(result.connection!.canCancel, isFalse);
  });
}
