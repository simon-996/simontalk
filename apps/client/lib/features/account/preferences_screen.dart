import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/account_components.dart';
import 'account_controller.dart';
import 'account_models.dart';

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

  Future<void> _save() async {
    final success = await ref
        .read(accountControllerProvider.notifier)
        .save(_draft!);
    if (mounted && success && !widget.onboarding) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('练习偏好已保存。')));
    }
  }

  Future<void> _logout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出当前账号？'),
        content: Text(
          _dirty ? '尚未保存的设置将丢失。已保存的偏好会在下次登录时恢复。' : '已保存的偏好会在下次登录时恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续使用'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await ref.read(accountControllerProvider.notifier).logout();
    }
  }

  bool get _dirty {
    final saved = ref.read(accountControllerProvider).session?.preferences;
    return saved != null && _draft != null && !_draft!.sameValues(saved);
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
    final colors = Theme.of(context).colorScheme;
    return AccountFrame(
      wide: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PageIntro(
            title: widget.onboarding ? '找到适合你的节奏' : '练习偏好',
            description: widget.onboarding
                ? '先选择一个舒服的起点。没有测试，也不用追求“选得准”，之后随时可以调整。'
                : '${session.user.displayName}，让每次交流更适合你。',
          ),
          if (state.error != null) StatusMessage(state.error!),
          Text('对话难度', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '这会影响话题和表达的复杂度，不代表能力评定。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          for (final difficulty in Difficulty.values) ...[
            _DifficultyChoice(
              value: difficulty,
              selected: draft.difficulty == difficulty,
              enabled: !state.busy,
              onTap: () => setState(
                () => _draft = draft.copyWith(difficulty: difficulty),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (!widget.onboarding) ...[
            const Divider(),
            Text('交流节奏', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              activeTrackColor: colors.primary,
              contentPadding: EdgeInsets.zero,
              title: const Text('语速放慢一点'),
              subtitle: const Text('开启后，AI 会以更舒缓的速度表达。'),
              value: draft.speechPace == 'slow',
              onChanged: state.busy
                  ? null
                  : (value) => setState(
                      () => _draft = draft.copyWith(
                        speechPace: value ? 'slow' : 'normal',
                      ),
                    ),
            ),
            const Divider(),
            Text('显示与辅助', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              activeTrackColor: colors.primary,
              contentPadding: EdgeInsets.zero,
              title: const Text('默认显示英文字幕'),
              subtitle: const Text('控制新对话的字幕初始状态。'),
              value: draft.subtitleDefault,
              onChanged: state.busy
                  ? null
                  : (value) => setState(
                      () => _draft = draft.copyWith(subtitleDefault: value),
                    ),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              activeTrackColor: colors.primary,
              contentPadding: EdgeInsets.zero,
              title: const Text('允许中文表达提示'),
              subtitle: const Text('需要帮助时，提供中文思路和英文开头。'),
              value: draft.chineseHintsEnabled,
              onChanged: state.busy
                  ? null
                  : (value) => setState(
                      () => _draft = draft.copyWith(chineseHintsEnabled: value),
                    ),
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
            onPressed: draft.difficulty != null && _dirty ? _save : null,
          ),
          if (!widget.onboarding && _dirty) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: state.busy
                  ? null
                  : () => setState(() => _draft = session.preferences),
              child: const Text('放弃修改'),
            ),
          ],
          const Divider(),
          Text(
            '账号 · ${session.user.username}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: state.busy ? null : _logout,
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
    required this.onTap,
  });
  final Difficulty value;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colors.surfaceContainerLow : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: selected ? colors.primary : colors.outline,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value.label,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        value.description,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
