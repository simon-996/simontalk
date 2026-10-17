import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/token_store.dart';

const accountId = '11111111-1111-4111-8111-111111111111';
const practiceId = '22222222-2222-4222-8222-222222222222';
const connectionId = '33333333-3333-4333-8333-333333333333';
const clientId = '44444444-4444-4444-8444-444444444444';
const requestKey = '55555555-5555-4555-8555-555555555555';
const providerJson = {
  'provider': 'test-only',
  'region': 'local',
  'model': 'test-only',
  'config_id': 'test-v1',
};

Map<String, dynamic> practiceJson({String status = 'created', int epoch = 0}) =>
    {
      'id': practiceId,
      'mode': 'free_chat',
      'status': status,
      'connection_epoch': epoch,
      'configuration': {
        'schema_version': 1,
        'preferences': {
          'difficulty': 'beginner',
          'speech_pace': 'normal',
          'subtitle_default': true,
          'chinese_hints_enabled': true,
          'translation_mode': 'on_demand',
          'version': 1,
        },
        'effective_difficulty': 'beginner',
        'provider': {...providerJson},
      },
      'created_at': '2026-10-17T00:00:00Z',
      'ended_at': status == 'cancelled' ? '2026-10-17T00:00:01Z' : null,
    };

Map<String, dynamic> connectionJson({
  String status = 'preparing',
  String termination = 'not_started',
  int second = 0,
  String instance = clientId,
}) => {
  'id': connectionId,
  'session_id': practiceId,
  'client_instance_id': instance,
  'epoch': 1,
  'configuration': {...providerJson},
  'status': status,
  'termination_status': termination,
  'state_reason': null,
  'created_at': '2026-10-17T00:00:00Z',
  'last_seen_at': DateTime.utc(
    2026,
    10,
    17,
  ).add(Duration(seconds: second)).toIso8601String(),
  'lease_expires_at': DateTime.utc(
    2026,
    10,
    17,
  ).add(Duration(seconds: second + 45)).toIso8601String(),
  'ended_at': ['closed', 'failed'].contains(status)
      ? '2026-10-17T00:00:01Z'
      : null,
};

http.Response response(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);

class TestTokenStore implements TokenStore {
  @override
  Future<String?> read() async => 'test-token';
  @override
  Future<void> write(String value) async {}
  @override
  Future<void> delete() async {}
}
