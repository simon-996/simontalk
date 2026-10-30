import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_recovery_controller.dart';
import 'package:simontalk_client/features/practice/termination_check_models.dart';

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

void main() {
  final path = Platform.environment['SIMONTALK_SAVED_STATUS_WIRE_FIXTURE'];
  test(
    'actual HTTP recovery reads sealed gaps and recorded checks with account isolation',
    () async {
      final fixture =
          jsonDecode(await File(path!).readAsString()) as Map<String, dynamic>;
      ApiClient apiFor(Map<String, dynamic> identity) => ApiClient(
        baseUrl: Uri.parse(fixture['base_url'] as String),
        isWeb: false,
        tokenStore: _Tokens(identity['access_token'] as String),
        client: http.Client(),
      )..expectedAccountId = identity['account_id'] as String;
      final a = fixture['a'] as Map<String, dynamic>,
          b = fixture['b'] as Map<String, dynamic>;
      final api = apiFor(a), other = apiFor(b);
      addTearDown(api.close);
      addTearDown(other.close);
      final controller = PracticeRecoveryController(
            api: api,
            accountId: a['account_id'] as String,
          ),
          second = PracticeRecoveryController(
            api: other,
            accountId: b['account_id'] as String,
          );
      addTearDown(controller.dispose);
      addTearDown(second.dispose);
      await controller.refresh();
      final original = controller.recovery!.connection!;
      expect(controller.savedCompletion, isNull);
      await controller.loadSaveStatus();
      expect(controller.saveStatusErrorCode, isNull);
      expect(controller.saveStatusLoaded, isTrue);
      expect(
        controller.savedCompletion!.status,
        PracticeCompletionStatus.sealed,
      );
      expect(
        controller.savedCompletion!.coverage,
        PracticeCompletionCoverage.incomplete,
      );
      expect(controller.savedCompletion!.gapCodes, ['tail_unconfirmed']);
      expect(
        controller.terminationCheck!.status,
        TerminationCheckStatus.blocked,
      );
      expect(controller.terminationCheck!.attempts, 0);
      expect(
        controller.recovery!.connection!.terminationStatus,
        TerminationStatus.unknown,
      );
      await controller.loadSaveStatus(refresh: true);
      expect(
        controller.recovery!.connection!.leaseExpiresAt,
        original.leaseExpiresAt,
      );
      await second.refresh();
      await second.loadSaveStatus();
      expect(second.saveStatusLoaded, isTrue);
      expect(second.savedCompletion, isNull);
      expect(
        second.terminationCheck!.status,
        TerminationCheckStatus.notRequested,
      );
      expect(second.terminationCheck!.scope.accountId, b['account_id']);
      await expectLater(
        other.request(
          'GET',
          '/v1/practice-sessions/${original.sessionId}/connections/${original.id}/termination-check',
          accountId: b['account_id'] as String,
        ),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      api.expectedAccountId = b['account_id'] as String;
      expect(controller.savedCompletion, isNull);
      expect(controller.terminationCheck, isNull);
      expect(controller.recovery, isNull);
      expect(controller.endRegistered, isFalse);
    },
    skip: path == null
        ? 'Requires isolated local API fixture; see saved status verification.'
        : false,
  );
}
