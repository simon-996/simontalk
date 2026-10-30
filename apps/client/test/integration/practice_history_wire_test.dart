import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/history/history_controller.dart';
import 'package:simontalk_client/features/review/review_page_controller.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_controller.dart';

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

final class _ObservedClient extends http.BaseClient {
  _ObservedClient(this.paths);
  final List<String> paths;
  final _delegate = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) {
    paths.add('${r.method} ${r.url.path}');
    return _delegate.send(r);
  }

  @override
  void close() => _delegate.close();
}

void main() {
  final fixture = Platform.environment['SIMONTALK_HISTORY_WIRE_FIXTURE'];
  test('actual owner history, three seek pages, detail, saved text, review and other account', () async {
    WidgetsFlutterBinding.ensureInitialized();
    final j =
        jsonDecode(await File(fixture!).readAsString()) as Map<String, dynamic>;
    final paths = <String>[];
    ApiClient source(String owner, String token) => ApiClient(
      baseUrl: Uri.parse(j['base_url'] as String),
      isWeb: false,
      tokenStore: _Token(token),
      client: _ObservedClient(paths),
    )..expectedAccountId = owner;
    final owner = j['account_id'] as String, sid = j['session_id'] as String;
    final api = source(owner, j['access_token'] as String);
    final list = HistoryController(
      accountApi: api,
      accountId: owner,
      httpClientFactory: () => _ObservedClient(paths),
    );
    final detail = HistoryController(
      accountApi: api,
      accountId: owner,
      sessionId: sid,
      httpClientFactory: () => _ObservedClient(paths),
    );
    final text = SavedTranscriptController(
      accountApi: api,
      accountId: owner,
      sessionId: sid,
      httpClientFactory: () => _ObservedClient(paths),
    );
    final review = ReviewPageController(
      accountApi: api,
      accountId: owner,
      sessionId: sid,
      httpClientFactory: () => _ObservedClient(paths),
    );
    final other = j['other_account_id'] as String;
    final bApi = source(other, j['other_access_token'] as String);
    final b = HistoryController(
      accountApi: bApi,
      accountId: other,
      httpClientFactory: () => _ObservedClient(paths),
    );
    final denied = HistoryController(
      accountApi: bApi,
      accountId: other,
      sessionId: sid,
      httpClientFactory: () => _ObservedClient(paths),
    );
    try {
      expect(paths, isEmpty);
      await list.refresh();
      final ids = <String>[];
      var pages = 0;
      while (true) {
        expect(list.errorCode, isNull);
        pages++;
        ids.addAll(list.page!.items.map((x) => x.id));
        if (!list.canNext) break;
        await list.next();
      }
      expect(pages, 3);
      expect(ids, hasLength(23));
      expect(ids.toSet(), hasLength(23));
      await list.previous();
      expect(list.pageNumber, 2);
      await detail.refresh();
      expect(detail.item!.isSealed, isTrue);
      expect(detail.item!.difficultyLabel, '轻松起步');
      await text.refresh();
      expect(text.page!.totalTurns, 23);
      expect(text.page!.items, hasLength(16));
      await text.next();
      expect(text.page!.items, hasLength(7));
      await review.refresh();
      expect(review.job!.result!.items, hasLength(1));
      await b.refresh();
      expect(b.page!.items.single.id, j['other_session_id']);
      await denied.refresh();
      expect(denied.item, isNull);
      expect(denied.errorCode, 'practice_not_found');
      expect(paths.every((p) => p.startsWith('GET ')), isTrue);
    } finally {
      list.dispose();
      detail.dispose();
      text.dispose();
      review.dispose();
      b.dispose();
      denied.dispose();
      api.close();
      bApi.close();
    }
  }, skip: fixture == null);
}
