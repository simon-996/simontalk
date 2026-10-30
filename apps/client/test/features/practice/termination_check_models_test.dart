import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/termination_check_models.dart';

import 'practice_fixtures.dart';

ConversationScope terminationScope() => ConversationScope(
  accountId: accountId,
  sessionId: practiceId,
  connectionId: connectionId,
  clientInstanceId: clientId,
  epoch: 1,
);

Map<String, dynamic> terminationJson({bool blocked = false}) => {
  'source': 'server_recorded',
  'account_id': accountId,
  'session_id': practiceId,
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'status': blocked ? 'blocked' : 'not_requested',
  'reason': blocked ? 'capability_unavailable' : null,
  'attempts': 0,
  'created_at': blocked ? '2026-10-21T08:00:00Z' : null,
};

void main() {
  test('not requested and blocked retain original scope and server facts', () {
    final scope = terminationScope();
    final none = TerminationCheckSnapshot.fromJson(
      terminationJson(),
      scope: scope,
    );
    expect(none.source, 'server_recorded');
    expect(identical(none.scope, scope), true);
    expect(none.status, TerminationCheckStatus.notRequested);
    expect(none.reason, isNull);
    expect(none.attempts, 0);
    expect(none.createdAt, isNull);
    final blocked = TerminationCheckSnapshot.fromJson(
      terminationJson(blocked: true),
      scope: scope,
    );
    expect(blocked.status, TerminationCheckStatus.blocked);
    expect(blocked.reason, 'capability_unavailable');
    expect(blocked.attempts, 0);
    expect(blocked.createdAt, DateTime.utc(2026, 10, 21, 8));
    final offset = TerminationCheckSnapshot.fromJson({
      ...terminationJson(blocked: true),
      'created_at': '2026-10-21T16:00:00.123456+08:00',
    }, scope: scope);
    expect(offset.createdAt, DateTime.utc(2026, 10, 21, 8, 0, 0, 123, 456));
  });

  test('scope identifiers and integer epoch are strictly validated', () {
    for (final change in [
      {'source': 'client_reported'},
      {'account_id': requestKey},
      {'session_id': requestKey},
      {'connection_id': requestKey},
      {'client_instance_id': requestKey},
      {'connection_id': 'bad'},
      {'account_id': 1},
      {'epoch': 2},
      {'epoch': true},
      {'epoch': 1.0},
      {'epoch': 0},
      {'epoch': 2147483648},
      {'epoch': '1'},
    ]) {
      expect(
        () => TerminationCheckSnapshot.fromJson({
          ...terminationJson(),
          ...change,
        }, scope: terminationScope()),
        throwsFormatException,
        reason: '$change',
      );
    }
    expect(
      () => TerminationCheckSnapshot.fromJson({
        ...terminationJson(),
        'attempt_digest': 'a' * 64,
      }, scope: terminationScope()),
      throwsFormatException,
    );
    final missing = terminationJson()..remove('created_at');
    expect(
      () =>
          TerminationCheckSnapshot.fromJson(missing, scope: terminationScope()),
      throwsFormatException,
    );
  });

  test(
    'status reason date and attempts must obey exact current capability',
    () {
      for (final change in [
        {'status': 'running'},
        {'status': 'confirmed'},
        {'status': true},
        {'reason': 'capability_unavailable'},
        {'created_at': '2026-10-21T08:00:00Z'},
        {'attempts': 1},
        {'attempts': -1},
        {'attempts': false},
        {'attempts': 0.0},
        {'attempts': '0'},
      ]) {
        expect(
          () => TerminationCheckSnapshot.fromJson({
            ...terminationJson(),
            ...change,
          }, scope: terminationScope()),
          throwsFormatException,
          reason: '$change',
        );
      }
      for (final change in [
        {'reason': null},
        {'reason': 'pending'},
        {'created_at': null},
        {'attempts': 1},
      ]) {
        expect(
          () => TerminationCheckSnapshot.fromJson({
            ...terminationJson(blocked: true),
            ...change,
          }, scope: terminationScope()),
          throwsFormatException,
          reason: '$change',
        );
      }
    },
  );

  test('blocked dates require valid calendar time with explicit timezone', () {
    for (final date in [
      '',
      '2026-10-21',
      '2026-10-21T08:00:00',
      '2026-02-30T08:00:00Z',
      '0000-01-01T08:00:00Z',
      '2026-10-21T24:00:00Z',
      '2026-10-21T08:60:00Z',
      '2026-10-21T08:00:60Z',
      '2026-10-21T08:00:00+24:00',
      '2026-10-21T08:00:00+08:60',
      123,
    ]) {
      expect(
        () => TerminationCheckSnapshot.fromJson({
          ...terminationJson(blocked: true),
          'created_at': date,
        }, scope: terminationScope()),
        throwsFormatException,
        reason: '$date',
      );
    }
  });
}
