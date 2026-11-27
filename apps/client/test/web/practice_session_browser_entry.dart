// Isolated Web entrypoint mounting the real SimonTalkApp with opt-in WebSocket media.
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simontalk_client/app.dart';
import 'package:simontalk_client/core/app_fonts.dart';
import 'package:simontalk_client/features/realtime/browser_media_session_factory.dart';
import 'package:simontalk_client/features/realtime/practice_media_providers.dart';
import 'package:simontalk_client/features/realtime/qwen_server_media_protocol.dart';

@JS('window.simontalkSessionTest')
external set _sessionTest(_SessionTestApi value);

extension type _SessionTestApi._(JSObject _) implements JSObject {
  external factory _SessionTestApi({
    JSFunction texts,
    JSFunction tap,
    JSFunction popRoute,
  });
}

void _visitVisible(Element element, void Function(Element) visitor) {
  final widget = element.widget;
  if (widget is Offstage && widget.offstage) return;
  if (widget is TickerMode && !widget.enabled) return;
  visitor(element);
  element.visitChildren((child) => _visitVisible(child, visitor));
}

String? _textValue(Widget widget) {
  if (widget is Text) {
    return widget.data ?? widget.textSpan?.toPlainText();
  }
  if (widget is SelectableText) {
    return widget.data ?? widget.textSpan?.toPlainText();
  }
  return null;
}

List<String> _visibleTexts() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return const [];
  final out = <String>[];
  _visitVisible(root, (element) {
    final text = _textValue(element.widget);
    if (text != null && text.isNotEmpty) out.add(text);
  });
  return out;
}

bool _tapVisibleButton(String label) {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return false;
  VoidCallback? target;
  _visitVisible(root, (element) {
    if (target != null) return;
    final widget = element.widget;
    if (widget is ButtonStyleButton && widget.onPressed != null) {
      final labels = <String>[];
      _visitVisible(element, (child) {
        final text = _textValue(child.widget);
        if (text != null && text.isNotEmpty) labels.add(text);
      });
      if (labels.contains(label)) {
        target = widget.onPressed;
      }
    } else if (widget is ChoiceChip && widget.onSelected != null) {
      final labels = <String>[];
      _visitVisible(element, (child) {
        final text = _textValue(child.widget);
        if (text != null && text.isNotEmpty) labels.add(text);
      });
      if (labels.contains(label)) {
        target = () => widget.onSelected!(true);
      }
    }
  });
  if (target == null) return false;
  target!();
  WidgetsBinding.instance.scheduleFrame();
  return true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await loadAppFonts();
  } catch (_) {
    reportStartupFailure();
    return;
  }
  _sessionTest = _SessionTestApi(
    texts: (() => jsonEncode(_visibleTexts()).toJS).toJS,
    tap: ((JSString label) => _tapVisibleButton(label.toDart).toJS).toJS,
    popRoute: (() {
      WidgetsBinding.instance.handlePopRoute();
      WidgetsBinding.instance.scheduleFrame();
    }).toJS,
  );
  runApp(
    ProviderScope(
      overrides: [
        realtimeMediaSessionCreatorProvider.overrideWithValue(
          createBrowserMediaSession,
        ),
        realtimeProtocolFactoryProvider.overrideWithValue(
          QwenServerMediaProtocol.new,
        ),
      ],
      child: const SimonTalkApp(),
    ),
  );
}
