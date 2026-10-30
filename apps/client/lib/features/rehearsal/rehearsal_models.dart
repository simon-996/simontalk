import 'dart:convert';

import '../account/account_models.dart';
import '../practice/practice_models.dart';

String rehearsalId(dynamic value) {
  if (value is! String || !isPracticeUuid(value)) throw const FormatException();
  return value.toLowerCase();
}

void _keys(Map<String, dynamic> j, Set<String> keys) {
  if (j.length != keys.length || !j.keys.every(keys.contains)) {
    throw const FormatException();
  }
}

void _hash(dynamic value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException();
  }
}

void _positive(dynamic value) {
  if (value is! int || value < 1 || value > 2147483647) {
    throw const FormatException();
  }
}

void _text(dynamic value, int bytes, {bool empty = false}) {
  if (value is! String ||
      (!empty && value.trim().isEmpty) ||
      value.contains('\u0000') ||
      utf8.encode(value).length > bytes) {
    throw const FormatException();
  }
}

dynamic _freeze(dynamic value) => value is Map<String, dynamic>
    ? Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k, _freeze(v))),
      )
    : value is List
    ? List<dynamic>.unmodifiable(value.map(_freeze))
    : value;
String _sortedJson(dynamic value) {
  dynamic sort(dynamic v) => v is Map<String, dynamic>
      ? {for (final key in (v.keys.toList()..sort())) key: sort(v[key])}
      : v is List
      ? v.map(sort).toList()
      : v;
  return jsonEncode(sort(value));
}

/// Verified by the server; the original hash binds the explicit creation request.
/// No target is synthesized from a review quote or stored in device persistence.
final class RehearsalTarget {
  const RehearsalTarget._(this._data);
  factory RehearsalTarget.fromJson(
    Map<String, dynamic> j, {
    required String accountId,
    required String sourceSessionId,
    required String itemId,
  }) {
    _keys(j, {
      'schema_version',
      'source',
      'evidence_source',
      'account_id',
      'source_session_id',
      'source_kind',
      'item_id',
      'job_id',
      'result_hash',
      'input_revision',
      'practice_input_hash',
      'review_input_hash',
      'policy_version',
      'generation_policy_version',
      'source_connection_id',
      'source_client_instance_id',
      'source_epoch',
      'source_turn_id',
      'revision',
      'source_text',
      'exact_quote',
      'kind',
      'basis',
      'explanation',
      'suggestion',
      'situation_mode',
      'context_before',
      'target_hash',
    });
    if (utf8.encode(jsonEncode(j)).length > 64 * 1024 ||
        j['schema_version'] != 'rehearsal_target_v1' ||
        j['source'] != 'server_derived' ||
        j['evidence_source'] != 'client_reported' ||
        j['source_kind'] != 'ordinary' ||
        rehearsalId(j['account_id']) != accountId ||
        rehearsalId(j['source_session_id']) != sourceSessionId ||
        rehearsalId(j['item_id']) != itemId ||
        j['input_revision'] is! int ||
        j['input_revision'] != 1 ||
        j['policy_version'] != 'review_input_v1' ||
        j['generation_policy_version'] != 'review_generation_v1' ||
        j['situation_mode'] != 'source_original' ||
        !['correction', 'polish', 'extension'].contains(j['kind']) ||
        !['text_only', 'conversation_context'].contains(j['basis'])) {
      throw const FormatException();
    }
    for (final key in [
      'job_id',
      'source_connection_id',
      'source_client_instance_id',
      'source_turn_id',
    ]) {
      rehearsalId(j[key]);
    }
    for (final key in [
      'result_hash',
      'practice_input_hash',
      'review_input_hash',
      'target_hash',
    ]) {
      _hash(j[key]);
    }
    for (final key in ['source_epoch', 'revision']) {
      _positive(j[key]);
    }
    for (final key in [
      'source_text',
      'exact_quote',
      'suggestion',
      'explanation',
    ]) {
      _text(j[key], key == 'explanation' ? 16384 : 8192);
    }
    if (!(j['source_text'] as String).contains(j['exact_quote'] as String)) {
      throw const FormatException();
    }
    final context = j['context_before'];
    if (context is! List ||
        context.length > 8192 ||
        j['basis'] == 'text_only' && context.isNotEmpty) {
      throw const FormatException();
    }
    for (final raw in context) {
      if (raw is! Map<String, dynamic>) throw const FormatException();
      _keys(raw, {
        'ledger',
        'event_id',
        'event_digest',
        'turn_id',
        'turn_index',
        'role',
        'revision',
        'text',
      });
      if (!['transcripts', 'playback'].contains(raw['ledger']) ||
          !['user', 'assistant'].contains(raw['role']) ||
          raw['ledger'] == 'playback' && raw['role'] != 'assistant') {
        throw const FormatException();
      }
      rehearsalId(raw['event_id']);
      rehearsalId(raw['turn_id']);
      _hash(raw['event_digest']);
      _positive(raw['turn_index']);
      _positive(raw['revision']);
      _text(raw['text'], 64 * 1024, empty: true);
    }
    return RehearsalTarget._(_freeze(j) as Map<String, dynamic>);
  }
  final Map<String, dynamic> _data;
  String get sourceSessionId => _data['source_session_id'] as String;
  String get itemId => _data['item_id'] as String;
  String get targetHash => _data['target_hash'] as String;
  String get sourceText => _data['source_text'] as String;
  String get exactQuote => _data['exact_quote'] as String;
  String get suggestion => _data['suggestion'] as String;
  String get explanation => _data['explanation'] as String;
  String get kind => _data['kind'] as String;
  List<dynamic> get contextBefore => _data['context_before'] as List<dynamic>;
  Map<String, dynamic> toJson() => _data;
  bool matches(RehearsalTarget other) =>
      _sortedJson(_data) == _sortedJson(other._data);
}

PracticePreparation rehearsalPractice(
  Map<String, dynamic> j, {
  required String sourceSessionId,
  required String itemId,
  String? childId,
}) {
  final p = PracticePreparation.fromJson(j);
  if (j['kind'] != 'rehearsal' ||
      rehearsalId(j['source_session_id']) != sourceSessionId ||
      rehearsalId(j['source_review_item_id']) != itemId ||
      p.id == sourceSessionId ||
      childId != null && p.id != childId) {
    throw const FormatException();
  }
  return p;
}

PracticePreparation readRehearsalPreparation(
  Map<String, dynamic> j, {
  required String accountId,
  required RehearsalTarget expected,
  required Difficulty difficulty,
}) {
  _keys(j, {'schema_version', 'source', 'account_id', 'practice', 'target'});
  if (j['schema_version'] != 'rehearsal_preparation_v1' ||
      j['source'] != 'server_recorded' ||
      rehearsalId(j['account_id']) != accountId) {
    throw const FormatException();
  }
  final target = RehearsalTarget.fromJson(
    j['target'] as Map<String, dynamic>,
    accountId: accountId,
    sourceSessionId: expected.sourceSessionId,
    itemId: expected.itemId,
  );
  if (!expected.matches(target)) throw const FormatException();
  final p = rehearsalPractice(
    j['practice'] as Map<String, dynamic>,
    sourceSessionId: expected.sourceSessionId,
    itemId: expected.itemId,
  );
  if (p.configuration.effectiveDifficulty != difficulty) {
    throw const FormatException();
  }
  return p;
}
