import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import '../../core/random_uuid.dart';
import '../conversation/conversation_models.dart';
import '../practice/practice_models.dart';

/// One explicit action and its recoverable request within the current call.
class SessionAssistance extends ChangeNotifier {
  SessionAssistance({
    required this.api,
    required this.accountId,
    required this.connection,
    required this.stillCurrent,
    this.sourceTurn,
  });

  final ApiClient api;
  final String accountId;
  final ConnectionReservation connection;
  final ConversationTurn? sourceTurn;
  final bool Function() stillCurrent;
  final _hash = RegExp(r'^[0-9a-f]{64}$');

  String get _path =>
      '/v1/practice-sessions/${connection.sessionId}/assistance';
  bool _disposed = false;
  bool _needsConfirmation = false;
  bool _retryable = false;
  String? _job, _key;
  String? _postPath;
  Map<String, Object>? _body;
  int _attempt = 0;

  bool busy = false;
  String? message;
  String? result;

  bool get _isTranslation => sourceTurn != null;
  String get heading => _isTranslation ? '中文翻译' : '英文开头';
  String get _kind => _isTranslation ? 'translation' : 'english_starter';
  String get _waiting => _isTranslation ? '正在翻译…' : '正在准备英文开头…';

  bool get _current => !_disposed && stillCurrent();
  bool get canStartOver =>
      !busy && _job == null && !_needsConfirmation && message != null;
  String? get actionLabel => busy
      ? null
      : _needsConfirmation
      ? '确认原请求'
      : _retryable
      ? '重试生成'
      : null;

  void _verifyScope(Map<String, dynamic> value) {
    final selected = sourceTurn;
    if (value['kind'] != _kind ||
        value['account_id'] != accountId ||
        value['session_id'] != connection.sessionId ||
        value['connection_id'] != connection.id ||
        value['epoch'] != connection.epoch ||
        (selected != null &&
            (value['source_turn_id'] != selected.turnId ||
                value['source_turn_revision'] != selected.revision))) {
      throw const FormatException();
    }
  }

  Future<Map<String, dynamic>> _request(String method, String path) =>
      api.request(
        method,
        path,
        accountId: accountId,
        idempotencyKey: method == 'POST' ? _key : null,
        body: method == 'POST' ? _body : null,
        stillCurrent: () => _current,
        maxResponseBytes: 4096,
      );

  Future<void> start() => _run(() async {
    final selected = sourceTurn;
    final parameters = Uri(
      queryParameters: {
        'connection_id': connection.id,
        'epoch': '${connection.epoch}',
        'kind': _kind,
        if (selected != null) ...{
          'source_turn_id': selected.turnId,
          'source_turn_revision': '${selected.revision}',
        },
      },
    ).query;
    final context = await _request('GET', '$_path/context?$parameters');
    _verifyScope(context);
    final revision = context['input_revision'];
    final existing = context['job_id'];
    if (revision is! String ||
        !_hash.hasMatch(revision) ||
        context['can_generate'] is! bool ||
        (existing != null &&
            (existing is! String || !isPracticeUuid(existing)))) {
      throw const FormatException();
    }
    if (existing == null && context['can_generate'] == false) {
      throw ApiException('assistance_unavailable', '$heading服务暂不可用。');
    }
    _body = {
      'connection_id': connection.id,
      'epoch': connection.epoch,
      'input_revision': revision,
      'kind': _kind,
      if (selected != null) ...{
        'source_turn_id': selected.turnId,
        'source_turn_revision': selected.revision,
      },
    };
    if (existing case final String jobId) {
      _job = jobId;
      if (!_accept(await _request('GET', '$_path/$jobId'))) await _confirm();
      return;
    }
    _postPath = _path;
    _key = randomUuid();
    await _confirm();
  });

  Future<void> performAction() {
    if (_needsConfirmation) return _run(_confirm);
    if (!_retryable || _job == null || _body == null) return Future.value();
    return _run(() async {
      _retryable = false;
      _postPath = '$_path/$_job/retry';
      _body = {..._body!, 'attempt_count': _attempt};
      _key = randomUuid();
      await _confirm();
    });
  }

  Future<void> revalidateResult() =>
      result != null && _job != null ? _run(_confirm) : Future.value();

  bool _accept(Map<String, dynamic> value) {
    _verifyScope(value);
    final id = value['id'];
    final attempt = value['attempt_count'];
    final state = value['status'];
    final text = value[_isTranslation ? 'translation' : 'starter'];
    final canRetry = value['can_retry'];
    if (id is! String ||
        !isPracticeUuid(id) ||
        (_job != null && id != _job) ||
        value['input_revision'] != _body?['input_revision'] ||
        attempt is! int ||
        attempt < 0 ||
        attempt > 2 ||
        canRetry is! bool ||
        (canRetry && (state != 'failed' || attempt == 2)) ||
        (state == 'succeeded' && !_validText(text)) ||
        (state != 'succeeded' && text != null) ||
        ![
          'queued',
          'running',
          'succeeded',
          'failed',
          'unknown',
          'expired',
        ].contains(state)) {
      throw const FormatException();
    }
    _attempt = attempt;
    _job = id;
    _retryable = canRetry;
    result = text as String?;
    message = switch (state) {
      'queued' || 'running' => _waiting,
      'failed' => '这次没有生成可用提示。',
      'unknown' => '生成结果尚未确认。',
      'expired' => '这次提示已过期。',
      _ => null,
    };
    return state != 'queued' && state != 'running';
  }

  bool _validText(Object? text) =>
      text is String &&
      text.trim() == text &&
      text.runes.length <= (_isTranslation ? 240 : 160) &&
      !RegExp(r'[<>\x00-\x1f\x7f]').hasMatch(text) &&
      (_isTranslation ? RegExp(r'[\u3400-\u9fff]') : RegExp(r'[A-Za-z]{2}'))
          .hasMatch(text);

  Future<void> _confirm() async {
    if (_postPath case final path?) {
      final value = await _request('POST', path);
      final done = _accept(value);
      _postPath = null;
      if (done) return;
    }
    final clock = Stopwatch()..start();
    while (_current &&
        _job != null &&
        clock.elapsed < const Duration(seconds: 16)) {
      await Future<void>.delayed(const Duration(milliseconds: 550));
      if (!_current) return;
      if (_accept(await _request('GET', '$_path/$_job'))) return;
    }
    if (_current) {
      _needsConfirmation = true;
      message = '提示还在准备，可再次确认这次请求。';
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (busy || !_current) return;
    busy = true;
    result = null;
    message = _waiting;
    _needsConfirmation = false;
    notifyListeners();
    try {
      await operation();
    } on Object catch (error) {
      if (!_current) return;
      final code = error is ApiException ? error.code : 'invalid_response';
      _needsConfirmation =
          (_job != null || _postPath != null) &&
          [
            'network_error',
            'service_unavailable',
            'invalid_response',
          ].contains(code);
      message = switch (code) {
        'assistance_unavailable' => '$heading服务暂不可用。',
        'invalid_assistance_selection' => '这条话轮无法翻译，请重新选择。',
        'assistance_context_changed' ||
        'assistance_context_unavailable' => '当前通话内容已变化，请关闭后重新求助。',
        _ when _needsConfirmation => '暂时无法确认提示结果。',
        _ => '暂时无法取得提示，请关闭后重试。',
      };
    } finally {
      busy = false;
      if (_current) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
