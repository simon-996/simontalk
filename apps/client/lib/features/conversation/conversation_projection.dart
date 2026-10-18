import 'dart:convert';

import '../practice/practice_models.dart';
import 'conversation_models.dart';

/// One bounded connection projection. No audio, raw provider events or persistence.
class ConversationProjection {
  ConversationProjection(this.scope);
  final ConversationScope scope;
  final _turns = <String, ConversationTurn>{};
  int _revision = 0;
  int _bytes = 0;
  bool _sealed = false;
  static const maxTurns = 256;
  static const maxTextBytes = 8192;
  static const maxTotalBytes = 262144;

  ConversationSnapshot get snapshot => ConversationSnapshot(
    scope: scope,
    revision: _revision,
    isSealed: _sealed,
    turns: _turns.values.toList()
      ..sort((a, b) => a.turnIndex.compareTo(b.turnIndex)),
  );

  ConversationApplyResult apply(ConversationUpdate update) {
    if (_sealed) return ConversationApplyResult.closed;
    return switch (update) {
      TranscriptUpdate() => _transcript(update),
      PlaybackUpdate() => _playback(update),
    };
  }

  Never _invalid() => throw const ConversationFailure('conversation_invalid');
  String _id(String value) {
    if (!isPracticeUuid(value)) _invalid();
    return value.toLowerCase();
  }

  void _positive(int value) {
    if (value < 1 || value > 2147483647) _invalid();
  }

  int _textBytes(String value) {
    if (value.length > maxTextBytes) _invalid();
    final bytes = utf8.encode(value);
    if (bytes.length > maxTextBytes || utf8.decode(bytes) != value) _invalid();
    return bytes.length;
  }

  ConversationApplyResult _transcript(TranscriptUpdate u) {
    final id = _id(u.turnId);
    final response = u.responseId == null ? null : _id(u.responseId!);
    _positive(u.revision);
    _positive(u.turnIndex);
    _textBytes(u.text);
    if ((u.role == ConversationRole.assistant) != (response != null) ||
        (u.providerItemId != null &&
            (u.providerItemId!.isEmpty || u.providerItemId!.length > 256))) {
      _invalid();
    }
    final old = _turns[id];
    if (old != null) {
      if (old.turnIndex != u.turnIndex ||
          old.role != u.role ||
          old.responseId != response ||
          old.providerItemId != u.providerItemId) {
        _invalid();
      }
      if (u.revision < old.revision) return ConversationApplyResult.stale;
      if (u.revision == old.revision) {
        if (old.text != u.text || old.isFinal != u.isFinal) _invalid();
        return ConversationApplyResult.duplicate;
      }
      if (old.isFinal && !u.isFinal) _invalid();
    } else if (_turns.values.any((turn) => turn.turnIndex == u.turnIndex)) {
      _invalid();
    }
    return _put(
      ConversationTurn(
        turnId: id,
        turnIndex: u.turnIndex,
        role: u.role,
        revision: u.revision,
        text: u.text,
        isFinal: u.isFinal,
        responseId: response,
        providerItemId: u.providerItemId,
        playback: const ConversationPlayback.unknown(),
      ),
    );
  }

  ConversationApplyResult _playback(PlaybackUpdate u) {
    final id = _id(u.turnId);
    final response = _id(u.responseId);
    _positive(u.revision);
    _positive(u.transcriptRevision);
    _textBytes(u.playedText);
    final until = u.playedUntilMs;
    if (until != null && (until < 0 || until > 86400000)) _invalid();
    switch (u.status) {
      case DeliveryStatus.unknown:
        if (u.playedText.isNotEmpty ||
            until != null ||
            u.source != PlaybackEvidenceSource.unknown) {
          _invalid();
        }
      case DeliveryStatus.notPlayed:
        if (u.playedText.isNotEmpty ||
            until != 0 ||
            u.source != PlaybackEvidenceSource.deviceOutputAligned) {
          _invalid();
        }
      case DeliveryStatus.partial:
      case DeliveryStatus.played:
        if (u.playedText.isEmpty ||
            until == null ||
            until == 0 ||
            u.source != PlaybackEvidenceSource.deviceOutputAligned) {
          _invalid();
        }
    }
    final turn = _turns[id];
    if (turn == null) return ConversationApplyResult.awaitingTranscript;
    if (turn.role != ConversationRole.assistant ||
        turn.responseId != response) {
      _invalid();
    }
    if (u.transcriptRevision < turn.revision) {
      return ConversationApplyResult.stale;
    }
    if (u.transcriptRevision > turn.revision) {
      return ConversationApplyResult.awaitingTranscript;
    }
    final old = turn.playback;
    if (u.revision < old.revision) return ConversationApplyResult.stale;
    if (u.revision == old.revision) {
      if (u.status != old.status ||
          u.playedText != old.playedText ||
          u.playedUntilMs != old.playedUntilMs ||
          u.source != old.source) {
        _invalid();
      }
      return ConversationApplyResult.duplicate;
    }
    if ((u.status == DeliveryStatus.partial &&
            (!turn.text.startsWith(u.playedText) ||
                turn.text == u.playedText)) ||
        (u.status == DeliveryStatus.played &&
            (!turn.isFinal || turn.text != u.playedText)) ||
        (u.status == DeliveryStatus.notPlayed && !turn.isFinal)) {
      _invalid();
    }
    if ((old.status == DeliveryStatus.played &&
            u.status != DeliveryStatus.played) ||
        (old.status == DeliveryStatus.notPlayed &&
            u.status != DeliveryStatus.notPlayed) ||
        (old.status != DeliveryStatus.unknown &&
            (u.status == DeliveryStatus.unknown ||
                !u.playedText.startsWith(old.playedText) ||
                until! < old.playedUntilMs!))) {
      _invalid();
    }
    return _put(
      ConversationTurn(
        turnId: turn.turnId,
        turnIndex: turn.turnIndex,
        role: turn.role,
        revision: turn.revision,
        text: turn.text,
        isFinal: turn.isFinal,
        responseId: turn.responseId,
        providerItemId: turn.providerItemId,
        playback: ConversationPlayback(
          revision: u.revision,
          status: u.status,
          playedText: u.playedText,
          playedUntilMs: until,
          source: u.source,
        ),
      ),
    );
  }

  int _size(ConversationTurn turn) =>
      utf8.encode(turn.text).length +
      utf8.encode(turn.playback.playedText).length;
  ConversationApplyResult _put(ConversationTurn turn) {
    final old = _turns[turn.turnId];
    final nextBytes = _bytes - (old == null ? 0 : _size(old)) + _size(turn);
    if ((old == null && _turns.length >= maxTurns) ||
        nextBytes > maxTotalBytes) {
      throw const ConversationFailure('conversation_limit_reached');
    }
    _turns[turn.turnId] = turn;
    _bytes = nextBytes;
    _revision++;
    return ConversationApplyResult.applied;
  }

  void seal() {
    if (_sealed) return;
    _sealed = true;
    _revision++;
  }

  /// Releases retained text and permanently prevents this scope being reused.
  void clear() {
    seal();
    if (_turns.isNotEmpty) _revision++;
    _turns.clear();
    _bytes = 0;
  }
}
