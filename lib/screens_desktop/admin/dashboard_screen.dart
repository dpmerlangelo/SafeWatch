import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../constants/barangay_boundary.dart';

/// Admin landing screen, v2 — a "bento" layout built from the same pieces
/// as CctvScreen (stat cards, rounded panels, status pills, avatars and
/// table-style rows) so the tabs read as one product.
///
///   ┌────────────────────────────────────────────────────────────┐
///   │ Header (title + date)                          [Refresh]    │
///   ├────────────────────────────────────────────────────────────┤
///   │ Stat cards — 4 across, clickable                            │
///   ├───────────────────────────────────────┬────────────────────┤
///   │ CAMERA LOCATIONS                       │ CAMERA HEALTH       │
///   │ map + floating status legend           │ ring + offline-first│
///   │                                        │ camera list         │
///   ├───────────────────────────────────────┴────────────────────┤
///   │ RECENT ACTIVITY — table (activity · user · when) + pager bar │
///   └────────────────────────────────────────────────────────────┘
///
/// Data sourcing:
///  - `cameras` and `profiles` are realtime-streamed (small tables).
///  - `logs` is polled every 30s (recent 8 rows + timestamps for counts),
///    since that table only grows.
///
/// Camera statuses are Online / Offline only.
class DashboardScreen extends StatefulWidget {
  final bool isActive;

  /// Lets stat cards / links jump to another tab. Safe to leave null.
  final void Function(String route)? onNavigate;

  const DashboardScreen({super.key, this.isActive = true, this.onNavigate});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with AutomaticKeepAliveClientMixin {
  final SupabaseClient _supabase = Supabase.instance.client;

  late final Stream<List<Map<String, dynamic>>> _camerasStream;
  late final Stream<List<Map<String, dynamic>>> _profilesStream;

  // --- Logs summary (polled, not streamed) ---
  List<Map<String, dynamic>> _recentLogs = [];
  int _totalLogs = 0;
  int _logsToday = 0;
  bool _logsLoading = true;
  String? _logsError;
  Timer? _logsRefreshTimer;

  static const Duration _logsRefreshInterval = Duration(seconds: 30);

  // Below this width the map / health row stacks into one column.
  static const double _stackBreakpoint = 1000;

  // Shared body height so the map panel and health panel line up exactly.
  static const double _panelBodyHeight = 400;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _camerasStream = _supabase.from('cameras').stream(primaryKey: ['id']);
    _profilesStream = _supabase.from('profiles').stream(primaryKey: ['id']);

    _loadLogsSummary();
    _logsRefreshTimer =
        Timer.periodic(_logsRefreshInterval, (_) => _loadLogsSummary());
  }

  @override
  void dispose() {
    _logsRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadLogsSummary() async {
    try {
      final recent = await _supabase
          .from('logs')
          .select()
          .order('timestamp', ascending: false)
          .limit(8);

      // Only `timestamp` is pulled for the counts to keep this cheap.
      final allTimestamps = await _supabase.from('logs').select('timestamp');

      final now = DateTime.now();
      final todayCount = allTimestamps.where((row) {
        final ts = DateTime.tryParse((row['timestamp'] ?? '').toString());
        if (ts == null) return false;
        final local = ts.toLocal();
        return local.year == now.year &&
            local.month == now.month &&
            local.day == now.day;
      }).length;

      if (!mounted) return;
      setState(() {
        _recentLogs = List<Map<String, dynamic>>.from(recent);
        _totalLogs = allTimestamps.length;
        _logsToday = todayCount;
        _logsLoading = false;
        _logsError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _logsLoading = false;
        _logsError = e.toString();
      });
    }
  }

  String _timeAgo(String? isoTimestamp) {
    if (isoTimestamp == null) return '';
    final dt = DateTime.tryParse(isoTimestamp)?.toLocal();
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  Color _colorForCameraStatus(String status) {
    return status.toUpperCase() == 'ONLINE'
        ? AppColors.accentGreen
        : AppColors.accentRed;
  }

  bool _isOnline(Map<String, dynamic> c) =>
      (c['status'] ?? '').toString().toUpperCase() == 'ONLINE';

  // Icon + color for an activity-log row, keyed off the action string.
  ({IconData icon, Color color}) _activityStyle(String action) {
    final a = action.toUpperCase();
    if (a.contains('DELETE') || a.contains('REMOVE')) {
      return (icon: Icons.delete_outline, color: AppColors.accentRed);
    }
    if (a.contains('CREATE') || a.contains('ADD')) {
      return (icon: Icons.add_circle_outline, color: AppColors.accentGreen);
    }
    if (a.contains('STATUS')) {
      return (icon: Icons.sync_alt_rounded, color: AppColors.accentOrange);
    }
    if (a.contains('UPDATE') || a.contains('EDIT')) {
      return (icon: Icons.edit_outlined, color: AppColors.accentBlue);
    }
    if (a.contains('LOGIN') || a.contains('LOGOUT')) {
      return (icon: Icons.login_rounded, color: AppColors.accentBlue);
    }
    return (icon: Icons.history_rounded, color: AppColors.textMuted(context));
  }

  // ---------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _camerasStream,
      builder: (context, cameraSnap) {
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: _profilesStream,
          builder: (context, profileSnap) {
            final camerasLoading = !cameraSnap.hasData &&
                cameraSnap.connectionState == ConnectionState.waiting;
            final profilesLoading = !profileSnap.hasData &&
                profileSnap.connectionState == ConnectionState.waiting;
            final cameras = (cameraSnap.data ?? const <Map<String, dynamic>>[])
                .map((r) => Map<String, dynamic>.from(r))
                .toList();
            final profiles =
                (profileSnap.data ?? const <Map<String, dynamic>>[]);

            // Dashboard is a zero-padding route at the shell level (see
            // DesktopShell.isZeroPadding), so this SingleChildScrollView
            // owns its own content padding. It's the scroll view's own
            // `padding` (space around its child), not an outer wrapper
            // around the whole Scrollable, so the Scrollbar still attaches
            // to the full-size Scrollable and hugs the true edge.
            return Scrollbar(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 18),
                    _buildStatCardsRow(
                      cameras: cameras,
                      profiles: profiles,
                      camerasLoading: camerasLoading,
                      profilesLoading: profilesLoading,
                    ),
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final canSplit =
                            constraints.maxWidth >= _stackBreakpoint;
                        final mapPanel = _buildCameraLocationsPanel(
                            cameras, camerasLoading);
                        final healthPanel =
                            _buildCameraHealthPanel(cameras, camerasLoading);

                        if (!canSplit) {
                          return Column(
                            children: [
                              mapPanel,
                              const SizedBox(height: 18),
                              healthPanel,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 6, child: mapPanel),
                            const SizedBox(width: 18),
                            Expanded(flex: 4, child: healthPanel),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 18),
                    _buildRecentActivityPanel(),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // --- HEADER ---

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Dashboard',
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${DateFormat('EEEE, MMM d, yyyy').format(DateTime.now())}  •  '
                'Overview of cameras, users and activity',
                style: TextStyle(
                    color: AppColors.textMuted(context), fontSize: 13),
              ),
            ],
          ),
        ),
        _HoverPop(
          child: SizedBox(
            height: 40,
            child: OutlinedButton.icon(
              onPressed: _loadLogsSummary,
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('Refresh',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textMain(context),
                backgroundColor: AppColors.card(context),
                side: BorderSide(color: AppColors.border(context)),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --- STAT CARDS ---

  Widget _buildStatCardsRow({
    required List<Map<String, dynamic>> cameras,
    required List<Map<String, dynamic>> profiles,
    required bool camerasLoading,
    required bool profilesLoading,
  }) {
    final total = cameras.length;
    final onlineCount = cameras.where(_isOnline).length;
    final placedCount = cameras
        .where((c) => c['latitude'] is num && c['longitude'] is num)
        .length;

    // Top-2 roles by count + "+N more", so the note never overflows.
    final roleCounts = <String, int>{};
    for (final p in profiles) {
      final role = (p['role'] ?? 'Unknown').toString().trim();
      final label = role.isEmpty ? 'Unknown' : role;
      roleCounts[label] = (roleCounts[label] ?? 0) + 1;
    }
    final sortedRoles = roleCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final shownRoles = sortedRoles.take(2).toList();
    final remainingRoles = sortedRoles.length - shownRoles.length;
    final roleNote = [
      for (final e in shownRoles) '${e.value} ${e.key}',
      if (remainingRoles > 0) '+$remainingRoles more',
    ].join(' • ');

    double share(int part, int whole) => whole == 0 ? 0 : part / whole;
    String pct(int part, int whole) =>
        whole == 0 ? '0%' : '${((part / whole) * 100).round()}%';

    final cards = <Widget>[
      _StatCard(
        label: 'Total cameras',
        value: camerasLoading ? '—' : '$total',
        caption: 'All statuses',
        note: camerasLoading ? 'Loading…' : '$onlineCount online',
        icon: Icons.videocam_outlined,
        color: AppColors.accentBlue,
        share: total == 0 ? 0 : 1,
        onTap: () => widget.onNavigate?.call('/cctv'),
      ),
      _StatCard(
        label: 'Cameras online',
        value: camerasLoading ? '—' : '$onlineCount',
        caption: camerasLoading ? '' : pct(onlineCount, total),
        note: camerasLoading ? 'Loading…' : '${total - onlineCount} offline',
        icon: Icons.wifi_tethering,
        color: AppColors.accentGreen,
        share: share(onlineCount, total),
        onTap: () => widget.onNavigate?.call('/cctv'),
      ),
      _StatCard(
        label: 'Total users',
        value: profilesLoading ? '—' : '${profiles.length}',
        caption: 'All roles',
        note: profilesLoading
            ? 'Loading…'
            : (roleNote.isEmpty ? 'No users yet' : roleNote),
        icon: Icons.people_outline,
        color: AppColors.accentOrange,
        share: profiles.isEmpty ? 0 : 1,
        onTap: () => widget.onNavigate?.call('/users'),
      ),
      _StatCard(
        label: 'Locations set',
        value: camerasLoading ? '—' : '$placedCount',
        caption: camerasLoading ? '' : pct(placedCount, total),
        note: camerasLoading ? 'Loading…' : '${total - placedCount} unplaced',
        icon: Icons.location_on_outlined,
        color: AppColors.accentBlue,
        share: share(placedCount, total),
        onTap: () => widget.onNavigate?.call('/device-location'),
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        const gap = 14.0;
        final perRow = c.maxWidth >= 760 ? 4 : 2;
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final card in cards) SizedBox(width: w, child: card)],
        );
      },
    );
  }

  // --- PANEL CHROME ---

  Widget _panelShell({
    required String title,
    required IconData icon,
    Widget? trailing,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
            child: Row(
              children: [
                Icon(icon, size: 15, color: AppColors.textMuted(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.9,
                    ),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }

  Widget _panelLink(String label, String route) {
    return _HoverPop(
      child: InkWell(
        onTap: () => widget.onNavigate?.call(route),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.accentBlue,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_forward_rounded,
                  size: 13, color: AppColors.accentBlue),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyMessage(IconData icon, String text, {double height = 120}) {
    return SizedBox(
      height: height,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: AppColors.textMuted(context)),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loadingBox({double height = 120}) {
    return SizedBox(
      height: height,
      child: const Center(
        child: CircularProgressIndicator(
            color: AppColors.accentBlue, strokeWidth: 2.4),
      ),
    );
  }

  // --- CAMERA LOCATIONS PANEL (map with floating legend) ---

  Widget _buildCameraLocationsPanel(
      List<Map<String, dynamic>> cameras, bool loading) {
    final online = cameras.where(_isOnline).length;
    final offline = cameras.length - online;

    return _panelShell(
      title: 'CAMERA LOCATIONS',
      icon: Icons.map_outlined,
      trailing: _panelLink('Manage', '/device-location'),
      child: loading
          ? _loadingBox(height: _panelBodyHeight)
          : SizedBox(
              height: _panelBodyHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border(context)),
                        ),
                        child: _CameraLocationsPreviewMap(
                          cameras: cameras,
                          colorForStatus: _colorForCameraStatus,
                          onEmptyManageTap: () =>
                              widget.onNavigate?.call('/device-location'),
                        ),
                      ),
                    ),
                    if (cameras.isNotEmpty)
                      Positioned(
                        top: 10,
                        left: 10,
                        child: Row(
                          children: [
                            _mapLegendPill('Online', online,
                                AppColors.accentGreen),
                            const SizedBox(width: 8),
                            _mapLegendPill('Offline', offline,
                                AppColors.accentRed),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _mapLegendPill(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.card(context).withOpacity(0.94),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: const [
          BoxShadow(
              color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '$count $label',
            style: TextStyle(
              color: AppColors.textMain(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // --- CAMERA HEALTH PANEL (ring + offline-first list) ---

  Widget _buildCameraHealthPanel(
      List<Map<String, dynamic>> cameras, bool loading) {
    return _panelShell(
      title: 'CAMERA HEALTH',
      icon: Icons.monitor_heart_outlined,
      trailing: _panelLink('View all', '/cctv'),
      child: loading
          ? _loadingBox(height: _panelBodyHeight)
          : cameras.isEmpty
              ? _emptyMessage(
                  Icons.videocam_off_outlined, 'No cameras added yet.',
                  height: _panelBodyHeight)
              : SizedBox(
                  height: _panelBodyHeight,
                  child: _buildHealthBody(cameras),
                ),
    );
  }

  Widget _buildHealthBody(List<Map<String, dynamic>> cameras) {
    final total = cameras.length;
    final online = cameras.where(_isOnline).length;
    final offline = total - online;
    final fraction = total == 0 ? 0.0 : online / total;

    // Offline first — those are what an admin needs to look at.
    final sorted = [...cameras]..sort((a, b) {
        int rank(Map<String, dynamic> m) => _isOnline(m) ? 1 : 0;
        return rank(a).compareTo(rank(b));
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 108,
              height: 108,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(108, 108),
                    painter: _HealthRingPainter(
                      fraction: fraction,
                      hasData: total > 0,
                      onlineColor: AppColors.accentGreen,
                      offlineColor: AppColors.accentRed,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${(fraction * 100).round()}%',
                        style: TextStyle(
                          color: AppColors.textMain(context),
                          fontSize: 22,
                          height: 1,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'online',
                        style: TextStyle(
                          color: AppColors.textMuted(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _legendRow('Online', online, AppColors.accentGreen),
                  const SizedBox(height: 10),
                  _legendRow('Offline', offline, AppColors.accentRed),
                  const SizedBox(height: 10),
                  _legendRow('Total', total, AppColors.accentBlue),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (offline == 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.accentGreen.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: AppColors.accentGreen.withOpacity(0.28)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline,
                    size: 15, color: AppColors.accentGreen),
                const SizedBox(width: 8),
                Text(
                  'All cameras are online',
                  style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.accentRed.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.accentRed.withOpacity(0.28)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 15, color: AppColors.accentRed),
                const SizedBox(width: 8),
                Text(
                  '$offline ${offline == 1 ? 'camera needs' : 'cameras need'} attention',
                  style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        Text(
          'CAMERAS · OFFLINE FIRST',
          style: TextStyle(
            color: AppColors.textMuted(context),
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: sorted.length,
            itemBuilder: (context, i) => _buildCameraRow(sorted[i]),
          ),
        ),
      ],
    );
  }

  Widget _legendRow(String label, int count, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          '$count',
          style: TextStyle(
            color: AppColors.textMain(context),
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildCameraRow(Map<String, dynamic> camera) {
    final name = (camera['name'] ?? 'Unnamed camera').toString();
    final location = (camera['location'] ?? '').toString();
    final status = (camera['status'] ?? 'Offline').toString();
    final hasPin = camera['latitude'] is num && camera['longitude'] is num;

    return _HoverRow(
      onTap: () => widget.onNavigate?.call('/cctv'),
      child: Row(
        children: [
          _CameraAvatar(
              color: _colorForCameraStatus(status), size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (location.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppColors.textMuted(context), fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ),
          if (!hasPin) ...[
            Tooltip(
              message: 'No map location set',
              child: Icon(Icons.location_off_outlined,
                  size: 14, color: AppColors.textMuted(context)),
            ),
            const SizedBox(width: 10),
          ],
          _StatusChip(status: status, color: _colorForCameraStatus(status)),
        ],
      ),
    );
  }

  // --- RECENT ACTIVITY PANEL (table style, like the CCTV list view) ---

  Widget _buildRecentActivityPanel() {
    Widget headerCell(String text, int flex) => Expanded(
          flex: flex,
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        );

    Widget body;
    if (_logsLoading) {
      body = _loadingBox(height: 160);
    } else if (_logsError != null) {
      body = _emptyMessage(Icons.error_outline_rounded,
          'Couldn\'t load recent activity.\n$_logsError',
          height: 160);
    } else if (_recentLogs.isEmpty) {
      body = _emptyMessage(
          Icons.history_toggle_off_rounded, 'No activity logged yet.',
          height: 160);
    } else {
      body = Column(
        children: [
          Container(
            color: AppColors.sunken(context),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
            child: Row(
              children: [
                headerCell('ACTIVITY', 6),
                headerCell('USER', 2),
                headerCell('WHEN', 2),
              ],
            ),
          ),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          for (int i = 0; i < _recentLogs.length; i++) ...[
            _buildActivityRow(_recentLogs[i]),
            if (i != _recentLogs.length - 1)
              Divider(color: AppColors.border(context), height: 1, thickness: 1),
          ],
        ],
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
            child: Row(
              children: [
                Icon(Icons.history_rounded,
                    size: 15, color: AppColors.textMuted(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'RECENT ACTIVITY',
                    style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.9,
                    ),
                  ),
                ),
                _HoverPop(
                  child: InkWell(
                    onTap: _loadLogsSummary,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.refresh_rounded,
                          size: 16, color: AppColors.textMuted(context)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          body,
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          Container(
            color: AppColors.sunken(context),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 18),
            child: Row(
              children: [
                Text(
                  _logsLoading || _logsError != null
                      ? 'Latest 8 entries'
                      : 'Showing latest ${_recentLogs.length} · '
                          '$_totalLogs total · $_logsToday today',
                  style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                _panelLink('View all logs', '/logs'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityRow(Map<String, dynamic> log) {
    final action = (log['action'] ?? '').toString();
    final details = (log['details'] ?? '').toString();
    final userName = (log['user_name'] ?? 'System').toString();
    final timeAgo = _timeAgo(log['timestamp']?.toString());
    final label = details.isNotEmpty ? details : action;
    final style = _activityStyle(action);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: style.color.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(style.icon, size: 16, color: style.color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              userName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: AppColors.textMain(context), fontSize: 12.5),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              timeAgo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: AppColors.textMuted(context), fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared small widgets (same look as CctvScreen)
// ---------------------------------------------------------------------------

/// Pointer cursor on hover.
class _HoverPop extends StatelessWidget {
  final Widget child;
  final bool enabled;
  const _HoverPop({required this.child, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: child,
    );
  }
}

/// Tinted pill with a colored dot.
class _StatusChip extends StatelessWidget {
  final String status;
  final Color color;
  const _StatusChip({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            status.toUpperCase(),
            style: TextStyle(
              color: AppColors.textMain(context),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular camera avatar with a soft status-colored ring.
class _CameraAvatar extends StatelessWidget {
  final Color color;
  final double size;
  const _CameraAvatar({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.045),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.card(context),
        border: Border.all(color: color.withOpacity(0.55), width: 2),
      ),
      child: ClipOval(
        child: Container(
          color: color.withOpacity(0.16),
          alignment: Alignment.center,
          child: Icon(Icons.videocam_outlined, color: color, size: size * 0.42),
        ),
      ),
    );
  }
}

/// Bordered list row with a hover highlight.
class _HoverRow extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _HoverRow({required this.child, this.onTap});

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  static const Duration _hoverDuration = Duration(milliseconds: 120);

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          // New key when the theme colors change => fresh state that starts
          // at the new colors (no fade). Hover still animates normally.
          key: ValueKey(AppColors.border(context)),
          duration: _hoverDuration,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: AppColors.sunken(context).withOpacity(_hover ? 1 : 0.55),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Dashboard stat card — same structure as the CCTV tab's stat cards, plus
/// an optional one-line `note` under the label.
class _StatCard extends StatefulWidget {
  final String label;
  final String value;
  final String caption;
  final String? note;
  final IconData icon;
  final Color color;
  final double share;
  final VoidCallback? onTap;

  const _StatCard({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
    required this.share,
    this.note,
    this.onTap,
  });

  @override
  State<_StatCard> createState() => _StatCardState();
}

class _StatCardState extends State<_StatCard> {
  bool _hover = false;

  static const Duration _hoverDuration = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return MouseRegion(
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          // New key when the theme colors change => fresh state that starts
          // at the new colors (no fade). Hover still animates normally.
          key: ValueKey(AppColors.card(context)),
          duration: _hoverDuration,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _hover ? c.withOpacity(0.5) : AppColors.border(context),
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: c.withOpacity(0.14),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    )
                  ]
                : const [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: c.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(widget.icon, size: 18, color: c),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      widget.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted(context),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                widget.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 28,
                  height: 1,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textMuted(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (widget.note != null) ...[
                const SizedBox(height: 2),
                Text(
                  widget.note!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMuted(context).withOpacity(0.85),
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: widget.share.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: c.withOpacity(0.12),
                  valueColor: AlwaysStoppedAnimation<Color>(c),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Donut showing the online share. The full ring is drawn in the offline
/// color, then the online arc is painted on top.
class _HealthRingPainter extends CustomPainter {
  final double fraction;
  final bool hasData;
  final Color onlineColor;
  final Color offlineColor;

  const _HealthRingPainter({
    required this.fraction,
    required this.hasData,
    required this.onlineColor,
    required this.offlineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke,
        size.height - stroke);

    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = hasData ? offlineColor.withOpacity(0.85) : Colors.grey.withOpacity(0.25);
    canvas.drawArc(rect, 0, math.pi * 2, false, base);

    if (hasData && fraction > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = onlineColor;
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fraction, false, arc);
    }
  }

  @override
  bool shouldRepaint(covariant _HealthRingPainter old) =>
      old.fraction != fraction ||
      old.hasData != hasData ||
      old.onlineColor != onlineColor ||
      old.offlineColor != offlineColor;
}

// ---------------------------------------------------------------------------
// Read-only camera map preview
// ---------------------------------------------------------------------------

/// Read-only map used in the "Camera Locations" panel. Fits the boundary (or
/// all pins) once and shows static markers. Mirrors DeviceLocationScreen's
/// themed-tile / boundary-mask technique so both maps look like one basemap.
class _CameraLocationsPreviewMap extends StatefulWidget {
  final List<Map<String, dynamic>> cameras;
  final Color Function(String status) colorForStatus;
  final VoidCallback onEmptyManageTap;

  const _CameraLocationsPreviewMap({
    required this.cameras,
    required this.colorForStatus,
    required this.onEmptyManageTap,
  });

  @override
  State<_CameraLocationsPreviewMap> createState() =>
      _CameraLocationsPreviewMapState();
}

class _CameraLocationsPreviewMapState
    extends State<_CameraLocationsPreviewMap> {
  static const LatLng _fallbackCenter = LatLng(14.6837, 121.0766);
  static const Color _cameraPinColor = Color(0xFF2082E2);
  static const List<LatLng> _maskOuterRing = [
    LatLng(-85, -180),
    LatLng(-85, 180),
    LatLng(85, 180),
    LatLng(85, -180),
  ];

  // Pre-combined tile color matrices. Using ONE ColorFiltered whose matrix
  // swaps between modes keeps the widget tree identical in light and dark,
  // so the TileLayer (and its loaded tiles) survives a theme switch instead
  // of being destroyed and re-fetched.

  // Light: saturation matrix, then a 4% white "screen" (≈ ×0.96 + 10.2).
  static const List<double> _lightTileMatrix = <double>[
    0.657638, 0.274637, 0.027725, 0, 10.2,
    0.081638, 0.850637, 0.027725, 0, 10.2,
    0.081638, 0.274637, 0.603725, 0, 10.2,
    0, 0, 0, 1, 0,
  ];

  // Dark: grayscale -> invert -> duotone, collapsed into a single matrix.
  static const List<double> _darkTileMatrix = <double>[
    -0.105046, -0.353380, -0.035674, 0, 147.9955,
    -0.109213, -0.367398, -0.037089, 0, 162.9935,
    -0.115059, -0.387066, -0.039075, 0, 184.006,
    0, 0, 0, 1, 0,
  ];

  final MapController _mapController = MapController();
  bool _fitted = false;

  List<_PreviewPin> get _pins => widget.cameras
      .map((c) {
        final lat = c['latitude'];
        final lng = c['longitude'];
        if (lat is! num || lng is! num) return null;
        return _PreviewPin(
          name: (c['name'] ?? 'Unnamed camera').toString(),
          status: (c['status'] ?? 'Offline').toString(),
          position: LatLng(lat.toDouble(), lng.toDouble()),
        );
      })
      .whereType<_PreviewPin>()
      .toList();

  // Fit is driven by onMapReady (not build()) so flutter_map's camera has
  // synced to the real container size; a short delayed re-fit covers layout
  // that settles a frame or two later.
  void _fitOnce(List<LatLng> points) {
    if (_fitted || points.isEmpty) return;
    _fitted = true;

    void doFit() {
      if (!mounted) return;
      if (points.length == 1) {
        _mapController.move(points.first, 16);
      } else {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(48),
          ),
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      doFit();
      Future.delayed(const Duration(milliseconds: 150), doFit);
    });
  }

  Widget _buildThemedTileLayer(bool isDark) {
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(
        isDark ? _darkTileMatrix : _lightTileMatrix,
      ),
      child: TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.yourcompany.admin_app',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pins = _pins;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final boundaryPoints = BarangayBoundary.points;
    final maskColor = AppColors.bg(context).withOpacity(isDark ? 0.90 : 0.80);

    final fitTargets =
        pins.isNotEmpty ? pins.map((p) => p.position).toList() : boundaryPoints;
    final initialCenter =
        boundaryPoints.isNotEmpty ? boundaryPoints.first : _fallbackCenter;

    return Stack(
      children: [
        RepaintBoundary(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: 16,
              minZoom: 13,
              maxZoom: 18,
              onMapReady: () => _fitOnce(fitTargets),
              // Read-only preview: just pan/zoom.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.drag |
                    InteractiveFlag.pinchZoom |
                    InteractiveFlag.doubleTapZoom,
              ),
            ),
            children: [
              _buildThemedTileLayer(isDark),
              if (boundaryPoints.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: _maskOuterRing,
                      holePointsList: [boundaryPoints],
                      color: maskColor,
                      isFilled: true,
                    ),
                    Polygon(
                      points: boundaryPoints,
                      color: Colors.transparent,
                      borderColor: AppColors.accentBlue,
                      borderStrokeWidth: 2,
                      isFilled: false,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  for (final pin in pins)
                    Marker(
                      point: pin.position,
                      width: 80,
                      height: 48,
                      // Pin dot sits on the coordinate, label hangs below.
                      alignment: Alignment.topCenter,
                      child: Tooltip(
                        message: '${pin.name} · ${pin.status}',
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: _cameraPinColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: widget.colorForStatus(pin.status),
                                    width: 2.5),
                                boxShadow: const [
                                  BoxShadow(
                                      color: Colors.black45,
                                      blurRadius: 3,
                                      offset: Offset(0, 1)),
                                ],
                              ),
                              child: const Icon(Icons.videocam,
                                  color: Colors.white, size: 13),
                            ),
                            const SizedBox(height: 3),
                            Container(
                              constraints: const BoxConstraints(maxWidth: 76),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color:
                                    AppColors.card(context).withOpacity(0.92),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: AppColors.border(context)),
                              ),
                              child: Text(
                                pin.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textMain(context),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              RichAttributionWidget(
                alignment: AttributionAlignment.bottomRight,
                showFlutterMapAttribution: false,
                attributions: [
                  TextSourceAttribution('OpenStreetMap contributors'),
                ],
                popupBackgroundColor: AppColors.card(context),
              ),
            ],
          ),
        ),
        if (pins.isEmpty)
          Positioned.fill(
            child: Container(
              color: AppColors.bg(context).withOpacity(0.55),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_off_outlined,
                          color: AppColors.textMuted(context), size: 22),
                      const SizedBox(height: 8),
                      Text(
                        'No cameras have a location yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColors.textMuted(context), fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: widget.onEmptyManageTap,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accentBlue,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Set Locations',
                            style: TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else
          Positioned(
            left: 10,
            bottom: 10,
            child: Material(
              color: AppColors.card(context).withOpacity(0.94),
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  '${pins.length}/${widget.cameras.length} placed',
                  style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PreviewPin {
  final String name;
  final String status;
  final LatLng position;

  const _PreviewPin({
    required this.name,
    required this.status,
    required this.position,
  });
}