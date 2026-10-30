import 'dart:convert';

import '../account/account_models.dart';
import '../conversation/conversation_models.dart';
import '../practice/practice_models.dart';
import 'qwen_transcript_normalizer.dart';
import 'realtime_session_protocol.dart';
import 'realtime_transport.dart';

/// A deliberately limited candidate. It does not establish safe interruption or
/// upstream termination and is not registered in the default provider.
final class QwenGuardedProtocol implements RealtimeSessionProtocol {
  QwenGuardedProtocol(this.configuration, this.callbacks) {
    final provider = configuration.provider;
    if (provider.provider != 'dashscope' ||
        provider.region != 'cn-beijing' ||
        provider.model != 'qwen3.8-omni-flash-realtime') {
      throw const RealtimeFailure('realtime_unavailable');
    }
  }

  final PracticeConfiguration configuration;
  final RealtimeProtocolCallbacks callbacks;
  final _normalizer = QwenTranscriptNormalizer();
  final _openChannels = <String>{};
  String? _channel;
  String? _sessionId;
  String? _userItem;
  String? _providerResponse;
  String? _businessResponse;
  bool _speechStopped = false;
  bool _inputCommitted = false;
  bool _configured = false;
  bool _replyRequested = false;
  bool _responseDone = false;
  bool _draining = false;
  bool _closed = false;
  bool _cancelSent = false;

  String get _instructions {
    final level = switch (configuration.effectiveDifficulty) {
      Difficulty.beginner => 'Use short, simple sentences and familiar words.',
      Difficulty.intermediate =>
        'Use natural everyday English and clear questions.',
      Difficulty.advanced =>
        'Use natural English with richer detail and discussion.',
    };
    final pace = configuration.preferences.speechPace == 'slow'
        ? 'Speak slowly and clearly.'
        : 'Speak at a natural conversational pace.';
    return 'You are a friendly English conversation partner. $level $pace '
        'Keep replies concise and invite the learner to speak.';
  }

  Map<String, Object?> get _settings => {
    'modalities': ['text', 'audio'],
    'max_tokens': 128,
    'enable_search': false,
    'voice': 'Tina',
    'instructions': _instructions,
    'input_audio_transcription': {'model': 'qwen3-asr-flash-realtime'},
    'turn_detection': {
      'type': 'server_vad',
      'threshold': 0.2,
      'silence_duration_ms': 600,
      'create_response': false,
      'interrupt_response': false,
    },
  };

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
    if (channelId.isEmpty ||
        channelId.length > 64 ||
        (!_openChannels.contains(channelId) && _openChannels.length >= 8)) {
      _fail();
      return;
    }
    _openChannels.add(channelId);
  }

  @override
  void receive(RealtimeTransportEvent event) {
    if (_closed) return;
    try {
      if (!_openChannels.contains(event.channelId) ||
          (_channel != null && event.channelId != _channel) ||
          event.json.length > 65536 ||
          utf8.encode(event.json).length > 65536) {
        throw const FormatException();
      }
      final decoded = jsonDecode(event.json);
      if (decoded is! Map<String, dynamic> || decoded['type'] is! String) {
        throw const FormatException();
      }
      if (_channel == null) {
        if (decoded['type'] != 'session.created') throw const FormatException();
        _channel = event.channelId;
      }
      _receive(decoded);
    } on Object {
      _fail();
    }
  }

  void _receive(Map<String, dynamic> event) {
    final type = event['type'] as String;
    if (type == 'error') throw const FormatException();
    if (type == 'session.created') {
      if (_sessionId != null || _configured || _draining) {
        throw const FormatException();
      }
      final session = event['session'];
      if (session is! Map || session['model'] != configuration.provider.model) {
        throw const FormatException();
      }
      _sessionId = _id(session['id']);
      callbacks.send(
        jsonEncode({'type': 'session.update', 'session': _settings}),
        _channel!,
      );
      return;
    }
    if (type == 'session.updated') {
      if (_sessionId == null || _configured || _draining) {
        throw const FormatException();
      }
      final session = event['session'];
      if (session is! Map ||
          session['id'] != _sessionId ||
          session['model'] != configuration.provider.model ||
          !_sameSettings(session)) {
        throw const FormatException();
      }
      _configured = true;
      callbacks.confirmConfigured(_channel!);
      return;
    }
    if (!_configured) throw const FormatException();
    if (_draining) {
      if (type == 'response.created') {
        final response = event['response'];
        // A new response was not in the frozen controller scope. It cannot be
        // safely published or cancelled through the frozen-response capability.
        if (_providerResponse == null ||
            response is! Map ||
            response['id'] != _providerResponse) {
          throw const FormatException();
        }
        return;
      }
      final sameUserItem = _userItem != null && event['item_id'] == _userItem;
      if (type == 'input_audio_buffer.speech_stopped' && sameUserItem) {
        _speechStopped = true;
      } else if (type == 'input_audio_buffer.committed' &&
          sameUserItem &&
          _speechStopped) {
        _inputCommitted = true;
      } else if (type ==
              'conversation.item.input_audio_transcription.completed' &&
          sameUserItem &&
          _speechStopped &&
          _inputCommitted) {
        _emit(event);
      } else if (type == 'response.audio_transcript.done' &&
          event['response_id'] == _providerResponse) {
        _emit(event);
      } else if (type == 'response.done') {
        _finishResponse(event);
      }
      return;
    }
    switch (type) {
      case 'input_audio_buffer.speech_started':
        final item = _id(event['item_id']);
        if (_replyRequested || (_userItem != null && _userItem != item)) {
          throw const FormatException();
        }
        _userItem = item;
        _emit(event);
      case 'input_audio_buffer.speech_stopped':
        if (_userItem == null ||
            event['item_id'] != _userItem ||
            _replyRequested) {
          throw const FormatException();
        }
        _speechStopped = true;
      case 'input_audio_buffer.committed':
        if (!_speechStopped ||
            event['item_id'] != _userItem ||
            _replyRequested) {
          throw const FormatException();
        }
        _inputCommitted = true;
      case 'conversation.item.input_audio_transcription.delta':
        if (_userItem == null ||
            event['item_id'] != _userItem ||
            _replyRequested) {
          throw const FormatException();
        }
        _emit(event);
      case 'conversation.item.input_audio_transcription.completed':
        if (!_speechStopped ||
            !_inputCommitted ||
            event['item_id'] != _userItem) {
          throw const FormatException();
        }
        final updates = _emit(event);
        if (_closed || _draining) return;
        if (updates.isNotEmpty && !_replyRequested) {
          final transcript = event['transcript'];
          if (transcript is! String || transcript.trim().isEmpty) {
            throw const FormatException();
          }
          _replyRequested = true;
          callbacks.send('{"type":"response.create"}', _channel!);
        }
      case 'response.created':
        final response = event['response'];
        if (!_replyRequested || response is! Map || _responseDone) {
          throw const FormatException();
        }
        final id = _id(response['id']);
        if (_providerResponse != null && _providerResponse != id) {
          throw const FormatException();
        }
        _providerResponse = id;
        _emit(event);
      case 'response.output_item.added':
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
        // These do not establish playback, context truncation or termination.
        break;
      default:
        throw const FormatException();
    }
  }

  bool _sameSettings(Map<dynamic, dynamic> session) {
    final required = _settings;
    final vad = session['turn_detection'];
    final expectedVad = required['turn_detection'] as Map;
    final transcription = session['input_audio_transcription'];
    final modalities = session['modalities'];
    final tools = session['tools'];
    return modalities is List &&
        modalities.length == 2 &&
        modalities.contains('text') &&
        modalities.contains('audio') &&
        session['max_tokens'] == required['max_tokens'] &&
        session['enable_search'] == false &&
        (!session.containsKey('tools') || (tools is List && tools.isEmpty)) &&
        session['voice'] == required['voice'] &&
        session['instructions'] == required['instructions'] &&
        transcription is Map &&
        transcription['model'] == 'qwen3-asr-flash-realtime' &&
        vad is Map &&
        expectedVad.entries.every((entry) => vad[entry.key] == entry.value);
  }

  List<ConversationUpdate> _emit(Map<String, dynamic> event) {
    final updates = _normalizer.accept(event);
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
        !(_draining
                ? ['completed', 'cancelled', 'failed', 'incomplete']
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
    final response = _businessResponse;
    if (!_responseDone &&
        response != null &&
        !_cancelSent &&
        _channel != null) {
      _cancelSent = true;
      callbacks.sendDrainControl(
        '{"type":"response.cancel"}',
        _channel!,
        RealtimeDrainControlKind.cancelResponse,
        response,
      );
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _normalizer.dispose();
    _openChannels.clear();
    _channel = null;
    _sessionId = null;
    _userItem = null;
    _providerResponse = null;
    _businessResponse = null;
  }
}
