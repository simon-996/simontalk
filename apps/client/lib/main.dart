import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/app_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await loadAppFonts();
  } catch (_) {
    reportStartupFailure();
    return;
  }
  runApp(const ProviderScope(child: SimonTalkApp()));
}
