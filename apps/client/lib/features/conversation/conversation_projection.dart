import 'dart:convert';

import '../practice/practice_models.dart';
import 'conversation_models.dart';

/// One bounded connection projection. No audio, raw provider events or persistence.
class ConversationProjection {
  ConversationProjection(this.scope);
  final ConversationScope scope;
  final _turns = <String, ConversationTurn>{};
  final _frozenResponses = <String, _FrozenResponse>{};
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
      TurnStartedUpdate() => _started(update),
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

  void _association({
    required String id,
    required int index,
    required ConversationRole role,
    required String? response,
    required String? provider,
  }) {
    _positive(index);
    final frozen = response == null ? null : _frozenResponses[response];
    if ((role == ConversationRole.assistant) != (response != null) ||
        (provider != null &&
            (provider.isEmpty ||
                provider.length > 256 ||
                provider.contains('\u0000') ||
                utf8.decode(utf8.encode(provider)) != provider)) ||
        _turns.values.any(
          (turn) =>
              turn.turnId != id &&
              (turn.turnIndex == index ||
                  (provider != null && turn.providerItemId == provider)),
        ) ||
        (frozen != null && !frozen.turnIds.contains(id))) {
      _invalid();
    }
  }

  ConversationApplyResult _started(TurnStartedUpdate u) {
    final id = _id(u.turnId);
    final response = u.responseId == null ? null : _id(u.responseId!);
    _association(
      id: id,
      index: u.turnIndex,
      role: u.role,
      response: response,
      provider: u.providerItemId,
    );
    final old = _turns[id];
    if (old != null) {
      if (old.turnIndex != u.turnIndex ||
          old.role != u.role ||
          old.responseId != response ||
          (u.providerItemId != null &&
              old.providerItemId != u.providerItemId &&
              (old.providerItemId != null || old.isFinal))) {
        _invalid();
      }
      if (u.providerItemId == null || old.providerItemId == u.providerItemId) {
        return ConversationApplyResult.duplicate;
      }
      return _put(_copy(old, providerItemId: u.providerItemId));
    }
    return _put(
      ConversationTurn(
        turnId: id,
        turnIndex: u.turnIndex,
        role: u.role,
        revision: 0,
        text: '',
        isFinal: false,
        responseId: response,
        providerItemId: u.providerItemId,
        playback: const ConversationPlayback.unknown(),
      ),
    );
  }

  ConversationApplyResult _transcript(TranscriptUpdate u) {
    final id = _id(u.turnId);
    final response = u.responseId == null ? null : _id(u.responseId!);
    _positive(u.revision);
    _textBytes(u.text);
    _association(
      id: id,
      index: u.turnIndex,
      role: u.role,
      response: response,
      provider: u.providerItemId,
    );
    final old = _turns[id];
    if (old != null) {
      if (old.turnIndex != u.turnIndex ||
          old.role != u.role ||
          old.responseId != response ||
          (old.providerItemId != u.providerItemId &&
              !(old.providerItemId == null &&
                  !old.isFinal &&
                  u.providerItemId != null))) {
        _invalid();
      }
      if (u.revision < old.revision) return ConversationApplyResult.stale;
      if (u.revision == old.revision) {
        if (old.text != u.text || old.isFinal != u.isFinal) _invalid();
        if (old.providerItemId != u.providerItemId) {
          return _put(_copy(old, providerItemId: u.providerItemId));
        }
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
        frozenPrefix: old?.frozenPrefix,
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
    final frozen = _frozenResponses[response];
    if (frozen?.revoked ?? false) return ConversationApplyResult.stale;
    if (frozen != null && until != null && until > frozen.stopBoundaryMs) {
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
    final next = ConversationTurn(
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
      frozenPrefix: turn.frozenPrefix,
    );
    return _put(frozen == null ? next : _freezeTurn(next, frozen));
  }

  /// Fixes the verified device-output boundary. Replays cannot move it.
  /// The controller separately bounds callback acceptance by time and channel.
  ConversationApplyResult freezeResponse(
    String responseId, {
    required int stopBoundaryMs,
    required InterruptedPrefixReason reason,
  }) {
    if (_sealed) return ConversationApplyResult.closed;
    final response = _id(responseId);
    if (stopBoundaryMs < 0 || stopBoundaryMs > 86400000) _invalid();
    final old = _frozenResponses[response];
    if (old != null) {
      if (old.stopBoundaryMs != stopBoundaryMs || old.reason != reason) {
        _invalid();
      }
      return ConversationApplyResult.duplicate;
    }
    final turns = _turns.values
        .where((turn) => turn.responseId == response)
        .toList();
    if (turns.isEmpty ||
        turns.any(
          (turn) => (turn.playback.playedUntilMs ?? 0) > stopBoundaryMs,
        )) {
      _invalid();
    }
    final frozen = _FrozenResponse(
      stopBoundaryMs: stopBoundaryMs,
      reason: reason,
      turnIds: turns.map((turn) => turn.turnId).toSet(),
    );
    _putAll(turns.map((turn) => _freezeTurn(turn, frozen)).toList());
    _frozenResponses[response] = frozen;
    return ConversationApplyResult.applied;
  }

  /// Use only when new facts disprove alignment. This response stays unusable
  /// rather than guessing that another version has the same audible content.
  ConversationApplyResult revokeFrozenPrefix(String responseId) {
    if (_sealed) return ConversationApplyResult.closed;
    final response = _id(responseId);
    final frozen = _frozenResponses[response];
    if (frozen == null) _invalid();
    if (frozen.revoked) return ConversationApplyResult.duplicate;
    _putAll([
      for (final turn in _turns.values)
        if (turn.responseId == response)
          _copy(
            turn,
            playback: const ConversationPlayback.unknown(),
            clearFrozenPrefix: true,
          ),
    ]);
    frozen.revoked = true;
    return ConversationApplyResult.applied;
  }

  ConversationTurn _freezeTurn(ConversationTurn turn, _FrozenResponse frozen) {
    final playback = turn.playback;
    if (turn.frozenPrefix != null ||
        frozen.revoked ||
        (playback.status != DeliveryStatus.partial &&
            playback.status != DeliveryStatus.played)) {
      return turn;
    }
    return _copy(
      turn,
      frozenPrefix: ConversationFrozenPrefix(
        transcriptRevision: turn.revision,
        playbackRevision: playback.revision,
        text: playback.playedText,
        playedUntilMs: playback.playedUntilMs!,
        stopBoundaryMs: frozen.stopBoundaryMs,
        source: playback.source,
        reason: frozen.reason,
      ),
    );
  }

  ConversationTurn _copy(
    ConversationTurn turn, {
    String? providerItemId,
    ConversationPlayback? playback,
    ConversationFrozenPrefix? frozenPrefix,
    bool clearFrozenPrefix = false,
  }) => ConversationTurn(
    turnId: turn.turnId,
    turnIndex: turn.turnIndex,
    role: turn.role,
    revision: turn.revision,
    text: turn.text,
    isFinal: turn.isFinal,
    responseId: turn.responseId,
    providerItemId: providerItemId ?? turn.providerItemId,
    playback: playback ?? turn.playback,
    frozenPrefix: clearFrozenPrefix ? null : frozenPrefix ?? turn.frozenPrefix,
  );

  int _size(ConversationTurn turn) =>
      utf8.encode(turn.text).length +
      utf8.encode(turn.playback.playedText).length +
      utf8.encode(turn.frozenPrefix?.text ?? '').length;

  void _putAll(List<ConversationTurn> turns) {
    var nextBytes = _bytes;
    for (final turn in turns) {
      nextBytes += _size(turn) - _size(_turns[turn.turnId]!);
    }
    if (nextBytes > maxTotalBytes) {
      throw const ConversationFailure('conversation_limit_reached');
    }
    for (final turn in turns) {
      _turns[turn.turnId] = turn;
    }
    _bytes = nextBytes;
    _revision++;
  }

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
    _frozenResponses.clear();
    _bytes = 0;
  }
}

final class _FrozenResponse {
  _FrozenResponse({
    required this.stopBoundaryMs,
    required this.reason,
    required this.turnIds,
  });
  final int stopBoundaryMs;
  final InterruptedPrefixReason reason;
  final Set<String> turnIds;
  bool revoked = false;
}
