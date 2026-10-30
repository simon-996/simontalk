import 'conversation_models.dart';
import 'playback_evidence_models.dart';

/// One bounded page of client reports. These records cannot resume media/context.
final class PlaybackEvidencePage {
  PlaybackEvidencePage._({
    required this.scope,
    required this.events,
    required this.afterSequence,
    required this.lastSequence,
    required this.totalEvents,
    required this.totalTextBytes,
    required this.nextAfterSequence,
    required this.hasMore,
    required this.sealed,
  });
  factory PlaybackEvidencePage.fromJson(
    Map<String, dynamic> json, {
    required ConversationScope scope,
    required int afterSequence,
    required int limit,
  }) {
    PlaybackEvidenceValidation.keys(json, {
      'source',
      'account_id',
      'session_id',
      'connection_id',
      'client_instance_id',
      'epoch',
      'events',
      'last_sequence',
      'total_events',
      'total_text_bytes',
      'next_after_sequence',
      'has_more',
      'sealed',
      'recoverable',
    });
    PlaybackEvidenceValidation.number(afterSequence, 0, 2147483647);
    PlaybackEvidenceValidation.number(limit, 1, 16);
    if (json['source'] != 'client_reported' ||
        PlaybackEvidenceValidation.id(json['account_id']) != scope.accountId ||
        PlaybackEvidenceValidation.id(json['session_id']) != scope.sessionId ||
        PlaybackEvidenceValidation.id(json['connection_id']) !=
            scope.connectionId ||
        PlaybackEvidenceValidation.id(json['client_instance_id']) !=
            scope.clientInstanceId ||
        PlaybackEvidenceValidation.number(json['epoch'], 1, 2147483647) !=
            scope.epoch ||
        json['events'] is! List ||
        json['has_more'] is! bool ||
        json['sealed'] is! bool ||
        json['recoverable'] != false) {
      throw const FormatException();
    }
    final last = PlaybackEvidenceValidation.number(
      json['last_sequence'],
      0,
      2147483647,
    );
    final total = PlaybackEvidenceValidation.number(
      json['total_events'],
      0,
      maxPlaybackEvidenceNormalEvents + maxPlaybackEvidenceRevocations,
    );
    final bytes = PlaybackEvidenceValidation.number(
      json['total_text_bytes'],
      0,
      maxPlaybackEvidenceTextBytes,
    );
    final cursor = PlaybackEvidenceValidation.number(
      json['next_after_sequence'],
      0,
      2147483647,
    );
    final raw = json['events'] as List;
    if (raw.length > limit || raw.length > total) throw const FormatException();
    final events = <PlaybackEvidenceEvent>[];
    final ids = <String>{};
    var previous = afterSequence;
    var pageBytes = 0;
    for (final value in raw) {
      if (value is! Map<String, dynamic>) throw const FormatException();
      final event = PlaybackEvidenceEvent.fromJson(value);
      if (!ids.add(event.eventId) ||
          event.sequence <= previous ||
          event.sequence > last) {
        throw const FormatException();
      }
      previous = event.sequence;
      pageBytes += event.textBytes;
      events.add(event);
    }
    final more = json['has_more'] as bool;
    if (total > last ||
        (total == 0) != (last == 0) ||
        bytes > total * maxPlaybackEvidenceEventTextBytes ||
        pageBytes > bytes ||
        cursor != previous ||
        more != (cursor < last) ||
        (more && (events.length != limit || events.length >= total)) ||
        (events.isEmpty && afterSequence < last) ||
        (afterSequence == 0 &&
            (events.length != (total < limit ? total : limit) ||
                more != (events.length < total)))) {
      throw const FormatException();
    }
    return PlaybackEvidencePage._(
      scope: scope,
      events: List.unmodifiable(events),
      afterSequence: afterSequence,
      lastSequence: last,
      totalEvents: total,
      totalTextBytes: bytes,
      nextAfterSequence: cursor,
      hasMore: more,
      sealed: json['sealed'] as bool,
    );
  }
  final ConversationScope scope;
  final List<PlaybackEvidenceEvent> events;
  final int afterSequence;
  final int lastSequence;
  final int totalEvents;
  final int totalTextBytes;
  final int nextAfterSequence;
  final bool hasMore;
  final bool sealed;
  bool get recoverable => false;
}

/// Atomic reconstruction preserves historical source versions and tombstones.
/// Server sealing fixes input facts; it never makes this recovery context.
final class PlaybackEvidenceHistory {
  PlaybackEvidenceHistory._(
    this._ledger, {
    required this.scope,
    required this.lastSequence,
    required this.totalEvents,
    required this.totalTextBytes,
    required this.nextAfterSequence,
    required this.hasMore,
    required this.sealed,
  });
  factory PlaybackEvidenceHistory.empty(ConversationScope scope) =>
      PlaybackEvidenceHistory._(
        PlaybackEvidenceLedger.empty(),
        scope: scope,
        lastSequence: 0,
        totalEvents: 0,
        totalTextBytes: 0,
        nextAfterSequence: 0,
        hasMore: false,
        sealed: false,
      );
  PlaybackEvidenceHistory append(PlaybackEvidencePage page) {
    final growth = page.totalEvents - totalEvents;
    final sequenceGrowth = page.lastSequence - lastSequence;
    final byteGrowth = page.totalTextBytes - totalTextBytes;
    if ((sealed &&
            (!page.sealed ||
                page.lastSequence != lastSequence ||
                page.totalEvents != totalEvents ||
                page.totalTextBytes != totalTextBytes)) ||
        !PlaybackEvidenceValidation.sameScope(scope, page.scope) ||
        page.afterSequence != nextAfterSequence ||
        growth < 0 ||
        sequenceGrowth < 0 ||
        byteGrowth < 0 ||
        growth > sequenceGrowth ||
        (growth == 0 && (sequenceGrowth != 0 || byteGrowth != 0)) ||
        byteGrowth > growth * maxPlaybackEvidenceEventTextBytes) {
      throw const FormatException();
    }
    final next = PlaybackEvidenceLedger.fromEvents([...events, ...page.events]);
    final unread = page.totalEvents - next.events.length;
    final unreadBytes = page.totalTextBytes - next.textBytes;
    if (unread < 0 ||
        unreadBytes < 0 ||
        unread > page.lastSequence - page.nextAfterSequence ||
        unreadBytes > unread * maxPlaybackEvidenceEventTextBytes ||
        (page.hasMore ? unread == 0 : unread != 0 || unreadBytes != 0)) {
      throw const FormatException();
    }
    return PlaybackEvidenceHistory._(
      next,
      scope: scope,
      lastSequence: page.lastSequence,
      totalEvents: page.totalEvents,
      totalTextBytes: page.totalTextBytes,
      nextAfterSequence: page.nextAfterSequence,
      hasMore: page.hasMore,
      sealed: page.sealed,
    );
  }

  final ConversationScope scope;
  final PlaybackEvidenceLedger _ledger;
  List<PlaybackEvidenceEvent> get events => _ledger.events;
  List<PlaybackEvidenceTurn> get turns => _ledger.turns;
  Set<String> get revokedResponseIds => _ledger.revokedResponseIds;
  final int lastSequence;
  final int totalEvents;
  final int totalTextBytes;
  final int nextAfterSequence;
  final bool hasMore;
  final bool sealed;
  bool get recoverable => false;
  bool get hasSequenceGaps {
    var previous = 0;
    for (final event in events) {
      if (event.sequence != previous + 1) return true;
      previous = event.sequence;
    }
    return false;
  }
}
