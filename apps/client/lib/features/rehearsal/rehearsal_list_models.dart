import 'dart:convert';

import '../practice/practice_models.dart';

T _parse<T>(T Function() read) {
  try {
    return read();
  } on Object {
    throw const FormatException('Invalid related rehearsal response');
  }
}

String _id(dynamic v) {
  if (v is! String || !isPracticeUuid(v)) {
    throw const FormatException();
  }
  return v.toLowerCase();
}

void _keys(Map<String, dynamic> j, Set<String> keys) {
  if (j.length != keys.length || !j.keys.every(keys.contains)) {
    throw const FormatException();
  }
}

DateTime _time(dynamic raw) {
  if (raw is! String) {
    throw const FormatException();
  }
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|\+00:00)$',
  ).firstMatch(raw);
  if (match == null) {
    throw const FormatException();
  }
  final p = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
  final value = DateTime.parse(raw).toUtc();
  if (p[0] < 1 ||
      value.year != p[0] ||
      value.month != p[1] ||
      value.day != p[2] ||
      value.hour != p[3] ||
      value.minute != p[4] ||
      value.second != p[5]) {
    throw const FormatException();
  }
  return value;
}

/// Metadata only. This endpoint supplies no difficulty, saved text or scores.
final class RelatedRehearsal {
  const RelatedRehearsal._(
    this.id,
    this.sourceSessionId,
    this.itemId,
    this.status,
    this.createdAt,
    this.endedAt,
  );
  factory RelatedRehearsal.fromJson(
    Map<String, dynamic> j, {
    required String sourceSessionId,
  }) => _parse(() {
    _keys(j, {
      'id',
      'kind',
      'source_session_id',
      'source_review_item_id',
      'status',
      'created_at',
      'ended_at',
    });
    final id = _id(j['id']);
    if (j['kind'] != 'rehearsal' ||
        _id(j['source_session_id']) != sourceSessionId ||
        id == sourceSessionId) {
      throw const FormatException();
    }
    final created = _time(j['created_at']),
        ended = j['ended_at'] == null ? null : _time(j['ended_at']);
    if (ended != null && ended.isBefore(created)) {
      throw const FormatException();
    }
    return RelatedRehearsal._(
      id,
      sourceSessionId,
      _id(j['source_review_item_id']),
      PracticeStatus.values.byName(j['status'] as String),
      created,
      ended,
    );
  });
  final String id, sourceSessionId, itemId;
  final PracticeStatus status;
  final DateTime createdAt;
  final DateTime? endedAt;
  bool olderThan(RelatedRehearsal other) =>
      createdAt.isBefore(other.createdAt) ||
      createdAt == other.createdAt && id.compareTo(other.id) < 0;
  String get statusLabel => switch (status) {
    PracticeStatus.created => '已登记准备',
    PracticeStatus.connecting => '建连中',
    PracticeStatus.active => '练习中',
    PracticeStatus.interrupted => '练习已中断',
    PracticeStatus.ending => '结束处理中',
    PracticeStatus.completed => '练习已结束',
    PracticeStatus.cancelled => '准备已取消',
    PracticeStatus.failed => '练习未完成',
  };
}

final class RehearsalListPage {
  const RehearsalListPage._(this.items, this.nextBeforeId);
  factory RehearsalListPage.fromJson(
    Map<String, dynamic> j, {
    required String accountId,
    required String sourceSessionId,
    RelatedRehearsal? before,
  }) => _parse(() {
    _keys(j, {
      'schema_version',
      'source',
      'account_id',
      'source_session_id',
      'limit',
      'items',
      'next_before_id',
    });
    if (utf8.encode(jsonEncode(j)).length > 32768 ||
        j['schema_version'] != 'rehearsal_list_v1' ||
        j['source'] != 'server_recorded' ||
        _id(j['account_id']) != accountId ||
        _id(j['source_session_id']) != sourceSessionId ||
        j['limit'] is! int ||
        j['limit'] != 10 ||
        before != null && before.sourceSessionId != sourceSessionId) {
      throw const FormatException();
    }
    final raw = j['items'];
    if (raw is! List || raw.length > 10) {
      throw const FormatException();
    }
    final items = [
      for (final r in raw)
        RelatedRehearsal.fromJson(
          r as Map<String, dynamic>,
          sourceSessionId: sourceSessionId,
        ),
    ];
    final ids = <String>{};
    for (var i = 0; i < items.length; i++) {
      if (!ids.add(items[i].id) ||
          i > 0 && !items[i].olderThan(items[i - 1]) ||
          before != null && !items[i].olderThan(before)) {
        throw const FormatException();
      }
    }
    final next = j['next_before_id'] == null ? null : _id(j['next_before_id']);
    if (next != null && (items.length != 10 || next != items.last.id)) {
      throw const FormatException();
    }
    return RehearsalListPage._(List.unmodifiable(items), next);
  });
  final List<RelatedRehearsal> items;
  final String? nextBeforeId;
}
