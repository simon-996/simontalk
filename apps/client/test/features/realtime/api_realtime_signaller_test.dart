import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/realtime/api_realtime_signaller.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../practice/practice_fixtures.dart';

const offerSdp =
    'v=0\r\ns=private-offer\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';
const answerSdp = 'v=0\r\ns=answer\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';
Map<String, dynamic> answerJson() => {
  'session_id': practiceId,
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'answer': answerSdp,
};

class TrackedClient extends http.BaseClient {
  TrackedClient(Future<http.Response> Function(http.Request) handler)
    : delegate = MockClient(handler);
  final http.Client delegate;
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      delegate.send(request);
  @override
  void close() {
    closes++;
    delegate.close();
  }
}

class WaitingTokenStore extends TestTokenStore {
  final token = Completer<String?>();
  @override
  Future<String?> read() => token.future;
}

class StreamingAbortClient extends http.BaseClient {
  StreamingAbortClient(this.holdCsrf);
  final bool holdCsrf;
  final body = StreamController<List<int>>();
  bool reading = false;
  bool aborted = false;
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/csrf') && !holdCsrf) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"csrf_token":"test-csrf"}')),
        200,
      );
    }
    body.onListen = () => reading = true;
    if (request is http.Abortable && request.abortTrigger != null) {
      unawaited(
        request.abortTrigger!.then((_) async {
          if (body.isClosed) return;
          aborted = true;
          body.addError(http.RequestAbortedException(request.url));
          await body.close();
        }),
      );
    }
    // Headers arrive, but the response body never completes by itself.
    body.add(utf8.encode('{"'));
    return http.StreamedResponse(body.stream, 200);
  }

  @override
  void close() => closes++;
}

void main() {
  late ApiClient account;
  late TrackedClient shared;
  late TrackedClient owned;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  late ApiRealtimeSignaller signaller;
  Future<void> Function()? onCsrf;

  void setup({bool web = true, TestTokenStore? store}) {
    shared = TrackedClient((_) async => response({}));
    account = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: web,
      tokenStore: store ?? TestTokenStore(),
      client: shared,
    )..expectedAccountId = accountId;
    requests = [];
    onCsrf = null;
    handler = (_) async => response(answerJson());
    owned = TrackedClient((r) async {
      requests.add(r);
      if (r.url.path.endsWith('/csrf')) {
        await onCsrf?.call();
        return response({'csrf_token': 'test-csrf'});
      }
      return handler(r);
    });
    signaller = ApiRealtimeSignaller(
      accountApi: account,
      accountId: accountId,
      clientInstanceId: clientId,
      connection: ConnectionReservation.fromJson(connectionJson()),
      client: owned,
    );
  }

  Matcher failure(String code) =>
      throwsA(isA<RealtimeFailure>().having((e) => e.code, 'code', code));
  tearDown(() {
    signaller.cancel();
    account.close();
  });

  test('single offer uses owned account-bound CSRF client and leaves account API usable', () async {
    setup();
    expect(await signaller.exchangeOffer(offerSdp), answerSdp);
    expect(requests.length, 2);
    final request = requests.last;
    expect(
      request.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/offer',
    );
    expect(request.headers['X-Account-ID'], accountId);
    expect(request.headers['X-CSRF-Token'], 'test-csrf');
    expect(jsonDecode(request.body), {
      'client_instance_id': clientId,
      'epoch': 1,
      'offer': offerSdp,
    });
    expect(request.headers.containsKey('Idempotency-Key'), isFalse);
    await expectLater(
      signaller.exchangeOffer(offerSdp),
      failure('signalling_already_attempted'),
    );
    expect(owned.closes, 1);
    expect(shared.closes, 0);
    expect(
      await account.request('GET', '/v1/me', accountId: accountId),
      isEmpty,
    );
  });

  test(
    'cancel before exchange closes only owned client and never sends',
    () async {
      setup();
      signaller.cancel();
      signaller.cancel();
      await expectLater(
        signaller.exchangeOffer(offerSdp),
        failure('cancelled'),
      );
      expect(requests, isEmpty);
      expect(owned.closes, 1);
      expect(shared.closes, 0);
    },
  );

  test(
    'cancel resolves pending exchange immediately and ignores late answer',
    () async {
      setup(web: false);
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final result = signaller.exchangeOffer(offerSdp);
      final assertion = expectLater(result, failure('cancelled'));
      await Future<void>.delayed(Duration.zero);
      signaller.cancel();
      await assertion;
      pending.complete(response(answerJson()));
      await Future<void>.delayed(Duration.zero);
      expect(requests.length, 1);
      expect(owned.closes, 1);
      expect(shared.closes, 0);
    },
  );

  test(
    'account switch before request prevents every owned network call',
    () async {
      setup();
      account.expectedAccountId = requestKey;
      await expectLater(
        signaller.exchangeOffer(offerSdp),
        failure('account_changed'),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'source account closing invalidates its independent request scope',
    () async {
      setup();
      account.close();
      await expectLater(
        signaller.exchangeOffer(offerSdp),
        failure('account_changed'),
      );
      expect(requests, isEmpty);
      expect(owned.closes, 1);
    },
  );

  test(
    'source identity change during CSRF wait prevents offer transmission',
    () async {
      setup();
      onCsrf = () async {
        account.expectedAccountId = null;
      };
      await expectLater(
        signaller.exchangeOffer(offerSdp),
        failure('account_changed'),
      );
      expect(requests.length, 1);
      expect(requests.single.method, 'GET');
    },
  );

  test(
    'account switch during credential read is checked by scoped ApiClient',
    () async {
      final store = WaitingTokenStore();
      setup(web: false, store: store);
      final result = signaller.exchangeOffer(offerSdp);
      final assertion = expectLater(result, failure('account_changed'));
      account.expectedAccountId = null;
      store.token.complete('new-account-token');
      await assertion;
      expect(requests, isEmpty);
    },
  );

  test('late answer after source account changes is discarded', () async {
    setup(web: false);
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    final result = signaller.exchangeOffer(offerSdp);
    final assertion = expectLater(result, failure('account_changed'));
    await Future<void>.delayed(Duration.zero);
    account.expectedAccountId = null;
    pending.complete(response(answerJson()));
    await assertion;
  });

  test(
    'service error is stable and never automatically replays offer',
    () async {
      setup();
      handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
      await expectLater(
        signaller.exchangeOffer(offerSdp),
        failure('realtime_unavailable'),
      );
      await expectLater(
        signaller.exchangeOffer(offerSdp),
        failure('signalling_already_attempted'),
      );
      expect(requests.length, 2);
      expect(owned.closes, 1);
    },
  );

  test('local SDP format and UTF-8 limit are checked before network', () async {
    setup();
    await expectLater(
      signaller.exchangeOffer('v=0\r\n${'é' * 40000}'),
      failure('invalid_offer'),
    );
    expect(requests, isEmpty);
  });

  test(
    'wrong local client identity is rejected before constructing a request',
    () {
      setup();
      expect(
        () => ApiRealtimeSignaller(
          accountApi: account,
          accountId: accountId,
          clientInstanceId: requestKey,
          connection: ConnectionReservation.fromJson(connectionJson()),
        ),
        throwsA(isA<RealtimeFailure>()),
      );
      expect(requests, isEmpty);
    },
  );

  test('response validates all attempt identifiers and answer size', () async {
    for (final mutation in [
      {'session_id': requestKey},
      {'connection_id': requestKey},
      {'client_instance_id': requestKey},
      {'epoch': 2},
      {'answer': 'not-sdp'},
      {'answer': 'v=0\r\n${'x' * 65536}'},
    ]) {
      setup();
      handler = (_) async => response({...answerJson(), ...mutation});
      await expectLater(
        signaller.exchangeOffer(offerSdp),
        failure('invalid_response'),
      );
      expect(owned.closes, 1);
      account.close();
    }
  });

  testWidgets(
    'total exchange timeout includes waiting for headers and cancels only owned client',
    (tester) async {
      setup(web: false);
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final result = signaller.exchangeOffer(offerSdp);
      final assertion = expectLater(result, failure('signalling_timeout'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 12));
      await assertion;
      expect(owned.closes, 1);
      expect(shared.closes, 0);
      pending.complete(response(answerJson()));
      await tester.pump();
    },
  );

  for (final holdCsrf in [true, false]) {
    for (final cancel in [true, false]) {
      testWidgets(
        '${cancel ? 'cancel' : 'timeout'} aborts a streaming ${holdCsrf ? 'CSRF' : 'offer'} body after headers',
        (tester) async {
          setup();
          signaller.cancel();
          final streaming = StreamingAbortClient(holdCsrf);
          signaller = ApiRealtimeSignaller(
            accountApi: account,
            accountId: accountId,
            clientInstanceId: clientId,
            connection: ConnectionReservation.fromJson(connectionJson()),
            client: streaming,
          );
          final result = signaller.exchangeOffer(offerSdp);
          final assertion = expectLater(
            result,
            failure(cancel ? 'cancelled' : 'signalling_timeout'),
          );
          await tester.pump();
          expect(streaming.reading, isTrue);
          try {
            if (cancel) {
              signaller.cancel();
            } else {
              await tester.pump(const Duration(seconds: 12));
            }
            await assertion;
            await tester.pump();
            expect(streaming.aborted, isTrue);
            expect(streaming.closes, 1);
            expect(shared.closes, 0);
          } finally {
            if (!streaming.body.isClosed) {
              unawaited(streaming.body.close());
            }
            await tester.pump();
          }
        },
      );
    }
  }
}
