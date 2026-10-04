// lib/screens_mobile/auth_gate.dart
//
// Mobile build's root auth gate. Deliberately separate from
// screens_desktop/auth_gate.dart so the two platforms can never import
// each other's home screens.
//
// Behavior:
//   - No session               -> LoginScreen (mobile)
//   - Session + role tanod     -> MobileShell (Tanod screens)
//   - Session + role task force -> MobileShell (Task Force screens)
//   - Session + any other role -> signed out immediately and bounced
//     back to LoginScreen with an explanatory message. Non-mobile
//     roles (admin / cctv manager) are desktop-only and should never
//     end up inside the mobile app's home screen.
//
// CHANGED: Task Force used to be commented out here and, when it was
// enabled, pointed at a standalone `TaskForceHomeScreen()` route. That
// screen isn't a standalone route anymore — `MobileShell` now owns
// role-based branching (see `_pagesForRole` in widgets/mobile_shell.dart)
// and picks the Task Force screens (dispatch map + report history)
// itself once it resolves the role. So both eligible roles now go
// through the same `MobileShell()` widget; the role check here only
// decides *whether* this account is allowed on a mobile device at all.
//
// !! If your `users`/`profiles` table or role column is named
// differently, update the query inside _RoleRouter below. !!
import 'package:flutter/material.dart';
import 'package:safewatch/widgets/mobile_shell.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_screen.dart';

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
/// on this (mobile) device.
class _RoleRouter extends StatefulWidget {
  final String userId;
  const _RoleRouter({required this.userId});

  @override
  State<_RoleRouter> createState() => _RoleRouterState();
}

class _RoleRouterState extends State<_RoleRouter> {
  late final Future<String?> _roleFuture = _fetchRole();

  // Guards against calling signOut() more than once while the
  // onAuthStateChange stream catches up and rebuilds this subtree.
  bool _signOutTriggered = false;

  Future<String?> _fetchRole() async {
    try {
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
    // Defer to after the current build so we don't call setState-adjacent
    // work (auth state change) mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Supabase.instance.client.auth.signOut();
    });
  }

  /// True for any role this mobile build should let in. Matches
  /// `MobileShell._normalizeRole`'s matching (`contains('task')`)
  /// rather than an exact string, so 'Task Force', 'task force', and
  /// 'task_force' — however it's stored in `profiles.role` — all pass.
  /// Add Purok Leader here too once it has its own mobile screens
  /// wired into MobileShell's `_pagesForRole`.
  bool _isMobileEligible(String role) {
    return role == 'tanod' || role.contains('task') || role.contains('purok');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _roleFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _LoadingScaffold();
        }

        final role = snapshot.data?.trim().toLowerCase() ?? '';

        if (_isMobileEligible(role)) {
          // MobileShell resolves the exact role itself (again) to pick
          // nav items and pages — this check only gates entry.
          return const MobileShell();
        }

        // Wrong device for this role — sign out and show a brief
        // explanation. AuthGate's StreamBuilder will swap this out for
        // LoginScreen as soon as the sign-out completes.
        _rejectAndSignOut();
        return const _AccessDeniedScaffold(
          message:
              'This account is not set up for the mobile app.\n'
              'Please sign in from the desktop app instead.',
        );
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