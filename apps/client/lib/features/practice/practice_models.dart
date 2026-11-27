import '../account/account_models.dart';
import 'daily_topic.dart';

bool isPracticeUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
).hasMatch(value);

String _uuid(dynamic value) {
  if (value is! String || !isPracticeUuid(value)) throw const FormatException();
  return value.toLowerCase();
}

int _integer(dynamic value, int minimum) {
  if (value is! int || value < minimum || value > 2147483647) {
    throw const FormatException();
  }
  return value;
}

DateTime _time(dynamic value) {
  if (value is! String || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    throw const FormatException();
  }
  return DateTime.parse(value).toUtc();
}

T _parse<T>(T Function() read) {
  try {
    return read();
  } on Object {
    throw const FormatException('Invalid practice response');
  }
}

enum PracticeStatus {
  created,
  connecting,
  active,
  interrupted,
  ending,
  completed,
  cancelled,
  failed,
}

enum ConnectionStatus {
  preparing,
  negotiating,
  configuring,
  ready,
  closing,
  unknown,
  closed,
  failed,
}

enum TerminationStatus { notStarted, unknown, confirmed }

class ProviderConfiguration {
  ProviderConfiguration.fromJson(Map<String, dynamic> json)
    : provider = _label(json['provider']),
      region = _label(json['region']),
      model = _label(json['model']),
      configId = _label(json['config_id']);
  final String provider;
  final String region;
  final String model;
  final String configId;

  static String _label(dynamic value) {
    if (value is! String || value.isEmpty || value.length > 256) {
      throw const FormatException();
    }
    return value;
  }

  bool matches(ProviderConfiguration other) =>
      provider == other.provider &&
      region == other.region &&
      model == other.model &&
      configId == other.configId;
}

class PracticeConfiguration {
  PracticeConfiguration._(
    this.preferences,
    this.effectiveDifficulty,
    this.provider,
    this.topic,
  );
  factory PracticeConfiguration.fromJson(Map<String, dynamic> json) =>
      _parse(() {
        if (json['schema_version'] != 1) throw const FormatException();
        final raw = json['preferences'] as Map<String, dynamic>;
        final preferences = AccountPreferences.fromJson(raw);
        if (preferences.difficulty == null ||
            preferences.version < 1 ||
            !['slow', 'normal'].contains(preferences.speechPace) ||
            raw['translation_mode'] != 'on_demand') {
          throw const FormatException();
        }
        return PracticeConfiguration._(
          preferences,
          Difficulty.values.byName(json['effective_difficulty'] as String),
          ProviderConfiguration.fromJson(
            json['provider'] as Map<String, dynamic>,
          ),
          json.containsKey('topic')
              ? PracticeTopicSnapshot.fromJson(
                  json['topic'] as Map<String, dynamic>,
                )
              : null,
        );
      });
  final AccountPreferences preferences;
  final Difficulty effectiveDifficulty;
  final ProviderConfiguration provider;
  final PracticeTopicSnapshot? topic;
}

class PracticePreparation {
  PracticePreparation._(
    this.id,
    this.kind,
    this.sourceSessionId,
    this.sourceReviewItemId,
    this.status,
    this.connectionEpoch,
    this.configuration,
    this.createdAt,
    this.endedAt,
    this.stateReason,
  );
  factory PracticePreparation.fromJson(Map<String, dynamic> json) => _parse(() {
    final mode = json['mode'];
    if (mode != 'free_chat' && mode != 'daily_topic') {
      throw const FormatException();
    }
    final kind = json['kind'] == null ? 'ordinary' : json['kind'] as String;
    if (!['ordinary', 'rehearsal'].contains(kind)) {
      throw const FormatException();
    }
    final sourceSessionId = json['source_session_id'] == null
        ? null
        : _uuid(json['source_session_id']);
    final sourceReviewItemId = json['source_review_item_id'] == null
        ? null
        : _uuid(json['source_review_item_id']);
    final id = _uuid(json['id']);
    if (kind == 'ordinary') {
      if (sourceSessionId != null || sourceReviewItemId != null) {
        throw const FormatException();
      }
    } else if (sourceSessionId == null ||
        sourceReviewItemId == null ||
        sourceSessionId == id) {
      throw const FormatException();
    }
    final configuration = PracticeConfiguration.fromJson(
      json['configuration'] as Map<String, dynamic>,
    );
    final status = PracticeStatus.values.byName(json['status'] as String);
    final reason = json['state_reason'] as String?;
    final hasTopic =
        mode == 'daily_topic' &&
        !(status == PracticeStatus.completed && reason == 'content_deleted');
    if (hasTopic != (configuration.topic != null) ||
        (mode == 'daily_topic' && kind != 'ordinary')) {
      throw const FormatException();
    }
    return PracticePreparation._(
      id,
      kind,
      sourceSessionId,
      sourceReviewItemId,
      status,
      _integer(json['connection_epoch'], 0),
      configuration,
      _time(json['created_at']),
      json['ended_at'] == null ? null : _time(json['ended_at']),
      reason,
    );
  });
  final String id;
  final String kind;
  final String? sourceSessionId;
  final String? sourceReviewItemId;
  final PracticeStatus status;
  final int connectionEpoch;
  final PracticeConfiguration configuration;
  final DateTime createdAt;
  final DateTime? endedAt;
  final String? stateReason;
}

/// Identity-scoped recovery evidence. It does not grant this client a lease.
class PracticeRecovery {
  PracticeRecovery._(this.practice, this.connection);
  factory PracticeRecovery.fromJson(Map<String, dynamic> json) => _parse(() {
    if (!json.containsKey('practice') || !json.containsKey('connection')) {
      throw const FormatException();
    }
    final practice = json['practice'] == null
        ? null
        : PracticePreparation.fromJson(
            json['practice'] as Map<String, dynamic>,
          );
    final connection = json['connection'] == null
        ? null
        : ConnectionReservation.fromJson(
            json['connection'] as Map<String, dynamic>,
          );
    if (connection != null &&
        (practice == null ||
            connection.sessionId != practice.id ||
            connection.epoch > practice.connectionEpoch ||
            !connection.configuration.matches(
              practice.configuration.provider,
            ))) {
      throw const FormatException();
    }
    if (practice != null &&
        [
          PracticeStatus.completed,
          PracticeStatus.cancelled,
          PracticeStatus.failed,
        ].contains(practice.status) &&
        (connection == null || connection.safelyEnded)) {
      throw const FormatException();
    }
    return PracticeRecovery._(practice, connection);
  });
  final PracticePreparation? practice;
  final ConnectionReservation? connection;

  /// A UI candidate only. The server checks the complete locked history again.
  bool get canDiscardPreparation {
    final original = practice;
    if (original == null) return false;
    final latest = connection;
    if (latest == null) {
      return original.status == PracticeStatus.created &&
          original.connectionEpoch == 0;
    }
    if (latest.epoch != original.connectionEpoch ||
        latest.terminationStatus != TerminationStatus.notStarted) {
      return false;
    }
    return (original.status == PracticeStatus.connecting && latest.canCancel) ||
        (original.status == PracticeStatus.created && latest.safelyEnded);
  }
}

class ConnectionReservation {
  ConnectionReservation._(
    this.id,
    this.sessionId,
    this.clientInstanceId,
    this.epoch,
    this.configuration,
    this.status,
    this.terminationStatus,
    this.stateReason,
    this.createdAt,
    this.lastSeenAt,
    this.leaseExpiresAt,
    this.endedAt,
  );
  factory ConnectionReservation.fromJson(Map<String, dynamic> json) =>
      _parse(() {
        final status = ConnectionStatus.values.byName(json['status'] as String);
        final termination = switch (json['termination_status']) {
          'not_started' => TerminationStatus.notStarted,
          'unknown' => TerminationStatus.unknown,
          'confirmed' => TerminationStatus.confirmed,
          _ => throw const FormatException(),
        };
        final terminal = [
          ConnectionStatus.closed,
          ConnectionStatus.failed,
        ].contains(status);
        final ended = json['ended_at'] == null ? null : _time(json['ended_at']);
        final validEvidence = status == ConnectionStatus.preparing
            ? termination == TerminationStatus.notStarted
            : terminal
            ? termination != TerminationStatus.unknown
            : termination == TerminationStatus.unknown;
        final created = _time(json['created_at']);
        final lastSeen = _time(json['last_seen_at']);
        final expires = _time(json['lease_expires_at']);
        if (!validEvidence ||
            terminal != (ended != null) ||
            lastSeen.isBefore(created) ||
            !expires.isAfter(lastSeen)) {
          throw const FormatException();
        }
        return ConnectionReservation._(
          _uuid(json['id']),
          _uuid(json['session_id']),
          _uuid(json['client_instance_id']),
          _integer(json['epoch'], 1),
          ProviderConfiguration.fromJson(
            json['configuration'] as Map<String, dynamic>,
          ),
          status,
          termination,
          json['state_reason'] as String?,
          created,
          lastSeen,
          expires,
          ended,
        );
      });
  final String id;
  final String sessionId;
  final String clientInstanceId;
  final int epoch;
  final ProviderConfiguration configuration;
  final ConnectionStatus status;
  final TerminationStatus terminationStatus;
  final String? stateReason;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final DateTime leaseExpiresAt;
  final DateTime? endedAt;
  bool get canCancel =>
      status == ConnectionStatus.preparing &&
      terminationStatus == TerminationStatus.notStarted;
  bool get safelyEnded =>
      endedAt != null && terminationStatus != TerminationStatus.unknown;
  Duration get leaseDuration => leaseExpiresAt.difference(lastSeenAt);
}
