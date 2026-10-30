import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/history/deletion_controller.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';

class _Token implements TokenStore {
  _Token(this.token);
  final String token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => throw UnsupportedError('read only');
  @override
  Future<void> delete() async {}
}

class _Wire extends http.BaseClient {
  _Wire(this.paths, this.parent, this.drop);
  final List<String> paths;
  final String parent;
  final List<bool> drop;
  final _client = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    paths.add('${r.method} ${r.url.path}');
    final result = await _client.send(r);
    if (r.method == 'DELETE' &&
        r.url.path.endsWith(parent) &&
        result.statusCode >= 200 &&
        result.statusCode < 300 &&
        drop[0]) {
      drop[0] = false;
      await result.stream.drain<void>();
      throw http.ClientException('deliberate lost accepted receipt');
    }
    return result;
  }

  @override
  void close() => _client.close();
}

void main() {
  final fixture = Platform.environment['SIMONTALK_DELETION_WIRE_FIXTURE'];
  test(
    'real scope change, child isolation, lost parent receipt, unknown occupancy and no resurrection',
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final j = jsonDecode(
        await File(fixture!).readAsString(),
      ) as Map<String, dynamic>;
      final paths = <String>[], drop = [true];
      final sid = j['session_id'] as String;
      ApiClient source(String owner, String token) => ApiClient(
        baseUrl: Uri.parse(j['base_url'] as String),
        isWeb: false,
        tokenStore: _Token(token),
        client: _Wire(paths, sid, drop),
      )..expectedAccountId = owner;
      final owner = j['account_id'] as String,
          other = j['other_account_id'] as String;
      final a = source(owner, j['access_token'] as String),
          b = source(other, j['other_access_token'] as String);
      DeletionController make(
        ApiClient api,
        String owner,
        String target,
        String key,
      ) => DeletionController(
        accountApi: api,
        accountId: owner,
        sessionId: target,
        keyFactory: () => key,
        httpClientFactory: () => _Wire(paths, sid, drop),
      );
      final parent = make(
        a,
        owner,
        sid,
        '55555555-5555-4555-8555-555555555555',
      );
      final child = make(
        a,
        owner,
        j['child_id'] as String,
        '44444444-4444-4444-8444-444444444444',
      );
      final denied = make(
        b,
        other,
        sid,
        '66666666-6666-4666-8666-666666666666',
      );
      try {
        await denied.load();
        expect(denied.errorCode, 'practice_not_found');
        expect(denied.scope, isNull);
        await parent.load();
        expect(parent.scope!.recordCount, 3);
        expect(parent.scope!.connectionPending, isTrue);
        await child.load();
        expect(child.scope!.recordCount, 1);
        expect(child.scope!.kind, 'rehearsal');
        await child.confirm();
        expect(child.state, DeletionState.deleted);
        await parent.confirm();
        expect(parent.state, DeletionState.failed);
        expect(parent.errorCode, 'deletion_scope_changed');
        await parent.load();
        expect(parent.scope!.recordCount, 2);
        await parent.confirm();
        expect(parent.state, DeletionState.unconfirmed);
        await parent.check();
        expect(parent.state, DeletionState.deleted);
        expect(parent.receipt!.connectionPending, isTrue);
        final history = await a.request(
          'GET',
          '/v1/practice-history',
          accountId: owner,
        );
        expect(history['items'], isEmpty);
        final otherHistory = await b.request(
          'GET',
          '/v1/practice-history',
          accountId: other,
        );
        expect(
          (otherHistory['items'] as List).single['id'],
          j['other_session_id'],
        );
        final recovery = PracticeRecovery.fromJson(
          await a.request(
            'GET',
            '/v1/practice-sessions/current',
            accountId: owner,
          ),
        );
        expect(recovery.practice!.stateReason, 'content_deleted');
        expect(
          recovery.connection!.terminationStatus,
          TerminationStatus.unknown,
        );
        for (final path in [
          '/v1/practice-history/$sid',
          '/v1/practice-sessions/$sid/review',
          '/v1/practice-sessions/$sid/saved-transcript?input_revision=1&input_hash=${j['input_hash']}',
        ]) {
          await expectLater(
            a.request('GET', path, accountId: owner),
            throwsA(
              isA<ApiException>().having((e) => e.statusCode, 'status', 404),
            ),
          );
        }
        expect(
          paths.every((p) => p.startsWith('GET ') || p.startsWith('DELETE ')),
          isTrue,
        );
      } finally {
        parent.dispose();
        child.dispose();
        denied.dispose();
        a.close();
        b.close();
      }
    },
    skip: fixture == null
        ? 'Requires a private isolated deletion fixture'
        : false,
  );
}
