import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/practice/saved_practice_status_controller.dart';

class _Token implements TokenStore {
  _Token(this.value);
  final String value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => throw UnsupportedError('read only');
  @override
  Future<void> delete() async {}
}

class _ReadWire extends http.BaseClient {
  _ReadWire(this.requests);
  final List<String> requests;
  final _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method != 'GET') {
      throw StateError('Save status must remain read only');
    }
    requests.add('${request.method} ${request.url.path}');
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

void main() {
  final fixture = Platform.environment['SIMONTALK_SAVE_STATUS_WIRE_FIXTURE'];
  test(
    'real saved result, missing registration, owner and deletion gates remain pure GET',
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final j = jsonDecode(
        await File(fixture!).readAsString(),
      ) as Map<String, dynamic>;
      final requests = <String>[];
      ApiClient source(String account, String token) => ApiClient(
        baseUrl: Uri.parse(j['base_url'] as String),
        isWeb: false,
        tokenStore: _Token(token),
        client: _ReadWire(requests),
      )..expectedAccountId = account;
      final owner = j['account_id'] as String;
      final a = source(owner, j['access_token'] as String);
      final b = source(
        j['other_account_id'] as String,
        j['other_access_token'] as String,
      );
      final controllers = <SavedPracticeStatusController>[];
      SavedPracticeStatusController make(
        ApiClient api,
        String account,
        String sid,
      ) {
        final controller = SavedPracticeStatusController(
          accountApi: api,
          accountId: account,
          sessionId: sid,
          httpClientFactory: () => _ReadWire(requests),
        );
        controllers.add(controller);
        return controller;
      }

      try {
        final sealed = make(a, owner, j['sealed_session_id'] as String);
        expect(requests, isEmpty);
        await sealed.refresh();
        expect(sealed.state, SavedPracticeStatusState.ready);
        expect(sealed.completion!.coverage.name, 'incomplete');
        expect(sealed.completion!.gapCodes, contains('tail_unconfirmed'));
        final originalHash = sealed.completion!.inputHash;
        final unregistered = make(
          a,
          owner,
          j['unregistered_session_id'] as String,
        );
        await unregistered.refresh();
        expect(unregistered.state, SavedPracticeStatusState.ready);
        expect(unregistered.item!.completionStatus, 'unregistered');
        expect(unregistered.completion, isNull);
        final cross = make(
          b,
          j['other_account_id'] as String,
          j['sealed_session_id'] as String,
        );
        await cross.refresh();
        expect(cross.state, SavedPracticeStatusState.unavailable);
        expect(cross.errorCode, 'practice_not_found');
        expect(cross.item, isNull);
        final deleted = make(a, owner, j['deleted_session_id'] as String);
        await deleted.refresh();
        expect(deleted.state, SavedPracticeStatusState.unavailable);
        expect(deleted.item, isNull);
        await sealed.refresh();
        expect(sealed.completion!.inputHash, originalHash);
        expect(requests, hasLength(8));
        final evidence = j['evidence_path'] as String?;
        if (evidence != null) {
          await File(evidence).writeAsString(
            '${const JsonEncoder.withIndent('  ').convert({'request_count': requests.length, 'all_requests_get': requests.every((r) => r.startsWith('GET ')), 'sealed_incomplete_and_gap_verified': true, 'unregistered_explicit_404_verified': true, 'cross_account_and_deleted_rejected': true, 'refresh_preserves_sealed_input_hash': true})}\n',
          );
        }
      } finally {
        for (final controller in controllers) {
          controller.dispose();
        }
        a.close();
        b.close();
      }
    },
    skip: fixture == null
        ? 'requires isolated save status wire fixture'
        : false,
  );
}
