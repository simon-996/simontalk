import 'practice_models.dart';

const observationCodes = {
  'requesting_microphone',
  'negotiating',
  'transport_connected',
  'configuration_confirmed',
  'microphone_active',
  'playback_waiting',
  'playback_blocked',
  'playback_playing',
  'playback_paused',
  'muted',
  'unmuted',
  'local_closed',
};
const observationCloseReasons = {
  'user_stop',
  'background',
  'disposed',
  'account_changed',
  'lease_expired',
  'connection_failed',
  'configuration_failed',
  'other',
};

int _number(dynamic value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException();
  }
  return value;
}

String _id(dynamic value) {
  if (value is! String || !isPracticeUuid(value)) {
    throw const FormatException();
  }
  return value.toLowerCase();
}

class ConnectionObservation {
  ConnectionObservation._(
    this.eventId,
    this.sequence,
    this.code,
    this.elapsedMs,
    this.reason,
    this.receivedAt,
  );
  factory ConnectionObservation.fromJson(Map<String, dynamic> json) {
    final code = json['code'];
    final reason = json['reason'];
    final time = json['received_at'];
    if (!observationCodes.contains(code) ||
        (reason != null &&
            (code != 'local_closed' ||
                !observationCloseReasons.contains(reason))) ||
        time is! String ||
        !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(time)) {
      throw const FormatException();
    }
    return ConnectionObservation._(
      _id(json['event_id']),
      _number(json['sequence'], 1, 2147483647),
      code as String,
      _number(json['elapsed_ms'], 0, 86400000),
      reason as String?,
      DateTime.parse(time).toUtc(),
    );
  }
  final String eventId;
  final int sequence;
  final String code;
  final int elapsedMs;
  final String? reason;
  final DateTime receivedAt;
}

/// A single server snapshot, bound to the requested original connection identity.
class ConnectionObservationPage {
  ConnectionObservationPage._(
    this.events,
    this.lastSequence,
    this.totalEvents,
    this.nextAfterSequence,
    this.hasMore,
  );
  factory ConnectionObservationPage.fromJson(
    Map<String, dynamic> json, {
    required ConnectionReservation connection,
    required int afterSequence,
    required int limit,
  }) {
    if (json['source'] != 'client_observed' ||
        _id(json['connection_id']) != connection.id ||
        _id(json['client_instance_id']) != connection.clientInstanceId ||
        _number(json['epoch'], 1, 2147483647) != connection.epoch ||
        json['has_more'] is! bool ||
        json['events'] is! List) {
      throw const FormatException();
    }
    final last = _number(json['last_sequence'], 0, 2147483647);
    final total = _number(json['total_events'], 0, 256);
    final cursor = _number(json['next_after_sequence'], 0, 2147483647);
    final more = json['has_more'] as bool;
    final events = (json['events'] as List)
        .map((e) => ConnectionObservation.fromJson(e as Map<String, dynamic>))
        .toList();
    var previous = afterSequence;
    final ids = <String>{};
    for (final event in events) {
      if (event.sequence <= previous ||
          event.sequence > last ||
          !ids.add(event.eventId)) {
        throw const FormatException();
      }
      previous = event.sequence;
    }
    if (total > last ||
        (total == 0) != (last == 0) ||
        events.length > limit ||
        events.length > total ||
        cursor != previous ||
        more != (cursor < last) ||
        (more && (events.length != limit || events.length >= total)) ||
        (events.isEmpty && afterSequence < last) ||
        (afterSequence == 0 &&
            events.length != (total < limit ? total : limit))) {
      throw const FormatException();
    }
    return ConnectionObservationPage._(
      List.unmodifiable(events),
      last,
      total,
      cursor,
      more,
    );
  }
  final List<ConnectionObservation> events;
  final int lastSequence;
  final int totalEvents;
  final int nextAfterSequence;
  final bool hasMore;
}
