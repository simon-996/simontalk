import '../practice/practice_models.dart';

const _maxTokenTotal = 1000000000000;

T _parse<T>(T Function() read) {
  try {
    return read();
  } on Object {
    throw const FormatException('Invalid usage response');
  }
}

String _id(Object? value) {
  if (value is! String || !isPracticeUuid(value)) {
    throw const FormatException();
  }
  return value.toLowerCase();
}

int _nonNegativeInt(Object? value, {int max = _maxTokenTotal}) {
  if (value is! int || value < 0 || value > max) {
    throw const FormatException();
  }
  return value;
}

DateTime _time(Object? value) {
  if (value is! String || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    throw const FormatException();
  }
  return DateTime.parse(value).toUtc();
}

void _exactKeys(Map<String, dynamic> map, Set<String> expected) {
  if (map.length != expected.length ||
      !map.keys.toSet().containsAll(expected)) {
    throw const FormatException();
  }
}

final class VoiceUsageBucket {
  const VoiceUsageBucket._({
    required this.responseCount,
    required this.deletedResponseCount,
    required this.incompleteCount,
    required this.detailIncompleteCount,
    required this.knownInputTokens,
    required this.knownOutputTokens,
    required this.knownInputTextTokens,
    required this.knownInputAudioTokens,
    required this.knownOutputTextTokens,
    required this.knownOutputAudioTokens,
  });

  factory VoiceUsageBucket.fromJson(
    Map<String, dynamic> json, {
    required bool includeDeleted,
  }) => _parse(() {
    const baseKeys = {
      'response_count',
      'incomplete_count',
      'detail_incomplete_count',
      'known_input_tokens',
      'known_output_tokens',
      'known_input_text_tokens',
      'known_input_audio_tokens',
      'known_output_text_tokens',
      'known_output_audio_tokens',
    };
    _exactKeys(
      json,
      includeDeleted ? {...baseKeys, 'deleted_response_count'} : baseKeys,
    );
    final responses = _nonNegativeInt(json['response_count']);
    final deleted = includeDeleted
        ? _nonNegativeInt(json['deleted_response_count'], max: responses)
        : null;
    final incomplete = _nonNegativeInt(
      json['incomplete_count'],
      max: responses,
    );
    final detailIncomplete = _nonNegativeInt(
      json['detail_incomplete_count'],
      max: responses,
    );
    final input = _nonNegativeInt(json['known_input_tokens']);
    final output = _nonNegativeInt(json['known_output_tokens']);
    final inText = _nonNegativeInt(json['known_input_text_tokens']);
    final inAudio = _nonNegativeInt(json['known_input_audio_tokens']);
    final outText = _nonNegativeInt(json['known_output_text_tokens']);
    final outAudio = _nonNegativeInt(json['known_output_audio_tokens']);
    if (responses == 0 &&
        (input != 0 ||
            output != 0 ||
            inText != 0 ||
            inAudio != 0 ||
            outText != 0 ||
            outAudio != 0)) {
      throw const FormatException();
    }
    if (incomplete == 0 &&
        (inText + inAudio > input || outText + outAudio > output)) {
      throw const FormatException();
    }
    return VoiceUsageBucket._(
      responseCount: responses,
      deletedResponseCount: deleted,
      incompleteCount: incomplete,
      detailIncompleteCount: detailIncomplete,
      knownInputTokens: input,
      knownOutputTokens: output,
      knownInputTextTokens: inText,
      knownInputAudioTokens: inAudio,
      knownOutputTextTokens: outText,
      knownOutputAudioTokens: outAudio,
    );
  });

  final int responseCount;
  final int? deletedResponseCount;
  final int incompleteCount;
  final int detailIncompleteCount;
  final int knownInputTokens;
  final int knownOutputTokens;
  final int knownInputTextTokens;
  final int knownInputAudioTokens;
  final int knownOutputTextTokens;
  final int knownOutputAudioTokens;
}

final class ReviewUsageBucket {
  const ReviewUsageBucket._({
    required this.attemptCount,
    required this.deletedAttemptCount,
    required this.incompleteCount,
    required this.knownInputTokens,
    required this.knownOutputTokens,
  });

  factory ReviewUsageBucket.fromJson(
    Map<String, dynamic> json, {
    required bool includeDeleted,
  }) => _parse(() {
    const baseKeys = {
      'attempt_count',
      'incomplete_count',
      'known_input_tokens',
      'known_output_tokens',
    };
    _exactKeys(
      json,
      includeDeleted ? {...baseKeys, 'deleted_attempt_count'} : baseKeys,
    );
    final attempts = _nonNegativeInt(json['attempt_count']);
    final deleted = includeDeleted
        ? _nonNegativeInt(json['deleted_attempt_count'], max: attempts)
        : null;
    final incomplete = _nonNegativeInt(json['incomplete_count'], max: attempts);
    final input = _nonNegativeInt(json['known_input_tokens']);
    final output = _nonNegativeInt(json['known_output_tokens']);
    if (attempts == 0 && (input != 0 || output != 0)) {
      throw const FormatException();
    }
    return ReviewUsageBucket._(
      attemptCount: attempts,
      deletedAttemptCount: deleted,
      incompleteCount: incomplete,
      knownInputTokens: input,
      knownOutputTokens: output,
    );
  });

  final int attemptCount;
  final int? deletedAttemptCount;
  final int incompleteCount;
  final int knownInputTokens;
  final int knownOutputTokens;
}

final class AccountUsageSummary {
  const AccountUsageSummary._({
    required this.accountId,
    required this.checkedAt,
    required this.latestRecordedAt,
    required this.connectionPendingCount,
    required this.deletedPracticeCount,
    required this.voiceOrdinary,
    required this.voiceRehearsal,
    required this.review,
    required this.assistance,
  });

  factory AccountUsageSummary.fromJson(
    Map<String, dynamic> json, {
    required String accountId,
  }) => _parse(() {
    _exactKeys(json, {
      'schema_version',
      'source',
      'account_id',
      'checked_at',
      'latest_recorded_at',
      'connection_pending_count',
      'deleted_practice_count',
      'voice_ordinary',
      'voice_rehearsal',
      'review',
      if (json.containsKey('assistance')) 'assistance',
    });
    if (json['schema_version'] != 'account_usage_v1' ||
        json['source'] != 'server_recorded' ||
        _id(json['account_id']) != _id(accountId)) {
      throw const FormatException();
    }
    final checkedAt = _time(json['checked_at']);
    final latest = json['latest_recorded_at'] == null
        ? null
        : _time(json['latest_recorded_at']);
    final pending = _nonNegativeInt(json['connection_pending_count']);
    final deletedPractices = _nonNegativeInt(json['deleted_practice_count']);
    final ordinaryRaw = json['voice_ordinary'];
    final rehearsalRaw = json['voice_rehearsal'];
    final reviewRaw = json['review'];
    if (ordinaryRaw is! Map<String, dynamic> ||
        rehearsalRaw is! Map<String, dynamic> ||
        reviewRaw is! Map<String, dynamic>) {
      throw const FormatException();
    }
    final ordinary = VoiceUsageBucket.fromJson(
      ordinaryRaw,
      includeDeleted: true,
    );
    final rehearsal = VoiceUsageBucket.fromJson(
      rehearsalRaw,
      includeDeleted: true,
    );
    final review = ReviewUsageBucket.fromJson(reviewRaw, includeDeleted: true);
    final assistance = _assistanceBucket(json, includeDeleted: true);
    final totalRecords =
        ordinary.responseCount +
        rehearsal.responseCount +
        review.attemptCount +
        (assistance?.attemptCount ?? 0);
    if ((totalRecords == 0) != (latest == null)) {
      throw const FormatException();
    }
    if (deletedPractices == 0 &&
        ((ordinary.deletedResponseCount ?? 0) > 0 ||
            (rehearsal.deletedResponseCount ?? 0) > 0 ||
            (assistance?.deletedAttemptCount ?? 0) > 0)) {
      throw const FormatException();
    }
    return AccountUsageSummary._(
      accountId: _id(accountId),
      checkedAt: checkedAt,
      latestRecordedAt: latest,
      connectionPendingCount: pending,
      deletedPracticeCount: deletedPractices,
      voiceOrdinary: ordinary,
      voiceRehearsal: rehearsal,
      review: review,
      assistance: assistance,
    );
  });

  final String accountId;
  final DateTime checkedAt;
  final DateTime? latestRecordedAt;
  final int connectionPendingCount;
  final int deletedPracticeCount;
  final VoiceUsageBucket voiceOrdinary;
  final VoiceUsageBucket voiceRehearsal;
  final ReviewUsageBucket review;
  final ReviewUsageBucket? assistance;

  bool get hasAnyRecords =>
      voiceOrdinary.responseCount > 0 ||
      voiceRehearsal.responseCount > 0 ||
      review.attemptCount > 0 ||
      (assistance?.attemptCount ?? 0) > 0;
}

final class PracticeUsageSummary {
  const PracticeUsageSummary._({
    required this.accountId,
    required this.sessionId,
    required this.kind,
    required this.checkedAt,
    required this.latestRecordedAt,
    required this.connectionCount,
    required this.connectionPending,
    required this.voice,
    required this.review,
    required this.assistance,
  });

  factory PracticeUsageSummary.fromJson(
    Map<String, dynamic> json, {
    required String accountId,
    required String sessionId,
  }) => _parse(() {
    _exactKeys(json, {
      'schema_version',
      'source',
      'account_id',
      'session_id',
      'kind',
      'checked_at',
      'latest_recorded_at',
      'connection_count',
      'connection_pending',
      'voice',
      'review',
      if (json.containsKey('assistance')) 'assistance',
    });
    final kind = json['kind'];
    if (json['schema_version'] != 'practice_usage_v1' ||
        json['source'] != 'server_recorded' ||
        _id(json['account_id']) != _id(accountId) ||
        _id(json['session_id']) != _id(sessionId) ||
        (kind != 'ordinary' && kind != 'rehearsal') ||
        json['connection_pending'] is! bool) {
      throw const FormatException();
    }
    final checkedAt = _time(json['checked_at']);
    final latest = json['latest_recorded_at'] == null
        ? null
        : _time(json['latest_recorded_at']);
    final connections = _nonNegativeInt(json['connection_count']);
    final pending = json['connection_pending'] as bool;
    final voiceRaw = json['voice'];
    final reviewRaw = json['review'];
    if (voiceRaw is! Map<String, dynamic> ||
        reviewRaw is! Map<String, dynamic>) {
      throw const FormatException();
    }
    final voice = VoiceUsageBucket.fromJson(voiceRaw, includeDeleted: false);
    final review = ReviewUsageBucket.fromJson(reviewRaw, includeDeleted: false);
    final assistance = _assistanceBucket(json, includeDeleted: false);
    if (connections == 0 && (pending || voice.responseCount > 0)) {
      throw const FormatException();
    }
    if ((voice.responseCount +
                review.attemptCount +
                (assistance?.attemptCount ?? 0) ==
            0) !=
        (latest == null)) {
      throw const FormatException();
    }
    return PracticeUsageSummary._(
      accountId: _id(accountId),
      sessionId: _id(sessionId),
      kind: kind as String,
      checkedAt: checkedAt,
      latestRecordedAt: latest,
      connectionCount: connections,
      connectionPending: pending,
      voice: voice,
      review: review,
      assistance: assistance,
    );
  });

  final String accountId;
  final String sessionId;
  final String kind;
  final DateTime checkedAt;
  final DateTime? latestRecordedAt;
  final int connectionCount;
  final bool connectionPending;
  final VoiceUsageBucket voice;
  final ReviewUsageBucket review;
  final ReviewUsageBucket? assistance;

  bool get hasAnyRecords =>
      voice.responseCount > 0 ||
      review.attemptCount > 0 ||
      (assistance?.attemptCount ?? 0) > 0;
}

ReviewUsageBucket? _assistanceBucket(
  Map<String, dynamic> json, {
  required bool includeDeleted,
}) => !json.containsKey('assistance')
    ? null
    : ReviewUsageBucket.fromJson(
        json['assistance'] as Map<String, dynamic>,
        includeDeleted: includeDeleted,
      );
