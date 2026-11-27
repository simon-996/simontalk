import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../audio_check/microphone_check_panel.dart';
import '../practice/practice_recovery_panel.dart';
import '../usage/usage_panel.dart';
import 'account_controller.dart';
import 'account_models.dart';

typedef _CanAct = bool Function({BuildContext? dialog, bool checkValues});

class PreferencesScreen extends ConsumerStatefulWidget {
  const PreferencesScreen({super.key, this.onboarding = false});
  final bool onboarding;
  @override
  ConsumerState<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends ConsumerState<PreferencesScreen> {
  AccountPreferences? _draft;
  int? _version;
  String? _userId;

  Future<void> _save(
    AccountPreferences draft,
    AccountController controller,
    _CanAct canAct,
  ) async {
    if (!canAct() || !_dirty || draft.difficulty == null) return;
    final success = await controller.save(draft);
    if (mounted &&
        success &&
        !widget.onboarding &&
        canAct(checkValues: false)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('练习偏好已保存。')));
    }
  }

  Future<bool> _confirm({
    required _CanAct canAct,
    required String title,
    required String description,
    required String keep,
    required String confirm,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) {
          void finish(bool approved) {
            if (!dialog.mounted || ModalRoute.of(dialog)?.isCurrent != true) {
              return;
            }
            Navigator.pop(dialog, approved && canAct(dialog: dialog));
          }

          return AlertDialog(
            title: Text(title),
            content: Text(description),
            actions: [
              TextButton(onPressed: () => finish(false), child: Text(keep)),
              TextButton(onPressed: () => finish(true), child: Text(confirm)),
            ],
          );
        },
      ) ==
      true;

  Future<void> _logout(AccountController controller, _CanAct canAct) async {
    if (!canAct()) return;
    final yes = await _confirm(
      canAct: canAct,
      title: '退出当前账号？',
      description: _dirty ? '尚未保存的设置将丢失。已保存的偏好会在下次登录时恢复。' : '已保存的偏好会在下次登录时恢复。',
      keep: '继续使用',
      confirm: '退出登录',
    );
    if (yes && canAct()) await controller.logout();
  }

  bool get _dirty {
    final saved = ref.read(accountControllerProvider).session?.preferences;
    return saved != null && _draft != null && !_draft!.sameValues(saved);
  }

  Future<void> _backToPractice(_CanAct canAct) async {
    if (!canAct()) return;
    if (_dirty) {
      final discard = await _confirm(
        canAct: canAct,
        title: '放弃未保存的修改？',
        description: '返回练习后，仍会使用上次已保存的设置。',
        keep: '继续编辑',
        confirm: '放弃并返回',
      );
      if (!discard) return;
    }
    if (mounted && canAct()) context.go('/practice');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(accountControllerProvider);
    final session = state.session;
    if (session == null) return const SizedBox.shrink();
    if (_version != session.preferences.version || _userId != session.user.id) {
      _userId = session.user.id;
      _version = session.preferences.version;
      _draft = session.preferences;
    }
    final draft = _draft!;
    final controller = ref.read(accountControllerProvider.notifier);
    final repository = ref.read(accountRepositoryProvider);
    final path = widget.onboarding ? '/setup' : '/account';
    bool canAct({BuildContext? dialog, bool checkValues = true}) {
      if (!mounted ||
          (dialog == null
              ? ModalRoute.of(context)?.isCurrent != true
              : !dialog.mounted ||
                    ModalRoute.of(dialog)?.isCurrent != true ||
                    ModalRoute.of(context)?.isActive != true) ||
          GoRouter.of(context).routeInformationProvider.value.uri.path !=
              path) {
        return false;
      }
      final current = ref.read(accountControllerProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == session.user.id &&
          repository.api.hasCurrentAccount(session.user.id) &&
          identical(ref.read(accountControllerProvider.notifier), controller) &&
          identical(ref.read(accountRepositoryProvider), repository) &&
          (!checkValues ||
              identical(current.session?.preferences, session.preferences) &&
                  identical(_draft, draft));
    }

    final colors = Theme.of(context).colorScheme;
    return AccountFrame(
      wide: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.onboarding) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: state.busy ? null : () => _backToPractice(canAct),
                child: const Text('返回练习'),
              ),
            ),
            const SizedBox(height: 16),
          ],
          PageIntro(
            title: widget.onboarding ? '找到适合你的节奏' : '练习偏好',
            description: widget.onboarding
                ? '先选择一个舒服的起点。没有测试，也不用追求“选得准”，之后随时可以调整。'
                : '${session.user.displayName}，让每次交流更适合你。',
          ),
          if (state.error != null) StatusMessage(state.error!),
          const SectionHeading('对话难度'),
          const SizedBox(height: 8),
          Text(
            '这会影响话题和表达的复杂度，不代表能力评定。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          RadioGroup<Difficulty>(
            groupValue: draft.difficulty,
            onChanged: (value) {
              if (!canAct() || value == null) return;
              setState(() => _draft = draft.copyWith(difficulty: value));
            },
            child: Column(
              children: [
                for (final difficulty in Difficulty.values) ...[
                  _DifficultyChoice(
                    value: difficulty,
                    selected: draft.difficulty == difficulty,
                    enabled: !state.busy,
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
          if (!widget.onboarding) ...[
            const Divider(),
            const SectionHeading('交流节奏'),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              activeTrackColor: colors.primary,
              contentPadding: EdgeInsets.zero,
              title: const Text('语速放慢一点'),
              subtitle: const Text('开启后，AI 会以更舒缓的速度表达。'),
              value: draft.speechPace == 'slow',
              onChanged: state.busy
                  ? null
                  : (value) {
                      if (!canAct()) return;
                      setState(
                        () => _draft = draft.copyWith(
                          speechPace: value ? 'slow' : 'normal',
                        ),
                      );
                    },
            ),
            const Divider(),
            const SectionHeading('显示与辅助'),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              activeTrackColor: colors.primary,
              contentPadding: EdgeInsets.zero,
              title: const Text('默认显示英文字幕'),
              subtitle: const Text('控制新对话的字幕初始状态。'),
              value: draft.subtitleDefault,
              onChanged: state.busy
                  ? null
                  : (value) {
                      if (!canAct()) return;
                      setState(
                        () => _draft = draft.copyWith(subtitleDefault: value),
                      );
                    },
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              activeTrackColor: colors.primary,
              contentPadding: EdgeInsets.zero,
              title: const Text('允许中文表达提示'),
              subtitle: const Text('为新对话显示简短的中文开口提示，可在通话中单独关闭。'),
              value: draft.chineseHintsEnabled,
              onChanged: state.busy
                  ? null
                  : (value) {
                      if (!canAct()) return;
                      setState(
                        () =>
                            _draft = draft.copyWith(chineseHintsEnabled: value),
                      );
                    },
            ),
            const SizedBox(height: 16),
            Text(
              '中文翻译按需查看，与字幕和表达提示分别控制。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(),
          ] else
            const SizedBox(height: 20),
          if (_dirty && !widget.onboarding)
            Text('有尚未保存的修改', style: TextStyle(color: colors.onSurfaceVariant)),
          const SizedBox(height: 16),
          PrimaryAction(
            label: widget.onboarding ? '保存并继续' : '保存设置',
            busy: state.busy,
            onPressed: !state.busy && draft.difficulty != null && _dirty
                ? () => _save(draft, controller, canAct)
                : null,
          ),
          if (!widget.onboarding && _dirty) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: state.busy
                  ? null
                  : () {
                      if (canAct()) {
                        setState(() => _draft = session.preferences);
                      }
                    },
              child: const Text('放弃修改'),
            ),
          ],
          const Divider(),
          if (!widget.onboarding) ...[
            AccountUsagePanel(key: ValueKey('usage-${session.user.id}')),
            const SizedBox(height: 24),
            PracticeRecoveryPanel(key: ValueKey('recovery-${session.user.id}')),
            const SizedBox(height: 24),
          ],
          if (kIsWeb && !widget.onboarding) ...[
            MicrophoneCheckPanel(
              key: ValueKey('microphone-${session.user.id}'),
            ),
            const SizedBox(height: 24),
          ],
          Text(
            '账号 · ${session.user.username}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: state.busy ? null : () => _logout(controller, canAct),
              child: const Text('退出登录'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DifficultyChoice extends StatelessWidget {
  const _DifficultyChoice({
    required this.value,
    required this.selected,
    required this.enabled,
  });
  final Difficulty value;
  final bool selected;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.surfaceContainerLow : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected ? colors.primary : colors.outline,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: RadioListTile<Difficulty>(
        value: value,
        enabled: enabled,
        selected: selected,
        activeColor: colors.primary,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        title: Text(value.label, style: Theme.of(context).textTheme.labelLarge),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            value.description,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}
