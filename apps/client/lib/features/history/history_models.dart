import 'dart:convert';

import '../account/account_models.dart';
import '../practice/practice_models.dart';

T _parse<T>(T Function() read) {
  try {
    return read();
  } on Object {
    throw const FormatException('Invalid history response');
  }
}

String _id(dynamic v) {
  if (v is! String || !isPracticeUuid(v)) throw const FormatException();
  return v.toLowerCase();
}

DateTime _time(dynamic v) {
  if (v is! String || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(v)) {
    throw const FormatException();
  }
  return DateTime.parse(v).toUtc();
}

void _envelope(Map<String, dynamic> j, String accountId, String schema) {
  if (j['schema_version'] != schema ||
      j['source'] != 'server_recorded' ||
      _id(j['account_id']) != accountId) {
    throw const FormatException();
  }
}

final class HistoryItem {
  HistoryItem._(
    this.id,
    this.kind,
    this.sourceSessionId,
    this.status,
    this.createdAt,
    this.endedAt,
    this.difficulty,
    this.completionStatus,
    this.coverage,
    this.connectionPending,
  );
  factory HistoryItem.fromJson(Map<String, dynamic> j) => _parse(() {
    final id = _id(j['id']);
    final kind = j['kind'];
    final source = j['source_session_id'] == null
        ? null
        : _id(j['source_session_id']);
    if (!(kind == 'ordinary' && source == null ||
        kind == 'rehearsal' && source != null && source != id)) {
      throw const FormatException();
    }
    final completion = j['completion_status'], coverage = j['coverage'];
    if (!(completion == 'unregistered' && coverage == null ||
            completion == 'ending' && coverage == 'pending' ||
            completion == 'sealed' &&
                ['complete', 'incomplete'].contains(coverage)) ||
        j['connection_pending'] is! bool) {
      throw const FormatException();
    }
    final created = _time(j['created_at']);
    final ended = j['ended_at'] == null ? null : _time(j['ended_at']);
    if (ended != null && ended.isBefore(created)) throw const FormatException();
    return HistoryItem._(
      id,
      kind as String,
      source,
      PracticeStatus.values.byName(j['status'] as String),
      created,
      ended,
      j['difficulty'] == null
          ? null
          : Difficulty.values.byName(j['difficulty'] as String),
      completion as String,
      coverage as String?,
      j['connection_pending'] as bool,
    );
  });
  factory HistoryItem.fromDetail(
    Map<String, dynamic> j, {
    required String accountId,
    required String sessionId,
  }) => _parse(() {
    _envelope(j, accountId, 'practice_history_detail_v1');
    final item = HistoryItem.fromJson(j['item'] as Map<String, dynamic>);
    if (item.id != sessionId) throw const FormatException();
    return item;
  });
  final String id, kind;
  final String? sourceSessionId;
  final PracticeStatus status;
  final DateTime createdAt;
  final DateTime? endedAt;
  final Difficulty? difficulty;
  final String completionStatus;
  final String? coverage;
  final bool connectionPending;
  bool get isSealed => completionStatus == 'sealed';
  String get title => kind == 'ordinary' ? '自由聊天' : '逐句重练';
  String get difficultyLabel => difficulty?.label ?? '难度未记录';
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
  String get saveLabel => switch (completionStatus) {
    'ending' => '正在保存',
    'sealed' => coverage == 'complete' ? '文字已保存' : '文字已保存，部分内容缺失',
    _ => '尚未登记文字保存',
  };
}

final class HistoryPage {
  HistoryPage._(this.items, this.nextCursor);
  factory HistoryPage.fromJson(
    Map<String, dynamic> j, {
    required String accountId,
    String? cursor,
  }) => _parse(() {
    _envelope(j, accountId, 'practice_history_v1');
    final raw = j['items'];
    if (j['limit'] != 10 ||
        j['limit'] is! int ||
        raw is! List ||
        raw.length > 10) {
      throw const FormatException();
    }
    final items = [
      for (final row in raw) HistoryItem.fromJson(row as Map<String, dynamic>),
    ];
    for (var i = 1; i < items.length; i++) {
      final a = items[i - 1], b = items[i];
      if (a.createdAt.isBefore(b.createdAt) ||
          a.createdAt == b.createdAt && a.id.compareTo(b.id) <= 0 ||
          items.take(i).any((x) => x.id == b.id)) {
        throw const FormatException();
      }
    }
    (DateTime, String) boundary(dynamic value) {
      if (value is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(value)) {
        throw const FormatException();
      }
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(value))),
      );
      if (decoded is! List || decoded.length != 3 || decoded[0] != accountId) {
        throw const FormatException();
      }
      return (_time(decoded[1]), _id(decoded[2]));
    }

    if (cursor != null) {
      final (time, id) = boundary(cursor);
      if (items.any(
        (x) =>
            x.createdAt.isAfter(time) ||
            x.createdAt == time && x.id.compareTo(id) >= 0,
      )) {
        throw const FormatException();
      }
    }
    final next = j['next_cursor'];
    if (next != null) {
      final (time, id) = boundary(next);
      if (items.length != 10 ||
          time != items.last.createdAt ||
          id != items.last.id) {
        throw const FormatException();
      }
    }
    return HistoryPage._(List.unmodifiable(items), next as String?);
  });
  final List<HistoryItem> items;
  final String? nextCursor;
}
