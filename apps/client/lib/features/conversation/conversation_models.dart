import '../practice/practice_models.dart';

final class ConversationFailure implements Exception {
  const ConversationFailure(this.code);
  final String code;
  @override
  String toString() => 'ConversationFailure($code)';
}

final class ConversationScope {
  factory ConversationScope({
    required String accountId,
    required String sessionId,
    required String connectionId,
    required String clientInstanceId,
    required int epoch,
  }) {
    if ([
          accountId,
          sessionId,
          connectionId,
          clientInstanceId,
        ].any((id) => !isPracticeUuid(id)) ||
        epoch < 1 ||
        epoch > 2147483647) {
      throw const ConversationFailure('conversation_invalid');
    }
    return ConversationScope._(
      accountId.toLowerCase(),
      sessionId.toLowerCase(),
      connectionId.toLowerCase(),
      clientInstanceId.toLowerCase(),
      epoch,
    );
  }
  const ConversationScope._(
    this.accountId,
    this.sessionId,
    this.connectionId,
    this.clientInstanceId,
    this.epoch,
  );
  final String accountId;
  final String sessionId;
  final String connectionId;
  final String clientInstanceId;
  final int epoch;
}

enum ConversationRole { user, assistant }

enum DeliveryStatus { unknown, notPlayed, partial, played }

enum PlaybackEvidenceSource { unknown, deviceOutputAligned }

enum ConversationApplyResult {
  applied,
  duplicate,
  stale,
  awaitingTranscript,
  closed,
}

/// An adapter provides a full normalized snapshot, never an unassociated raw delta.
sealed class ConversationUpdate {
  const ConversationUpdate({required this.turnId});
  final String turnId;
}

final class TranscriptUpdate extends ConversationUpdate {
  const TranscriptUpdate({
    required super.turnId,
    required this.turnIndex,
    required this.role,
    required this.revision,
    required this.text,
    required this.isFinal,
    this.responseId,
    this.providerItemId,
  });
  final int turnIndex;
  final ConversationRole role;
  final int revision;
  final String text;
  final bool isFinal;
  final String? responseId;
  final String? providerItemId;
}

/// Known prefixes require adapter-verified device output with text alignment.
/// Neither a generation-complete event nor elapsed playback time supplies this.
final class PlaybackUpdate extends ConversationUpdate {
  const PlaybackUpdate({
    required super.turnId,
    required this.responseId,
    required this.transcriptRevision,
    required this.revision,
    required this.status,
    required this.playedText,
    required this.playedUntilMs,
    required this.source,
  });
  final String responseId;
  final int transcriptRevision;
  final int revision;
  final DeliveryStatus status;
  final String playedText;
  final int? playedUntilMs;
  final PlaybackEvidenceSource source;
}

final class ConversationPlayback {
  const ConversationPlayback({
    required this.revision,
    required this.status,
    required this.playedText,
    required this.playedUntilMs,
    required this.source,
  });
  const ConversationPlayback.unknown()
    : revision = 0,
      status = DeliveryStatus.unknown,
      playedText = '',
      playedUntilMs = null,
      source = PlaybackEvidenceSource.unknown;
  final int revision;
  final DeliveryStatus status;
  final String playedText;
  final int? playedUntilMs;
  final PlaybackEvidenceSource source;
}

final class ConversationTurn {
  const ConversationTurn({
    required this.turnId,
    required this.turnIndex,
    required this.role,
    required this.revision,
    required this.text,
    required this.isFinal,
    required this.responseId,
    required this.providerItemId,
    required this.playback,
  });
  final String turnId;
  final int turnIndex;
  final ConversationRole role;
  final int revision;
  final String text;
  final bool isFinal;
  final String? responseId;
  final String? providerItemId;
  final ConversationPlayback playback;
}

final class ConversationContextEntry {
  const ConversationContextEntry({
    required this.turnId,
    required this.turnIndex,
    required this.role,
    required this.transcriptRevision,
    required this.text,
    required this.responseId,
  });
  final String turnId;
  final int turnIndex;
  final ConversationRole role;
  final int transcriptRevision;
  final String text;
  final String? responseId;
}

final class ConversationContext {
  ConversationContext(this.scope, Iterable<ConversationContextEntry> entries)
    : entries = List.unmodifiable(entries);
  final ConversationScope scope;
  final List<ConversationContextEntry> entries;
  String get source => 'client_reported';
}

final class ConversationSnapshot {
  ConversationSnapshot({
    required this.scope,
    required this.revision,
    required this.isSealed,
    required Iterable<ConversationTurn> turns,
  }) : turns = List.unmodifiable(turns);
  final ConversationScope scope;
  final int revision;
  final bool isSealed;
  final List<ConversationTurn> turns;
  bool get hasUnfinalizedText =>
      turns.any((t) => !t.isFinal && t.text.isNotEmpty);
  bool get hasUnconfirmedPlayback => turns.any(
    (t) =>
        t.role == ConversationRole.assistant &&
        t.text.isNotEmpty &&
        t.playback.status == DeliveryStatus.unknown,
  );

  ConversationContext get context => ConversationContext(scope, [
    for (final turn in turns)
      if (turn.isFinal &&
          (turn.role == ConversationRole.user ||
              turn.playback.status == DeliveryStatus.partial ||
              turn.playback.status == DeliveryStatus.played))
        if ((turn.role == ConversationRole.user
                ? turn.text
                : turn.playback.playedText)
            .trim()
            .isNotEmpty)
          ConversationContextEntry(
            turnId: turn.turnId,
            turnIndex: turn.turnIndex,
            role: turn.role,
            transcriptRevision: turn.revision,
            text: turn.role == ConversationRole.user
                ? turn.text
                : turn.playback.playedText,
            responseId: turn.responseId,
          ),
  ]);
}
