import '../conversation/conversation_models.dart';
import 'practice_models.dart';
import 'submission_manifest.dart';

enum PracticeCompletionTailStatus { complete, unconfirmed, aborted }

enum PracticeCompletionStatus { ending, sealed }

enum PracticeCompletionCoverage { pending, complete, incomplete }

const practiceCompletionGapCodes = {
  'manifest_missing',
  'transcript_missing',
  'playback_missing',
  'transcript_unexpected',
  'playback_unexpected',
  'manifest_totals_mismatch',
  'transcript_rejected',
  'playback_rejected',
  'unfinalized_turn',
  'unconfirmed_response',
  'journal_unavailable',
  'tail_unconfirmed',
  'tail_aborted',
  'playback_revoked',
  'playback_unconfirmed',
};

bool sameCompletionScope(ConversationScope a, ConversationScope b) =>
    a.accountId == b.accountId &&
    a.sessionId == b.sessionId &&
    a.connectionId == b.connectionId &&
    a.clientInstanceId == b.clientInstanceId &&
    a.epoch == b.epoch;

String _id(dynamic value) {
  if (value is! String || !isPracticeUuid(value)) throw const FormatException();
  return value.toLowerCase();
}

int _number(dynamic value, int min, int max) {
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

List<String> _ids(Iterable<String> raw) {
  final ids = raw.take(257).map(_id).toList(growable: false);
  if (ids.length > 256 || ids.toSet().length != ids.length) {
    throw const FormatException();
  }
  return List.unmodifiable(ids);
}

/// A fixed body captured after local draining, never rebuilt after later ACKs.
final class PracticeCompletionManifest {
  PracticeCompletionManifest({
    required this.scope,
    required this.transcripts,
    required this.playback,
    required this.tailStatus,
    Iterable<String> unfinalizedTurnIds = const [],
    Iterable<String> unconfirmedResponseIds = const [],
    this.transcriptRejectedCount = 0,
    this.playbackRejectedCount = 0,
    this.journalUnavailable = false,
  }) : unfinalizedTurnIds = _ids(unfinalizedTurnIds),
       unconfirmedResponseIds = _ids(unconfirmedResponseIds) {
    if (transcripts.ledger != SubmissionLedger.transcripts ||
        playback.ledger != SubmissionLedger.playback) {
      throw const FormatException();
    }
    _number(transcriptRejectedCount, 0, 2147483647);
    _number(playbackRejectedCount, 0, 2147483647);
  }
  final ConversationScope scope;
  final SubmissionManifest transcripts;
  final SubmissionManifest playback;
  final PracticeCompletionTailStatus tailStatus;
  final List<String> unfinalizedTurnIds;
  final List<String> unconfirmedResponseIds;
  final int transcriptRejectedCount;
  final int playbackRejectedCount;
  final bool journalUnavailable;
  Map<String, dynamic> toRequestJson() => {
    'client_instance_id': scope.clientInstanceId,
    'epoch': scope.epoch,
    'transcripts': transcripts.toRequestJson(),
    'playback': playback.toRequestJson(),
    'tail_status': tailStatus.name,
    'unfinalized_turn_ids': unfinalizedTurnIds,
    'unconfirmed_response_ids': unconfirmedResponseIds,
    'transcript_rejected_count': transcriptRejectedCount,
    'playback_rejected_count': playbackRejectedCount,
    'journal_unavailable': journalUnavailable,
  };
}

/// A server input snapshot. Sealing never grants media or termination authority.
final class PracticeCompletionSummary {
  const PracticeCompletionSummary._({
    required this.scope,
    required this.endKey,
    required this.status,
    required this.acceptedAt,
    required this.finalUploadDeadline,
    required this.sealedAt,
    required this.inputRevision,
    required this.inputHash,
    required this.coverage,
    required this.connectionCount,
    required this.gapCodes,
  });
  factory PracticeCompletionSummary.fromJson(
    Map<String, dynamic> json, {
    required ConversationScope scope,
    String? endKey,
  }) {
    const keys = {
      'source',
      'account_id',
      'session_id',
      'origin_connection_id',
      'client_instance_id',
      'epoch',
      'end_key',
      'status',
      'accepted_at',
      'final_upload_deadline',
      'sealed_at',
      'input_revision',
      'input_hash',
      'coverage',
      'connection_count',
      'gap_codes',
    };
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['source'] != 'server_recorded' ||
        _id(json['account_id']) != scope.accountId ||
        _id(json['session_id']) != scope.sessionId ||
        _id(json['origin_connection_id']) != scope.connectionId ||
        _id(json['client_instance_id']) != scope.clientInstanceId ||
        _number(json['epoch'], 1, 2147483647) != scope.epoch) {
      throw const FormatException();
    }
    final key = _id(json['end_key']);
    if (endKey != null && key != _id(endKey)) throw const FormatException();
    final status = switch (json['status']) {
      'ending' => PracticeCompletionStatus.ending,
      'sealed' => PracticeCompletionStatus.sealed,
      _ => throw const FormatException(),
    };
    final coverage = switch (json['coverage']) {
      'pending' => PracticeCompletionCoverage.pending,
      'complete' => PracticeCompletionCoverage.complete,
      'incomplete' => PracticeCompletionCoverage.incomplete,
      _ => throw const FormatException(),
    };
    final accepted = _time(json['accepted_at']);
    final deadline = _time(json['final_upload_deadline']);
    if (deadline.difference(accepted) != const Duration(seconds: 30)) {
      throw const FormatException();
    }
    final sealed = json['sealed_at'] == null ? null : _time(json['sealed_at']);
    final revision = _number(json['input_revision'], 0, 1);
    final hash = json['input_hash'];
    if (json['gap_codes'] is! List) throw const FormatException();
    final gaps = <String>[];
    for (final raw in json['gap_codes'] as List) {
      if (raw is! String ||
          !practiceCompletionGapCodes.contains(raw) ||
          (gaps.isNotEmpty && gaps.last.compareTo(raw) >= 0)) {
        throw const FormatException();
      }
      gaps.add(raw);
    }
    if (status == PracticeCompletionStatus.ending
        ? sealed != null ||
              revision != 0 ||
              hash != null ||
              coverage != PracticeCompletionCoverage.pending
        : sealed == null ||
              sealed.isBefore(accepted) ||
              revision != 1 ||
              hash is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
              coverage == PracticeCompletionCoverage.pending ||
              ((coverage == PracticeCompletionCoverage.complete) !=
                  gaps.isEmpty)) {
      throw const FormatException();
    }
    return PracticeCompletionSummary._(
      scope: scope,
      endKey: key,
      status: status,
      acceptedAt: accepted,
      finalUploadDeadline: deadline,
      sealedAt: sealed,
      inputRevision: revision,
      inputHash: hash as String?,
      coverage: coverage,
      connectionCount: _number(json['connection_count'], 1, 2147483647),
      gapCodes: List.unmodifiable(gaps),
    );
  }
  final ConversationScope scope;
  final String endKey;
  final PracticeCompletionStatus status;
  final DateTime acceptedAt;
  final DateTime finalUploadDeadline;
  final DateTime? sealedAt;
  final int inputRevision;
  final String? inputHash;
  final PracticeCompletionCoverage coverage;
  final int connectionCount;
  final List<String> gapCodes;

  bool sameFixedIdentity(PracticeCompletionSummary other) =>
      sameCompletionScope(scope, other.scope) &&
      endKey == other.endKey &&
      acceptedAt == other.acceptedAt &&
      finalUploadDeadline == other.finalUploadDeadline &&
      connectionCount == other.connectionCount;
  bool sameSealedInput(PracticeCompletionSummary other) =>
      sameFixedIdentity(other) &&
      status == other.status &&
      sealedAt == other.sealedAt &&
      inputRevision == other.inputRevision &&
      inputHash == other.inputHash &&
      coverage == other.coverage &&
      gapCodes.join(',') == other.gapCodes.join(',');
}

/// Scope-bound received event identities, separate from a client's declaration.
final class PracticeCompletionReceipt {
  const PracticeCompletionReceipt._({
    required this.scope,
    required this.inputHash,
    required this.practiceInputHash,
    required this.transcripts,
    required this.playback,
  });
  factory PracticeCompletionReceipt.fromJson(
    Map<String, dynamic> json, {
    required ConversationScope scope,
    required String practiceInputHash,
  }) {
    const keys = {
      'source',
      'account_id',
      'session_id',
      'connection_id',
      'client_instance_id',
      'epoch',
      'sealed',
      'recoverable',
      'input_revision',
      'input_hash',
      'practice_input_hash',
      'transcript_events',
      'playback_events',
    };
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['source'] != 'server_recorded' ||
        _id(json['account_id']) != scope.accountId ||
        _id(json['session_id']) != scope.sessionId ||
        _id(json['connection_id']) != scope.connectionId ||
        _id(json['client_instance_id']) != scope.clientInstanceId ||
        _number(json['epoch'], 1, 2147483647) != scope.epoch ||
        json['sealed'] != true ||
        json['recoverable'] != false ||
        json['input_revision'] is! int ||
        json['input_revision'] != 1 ||
        json['practice_input_hash'] != practiceInputHash ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(practiceInputHash) ||
        json['input_hash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['input_hash'] as String)) {
      throw const FormatException();
    }
    SubmissionManifest refs(dynamic raw, SubmissionLedger ledger) {
      if (raw is! List) throw const FormatException();
      var last = 0;
      if (raw.isNotEmpty) {
        if (raw.last is! Map<String, dynamic> || raw.last['sequence'] is! int) {
          throw const FormatException();
        }
        last = raw.last['sequence'] as int;
      }
      return SubmissionManifest.fromJson({
        'events': raw,
        'last_sequence': last,
        'total_events': raw.length,
        'total_text_bytes': 0,
        'pending_count_at_close': 0,
      }, ledger: ledger);
    }

    return PracticeCompletionReceipt._(
      scope: scope,
      inputHash: json['input_hash'] as String,
      practiceInputHash: practiceInputHash,
      transcripts: refs(
        json['transcript_events'],
        SubmissionLedger.transcripts,
      ),
      playback: refs(json['playback_events'], SubmissionLedger.playback),
    );
  }
  final ConversationScope scope;
  final String inputHash;
  final String practiceInputHash;
  final SubmissionManifest transcripts;
  final SubmissionManifest playback;
  int get inputRevision => 1;
  bool get sealed => true;
  bool get recoverable => false;
}
