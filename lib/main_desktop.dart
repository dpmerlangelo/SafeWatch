import 'dart:convert' show jsonDecode;
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'constants/app_theme.dart';
import 'constants/supabase_constants.dart';
import 'controllers/theme_controller.dart';
import 'screens_desktop/auth/auth_gate.dart';
import 'screens_desktop/auth/login_screen.dart';
import 'widgets/desktop_shell.dart';
import 'services/pa_audio_service.dart';

// Adjust to wherever CctvLiveScreen / AuxiliaryDisplayApp live.
import 'screens_desktop/command_center/cctv_live_screen.dart';

bool get _isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------------- Auxiliary window (separate process) ----------------
  if (args.length >= 2 && args.first == '--aux') {
    final file = File(args[1]);
    final payload =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    try {
      await file.delete();
    } catch (_) {}

    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();

    runApp(AuxiliaryDisplayApp(args: payload));
    return;
  }

  // ---------------- Normal main-window startup ----------------
  await Supabase.initialize(
    url: SupabaseConstants.url,
    anonKey: SupabaseConstants.anonKey,
  );

  final currentSession = Supabase.instance.client.auth.currentSession;
  if (currentSession != null) {
    try {
      await Supabase.instance.client.auth
          .setSession(currentSession.refreshToken!);
    } catch (_) {
      await Supabase.instance.client.auth.signOut();
    }
  }

  MediaKit.ensureInitialized();
   await PaAudioService.instance.init();

  if (_isDesktopPlatform) {
    await windowManager.ensureInitialized();
    // Lets us close aux windows when the main window closes.
    await windowManager.setPreventClose(true);
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (_isDesktopPlatform) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (_isDesktopPlatform) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    closeAllAuxWindows(); // defined in cctv_live_screen.dart
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeController,
      builder: (context, _) {
        return MaterialApp(
          title: 'SafeWatch',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeController.mode,
          home: const AuthGate(),
          routes: {
            '/login': (context) => const LoginScreen(),
            '/dashboard': (context) => const DesktopShell(),
          },
          builder: (context, child) {
            return AnimatedTheme(
              data: Theme.of(context),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              child: child!,
            );
          },
        );
      },
    );
  }
}