import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_controller.dart';

class _Token implements TokenStore {
  _Token(this.token);
  final String token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String token) async =>
      throw UnsupportedError('fixture read only');
  @override
  Future<void> delete() async {}
}

class _Wire extends http.BaseClient {
  _Wire(this.paths, this.posts, this.drop);
  final List<String> paths;
  final List<({String? key, String body})> posts;
  final List<bool> drop;
  final _client = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    paths.add('${r.method} ${r.url.path}');
    if (r.method == 'POST' &&
        r.url.path.endsWith('/rehearsals') &&
        r is http.Request) {
      posts.add((key: r.headers['Idempotency-Key'], body: r.body));
    }
    final response = await _client.send(r);
    if (r.method == 'POST' &&
        r.url.path.endsWith('/rehearsals') &&
        response.statusCode == 201 &&
        drop[0]) {
      drop[0] = false;
      await response.stream.drain<void>();
      throw http.ClientException('deliberately lost accepted preparation');
    }
    return response;
  }

  @override
  void close() => _client.close();
}

void main() {
  final fixture = Platform.environment['SIMONTALK_REHEARSAL_WIRE_FIXTURE'];
  test(
    'real target, unavailable, lost accepted response, original replay, independent children and safe discard',
    () async {
      final j = jsonDecode(
        await File(fixture!).readAsString(),
      ) as Map<String, dynamic>;
      final paths = <String>[],
          posts = <({String? key, String body})>[],
          drop = [true];
      final owner = j['account_id'] as String,
          other = j['other_account_id'] as String,
          sid = j['source_session_id'] as String,
          item = j['item_id'] as String;
      ApiClient api(String id, String token) => ApiClient(
        baseUrl: Uri.parse(j['base_url'] as String),
        isWeb: false,
        tokenStore: _Token(token),
        client: _Wire(paths, posts, drop),
      )..expectedAccountId = id;
      final a = api(owner, j['access_token'] as String),
          b = api(other, j['other_access_token'] as String);
      final controllers = <RehearsalController>[];
      RehearsalController make({
        String? child,
        String? key,
        ApiClient? source,
        String? account,
      }) {
        final c = RehearsalController(
          accountApi: source ?? a,
          accountId: account ?? owner,
          sessionId: child ?? sid,
          itemId: child == null ? item : null,
          keyFactory: () => key ?? '11111111-1111-4111-8111-111111111111',
          httpClientFactory: () => _Wire(paths, posts, drop),
        );
        controllers.add(c);
        return c;
      }

      Map<String, dynamic> control() =>
          jsonDecode(File(j['control_path'] as String).readAsStringSync())
              as Map<String, dynamic>;
      try {
        final before = await a.request(
          'GET',
          '/v1/practice-history',
          accountId: owner,
        );
        final unavailable = make();
        await unavailable.load();
        expect(unavailable.state, RehearsalState.ready);
        expect(unavailable.target!.sourceText, contains('my weekend'));
        unavailable.selectDifficulty(Difficulty.advanced);
        await unavailable.confirm();
        expect(unavailable.errorCode, 'realtime_unavailable');
        expect(unavailable.state, RehearsalState.failed);
        expect(
          (await a.request(
            'GET',
            '/v1/practice-history',
            accountId: owner,
          ))['items'],
          before['items'],
        );
        expect(control()['admitted'], 0);
        final settings = control()..['enabled'] = true;
        File(j['control_path'] as String)
            .writeAsStringSync(jsonEncode(settings));
        final first = make(key: '22222222-2222-4222-8222-222222222222');
        await first.load();
        first.selectDifficulty(Difficulty.advanced);
        await first.confirm();
        expect(first.state, RehearsalState.unconfirmed);
        expect(first.preparation, isNull);
        expect(control()['admitted'], 1);
        final original = posts.last;
        await first.replay();
        expect(first.state, RehearsalState.prepared);
        expect(posts.last, original);
        expect(control()['admitted'], 1);
        final child1 = first.preparation!.id;
        expect(
          first.preparation!.configuration.effectiveDifficulty,
          Difficulty.advanced,
        );
        final fixed = make(child: child1);
        await fixed.load();
        expect(fixed.state, RehearsalState.ready);
        expect(fixed.target!.matches(first.target!), isTrue);
        await fixed.confirm();
        expect(control()['admitted'], 1);
        await first.discard();
        expect(first.state, RehearsalState.cancelled);
        final second = make(key: '33333333-3333-4333-8333-333333333333');
        await second.load();
        second.selectDifficulty(Difficulty.beginner);
        await second.confirm();
        expect(second.state, RehearsalState.prepared);
        expect(second.preparation!.id, isNot(child1));
        expect(control()['admitted'], 2);
        final siblings = await a.request(
          'GET',
          '/v1/practice-sessions/$sid/rehearsals',
          accountId: owner,
        );
        expect(siblings['items'], hasLength(2));
        expect(
          (siblings['items'] as List).every(
            (x) => x['source_session_id'] == sid,
          ),
          isTrue,
        );
        final denied = make(source: b, account: other);
        await denied.load();
        expect(denied.state, RehearsalState.failed);
        expect(denied.target, isNull);
        expect(denied.errorCode, 'practice_not_found');
        await second.discard();
        expect(second.state, RehearsalState.cancelled);
        expect(paths.where((p) => p.contains('/connections')), isEmpty);
        final report = Platform.environment['SIMONTALK_REHEARSAL_WIRE_REPORT'];
        if (report != null) {
          await File(report).writeAsString(
            '${const JsonEncoder.withIndent('  ').convert({'default_503_no_new_record': true, 'lost_accepted_reply': 'unconfirmed', 'original_key_body_replayed': true, 'two_independent_children': true, 'admission_calls': control()['admitted'], 'read_only_fixed_target': true, 'safe_discard_both_children': true, 'cross_owner_source': 'practice_not_found', 'connection_requests': 0})}\n',
          );
        }
      } finally {
        for (final c in controllers) {
          c.dispose();
        }
        a.close();
        b.close();
      }
    },
    skip: fixture == null
        ? 'Requires a private isolated rehearsal fixture.'
        : false,
  );
}
