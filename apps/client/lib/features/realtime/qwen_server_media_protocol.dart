import 'dart:convert';

import '../conversation/conversation_models.dart';
import '../practice/practice_models.dart';
import 'qwen_transcript_normalizer.dart';
import 'realtime_session_protocol.dart';
import 'realtime_transport.dart';

/// Event adapter for a server-supervised Qwen WebSocket media session.
///
/// The backend supervisor validates `session.created` / `session.updated` before
/// announcing readiness, and the backend turn pump owns `response.create`,
/// `response.cancel` and playback-settled turn gating. This adapter never emits
/// SDP or upstream model control frames from the browser.
final class QwenServerMediaProtocol implements RealtimeSessionProtocol {
  QwenServerMediaProtocol(this.configuration, this.callbacks) {
    final provider = configuration.provider;
    if (provider.provider != 'dashscope' ||
        provider.region != 'cn-beijing' ||
        provider.model != 'qwen3.8-omni-flash-realtime') {
      throw const RealtimeFailure('realtime_unavailable');
    }
  }

  static const _maxTurns = 64;
  final PracticeConfiguration configuration;
  final RealtimeProtocolCallbacks callbacks;
  final _normalizer = QwenTranscriptNormalizer();
  final _seenUsers = <String>{};
  final _seenResponses = <String>{};
  int _turnCount = 0;
  String? _channel;
  String? _previousUserItem;
  String? _userItem;
  String? _providerResponse;
  String? _providerItem;
  String? _businessResponse;
  bool _configured = false;
  bool _speechStopped = false;
  bool _inputCommitted = false;
  bool _inputFinal = false;
  bool _replyRequested = false;
  bool _responseDone = false;
  bool _interrupting = false;
  bool _draining = false;
  bool _closed = false;

  void _fail() {
    if (_closed) return;
    _closed = true;
    _normalizer.dispose();
    callbacks.fail('qwen_protocol_unavailable');
  }

  String _id(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 256 ||
        value.contains('\u0000') ||
        utf8.encode(value).length > 256 ||
        utf8.decode(utf8.encode(value)) != value) {
      throw const FormatException();
    }
    return value;
  }

  @override
  void channelOpened(String channelId) {
    if (_closed) return;
    if (_configured ||
        _draining ||
        _channel != null ||
        channelId.isEmpty ||
        channelId.length > 64) {
      _fail();
      return;
    }
    _channel = channelId;
    _configured = true;
    callbacks.confirmConfigured(channelId);
  }

  @override
  void receive(RealtimeTransportEvent event) {
    if (_closed) return;
    try {
      if (!_configured ||
          event.channelId != _channel ||
          event.json.length > 65536 ||
          utf8.encode(event.json).length > 65536) {
        throw const FormatException();
      }
      final envelope = jsonDecode(event.json);
      if (envelope is! Map<String, dynamic> || envelope['kind'] is! String) {
        throw const FormatException();
      }
      switch (envelope['kind'] as String) {
        case 'quarantine':
          _receiveQuarantine(_id(envelope['payload']));
        case 'provider_event':
          final raw = envelope['payload'];
          if (raw is! String ||
              raw.length > 65536 ||
              utf8.encode(raw).length > 65536) {
            throw const FormatException();
          }
          final decoded = jsonDecode(raw);
          if (decoded is! Map<String, dynamic> || decoded['type'] is! String) {
            throw const FormatException();
          }
          _receiveProviderEvent(decoded);
        default:
          throw const FormatException();
      }
    } on Object {
      _fail();
    }
  }

  void _receiveQuarantine(String responseId) {
    // Quarantine may arrive either before `response.done` (mid-generation) or
    // after `response.done` while the browser was still playing buffered audio.
    if (_providerResponse == null ||
        responseId != _providerResponse ||
        _businessResponse == null ||
        _interrupting) {
      throw const FormatException();
    }
    _interrupting = true;
    _previousUserItem = _userItem;
    _userItem = null;
    _speechStopped = false;
    _inputCommitted = false;
    _inputFinal = false;
    if (_draining) return;
    callbacks.quarantineUnknownResponse(_businessResponse!, _channel!);
  }

  void _receiveProviderEvent(Map<String, dynamic> event) {
    final type = event['type'] as String;
    if (type == 'error' ||
        type == 'session.created' ||
        type == 'session.updated') {
      throw const FormatException();
    }
    if (_draining) {
      final sameUserItem = _userItem != null && event['item_id'] == _userItem;
      if (type == 'input_audio_buffer.speech_stopped' && sameUserItem) {
        _speechStopped = true;
      } else if (type == 'input_audio_buffer.committed' && sameUserItem) {
        // The server also validates explicit end-of-input commits, which do
        // not generate a speech_stopped event.
        _inputCommitted = true;
      } else if (type ==
              'conversation.item.input_audio_transcription.completed' &&
          sameUserItem &&
          _inputCommitted &&
          !_inputFinal) {
        final transcript = event['transcript'];
        if (transcript is! String || transcript.trim().isEmpty) {
          throw const FormatException();
        }
        _inputFinal = true;
        _emit(event);
      } else if (type == 'response.output_item.added' &&
          _providerResponse != null &&
          event['response_id'] == _providerResponse &&
          _providerItem == null &&
          !_responseDone) {
        final item = event['item'];
        if (item is! Map) throw const FormatException();
        _normalizer.accept(event);
        _providerItem = _id(item['id']);
      } else if (type == 'response.audio_transcript.done' &&
          event['response_id'] == _providerResponse &&
          _providerItem != null &&
          event['item_id'] == _providerItem &&
          !_responseDone) {
        _emit(event);
      } else if (type == 'response.done' && !_responseDone) {
        final response = event['response'];
        if (_providerResponse != null &&
            response is Map &&
            response['id'] == _providerResponse) {
          _finishResponse(event);
        }
      }
      return;
    }

    switch (type) {
      case 'input_audio_buffer.speech_started':
        final item = _id(event['item_id']);
        _id(event['event_id']);
        if (_interrupting) {
          if (item == _previousUserItem ||
              (_userItem == null && _seenUsers.contains(item)) ||
              (_userItem != null && _userItem != item) ||
              _speechStopped) {
            throw const FormatException();
          }
          _userItem ??= item;
          _seenUsers.add(item);
          _emit(event);
          return;
        }
        if (_responseDone) {
          if (_seenUsers.contains(item) || _turnCount >= _maxTurns) {
            throw const FormatException();
          }
          _turnCount++;
          _previousUserItem = _userItem;
          _userItem = item;
          _seenUsers.add(item);
          _providerResponse = null;
          _providerItem = null;
          _businessResponse = null;
          _speechStopped = false;
          _inputCommitted = false;
          _inputFinal = false;
          _replyRequested = false;
          _responseDone = false;
          _emit(event);
          return;
        }
        if (_replyRequested || _speechStopped) {
          throw const FormatException();
        }
        if (_userItem == null) {
          if (_seenUsers.contains(item) || _turnCount >= _maxTurns) {
            throw const FormatException();
          }
          _turnCount++;
          _userItem = item;
          _seenUsers.add(item);
        } else if (_userItem != item) {
          throw const FormatException();
        }
        _emit(event);
      case 'input_audio_buffer.speech_stopped':
        if (_userItem == null ||
            event['item_id'] != _userItem ||
            (_replyRequested && !_interrupting)) {
          throw const FormatException();
        }
        _speechStopped = true;
      case 'input_audio_buffer.committed':
        if (!_speechStopped ||
            event['item_id'] != _userItem ||
            (_replyRequested && !_interrupting)) {
          throw const FormatException();
        }
        _inputCommitted = true;
      case 'conversation.item.input_audio_transcription.delta':
        final item = _id(event['item_id']);
        if (_interrupting) {
          if (item == _previousUserItem ||
              (_userItem == null && _seenUsers.contains(item)) ||
              (_userItem != null && _userItem != item) ||
              _inputFinal) {
            throw const FormatException();
          }
          final allowStart = _userItem == null;
          _userItem ??= item;
          _seenUsers.add(item);
          _emit(event, allowUserStartFromDelta: allowStart);
          return;
        }
        if (_responseDone) {
          if (_seenUsers.contains(item) || _turnCount >= _maxTurns) {
            throw const FormatException();
          }
          _turnCount++;
          _previousUserItem = _userItem;
          _userItem = item;
          _seenUsers.add(item);
          _providerResponse = null;
          _providerItem = null;
          _businessResponse = null;
          _speechStopped = false;
          _inputCommitted = false;
          _inputFinal = false;
          _replyRequested = false;
          _responseDone = false;
          _emit(event, allowUserStartFromDelta: true);
          return;
        }
        if (_userItem == null && !_replyRequested) {
          if (_seenUsers.contains(item) || _turnCount >= _maxTurns) {
            throw const FormatException();
          }
          _turnCount++;
          _userItem = item;
          _seenUsers.add(item);
          _emit(event, allowUserStartFromDelta: true);
          return;
        }
        if (_userItem == null ||
            item != _userItem ||
            _inputFinal ||
            _replyRequested) {
          throw const FormatException();
        }
        _emit(event);
      case 'conversation.item.input_audio_transcription.completed':
        if (!_speechStopped ||
            !_inputCommitted ||
            _inputFinal ||
            event['item_id'] != _userItem ||
            (_replyRequested && !_interrupting)) {
          throw const FormatException();
        }
        final transcript = event['transcript'];
        if (transcript is! String || transcript.trim().isEmpty) {
          throw const FormatException();
        }
        _inputFinal = true;
        _replyRequested = true;
        _emit(event);
      case 'response.created':
        final response = event['response'];
        if (!_replyRequested || response is! Map || _responseDone) {
          throw const FormatException();
        }
        final id = _id(response['id']);
        if (_providerResponse != null) {
          if (_providerResponse != id) throw const FormatException();
          return;
        }
        if (_interrupting || _seenResponses.contains(id)) {
          throw const FormatException();
        }
        _seenResponses.add(id);
        _providerResponse = id;
        _emit(event);
      case 'response.output_item.added':
        final item = event['item'];
        if (_providerResponse == null ||
            event['response_id'] != _providerResponse ||
            item is! Map ||
            _responseDone) {
          throw const FormatException();
        }
        _providerItem = _id(item['id']);
        _emit(event);
      case 'response.audio_transcript.delta':
      case 'response.audio_transcript.done':
        if (_providerResponse == null ||
            event['response_id'] != _providerResponse ||
            _responseDone) {
          throw const FormatException();
        }
        _emit(event);
      case 'response.done':
        _finishResponse(event);
      case 'conversation.item.created':
      case 'response.content_part.added':
      case 'response.content_part.done':
      case 'response.output_item.done':
      case 'response.audio.done':
        break;
      default:
        throw const FormatException();
    }
  }

  List<ConversationUpdate> _emit(
    Map<String, dynamic> event, {
    bool allowUserStartFromDelta = false,
  }) {
    final updates = _normalizer.accept(
      event,
      allowUserStartFromDelta: allowUserStartFromDelta,
    );
    for (final update in updates) {
      if (_closed) break;
      if (update is TurnStartedUpdate &&
          update.role == ConversationRole.assistant) {
        _businessResponse = update.responseId;
      }
      callbacks.emitConversation(update, _channel!);
    }
    return updates;
  }

  void _finishResponse(Map<String, dynamic> event) {
    final response = event['response'];
    if (response is! Map ||
        _providerResponse == null ||
        response['id'] != _providerResponse ||
        _responseDone ||
        !(_draining
                ? ['completed', 'cancelled', 'failed', 'incomplete']
                : _interrupting
                ? ['completed', 'cancelled']
                : ['completed'])
            .contains(response['status'])) {
      throw const FormatException();
    }
    _responseDone = true;
  }

  @override
  void beginDrain() {
    if (_closed || _draining) return;
    _draining = true;
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _normalizer.dispose();
    _seenUsers.clear();
    _seenResponses.clear();
    _channel = null;
    _previousUserItem = null;
    _userItem = null;
    _providerResponse = null;
    _providerItem = null;
    _businessResponse = null;
  }
}
