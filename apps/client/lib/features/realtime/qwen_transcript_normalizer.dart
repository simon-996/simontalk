import 'dart:convert';

import '../../core/random_uuid.dart';
import '../conversation/conversation_models.dart';
import '../practice/practice_models.dart';

/// Fixed error deliberately excludes provider data and conversation content.
final class QwenTranscriptFailure implements Exception {
  const QwenTranscriptFailure();
  @override
  String toString() => 'QwenTranscriptFailure';
}

/// One ordered, already-authorized provider channel. It creates no playback facts.
final class QwenTranscriptNormalizer {
  QwenTranscriptNormalizer({String Function()? idFactory})
    : _idFactory = idFactory ?? randomUuid;

  final String Function() _idFactory;
  final _items = <String, _Turn>{};
  final _responses = <String, _Turn>{};
  final _identities = <String>{};
  final _events = <String, String>{};
  int _eventBytes = 0;
  int _turnCount = 0;
  bool _closed = false;

  Never _invalid() => throw const QwenTranscriptFailure();

  String _id(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 256 ||
        value.contains('\u0000')) {
      _invalid();
    }
    final bytes = utf8.encode(value);
    if (bytes.length > 256 || utf8.decode(bytes) != value) _invalid();
    return value;
  }

  String _text(Object? value) {
    if (value is! String || value.length > 8192 || value.contains('\u0000')) {
      _invalid();
    }
    final bytes = utf8.encode(value);
    if (bytes.length > 8192 || utf8.decode(bytes) != value) _invalid();
    return value;
  }

  void _zero(Object? value) {
    if (value is! int || value != 0) _invalid();
  }

  String _newId() {
    final value = _idFactory().toLowerCase();
    if (!isPracticeUuid(value) || !_identities.add(value)) _invalid();
    return value;
  }

  _Turn _newTurn(ConversationRole role, {String? response}) {
    if (_turnCount >= 256) _invalid();
    return _Turn(_newId(), ++_turnCount, role, response);
  }

  /// Receives only the explicitly supported event types; callers filter all others.
  /// Any malformed or conflicting event permanently closes this instance.
  List<ConversationUpdate> accept(
    Map<String, Object?> event, {
    bool allowUserStartFromDelta = false,
  }) {
    if (_closed) _invalid();
    try {
      final eventId = _id(event['event_id']);
      final type = _id(event['type']);
      final normalized = <String, Object?>{'type': type};
      switch (type) {
        case 'input_audio_buffer.speech_started':
          normalized['item_id'] = _id(event['item_id']);
        case 'conversation.item.input_audio_transcription.delta':
          normalized['item_id'] = _id(event['item_id']);
          _zero(event['content_index']);
          normalized['text'] = _text(event['text']);
          normalized['stash'] = _text(event['stash']);
          _text('${normalized['text']}${normalized['stash']}');
        case 'conversation.item.input_audio_transcription.completed':
          normalized['item_id'] = _id(event['item_id']);
          _zero(event['content_index']);
          normalized['transcript'] = _text(event['transcript']);
        case 'response.created':
          final response = event['response'];
          if (response is! Map) _invalid();
          normalized['response_id'] = _id(response['id']);
        case 'response.output_item.added':
          normalized['response_id'] = _id(event['response_id']);
          _zero(event['output_index']);
          final item = event['item'];
          if (item is! Map ||
              item['type'] != 'message' ||
              item['role'] != 'assistant') {
            _invalid();
          }
          normalized['item_id'] = _id(item['id']);
        case 'response.audio_transcript.delta':
        case 'response.audio_transcript.done':
          normalized['response_id'] = _id(event['response_id']);
          normalized['item_id'] = _id(event['item_id']);
          _zero(event['output_index']);
          _zero(event['content_index']);
          final key = type.endsWith('.delta') ? 'delta' : 'transcript';
          normalized[key] = _text(event[key]);
        default:
          _invalid();
      }
      final signature = jsonEncode(normalized);
      final old = _events[eventId];
      if (old != null) {
        if (old != signature) _invalid();
        return const [];
      }
      final bytes = utf8.encode(eventId).length + utf8.encode(signature).length;
      if (_events.length >= 1024 || _eventBytes + bytes > 262144) _invalid();
      final updates = _apply(type, normalized, allowUserStartFromDelta);
      _events[eventId] = signature;
      _eventBytes += bytes;
      return List.unmodifiable(updates);
    } on Object {
      dispose();
      throw const QwenTranscriptFailure();
    }
  }

  List<ConversationUpdate> _apply(
    String type,
    Map<String, Object?> data,
    bool allowUserStartFromDelta,
  ) {
    switch (type) {
      case 'input_audio_buffer.speech_started':
        final itemId = data['item_id'] as String;
        final existing = _items[itemId];
        if (existing != null) {
          if (existing.role != ConversationRole.user || existing.isFinal) {
            _invalid();
          }
          return const [];
        }
        final turn = _newTurn(ConversationRole.user)..itemId = itemId;
        _items[itemId] = turn;
        return [turn.started()];
      case 'response.created':
        final responseId = data['response_id'] as String;
        if (_responses.containsKey(responseId)) _invalid();
        final response = _newId();
        final turn = _newTurn(ConversationRole.assistant, response: response);
        _responses[responseId] = turn;
        return [turn.started()];
      case 'response.output_item.added':
        final turn = _responses[data['response_id']];
        final itemId = data['item_id'] as String;
        if (turn == null ||
            turn.isFinal ||
            turn.itemId != null ||
            _items.containsKey(itemId)) {
          _invalid();
        }
        turn.itemId = itemId;
        _items[itemId] = turn;
        return [turn.started()];
      case 'conversation.item.input_audio_transcription.delta':
      case 'conversation.item.input_audio_transcription.completed':
        var turn = _items[data['item_id']];
        final isFinal = type.endsWith('.completed');
        final text = isFinal
            ? data['transcript'] as String
            : '${data['text']}${data['stash']}';
        if (turn == null && !isFinal && allowUserStartFromDelta) {
          if (text.trim().isEmpty) _invalid();
          final itemId = data['item_id'] as String;
          turn = _newTurn(ConversationRole.user)..itemId = itemId;
          _items[itemId] = turn;
          return [turn.started(), ...turn.update(text, false)];
        }
        if (turn == null || turn.role != ConversationRole.user) _invalid();
        return turn.update(text, isFinal);
      case 'response.audio_transcript.delta':
      case 'response.audio_transcript.done':
        final turn = _responses[data['response_id']];
        if (turn == null ||
            turn.itemId == null ||
            turn.itemId != data['item_id'] ||
            _items[data['item_id']] != turn) {
          _invalid();
        }
        final isFinal = type.endsWith('.done');
        final text = isFinal
            ? data['transcript'] as String
            : '${turn.text}${data['delta']}';
        _text(text);
        return turn.update(text, isFinal);
      default:
        _invalid();
    }
  }

  void dispose() {
    _closed = true;
    _items.clear();
    _responses.clear();
    _identities.clear();
    _events.clear();
    _eventBytes = 0;
  }
}

final class _Turn {
  _Turn(this.id, this.index, this.role, this.responseId);
  final String id;
  final int index;
  final ConversationRole role;
  final String? responseId;
  String? itemId;
  String text = '';
  int revision = 0;
  bool isFinal = false;

  TurnStartedUpdate started() => TurnStartedUpdate(
    turnId: id,
    turnIndex: index,
    role: role,
    responseId: responseId,
    providerItemId: itemId,
  );

  List<ConversationUpdate> update(String next, bool finalText) {
    if (isFinal) {
      if (!finalText || next != text) throw const QwenTranscriptFailure();
      return const [];
    }
    text = next;
    isFinal = finalText;
    revision++;
    return [
      TranscriptUpdate(
        turnId: id,
        turnIndex: index,
        role: role,
        revision: revision,
        text: text,
        isFinal: isFinal,
        responseId: responseId,
        providerItemId: itemId,
      ),
    ];
  }
}
