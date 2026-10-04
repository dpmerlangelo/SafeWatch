// lib/main_mobile.dart
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'constants/app_theme.dart';
import 'constants/supabase_constants.dart';
import 'controllers/theme_controller.dart';
import 'screens_mobile/auth/auth_gate.dart';
import 'screens_mobile/auth/login_screen.dart';
import 'services/location_tracking_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: SupabaseConstants.url,
    anonKey: SupabaseConstants.anonKey,
  );

  final currentSession = Supabase.instance.client.auth.currentSession;
  if (currentSession != null) {
    try {
      await Supabase.instance.client.auth.setSession(currentSession.refreshToken!);
    } catch (_) {
      await Supabase.instance.client.auth.signOut();
    }
  }

  MediaKit.ensureInitialized();

  LocationTrackingService.instance.init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
          },
        );
      },
    );
  }
}