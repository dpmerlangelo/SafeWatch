// lib/screens_desktop/auth_gate.dart
//
// Desktop build's root auth gate. Sits at root and reacts to auth state
// changes. Supabase persists the session automatically, so
// onAuthStateChange will immediately emit the still-signed-in user
// after a reload.
//
// After a session exists, we look up the user's role in the `profiles`
// table and route accordingly:
//   - 'tanod'         -> rejected here. Tanod accounts are mobile-only;
//                        they're signed out and bounced back to the
//                        desktop LoginScreen with an explanatory message.
//   - anything else   -> DashboardShell (admin / cctv manager, desktop)
//
// !! If your `users`/`profiles` table or role column is named
// differently, update the query inside _RoleRouter below. !!
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_screen.dart';
import '../../widgets/desktop_shell.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _LoadingScaffold();
        }

        final session = snapshot.data?.session;

        if (session == null) {
          return const LoginScreen();
        }

        return _RoleRouter(userId: session.user.id);
      },
    );
  }
}

/// Fetches the current user's role and decides whether they're allowed
/// on this (desktop) device.
class _RoleRouter extends StatefulWidget {
  final String userId;
  const _RoleRouter({required this.userId});

  @override
  State<_RoleRouter> createState() => _RoleRouterState();
}

class _RoleRouterState extends State<_RoleRouter> {
  late final Future<String?> _roleFuture = _fetchRole();
  bool _signOutTriggered = false;

  Future<String?> _fetchRole() async {
    try {
      // Matches DashboardShell._fetchAdminProfile(): role lives in the
      // 'profiles' table, keyed by the auth user id.
      final row = await Supabase.instance.client
          .from('profiles')
          .select('role')
          .eq('id', widget.userId)
          .maybeSingle();

      return row?['role'] as String?;
    } catch (e) {
      debugPrint('Failed to fetch user role: $e');
      return null;
    }
  }

  void _rejectAndSignOut() {
    if (_signOutTriggered) return;
    _signOutTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Supabase.instance.client.auth.signOut();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _roleFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _LoadingScaffold();
        }

        final role = snapshot.data?.trim().toLowerCase();

        // Mobile-only roles that should be rejected from the desktop dashboard
        const mobileOnlyRoles = {'tanod', 'purok leader', 'task force'};

        if (role != null && mobileOnlyRoles.contains(role)) {
          _rejectAndSignOut();
          return const _AccessDeniedScaffold(
            message:
                'This account is set up for the mobile app.\n'
                'Please sign in from the mobile app instead.',
          );
        }

        // Default: admin / cctv manager / desktop roles -> desktop shell.
        return const DesktopShell();
      },
    );
  }
}

class _LoadingScaffold extends StatelessWidget {
  const _LoadingScaffold();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF121316),
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFF2082E2)),
      ),
    );
  }
}

class _AccessDeniedScaffold extends StatelessWidget {
  final String message;
  const _AccessDeniedScaffold({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121316),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.block, color: Color(0xFFE53935), size: 36),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF8A8F9B), fontSize: 13.5, height: 1.5),
              ),
              const SizedBox(height: 20),
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2082E2)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}