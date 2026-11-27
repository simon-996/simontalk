import 'dart:async';

import 'package:flutter/widgets.dart';

import '../account/account_models.dart';
import 'practice_preparation_controller.dart';
import 'practice_recovery_controller.dart';

/// Owns the explicit current-check → never-started preparation flow. No media.
class PracticeEntryController extends ChangeNotifier
    with WidgetsBindingObserver {
  PracticeEntryController({required this.recovery, required this.preparation}) {
    recovery.addListener(_changed);
    preparation.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  final PracticeRecoveryController recovery;
  final PracticePreparationController preparation;
  bool _checking = false;
  bool _stopped = false;
  bool _disposed = false;
  int _generation = 0;
  Difficulty? _requestedDifficulty;

  /// The clicked request remains stable; known server configuration wins.
  Difficulty? get preparationDifficulty {
    if (_disposed || !preparation.repository.hasCurrentAccount) return null;
    return preparation.practice?.configuration.effectiveDifficulty ??
        _requestedDifficulty;
  }

  bool get busy =>
      _checking ||
      recovery.busy ||
      [
        PreparationPhase.preparing,
        PreparationPhase.releasing,
      ].contains(preparation.phase);
  bool get canStart =>
      !_disposed &&
      !_stopped &&
      !busy &&
      preparation.repository.hasCurrentAccount &&
      preparation.phase == PreparationPhase.idle &&
      recovery.errorCode == null &&
      recovery.recovery?.practice == null;
  bool get canRetry =>
      !_disposed &&
      !busy &&
      preparation.repository.hasCurrentAccount &&
      preparation.phase == PreparationPhase.uncertain;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> begin(Difficulty difficulty, {VoidCallback? onAvailable}) async {
    if (!canStart) return;
    final generation = ++_generation;
    _requestedDifficulty = difficulty;
    _checking = true;
    _changed();
    try {
      await recovery.refresh();
      if (_disposed ||
          _stopped ||
          generation != _generation ||
          !preparation.repository.hasCurrentAccount ||
          recovery.errorCode != null ||
          recovery.recovery == null ||
          recovery.recovery!.practice != null) {
        return;
      }
      if (onAvailable == null) {
        await preparation.begin(difficulty: difficulty);
      } else {
        onAvailable();
      }
    } finally {
      if (!_disposed && generation == _generation) {
        if (preparation.phase == PreparationPhase.idle) {
          _requestedDifficulty = null;
        }
        _checking = false;
        _changed();
      }
    }
  }

  /// Explicit read only. Never resumes the start action after the read.
  Future<void> refresh() async {
    if (_disposed || busy) return;
    await recovery.refresh();
  }

  Future<void> retry() async {
    if (canRetry) await preparation.retry();
  }

  Future<void> cancel() async {
    if (_disposed) return;
    _stopped = true;
    _checking = false;
    _generation++;
    _changed();
    await preparation.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(cancel());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    recovery.removeListener(_changed);
    preparation.removeListener(_changed);
    recovery.dispose();
    preparation.dispose();
    super.dispose();
  }
}
