import '../practice/practice_models.dart';

String _id(dynamic v) {
  if (v is! String || !isPracticeUuid(v)) throw const FormatException();
  return v.toLowerCase();
}

String _hash(dynamic v) {
  if (v is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(v)) {
    throw const FormatException();
  }
  return v;
}

void _envelope(
  Map<String, dynamic> j,
  String schema,
  String owner,
  String sid,
) {
  if (j['schema_version'] != schema ||
      j['source'] != 'server_recorded' ||
      _id(j['account_id']) != owner ||
      _id(j['session_id']) != sid ||
      j['connection_pending'] is! bool) {
    throw const FormatException();
  }
}

(int, int) _counts(Map<String, dynamic> j) {
  final count = j['record_count'], children = j['rehearsal_count'];
  if (count is! int ||
      children is! int ||
      count < 1 ||
      children < 0 ||
      children > count ||
      count > 2147483647) {
    throw const FormatException();
  }
  return (count, children);
}

T _parse<T>(T Function() read) {
  try {
    return read();
  } on Object {
    throw const FormatException('Invalid deletion response');
  }
}

final class DeletionScope {
  DeletionScope._(
    this.accountId,
    this.sessionId,
    this.kind,
    this.recordCount,
    this.rehearsalCount,
    this.version,
    this.connectionPending,
  );
  factory DeletionScope.fromJson(
    Map<String, dynamic> j, {
    required String accountId,
    required String sessionId,
  }) => _parse(() {
    _envelope(j, 'practice_deletion_scope_v1', accountId, sessionId);
    final (count, children) = _counts(j);
    final kind = j['kind'];
    if (!(kind == 'ordinary' && children == count - 1 ||
        kind == 'rehearsal' && count == 1 && children == 1)) {
      throw const FormatException();
    }
    return DeletionScope._(
      accountId,
      sessionId,
      kind as String,
      count,
      children,
      _hash(j['scope_version']),
      j['connection_pending'] as bool,
    );
  });
  final String accountId, sessionId, kind, version;
  final int recordCount, rehearsalCount;
  final bool connectionPending;
}

final class DeletionReceipt {
  DeletionReceipt._(this.recordCount, this.connectionPending, this.deletedAt);
  factory DeletionReceipt.fromJson(
    Map<String, dynamic> j, {
    required DeletionScope scope,
    required String requestKey,
  }) => _parse(() {
    _envelope(
      j,
      'practice_deletion_receipt_v1',
      scope.accountId,
      scope.sessionId,
    );
    final (count, children) = _counts(j);
    final date = j['deleted_at'];
    if (_id(j['request_key']) != requestKey ||
        _hash(j['scope_version']) != scope.version ||
        count != scope.recordCount ||
        children != scope.rehearsalCount ||
        date is! String ||
        !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(date)) {
      throw const FormatException();
    }
    return DeletionReceipt._(
      count,
      j['connection_pending'] as bool,
      DateTime.parse(date).toUtc(),
    );
  });
  final int recordCount;
  final bool connectionPending;
  final DateTime deletedAt;
}
