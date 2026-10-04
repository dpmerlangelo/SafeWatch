import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:flutter_map/flutter_map.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../constants/app_colors.dart';
import '../../constants/barangay_boundary.dart';
import '../../widgets/themed_map_layers.dart';

// =============================================================================
// PUROK LEADER — LIVE MAP (monitoring, not action)
// =============================================================================
//
// A tanod shows as:
//   - GREY  + location_off icon ("OFF")        when live_gps.is_sharing == false
//   - AMBER + signal_wifi_off icon ("NO SIGNAL") when sharing is on but the
//     last update is older than _kStaleAfter (app closed / no signal).
//
// DATA SOURCES:
//   - profiles WHERE purok = <leader's purok> AND role = 'Tanod'  -> roster
//   - live_gps (realtime, incl. is_sharing)                        -> pins
//   - dispatch_requests WHERE leader_id = me (pending/dispatched) -> incidents
//   - tanod_dispatches (realtime)                                  -> busy + team
//   - incidents / cameras (cached one-shot fetches)                -> labels
//
// MAP THEME: basemap tiles and the barangay boundary mask come from the shared
// `ThemedMapLayers` (widgets/themed_map_layers.dart), the same one used by the
// Tanod and Task Force home screens.

const String _kTanodRole = 'Tanod';
const _kCompletedStatus = 'completed';

// A fix older than this is treated as "no signal" even if is_sharing is true.
const Duration _kStaleAfter = Duration(minutes: 3);

/// Amber for "no signal" so it reads differently from grey (sharing turned
/// off) and from the orange used for mixed clusters.
const Color _kNoSignalColor = Color(0xFFFFB300);

const double _kClusterCellPx = 64;
const double _kClusterOffZoom = 18;

class _TanodProfile {
  final String id;
  final String fullName;
  _TanodProfile({required this.id, required this.fullName});

  factory _TanodProfile.fromMap(Map<String, dynamic> row) {
    final first = (row['first_name'] ?? '').toString().trim();
    final last = (row['last_name'] ?? '').toString().trim();
    final name = '$first $last'.trim();
    return _TanodProfile(
        id: row['id'].toString(), fullName: name.isEmpty ? 'Unnamed tanod' : name);
  }

  String get shortName {
    final parts = fullName.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) return fullName;
    return '${parts.first} ${parts.last.substring(0, 1).toUpperCase()}.';
  }

  String get initials {
    final parts = fullName.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

class _TanodFix {
  final ll.LatLng point;
  final DateTime updatedAt;

  /// live_gps.is_sharing — false when the tanod turned location sharing off.
  final bool sharing;

  _TanodFix({required this.point, required this.updatedAt, this.sharing = true});

  bool get isStale => DateTime.now().difference(updatedAt) > _kStaleAfter;

  /// Tanod deliberately turned location sharing off.
  bool get isSharingOff => !sharing;

  /// Sharing is on, but no fresh fix has arrived (lost signal / no data).
  bool get isNoSignal => sharing && isStale;

  /// Either of the above — shown greyed/amber on the map.
  bool get isOff => isSharingOff || isNoSignal;
}

class _IncidentPin {
  final String requestId;
  final String alertType;
  final String? cameraLocation;
  final double? latitude;
  final double? longitude;
  final String status; // pending | dispatched
  final Set<String> assignedTanodIds;
  final String? teamLeadId;

  _IncidentPin({
    required this.requestId,
    required this.alertType,
    required this.cameraLocation,
    required this.latitude,
    required this.longitude,
    required this.status,
    required this.assignedTanodIds,
    this.teamLeadId,
  });

  bool get hasLocation => latitude != null && longitude != null;

  _IncidentPin copyWith({Set<String>? assignedTanodIds, String? teamLeadId}) => _IncidentPin(
        requestId: requestId,
        alertType: alertType,
        cameraLocation: cameraLocation,
        latitude: latitude,
        longitude: longitude,
        status: status,
        assignedTanodIds: assignedTanodIds ?? this.assignedTanodIds,
        teamLeadId: teamLeadId ?? this.teamLeadId,
      );
}

// ============================================================================
// SHARED UI HELPERS
// ============================================================================

String _titleCase(String s) {
  final cleaned = s.replaceAll('_', ' ').trim();
  if (cleaned.isEmpty) return cleaned;
  return cleaned
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

IconData _incidentIcon(String alertType) {
  final t = alertType.toLowerCase();
  bool has(List<String> keys) => keys.any(t.contains);
  if (has(['fire', 'smoke', 'burn'])) return Icons.local_fire_department;
  if (has(['weapon', 'gun', 'knife', 'firearm'])) return Icons.gpp_maybe;
  if (has(['fight', 'violence', 'assault', 'brawl'])) return Icons.sports_kabaddi;
  if (has(['accident', 'crash', 'collision', 'vehicle'])) return Icons.car_crash;
  if (has(['theft', 'robb', 'burglar', 'snatch', 'stolen'])) return Icons.lock_open;
  if (has(['intru', 'trespass', 'unauthor', 'loiter', 'suspicious', 'person'])) {
    return Icons.person_search;
  }
  if (has(['flood', 'water'])) return Icons.flood;
  return Icons.warning_amber_rounded;
}

String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  // Negative = timestamp slightly in the future (clock skew) -> treat as now.
  if (diff.isNegative || diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  return '${diff.inDays} d ago';
}

String _formatDistance(double km) =>
    km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km';

double _straightLineKm(ll.LatLng a, ll.LatLng b) {
  const earthRadiusKm = 6371.0;
  double degToRad(double d) => d * (math.pi / 180);
  final dLat = degToRad(b.latitude - a.latitude);
  final dLng = degToRad(b.longitude - a.longitude);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(degToRad(a.latitude)) *
          math.cos(degToRad(b.latitude)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return earthRadiusKm * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

Widget _pill(String label, Color color, {IconData? icon}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w800)),
        ],
      ),
    );

class _Pin extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool selected;
  const _Pin({required this.icon, required this.color, this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: selected ? 3 : 2),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: selected ? 8 : 4)],
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

/// Round icon badge with a small Life360-style pointer at the bottom: status
/// color badge, white border, solid white pointer. The pointer tip is at
/// bottom-center of [size], so a Marker with `alignment: Alignment.topCenter`
/// puts that tip exactly on the coordinate.
class _PinPainter extends CustomPainter {
  final Color fill;
  final double borderWidth;
  final bool selected;

  const _PinPainter({
    required this.fill,
    this.borderWidth = 2.5,
    this.selected = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final outerR = size.width / 2;
    final r = outerR - borderWidth / 2; // border stays inside the badge width
    final cy = outerR;
    final hw = outerR * 0.36; // half-width of the pointer base
    final baseY = cy + outerR * 0.85; // base sits inside the circle
    final tipY = size.height;

    final circle = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    final pointer = Path()
      ..moveTo(cx - hw, baseY)
      ..lineTo(cx, tipY)
      ..lineTo(cx + hw, baseY)
      ..close();
    final shape = Path.combine(PathOperation.union, circle, pointer);

    canvas.drawShadow(shape, Colors.black, 3, true);

    // Selected: dark halo around the white border so it stands out.
    if (selected) {
      canvas.drawPath(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = borderWidth + 5
          ..color = Colors.black.withOpacity(0.55),
      );
    }

    // Pointer is solid white; the badge is the status color with a white border.
    canvas.drawPath(pointer, Paint()..color = Colors.white);
    canvas.drawPath(circle, Paint()..color = fill);
    canvas.drawPath(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_PinPainter o) =>
      o.fill != fill || o.borderWidth != borderWidth || o.selected != selected;
}

/// Tanod pin: round badge (status color, white border, shield icon) with a
/// small white pointer at the bottom and the tanod's name above it.
///
/// Status color:
///   • available            -> green
///   • on active dispatch   -> red
///   • sharing turned off   -> grey
///   • lost signal          -> amber (noSignal = true)
///
/// The marker box is bottom-aligned, so with `Marker.alignment:
/// Alignment.topCenter` the pointer tip lands exactly on the coordinate.
class _TanodMarker extends StatelessWidget {
  final String initials;
  final String label;
  final bool busy;
  final bool selected;
  final bool off;

  /// Only meaningful when [off] is true: still sharing but stale fix.
  final bool noSignal;

  const _TanodMarker({
    required this.initials,
    required this.label,
    required this.busy,
    required this.selected,
    this.off = false,
    this.noSignal = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color offColor = noSignal ? _kNoSignalColor : Colors.grey;
    final Color color =
        off ? offColor : (busy ? AppColors.accentRed : AppColors.accentGreen);

    const pinW = 30.0, pinH = 38.0;

    return Column(
      // Bottom-aligned so the pointer tip is the very bottom of the marker box.
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 108),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.card(context).withOpacity(0.92),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: off ? AppColors.textMuted(context) : AppColors.textMain(context),
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: pinW,
          height: pinH,
          child: Opacity(
            opacity: off ? 0.7 : 1,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(
                  size: const Size(pinW, pinH),
                  painter: _PinPainter(fill: color, selected: selected),
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: pinW,
                  child: Center(
                    child: Icon(Icons.shield_outlined, color: Colors.white, size: 15),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Numbered pin for a group of nearby tanod. If everyone in the group is
/// off / no signal it is grey (all sharing off or a mix) or amber (all lost
/// signal). Otherwise coloured by the tanod who ARE reporting: green all
/// available, red all busy, orange a mix.
class _ClusterMarker extends StatelessWidget {
  final int count;
  final int busyCount;
  final int offCount;

  /// How many of the [offCount] are "no signal" (sharing on, stale fix)
  /// rather than "sharing turned off".
  final int noSignalCount;

  const _ClusterMarker({
    required this.count,
    required this.busyCount,
    this.offCount = 0,
    this.noSignalCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final active = count - offCount;
    final Color color;
    if (active == 0) {
      color = (noSignalCount > 0 && noSignalCount == offCount)
          ? _kNoSignalColor
          : Colors.grey;
    } else if (busyCount == 0) {
      color = AppColors.accentGreen;
    } else if (busyCount == active) {
      color = AppColors.accentRed;
    } else {
      color = AppColors.accentOrange;
    }

    const pinW = 40.0, pinH = 48.0;
    return SizedBox(
      width: pinW,
      height: pinH,
      child: Stack(
        children: [
          CustomPaint(
            size: const Size(pinW, pinH),
            painter: _PinPainter(fill: color, borderWidth: 3),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: pinW,
            child: Center(
              child: Text(
                count > 99 ? '99+' : '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// SCREEN
// ============================================================================

class PurokLeaderMapScreen extends StatefulWidget {
  final bool isActive;
  const PurokLeaderMapScreen({super.key, required this.isActive});

  @override
  State<PurokLeaderMapScreen> createState() => _PurokLeaderMapScreenState();
}

class _PurokLeaderMapScreenState extends State<PurokLeaderMapScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final MapController _mapController = MapController();
  bool _mapReady = false;
  bool _didInitialFit = false;
  double _zoom = 14;

  String? _myPurok;
  bool _loadingRoster = true;
  List<_TanodProfile> _roster = [];
  late Set<String> _rosterIds = {};

  StreamSubscription<List<Map<String, dynamic>>>? _gpsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _dispatchSub;
  StreamSubscription<List<Map<String, dynamic>>>? _requestSub;

  // Re-evaluates "stale" every 30 s even if no new rows arrive.
  Timer? _staleTimer;

  final Map<String, _TanodFix> _fixes = {};
  Set<String> _busyIds = {};

  final Map<String, _IncidentPin> _pins = {};
  final Set<String> _completedRequestIds = {};
  final Map<String, String> _incidentAlertType = {};
  final Map<String, Map<String, dynamic>> _cameraRaw = {};

  String? _selectedTanodId;
  String? _selectedRequestId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant PurokLeaderMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _startSubscriptions();
    if (!widget.isActive && oldWidget.isActive) _stopSubscriptions();
  }

  @override
  void dispose() {
    _stopSubscriptions();
    super.dispose();
  }

  Future<void> _init() async {
    await _loadRoster();
    if (widget.isActive) _startSubscriptions();
  }

  Future<void> _loadRoster() async {
    final userId = _supabase.auth.currentUser?.id ?? '';
    try {
      final profileRow =
          await _supabase.from('profiles').select('purok').eq('id', userId).maybeSingle();
      final purok = (profileRow?['purok'] as String?)?.trim();
      if (purok == null || purok.isEmpty) {
        if (mounted) setState(() => _loadingRoster = false);
        return;
      }
      final rows = await _supabase
          .from('profiles')
          .select('id, first_name, last_name')
          .eq('purok', purok)
          .eq('role', _kTanodRole);
      final roster = (rows as List)
          .map((r) => _TanodProfile.fromMap(r as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.fullName.compareTo(b.fullName));
      if (!mounted) return;
      setState(() {
        _myPurok = purok;
        _roster = roster;
        _rosterIds = roster.map((t) => t.id).toSet();
        _loadingRoster = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingRoster = false);
    }
  }

  void _startSubscriptions() {
    if (_rosterIds.isEmpty) return;
    final userId = _supabase.auth.currentUser?.id ?? '';

    _gpsSub ??= _supabase.from('live_gps').stream(primaryKey: ['member_id']).listen(_handleGpsRows);

    _dispatchSub ??=
        _supabase.from('tanod_dispatches').stream(primaryKey: ['id']).listen(_handleDispatchRows);

    _requestSub ??= _supabase
        .from('dispatch_requests')
        .stream(primaryKey: ['id'])
        .eq('leader_id', userId)
        .listen(_handleRequestRows);

    _staleTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stopSubscriptions() {
    _gpsSub?.cancel();
    _dispatchSub?.cancel();
    _requestSub?.cancel();
    _staleTimer?.cancel();
    _gpsSub = null;
    _dispatchSub = null;
    _requestSub = null;
    _staleTimer = null;
  }

  void _handleGpsRows(List<Map<String, dynamic>> rows) {
    // The stream emits the full table each time; rebuild so removed rows
    // (e.g. deleted on logout) disappear.
    final seen = <String>{};
    for (final row in rows) {
      final memberId = row['member_id']?.toString();
      if (memberId == null || !_rosterIds.contains(memberId)) continue;
      final lat = (row['latitude'] as num?)?.toDouble();
      final lng = (row['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      seen.add(memberId);
      // If updated_at is missing/unparseable, use epoch (=> stale) instead of
      // "now", so a bad row never looks fresh.
      final updatedAt = DateTime.tryParse(row['updated_at']?.toString() ?? '')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      _fixes[memberId] = _TanodFix(
        point: ll.LatLng(lat, lng),
        updatedAt: updatedAt,
        sharing: row['is_sharing'] != false,
      );
    }
    _fixes.removeWhere((id, _) => !seen.contains(id));
    if (mounted) setState(() {});
    _fitMapIfNeeded();
  }

  void _handleDispatchRows(List<Map<String, dynamic>> rows) {
    final busy = <String>{};
    final assignedByRequest = <String, Set<String>>{};
    final leadByRequest = <String, String?>{};
    for (final row in rows) {
      final status = (row['status'] ?? '').toString();
      final memberIds = ((row['member_ids'] as List?) ?? []).map((e) => e.toString()).toSet();
      if (status != _kCompletedStatus) busy.addAll(memberIds);

      final requestId = row['dispatch_request_id']?.toString();
      if (requestId != null) {
        if (status == _kCompletedStatus) {
          _completedRequestIds.add(requestId);
          continue;
        }
        _completedRequestIds.remove(requestId);
        assignedByRequest[requestId] = memberIds;
        leadByRequest[requestId] = row['team_lead_id']?.toString();
      }
    }
    _busyIds = busy;
    _pins.removeWhere((id, _) => _completedRequestIds.contains(id));
    if (_selectedRequestId != null && !_pins.containsKey(_selectedRequestId)) {
      _selectedRequestId = null;
    }
    for (final entry in assignedByRequest.entries) {
      final pin = _pins[entry.key];
      if (pin != null) {
        _pins[entry.key] =
            pin.copyWith(assignedTanodIds: entry.value, teamLeadId: leadByRequest[entry.key]);
      }
    }
    if (mounted) setState(() {});
  }

  void _handleRequestRows(List<Map<String, dynamic>> rows) async {
    final keepIds = <String>{};
    for (final row in rows) {
      final status = (row['status'] ?? '').toString();
      final requestId = row['id'].toString();
      if (status == _kCompletedStatus) _completedRequestIds.add(requestId);
      if (status != 'pending' && status != 'dispatched') continue;
      if (_completedRequestIds.contains(requestId)) continue;
      final incidentId = row['incident_id'].toString();
      final cameraId = row['camera_id'].toString();
      keepIds.add(requestId);

      await _ensureIncidentAndCamera(incidentId, cameraId);
      if (!mounted) return;

      final cameraRow = _cameraRaw[cameraId];
      final lat = (cameraRow?['latitude'] as num?)?.toDouble();
      final lng = (cameraRow?['longitude'] as num?)?.toDouble();
      final location = (cameraRow?['location'] as String?)?.trim();
      final name = (cameraRow?['name'] as String?)?.trim();

      final existing = _pins[requestId];
      _pins[requestId] = _IncidentPin(
        requestId: requestId,
        alertType: _incidentAlertType[incidentId] ?? '',
        cameraLocation: (location != null && location.isNotEmpty) ? location : name,
        latitude: lat,
        longitude: lng,
        status: status,
        assignedTanodIds: existing?.assignedTanodIds ?? const {},
        teamLeadId: existing?.teamLeadId,
      );
    }
    _pins.removeWhere((id, _) => !keepIds.contains(id));
    if (_selectedRequestId != null && !_pins.containsKey(_selectedRequestId)) {
      _selectedRequestId = null;
    }
    if (mounted) setState(() {});
    _fitMapIfNeeded();
  }

  Future<void> _ensureIncidentAndCamera(String incidentId, String cameraId) async {
    final needsIncident = !_incidentAlertType.containsKey(incidentId);
    final needsCamera = !_cameraRaw.containsKey(cameraId);
    if (!needsIncident && !needsCamera) return;
    try {
      if (needsIncident) {
        final row = await _supabase
            .from('incidents')
            .select('alert_type')
            .eq('id', incidentId)
            .maybeSingle();
        _incidentAlertType[incidentId] = (row?['alert_type'] ?? '').toString();
      }
      if (needsCamera) {
        final row = await _supabase.from('cameras').select().eq('id', cameraId).maybeSingle();
        if (row != null) _cameraRaw[cameraId] = row;
      }
    } catch (_) {}
  }

  // --- Map framing -------------------------------------------------------

  void _onMapReady() {
    _mapReady = true;
    _zoom = _mapController.camera.zoom;
    if (_allPoints.isEmpty) _fitPoints(const []);
    _fitMapIfNeeded();
  }

  List<ll.LatLng> get _allPoints => [
        ..._fixes.values.map((f) => f.point),
        ..._pins.values.where((p) => p.hasLocation).map((p) => ll.LatLng(p.latitude!, p.longitude!)),
      ];

  void _fitPoints(List<ll.LatLng> points) {
    if (points.isEmpty) {
      if (BarangayBoundary.points.isEmpty) return;
      points = BarangayBoundary.points;
    }
    if (points.length == 1) {
      _mapController.move(points.first, 16);
    } else {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.all(64),
          maxZoom: 17,
        ),
      );
    }
  }

  void _fitMapIfNeeded() {
    if (!_mapReady || _didInitialFit) return;
    final points = _allPoints;
    if (points.isEmpty) return;
    _didInitialFit = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady) return;
      _fitPoints(points);
    });
  }

  void _recenter() => _fitPoints(_allPoints);

  void _onTanodTap(_TanodProfile tanod) {
    final fix = _fixes[tanod.id];
    HapticFeedback.selectionClick();
    setState(() {
      _selectedTanodId = tanod.id;
      _selectedRequestId = null;
    });
    if (fix != null && _mapReady) {
      _mapController.move(fix.point, math.max(_mapController.camera.zoom, 17));
    }
  }

  void _onPinTap(_IncidentPin pin) {
    HapticFeedback.selectionClick();
    setState(() {
      _selectedRequestId = pin.requestId;
      _selectedTanodId = null;
    });
    if (pin.hasLocation && _mapReady) {
      _mapController.move(
          ll.LatLng(pin.latitude!, pin.longitude!), math.max(_mapController.camera.zoom, 16));
    }
  }

  void _clearSelection() => setState(() {
        _selectedTanodId = null;
        _selectedRequestId = null;
      });

  _TanodProfile? get _selectedTanod {
    if (_selectedTanodId == null) return null;
    for (final t in _roster) {
      if (t.id == _selectedTanodId) return t;
    }
    return null;
  }

  _TanodProfile? _tanodById(String id) {
    for (final t in _roster) {
      if (t.id == id) return t;
    }
    return null;
  }

  _IncidentPin? get _selectedPin => _selectedRequestId == null ? null : _pins[_selectedRequestId];

  _IncidentPin? _pinForTanod(String tanodId) {
    for (final p in _pins.values) {
      if (p.assignedTanodIds.contains(tanodId)) return p;
    }
    return null;
  }

  // --- Clustering -------------------------------------------------------------

  ({double x, double y}) _worldPx(ll.LatLng p, double zoom) {
    final scale = 256 * math.pow(2, zoom).toDouble();
    final sinLat = math.sin(p.latitude * math.pi / 180).clamp(-0.9999, 0.9999).toDouble();
    return (
      x: (p.longitude + 180) / 360 * scale,
      y: (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * scale,
    );
  }

  Marker _singleTanodMarker(_TanodProfile tanod) {
    final fix = _fixes[tanod.id]!;
    return Marker(
      point: fix.point,
      width: 112,
      height: 66,
      alignment: Alignment.topCenter,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTanodTap(tanod),
        child: _TanodMarker(
          initials: tanod.initials,
          label: tanod.shortName,
          busy: _busyIds.contains(tanod.id),
          selected: _selectedTanodId == tanod.id,
          off: fix.isOff,
          noSignal: fix.isNoSignal,
        ),
      ),
    );
  }

  /// Groups nearby tanod into numbered bubbles at low zoom, regardless of
  /// status (available / busy / location off / no signal). Only the selected
  /// tanod is kept out of a group so it stays visible.
  List<Marker> _tanodMarkers() {
    final visible = [
      for (final t in _roster)
        if (_fixes[t.id] != null) t,
    ];
    final zoom = (_zoom * 2).floor() / 2;
    if (zoom >= _kClusterOffZoom) return visible.map(_singleTanodMarker).toList();

    final cells = <String, List<_TanodProfile>>{};
    _TanodProfile? selected;
    for (final t in visible) {
      if (t.id == _selectedTanodId) {
        selected = t;
        continue;
      }
      final w = _worldPx(_fixes[t.id]!.point, zoom);
      final key = '${(w.x / _kClusterCellPx).floor()}:${(w.y / _kClusterCellPx).floor()}';
      cells.putIfAbsent(key, () => []).add(t);
    }

    final markers = <Marker>[];
    for (final group in cells.values) {
      if (group.length == 1) {
        markers.add(_singleTanodMarker(group.first));
        continue;
      }
      var lat = 0.0, lng = 0.0;
      for (final t in group) {
        lat += _fixes[t.id]!.point.latitude;
        lng += _fixes[t.id]!.point.longitude;
      }
      final off = group.where((t) => _fixes[t.id]!.isOff).length;
      final noSig = group.where((t) => _fixes[t.id]!.isNoSignal).length;
      final busy = group
          .where((t) => !_fixes[t.id]!.isOff && _busyIds.contains(t.id))
          .length;
      markers.add(Marker(
        point: ll.LatLng(lat / group.length, lng / group.length),
        width: 48,
        height: 48,
        alignment: Alignment.topCenter,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _onClusterTap(group),
          child: _ClusterMarker(
            count: group.length,
            busyCount: busy,
            offCount: off,
            noSignalCount: noSig,
          ),
        ),
      ));
    }
    if (selected != null) markers.add(_singleTanodMarker(selected));
    return markers;
  }

  void _onClusterTap(List<_TanodProfile> group) {
    HapticFeedback.selectionClick();
    final points = [for (final t in group) _fixes[t.id]!.point];
    final bounds = LatLngBounds.fromPoints(points);
    final tiny = (bounds.north - bounds.south).abs() < 1e-6 &&
        (bounds.east - bounds.west).abs() < 1e-6;
    if (tiny) {
      _mapController.move(points.first, _kClusterOffZoom + 0.5);
      return;
    }
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(72),
        maxZoom: _kClusterOffZoom + 0.5,
      ),
    );
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loadingRoster) {
      return Container(
        color: AppColors.bg(context),
        child: Center(child: CircularProgressIndicator(color: AppColors.accentBlue)),
      );
    }
    if (_myPurok == null) {
      return Container(
        color: AppColors.bg(context),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              "Your profile has no purok set — can't load a tanod map.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
            ),
          ),
        ),
      );
    }

    final selectedTanod = _selectedTanod;
    final selectedPin = _selectedPin;

    return Container(
      color: AppColors.bg(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: BarangayBoundary.points.isNotEmpty
                    ? BarangayBoundary.points.first
                    : const ll.LatLng(14.6091, 121.0223),
                initialZoom: 14,
                minZoom: 13,
                maxZoom: 19,
                onMapReady: _onMapReady,
                onTap: (_, __) => _clearSelection(),
                onPositionChanged: (camera, _) {
                  if ((camera.zoom * 2).floor() != (_zoom * 2).floor()) {
                    _zoom = camera.zoom;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() {});
                    });
                  }
                },
              ),
              children: [
                // MAP THEME: shared light/dark basemap + barangay boundary.
                ThemedMapLayers.tileLayer(
                  context,
                  userAgentPackageName: 'com.barangay.task_force',
                ),
                if (ThemedMapLayers.hasBoundary) ThemedMapLayers.boundaryLayer(context),
                MarkerLayer(markers: [
                  ..._tanodMarkers(),
                  for (final pin in _pins.values)
                    if (pin.hasLocation)
                      Marker(
                        point: ll.LatLng(pin.latitude!, pin.longitude!),
                        width: 48,
                        height: 48,
                        child: GestureDetector(
                          onTap: () => _onPinTap(pin),
                          child: _Pin(
                            icon: _incidentIcon(pin.alertType),
                            color: AppColors.accentRed,
                            selected: _selectedRequestId == pin.requestId,
                          ),
                        ),
                      ),
                ]),
              ],
            ),
          ),

          _legend(),

          Positioned(
            right: 12,
            top: 12,
            child: FloatingActionButton.small(
              heroTag: 'recenter_leader_overview',
              backgroundColor: AppColors.card(context),
              foregroundColor: AppColors.accentBlue,
              onPressed: _recenter,
              child: const Icon(Icons.center_focus_strong),
            ),
          ),

          if (_fixes.isEmpty && _pins.isEmpty)
            Positioned(
              left: 24,
              right: 24,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.card(context).withOpacity(0.96),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border(context)),
                  ),
                  child: Text(
                    'No tanod are currently reporting their location, and there are no active incidents.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5),
                  ),
                ),
              ),
            ),

          if (selectedTanod != null) _tanodPanel(selectedTanod),
          if (selectedPin != null) _incidentPanel(selectedPin),
        ],
      ),
    );
  }

  // --- Legend ---------------------------------------------------------------

  Widget _legendDot(Color color, String label, {IconData? icon}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, size: 9, color: Colors.white),
          )
        else
          Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        SizedBox(width: icon != null ? 4 : 6),
        Text(label, style: TextStyle(color: AppColors.textMain(context), fontSize: 11)),
      ],
    );
  }

  Widget _legend() {
    return Positioned(
      top: 12,
      left: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.card(context).withOpacity(0.94),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _legendDot(AppColors.accentGreen, 'Available'),
            const SizedBox(height: 4),
            _legendDot(AppColors.accentRed, 'On active dispatch'),
            const SizedBox(height: 4),
            _legendDot(Colors.grey, 'Location off', icon: Icons.location_off),
            const SizedBox(height: 4),
            _legendDot(_kNoSignalColor, 'No signal', icon: Icons.signal_wifi_off),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.location_on, size: 11, color: AppColors.accentRed),
                const SizedBox(width: 4),
                Text('Incident',
                    style: TextStyle(color: AppColors.textMain(context), fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- Bottom panels ---------------------------------------------------------

  Widget _panelShell({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    final mq = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.4),
        padding: EdgeInsets.fromLTRB(16, 14, 16, 10 + mq.padding.bottom),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border.all(color: AppColors.border(context)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 14)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: AppColors.textMain(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 14,
                        fontWeight: FontWeight.w800),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: _clearSelection,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 20, color: AppColors.textMuted(context)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(child: SingleChildScrollView(child: child)),
          ],
        ),
      ),
    );
  }

  Widget _tanodPanel(_TanodProfile t) {
    final busy = _busyIds.contains(t.id);
    final fix = _fixes[t.id];
    final sharingOff = fix != null && fix.isSharingOff;
    final noSignal = fix != null && fix.isNoSignal;
    final off = sharingOff || noSignal;
    final Color offColor = noSignal ? _kNoSignalColor : Colors.grey;
    final Color statusColor =
        off ? offColor : (busy ? AppColors.accentRed : AppColors.accentGreen);
    final pin = _pinForTanod(t.id);
    double? d;
    if (fix != null && pin != null && pin.hasLocation) {
      d = _straightLineKm(fix.point, ll.LatLng(pin.latitude!, pin.longitude!));
    }

    final String subtitle;
    if (fix == null) {
      subtitle = 'No GPS signal';
    } else if (sharingOff) {
      subtitle = 'Turned off location sharing • last seen ${_relativeTime(fix.updatedAt)}';
    } else if (noSignal) {
      subtitle = 'Lost signal • last seen ${_relativeTime(fix.updatedAt)}';
    } else {
      subtitle = [
        if (busy && pin != null)
          'Responding to ${_titleCase(pin.alertType.isEmpty ? 'incident' : pin.alertType)}',
        if (d != null) '${_formatDistance(d)} from incident',
        'updated ${_relativeTime(fix.updatedAt)}',
      ].join(' • ');
    }

    return _panelShell(
      icon: Icons.person_pin_circle_outlined,
      title: 'Tanod',
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.sunken(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration:
                  BoxDecoration(color: statusColor.withOpacity(0.15), shape: BoxShape.circle),
              alignment: Alignment.center,
              child: off
                  ? Icon(noSignal ? Icons.signal_wifi_off : Icons.location_off,
                      size: 18, color: statusColor)
                  : Text(t.initials,
                      style: TextStyle(
                          color: statusColor, fontSize: 12.5, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(t.fullName,
                            style: TextStyle(
                                color: AppColors.textMain(context),
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 6),
                      if (sharingOff)
                        _pill('LOCATION OFF', Colors.grey, icon: Icons.location_off)
                      else if (noSignal)
                        _pill('NO SIGNAL', _kNoSignalColor, icon: Icons.signal_wifi_off)
                      else if (busy)
                        _pill('ON DISPATCH', AppColors.accentRed,
                            icon: Icons.notifications_active)
                      else
                        _pill('AVAILABLE', AppColors.accentGreen,
                            icon: Icons.check_circle_outline),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                        color: fix == null
                            ? AppColors.accentOrange
                            : AppColors.textMuted(context),
                        fontSize: 11.5),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _incidentPanel(_IncidentPin pin) {
    final dispatched = pin.status == 'dispatched';
    final team = [
      for (final id in pin.assignedTanodIds) _tanodById(id),
    ].whereType<_TanodProfile>().toList()
      ..sort((a, b) {
        final aLead = a.id == pin.teamLeadId;
        final bLead = b.id == pin.teamLeadId;
        if (aLead != bLead) return aLead ? -1 : 1;
        return a.fullName.compareTo(b.fullName);
      });

    return _panelShell(
      icon: _incidentIcon(pin.alertType),
      title: pin.alertType.isEmpty ? 'Incident' : _titleCase(pin.alertType),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pin.cameraLocation != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.location_on, size: 16, color: AppColors.accentRed),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pin.cameraLocation!,
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              dispatched
                  ? _pill('DISPATCHED', AppColors.accentRed, icon: Icons.notifications_active)
                  : _pill('PENDING', AppColors.accentOrange, icon: Icons.hourglass_empty),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  dispatched
                      ? '${pin.assignedTanodIds.length} tanod assigned'
                      : 'Awaiting dispatch',
                  style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (team.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.sunken(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < team.length; i++)
                    _teamRow(team[i], team[i].id == pin.teamLeadId, isLast: i == team.length - 1),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text('Manage this request from the Requests tab.',
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
        ],
      ),
    );
  }

  Widget _teamRow(_TanodProfile member, bool isLead, {bool isLast = false}) {
    final accent = isLead ? AppColors.accentRed : AppColors.accentBlue;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: accent.withOpacity(0.15), shape: BoxShape.circle),
            child: Center(
              child: Text(member.initials,
                  style: TextStyle(color: accent, fontSize: 11.5, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              member.fullName,
              style: TextStyle(
                  color: AppColors.textMain(context), fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isLead) ...[
            const SizedBox(width: 8),
            _pill('LEAD', AppColors.accentRed, icon: Icons.star_outline),
          ],
        ],
      ),
    );
  }
}