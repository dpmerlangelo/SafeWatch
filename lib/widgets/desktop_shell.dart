import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/nav_item.dart';
import '../screens_desktop/admin/users_screen.dart';
import '../screens_desktop/admin/logs_screen.dart';
import '../screens_desktop/admin/cctv_screen.dart';
import '../screens_desktop/admin/speaker_screen.dart';
import '../screens_desktop/command_center/cctv_live_screen.dart';
import '../screens_desktop/command_center/user_location_screen.dart';
import 'app_sidebar.dart';
import 'app_top_header.dart';
import '../services/realtime_stream_service.dart';
import '../services/incident_report_link_service.dart';
import '../screens_desktop/command_center/incidents_screen.dart';
import '../screens_desktop/command_center/incident_report_screen.dart';
import '../screens_desktop/admin/dashboard_screen.dart';
import '../screens_desktop/admin/device_location_screen.dart';
import '../screens_desktop/admin/settings_screen.dart';
import '../screens_desktop/command_center/dashbard_screen.dart';
import '../constants/app_colors.dart';

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DesktopShell> {
  bool _isSidebarCollapsed = false;
  String _activeRoute = '/dashboard';

  final _supabase = Supabase.instance.client;

  // Nullable now — stays null until the Realtime socket is confirmed
  // authenticated, which prevents the same "opens as anonymous, RLS
  // returns 0 rows" race that hit UsersScreen.
  Stream<List<Map<String, dynamic>>>? _camerasStream;

  static const List<NavItem> _defaultNavItems = kAppNavItems;
  static const List<NavItem> _commandCenterNavItems = kCommandCenterNavItems;

  bool _isCommandCenter(String role) =>
      role.trim().toLowerCase() == 'command center';

  String _getInitials(String name) {
    if (name.trim().isEmpty) return 'U';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return parts[0][0].toUpperCase();
  }

  String _titleForRoute(String route, bool isCommandCenter) {
    switch (route) {
      case '/settings':
        return 'Settings';
      case '/dashboard':
        return 'Dashboard';
      case '/logs':
        return 'Logs';
      case '/cctv':
        return isCommandCenter ? 'Live CCTV' : 'CCTV';
      case '/incidents':
        return 'Incidents';
      case '/incident-reports':
        return 'Incident Reports';
      case '/speakers':
        return 'Speakers';
      case '/device-map':
        return 'Device Map';
      case '/location':
        return 'Tanod Location';
      case '/users':
      default:
        return 'Users';
    }
  }

  Future<Map<String, dynamic>> _fetchAdminProfile() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return {};

    try {
      final response = await _supabase
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();
      return response ?? {};
    } catch (_) {
      return {};
    }
  }

  Widget _buildCameraFeedPage(Widget Function(List<CctvCamera> cameras) builder) {
    if (_camerasStream == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF2082E2)),
      );
    }
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _camerasStream,
      builder: (context, camSnapshot) {
        final cameras = CctvCamera.listFromMaps(
          List<Map<String, dynamic>>.from(camSnapshot.data ?? []),
        );
        return builder(cameras);
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _camerasStream = RealtimeStreamService.instance
        .streamTable('cameras', primaryKey: ['id']);
    IncidentReportLinkService.instance.pending.addListener(_onLinkRequest);
  }

  @override
  void dispose() {
    IncidentReportLinkService.instance.pending.removeListener(_onLinkRequest);
    super.dispose();
  }

  /// Switches tabs when one screen asks to open a record on the other.
  /// The shell does NOT consume the request; the target screen does,
  /// once its data has loaded.
  void _onLinkRequest() {
    final req = IncidentReportLinkService.instance.pending.value;
    if (req == null) return;
    final route =
        req.target == LinkTarget.incident ? '/incidents' : '/incident-reports';
    if (route != _activeRoute) {
      setState(() => _activeRoute = route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _fetchAdminProfile(),
      builder: (context, snapshot) {
        final authUser = _supabase.auth.currentUser;
        final profile = snapshot.data ?? {};

        final firstName = profile['first_name'] ?? authUser?.userMetadata?['first_name'] ?? '';
        final lastName = profile['last_name'] ?? authUser?.userMetadata?['last_name'] ?? '';

        String adminName = '$firstName $lastName'.trim();
        if (adminName.isEmpty) {
          adminName = authUser?.email ?? 'User';
        }

        final String adminRole = profile['role'] ?? authUser?.userMetadata?['role'] ?? 'Admin';
        final String adminInitials = _getInitials(adminName);

        final isCommandCenter = _isCommandCenter(adminRole);
        final navItems = isCommandCenter ? _commandCenterNavItems : _defaultNavItems;
        final routeOrder = navItems.map((item) => item.route).toList();

        final activeIndexRaw = routeOrder.indexOf(_activeRoute);
        final resolvedIndex = activeIndexRaw == -1 ? 0 : activeIndexRaw;
        final resolvedRoute = routeOrder[resolvedIndex];

        // --- Build pages ---
        final pages = isCommandCenter
            ? [
                CommandCenterDashboardScreen(isActive: resolvedIndex == 0),
                _buildCameraFeedPage(
                  (cams) => CctvLiveScreen(isActive: resolvedIndex == 1, cameras: cams),
                ),
                _buildCameraFeedPage(
                  (cams) => IncidentsScreen(isActive: resolvedIndex == 2, cameras: cams),
                ),
                IncidentReportScreen(isActive: resolvedIndex == 3),
                // FIX: was `== 2`, which made it "active" on the reports tab.
                UserLocationScreen(isActive: resolvedIndex == 4),
              ]
            : [
                DashboardScreen(isActive: resolvedIndex == 0),
                UsersScreen(isActive: resolvedIndex == 1),
                LogsScreen(isActive: resolvedIndex == 2),
                CctvScreen(isActive: resolvedIndex == 3),
                SpeakerScreen(isActive: resolvedIndex == 4),
                DeviceLocationScreen(isActive: resolvedIndex == 5),
                AdminSettingsScreen(isActive: resolvedIndex == 6),
              ];

        // NOTE: '/dashboard' was added here. DashboardScreen's own
        // SingleChildScrollView now owns its content padding internally, so
        // the shell no longer wraps it in an outer Padding. That outer
        // Padding was pushing the scrollbar in from the true edge — a
        // Scrollbar always hugs the edge of whatever Scrollable it's
        // attached to, so wrapping the scroll view in padding drags the
        // scrollbar in with it, which is the "scrollbar has a padding" bug.
        final isZeroPadding =
            resolvedRoute == '/dashboard' ||
            (isCommandCenter && (resolvedRoute == '/cctv' || resolvedRoute == '/location')) ||
            resolvedRoute == '/device-map';

        return Scaffold(
          backgroundColor: AppColors.bg(context),
          body: Row(
            children: [
              AppSidebar(
                isCollapsed: _isSidebarCollapsed,
                navItems: navItems,
                activeRoute: resolvedRoute,
                onNavItemTap: (route) {
                  if (route != _activeRoute) {
                    setState(() => _activeRoute = route);
                  }
                },
                onLogout: () {
                  RealtimeStreamService.instance.clear(); // clear cached channels first
                  _supabase.auth.signOut();
                },
                onToggleSidebar: () => setState(
                    () => _isSidebarCollapsed = !_isSidebarCollapsed),
              ),
              Expanded(
                child: Column(
                  children: [
                    AppTopHeader(
                      title: _titleForRoute(resolvedRoute, isCommandCenter),
                      adminName: adminName,
                      adminInitials: adminInitials,
                    ),
                    Expanded(
                      child: Padding(
                        padding: isZeroPadding
                            ? EdgeInsets.zero
                            : const EdgeInsets.all(15.0),
                        child: IndexedStack(
                          index: resolvedIndex,
                          children: pages,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}