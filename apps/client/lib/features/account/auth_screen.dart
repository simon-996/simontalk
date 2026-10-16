import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import 'account_controller.dart';

enum AuthMode { login, register, reset }

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, required this.mode});
  final AuthMode mode;
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _invite = TextEditingController();
  final _displayName = TextEditingController();
  bool _showPassword = false;

  @override
  void dispose() {
    for (final controller in [
      _username,
      _password,
      _confirm,
      _invite,
      _displayName,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final controller = ref.read(accountControllerProvider.notifier);
    final mode = widget.mode;
    final success = switch (mode) {
      AuthMode.login => await controller.authenticate(
        (repo) => repo.login(_username.text, _password.text),
      ),
      AuthMode.register => await controller.authenticate(
        (repo) => repo.register(
          inviteCode: _invite.text,
          username: _username.text,
          password: _password.text,
          displayName: _displayName.text,
        ),
      ),
      AuthMode.reset => await controller.resetPassword(
        _invite.text,
        _password.text,
      ),
    };
    if (!mounted || !success) return;
    _password.clear();
    _confirm.clear();
    _invite.clear();
    if (mode == AuthMode.reset) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码已更新，请使用新密码登录。')));
      context.go('/login');
    }
  }

  void _navigate(String path) {
    ref.read(accountControllerProvider.notifier).clearError();
    context.go(path);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(accountControllerProvider);
    final register = widget.mode == AuthMode.register;
    final reset = widget.mode == AuthMode.reset;
    final title = reset
        ? '重新设置密码'
        : register
        ? '开启你的英语日常'
        : '欢迎回来';
    final description = reset
        ? '向维护者获取一次性重设凭证，即可设置新密码。'
        : register
        ? '使用朋友分享的邀请码，创建自己的练习账号。'
        : '登录 SimonTalk，保持自己的练习节奏。';
    return AccountFrame(
      child: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              PageIntro(title: title, description: description),
              if (state.error != null) StatusMessage(state.error!),
              if (register || reset) ...[
                _field(
                  controller: _invite,
                  label: reset ? '重设凭证' : '邀请码',
                  busy: state.busy,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? (reset ? '请输入重设凭证' : '请输入邀请码')
                      : null,
                ),
                const SizedBox(height: 24),
              ],
              if (register) ...[
                _field(
                  controller: _displayName,
                  label: '怎么称呼你',
                  busy: state.busy,
                  autofillHints: const [AutofillHints.nickname],
                  validator: (value) =>
                      value == null ||
                          value.trim().isEmpty ||
                          value.trim().length > 60
                      ? '请输入 1–60 个字符的称呼'
                      : null,
                ),
                const SizedBox(height: 24),
              ],
              if (!reset) ...[
                _field(
                  controller: _username,
                  label: '用户名',
                  busy: state.busy,
                  autofillHints: const [AutofillHints.username],
                  helper: register ? '3–32 位，以英文字母开头，可用字母、数字和下划线。' : null,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) return '请输入用户名';
                    if (register &&
                        !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,31}$')
                            .hasMatch(value.trim())) {
                      return '请按说明填写用户名';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),
              ],
              TextFormField(
                controller: _password,
                enabled: !state.busy,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: [
                  register || reset
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                textInputAction: register || reset
                    ? TextInputAction.next
                    : TextInputAction.done,
                onFieldSubmitted: (_) {
                  if (!register && !reset) _submit();
                },
                decoration: InputDecoration(
                  labelText: reset ? '新密码' : '密码',
                  helperText: register || reset
                      ? '12–128 个字符，建议使用密码管理器生成。'
                      : null,
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? '隐藏密码' : '显示密码',
                    onPressed: state.busy
                        ? null
                        : () => setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) return '请输入密码';
                  if ((register || reset) &&
                      (value.length < 12 || value.length > 128)) {
                    return '密码需要 12–128 个字符';
                  }
                  return null;
                },
              ),
              if (register || reset) ...[
                const SizedBox(height: 24),
                TextFormField(
                  controller: _confirm,
                  enabled: !state.busy,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: '再次输入密码'),
                  validator: (value) =>
                      value != _password.text || value == null || value.isEmpty
                      ? '两次输入的密码需要一致'
                      : null,
                ),
              ],
              const SizedBox(height: 32),
              PrimaryAction(
                label: reset
                    ? '更新密码'
                    : register
                    ? '创建账号'
                    : '登录',
                busy: state.busy,
                onPressed: _submit,
              ),
              const SizedBox(height: 16),
              if (!register && !reset) ...[
                TextButton(
                  onPressed: state.busy ? null : () => _navigate('/join'),
                  child: const Text('邀请码注册'),
                ),
                TextButton(
                  onPressed: state.busy ? null : () => _navigate('/reset'),
                  child: const Text('忘记密码'),
                ),
              ] else
                TextButton(
                  onPressed: state.busy ? null : () => _navigate('/login'),
                  child: const Text('返回登录'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required bool busy,
    String? helper,
    Iterable<String>? autofillHints,
    required String? Function(String?) validator,
  }) => TextFormField(
    controller: controller,
    enabled: !busy,
    autocorrect: false,
    textInputAction: TextInputAction.next,
    autofillHints: autofillHints,
    decoration: InputDecoration(labelText: label, helperText: helper),
    validator: validator,
  );
}
