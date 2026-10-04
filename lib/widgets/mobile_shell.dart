import 'package:flutter/material.dart';
import 'package:safewatch/screens_mobile/profile_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/nav_item_mobile.dart';
import 'app_navbar.dart';
import 'app_topbar.dart';
import '../screens_mobile/tanod/home_screen.dart';
import '../screens_mobile/tanod/report_history_screen.dart';
import '../screens_mobile/task_force/home_screen.dart';
import '../screens_mobile/task_force/report_history_screen.dart';
import '../screens_mobile/purok_leader/home_screen.dart';
import '../screens_mobile/purok_leader/map_screen.dart';
import '../screens_mobile/purok_leader/report_history_screen.dart';
import '../services/dispatch_notification_service.dart';
import '../services/dispatch_route_notifier.dart';

// TODO: give Purok Leader its own independent report-history screen the
// same way Task Force has one (e.g. purok_leader_report_history_screen.dart)
// instead of falling back to the Tanod report history screen.

/// Mobile equivalent of DesktopShell.
///
/// Resolves the signed-in user's role (Tanod / Task Force / Purok
/// Leader) and uses it to pick both the bottom nav items and the
/// pages shown in the IndexedStack — same pattern DesktopShell uses
/// for "isCommandCenter" vs default nav items.
class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  String _activeRoute = '/location';
  String? _role;
  bool _loadingRole = true;

  final _supabase = Supabase.instance.client;

  static const Color bgDark = Color(0xFF121316);

  @override
  void initState() {
    super.initState();
    _fetchRole();
    // Fires when DispatchNotificationService's tap callback (wired in
    // main.dart) writes a dispatch id here — jumps Task Force straight
    // to the Dispatch tab so they land on the incident they were paged
    // for instead of whatever tab they were last on.
    TaskForceDispatchRouter.pendingDispatchId.addListener(_onDispatchTapped);
  }

  @override
  void dispose() {
    TaskForceDispatchRouter.pendingDispatchId.removeListener(_onDispatchTapped);
    DispatchNotificationService.instance.stopListening();
    super.dispose();
  }

  void _onDispatchTapped() {
    if (TaskForceDispatchRouter.pendingDispatchId.value == null) return;
    if (_role == 'task_force' && mounted) {
      setState(() => _activeRoute = '/dispatch');
    }
    TaskForceDispatchRouter.consume();
  }

  /// Normalizes whatever is stored in `profiles.role` / auth metadata
  /// into one of the three role keys this shell understands. Adjust
  /// the matching here if your DB already stores exact role slugs.
  String _normalizeRole(String? raw) {
    final r = (raw ?? '').trim().toLowerCase();
    if (r.contains('task')) return 'task_force';
    if (r.contains('purok')) return 'purok_leader';
    return 'tanod'; // default fallback
  }

  List<NavItem> _navItemsForRole(String role) {
    switch (role) {
      case 'task_force':
        return kTaskForceNavItems;
      case 'purok_leader':
        return kPurokLeaderNavItems;
      case 'tanod':
      default:
        return kTanodNavItems;
    }
  }

  /// Builds the IndexedStack pages for the given role. Each role can
  /// point at fully independent screen widgets — Tanod and Task Force
  /// already do.
  List<Widget> _pagesForRole(String role, int resolvedIndex) {
    switch (role) {
      case 'task_force':
        return [
          TaskForceHomeScreen(isActive: resolvedIndex == 0),
          TaskForceReportHistoryScreen(isActive: resolvedIndex == 1),
          ProfileScreen(isActive: resolvedIndex == 2),
        ];
      case 'purok_leader':
        return [
          PurokLeaderHomeScreen(isActive: resolvedIndex == 0),
          PurokLeaderMapScreen(isActive: resolvedIndex == 1),
          // NOTE: still borrowing Tanod's report history screen — see
          // TODO at top of file. Not in scope for this change.
          PurokLeaderReportHistoryScreen(isActive: resolvedIndex == 2),
          ProfileScreen(isActive: resolvedIndex == 3),
        ];
      case 'tanod':
      default:
        return [
          TanodHomeScreen(isActive: resolvedIndex == 0),
          TanodReportHistoryScreen(isActive: resolvedIndex == 1),
          ProfileScreen(isActive: resolvedIndex == 2),
        ];
    }
  }

  Future<void> _fetchRole() async {
    final userId = _supabase.auth.currentUser?.id;
    String? role = _supabase.auth.currentUser?.userMetadata?['role'];

    if (userId != null) {
      try {
        final response = await _supabase
            .from('profiles')
            .select('role')
            .eq('id', userId)
            .maybeSingle();
        if (response != null && response['role'] != null) {
          role = response['role'] as String;
        }
      } catch (_) {
        // Fall back to auth metadata role (or the default) on error.
      }
    }

    if (!mounted) return;
    final resolvedRole = _normalizeRole(role);
    setState(() {
      _role = resolvedRole;
      // Point the initial route at whatever this role's own first tab
      // is, rather than assuming '/location' always exists.
      _activeRoute = _navItemsForRole(resolvedRole).first.route;
      _loadingRole = false;
    });

    // Only Task Force currently needs push-style dispatch alerts.
    // Extend this to Purok Leader once their dispatch-request flow
    // gets an equivalent notification.
    if (resolvedRole == 'task_force') {
      DispatchNotificationService.instance.startListening();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingRole) {
      return const Scaffold(
        backgroundColor: bgDark,
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF2082E2)),
        ),
      );
    }

    final role = _role ?? 'tanod';
    final navItems = _navItemsForRole(role);
    final routeOrder = navItems.map((item) => item.route).toList();

    final activeIndexRaw = routeOrder.indexOf(_activeRoute);
    final resolvedIndex = activeIndexRaw == -1 ? 0 : activeIndexRaw;
    final resolvedRoute = routeOrder[resolvedIndex];

    final pages = _pagesForRole(role, resolvedIndex);

    return Scaffold(
      backgroundColor: bgDark,
      appBar: AppTopBar(title: navItems[resolvedIndex].label),
      body: SafeArea(
        child: IndexedStack(
          index: resolvedIndex,
          children: pages,
        ),
      ),
      bottomNavigationBar: AppNavbar(
        navItems: navItems,
        activeRoute: resolvedRoute,
        onNavItemTap: (route) {
          if (route != _activeRoute) {
            setState(() => _activeRoute = route);
          }
        },
      ),
    );
  }
}