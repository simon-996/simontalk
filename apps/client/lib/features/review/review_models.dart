import 'dart:convert';

import '../practice/practice_completion_models.dart';
import '../practice/practice_models.dart';

const reviewInputPolicy = 'review_input_v1';
const reviewGenerationPolicy = 'review_generation_v1';

void _keys(Map<String, dynamic> json, Set<String> keys) {
  if (json.length != keys.length || !json.keys.every(keys.contains)) {
    throw const FormatException('Unexpected review fields');
  }
}

String _id(dynamic value) {
  if (value is! String || !isPracticeUuid(value)) throw const FormatException();
  return value.toLowerCase();
}

String _hash(dynamic value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

int _integer(dynamic value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException();
  }
  return value;
}

DateTime _time(dynamic raw) {
  if (raw is! String) throw const FormatException();
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|\+00:00)$',
  ).firstMatch(raw);
  if (match == null) throw const FormatException();
  final p = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
  final date = DateTime.utc(p[0], p[1], p[2], p[3], p[4], p[5]);
  if (p[0] < 1 ||
      date.year != p[0] ||
      date.month != p[1] ||
      date.day != p[2] ||
      date.hour != p[3] ||
      date.minute != p[4] ||
      date.second != p[5]) {
    throw const FormatException();
  }
  return DateTime.parse(raw).toUtc();
}

Map<String, dynamic> _object(dynamic raw) {
  if (raw is! Map<String, dynamic>) throw const FormatException();
  return raw;
}

String _text(dynamic value, int limit) {
  if (value is! String || value.trim().isEmpty || value.runes.length > limit) {
    throw const FormatException();
  }
  return value;
}

/// Only a parsed, sealed completion can supply this immutable provider key.
final class ReviewTarget {
  const ReviewTarget._(
    this.accountId,
    this.sessionId,
    this.inputRevision,
    this.practiceInputHash,
  );
  factory ReviewTarget.fromCompletion(PracticeCompletionSummary summary) {
    if (summary.status != PracticeCompletionStatus.sealed ||
        summary.inputRevision != 1) {
      throw const FormatException();
    }
    return ReviewTarget._(
      _id(summary.scope.accountId),
      _id(summary.scope.sessionId),
      1,
      _hash(summary.inputHash),
    );
  }
  final String accountId, sessionId, practiceInputHash;
  final int inputRevision;
  @override
  bool operator ==(Object other) =>
      other is ReviewTarget &&
      accountId == other.accountId &&
      sessionId == other.sessionId &&
      inputRevision == other.inputRevision &&
      practiceInputHash == other.practiceInputHash;
  @override
  int get hashCode =>
      Object.hash(accountId, sessionId, inputRevision, practiceInputHash);
}

enum ReviewInputStatus { ready, noEvaluableContent }

/// Deliberately stores no scope, original utterance, or context copies.
final class ReviewInputBinding {
  const ReviewInputBinding._(
    this.target,
    this.reviewInputHash,
    this.createdAt,
    this.status,
    this.eligibleCount,
    this.uncertainCount,
    this.excludedCount,
  );
  factory ReviewInputBinding.fromJson(
    Map<String, dynamic> json, {
    required ReviewTarget target,
  }) {
    _keys(json, {
      'source',
      'evidence_source',
      'account_id',
      'session_id',
      'input_revision',
      'practice_input_hash',
      'policy_version',
      'review_input_hash',
      'created_at',
      'status',
      'counts',
      'scopes',
    });
    if (utf8.encode(jsonEncode(json)).length > 512 * 1024 ||
        json['source'] != 'server_derived' ||
        json['evidence_source'] != 'client_reported') {
      throw const FormatException();
    }
    _binding(json, target);
    final hash = _hash(json['review_input_hash']);
    final created = _time(json['created_at']);
    final counts = _object(json['counts']);
    _keys(counts, {'eligible', 'uncertain', 'excluded'});
    final eligible = _integer(counts['eligible'], 0, 8192),
        uncertain = _integer(counts['uncertain'], 0, 8192),
        excluded = _integer(counts['excluded'], 0, 8192);
    final scopes = json['scopes'];
    if (scopes is! List ||
        scopes.length > 32 ||
        eligible + uncertain + excluded > 8192) {
      throw const FormatException();
    }
    final actual = {'eligible': 0, 'uncertain': 0, 'excluded': 0};
    final connections = <String>{};
    var total = 0;
    for (final raw in scopes) {
      final scope = _object(raw);
      _keys(scope, {
        'account_id',
        'session_id',
        'connection_id',
        'client_instance_id',
        'epoch',
        'decisions',
      });
      if (_id(scope['account_id']) != target.accountId ||
          _id(scope['session_id']) != target.sessionId ||
          !connections.add(_id(scope['connection_id']))) {
        throw const FormatException();
      }
      _id(scope['client_instance_id']);
      _integer(scope['epoch'], 1, 2147483647);
      final decisions = scope['decisions'];
      if (decisions is! List || (total += decisions.length) > 8192) {
        throw const FormatException();
      }
      for (final raw in decisions) {
        final decision = _object(raw);
        final category = decision['eligibility'];
        if (!actual.containsKey(category)) throw const FormatException();
        actual[category as String] = actual[category]! + 1;
      }
    }
    if (actual['eligible'] != eligible ||
        actual['uncertain'] != uncertain ||
        actual['excluded'] != excluded) {
      throw const FormatException();
    }
    final status = switch (json['status']) {
      'ready' => ReviewInputStatus.ready,
      'no_evaluable_content' => ReviewInputStatus.noEvaluableContent,
      _ => throw const FormatException(),
    };
    if ((status == ReviewInputStatus.ready) != (eligible + uncertain > 0)) {
      throw const FormatException();
    }
    return ReviewInputBinding._(
      target,
      hash,
      created,
      status,
      eligible,
      uncertain,
      excluded,
    );
  }
  final ReviewTarget target;
  final String reviewInputHash;
  final DateTime createdAt;
  final ReviewInputStatus status;
  final int eligibleCount, uncertainCount, excludedCount;
  String get policyVersion => reviewInputPolicy;
  Map<String, dynamic> toJobRequestJson() => {
    'input_revision': target.inputRevision,
    'practice_input_hash': target.practiceInputHash,
    'review_input_hash': reviewInputHash,
    'policy_version': policyVersion,
  };
}

void _binding(
  Map<String, dynamic> json,
  ReviewTarget target, {
  String? reviewHash,
  bool identity = true,
}) {
  if ((identity &&
          (_id(json['account_id']) != target.accountId ||
              _id(json['session_id']) != target.sessionId)) ||
      _integer(json['input_revision'], 1, 1) != target.inputRevision ||
      _hash(json['practice_input_hash']) != target.practiceInputHash ||
      json['policy_version'] != reviewInputPolicy ||
      (reviewHash != null && _hash(json['review_input_hash']) != reviewHash)) {
    throw const FormatException();
  }
}

enum ReviewJobStatus {
  queued,
  running,
  retryWait,
  blocked,
  succeeded,
  noSuggestions,
  noEvaluableContent,
  failed,
  invalidated,
}

enum ReviewItemKind { correction, polish, extension }

enum ReviewItemBasis { textOnly, conversationContext }

final class ReviewItem {
  const ReviewItem._(
    this.id,
    this.ordinal,
    this.sourceConnectionId,
    this.sourceTurnId,
    this.revision,
    this.exactQuote,
    this.kind,
    this.basis,
    this.explanation,
    this.suggestion,
  );
  factory ReviewItem.fromJson(
    Map<String, dynamic> json, {
    required int ordinal,
  }) {
    _keys(json, {
      'id',
      'ordinal',
      'source_connection_id',
      'source_turn_id',
      'revision',
      'exact_quote',
      'kind',
      'basis',
      'explanation',
      'suggestion',
    });
    if (_integer(json['ordinal'], 1, 3) != ordinal) {
      throw const FormatException();
    }
    return ReviewItem._(
      _id(json['id']),
      ordinal,
      _id(json['source_connection_id']),
      _id(json['source_turn_id']),
      _integer(json['revision'], 1, 2147483647),
      _text(json['exact_quote'], 8192),
      switch (json['kind']) {
        'correction' => ReviewItemKind.correction,
        'polish' => ReviewItemKind.polish,
        'extension' => ReviewItemKind.extension,
        _ => throw const FormatException(),
      },
      switch (json['basis']) {
        'text_only' => ReviewItemBasis.textOnly,
        'conversation_context' => ReviewItemBasis.conversationContext,
        _ => throw const FormatException(),
      },
      _text(json['explanation'], 4096),
      _text(json['suggestion'], 8192),
    );
  }
  final String id,
      sourceConnectionId,
      sourceTurnId,
      exactQuote,
      explanation,
      suggestion;
  final int ordinal, revision;
  final ReviewItemKind kind;
  final ReviewItemBasis basis;
}

enum RehearsalIntentStatus { conveyed, changed, insufficientEvidence }

enum RehearsalTargetIssueStatus {
  demonstrated,
  stillPresent,
  notDemonstrated,
  insufficientEvidence,
}

String _evaluationText(dynamic value, int limit, int byteLimit) {
  if (value is! String || value.trim().isEmpty || value.contains('\u0000')) {
    throw const FormatException();
  }
  // Dart strings can contain unpaired UTF-16 surrogates. Reject those before
  // UTF-8 encoding can replace them, then count Unicode scalar values.
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length ||
          value.codeUnitAt(i) < 0xdc00 ||
          value.codeUnitAt(i) > 0xdfff) {
        throw const FormatException();
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException();
    }
  }
  if (value.runes.length > limit || utf8.encode(value).length > byteLimit) {
    throw const FormatException();
  }
  return value;
}

String _evaluationId(dynamic value) {
  if (value is! String || value != value.toLowerCase()) {
    throw const FormatException();
  }
  return _id(value);
}

/// A server-validated quote reference; this client has no transcript here with
/// which to independently verify its substring or source eligibility.
final class RehearsalEvaluationEvidence {
  const RehearsalEvaluationEvidence._(
    this.sourceConnectionId,
    this.sourceTurnId,
    this.revision,
    this.exactQuote,
  );
  factory RehearsalEvaluationEvidence.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'source_connection_id',
      'source_turn_id',
      'revision',
      'exact_quote',
    });
    return RehearsalEvaluationEvidence._(
      _evaluationId(json['source_connection_id']),
      _evaluationId(json['source_turn_id']),
      _integer(json['revision'], 1, 2147483647),
      _evaluationText(json['exact_quote'], 8192, 32768),
    );
  }
  final String sourceConnectionId, sourceTurnId, exactQuote;
  final int revision;
}

final class RehearsalEvaluationConclusion<T extends Enum> {
  const RehearsalEvaluationConclusion._(
    this.status,
    this.explanation,
    this.evidence,
  );
  final T status;
  final String explanation;
  final List<RehearsalEvaluationEvidence> evidence;
}

RehearsalEvaluationConclusion<T> _evaluationConclusion<T extends Enum>(
  dynamic raw,
  T Function(dynamic) parseStatus, {
  required T insufficient,
}) {
  final json = _object(raw);
  _keys(json, {'status', 'explanation', 'evidence'});
  final status = parseStatus(json['status']);
  final rows = json['evidence'];
  if (rows is! List ||
      rows.length > 3 ||
      (status != insufficient && rows.isEmpty)) {
    throw const FormatException();
  }
  return RehearsalEvaluationConclusion._(
    status,
    _evaluationText(json['explanation'], 4096, 16384),
    List.unmodifiable([
      for (final row in rows)
        RehearsalEvaluationEvidence.fromJson(_object(row)),
    ]),
  );
}

final class RehearsalEvaluation {
  const RehearsalEvaluation._(this.targetHash, this.intent, this.targetIssue);
  factory RehearsalEvaluation.fromJson(Map<String, dynamic> json) {
    _keys(json, {'schema_version', 'target_hash', 'intent', 'target_issue'});
    if (json['schema_version'] != 'rehearsal_evaluation_v1') {
      throw const FormatException();
    }
    return RehearsalEvaluation._(
      _hash(json['target_hash']),
      _evaluationConclusion(
        json['intent'],
        (raw) => switch (raw) {
          'conveyed' => RehearsalIntentStatus.conveyed,
          'changed' => RehearsalIntentStatus.changed,
          'insufficient_evidence' => RehearsalIntentStatus.insufficientEvidence,
          _ => throw const FormatException(),
        },
        insufficient: RehearsalIntentStatus.insufficientEvidence,
      ),
      _evaluationConclusion(
        json['target_issue'],
        (raw) => switch (raw) {
          'demonstrated' => RehearsalTargetIssueStatus.demonstrated,
          'still_present' => RehearsalTargetIssueStatus.stillPresent,
          'not_demonstrated' => RehearsalTargetIssueStatus.notDemonstrated,
          'insufficient_evidence' =>
            RehearsalTargetIssueStatus.insufficientEvidence,
          _ => throw const FormatException(),
        },
        insufficient: RehearsalTargetIssueStatus.insufficientEvidence,
      ),
    );
  }
  final String targetHash;
  final RehearsalEvaluationConclusion<RehearsalIntentStatus> intent;
  final RehearsalEvaluationConclusion<RehearsalTargetIssueStatus> targetIssue;
}

final class ReviewResult {
  const ReviewResult._(
    this.jobId,
    this.input,
    this.resultHash,
    this.createdAt,
    this.items,
    this.rehearsalEvaluation,
  );
  factory ReviewResult.fromJson(
    Map<String, dynamic> json, {
    required String jobId,
    required ReviewInputBinding input,
  }) {
    _keys(json, {
      'schema_version',
      'version',
      'job_id',
      'input_revision',
      'practice_input_hash',
      'review_input_hash',
      'policy_version',
      'generation_policy_version',
      'items',
      'result_hash',
      'created_at',
      if (json.containsKey('rehearsal_evaluation')) 'rehearsal_evaluation',
    });
    _binding(
      json,
      input.target,
      reviewHash: input.reviewInputHash,
      identity: false,
    );
    if (json['schema_version'] != 'review_result_v1' ||
        _integer(json['version'], 1, 1) != 1 ||
        _id(json['job_id']) != jobId ||
        json['generation_policy_version'] != reviewGenerationPolicy) {
      throw const FormatException();
    }
    final rows = json['items'];
    if (rows is! List || rows.length > 3) throw const FormatException();
    final items = [
      for (var i = 0; i < rows.length; i++)
        ReviewItem.fromJson(_object(rows[i]), ordinal: i + 1),
    ];
    if (items.map((item) => item.id).toSet().length != items.length) {
      throw const FormatException();
    }
    return ReviewResult._(
      jobId,
      input,
      _hash(json['result_hash']),
      _time(json['created_at']),
      List.unmodifiable(items),
      json.containsKey('rehearsal_evaluation')
          ? RehearsalEvaluation.fromJson(_object(json['rehearsal_evaluation']))
          : null,
    );
  }
  final String jobId, resultHash;
  final ReviewInputBinding input;
  final DateTime createdAt;
  final List<ReviewItem> items;
  final RehearsalEvaluation? rehearsalEvaluation;
}

final class ReviewJobSnapshot {
  const ReviewJobSnapshot._(
    this.id,
    this.input,
    this.status,
    this.attemptCount,
    this.nextAttemptAt,
    this.errorCode,
    this.outcomeUnknown,
    this.createdAt,
    this.updatedAt,
    this.result,
  );
  factory ReviewJobSnapshot.fromJson(
    Map<String, dynamic> json, {
    required ReviewInputBinding input,
  }) {
    _keys(json, {
      'id',
      'account_id',
      'session_id',
      'input_revision',
      'practice_input_hash',
      'review_input_hash',
      'policy_version',
      'generation_policy_version',
      'status',
      'attempt_count',
      'next_attempt_at',
      'error_code',
      'outcome_unknown',
      'created_at',
      'updated_at',
      'result',
    });
    _binding(json, input.target, reviewHash: input.reviewInputHash);
    if (json['generation_policy_version'] != reviewGenerationPolicy ||
        json['outcome_unknown'] is! bool) {
      throw const FormatException();
    }
    final status = switch (json['status']) {
      'queued' => ReviewJobStatus.queued,
      'running' => ReviewJobStatus.running,
      'retry_wait' => ReviewJobStatus.retryWait,
      'blocked' => ReviewJobStatus.blocked,
      'succeeded' => ReviewJobStatus.succeeded,
      'no_suggestions' => ReviewJobStatus.noSuggestions,
      'no_evaluable_content' => ReviewJobStatus.noEvaluableContent,
      'failed' => ReviewJobStatus.failed,
      'invalidated' => ReviewJobStatus.invalidated,
      _ => throw const FormatException(),
    };
    final id = _id(json['id']),
        attempts = _integer(json['attempt_count'], 0, 3);
    final created = _time(json['created_at']),
        updated = _time(json['updated_at']);
    final next = json['next_attempt_at'] == null
        ? null
        : _time(json['next_attempt_at']);
    final error = json['error_code'];
    if (error != null &&
        (error is! String ||
            !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(error))) {
      throw const FormatException();
    }
    final result = json['result'] == null
        ? null
        : ReviewResult.fromJson(
            _object(json['result']),
            jobId: id,
            input: input,
          );
    final success =
        status == ReviewJobStatus.succeeded ||
        status == ReviewJobStatus.noSuggestions;
    final empty = status == ReviewJobStatus.noEvaluableContent;
    final unknown = json['outcome_unknown'] as bool;
    if (updated.isBefore(created) ||
        created.isBefore(input.createdAt) ||
        ((status == ReviewJobStatus.retryWait) != (next != null)) ||
        (next != null && next.isBefore(updated)) ||
        (success != (result != null)) ||
        (success &&
            (attempts == 0 ||
                unknown ||
                error != null ||
                result!.createdAt.isBefore(created) ||
                result.createdAt.isAfter(updated))) ||
        (status == ReviewJobStatus.succeeded &&
            result!.items.isEmpty &&
            result.rehearsalEvaluation == null) ||
        (status == ReviewJobStatus.noSuggestions &&
            (result!.items.isNotEmpty || result.rehearsalEvaluation != null)) ||
        (empty && (attempts != 0 || unknown || error != null)) ||
        (empty != (input.status == ReviewInputStatus.noEvaluableContent) &&
            status != ReviewJobStatus.invalidated) ||
        ((status == ReviewJobStatus.running ||
                status == ReviewJobStatus.retryWait) &&
            attempts == 0)) {
      throw const FormatException();
    }
    return ReviewJobSnapshot._(
      id,
      input,
      status,
      attempts,
      next,
      error as String?,
      unknown,
      created,
      updated,
      result,
    );
  }
  final String id;
  final ReviewInputBinding input;
  final ReviewJobStatus status;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? errorCode;
  final bool outcomeUnknown;
  final DateTime createdAt, updatedAt;
  final ReviewResult? result;
  bool get canRetryGeneration =>
      (status == ReviewJobStatus.blocked || status == ReviewJobStatus.failed) &&
      attemptCount < 3 &&
      !outcomeUnknown;
}
