import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/history/deletion_controller.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_list_controller.dart';

final class _Token implements TokenStore {
  _Token(this.value);
  final String value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => throw UnsupportedError('read only');
  @override
  Future<void> delete() async {}
}

final class _Observed extends http.BaseClient {
  _Observed(this.paths);
  final List<String> paths;
  final _delegate = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    paths.add('${request.method} ${request.url.path}');
    return _delegate.send(request);
  }

  @override
  void close() => _delegate.close();
}

void main() {
  final fixture = Platform.environment['SIMONTALK_RELATED_WIRE_FIXTURE'];
  test(
    'actual related seek pages, empty owner, cursor deletion and source deletion',
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final j = jsonDecode(
        await File(fixture!).readAsString(),
      ) as Map<String, dynamic>;
      final paths = <String>[];
      final owner = j['account_id'] as String,
          other = j['other_account_id'] as String;
      final sid = j['source_session_id'] as String;
      ApiClient source(String owner, String token) => ApiClient(
        baseUrl: Uri.parse(j['base_url'] as String),
        isWeb: false,
        tokenStore: _Token(token),
        client: _Observed(paths),
      )..expectedAccountId = owner;
      final a = source(owner, j['access_token'] as String),
          b = source(other, j['other_access_token'] as String);
      RehearsalListController list(ApiClient api, String id, String parent) =>
          RehearsalListController(
            accountApi: api,
            accountId: id,
            sourceSessionId: parent,
            httpClientFactory: () => _Observed(paths),
          );
      final c = list(a, owner, sid),
          empty = list(b, other, j['empty_source_session_id'] as String),
          denied = list(b, other, sid);
      DeletionController deletion(String target, String key) =>
          DeletionController(
            accountApi: a,
            accountId: owner,
            sessionId: target,
            keyFactory: () => key,
            httpClientFactory: () => _Observed(paths),
          );
      DeletionController? child, parent;
      try {
        expect(paths, isEmpty);
        await c.refresh();
        final ids = <String>[];
        final sizes = <int>[];
        while (true) {
          expect(c.errorCode, isNull);
          ids.addAll(c.page!.items.map((x) => x.id));
          sizes.add(c.page!.items.length);
          if (!c.canNext) {
            break;
          }
          await c.next();
        }
        expect(sizes, [10, 10, 1]);
        expect(ids, j['child_ids']);
        expect(ids.toSet(), hasLength(21));
        await c.previous();
        expect(c.pageNumber, 2);
        await c.previous();
        expect(c.pageNumber, 1);
        await empty.refresh();
        expect(empty.page!.items, isEmpty);
        await denied.refresh();
        expect(denied.page, isNull);
        expect(denied.errorCode, 'practice_not_found');
        expect(paths.every((x) => x.startsWith('GET ')), isTrue);
        final cursor = c.page!.items.last.id;
        child = deletion(cursor, '22222222-2222-4222-8222-222222222222');
        await child.load();
        expect(child.scope!.recordCount, 1);
        await child.confirm();
        expect(child.state, DeletionState.deleted);
        await c.next();
        expect(c.errorCode, 'rehearsal_cursor_not_found');
        expect(c.page, isNull);
        expect(c.canNext || c.canPrevious, isFalse);
        await c.refresh();
        expect(c.errorCode, isNull);
        expect(c.pageNumber, 1);
        expect(c.page!.items, hasLength(10));
        expect(c.page!.items.any((x) => x.id == cursor), isFalse);
        parent = deletion(sid, '33333333-3333-4333-8333-333333333333');
        await parent.load();
        expect(parent.scope!.recordCount, 21);
        await parent.confirm();
        expect(parent.state, DeletionState.deleted);
        await c.refresh();
        expect(c.errorCode, 'practice_not_found');
        expect(c.page, isNull);
        await empty.refresh();
        expect(empty.page!.items, isEmpty);
        expect(paths.where((x) => x.startsWith('DELETE ')), hasLength(2));
        expect(
          paths.every((x) => x.startsWith('GET ') || x.startsWith('DELETE ')),
          isTrue,
        );
        final report = Platform.environment['SIMONTALK_RELATED_WIRE_REPORT'];
        if (report != null) {
          await File(report).writeAsString(
            '${const JsonEncoder.withIndent('  ').convert({'kind': 'actual_dart_controllers_to_loopback_http', 'page_sizes': sizes, 'distinct_children': ids.toSet().length, 'back_to_page_1': true, 'read_phase_get_only': true, 'other_account_denied': true, 'other_source_empty': true, 'deleted_cursor_clears_old_page': true, 'refresh_restarts_head': true, 'deleted_parent_clears_old_page': true, 'other_owner_preserved': true, 'explicit_fixture_deletions': 2, 'gateway_calls': 0})}\n',
          );
        }
      } finally {
        child?.dispose();
        parent?.dispose();
        c.dispose();
        empty.dispose();
        denied.dispose();
        a.close();
        b.close();
      }
    },
    skip: fixture == null
        ? 'Requires a private disposable related-list fixture'
        : false,
  );
}
