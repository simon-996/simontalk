import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/practice/practice_entry_controller.dart';
import 'package:simontalk_client/features/practice/practice_preparation_controller.dart';
import 'package:simontalk_client/features/practice/practice_recovery_controller.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

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

class _ObservedClient extends http.BaseClient {
  _ObservedClient(this.paths);
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
  final fixture = Platform.environment['SIMONTALK_ENTRY_WIRE_FIXTURE'];
  test(
    'actual default HTTP preflight rejects preparation without any connection',
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final data = jsonDecode(
        await File(fixture!).readAsString(),
      ) as Map<String, dynamic>;
      final paths = <String>[];
      final id = data['account_id'] as String;
      final api = ApiClient(
        baseUrl: Uri.parse(data['base_url'] as String),
        isWeb: false,
        tokenStore: _Token(data['access_token'] as String),
        client: _ObservedClient(paths),
      )..expectedAccountId = id;
      final controller = PracticeEntryController(
        recovery: PracticeRecoveryController(
          api: api,
          accountId: id,
          httpClientFactory: () => _ObservedClient(paths),
        ),
        preparation: PracticePreparationController(
          repository: PracticeRepository(api, accountId: id),
        ),
      );
      try {
        expect(paths, isEmpty);
        await controller.begin(Difficulty.beginner);
        expect(paths, [
          'GET /v1/practice-sessions/current',
          'POST /v1/practice-sessions',
        ]);
        expect(controller.preparation.phase, PreparationPhase.blocked);
        expect(controller.preparation.errorCode, 'realtime_unavailable');
        expect(controller.preparation.practice, isNull);
        expect(controller.preparation.connection, isNull);
        await controller.begin(Difficulty.beginner);
        await controller.retry();
        expect(paths.length, 2);
      } finally {
        controller.dispose();
        api.close();
      }
    },
    skip: fixture == null,
  );
}
