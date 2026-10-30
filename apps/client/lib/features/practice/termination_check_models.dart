import '../conversation/conversation_models.dart';
import 'practice_models.dart';

enum TerminationCheckStatus { notRequested, blocked }

String _id(dynamic value) {
  if (value is! String || !isPracticeUuid(value)) throw const FormatException();
  return value.toLowerCase();
}

int _integer(dynamic value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException();
  }
  return value;
}

DateTime _time(dynamic value) {
  if (value is! String) throw const FormatException();
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|([+-])(\d{2}):(\d{2}))$',
  ).firstMatch(value);
  if (match == null) throw const FormatException();
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
  final calendar = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if (parts[0] < 1 ||
      calendar.year != parts[0] ||
      calendar.month != parts[1] ||
      calendar.day != parts[2] ||
      calendar.hour != parts[3] ||
      calendar.minute != parts[4] ||
      calendar.second != parts[5] ||
      (match[7] != 'Z' &&
          (int.parse(match[9]!) > 23 || int.parse(match[10]!) > 59))) {
    throw const FormatException();
  }
  return DateTime.parse(value).toUtc();
}

/// The server's recorded intent; it grants no termination or media authority.
final class TerminationCheckSnapshot {
  const TerminationCheckSnapshot({
    required this.scope,
    required this.status,
    required this.reason,
    required this.attempts,
    required this.createdAt,
  });

  factory TerminationCheckSnapshot.fromJson(
    Map<String, dynamic> json, {
    required ConversationScope scope,
  }) {
    const keys = {
      'source',
      'account_id',
      'session_id',
      'connection_id',
      'client_instance_id',
      'epoch',
      'status',
      'reason',
      'attempts',
      'created_at',
    };
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['source'] != 'server_recorded' ||
        _id(json['account_id']) != scope.accountId ||
        _id(json['session_id']) != scope.sessionId ||
        _id(json['connection_id']) != scope.connectionId ||
        _id(json['client_instance_id']) != scope.clientInstanceId ||
        _integer(json['epoch'], 1, 2147483647) != scope.epoch) {
      throw const FormatException();
    }
    final status = switch (json['status']) {
      'not_requested' => TerminationCheckStatus.notRequested,
      'blocked' => TerminationCheckStatus.blocked,
      _ => throw const FormatException(),
    };
    final attempts = _integer(json['attempts'], 0, 0);
    final reason = json['reason'];
    final created = json['created_at'] == null
        ? null
        : _time(json['created_at']);
    if (status == TerminationCheckStatus.notRequested
        ? reason != null || created != null
        : reason != 'capability_unavailable' || created == null) {
      throw const FormatException();
    }
    return TerminationCheckSnapshot(
      scope: scope,
      status: status,
      reason: reason as String?,
      attempts: attempts,
      createdAt: created,
    );
  }

  final ConversationScope scope;
  final TerminationCheckStatus status;
  final String? reason;
  final int attempts;
  final DateTime? createdAt;
  String get source => 'server_recorded';
}
