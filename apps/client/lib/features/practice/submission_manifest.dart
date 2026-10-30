import 'practice_models.dart';

enum SubmissionLedger { transcripts, playback }

/// Only identifiers and budgets are retained after an acknowledgement.
abstract interface class SubmissionManifestProvider {
  SubmissionManifest? get submissionManifest;
}

/// Only a verified server receipt may settle permanently unreceived submissions.
abstract interface class SealedSubmissionReconciler {
  void reconcileSealed(SubmissionManifest received);
  int get permanentlyUnsavedCount;
}

final class SubmissionEventRef {
  factory SubmissionEventRef({required int sequence, required String eventId}) {
    if (sequence < 1 || sequence > 2147483647 || !isPracticeUuid(eventId)) {
      throw const FormatException('Invalid submission reference');
    }
    return SubmissionEventRef._(sequence, eventId.toLowerCase());
  }
  const SubmissionEventRef._(this.sequence, this.eventId);
  final int sequence;
  final String eventId;
  Map<String, Object> toRequestJson() => {
    'sequence': sequence,
    'event_id': eventId,
  };
}

/// A full immutable declaration, including events whose ACK was already read.
/// A sequence gap is legal and does not by itself establish missing input.
final class SubmissionManifest {
  factory SubmissionManifest({
    required SubmissionLedger ledger,
    required Iterable<SubmissionEventRef> events,
    required int totalTextBytes,
    required int pendingCountAtClose,
  }) {
    final limit = ledger == SubmissionLedger.transcripts ? 512 : 768;
    final refs = List<SubmissionEventRef>.unmodifiable(events.take(limit + 1));
    final byteLimit = ledger == SubmissionLedger.transcripts
        ? 1048576
        : 2097152;
    final eventByteLimit = ledger == SubmissionLedger.transcripts
        ? 8192
        : 16384;
    var previous = 0;
    final ids = <String>{};
    if (refs.length > limit ||
        totalTextBytes < 0 ||
        totalTextBytes > byteLimit ||
        totalTextBytes > refs.length * eventByteLimit ||
        pendingCountAtClose < 0 ||
        pendingCountAtClose > refs.length) {
      throw const FormatException('Invalid submission manifest');
    }
    for (final event in refs) {
      if (event.sequence <= previous || !ids.add(event.eventId)) {
        throw const FormatException('Invalid submission manifest');
      }
      previous = event.sequence;
    }
    return SubmissionManifest._(
      ledger,
      refs,
      totalTextBytes,
      pendingCountAtClose,
    );
  }
  const SubmissionManifest._(
    this.ledger,
    this.events,
    this.totalTextBytes,
    this.pendingCountAtClose,
  );

  factory SubmissionManifest.empty(SubmissionLedger ledger) =>
      SubmissionManifest(
        ledger: ledger,
        events: const [],
        totalTextBytes: 0,
        pendingCountAtClose: 0,
      );

  factory SubmissionManifest.fromJson(
    Map<String, dynamic> json, {
    required SubmissionLedger ledger,
  }) {
    const keys = {
      'events',
      'last_sequence',
      'total_events',
      'total_text_bytes',
      'pending_count_at_close',
    };
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['events'] is! List ||
        json['last_sequence'] is! int ||
        json['total_events'] is! int ||
        json['total_text_bytes'] is! int ||
        json['pending_count_at_close'] is! int) {
      throw const FormatException('Invalid submission manifest');
    }
    final rawEvents = json['events'] as List;
    if (rawEvents.length >
        (ledger == SubmissionLedger.transcripts ? 512 : 768)) {
      throw const FormatException('Invalid submission manifest');
    }
    final events = <SubmissionEventRef>[];
    for (final raw in rawEvents) {
      if (raw is! Map<String, dynamic> ||
          raw.length != 2 ||
          !raw.containsKey('event_id') ||
          !raw.containsKey('sequence') ||
          raw['event_id'] is! String ||
          raw['sequence'] is! int) {
        throw const FormatException('Invalid submission manifest');
      }
      events.add(
        SubmissionEventRef(
          sequence: raw['sequence'] as int,
          eventId: raw['event_id'] as String,
        ),
      );
    }
    final manifest = SubmissionManifest(
      ledger: ledger,
      events: events,
      totalTextBytes: json['total_text_bytes'] as int,
      pendingCountAtClose: json['pending_count_at_close'] as int,
    );
    if (json['last_sequence'] != manifest.lastSequence ||
        json['total_events'] != manifest.totalEvents) {
      throw const FormatException('Invalid submission manifest');
    }
    return manifest;
  }

  final SubmissionLedger ledger;
  final List<SubmissionEventRef> events;
  final int totalTextBytes;
  final int pendingCountAtClose;
  int get lastSequence => events.lastOrNull?.sequence ?? 0;
  int get totalEvents => events.length;
  Map<String, Object> toRequestJson() => {
    'events': events.map((e) => e.toRequestJson()).toList(growable: false),
    'last_sequence': lastSequence,
    'total_events': totalEvents,
    'total_text_bytes': totalTextBytes,
    'pending_count_at_close': pendingCountAtClose,
  };
}
