import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../practice/practice_completion_models.dart';
import '../practice/practice_models.dart';
import '../review/review_models.dart';
import 'saved_transcript_models.dart';
import 'saved_transcript_repository.dart';

enum SavedTranscriptState { idle, reading, ready, failed, unavailable, aborted }

/// An owner-bound, cancellable single flight. Initial two GETs share one deadline.
final class SavedTranscriptController extends ChangeNotifier {
  SavedTranscriptController({
    required ApiClient accountApi,
    required this.accountId,
    required this.sessionId,
    this.reviewItemId,
    http.Client Function()? httpClientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _factory = httpClientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();
  final ApiClient _source;
  final String accountId, sessionId;
  final String? reviewItemId;
  final http.Client Function() _factory;
  final Duration Function() _elapsed;
  static Duration Function() _clock() {
    final c = Stopwatch()..start();
    return () => c.elapsed;
  }

  bool _disposed = false, _aborted = false;
  SavedTranscriptState _state = SavedTranscriptState.idle;
  SavedTranscriptPage? _page;
  String? _error;
  Future<void>? _task;
  ApiClient? _active;
  void Function()? _cancel;
  bool _owns() {
    if (_disposed || _aborted) return false;
    if (_source.hasCurrentAccount(accountId)) return true;
    _error = 'account_changed';
    _abort();
    return false;
  }

  SavedTranscriptState get state {
    _owns();
    return _state;
  }

  SavedTranscriptPage? get page => _owns() ? _page : null;
  String? get errorCode {
    _owns();
    return _error;
  }

  bool get busy => _owns() && _task != null;
  Future<void> refresh() => _run(initial: true);
  Future<void> previous() => _step(forward: false);
  Future<void> next() => _step(forward: true);
  Future<void> _step({required bool forward}) {
    if (!_owns()) return Future.value();
    if (_task != null) return _task!;
    final offset = forward ? _page?.nextOffset : _page?.previousOffset;
    return offset == null ? Future.value() : _run(offset: offset);
  }

  Future<void> focus() => !_owns()
      ? Future.value()
      : _task ?? (reviewItemId == null ? Future.value() : _run());
  Future<void> _run({bool initial = false, int? offset}) {
    if (!_owns()) return Future.value();
    if (_task != null) return _task!;
    if (!isPracticeUuid(accountId) ||
        !isPracticeUuid(sessionId) ||
        (reviewItemId != null && !isPracticeUuid(reviewItemId!))) {
      _page = null;
      _error = 'invalid_source';
      _state = SavedTranscriptState.unavailable;
      notifyListeners();
      return Future.value();
    }
    // A fresh source read removes accepted content synchronously, before I/O.
    final previous = initial ? null : _page;
    if (initial) _page = null;
    _error = null;
    _state = SavedTranscriptState.reading;
    final done = Completer<void>();
    _task = done.future;
    notifyListeners();
    unawaited(
      Future<void>.microtask(() async {
        try {
          if (!_owns()) return;
          final result = await _operation(
            initial: initial,
            offset: offset,
            previous: previous,
          );
          if (!_owns()) return;
          _page = result;
          _state = SavedTranscriptState.ready;
        } on Object catch (error) {
          if (!_owns()) return;
          final api = error is ApiException ? error : null;
          _error = api?.code ?? 'invalid_response';
          final transient =
              api?.statusCode != 401 &&
              api?.statusCode != 404 &&
              api?.statusCode != 409 &&
              {
                'network_error',
                'transcript_timeout',
                'service_unavailable',
                'rate_limited',
              }.contains(_error);
          _page = transient ? previous : null;
          if (api?.statusCode == 401 || _error == 'account_changed') {
            _error = api?.statusCode == 401
                ? 'unauthorized'
                : 'account_changed';
            _abort();
          } else {
            _state = transient
                ? SavedTranscriptState.failed
                : SavedTranscriptState.unavailable;
          }
        } finally {
          _task = null;
          if (!_disposed) notifyListeners();
          done.complete();
        }
      }),
    );
    return done.future;
  }

  Future<SavedTranscriptPage> _operation({
    required bool initial,
    required int? offset,
    required SavedTranscriptPage? previous,
  }) async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    var live = true;
    void check() {
      if (!live || !_owns()) throw const ApiException('cancelled', '读取已停止。');
      if (_elapsed() >= cutoff) {
        throw const ApiException('transcript_timeout', '文字读取超时。');
      }
    }

    ApiClient? api;
    Timer? timer;
    try {
      check();
      api = _source.forkForAccount(accountId: accountId, client: _factory());
      _active = api;
      final cancel = Completer<SavedTranscriptPage>();
      _cancel = () {
        if (!cancel.isCompleted) {
          cancel.completeError(const ApiException('cancelled', '读取已停止。'));
        }
      };
      final deadline = Completer<SavedTranscriptPage>();
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('transcript_timeout', '文字读取超时。'),
        ),
      );
      final repo = SavedTranscriptRepository(
        api,
        accountId: accountId,
        sessionId: sessionId,
      );
      final work = () async {
        check();
        ReviewTarget target;
        PracticeCompletionSummary? confirmed;
        if (initial || previous == null) {
          final completion = await repo.readCompletion();
          confirmed = completion;
          check();
          if (completion.status != PracticeCompletionStatus.sealed) {
            throw const ApiException('completion_not_sealed', '文字尚未封存。');
          }
          target = ReviewTarget.fromCompletion(completion);
        } else {
          target = previous.target;
        }
        check();
        final result = await repo.readPage(
          target,
          offset: offset,
          reviewItemId: reviewItemId,
        );
        check();
        if (confirmed != null &&
            (result.sealedAt != confirmed.sealedAt ||
                result.coverage != confirmed.coverage.name ||
                result.gapCodes.length != confirmed.gapCodes.length ||
                !result.gapCodes.toSet().containsAll(confirmed.gapCodes))) {
          throw const ApiException('saved_transcript_changed', '保存来源已变化。');
        }
        if (previous != null && !previous.hasSameAnchor(result)) {
          throw const ApiException('saved_transcript_changed', '保存来源已变化。');
        }
        return result;
      }();
      final result = await Future.any([work, cancel.future, deadline.future]);
      check();
      return result;
    } finally {
      live = false;
      timer?.cancel();
      _cancel = null;
      _active = null;
      api?.close();
    }
  }

  void _abort() {
    if (_aborted) return;
    _aborted = true;
    _page = null;
    _state = SavedTranscriptState.aborted;
    _cancel?.call();
    _active?.close();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _abort();
    super.dispose();
  }
}
