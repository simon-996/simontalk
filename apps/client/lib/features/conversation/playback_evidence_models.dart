import 'dart:convert';

import '../practice/practice_models.dart';
import 'conversation_models.dart';

const maxPlaybackEvidenceNormalEvents = 512;
const maxPlaybackEvidenceRevocations = 256;
const maxPlaybackEvidenceTextBytes = 2097152;
const maxPlaybackEvidenceEventTextBytes = 16384;

enum PlaybackEvidenceKind { alignment, freeze, revoke }

/// Strict shared parsing for the independent, unsealed evidence ledger.
abstract final class PlaybackEvidenceValidation {
  static int number(dynamic value, int min, int max) {
    if (value is! int || value < min || value > max) {
      throw const FormatException();
    }
    return value;
  }

  static String id(dynamic value) {
    if (value is! String || !isPracticeUuid(value)) {
      throw const FormatException();
    }
    return value.toLowerCase();
  }

  static String text(dynamic value) {
    if (value is! String ||
        value.length > 8192 ||
        value.contains('\u0000') ||
        utf8.decode(utf8.encode(value)) != value ||
        utf8.encode(value).length > 8192) {
      throw const FormatException();
    }
    return value;
  }

  static void keys(Map<String, dynamic> json, Set<String> allowed) {
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException();
    }
  }

  static DateTime time(dynamic value) {
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

  static bool sameScope(ConversationScope a, ConversationScope b) =>
      a.accountId == b.accountId &&
      a.sessionId == b.sessionId &&
      a.connectionId == b.connectionId &&
      a.clientInstanceId == b.clientInstanceId &&
      a.epoch == b.epoch;
}

/// A self-contained report of one accepted output snapshot, or a tombstone.
/// Generated source text is retained independently of later final transcripts.
final class PlaybackEvidenceEvent {
  PlaybackEvidenceEvent._(this._record, this.receivedAt);

  factory PlaybackEvidenceEvent.fromJson(Map<String, dynamic> json) =>
      PlaybackEvidenceEvent._parse(json, stored: true);

  factory PlaybackEvidenceEvent.alignment(
    ConversationTurn turn, {
    required String eventId,
    required int sequence,
  }) => PlaybackEvidenceEvent._fromTurn(
    turn,
    eventId: eventId,
    sequence: sequence,
    kind: 'alignment',
  );

  factory PlaybackEvidenceEvent.freeze(
    ConversationTurn turn, {
    required String eventId,
    required int sequence,
    required int stopBoundaryMs,
    required InterruptedPrefixReason reason,
  }) => PlaybackEvidenceEvent._fromTurn(
    turn,
    eventId: eventId,
    sequence: sequence,
    kind: 'freeze',
    stopBoundaryMs: stopBoundaryMs,
    reason: reason == InterruptedPrefixReason.normalEnd
        ? 'normal_end'
        : 'interrupted',
  );

  factory PlaybackEvidenceEvent.revoke(
    String responseId, {
    required String eventId,
    required int sequence,
  }) => PlaybackEvidenceEvent._parse({
    'event_id': eventId,
    'sequence': sequence,
    'kind': 'revoke',
    'response_id': responseId,
  }, stored: false);

  static PlaybackEvidenceEvent _fromTurn(
    ConversationTurn turn, {
    required String eventId,
    required int sequence,
    required String kind,
    int? stopBoundaryMs,
    String? reason,
  }) {
    if (turn.role != ConversationRole.assistant) throw const FormatException();
    return PlaybackEvidenceEvent._parse({
      'event_id': eventId,
      'sequence': sequence,
      'kind': kind,
      'response_id': turn.responseId,
      'turn_id': turn.turnId,
      'turn_index': turn.turnIndex,
      'transcript_revision': turn.revision,
      'generated_text': turn.text,
      'transcript_final': turn.isFinal,
      'playback_revision': turn.playback.revision,
      'delivery_status': switch (turn.playback.status) {
        DeliveryStatus.notPlayed => 'not_played',
        final status => status.name,
      },
      'played_text': turn.playback.playedText,
      'played_until_ms': turn.playback.playedUntilMs,
      'evidence_source': turn.playback.source == PlaybackEvidenceSource.unknown
          ? 'unknown'
          : 'device_output_aligned',
      'stop_boundary_ms': stopBoundaryMs,
      'reason': reason,
    }, stored: false);
  }

  static PlaybackEvidenceEvent _parse(
    Map<String, dynamic> json, {
    required bool stored,
  }) {
    PlaybackEvidenceValidation.keys(json, {
      'event_id',
      'sequence',
      'kind',
      'response_id',
      'turn_id',
      'turn_index',
      'transcript_revision',
      'generated_text',
      'transcript_final',
      'playback_revision',
      'delivery_status',
      'played_text',
      'played_until_ms',
      'evidence_source',
      'stop_boundary_ms',
      'reason',
      if (stored) 'received_at',
    });
    final eventId = PlaybackEvidenceValidation.id(json['event_id']);
    final sequence = PlaybackEvidenceValidation.number(
      json['sequence'],
      1,
      2147483647,
    );
    final responseId = PlaybackEvidenceValidation.id(json['response_id']);
    final kind = switch (json['kind']) {
      'alignment' => PlaybackEvidenceKind.alignment,
      'freeze' => PlaybackEvidenceKind.freeze,
      'revoke' => PlaybackEvidenceKind.revoke,
      _ => throw const FormatException(),
    };
    final record = <String, Object?>{
      'event_id': eventId,
      'sequence': sequence,
      'kind': kind.name,
      'response_id': responseId,
    };
    if (kind == PlaybackEvidenceKind.revoke) {
      if (json.entries.any(
        (e) =>
            !{
              'event_id',
              'sequence',
              'kind',
              'response_id',
              'received_at',
            }.contains(e.key) &&
            e.value != null,
      )) {
        throw const FormatException();
      }
    } else {
      final transcript = PlaybackEvidenceValidation.number(
        json['transcript_revision'],
        kind == PlaybackEvidenceKind.freeze ? 0 : 1,
        2147483647,
      );
      final playback = PlaybackEvidenceValidation.number(
        json['playback_revision'],
        kind == PlaybackEvidenceKind.freeze ? 0 : 1,
        2147483647,
      );
      final generated = PlaybackEvidenceValidation.text(json['generated_text']);
      final played = PlaybackEvidenceValidation.text(json['played_text']);
      final isFinal = json['transcript_final'];
      if (isFinal is! bool) throw const FormatException();
      final until = json['played_until_ms'] == null
          ? null
          : PlaybackEvidenceValidation.number(
              json['played_until_ms'],
              0,
              86400000,
            );
      final status = json['delivery_status'];
      final source = json['evidence_source'];
      switch (status) {
        case 'unknown':
          if (played.isNotEmpty || until != null || source != 'unknown') {
            throw const FormatException();
          }
        case 'not_played':
          if (played.isNotEmpty ||
              until != 0 ||
              !isFinal ||
              source != 'device_output_aligned' ||
              playback == 0) {
            throw const FormatException();
          }
        case 'partial':
          if (played.isEmpty ||
              !generated.startsWith(played) ||
              played == generated ||
              until == null ||
              until == 0 ||
              source != 'device_output_aligned' ||
              playback == 0) {
            throw const FormatException();
          }
        case 'played':
          if (played.isEmpty ||
              generated != played ||
              !isFinal ||
              until == null ||
              until == 0 ||
              source != 'device_output_aligned' ||
              playback == 0) {
            throw const FormatException();
          }
        default:
          throw const FormatException();
      }
      if ((transcript == 0 &&
              (generated.isNotEmpty ||
                  isFinal ||
                  playback != 0 ||
                  status != 'unknown')) ||
          (playback == 0 && status != 'unknown')) {
        throw const FormatException();
      }
      record.addAll({
        'turn_id': PlaybackEvidenceValidation.id(json['turn_id']),
        'turn_index': PlaybackEvidenceValidation.number(
          json['turn_index'],
          1,
          2147483647,
        ),
        'transcript_revision': transcript,
        'generated_text': generated,
        'transcript_final': isFinal,
        'playback_revision': playback,
        'delivery_status': status,
        'played_text': played,
        'played_until_ms': until,
        'evidence_source': source,
      });
      if (kind == PlaybackEvidenceKind.freeze) {
        final boundary = PlaybackEvidenceValidation.number(
          json['stop_boundary_ms'],
          0,
          86400000,
        );
        if ((until != null && until > boundary) ||
            !{'interrupted', 'normal_end'}.contains(json['reason'])) {
          throw const FormatException();
        }
        record['stop_boundary_ms'] = boundary;
        record['reason'] = json['reason'];
      } else if (json['stop_boundary_ms'] != null || json['reason'] != null) {
        throw const FormatException();
      }
    }
    return PlaybackEvidenceEvent._(
      Map.unmodifiable(record),
      stored ? PlaybackEvidenceValidation.time(json['received_at']) : null,
    );
  }

  final Map<String, Object?> _record;
  final DateTime? receivedAt;
  String get eventId => _record['event_id'] as String;
  int get sequence => _record['sequence'] as int;
  PlaybackEvidenceKind get kind =>
      PlaybackEvidenceKind.values.byName(_record['kind'] as String);
  String get responseId => _record['response_id'] as String;
  String? get turnId => _record['turn_id'] as String?;
  int? get turnIndex => _record['turn_index'] as int?;
  int? get transcriptRevision => _record['transcript_revision'] as int?;
  String? get generatedText => _record['generated_text'] as String?;
  bool? get transcriptFinal => _record['transcript_final'] as bool?;
  int? get playbackRevision => _record['playback_revision'] as int?;
  DeliveryStatus? get deliveryStatus => switch (_record['delivery_status']) {
    'unknown' => DeliveryStatus.unknown,
    'not_played' => DeliveryStatus.notPlayed,
    'partial' => DeliveryStatus.partial,
    'played' => DeliveryStatus.played,
    _ => null,
  };
  String? get playedText => _record['played_text'] as String?;
  int? get playedUntilMs => _record['played_until_ms'] as int?;
  PlaybackEvidenceSource? get evidenceSource =>
      switch (_record['evidence_source']) {
        'unknown' => PlaybackEvidenceSource.unknown,
        'device_output_aligned' => PlaybackEvidenceSource.deviceOutputAligned,
        _ => null,
      };
  int? get stopBoundaryMs => _record['stop_boundary_ms'] as int?;
  InterruptedPrefixReason? get reason => switch (_record['reason']) {
    'interrupted' => InterruptedPrefixReason.interrupted,
    'normal_end' => InterruptedPrefixReason.normalEnd,
    _ => null,
  };
  int get textBytes =>
      utf8.encode(generatedText ?? '').length +
      utf8.encode(playedText ?? '').length;
  Map<String, Object?> toRequestJson() => _record;

  bool sameSnapshot(PlaybackEvidenceEvent other) {
    final a = {..._record}
      ..remove('event_id')
      ..remove('sequence');
    final b = {...other._record}
      ..remove('event_id')
      ..remove('sequence');
    return a.length == b.length &&
        a.entries.every((e) => b.containsKey(e.key) && b[e.key] == e.value);
  }
}

final class PlaybackEvidencePrefix {
  const PlaybackEvidencePrefix({
    required this.evidence,
    required this.stopBoundaryMs,
    required this.reason,
  });
  final PlaybackEvidenceEvent evidence;
  final int stopBoundaryMs;
  final InterruptedPrefixReason reason;
}

final class PlaybackEvidenceTurn {
  const PlaybackEvidenceTurn({
    required this.latest,
    required this.freeze,
    required this.frozenPrefix,
    required this.revoked,
  });
  final PlaybackEvidenceEvent latest;
  final PlaybackEvidenceEvent? freeze;
  final PlaybackEvidencePrefix? frozenPrefix;
  final bool revoked;
  String get turnId => latest.turnId!;
  int get turnIndex => latest.turnIndex!;
  String get responseId => latest.responseId;
}

/// Immutable bounded validation state shared by upload and read reconstruction.
/// It never creates ConversationContext or marks a transcript as played.
final class PlaybackEvidenceLedger {
  PlaybackEvidenceLedger._(
    this.events,
    this.turns,
    this.revokedResponseIds,
    this.textBytes,
    this.normalEvents,
    this.revocations,
  );
  factory PlaybackEvidenceLedger.empty() =>
      PlaybackEvidenceLedger._(const [], const [], const {}, 0, 0, 0);

  PlaybackEvidenceLedger append(PlaybackEvidenceEvent event) =>
      PlaybackEvidenceLedger.fromEvents([...events, event]);

  factory PlaybackEvidenceLedger.fromEvents(
    Iterable<PlaybackEvidenceEvent> input,
  ) {
    final events = input.toList(growable: false);
    final turns = <String, PlaybackEvidenceTurn>{};
    final indices = <int, String>{};
    final responses = <String>{};
    final revoked = <String>{};
    final boundaries = <String, (int, InterruptedPrefixReason)>{};
    final greatestPlayedUntil = <String, int>{};
    final ids = <String>{};
    var bytes = 0;
    var normal = 0;
    var revocations = 0;
    var sequence = 0;
    for (final event in events) {
      if (!ids.add(event.eventId) || event.sequence <= sequence) {
        throw const FormatException();
      }
      sequence = event.sequence;
      responses.add(event.responseId);
      if (responses.length > 256) throw const FormatException();
      if (event.kind == PlaybackEvidenceKind.revoke) {
        if (!revoked.add(event.responseId) ||
            ++revocations > maxPlaybackEvidenceRevocations) {
          throw const FormatException();
        }
        continue;
      }
      if (revoked.contains(event.responseId) ||
          ++normal > maxPlaybackEvidenceNormalEvents) {
        throw const FormatException();
      }
      bytes += event.textBytes;
      if (bytes > maxPlaybackEvidenceTextBytes) throw const FormatException();
      final id = event.turnId!;
      final old = turns[id];
      final indexOwner = indices[event.turnIndex!];
      if ((indexOwner != null && indexOwner != id) ||
          (old != null &&
              (old.turnIndex != event.turnIndex ||
                  old.responseId != event.responseId))) {
        throw const FormatException();
      }
      final prior = old?.latest;
      if (prior != null) {
        if (event.transcriptRevision! < prior.transcriptRevision! ||
            (prior.transcriptFinal! && !event.transcriptFinal!)) {
          throw const FormatException();
        }
        if (event.transcriptRevision == prior.transcriptRevision) {
          if (event.generatedText != prior.generatedText ||
              event.transcriptFinal != prior.transcriptFinal ||
              event.playbackRevision! < prior.playbackRevision!) {
            throw const FormatException();
          }
          if (event.playbackRevision == prior.playbackRevision) {
            if (event.deliveryStatus != prior.deliveryStatus ||
                event.playedText != prior.playedText ||
                event.playedUntilMs != prior.playedUntilMs ||
                event.evidenceSource != prior.evidenceSource ||
                event.kind != PlaybackEvidenceKind.freeze) {
              throw const FormatException();
            }
          } else if ((prior.deliveryStatus == DeliveryStatus.played &&
                  event.deliveryStatus != DeliveryStatus.played) ||
              (prior.deliveryStatus == DeliveryStatus.notPlayed &&
                  event.deliveryStatus != DeliveryStatus.notPlayed) ||
              (prior.deliveryStatus != DeliveryStatus.unknown &&
                  (event.deliveryStatus == DeliveryStatus.unknown ||
                      !event.playedText!.startsWith(prior.playedText!) ||
                      event.playedUntilMs! < prior.playedUntilMs!))) {
            throw const FormatException();
          }
        }
      }
      var freeze = old?.freeze;
      if (event.kind == PlaybackEvidenceKind.alignment &&
          boundaries.containsKey(event.responseId) &&
          freeze == null) {
        throw const FormatException();
      }
      if (event.kind == PlaybackEvidenceKind.freeze) {
        if (freeze != null) throw const FormatException();
        final value = (event.stopBoundaryMs!, event.reason!);
        if (boundaries[event.responseId] case final known?
            when known != value) {
          throw const FormatException();
        }
        if ((greatestPlayedUntil[event.responseId] ?? 0) > value.$1) {
          throw const FormatException();
        }
        boundaries[event.responseId] = value;
        freeze = event;
      }
      final boundary = boundaries[event.responseId];
      if (boundary != null && (event.playedUntilMs ?? 0) > boundary.$1) {
        throw const FormatException();
      }
      if ((event.playedUntilMs ?? 0) >
          (greatestPlayedUntil[event.responseId] ?? 0)) {
        greatestPlayedUntil[event.responseId] = event.playedUntilMs!;
      }
      var prefix = old?.frozenPrefix;
      if (freeze != null &&
          prefix == null &&
          (event.deliveryStatus == DeliveryStatus.partial ||
              event.deliveryStatus == DeliveryStatus.played)) {
        prefix = PlaybackEvidencePrefix(
          evidence: event,
          stopBoundaryMs: freeze.stopBoundaryMs!,
          reason: freeze.reason!,
        );
      }
      turns[id] = PlaybackEvidenceTurn(
        latest: event,
        freeze: freeze,
        frozenPrefix: prefix,
        revoked: false,
      );
      indices[event.turnIndex!] = id;
      if (turns.length > 256) throw const FormatException();
    }
    final ordered = [
      for (final turn in turns.values)
        PlaybackEvidenceTurn(
          latest: turn.latest,
          freeze: turn.freeze,
          frozenPrefix: revoked.contains(turn.responseId)
              ? null
              : turn.frozenPrefix,
          revoked: revoked.contains(turn.responseId),
        ),
    ]..sort((a, b) => a.turnIndex.compareTo(b.turnIndex));
    return PlaybackEvidenceLedger._(
      List.unmodifiable(events),
      List.unmodifiable(ordered),
      Set.unmodifiable(revoked),
      bytes,
      normal,
      revocations,
    );
  }
  final List<PlaybackEvidenceEvent> events;
  final List<PlaybackEvidenceTurn> turns;
  final Set<String> revokedResponseIds;
  final int textBytes;
  final int normalEvents;
  final int revocations;
}
