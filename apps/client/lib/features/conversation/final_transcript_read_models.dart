import 'dart:convert';

import '../practice/practice_models.dart';
import 'conversation_models.dart';

const _maxInteger = 2147483647;
const _maxTextBytes = 8192;
const _maxHistoryBytes = 1048576;

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

String _unicode(dynamic value) {
  if (value is! String ||
      value.contains('\u0000') ||
      utf8.decode(utf8.encode(value)) != value) {
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
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  final calendar = DateTime.utc(year, month, day, hour, minute, second);
  if (year < 1 ||
      calendar.year != year ||
      calendar.month != month ||
      calendar.day != day ||
      calendar.hour != hour ||
      calendar.minute != minute ||
      calendar.second != second ||
      (match[7] != 'Z' &&
          (int.parse(match[9]!) > 23 || int.parse(match[10]!) > 59))) {
    throw const FormatException();
  }
  return DateTime.parse(value).toUtc();
}

bool _sameScope(ConversationScope a, ConversationScope b) =>
    a.accountId == b.accountId &&
    a.sessionId == b.sessionId &&
    a.connectionId == b.connectionId &&
    a.clientInstanceId == b.clientInstanceId &&
    a.epoch == b.epoch;

/// A stored client report of final text, without evidence of audio delivery.
final class FinalTranscriptEvent {
  const FinalTranscriptEvent._({
    required this.eventId,
    required this.sequence,
    required this.turnId,
    required this.turnIndex,
    required this.role,
    required this.revision,
    required this.text,
    required this.responseId,
    required this.providerItemId,
    required this.receivedAt,
    required this.deliveryStatus,
  });

  factory FinalTranscriptEvent.fromJson(Map<String, dynamic> json) {
    final role = switch (json['role']) {
      'user' => ConversationRole.user,
      'assistant' => ConversationRole.assistant,
      _ => throw const FormatException(),
    };
    final text = _unicode(json['text']);
    if (utf8.encode(text).length > _maxTextBytes ||
        !json.containsKey('delivery_status')) {
      throw const FormatException();
    }
    final provider = json['provider_item_id'] == null
        ? null
        : _unicode(json['provider_item_id']);
    if (provider != null &&
        (provider.runes.isEmpty || provider.runes.length > 256)) {
      throw const FormatException();
    }
    String? response;
    DeliveryStatus? delivery;
    if (role == ConversationRole.user) {
      if (json['response_id'] != null || json['delivery_status'] != null) {
        throw const FormatException();
      }
    } else {
      response = _id(json['response_id']);
      if (json['delivery_status'] != 'unknown') {
        throw const FormatException();
      }
      delivery = DeliveryStatus.unknown;
    }
    return FinalTranscriptEvent._(
      eventId: _id(json['event_id']),
      sequence: _number(json['sequence'], 1, _maxInteger),
      turnId: _id(json['turn_id']),
      turnIndex: _number(json['turn_index'], 1, _maxInteger),
      role: role,
      revision: _number(json['revision'], 1, _maxInteger),
      text: text,
      responseId: response,
      providerItemId: provider,
      receivedAt: _time(json['received_at']),
      deliveryStatus: delivery,
    );
  }

  final String eventId;
  final int sequence;
  final String turnId;
  final int turnIndex;
  final ConversationRole role;
  final int revision;
  final String text;
  final String? responseId;
  final String? providerItemId;
  final DateTime receivedAt;
  final DeliveryStatus? deliveryStatus;
}

/// A bounded server snapshot bound to the account and original connection.
final class FinalTranscriptPage {
  FinalTranscriptPage._({
    required this.scope,
    required Iterable<FinalTranscriptEvent> events,
    required this.afterSequence,
    required this.lastSequence,
    required this.totalEvents,
    required this.totalTextBytes,
    required this.nextAfterSequence,
    required this.hasMore,
  }) : events = List.unmodifiable(events);

  factory FinalTranscriptPage.fromJson(
    Map<String, dynamic> json, {
    required ConversationScope scope,
    required int afterSequence,
    required int limit,
  }) {
    _number(afterSequence, 0, _maxInteger);
    _number(limit, 1, 32);
    if (json['source'] != 'client_reported' ||
        _id(json['account_id']) != scope.accountId ||
        _id(json['session_id']) != scope.sessionId ||
        _id(json['connection_id']) != scope.connectionId ||
        _id(json['client_instance_id']) != scope.clientInstanceId ||
        _number(json['epoch'], 1, _maxInteger) != scope.epoch ||
        json['events'] is! List ||
        json['has_more'] is! bool) {
      throw const FormatException();
    }
    final last = _number(json['last_sequence'], 0, _maxInteger);
    final total = _number(json['total_events'], 0, 512);
    final totalBytes = _number(json['total_text_bytes'], 0, _maxHistoryBytes);
    final cursor = _number(json['next_after_sequence'], 0, _maxInteger);
    final more = json['has_more'] as bool;
    final rawEvents = json['events'] as List;
    if (rawEvents.length > limit || rawEvents.length > total) {
      throw const FormatException();
    }
    final events = <FinalTranscriptEvent>[];
    final ids = <String>{};
    var previous = afterSequence;
    var bytes = 0;
    for (final raw in rawEvents) {
      if (raw is! Map<String, dynamic>) throw const FormatException();
      final event = FinalTranscriptEvent.fromJson(raw);
      if (event.sequence <= previous ||
          event.sequence > last ||
          !ids.add(event.eventId)) {
        throw const FormatException();
      }
      previous = event.sequence;
      bytes += utf8.encode(event.text).length;
      events.add(event);
    }
    if (total > last ||
        (total == 0) != (last == 0) ||
        totalBytes > total * _maxTextBytes ||
        bytes > totalBytes ||
        cursor != previous ||
        more != (cursor < last) ||
        (more && (events.length != limit || events.length >= total)) ||
        (events.isEmpty && afterSequence < last) ||
        (afterSequence == 0 &&
            (events.length != (total < limit ? total : limit) ||
                more != (events.length < total)))) {
      throw const FormatException();
    }
    return FinalTranscriptPage._(
      scope: scope,
      events: events,
      afterSequence: afterSequence,
      lastSequence: last,
      totalEvents: total,
      totalTextBytes: totalBytes,
      nextAfterSequence: cursor,
      hasMore: more,
    );
  }

  final ConversationScope scope;
  final List<FinalTranscriptEvent> events;
  final int afterSequence;
  final int lastSequence;
  final int totalEvents;
  final int totalTextBytes;
  final int nextAfterSequence;
  final bool hasMore;
}

/// Immutable reconstruction of the pages read from cursor zero.
/// All final revisions count toward the server budget, including empty text.
final class FinalTranscriptHistory {
  FinalTranscriptHistory._({
    required this.scope,
    required Iterable<FinalTranscriptEvent> events,
    required Iterable<FinalTranscriptEvent> turns,
    required this.lastSequence,
    required this.totalEvents,
    required this.totalTextBytes,
    required this.nextAfterSequence,
    required this.hasMore,
    required this.hasSequenceGaps,
    required this.hasTurnIndexGaps,
    required this.hasRevisionGaps,
  }) : events = List.unmodifiable(events),
       turns = List.unmodifiable(turns);

  factory FinalTranscriptHistory.empty(ConversationScope scope) =>
      FinalTranscriptHistory._(
        scope: scope,
        events: const [],
        turns: const [],
        lastSequence: 0,
        totalEvents: 0,
        totalTextBytes: 0,
        nextAfterSequence: 0,
        hasMore: false,
        hasSequenceGaps: false,
        hasTurnIndexGaps: false,
        hasRevisionGaps: false,
      );

  FinalTranscriptHistory append(FinalTranscriptPage page) {
    final countGrowth = page.totalEvents - totalEvents;
    final sequenceGrowth = page.lastSequence - lastSequence;
    final byteGrowth = page.totalTextBytes - totalTextBytes;
    if (!_sameScope(scope, page.scope) ||
        page.afterSequence != nextAfterSequence ||
        countGrowth < 0 ||
        sequenceGrowth < 0 ||
        byteGrowth < 0 ||
        countGrowth > sequenceGrowth ||
        (countGrowth == 0 && (sequenceGrowth != 0 || byteGrowth != 0)) ||
        byteGrowth > countGrowth * _maxTextBytes) {
      throw const FormatException();
    }
    final combined = [...events, ...page.events];
    final current = <String, FinalTranscriptEvent>{};
    final indices = <int, String>{};
    final ids = <String>{};
    var bytes = 0;
    var previousSequence = 0;
    var sequenceGaps = false;
    var revisionGaps = false;
    for (final event in combined) {
      final prior = current[event.turnId];
      final indexOwner = indices[event.turnIndex];
      if (!ids.add(event.eventId) ||
          event.sequence <= previousSequence ||
          (indexOwner != null && indexOwner != event.turnId) ||
          (prior != null &&
              (prior.turnIndex != event.turnIndex ||
                  prior.role != event.role ||
                  prior.responseId != event.responseId ||
                  prior.providerItemId != event.providerItemId ||
                  event.revision <= prior.revision))) {
        throw const FormatException();
      }
      sequenceGaps |= event.sequence != previousSequence + 1;
      revisionGaps |= event.revision != (prior?.revision ?? 0) + 1;
      previousSequence = event.sequence;
      bytes += utf8.encode(event.text).length;
      current[event.turnId] = event;
      indices[event.turnIndex] = event.turnId;
    }
    final unreadCount = page.totalEvents - combined.length;
    final unreadBytes = page.totalTextBytes - bytes;
    if (combined.length > 512 ||
        current.length > 256 ||
        bytes > _maxHistoryBytes ||
        unreadCount < 0 ||
        unreadBytes < 0 ||
        unreadCount > page.lastSequence - page.nextAfterSequence ||
        unreadBytes > unreadCount * _maxTextBytes ||
        (page.hasMore
            ? unreadCount == 0
            : unreadCount != 0 || unreadBytes != 0)) {
      throw const FormatException();
    }
    final turns = current.values.toList()
      ..sort((a, b) => a.turnIndex.compareTo(b.turnIndex));
    var previousIndex = 0;
    var indexGaps = false;
    for (final turn in turns) {
      indexGaps |= turn.turnIndex != previousIndex + 1;
      previousIndex = turn.turnIndex;
    }
    return FinalTranscriptHistory._(
      scope: scope,
      events: combined,
      turns: turns,
      lastSequence: page.lastSequence,
      totalEvents: page.totalEvents,
      totalTextBytes: page.totalTextBytes,
      nextAfterSequence: page.nextAfterSequence,
      hasMore: page.hasMore,
      hasSequenceGaps: sequenceGaps,
      hasTurnIndexGaps: indexGaps,
      hasRevisionGaps: revisionGaps,
    );
  }

  final ConversationScope scope;
  final List<FinalTranscriptEvent> events;
  final List<FinalTranscriptEvent> turns;
  final int lastSequence;
  final int totalEvents;
  final int totalTextBytes;
  final int nextAfterSequence;
  final bool hasMore;
  final bool hasSequenceGaps;
  final bool hasTurnIndexGaps;
  final bool hasRevisionGaps;
}
