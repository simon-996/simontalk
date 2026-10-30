import 'dart:convert';
import 'dart:math' as math;

import '../practice/practice_completion_models.dart';
import '../practice/practice_models.dart';
import '../review/review_models.dart';

const savedTranscriptMaxBytes = 512 * 1024;
void _keys(Map<String, dynamic> j, String fields) {
  final keys = fields.split(' ').toSet();
  if (j.length != keys.length || !j.keys.every(keys.contains)) {
    throw const FormatException();
  }
}

String _id(dynamic x) {
  if (x is! String || !isPracticeUuid(x)) throw const FormatException();
  return x.toLowerCase();
}

String _hash(dynamic x) {
  if (x is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(x)) {
    throw const FormatException();
  }
  return x;
}

int _int(dynamic x, int min, int max) {
  if (x is! int || x < min || x > max) throw const FormatException();
  return x;
}

Map<String, dynamic> _map(dynamic x) {
  if (x is! Map<String, dynamic>) throw const FormatException();
  return x;
}

String _text(dynamic x, {bool nonempty = false}) {
  if (x is! String ||
      x.contains('\u0000') ||
      utf8.encode(x).length > 8192 ||
      (nonempty && x.isEmpty)) {
    throw const FormatException();
  }
  final units = x.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (++i >= units.length || units[i] < 0xDC00 || units[i] > 0xDFFF) {
        throw const FormatException();
      }
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      throw const FormatException();
    }
  }
  return x;
}

DateTime _time(dynamic x) {
  if (x is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|\+00:00)$',
      ).hasMatch(x)) {
    throw const FormatException();
  }
  final p = [
    int.parse(x.substring(0, 4)),
    int.parse(x.substring(5, 7)),
    int.parse(x.substring(8, 10)),
    int.parse(x.substring(11, 13)),
    int.parse(x.substring(14, 16)),
    int.parse(x.substring(17, 19)),
  ];
  final t = DateTime.utc(p[0], p[1], p[2], p[3], p[4], p[5]);
  if (p[0] < 1 ||
      t.year != p[0] ||
      t.month != p[1] ||
      t.day != p[2] ||
      t.hour != p[3] ||
      t.minute != p[4] ||
      t.second != p[5]) {
    throw const FormatException();
  }
  return DateTime.parse(x).toUtc();
}

final class SavedTranscriptTurn {
  const SavedTranscriptTurn._(
    this.ordinal,
    this.connectionId,
    this.clientInstanceId,
    this.epoch,
    this.turnId,
    this.turnIndex,
    this.revision,
    this.role,
    this.finalText,
    this.finalSource,
    this.playbackStatus,
    this.playedText,
    this.playedRevision,
  );
  factory SavedTranscriptTurn.fromJson(Map<String, dynamic> j) {
    _keys(
      j,
      'ordinal connection_id client_instance_id epoch turn_id turn_index revision role final_text final_source playback_status played_text played_revision',
    );
    final role = j['role'];
    if (role != 'user' && role != 'assistant') throw const FormatException();
    final rev = _int(j['revision'], role == 'user' ? 1 : 0, 2147483647);
    final text = j['final_text'] == null ? null : _text(j['final_text']);
    final source = j['final_source'];
    final status = j['playback_status'];
    final played = j['played_text'] == null
        ? null
        : _text(j['played_text'], nonempty: true);
    final playedRev = j['played_revision'] == null
        ? null
        : _int(j['played_revision'], 1, 2147483647);
    if ((text == null) != (source == null) ||
        (source != null &&
            source != 'final_transcript' &&
            source != 'playback_final')) {
      throw const FormatException();
    }
    if (role == 'user') {
      if (text == null ||
          source != 'final_transcript' ||
          status != null ||
          played != null ||
          playedRev != null) {
        throw const FormatException();
      }
    } else {
      if (!{
        'unknown',
        'played',
        'partial',
        'not_played',
        'revoked',
      }.contains(status)) {
        throw const FormatException();
      }
      final prefix = status == 'played' || status == 'partial';
      if (prefix != (played != null) || prefix != (playedRev != null)) {
        throw const FormatException();
      }
      if (rev == 0 &&
          (text != null ||
              played != null ||
              !{'unknown', 'revoked'}.contains(status))) {
        throw const FormatException();
      }
      if (status == 'not_played' && text == null) throw const FormatException();
      if (playedRev != null &&
          (playedRev > rev ||
              (playedRev == rev &&
                  text != null &&
                  (!text.startsWith(played!) ||
                      (status == 'played' && text != played) ||
                      (status == 'partial' && text == played))))) {
        throw const FormatException();
      }
    }
    return SavedTranscriptTurn._(
      _int(j['ordinal'], 1, 8192),
      _id(j['connection_id']),
      _id(j['client_instance_id']),
      _int(j['epoch'], 1, 2147483647),
      _id(j['turn_id']),
      _int(j['turn_index'], 0, 2147483647),
      rev,
      role,
      text,
      source as String?,
      status as String?,
      played,
      playedRev,
    );
  }
  final int ordinal, epoch, turnIndex, revision;
  final String connectionId, clientInstanceId, turnId, role;
  final String? finalText, finalSource, playbackStatus, playedText;
  final int? playedRevision;
}

final class SavedTranscriptFocus {
  const SavedTranscriptFocus._(
    this.itemId,
    this.jobId,
    this.resultHash,
    this.connectionId,
    this.turnId,
    this.revision,
    this.exactQuote,
    this.ordinal,
  );
  factory SavedTranscriptFocus.fromJson(Map<String, dynamic> j) {
    _keys(
      j,
      'item_id job_id result_hash connection_id turn_id revision exact_quote ordinal',
    );
    final quote = _text(j['exact_quote'], nonempty: true);
    if (quote.trim().isEmpty) throw const FormatException();
    return SavedTranscriptFocus._(
      _id(j['item_id']),
      _id(j['job_id']),
      _hash(j['result_hash']),
      _id(j['connection_id']),
      _id(j['turn_id']),
      _int(j['revision'], 1, 2147483647),
      quote,
      _int(j['ordinal'], 1, 8192),
    );
  }
  final String itemId, jobId, resultHash, connectionId, turnId, exactQuote;
  final int revision, ordinal;
  bool matches(SavedTranscriptTurn t) =>
      t.ordinal == ordinal &&
      t.connectionId == connectionId &&
      t.turnId == turnId &&
      t.revision == revision &&
      t.role == 'user' &&
      t.finalText!.contains(exactQuote);
  @override
  bool operator ==(Object other) =>
      other is SavedTranscriptFocus &&
      itemId == other.itemId &&
      jobId == other.jobId &&
      resultHash == other.resultHash &&
      connectionId == other.connectionId &&
      turnId == other.turnId &&
      revision == other.revision &&
      exactQuote == other.exactQuote &&
      ordinal == other.ordinal;
  @override
  int get hashCode => Object.hash(
    itemId,
    jobId,
    resultHash,
    connectionId,
    turnId,
    revision,
    exactQuote,
    ordinal,
  );
}

/// One bounded page; no complete transcript or ReviewInput/Job is held here.
final class SavedTranscriptPage {
  const SavedTranscriptPage._(
    this.target,
    this.sealedAt,
    this.coverage,
    this.gapCodes,
    this.totalTurns,
    this.offset,
    this.limit,
    this.previousOffset,
    this.nextOffset,
    this.focus,
    this.items,
  );
  factory SavedTranscriptPage.fromJson(
    Map<String, dynamic> j, {
    required ReviewTarget target,
    int? offset,
    String? reviewItemId,
    int limit = 16,
  }) {
    _keys(
      j,
      'schema_version source evidence_source account_id session_id input_revision practice_input_hash sealed_at coverage gap_codes total_turns offset limit previous_offset next_offset focus items',
    );
    if (utf8.encode(jsonEncode(j)).length > savedTranscriptMaxBytes ||
        j['schema_version'] != 'saved_transcript_v1' ||
        j['source'] != 'server_derived' ||
        j['evidence_source'] != 'client_reported' ||
        _id(j['account_id']) != target.accountId ||
        _id(j['session_id']) != target.sessionId ||
        _int(j['input_revision'], 1, 1) != target.inputRevision ||
        _hash(j['practice_input_hash']) != target.practiceInputHash) {
      throw const FormatException();
    }
    final sealed = _time(j['sealed_at']);
    final coverage = j['coverage'];
    final rawGaps = j['gap_codes'];
    if (!{'complete', 'incomplete'}.contains(coverage) ||
        rawGaps is! List ||
        rawGaps.any(
          (x) => x is! String || !practiceCompletionGapCodes.contains(x),
        )) {
      throw const FormatException();
    }
    final gaps = rawGaps.cast<String>();
    if (gaps.toSet().length != gaps.length ||
        (coverage == 'complete') != gaps.isEmpty) {
      throw const FormatException();
    }
    final total = _int(j['total_turns'], 0, 8192);
    final start = _int(j['offset'], 0, total);
    final size = _int(j['limit'], 1, 16);
    final focus = j['focus'] == null
        ? null
        : SavedTranscriptFocus.fromJson(_map(j['focus']));
    if ((reviewItemId == null) != (focus == null) ||
        (reviewItemId != null && focus!.itemId != _id(reviewItemId)) ||
        (focus != null && focus.ordinal > total)) {
      throw const FormatException();
    }
    final expected = offset ?? (focus == null ? 0 : focus.ordinal - 1);
    if (start != expected || size != limit || j['items'] is! List) {
      throw const FormatException();
    }
    final items = [
      for (final x in j['items']) SavedTranscriptTurn.fromJson(_map(x)),
    ];
    if (items.length != math.min(size, total - start)) {
      throw const FormatException();
    }
    final seen = <String>{};
    for (var i = 0; i < items.length; i++) {
      final t = items[i];
      if (t.ordinal != start + i + 1 ||
          !seen.add('${t.connectionId}/${t.turnId}')) {
        throw const FormatException();
      }
      if (focus?.ordinal == t.ordinal && !focus!.matches(t)) {
        throw const FormatException();
      }
    }
    final prev = j['previous_offset'] == null
        ? null
        : _int(j['previous_offset'], 0, 8192);
    final next = j['next_offset'] == null
        ? null
        : _int(j['next_offset'], 0, 8192);
    if (prev != (start > 0 ? math.max(0, start - size) : null) ||
        next != (start + items.length < total ? start + items.length : null)) {
      throw const FormatException();
    }
    return SavedTranscriptPage._(
      target,
      sealed,
      coverage as String,
      List.unmodifiable(gaps),
      total,
      start,
      size,
      prev,
      next,
      focus,
      List.unmodifiable(items),
    );
  }
  final ReviewTarget target;
  final DateTime sealedAt;
  final String coverage;
  final List<String> gapCodes;
  final int totalTurns, offset, limit;
  final int? previousOffset, nextOffset;
  final SavedTranscriptFocus? focus;
  final List<SavedTranscriptTurn> items;
  bool hasSameAnchor(SavedTranscriptPage o) =>
      target == o.target &&
      sealedAt == o.sealedAt &&
      coverage == o.coverage &&
      totalTurns == o.totalTurns &&
      focus == o.focus &&
      gapCodes.length == o.gapCodes.length &&
      gapCodes.toSet().containsAll(o.gapCodes);
}
