import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/review/practice_review_client.dart';
import 'package:simontalk_client/features/review/review_models.dart';
import 'package:simontalk_client/features/review/review_repository.dart';

class _Tokens implements TokenStore {
  _Tokens(this.token);
  final String token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => throw UnsupportedError('read only');
  @override
  Future<void> delete() async {}
}

/// A test transport loses one response only after the real server accepted it.
class _ObservedClient extends http.BaseClient {
  _ObservedClient(this.requests, this.loseJobReply);
  final List<http.BaseRequest> requests;
  final bool Function() loseJobReply;
  final http.Client delegate = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final reply = await delegate.send(request);
    if (request.method == 'POST' &&
        request.url.path.endsWith('/review') &&
        loseJobReply()) {
      await reply.stream.drain<void>();
      throw http.ClientException('Test response deliberately lost');
    }
    return reply;
  }

  @override
  void close() => delegate.close();
}

void main() {
  final fixturePath =
      Platform.environment['SIMONTALK_REVIEW_CLIENT_WIRE_FIXTURE'];
  test(
    'actual HTTP review actions replay, read, isolate and validate worker results',
    () async {
      final fixture = jsonDecode(
        await File(fixturePath!).readAsString(),
      ) as Map<String, dynamic>;
      final mode = File(fixture['gateway_mode_path'] as String),
          calls = File(fixture['gateway_calls_path'] as String);
      Future<void> setMode(String value) =>
          mode.writeAsString(value, flush: true);
      final identities = [
        for (final key in ['a', 'b', 'c']) fixture[key] as Map<String, dynamic>,
      ];
      ApiClient apiFor(Map<String, dynamic> identity) => ApiClient(
        baseUrl: Uri.parse(fixture['base_url'] as String),
        isWeb: false,
        tokenStore: _Tokens(identity['access_token'] as String),
        client: http.Client(),
      )..expectedAccountId = identity['account_id'] as String;
      ReviewTarget targetFor(Map<String, dynamic> identity) {
        final connection = ConnectionReservation.fromJson(
          identity['connection'] as Map<String, dynamic>,
        );
        final scope = ConversationScope(
          accountId: identity['account_id'] as String,
          sessionId: connection.sessionId,
          connectionId: connection.id,
          clientInstanceId: connection.clientInstanceId,
          epoch: connection.epoch,
        );
        return ReviewTarget.fromCompletion(
          PracticeCompletionSummary.fromJson(
            identity['completion'] as Map<String, dynamic>,
            scope: scope,
          ),
        );
      }

      final apis = identities.map(apiFor).toList(),
          targets = identities.map(targetFor).toList();
      for (final api in apis) {
        addTearDown(api.close);
      }
      final requests = <http.BaseRequest>[];
      var lose = true;
      final a = PracticeReviewClient(
        accountApi: apis[0],
        target: targets[0],
        httpClientFactory: () => _ObservedClient(requests, () {
          if (!lose) return false;
          lose = false;
          return true;
        }),
      );
      final b = PracticeReviewClient(accountApi: apis[1], target: targets[1]);
      final c = PracticeReviewClient(accountApi: apis[2], target: targets[2]);
      for (final client in [a, b, c]) {
        addTearDown(client.dispose);
      }
      Future<void> until(
        PracticeReviewClient client,
        ReviewJobStatus status,
      ) async {
        for (var i = 0; i < 40; i++) {
          await client.refresh();
          expect(client.errorCode, isNull);
          if (client.job?.status == status) return;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        fail('Review job did not reach ${status.name}');
      }

      await setMode('blocked');
      expect(requests, isEmpty);
      await a.requestReview();
      expect(a.errorCode, 'network_error');
      expect(a.hasPendingAction, true);
      final first = requests.last as http.Request;
      await a.refresh();
      expect(a.job!.status, ReviewJobStatus.blocked);
      expect(a.job!.attemptCount, 0);
      expect(a.hasPendingAction, true);
      final writes = requests.where((r) => r.method == 'POST').length;
      await a.refresh();
      expect(requests.where((r) => r.method == 'POST').length, writes);
      await a.retryPending();
      final replay = requests.last as http.Request;
      expect(replay.body, first.body);
      expect(
        replay.headers['Idempotency-Key'],
        first.headers['Idempotency-Key'],
      );
      expect(a.hasPendingAction, false);
      await setMode('success');
      await a.retryGeneration();
      await until(a, ReviewJobStatus.succeeded);
      expect(a.job!.attemptCount, 1);
      expect(a.job!.result!.items.length, 1);
      await b.requestReview();
      expect(b.job!.status, ReviewJobStatus.noEvaluableContent);
      expect(b.job!.attemptCount, 0);
      expect(b.job!.result, isNull);
      await setMode('invalid');
      await c.requestReview();
      await until(c, ReviewJobStatus.failed);
      expect(c.job!.attemptCount, 1);
      expect(c.job!.errorCode, 'invalid_output');
      expect(c.job!.result, isNull);
      await setMode('empty');
      await c.retryGeneration();
      await until(c, ReviewJobStatus.noSuggestions);
      expect(c.job!.attemptCount, 2);
      expect(c.job!.result!.items, isEmpty);
      final repo = ReviewRepository(apis[1], accountId: targets[1].accountId);
      await expectLater(
        apis[1].request(
          'GET',
          '/v1/practice-sessions/${targets[0].sessionId}/review',
          accountId: targets[1].accountId,
        ),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      expect(
        () => repo.readInput(targets[0]),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invalid_request'),
        ),
      );
      final callsBefore = jsonDecode(await calls.readAsString()) as List;
      expect(callsBefore.map((dynamic row) => row['mode']), [
        'success',
        'invalid',
        'empty',
      ]);
      await a.requestReview();
      await a.retryGeneration();
      await b.retryGeneration();
      await c.retryGeneration();
      await a.refresh();
      await b.refresh();
      await c.refresh();
      expect((jsonDecode(await calls.readAsString()) as List).length, 3);
      apis[0].expectedAccountId = targets[1].accountId;
      expect(a.job, isNull);
      expect(a.input, isNull);
      expect(a.hasPendingAction, false);
    },
    skip: fixturePath == null
        ? 'Requires isolated local API review fixture; SIMONTALK_REVIEW_CLIENT_WIRE_FIXTURE is unset.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
