import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../constants/app_colors.dart';
import '../../constants/barangay_boundary.dart';

const String _kTanodRole = 'Tanod'; // must match profiles.role exactly — confirmed from the table editor.

const _kPendingStatus = 'pending';
const _kDispatchedStatus = 'dispatched';
const _kCompletedStatus = 'completed';

const _kReportPendingReviewStatus = 'pending_review';
const _kReportSubmittedStatus = 'submitted';
const _kIncidentResolvedStatus = 'resolved';

// A fix older than this is treated as "no signal" even if is_sharing is true.
const Duration _kStaleAfter = Duration(minutes: 3);

/// Amber for "no signal" so it reads differently from grey (sharing turned
/// off) and from the orange used for mixed clusters.
const Color _kNoSignalColor = Color(0xFFFFB300);

/// A single row from `dispatch_requests` addressed to this leader.
class _DispatchRequestRow {
  final String id;
  final String incidentId;
  final String leaderId;
  final String cameraId;
  final double? distanceKm;
  final String status;
  final String? requestedBy;
  final String? responseNote;
  final DateTime? respondedAt;
  final DateTime createdAt;

  _DispatchRequestRow({
    required this.id,
    required this.incidentId,
    required this.leaderId,
    required this.cameraId,
    required this.distanceKm,
    required this.status,
    required this.requestedBy,
    required this.responseNote,
    required this.respondedAt,
    required this.createdAt,
  });

  factory _DispatchRequestRow.fromMap(Map<String, dynamic> row) => _DispatchRequestRow(
        id: row['id'].toString(),
        incidentId: row['incident_id'].toString(),
        leaderId: row['leader_id'].toString(),
        cameraId: row['camera_id'].toString(),
        distanceKm: (row['distance_km'] as num?)?.toDouble(),
        status: (row['status'] ?? _kPendingStatus).toString(),
        requestedBy: row['requested_by']?.toString(),
        responseNote: (row['response_note'] as String?)?.trim().isNotEmpty == true
            ? (row['response_note'] as String).trim()
            : null,
        respondedAt: row['responded_at'] == null
            ? null
            : DateTime.tryParse(row['responded_at'].toString())?.toLocal(),
        createdAt:
            DateTime.tryParse(row['created_at']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
      );
}

class _IncidentInfo {
  final String alertType;
  final String alertLevel;
  final String imagePath;
  final DateTime occurredAt;

  _IncidentInfo({
    required this.alertType,
    required this.alertLevel,
    required this.imagePath,
    required this.occurredAt,
  });

  factory _IncidentInfo.fromMap(Map<String, dynamic> row) => _IncidentInfo(
        alertType: (row['alert_type'] ?? '').toString(),
        alertLevel: (row['alert_level'] ?? '').toString(),
        imagePath: (row['image_path'] ?? '').toString(),
        occurredAt:
            DateTime.tryParse(row['occurred_at']?.toString() ?? '')?.toLocal() ??
                DateTime.now(),
      );

  String get imageUrl =>
      Supabase.instance.client.storage.from('incidents').getPublicUrl(imagePath);
}

class _CameraInfo {
  final String name;
  final String? location;
  final double? latitude;
  final double? longitude;

  _CameraInfo({
    required this.name,
    required this.location,
    required this.latitude,
    required this.longitude,
  });

  factory _CameraInfo.fromMap(Map<String, dynamic> row) => _CameraInfo(
        name: (row['name'] ?? 'Unknown camera').toString(),
        location: (row['location'] as String?)?.trim().isNotEmpty == true
            ? (row['location'] as String).trim()
            : null,
        latitude: (row['latitude'] as num?)?.toDouble(),
        longitude: (row['longitude'] as num?)?.toDouble(),
      );

  bool get hasLocation => latitude != null && longitude != null;
  String get displayLocation => location ?? name;
}

/// One selectable tanod in the assign-team roster.
class _TanodProfile {
  final String id;
  final String fullName;
  final String role;

  _TanodProfile({required this.id, required this.fullName, required this.role});

  factory _TanodProfile.fromMap(Map<String, dynamic> row) {
    final first = (row['first_name'] ?? '').toString().trim();
    final last = (row['last_name'] ?? '').toString().trim();
    final name = '$first $last'.trim();
    return _TanodProfile(
      id: row['id'].toString(),
      fullName: name.isEmpty ? 'Unnamed tanod' : name,
      role: (row['role'] ?? '').toString().trim(),
    );
  }

  /// "Juan Dela Cruz" -> "Juan C." — short enough for a map name tag.
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

/// A `tanod_dispatches` row this leader created, joined back via
/// `dispatch_request_id`.
class _AssignmentInfo {
  final String id;
  final String dispatchRequestId;
  final String? teamLeadId;
  final List<String> memberIds;
  final String status; // dispatched / en_route / completed (tanod_dispatches' own status)
  final DateTime dispatchedAt;

  _AssignmentInfo({
    required this.id,
    required this.dispatchRequestId,
    required this.teamLeadId,
    required this.memberIds,
    required this.status,
    required this.dispatchedAt,
  });

  factory _AssignmentInfo.fromMap(Map<String, dynamic> row) => _AssignmentInfo(
        id: row['id'].toString(),
        dispatchRequestId: (row['dispatch_request_id'] ?? '').toString(),
        teamLeadId: row['team_lead_id']?.toString(),
        memberIds:
            ((row['member_ids'] as List?) ?? []).map((e) => e.toString()).toList(),
        status: (row['status'] ?? _kDispatchedStatus).toString(),
        dispatchedAt:
            DateTime.tryParse(row['dispatched_at']?.toString() ?? '')?.toLocal() ??
                DateTime.now(),
      );
}

/// One structured category from a tanod report's `report_sections` jsonb —
/// either a one-line `value` or a bulleted `items` list. Mirrors
/// `_ReportSection` in TanodReportHistoryScreen so review cards here and
/// the eventual read-only history entry render identically.
class _ReviewSection {
  final String header;
  final String? value;
  final List<String> items;

  _ReviewSection({required this.header, required this.value, required this.items});

  factory _ReviewSection.fromMap(Map<String, dynamic> map) {
    final rawItems = map['items'];
    return _ReviewSection(
      header: (map['header'] ?? '').toString(),
      value: map['value'] as String?,
      items: rawItems is List ? rawItems.map((e) => e.toString()).toList() : const [],
    );
  }
}

/// An `incident_reports` row (source_type = 'tanod') filed against one of
/// this leader's `tanod_dispatches` assignments, resolved via
/// `source_id`. Once a report attaches to a bundle, that request's card
/// moves from the Active filter to the For Review filter — see
/// `_handleReportRows` and the `_review` getter below.
class _IncidentReportInfo {
  final String id;
  final String sourceId; // tanod_dispatches.id
  final String status;
  final List<_ReviewSection> sections;
  final String narrative;
  final String? outcome;
  final List<String> photoPaths;
  final DateTime submittedAt;

  _IncidentReportInfo({
    required this.id,
    required this.sourceId,
    required this.status,
    required this.sections,
    required this.narrative,
    required this.outcome,
    required this.photoPaths,
    required this.submittedAt,
  });

  factory _IncidentReportInfo.fromMap(Map<String, dynamic> row) {
    final rawSections = row['report_sections'];
    final sections = rawSections is List
        ? rawSections
            .whereType<Map>()
            .map((e) => _ReviewSection.fromMap(e.cast<String, dynamic>()))
            .toList()
        : <_ReviewSection>[];

    final rawPhotos = row['photo_paths'];
    final photoPaths = rawPhotos is List
        ? rawPhotos.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    return _IncidentReportInfo(
      id: row['id'].toString(),
      sourceId: (row['source_id'] ?? '').toString(),
      status: (row['status'] ?? _kReportPendingReviewStatus).toString(),
      sections: sections,
      narrative: (row['report_text'] ?? '').toString(),
      outcome: row['outcome'] as String?,
      photoPaths: photoPaths,
      submittedAt:
          DateTime.tryParse(row['submitted_at']?.toString() ?? '')?.toLocal() ??
              DateTime.now(),
    );
  }

  /// Local-only copy carrying a leader's edited narrative, applied right
  /// after a successful `_saveReportEdits` write so the review screen and
  /// card reflect the change immediately instead of waiting on the
  /// `incident_reports` realtime stream to catch up.
  _IncidentReportInfo copyWith({String? narrative}) => _IncidentReportInfo(
        id: id,
        sourceId: sourceId,
        status: status,
        sections: sections,
        narrative: narrative ?? this.narrative,
        outcome: outcome,
        photoPaths: photoPaths,
        submittedAt: submittedAt,
      );
}

/// Public URL for a photo stored under the `incident_report` bucket —
/// same bucket/convention TanodReportHistoryScreen uses. Swap for
/// `createSignedUrl` if that bucket is private.
String _reviewPhotoUrl(String path) =>
    Supabase.instance.client.storage.from('incident_report').getPublicUrl(path);

/// Maps a report's `outcome` to a color, matching the palette
/// TanodReportHistoryScreen already uses so a report looks the same
/// whether the leader is reviewing it here or reading it later in history.
Color _reviewOutcomeColor(BuildContext context, String? outcome) {
  switch (outcome) {
    case 'resolved':
      return AppColors.accentGreen;
    case 'escalated':
      return AppColors.accentRed;
    case 'false_alarm':
      return AppColors.accentOrange;
    case 'ongoing':
      return AppColors.accentBlue;
    case 'no_action_needed':
      return AppColors.accentPurple;
    default:
      return AppColors.accentBlue;
  }
}

String _reviewOutcomeLabel(String? outcome) {
  switch (outcome) {
    case 'resolved':
      return 'Resolved on scene';
    case 'escalated':
      return 'Escalated further';
    case 'false_alarm':
      return 'False alarm';
    case 'ongoing':
      return 'Ongoing — monitoring';
    case 'no_action_needed':
      return 'No action needed';
    default:
      return outcome ?? 'Unspecified';
  }
}

IconData _reviewOutcomeIcon(String? outcome) {
  switch (outcome) {
    case 'resolved':
      return Icons.check_circle_outline;
    case 'escalated':
      return Icons.arrow_upward;
    case 'false_alarm':
      return Icons.info_outline;
    case 'ongoing':
      return Icons.autorenew;
    case 'no_action_needed':
      return Icons.remove_circle_outline;
    default:
      return Icons.help_outline;
  }
}

/// Same loose keyword match TanodReportHistoryScreen uses to pick an
/// icon/color per report section header, kept in sync so a section reads
/// identically here and in history.
({IconData icon, Color color}) _reviewSectionMeta(String header) {
  final h = header.toLowerCase();
  if (h.contains('individual') || h.contains('suspect') || h.contains('witness')) {
    return (icon: Icons.people_outline, color: AppColors.accentBlue);
  }
  if (h.contains('injur') || h.contains('casualt') || h.contains('medical')) {
    return (icon: Icons.medical_services_outlined, color: AppColors.accentRed);
  }
  if (h.contains('weapon')) {
    return (icon: Icons.gpp_maybe_outlined, color: AppColors.accentOrange);
  }
  if (h.contains('propert') || h.contains('damage')) {
    return (icon: Icons.home_repair_service_outlined, color: AppColors.accentOrange);
  }
  if (h.contains('vehicle')) {
    return (icon: Icons.directions_car_outlined, color: AppColors.accentBlue);
  }
  if (h.contains('fire')) {
    return (icon: Icons.local_fire_department_outlined, color: AppColors.accentOrange);
  }
  if (h.contains('evidence')) {
    return (icon: Icons.fact_check_outlined, color: AppColors.accentPurple);
  }
  if (h.contains('action') || h.contains('response') || h.contains('outcome')) {
    return (icon: Icons.task_alt_outlined, color: AppColors.accentGreen);
  }
  if (h.contains('time') || h.contains('duration')) {
    return (icon: Icons.schedule_outlined, color: AppColors.accentBlue);
  }
  return (icon: Icons.description_outlined, color: AppColors.accentBlue);
}

/// Everything the UI needs for one card: the request itself, its incident +
/// camera context, and — once tanod are assigned — the live assignment and
/// resolved team member profiles, plus (once filed) the incident report
/// waiting for this leader's review. Rebuilt in place as realtime rows
/// patch in, so acting on one card never disturbs another card's state.
class _RequestBundle {
  final _DispatchRequestRow request;
  final _IncidentInfo? incident;
  final _CameraInfo? camera;
  final _AssignmentInfo? assignment;
  final List<_TanodProfile> team;
  final _IncidentReportInfo? report;

  _RequestBundle({
    required this.request,
    required this.incident,
    required this.camera,
    required this.assignment,
    required this.team,
    this.report,
  });

  _RequestBundle copyWith({
    _DispatchRequestRow? request,
    _IncidentInfo? incident,
    _CameraInfo? camera,
    Object? assignment = _unset,
    List<_TanodProfile>? team,
    Object? report = _unset,
  }) {
    return _RequestBundle(
      request: request ?? this.request,
      incident: incident ?? this.incident,
      camera: camera ?? this.camera,
      assignment: identical(assignment, _unset) ? this.assignment : assignment as _AssignmentInfo?,
      team: team ?? this.team,
      report: identical(report, _unset) ? this.report : report as _IncidentReportInfo?,
    );
  }

  static const _unset = Object();
}

// ============================================================================
// THEMED BASEMAP + BOUNDARY + CLUSTER BUBBLE (shared by the dispatch maps)
// ============================================================================

// Tanod within the same cell (px) at the current zoom merge into one bubble.
// At/above _kClusterOffZoom everyone is shown individually.
const double _kClusterCellPx = 64;
const double _kClusterOffZoom = 18;

const List<ll.LatLng> _maskOuterRing = [
  ll.LatLng(-85, -180),
  ll.LatLng(-85, 180),
  ll.LatLng(85, 180),
  ll.LatLng(85, -180),
];

const List<double> _lightSaturationMatrix = <double>[
  0.68504, 0.28608, 0.02888, 0, 0,
  0.08504, 0.88608, 0.02888, 0, 0,
  0.08504, 0.28608, 0.62888, 0, 0,
  0, 0, 0, 1, 0,
];
const List<double> _grayscaleMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];
const List<double> _invertMatrix = <double>[
  -1, 0, 0, 0, 255,
  0, -1, 0, 0, 255,
  0, 0, -1, 0, 255,
  0, 0, 0, 1, 0,
];
const List<double> _duotoneMatrix = <double>[
  0.4941, 0, 0, 0, 22,
  0, 0.5137, 0, 0, 32,
  0, 0, 0.5412, 0, 46,
  0, 0, 0, 1, 0,
];

Widget _themedTileLayer(bool isDark) {
  final tiles = TileLayer(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    userAgentPackageName: 'com.barangay.task_force',
  );
  if (!isDark) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_lightSaturationMatrix),
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(Colors.white.withOpacity(0.04), BlendMode.screen),
        child: tiles,
      ),
    );
  }
  return ColorFiltered(
    colorFilter: const ColorFilter.matrix(_duotoneMatrix),
    child: ColorFiltered(
      colorFilter: const ColorFilter.matrix(_invertMatrix),
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(_grayscaleMatrix),
        child: tiles,
      ),
    ),
  );
}

/// Dimmed area outside the barangay + blue boundary outline.
List<Widget> _boundaryLayers(BuildContext context) {
  if (BarangayBoundary.points.isEmpty) return const [];
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return [
    PolygonLayer(
      polygons: [
        Polygon(
          points: _maskOuterRing,
          holePointsList: [BarangayBoundary.points],
          color: AppColors.bg(context).withOpacity(isDark ? 0.90 : 0.80),
          isFilled: true,
        ),
        Polygon(
          points: BarangayBoundary.points,
          color: Colors.transparent,
          borderColor: AppColors.accentBlue,
          borderStrokeWidth: 3,
          isFilled: false,
        ),
      ],
    ),
  ];
}

/// Web-mercator world pixel position at [zoom] (256px tiles, like OSM).
({double x, double y}) _worldPx(ll.LatLng p, double zoom) {
  final scale = 256 * math.pow(2, zoom).toDouble();
  final sinLat = math.sin(p.latitude * math.pi / 180).clamp(-0.9999, 0.9999).toDouble();
  return (
    x: (p.longitude + 180) / 360 * scale,
    y: (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * scale,
  );
}

/// Numbered bubble for a group of nearby tanod. If everyone in the group is
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
      color = (noSignalCount > 0 && noSignalCount == offCount) ? _kNoSignalColor : Colors.grey;
    } else if (busyCount == 0) {
      color = AppColors.accentGreen;
    } else if (busyCount == active) {
      color = AppColors.accentRed;
    } else {
      color = AppColors.accentOrange;
    }
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 6)],
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _Pin({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 4)],
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

class _DispatchMapScreen extends StatefulWidget {
  final _CameraInfo camera;
  final String title;
  final String? subtitle;
  final IconData incidentIcon;

  /// When set, the map shows a dispatch bar so the leader can assign
  /// tanod straight from the map. Returns true when the dispatch succeeded.
  final Future<bool> Function(_AssignSelection selection)? onDispatch;

  final List<_TanodProfile> roster;
  final Set<String> assignedIds;
  final Set<String> busyIds;

  final bool trackAssignedTeam;
  final String? teamLeadId;

  const _DispatchMapScreen({
    required this.camera,
    required this.title,
    this.subtitle,
    this.incidentIcon = Icons.warning_amber_rounded,
    this.onDispatch,
    this.roster = const [],
    this.assignedIds = const {},
    this.busyIds = const {},
    this.trackAssignedTeam = false,
    this.teamLeadId,
  });

  @override
  State<_DispatchMapScreen> createState() => _DispatchMapScreenState();
}

class _DispatchMapScreenState extends State<_DispatchMapScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final MapController _mapController = MapController();
  bool _mapReady = false;

  final Map<String, _TanodFix> _tanodFixes = {};
  StreamSubscription<List<Map<String, dynamic>>>? _gpsSub;
  // Re-evaluates "stale" every 30 s even if no new rows arrive.
  Timer? _staleTimer;
  String? _selectedTanodId;
  late final Set<String> _rosterIds = widget.roster.map((t) => t.id).toSet();

  @override
  void initState() {
    super.initState();
    if (_rosterIds.isNotEmpty) {
      _gpsSub = _supabase
          .from('live_gps')
          .stream(primaryKey: ['member_id'])
          .listen(_handleGpsRows);
      _staleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _staleTimer?.cancel();
    super.dispose();
  }

  void _handleGpsRows(List<Map<String, dynamic>> rows) {
    final seen = <String>{};
    for (final row in rows) {
      final memberId = row['member_id']?.toString();
      if (memberId == null || !_rosterIds.contains(memberId)) continue;
      final lat = (row['latitude'] as num?)?.toDouble();
      final lng = (row['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      seen.add(memberId);
      // Missing/unparseable updated_at => epoch (stale), never "fresh".
      final updatedAt = DateTime.tryParse(row['updated_at']?.toString() ?? '')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      _tanodFixes[memberId] = _TanodFix(
        point: ll.LatLng(lat, lng),
        updatedAt: updatedAt,
        sharing: row['is_sharing'] != false,
      );
    }
    _tanodFixes.removeWhere((id, _) => !seen.contains(id));

    // A tanod who turned location sharing off after being picked can no
    // longer be dispatched — drop them from the selection.
    if (_canDispatch) {
      _pickIds.removeWhere((id) => _tanodFixes[id]?.isSharingOff == true);
    }

    if (mounted) setState(() {});
    if (!_fittedToTanods && _tanodFixes.isNotEmpty) {
      _fittedToTanods = true;
      _fitMap();
    }
  }

  double? _distanceToCameraKm(ll.LatLng point) {
    if (!widget.camera.hasLocation) return null;
    const earthRadiusKm = 6371.0;
    double degToRad(double d) => d * (math.pi / 180);
    final b = ll.LatLng(widget.camera.latitude!, widget.camera.longitude!);
    final dLat = degToRad(b.latitude - point.latitude);
    final dLng = degToRad(b.longitude - point.longitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(degToRad(point.latitude)) *
            math.cos(degToRad(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadiusKm * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  /// Roster members with no `live_gps` row yet — they can't be shown on
  /// the map, so the dispatch bar tells the leader how many are hidden.
  int get _offlineCount => widget.roster.where((t) => _tanodFixes[t.id] == null).length;

  String _formatDistance(double km) =>
      km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km';

  // --- Clustering (dispatch map) ------------------------------------------

  double _zoom = 16;

  void _onCameraMoved(MapCamera camera, bool hasGesture) {
    // Only re-group when zoom crosses a half-level step.
    if ((camera.zoom * 2).floor() != (_zoom * 2).floor()) {
      _zoom = camera.zoom;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Marker _singleTanodMarker(_TanodProfile tanod) => Marker(
        point: _tanodFixes[tanod.id]!.point,
        width: 150, // wide enough for "Name X. NO SIGNAL" without truncation
        height: 80, // circle stays centred on the GPS point; name tag sits below
        child: GestureDetector(
          onTap: () => _onTanodTap(tanod),
          child: _TanodMarker(
            initials: tanod.initials,
            label: tanod.shortName,
            busy: widget.busyIds.contains(tanod.id),
            selected: _pickIds.contains(tanod.id),
            assigned: widget.assignedIds.contains(tanod.id) || _pickIds.contains(tanod.id),
            off: _tanodFixes[tanod.id]!.isOff,
            noSignal: _tanodFixes[tanod.id]!.isNoSignal,
          ),
        ),
      );

  /// Groups nearby tanod into numbered bubbles at low zoom. Tanod the leader
  /// already picked are never absorbed, so the selection stays visible.
  List<Marker> _clusteredTanodMarkers() {
    final visible = [
      for (final t in widget.roster)
        if (_tanodFixes[t.id] != null) t,
    ];
    final zoom = (_zoom * 2).floor() / 2;
    if (zoom >= _kClusterOffZoom) return visible.map(_singleTanodMarker).toList();

    final cells = <String, List<_TanodProfile>>{};
    final pinned = <_TanodProfile>[];
    for (final t in visible) {
      if (_pickIds.contains(t.id)) {
        pinned.add(t);
        continue;
      }
      final w = _worldPx(_tanodFixes[t.id]!.point, zoom);
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
        lat += _tanodFixes[t.id]!.point.latitude;
        lng += _tanodFixes[t.id]!.point.longitude;
      }
      final off = group.where((t) => _tanodFixes[t.id]!.isOff).length;
      final noSig = group.where((t) => _tanodFixes[t.id]!.isNoSignal).length;
      final busy = group
          .where((t) => !_tanodFixes[t.id]!.isOff && widget.busyIds.contains(t.id))
          .length;
      markers.add(Marker(
        point: ll.LatLng(lat / group.length, lng / group.length),
        width: 48,
        height: 48,
        child: GestureDetector(
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
    markers.addAll(pinned.map(_singleTanodMarker));
    return markers;
  }

  void _onClusterTap(List<_TanodProfile> group) {
    HapticFeedback.selectionClick();
    final points = [for (final t in group) _tanodFixes[t.id]!.point];
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

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: AppColors.textMain(context), fontSize: 11)),
      ],
    );
  }

  void _onMapReady() {
    _mapReady = true;
    _zoom = _mapController.camera.zoom;
    _fitMap();
  }

  bool _fittedToTanods = false;

  /// Simple map: frame the incident plus the nearest few tanod.
  void _fitSimple() {
    if (!widget.camera.hasLocation) return;
    final cam = ll.LatLng(widget.camera.latitude!, widget.camera.longitude!);
    final nearby = <MapEntry<ll.LatLng, double>>[];
    for (final t in widget.roster) {
      final fix = _tanodFixes[t.id];
      if (fix == null) continue;
      nearby.add(MapEntry(fix.point, _distanceToCameraKm(fix.point) ?? 0));
    }
    nearby.sort((a, b) => a.value.compareTo(b.value));
    final points = [cam, ...nearby.take(5).map((e) => e.key)];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady) return;
      if (points.length == 1) {
        _mapController.move(cam, 16);
      } else {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(64),
            maxZoom: 17,
          ),
        );
      }
    });
  }

  void _fitMap() {
    if (!_mapReady) return;
    if (!widget.trackAssignedTeam) {
      _fitSimple();
      return;
    }
    if (!widget.camera.hasLocation) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady) return;
      final cam = ll.LatLng(widget.camera.latitude!, widget.camera.longitude!);
      // Only the dispatched team is in `_tanodFixes` (roster = team).
      final points = [
        cam,
        for (final fix in _tanodFixes.values) fix.point,
      ];
      if (points.length == 1) {
        _mapController.move(cam, 16);
      } else {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            // Extra bottom padding keeps pins clear of the team panel.
            padding: const EdgeInsets.fromLTRB(48, 110, 48, 300),
            maxZoom: 17,
          ),
        );
      }
    });
  }

  void _focusTanod(_TanodProfile t) {
    final fix = _tanodFixes[t.id];
    if (fix == null) return;
    HapticFeedback.selectionClick();
    setState(() => _selectedTanodId = t.id);
    _mapController.move(fix.point, 17);
  }

  // --- Dispatch straight from the map ---------------------------------

  final List<String> _pickIds = []; // first picked = team lead
  bool _dispatching = false;

  bool get _canDispatch => widget.onDispatch != null;

  _TanodProfile? _tanodById(String id) {
    for (final t in widget.roster) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _onTanodTap(_TanodProfile t) {
    if (!_canDispatch) {
      _showTanodInfo(t);
      return;
    }

    // Busy tanod can't be picked — tell the leader why instead.
    if (widget.busyIds.contains(t.id)) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text("${t.fullName} is on an active dispatch and can't be selected."),
          ),
        );
      return;
    }

    // Tanod who turned location sharing off can't be dispatched: their
    // position is unknown, so there's no way to tell how far away they are.
    final fix = _tanodFixes[t.id];
    if (fix != null && fix.isSharingOff) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '${t.fullName} turned location sharing off and can\'t be dispatched.',
            ),
          ),
        );
      return;
    }

    HapticFeedback.selectionClick();
    final wasPicked = _pickIds.contains(t.id);
    setState(() {
      if (!_pickIds.remove(t.id)) _pickIds.add(t.id);
    });

    // Picking a tanod whose GPS has gone stale is allowed, but warn: the
    // pin shows where they WERE, not necessarily where they are now.
    if (!wasPicked && fix != null && fix.isNoSignal) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            backgroundColor: _kNoSignalColor,
            content: Text(
              '${t.fullName} has no signal — last seen ${_relativeTime(fix.updatedAt)}. '
              'They may not be at the location shown.',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        );
    }
  }

  /// View-only map (no dispatch bar): tapping a tanod just toasts how far
  /// they are from the incident.
  void _showTanodInfo(_TanodProfile t) {
    final fix = _tanodFixes[t.id];
    final d = fix == null ? null : _distanceToCameraKm(fix.point);
    final text = d == null
        ? '${t.fullName} • distance unavailable'
        : '${t.fullName} • ${_formatDistance(d)} from incident';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Picked tanod whose GPS fix is stale (sharing on, but no fresh update).
  List<_TanodProfile> get _pickedNoSignal => [
        for (final id in _pickIds)
          if (_tanodFixes[id]?.isNoSignal == true && _tanodById(id) != null) _tanodById(id)!,
      ];

  Future<void> _dispatchPicked() async {
    // Safety net in case a tanod became busy, or turned location sharing
    // off, after being picked.
    _pickIds.removeWhere(widget.busyIds.contains);
    _pickIds.removeWhere((id) => _tanodFixes[id]?.isSharingOff == true);
    if (_pickIds.isEmpty) {
      setState(() {});
      return;
    }

    // Warn before dispatching anyone whose location may be out of date.
    final stale = _pickedNoSignal;
    if (stale.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.signal_wifi_off, color: _kNoSignalColor, size: 32),
          title: const Text('Location may be outdated'),
          content: Text(
            '${stale.map((t) => t.fullName).join(', ')} '
            '${stale.length == 1 ? 'has' : 'have'} lost GPS signal. '
            'The position on the map is their last known one, so '
            '${stale.length == 1 ? 'they may' : 'they may'} be far from where '
            '${stale.length == 1 ? 'they appear' : 'they appear'} and could take '
            'longer to respond.\n\nDispatch anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Dispatch anyway'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      // Re-check after the dialog in case state changed while it was open.
      _pickIds.removeWhere(widget.busyIds.contains);
      _pickIds.removeWhere((id) => _tanodFixes[id]?.isSharingOff == true);
      if (_pickIds.isEmpty) {
        setState(() {});
        return;
      }
    }

    await _dispatch(_AssignSelection(memberIds: List.of(_pickIds), leadId: _pickIds.first));
  }

  Future<void> _dispatch(_AssignSelection selection) async {
    final onDispatch = widget.onDispatch;
    if (onDispatch == null || _dispatching) return;
    setState(() => _dispatching = true);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await onDispatch(selection);
    if (!mounted) return;
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text('Dispatched ${selection.memberIds.length} tanod.')),
      );
      Navigator.of(context).pop(); // back to the list; card is now under Active
    } else {
      setState(() => _dispatching = false);
    }
  }

  /// Details card for the most recently picked tanod: who they are, whether
  /// they're free, how far from the incident, and how fresh their GPS is.
  Widget _focusedInfo(_TanodProfile t) {
    final fix = _tanodFixes[t.id];
    final d = fix == null ? null : _distanceToCameraKm(fix.point);
    final busy = widget.busyIds.contains(t.id);
    final sharingOff = fix != null && fix.isSharingOff;
    final noSignal = fix != null && fix.isNoSignal;
    final off = sharingOff || noSignal;
    final Color offColor = noSignal ? _kNoSignalColor : Colors.grey;
    final Color statusColor =
        off ? offColor : (busy ? AppColors.accentRed : AppColors.accentGreen);

    final String subtitle;
    if (fix == null) {
      subtitle = 'No GPS signal';
    } else if (off) {
      subtitle = [
        sharingOff ? 'Turned off location sharing' : 'Lost signal',
        if (d != null) '${_formatDistance(d)} away',
        'last seen ${_relativeTime(fix.updatedAt)}',
      ].join(' • ');
    } else {
      subtitle = [
        if (d != null) '${_formatDistance(d)} away',
        'updated ${_relativeTime(fix.updatedAt)}',
      ].join(' • ');
    }

    return Container(
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
    );
  }

  /// Amber banner shown in the dispatch bar while any picked tanod has
  /// lost signal, so the leader knows the pin may not be where they are.
  Widget _noSignalWarning(List<_TanodProfile> stale) {
    final names = stale.map((t) => t.shortName).join(', ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kNoSignalColor.withOpacity(0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kNoSignalColor.withOpacity(0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: _kNoSignalColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$names ${stale.length == 1 ? 'has' : 'have'} lost signal. The pin shows '
              'the last known position — ${stale.length == 1 ? 'they' : 'they'} may be '
              'far from it and their real distance to the incident is unknown.',
              style: TextStyle(
                  color: AppColors.textMain(context), fontSize: 11.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dispatchBar() {
    final n = _pickIds.length;
    final busyVisible = widget.roster
        .where((t) => widget.busyIds.contains(t.id) && _tanodFixes[t.id] != null)
        .length;
    final sharingOffVisible =
        widget.roster.where((t) => _tanodFixes[t.id]?.isSharingOff == true).length;
    final noSignalVisible =
        widget.roster.where((t) => _tanodFixes[t.id]?.isNoSignal == true).length;
    final lastPicked = n == 0 ? null : _tanodById(_pickIds.last);
    final pickedStale = _pickedNoSignal;
    final mq = MediaQuery.of(context);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + mq.padding.bottom),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          border: Border(top: BorderSide(color: AppColors.border(context))),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 12)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              n == 0
                  ? 'Tap a tanod on the map to select'
                  : '$n selected · tap a name to make team lead',
              style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
            if (_offlineCount > 0) ...[
              const SizedBox(height: 3),
              Text(
                '$_offlineCount tanod not shown (no GPS data)',
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 11),
              ),
            ],
            if (sharingOffVisible > 0) ...[
              const SizedBox(height: 3),
              Text(
                '$sharingOffVisible tanod turned location sharing off — can\'t be selected',
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 11),
              ),
            ],
            if (noSignalVisible > 0) ...[
              const SizedBox(height: 3),
              Text(
                '$noSignalVisible tanod lost signal — last known position shown, may be inaccurate',
                style: const TextStyle(color: _kNoSignalColor, fontSize: 11),
              ),
            ],
            if (busyVisible > 0) ...[
              const SizedBox(height: 3),
              Text(
                '$busyVisible tanod on active dispatch — can\'t be selected',
                style: TextStyle(color: AppColors.accentRed, fontSize: 11.5),
              ),
            ],
            if (lastPicked != null) ...[
              const SizedBox(height: 10),
              _focusedInfo(lastPicked),
            ],
            if (pickedStale.isNotEmpty) ...[
              const SizedBox(height: 8),
              _noSignalWarning(pickedStale),
            ],
            if (n > 0) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: n,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final t = _tanodById(_pickIds[i]);
                    if (t == null) return const SizedBox.shrink();
                    final isLead = i == 0;
                    return InputChip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(isLead ? Icons.star : Icons.star_border,
                          size: 16, color: AppColors.accentRed),
                      label: Text(t.shortName, style: const TextStyle(fontSize: 12)),
                      onPressed: () {
                        if (isLead) return;
                        setState(() {
                          _pickIds.remove(t.id);
                          _pickIds.insert(0, t.id);
                        });
                      },
                      onDeleted: () => setState(() => _pickIds.remove(t.id)),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: (n == 0 || _dispatching) ? null : _dispatchPicked,
                icon: _dispatching
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white70),
                      )
                    : const Icon(Icons.send, size: 16),
                label: Text(_dispatching
                    ? 'DISPATCHING…'
                    : (n == 0 ? 'DISPATCH' : 'DISPATCH $n')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentBlue,
                  disabledBackgroundColor: AppColors.accentBlue.withOpacity(0.4),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      widget.trackAssignedTeam ? _buildTracking(context) : _buildSimple(context);

  /// Pending "View map & dispatch": incident pin, nearby tanod, and a
  /// dispatch bar — pick tanod directly on the map.
  Widget _buildSimple(BuildContext context) {
    final cam = widget.camera.hasLocation
        ? ll.LatLng(widget.camera.latitude!, widget.camera.longitude!)
        : null;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      appBar: AppBar(
        backgroundColor: AppColors.bg(context),
        elevation: 0,
        foregroundColor: AppColors.textMain(context),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
            Text(widget.camera.displayLocation,
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      body: cam == null
          ? Center(
              child: Text('No location available for this incident.',
                  style: TextStyle(color: AppColors.textMuted(context))))
          : Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: cam,
                    initialZoom: 16,
                    minZoom: 13,
                    maxZoom: 19,
                    onMapReady: _onMapReady,
                    onPositionChanged: _onCameraMoved,
                  ),
                  children: [
                    _themedTileLayer(Theme.of(context).brightness == Brightness.dark),
                    ..._boundaryLayers(context),
                    MarkerLayer(markers: [
                      ..._clusteredTanodMarkers(),
                      Marker(
                        point: cam,
                        width: 48,
                        height: 48,
                        child: _Pin(icon: widget.incidentIcon, color: AppColors.accentRed),
                      ),
                    ]),
                  ],
                ),
                Positioned(
                  right: 12,
                  top: 12, // top-right so it never collides with the dispatch bar
                  child: FloatingActionButton.small(
                    heroTag: 'recenter_leader_map',
                    backgroundColor: AppColors.card(context),
                    foregroundColor: AppColors.accentBlue,
                    onPressed: _fitMap,
                    child: const Icon(Icons.center_focus_strong),
                  ),
                ),
                if (_canDispatch) _dispatchBar(),
              ],
            ),
    );
  }

  /// Track-team map: only the tanod dispatched to THIS incident are shown
  /// (the caller passes just the team as `roster`), and the dispatched team
  /// is listed in a panel at the bottom instead of a route/directions card.
  Widget _buildTracking(BuildContext context) {
    final cam = widget.camera.hasLocation
        ? ll.LatLng(widget.camera.latitude!, widget.camera.longitude!)
        : null;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      appBar: AppBar(
        backgroundColor: AppColors.bg(context),
        elevation: 0,
        foregroundColor: AppColors.textMain(context),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
            Text(widget.camera.displayLocation,
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      body: cam == null
          ? Center(
              child: Text('No location available for this incident.',
                  style: TextStyle(color: AppColors.textMuted(context))))
          : Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: cam,
                    initialZoom: 16,
                    onMapReady: _onMapReady,
                    onTap: (_, __) => setState(() => _selectedTanodId = null),
                  ),
                  children: [
                    _themedTileLayer(Theme.of(context).brightness == Brightness.dark),
                    ..._boundaryLayers(context),
                    MarkerLayer(markers: [
                      for (final tanod in widget.roster)
                        if (_tanodFixes[tanod.id] != null)
                          Marker(
                            point: _tanodFixes[tanod.id]!.point,
                            width: 150,
                            height: 80, // circle centred on the GPS point, name tag below
                            child: GestureDetector(
                              onTap: () => _focusTanod(tanod),
                              child: _TanodMarker(
                                initials: tanod.initials,
                                label: tanod.id == widget.teamLeadId
                                    ? '★ ${tanod.shortName}'
                                    : tanod.shortName,
                                busy: false,
                                selected: _selectedTanodId == tanod.id,
                                assigned: true,
                                off: _tanodFixes[tanod.id]!.isOff,
                                noSignal: _tanodFixes[tanod.id]!.isNoSignal,
                              ),
                            ),
                          ),
                      Marker(
                        point: cam,
                        width: 48,
                        height: 48,
                        child: _Pin(icon: widget.incidentIcon, color: AppColors.accentRed),
                      ),
                    ]),
                  ],
                ),
                Positioned(
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
                        _legendDot(AppColors.accentBlue, 'Dispatched team'),
                        const SizedBox(height: 4),
                        _legendDot(AppColors.accentRed, 'Incident'),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'recenter_leader_map',
                    backgroundColor: AppColors.card(context),
                    foregroundColor: AppColors.accentBlue,
                    onPressed: _fitMap,
                    child: const Icon(Icons.center_focus_strong),
                  ),
                ),
                _teamPanel(),
              ],
            ),
    );
  }

  /// Bottom panel listing everyone dispatched to this incident. Tap a row
  /// to jump the map to that tanod.
  Widget _teamPanel() {
    final mq = MediaQuery.of(context);
    final members = [...widget.roster]..sort((a, b) {
        final aLead = a.id == widget.teamLeadId;
        final bLead = b.id == widget.teamLeadId;
        if (aLead != bLead) return aLead ? -1 : 1;
        return a.fullName.compareTo(b.fullName);
      });

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
                Icon(Icons.groups_outlined, size: 18, color: AppColors.textMain(context)),
                const SizedBox(width: 8),
                Text(
                  'Dispatched team · ${members.length}',
                  style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: members.length,
                itemBuilder: (context, i) => _teamPanelRow(members[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _teamPanelRow(_TanodProfile t) {
    final fix = _tanodFixes[t.id];
    final d = fix == null ? null : _distanceToCameraKm(fix.point);
    final isLead = t.id == widget.teamLeadId;
    final selected = _selectedTanodId == t.id;
    final accent = isLead ? AppColors.accentRed : AppColors.accentBlue;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: fix == null ? null : () => _focusTanod(t),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentBlue.withOpacity(0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration:
                    BoxDecoration(color: accent.withOpacity(0.15), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(t.initials,
                    style: TextStyle(
                        color: accent, fontSize: 12.5, fontWeight: FontWeight.w800)),
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
                        if (isLead) ...[
                          const SizedBox(width: 6),
                          _pill('LEAD', AppColors.accentRed, icon: Icons.star_outline),
                        ],
                        if (fix != null && fix.isSharingOff) ...[
                          const SizedBox(width: 6),
                          _pill('LOCATION OFF', Colors.grey, icon: Icons.location_off),
                        ] else if (fix != null && fix.isNoSignal) ...[
                          const SizedBox(width: 6),
                          _pill('NO SIGNAL', _kNoSignalColor, icon: Icons.signal_wifi_off),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fix == null
                          ? 'No GPS signal'
                          : [
                              if (d != null) '${_formatDistance(d)} from incident',
                              'updated ${_relativeTime(fix.updatedAt)}',
                            ].join(' • '),
                      style: TextStyle(
                          color: fix == null
                              ? AppColors.accentOrange
                              : AppColors.textMuted(context),
                          fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (fix != null)
                Icon(Icons.my_location, size: 16, color: AppColors.textMuted(context)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live snapshot of one tanod's position, resolved from `live_gps`.
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

  /// Either of the above — shown greyed on the map.
  bool get isOff => isSharingOff || isNoSignal;
}

/// Formats "how long ago" without pulling in a whole package for it —
/// good enough for a "last seen" label, not meant to be precise.
String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.isNegative || diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  return '${diff.inDays} d ago';
}

/// Exact clock time a report reached the purok leader, e.g.
/// "Today, 3:42 PM" or "Sep 29, 9:05 AM" (or with the year if it's from
/// a previous year). No intl dependency needed.
String _formatSentTime(DateTime time) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  final period = time.hour >= 12 ? 'PM' : 'AM';
  final clock = '$hour12:$minute $period';

  final now = DateTime.now();
  final sameDay = time.year == now.year && time.month == now.month && time.day == now.day;
  if (sameDay) return 'Today, $clock';

  final yesterday = now.subtract(const Duration(days: 1));
  final isYesterday = time.year == yesterday.year &&
      time.month == yesterday.month &&
      time.day == yesterday.day;
  if (isYesterday) return 'Yesterday, $clock';

  final date = '${months[time.month - 1]} ${time.day}';
  return time.year == now.year ? '$date, $clock' : '$date, ${time.year}, $clock';
}

/// Shared "one team member" row — avatar, name, role, LEAD badge. Used by
/// both the collapsible team section on Active cards and the full report
/// review screen, so a team reads identically everywhere it's shown.
Widget _teamMemberRow(BuildContext context, _TanodProfile member, String? teamLeadId,
    {bool isLast = false}) {
  final isLead = member.id == teamLeadId;
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
          child: Row(
            children: [
              Flexible(
                child: Text(
                  member.fullName,
                  style: TextStyle(
                      color: AppColors.textMain(context), fontSize: 13, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (member.role.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text('· ${member.role}',
                      style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ],
          ),
        ),
        if (isLead) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.accentRed.withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.star_outline, size: 10, color: AppColors.accentRed),
                const SizedBox(width: 3),
                Text('LEAD',
                    style: TextStyle(
                        color: AppColors.accentRed, fontSize: 9, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// One tanod's pin — colored by availability, with a highlighted ring when
/// tapped/selected. Busy (on active dispatch) tanod are dimmed and get a
/// red "BUSY" tag so the leader can see at a glance they can't be picked.
///
/// `off` = location sharing off OR no signal:
///   • sharing turned off  -> grey, location_off icon, "OFF" tag
///   • lost signal (noSignal = true) -> amber, signal_wifi_off icon, "NO SIGNAL" tag
class _TanodMarker extends StatelessWidget {
  final String initials;
  final bool busy;
  final bool selected;
  final bool assigned;
  final bool off;

  /// Only meaningful when [off] is true: the tanod is still sharing but
  /// their last fix is stale (lost signal), as opposed to having turned
  /// location sharing off.
  final bool noSignal;

  /// Optional name tag drawn under the pin so the leader can tell who is
  /// who without tapping. When set, the parent Marker should be roughly
  /// 150 x 80 so the circle stays centred on the GPS point.
  final String? label;

  const _TanodMarker({
    required this.initials,
    required this.busy,
    required this.selected,
    this.assigned = false,
    this.off = false,
    this.noSignal = false,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final locked = busy && !assigned && !selected && !off;
    // A picked / assigned tanod keeps its blue highlight even if off.
    final greyed = off && !assigned;
    final offColor = noSignal ? _kNoSignalColor : Colors.grey;
    final color = assigned
        ? AppColors.accentBlue
        : (off
            ? offColor
            : (busy ? AppColors.accentRed : AppColors.accentGreen));

    final circle = Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: selected ? 3 : 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: selected ? 8 : 4),
        ],
      ),
      alignment: Alignment.center,
      child: greyed
          ? Icon(noSignal ? Icons.signal_wifi_off : Icons.location_off,
              color: Colors.white, size: 18)
          : Text(initials,
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
    );

    final pin = Opacity(opacity: (locked || greyed) ? 0.75 : 1, child: circle);

    if (label == null) return pin;

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        SizedBox(width: 42, height: 42, child: pin),
        Positioned(
          bottom: 2,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.card(context).withOpacity(0.95),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected
                      ? AppColors.accentBlue
                      : (off
                          ? offColor
                          : (locked ? AppColors.accentRed : AppColors.border(context))),
                  width: selected ? 1.5 : 1,
                ),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 3)],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label!,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      color: off ? AppColors.textMuted(context) : AppColors.textMain(context),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (off) ...[
                    const SizedBox(width: 5),
                    Text(
                      noSignal ? 'NO SIGNAL' : 'OFF',
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: offColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ] else if (locked) ...[
                    const SizedBox(width: 5),
                    Text(
                      'BUSY',
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: AppColors.accentRed,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// SMALL UI HELPERS
// ============================================================================

/// "unauthorized_entry" -> "Unauthorized Entry"
String _titleCase(String s) {
  final cleaned = s.replaceAll('_', ' ').trim();
  if (cleaned.isEmpty) return cleaned;
  return cleaned
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

/// Icon that fits the kind of incident (used for the incident pin on the map).
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

class PurokLeaderHomeScreen extends StatefulWidget {
  final bool isActive;

  const PurokLeaderHomeScreen({super.key, required this.isActive});

  @override
  State<PurokLeaderHomeScreen> createState() => _PurokLeaderHomeScreenState();
}

class _PurokLeaderHomeScreenState extends State<PurokLeaderHomeScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  StreamSubscription<List<Map<String, dynamic>>>? _requestSub;
  StreamSubscription<List<Map<String, dynamic>>>? _dispatchSub;
  StreamSubscription<List<Map<String, dynamic>>>? _reportSub;

  final Map<String, _RequestBundle> _bundles = {};

  final Map<String, _IncidentInfo> _incidentCache = {};
  final Map<String, _CameraInfo> _cameraCache = {};

  final Set<String> _assigningRequestIds = {};

  final Set<String> _finalizingRequestIds = {};

  // In-flight guard for `_saveReportEdits`, mirroring `_finalizingRequestIds`
  // — a request can only be mid-save on this action while it's already in
  // the For Review filter, so it never overlaps with `_assigningRequestIds`.
  final Set<String> _savingEditsRequestIds = {};

  final Set<String> _expandedTeamRequestIds = {};

  void _toggleTeamExpanded(String requestId) {
    setState(() {
      if (!_expandedTeamRequestIds.remove(requestId)) {
        _expandedTeamRequestIds.add(requestId);
      }
    });
  }

  String? _myPurok;
  bool _loadingPurok = true;

  Set<String> _busyTanodIds = {};

  final Map<String, _IncidentReportInfo> _reportByAssignmentId = {};

  int _statusTab = 0; // 0 = Pending, 1 = Active, 2 = For Review

  String get _userId => _supabase.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _loadMyPurok();
    if (widget.isActive) _startSubscriptions();
  }

  @override
  void didUpdateWidget(covariant PurokLeaderHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _startSubscriptions();
    if (!widget.isActive && oldWidget.isActive) _stopSubscriptions();
  }

  void _startSubscriptions() {
    _requestSub ??= _supabase
        .from('dispatch_requests')
        .stream(primaryKey: ['id'])
        .eq('leader_id', _userId)
        .order('created_at', ascending: false)
        .listen(_handleRequestRows);

    _dispatchSub ??= _supabase
        .from('tanod_dispatches')
        .stream(primaryKey: ['id'])
        .listen(_handleDispatchRows);

    _reportSub ??= _supabase
        .from('incident_reports')
        .stream(primaryKey: ['id'])
        .listen(_handleReportRows);
  }

  void _stopSubscriptions() {
    _requestSub?.cancel();
    _dispatchSub?.cancel();
    _reportSub?.cancel();
    _requestSub = null;
    _dispatchSub = null;
    _reportSub = null;
  }

  @override
  void dispose() {
    _stopSubscriptions();
    super.dispose();
  }

  Future<void> _loadMyPurok() async {
    try {
      final row = await _supabase
          .from('profiles')
          .select('purok')
          .eq('id', _userId)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _myPurok = (row?['purok'] as String?)?.trim();
        _loadingPurok = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingPurok = false);
    }
  }

  // --- REQUEST STREAM --------------------------------------------------

  void _handleRequestRows(List<Map<String, dynamic>> rows) {
    final incomingIds = <String>{};
    for (final row in rows) {
      final request = _DispatchRequestRow.fromMap(row);
      incomingIds.add(request.id);

      final existing = _bundles[request.id];
      _bundles[request.id] = (existing ?? _RequestBundle(
        request: request,
        incident: null,
        camera: null,
        assignment: null,
        team: const [],
        report: null,
      ))
          .copyWith(request: request);

      _ensureIncidentAndCamera(request);
      _ensureAssignment(request);
    }

    _bundles.removeWhere((id, _) => !incomingIds.contains(id));

    if (mounted) setState(() {});
  }

  Future<void> _ensureIncidentAndCamera(_DispatchRequestRow request) async {
    final needsIncident = !_incidentCache.containsKey(request.incidentId);
    final needsCamera = !_cameraCache.containsKey(request.cameraId);
    if (!needsIncident && !needsCamera) {
      _applyIncidentCamera(request.id);
      return;
    }
    try {
      if (needsIncident) {
        final row = await _supabase
            .from('incidents')
            .select()
            .eq('id', request.incidentId)
            .maybeSingle();
        if (row != null) {
          _incidentCache[request.incidentId] = _IncidentInfo.fromMap(row);
        } else {
          debugPrint(
            '[PurokLeaderHome] incidents row ${request.incidentId} returned '
            'null for request ${request.id} — check RLS SELECT policy on '
            '`incidents` for this leader.',
          );
        }
      }
      if (needsCamera) {
        final row = await _supabase
            .from('cameras')
            .select()
            .eq('id', request.cameraId)
            .maybeSingle();
        if (row != null) {
          _cameraCache[request.cameraId] = _CameraInfo.fromMap(row);
        } else {
          debugPrint(
            '[PurokLeaderHome] cameras row ${request.cameraId} returned null '
            'for request ${request.id} — check RLS SELECT policy on '
            '`cameras` for this leader.',
          );
        }
      }
    } catch (e, st) {
      debugPrint('[PurokLeaderHome] incident/camera fetch failed: $e\n$st');
    } finally {
      _applyIncidentCamera(request.id);
    }
  }

  void _applyIncidentCamera(String requestId) {
    final bundle = _bundles[requestId];
    if (bundle == null) return;
    final incident = _incidentCache[bundle.request.incidentId];
    final camera = _cameraCache[bundle.request.cameraId];
    if (incident == null && camera == null) return;
    _bundles[requestId] = bundle.copyWith(incident: incident, camera: camera);
    if (mounted) setState(() {});
  }

  // --- ASSIGNMENT STREAM -------------------------------------------------

  final Set<String> _assignmentLookupAttempted = {};

  Future<void> _ensureAssignment(_DispatchRequestRow request) async {
    if (request.status != _kDispatchedStatus) return;
    final bundle = _bundles[request.id];
    if (bundle?.assignment != null) return;
    if (!_assignmentLookupAttempted.add(request.id)) return;

    try {
      final row = await _supabase
          .from('tanod_dispatches')
          .select()
          .eq('dispatch_request_id', request.id)
          .maybeSingle();
      if (mounted) setState(() {});
      if (row == null) return;
      final assignment = _AssignmentInfo.fromMap(row);
      final current = _bundles[request.id];
      if (current == null) return;
      _bundles[request.id] = current.copyWith(assignment: assignment);
      _resolveTeam(request.id, assignment);
      _applyReportIfAny(request.id, assignment.id);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[PurokLeaderHome] assignment lookup failed for ${request.id}: $e');
      if (mounted) setState(() {});
    }
  }

  void _handleDispatchRows(List<Map<String, dynamic>> rows) {
    final myRequestIds = _bundles.keys.toSet();
    final busy = <String>{};

    for (final row in rows) {
      final status = (row['status'] ?? '').toString();
      final memberIds =
          ((row['member_ids'] as List?) ?? []).map((e) => e.toString());
      if (status != _kCompletedStatus) busy.addAll(memberIds);

      final dispatchRequestId = row['dispatch_request_id']?.toString();
      if (dispatchRequestId == null || !myRequestIds.contains(dispatchRequestId)) {
        continue;
      }
      final assignment = _AssignmentInfo.fromMap(row);
      final bundle = _bundles[dispatchRequestId];
      if (bundle == null) continue;
      _bundles[dispatchRequestId] = bundle.copyWith(assignment: assignment);
      _resolveTeam(dispatchRequestId, assignment);
      _applyReportIfAny(dispatchRequestId, assignment.id);
    }

    _busyTanodIds = busy;
    if (mounted) setState(() {});
  }

  final Map<String, List<_TanodProfile>> _teamCache = {};

  /// Placeholder for a member whose profile couldn't be loaded, so they are
  /// still listed instead of the team collapsing to just the lead.
  _TanodProfile _placeholderTanod(String id) =>
      _TanodProfile(id: id, fullName: 'Assigned tanod', role: _kTanodRole);

  int _teamSort(_TanodProfile a, _TanodProfile b, String? leadId) {
    final aLead = a.id == leadId;
    final bLead = b.id == leadId;
    if (aLead != bLead) return aLead ? -1 : 1;
    return a.fullName.compareTo(b.fullName);
  }

  Future<void> _resolveTeam(String requestId, _AssignmentInfo assignment) async {
    if (assignment.memberIds.isEmpty) return;
    final cacheKey = assignment.id;
    if (_teamCache.containsKey(cacheKey)) {
      final bundle = _bundles[requestId];
      if (bundle != null) {
        _bundles[requestId] = bundle.copyWith(team: _teamCache[cacheKey]!);
        if (mounted) setState(() {});
      }
      return;
    }
    try {
      final rows = await _supabase
          .from('profiles')
          .select('id, first_name, last_name, role')
          .inFilter('id', assignment.memberIds);
      final found = (rows as List)
          .map((r) => _TanodProfile.fromMap(r as Map<String, dynamic>))
          .toList();
      final foundIds = found.map((t) => t.id).toSet();
      final missing =
          assignment.memberIds.where((id) => !foundIds.contains(id)).toList();

      // Every member in `member_ids` is listed — unresolved ones as
      // placeholders — so the report shows the whole team, not just the lead.
      final team = [
        ...found,
        for (final id in missing) _placeholderTanod(id),
      ]..sort((a, b) => _teamSort(a, b, assignment.teamLeadId));

      // Only cache a fully-resolved team so placeholders get retried.
      if (missing.isEmpty) _teamCache[cacheKey] = team;

      final bundle = _bundles[requestId];
      if (bundle != null) {
        _bundles[requestId] = bundle.copyWith(team: team);
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('[PurokLeaderHome] team resolve failed for ${assignment.id}: $e');
      final team = [
        for (final id in assignment.memberIds) _placeholderTanod(id),
      ]..sort((a, b) => _teamSort(a, b, assignment.teamLeadId));
      final bundle = _bundles[requestId];
      if (bundle != null && bundle.team.isEmpty) {
        _bundles[requestId] = bundle.copyWith(team: team);
        if (mounted) setState(() {});
      }
    }
  }

  // --- REPORT STREAM (For Review) ----------------------------------------

  void _applyReportIfAny(String requestId, String assignmentId) {
    final report = _reportByAssignmentId[assignmentId];
    if (report == null) return;
    final bundle = _bundles[requestId];
    if (bundle == null || bundle.report != null) return;
    _bundles[requestId] = bundle.copyWith(report: report);
  }

  void _handleReportRows(List<Map<String, dynamic>> rows) {
    final myAssignmentIds =
        _bundles.values.map((b) => b.assignment?.id).whereType<String>().toSet();

    for (final row in rows) {
      if (row['source_type'] != 'tanod') continue;
      final sourceId = row['source_id']?.toString();
      if (sourceId == null || sourceId.isEmpty) continue;
      final report = _IncidentReportInfo.fromMap(row);
      _reportByAssignmentId[sourceId] = report;
      if (!myAssignmentIds.contains(sourceId)) continue;

      for (final id in _bundles.keys) {
        final bundle = _bundles[id]!;
        if (bundle.assignment?.id == sourceId) {
          _bundles[id] = bundle.copyWith(report: report);
        }
      }
    }

    if (mounted) setState(() {});
  }

  // --- ASSIGN TANOD --------------------------------------------------------

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

  Future<Map<String, double>> _distancesToCamera(
    List<_TanodProfile> roster,
    _CameraInfo? camera,
  ) async {
    if (camera == null || !camera.hasLocation) return {};
    try {
      final rows = await _supabase
          .from('live_gps')
          .select('member_id, latitude, longitude')
          .inFilter('member_id', roster.map((t) => t.id).toList());
      final distances = <String, double>{};
      for (final row in rows as List) {
        final lat = (row['latitude'] as num?)?.toDouble();
        final lng = (row['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        distances[row['member_id'].toString()] = _straightLineKm(
          ll.LatLng(lat, lng),
          ll.LatLng(camera.latitude!, camera.longitude!),
        );
      }
      return distances;
    } catch (_) {
      return {};
    }
  }

  Future<List<_TanodProfile>?> _loadTanodRoster() async {
    if (_myPurok == null || _myPurok!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Your profile has no purok set — can't load a tanod roster.")),
      );
      return null;
    }
    try {
      final rows = await _supabase
          .from('profiles')
          .select('id, first_name, last_name, role')
          .eq('purok', _myPurok!)
          .eq('role', _kTanodRole);
      final roster = (rows as List)
          .map((r) => _TanodProfile.fromMap(r as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.fullName.compareTo(b.fullName));
      if (roster.isEmpty) {
        if (!mounted) return null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No tanod found for purok $_myPurok.')),
        );
        return null;
      }
      return roster;
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to load tanod roster: $e')));
      return null;
    }
  }

  /// List-sheet fallback. Only used when the camera has no coordinates
  /// (so there's no map to pick from) — normally the leader dispatches
  /// straight from the map via `_openDispatchMap`.
  Future<void> _openAssignSheet(_RequestBundle bundle) async {
    final roster = await _loadTanodRoster();
    if (roster == null || !mounted) return;

    final distanceKm = await _distancesToCamera(roster, bundle.camera);

    if (!mounted) return;
    // The sheet sorts itself (available first, then nearest), so no
    // pre-sorting is needed here.
    final result = await showModalBottomSheet<_AssignSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AssignTanodSheet(
        roster: roster,
        busyIds: _busyTanodIds,
        distanceKm: distanceKm,
        incidentTitle: _titleCase(bundle.incident?.alertType ?? 'Incident'),
        locationLabel: bundle.camera?.displayLocation ?? '',
      ),
    );
    if (result == null) return;

    await _assignTanod(bundle, result);
  }

  Future<bool> _assignTanod(_RequestBundle bundle, _AssignSelection selection) async {
    final requestId = bundle.request.id;
    if (_assigningRequestIds.contains(requestId)) return false;
    setState(() => _assigningRequestIds.add(requestId));
    try {
      await _supabase.from('tanod_dispatches').insert({
        'incident_id': bundle.request.incidentId,
        'camera_id': bundle.request.cameraId,
        'team_lead_id': selection.leadId,
        'member_ids': selection.memberIds,
        'dispatched_by': _userId,
        'status': _kDispatchedStatus,
        'dispatched_at': DateTime.now().toIso8601String(),
        'dispatch_request_id': requestId,
      });

      await _supabase
          .from('dispatch_requests')
          .update({'status': _kDispatchedStatus}).eq('id', requestId);

      try {
        await _supabase
            .from('incidents')
            .update({'status': 'tanod_dispatched'})
            .eq('id', bundle.request.incidentId);
      } catch (e) {
        debugPrint('[PurokLeaderHome] failed to update incident status: $e');
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to assign tanod: $e')));
      return false;
    } finally {
      if (mounted) setState(() => _assigningRequestIds.remove(requestId));
    }
  }

  // --- REVIEW & SUBMIT -----------------------------------------------------

  Future<bool> _askConfirmSubmit() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit to Command Center?'),
        content: const Text(
          'This marks the report submitted, the dispatch completed, and the '
          'incident resolved. You won\'t be able to edit it from here afterward.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _finalizeFromCard(_RequestBundle bundle) async {
    if (!await _askConfirmSubmit()) return;
    await _finalizeReport(bundle);
  }

  Future<void> _finalizeFromDetail(_RequestBundle bundle) async {
    if (!await _askConfirmSubmit()) return;
    await _finalizeReport(bundle);
    if (mounted) Navigator.of(context).pop();
  }

  void _openReviewDetail(_RequestBundle bundle) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ReportReviewScreen(
          bundle: bundle,
          isSubmitting: _finalizingRequestIds.contains(bundle.request.id),
          isSavingEdits: _savingEditsRequestIds.contains(bundle.request.id),
          onSubmit: () => _finalizeFromDetail(bundle),
          onSaveNarrative: (narrative) => _saveReportEdits(bundle, narrative),
        ),
      ),
    );
  }

  /// Writes a leader's cleaned-up description back onto the tanod's
  /// `incident_reports` row — same table & RLS path `_finalizeReport`
  /// already writes to (`leader_updates_own_tanod_reports`), so no new
  /// policy is needed. This only ever touches `report_text`; it never
  /// changes `status`, so it's safe to call any number of times before the
  /// leader finally hits SUBMIT.
  ///
  /// If you want an audit trail of leader edits, add two columns
  /// (`edited_by uuid`, `edited_at timestamptz`) to `incident_reports` and
  /// set them in the `.update({...})` call below.
  Future<bool> _saveReportEdits(_RequestBundle bundle, String narrative) async {
    final report = bundle.report;
    final requestId = bundle.request.id;
    if (report == null) return false;
    if (_savingEditsRequestIds.contains(requestId)) return false;

    setState(() => _savingEditsRequestIds.add(requestId));
    try {
      await _supabase.from('incident_reports').update({
        'report_text': narrative,
        // 'edited_by': _userId,
        // 'edited_at': DateTime.now().toIso8601String(),
      }).eq('id', report.id);

      final updatedReport = report.copyWith(narrative: narrative);

      // Reflect locally right away — both in the bundle map and in the
      // by-assignment-id cache `_handleReportRows`/`_applyReportIfAny`
      // read from, so nothing stomps this edit if a stale realtime row
      // for the OLD content arrives a moment later.
      final current = _bundles[requestId];
      if (current != null) {
        _bundles[requestId] = current.copyWith(report: updatedReport);
      }
      _reportByAssignmentId[report.sourceId] = updatedReport;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report updated.')),
        );
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to save changes: $e')));
      return false;
    } finally {
      if (mounted) setState(() => _savingEditsRequestIds.remove(requestId));
    }
  }

  /// The one action a For Review card exposes: writes the three status
  /// updates that hand the incident back to command center —
  /// incident_reports -> submitted, dispatch_requests -> completed,
  /// incidents -> resolved. Once dispatch_requests flips to `completed`
  /// this request no longer matches Pending, Active, or For Review, so the
  /// card simply disappears from the list on the next realtime tick.
  Future<void> _finalizeReport(_RequestBundle bundle) async {
    final requestId = bundle.request.id;
    final report = bundle.report;
    if (report == null) return;
    if (_finalizingRequestIds.contains(requestId)) return;

    setState(() => _finalizingRequestIds.add(requestId));
    try {
      await _supabase
          .from('incident_reports')
          .update({'status': _kReportSubmittedStatus}).eq('id', report.id);

      await _supabase
          .from('dispatch_requests')
          .update({'status': _kCompletedStatus}).eq('id', requestId);

      try {
        await _supabase
            .from('incidents')
            .update({'status': _kIncidentResolvedStatus})
            .eq('id', bundle.request.incidentId);
      } catch (e) {
        debugPrint('[PurokLeaderHome] failed to resolve incident: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted to command center.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to submit report: $e')));
    } finally {
      if (mounted) setState(() => _finalizingRequestIds.remove(requestId));
    }
  }

  // --- GROUPING ------------------------------------------------------------

  List<_RequestBundle> get _pending => _bundles.values
      .where((b) => b.request.status == _kPendingStatus)
      .toList()
    ..sort((a, b) => b.request.createdAt.compareTo(a.request.createdAt));

  List<_RequestBundle> get _active => _bundles.values
      .where((b) => b.request.status == _kDispatchedStatus && b.report == null)
      .toList()
    ..sort((a, b) => b.request.createdAt.compareTo(a.request.createdAt));

  List<_RequestBundle> get _review => _bundles.values
      .where((b) =>
          b.request.status == _kDispatchedStatus &&
          b.report != null &&
          b.report!.status != _kReportSubmittedStatus)
      .toList()
    ..sort((a, b) => b.report!.submittedAt.compareTo(a.report!.submittedAt));

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    final active = _active;
    final review = _review;

    return Container(
      color: AppColors.bg(context),
      child: _loadingPurok
          ? Center(child: CircularProgressIndicator(color: AppColors.accentBlue))
          : Column(
              children: [
                _buildFilterBar(pending.length, active.length, review.length),
                Expanded(
                  child: switch (_statusTab) {
                    0 => _list(pending, _pendingCard, emptyText: 'No pending requests right now.'),
                    1 => _list(active, _activeCard, emptyText: 'No active dispatches right now.'),
                    _ => _list(review, _reviewCard, emptyText: 'No reports waiting for review.'),
                  },
                ),
              ],
            ),
    );
  }

  Widget _buildFilterBar(int pendingCount, int activeCount, int reviewCount) {
    final tabs = [
      ('Pending', pendingCount),
      ('Active', activeCount),
      ('For Review', reviewCount),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        border: Border(bottom: BorderSide(color: AppColors.border(context))),
      ),
      child: Container(
        height: 42,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.sunken(context),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment(
                tabs.length <= 1 ? 0 : -1 + (2 * _statusTab) / (tabs.length - 1),
                0,
              ),
              child: FractionallySizedBox(
                widthFactor: 1 / tabs.length,
                heightFactor: 1,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.card(context),
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.10),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (int i = 0; i < tabs.length; i++)
                  Expanded(child: _segment(index: i, label: tabs[i].$1, count: tabs[i].$2)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment({required int index, required String label, required int count}) {
    final selected = _statusTab == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _statusTab = index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 160),
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.textMain(context) : AppColors.textMuted(context),
              ),
              child: Text(label),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: selected ? AppColors.accentRed : AppColors.accentRed.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _list(List<_RequestBundle> items, Widget Function(_RequestBundle) builder,
      {required String emptyText}) {
    if (items.isEmpty) {
      return Center(
        child: Text(emptyText, style: TextStyle(color: AppColors.textMuted(context), fontSize: 13)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      itemCount: items.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: builder(items[i]),
      ),
    );
  }

  // --- CARD BUILDERS ---------------------------------------------------

  Widget _cardShell({required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border(context)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: child,
      );

  /// Simple header: WHAT happened (type + time) and WHERE (location + distance).
  /// Pass `showMapButton: false` when the card supplies its own map action
  /// (the Pending card's combined "VIEW MAP & DISPATCH" button) or shouldn't
  /// have one at all (the For Review card).
  Widget _incidentHeader(_RequestBundle bundle, {bool showMapButton = true}) {
    final incident = bundle.incident;
    final camera = bundle.camera;
    final assignment = bundle.assignment;
    final hasTeam = assignment != null && assignment.memberIds.isNotEmpty;
    final type = incident == null ? 'Loading incident…' : _titleCase(incident.alertType);
    final when = incident?.occurredAt ?? bundle.request.createdAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                type,
                style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 16,
                    fontWeight: FontWeight.w800),
              ),
            ),
            Text(_relativeTime(when),
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.location_on, size: 16, color: AppColors.accentRed),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                camera?.displayLocation ?? 'Locating…',
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
        if (bundle.request.distanceKm != null)
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 4),
            child: Text('${bundle.request.distanceKm!.toStringAsFixed(1)} km away',
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
          ),
        if (showMapButton && camera != null && camera.hasLocation) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: hasTeam
                  ? () => _openTeamTrackingMap(bundle, camera, incident, assignment!)
                  : () => _openDispatchMap(bundle, camera, incident),
              icon: Icon(hasTeam ? Icons.near_me_outlined : Icons.map_outlined, size: 17),
              label: Text(hasTeam ? 'TRACK TEAM' : 'VIEW ON MAP'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentBlue,
                side: BorderSide(color: AppColors.border(context)),
                padding: const EdgeInsets.symmetric(vertical: 10),
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openDispatchMap(
    _RequestBundle bundle,
    _CameraInfo camera,
    _IncidentInfo? incident,
  ) async {
    final roster = await _loadTanodRoster();
    if (roster == null || !mounted) return; // no roster -> nothing to pick from
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _DispatchMapScreen(
          camera: camera,
          title: incident == null ? 'Incident' : _titleCase(incident.alertType),
          incidentIcon: _incidentIcon(incident?.alertType ?? ''),
          onDispatch: bundle.assignment == null ? (sel) => _assignTanod(bundle, sel) : null,
          roster: roster,
          assignedIds: bundle.assignment?.memberIds.toSet() ?? const {},
          busyIds: _busyTanodIds,
        ),
      ),
    );
  }

  /// Opens the tracking map for ONE incident: only the tanod dispatched to
  /// it are passed in as the roster, so nobody else appears on the map.
  Future<void> _openTeamTrackingMap(
    _RequestBundle bundle,
    _CameraInfo camera,
    _IncidentInfo? incident,
    _AssignmentInfo assignment,
  ) async {
    var team = bundle.team;
    if (team.isEmpty) {
      // Team profiles haven't resolved yet — pull them from the purok roster.
      final all = await _loadTanodRoster();
      if (!mounted) return;
      team = (all ?? const <_TanodProfile>[])
          .where((t) => assignment.memberIds.contains(t.id))
          .toList();
    }
    // Any member whose profile still can't be found gets a placeholder so
    // they're still listed (and tracked) rather than silently dropped.
    final known = team.map((t) => t.id).toSet();
    team = [
      ...team,
      for (final id in assignment.memberIds)
        if (!known.contains(id))
          _TanodProfile(id: id, fullName: 'Assigned tanod', role: _kTanodRole),
    ];

    final leadId = assignment.teamLeadId ??
        (assignment.memberIds.isNotEmpty ? assignment.memberIds.first : null);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _DispatchMapScreen(
          camera: camera,
          title: incident == null ? 'Tracking Team' : _titleCase(incident.alertType),
          incidentIcon: _incidentIcon(incident?.alertType ?? ''),
          roster: team,
          assignedIds: assignment.memberIds.toSet(),
          trackAssignedTeam: true,
          teamLeadId: leadId,
        ),
      ),
    );
  }

  Widget _assignButton(_RequestBundle bundle) {
    final isAssigning = _assigningRequestIds.contains(bundle.request.id);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: isAssigning ? null : () => _openAssignSheet(bundle),
        icon: isAssigning
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
              )
            : const Icon(Icons.groups_outlined, size: 18),
        label: Text(isAssigning ? 'ASSIGNING…' : 'ASSIGN TANOD'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accentBlue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  /// One combined action: opens the map where the leader picks tanod
  /// directly on the pins and dispatches from the bottom bar. Falls back
  /// to the list sheet only if the camera has no coordinates.
  Widget _pendingCard(_RequestBundle bundle) {
    final camera = bundle.camera;
    final hasMap = camera != null && camera.hasLocation;
    final isAssigning = _assigningRequestIds.contains(bundle.request.id);

    return _cardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _incidentHeader(bundle, showMapButton: false),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              // Camera still loading -> disabled.
              onPressed: (isAssigning || camera == null)
                  ? null
                  : () => hasMap
                      ? _openDispatchMap(bundle, camera, bundle.incident)
                      : _openAssignSheet(bundle),
              icon: isAssigning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                    )
                  : Icon(hasMap ? Icons.map_outlined : Icons.groups_outlined, size: 18),
              label: Text(isAssigning
                  ? 'DISPATCHING…'
                  : (hasMap ? 'VIEW MAP & DISPATCH' : 'ASSIGN TANOD')),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                disabledBackgroundColor: AppColors.accentBlue.withOpacity(0.4),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _activeCard(_RequestBundle bundle) {
    final assignment = bundle.assignment;
    final stillResolving =
        assignment == null && !_assignmentLookupAttempted.contains(bundle.request.id);

    return _cardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _incidentHeader(bundle),
          const SizedBox(height: 12),
          if (stillResolving)
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.textMuted(context)),
                ),
                const SizedBox(width: 8),
                Text('Loading assignment…',
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
              ],
            )
          else if (assignment == null)
            _assignButton(bundle)
          else ...[
            _assignmentStatusRow(assignment),
            const SizedBox(height: 8),
            _teamSection(bundle, assignment),
          ],
        ],
      ),
    );
  }

  /// For Review card: incident info, the outcome tag with the exact time the
  /// report reached this leader, and the VIEW REPORT / SUBMIT actions.
  /// No TRACK TEAM button and no "tanod assigned" list here — the team is
  /// shown inside the report details screen instead.
  Widget _reviewCard(_RequestBundle bundle) {
    final report = bundle.report;
    if (report == null) return const SizedBox.shrink();

    final isFinalizing = _finalizingRequestIds.contains(bundle.request.id);
    final color = _reviewOutcomeColor(context, report.outcome);

    return _cardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _incidentHeader(bundle, showMapButton: false),
          const SizedBox(height: 12),
          Row(
            children: [
              _pill(_reviewOutcomeLabel(report.outcome), color,
                  icon: _reviewOutcomeIcon(report.outcome)),
              const SizedBox(width: 8),
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule_outlined,
                        size: 13, color: AppColors.textMuted(context)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Sent ${_formatSentTime(report.submittedAt)}',
                        style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openReviewDetail(bundle),
                  icon: const Icon(Icons.visibility_outlined, size: 17),
                  label: const Text('VIEW REPORT'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textMain(context),
                    side: BorderSide(color: AppColors.border(context)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isFinalizing ? null : () => _finalizeFromCard(bundle),
                  icon: isFinalizing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                        )
                      : const Icon(Icons.send_outlined, size: 17),
                  label: Text(isFinalizing ? 'SUBMITTING…' : 'SUBMIT'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _assignmentStatusRow(_AssignmentInfo assignment) {
    final (label, color, icon) = switch (assignment.status) {
      'en_route' => ('EN ROUTE', AppColors.accentBlue, Icons.directions_run),
      _kCompletedStatus => ('COMPLETED', AppColors.accentGreen, Icons.check_circle_outline),
      _ => ('DISPATCHED', AppColors.accentRed, Icons.notifications_active),
    };
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800)),
      ],
    );
  }

  /// Team list for an Active card. Collapsible by default; pass
  /// `alwaysOpen: true` to keep every member visible with no toggle.
  Widget _teamSection(_RequestBundle bundle, _AssignmentInfo assignment,
      {bool alwaysOpen = false}) {
    final requestId = bundle.request.id;
    final expanded = alwaysOpen || _expandedTeamRequestIds.contains(requestId);
    final count = bundle.team.isNotEmpty ? bundle.team.length : assignment.memberIds.length;

    final teamList = Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.sunken(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: bundle.team.isEmpty
          ? Text('Team details unavailable.',
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 12))
          : Column(
              children: [
                for (var i = 0; i < bundle.team.length; i++)
                  _teamMemberRow(context, bundle.team[i], assignment.teamLeadId,
                      isLast: i == bundle.team.length - 1),
              ],
            ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: alwaysOpen ? null : () => _toggleTeamExpanded(requestId),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.groups_outlined, size: 15, color: AppColors.textMuted(context)),
                const SizedBox(width: 6),
                Text(
                  '$count tanod assigned',
                  style: TextStyle(
                      color: AppColors.textMuted(context), fontSize: 12, fontWeight: FontWeight.w600),
                ),
                if (!alwaysOpen) ...[
                  const Spacer(),
                  Text(
                    expanded ? 'HIDE TEAM' : 'VIEW TEAM',
                    style: TextStyle(
                        color: AppColors.accentBlue, fontSize: 11, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 2),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: AppColors.accentBlue),
                ],
              ],
            ),
          ),
        ),
        if (alwaysOpen)
          teamList
        else
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: teamList,
            secondChild: const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// Result of the assign-tanod sheet: the selected member ids, and which one
/// of them is the team lead (equal to the sole member for a solo dispatch).
class _AssignSelection {
  final List<String> memberIds;
  final String leadId;
  _AssignSelection({required this.memberIds, required this.leadId});
}

// ============================================================================
// ASSIGN TANOD SHEET — list fallback, used only when a camera has no
// coordinates (so there is no map to pick from).
//  • incident + location shown on top
//  • search box
//  • available tanod first, nearest first
//  • busy tanod are locked and labelled "ACTIVE DISPATCH"
//  • tap to select; first pick is team lead (tap the star to change)
// ============================================================================

class _AssignTanodSheet extends StatefulWidget {
  final List<_TanodProfile> roster;
  final Set<String> busyIds;
  final Map<String, double> distanceKm;
  final String incidentTitle;
  final String locationLabel;

  const _AssignTanodSheet({
    required this.roster,
    required this.busyIds,
    required this.distanceKm,
    required this.incidentTitle,
    required this.locationLabel,
  });

  @override
  State<_AssignTanodSheet> createState() => _AssignTanodSheetState();
}

class _AssignTanodSheetState extends State<_AssignTanodSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  final List<String> _selectedIds = [];
  String? _leadId;
  String _query = '';

  late final List<_TanodProfile> _sorted = _buildSorted();

  List<_TanodProfile> _buildSorted() {
    final list = [...widget.roster];
    list.sort((a, b) {
      final aBusy = widget.busyIds.contains(a.id);
      final bBusy = widget.busyIds.contains(b.id);
      if (aBusy != bBusy) return aBusy ? 1 : -1; // available first
      final da = widget.distanceKm[a.id];
      final db = widget.distanceKm[b.id];
      if (da != null && db != null) return da.compareTo(db);
      if (da != null) return -1;
      if (db != null) return 1;
      return a.fullName.compareTo(b.fullName);
    });
    return list;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String? get _nearestId {
    for (final t in _sorted) {
      if (!widget.busyIds.contains(t.id) && widget.distanceKm[t.id] != null) return t.id;
    }
    return null;
  }

  String _fmt(double km) =>
      km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km';

  void _toggle(String id) {
    if (widget.busyIds.contains(id)) return; // busy tanod can't be selected
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      if (_leadId == null || !_selectedIds.contains(_leadId)) {
        _leadId = _selectedIds.isEmpty ? null : _selectedIds.first;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final maxHeight = mq.size.height - mq.viewInsets.bottom - mq.padding.top - 12;
    final sheetHeight = math.min(mq.size.height * 0.85, maxHeight);

    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? _sorted
        : _sorted.where((t) => t.fullName.toLowerCase().contains(q)).toList();
    final nearestId = _nearestId;
    final n = _selectedIds.length;

    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        height: sheetHeight,
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.border(context), borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Assign Tanod',
                            style: TextStyle(
                                color: AppColors.textMain(context),
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(
                          widget.locationLabel.isEmpty
                              ? widget.incidentTitle
                              : '${widget.incidentTitle} • ${widget.locationLabel}',
                          style: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Text('$n selected',
                      style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(color: AppColors.textMain(context), fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search tanod',
                  hintStyle: TextStyle(color: AppColors.textMuted(context)),
                  prefixIcon:
                      Icon(Icons.search, size: 20, color: AppColors.textMuted(context)),
                  filled: true,
                  fillColor: AppColors.sunken(context),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.border(context)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.border(context)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.accentBlue, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: AppColors.border(context)),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text('No tanod found.',
                          style: TextStyle(color: AppColors.textMuted(context), fontSize: 13)),
                    )
                  : ListView.builder(
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final tanod = visible[i];
                        final selected = _selectedIds.contains(tanod.id);
                        final busy = widget.busyIds.contains(tanod.id);
                        final isLead = _leadId == tanod.id;
                        final distance = widget.distanceKm[tanod.id];

                        return Opacity(
                          opacity: busy ? 0.6 : 1,
                          child: ListTile(
                            enabled: !busy,
                            onTap: busy ? null : () => _toggle(tanod.id),
                            selected: selected,
                            selectedTileColor: AppColors.accentBlue.withOpacity(0.07),
                            leading: CircleAvatar(
                              radius: 18,
                              backgroundColor:
                                  (busy ? AppColors.accentRed : AppColors.accentGreen)
                                      .withOpacity(0.15),
                              child: Text(tanod.initials,
                                  style: TextStyle(
                                      color: busy
                                          ? AppColors.accentRed
                                          : AppColors.accentGreen,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12)),
                            ),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(tanod.fullName,
                                      style: TextStyle(
                                          color: AppColors.textMain(context), fontSize: 14),
                                      overflow: TextOverflow.ellipsis),
                                ),
                                if (busy) ...[
                                  const SizedBox(width: 6),
                                  _pill('ACTIVE DISPATCH', AppColors.accentRed),
                                ] else if (tanod.id == nearestId) ...[
                                  const SizedBox(width: 6),
                                  _pill('NEAREST', AppColors.accentGreen),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              [
                                if (distance != null) '${_fmt(distance)} away',
                                busy ? 'On active dispatch' : 'Available',
                              ].join(' • '),
                              style: TextStyle(
                                color: busy
                                    ? AppColors.accentRed
                                    : AppColors.textMuted(context),
                                fontSize: 11.5,
                              ),
                            ),
                            trailing: busy
                                ? null
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (selected && n > 1)
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          icon: Icon(
                                              isLead ? Icons.star : Icons.star_border,
                                              color: AppColors.accentRed),
                                          onPressed: () =>
                                              setState(() => _leadId = tanod.id),
                                        ),
                                      Checkbox(
                                        value: selected,
                                        activeColor: AppColors.accentBlue,
                                        onChanged: (_) => _toggle(tanod.id),
                                      ),
                                    ],
                                  ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(18, 10, 18, 12 + mq.padding.bottom),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.border(context))),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: n == 0 || _leadId == null
                      ? null
                      : () => Navigator.of(context).pop(
                            _AssignSelection(
                                memberIds: List.of(_selectedIds), leadId: _leadId!),
                          ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentBlue,
                    disabledBackgroundColor: AppColors.accentBlue.withOpacity(0.4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                    n == 0 ? 'SELECT A TANOD' : 'DISPATCH $n TANOD',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen report review, opened by tapping "View Report" on a For
/// Review card. Everything here is read-only except the "WHAT HAPPENED"
/// description at the bottom, which is a plain editable text field with
/// its own small SAVE button. This exists because some tanod aren't
/// confident writers — the leader can clean up that one block of text
/// before it goes to command center, without touching anything else the
/// tanod filed (sections, outcome tag, photos all stay exactly as-is).
class _ReportReviewScreen extends StatefulWidget {
  final _RequestBundle bundle;
  final bool isSubmitting;
  final bool isSavingEdits;
  final VoidCallback onSubmit;

  /// Called when the leader saves their edited description. Returns
  /// whether the save succeeded.
  final Future<bool> Function(String narrative) onSaveNarrative;

  const _ReportReviewScreen({
    required this.bundle,
    required this.isSubmitting,
    required this.isSavingEdits,
    required this.onSubmit,
    required this.onSaveNarrative,
  });

  @override
  State<_ReportReviewScreen> createState() => _ReportReviewScreenState();
}

class _ReportReviewScreenState extends State<_ReportReviewScreen> {
  late TextEditingController _narrativeController;
  String _savedText = '';

  _IncidentReportInfo? get _report => widget.bundle.report;

  bool get _hasUnsavedChanges => _narrativeController.text.trim() != _savedText.trim();

  @override
  void initState() {
    super.initState();
    _savedText = _report?.narrative ?? '';
    _narrativeController = TextEditingController(text: _savedText)..addListener(_onTextChanged);
  }

  void _onTextChanged() => setState(() {}); // keeps the SAVE button's enabled state current

  @override
  void didUpdateWidget(covariant _ReportReviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A fresh realtime row can replace the bundle while this screen is
    // open. Only resync the field from it when the leader has no unsaved
    // typing, so an in-progress edit is never clobbered.
    final newNarrative = widget.bundle.report?.narrative ?? '';
    if (!_hasUnsavedChanges && newNarrative != _savedText) {
      _savedText = newNarrative;
      _narrativeController.text = newNarrative;
    }
  }

  @override
  void dispose() {
    _narrativeController.removeListener(_onTextChanged);
    _narrativeController.dispose();
    super.dispose();
  }

  Future<void> _saveNarrative() async {
    final text = _narrativeController.text.trim();
    final ok = await widget.onSaveNarrative(text);
    if (ok && mounted) setState(() => _savedText = text);
  }

  BoxDecoration _cardDecoration(BuildContext context) => BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      );

  Widget _sectionLabel(BuildContext context, String text) => Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: AppColors.textMuted(context).withOpacity(0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            text,
            style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5),
          ),
        ],
      );

  void _openPhoto(BuildContext context, List<String> paths, int startIndex) {
    HapticFeedback.selectionClick();
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _ReviewPhotoViewerDialog(
        urls: paths.map(_reviewPhotoUrl).toList(),
        initialIndex: startIndex,
      ),
    );
  }

  InputDecoration _editDecoration(BuildContext context, {String? hint}) => InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textMuted(context).withOpacity(0.6)),
        filled: true,
        fillColor: AppColors.sunken(context),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.border(context)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.border(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.accentBlue, width: 1.5),
        ),
      );

  Widget _sectionBlock(BuildContext context, _ReviewSection section) {
    final meta = _reviewSectionMeta(section.header);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(color: meta.color.withOpacity(0.12), shape: BoxShape.circle),
          child: Icon(meta.icon, size: 15, color: meta.color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                section.header,
                style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1),
              ),
              const SizedBox(height: 7),
              if (section.items.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < section.items.length; i++)
                      Padding(
                        padding: EdgeInsets.only(bottom: i == section.items.length - 1 ? 0 : 7),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(top: 6, right: 9),
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: meta.color),
                            ),
                            Expanded(
                              child: Text(
                                section.items[i],
                                style: TextStyle(
                                    color: AppColors.textMain(context), fontSize: 13, height: 1.45),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                )
              else
                Text(
                  section.value ?? '—',
                  style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.35),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bundle = widget.bundle;
    final report = _report;
    final incident = bundle.incident;
    final assignment = bundle.assignment;
    if (report == null) {
      return Scaffold(
        backgroundColor: AppColors.bg(context),
        appBar: AppBar(title: const Text('Report Details')),
        body: const Center(child: Text('Report not available.')),
      );
    }
    final color = _reviewOutcomeColor(context, report.outcome);

    // Full team (lead + every member). If profiles haven't resolved yet,
    // fall back to placeholders built from member_ids so nobody is dropped.
    final List<_TanodProfile> reviewTeam;
    if (assignment == null) {
      reviewTeam = const [];
    } else if (bundle.team.isNotEmpty) {
      final known = bundle.team.map((t) => t.id).toSet();
      reviewTeam = [
        ...bundle.team,
        for (final id in assignment.memberIds)
          if (!known.contains(id))
            _TanodProfile(id: id, fullName: 'Assigned tanod', role: _kTanodRole),
      ];
    } else {
      reviewTeam = [
        for (final id in assignment.memberIds)
          _TanodProfile(id: id, fullName: 'Assigned tanod', role: _kTanodRole),
      ];
    }

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.card(context),
            border: Border(bottom: BorderSide(color: AppColors.border(context), width: 1)),
          ),
          child: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: AppColors.textMain(context),
            centerTitle: true,
            title: Text('Review Report',
                style: TextStyle(
                    color: AppColors.textMain(context), fontSize: 18, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Header: incident, timestamp, outcome, location ---
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: _cardDecoration(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration:
                            BoxDecoration(color: color.withOpacity(0.12), shape: BoxShape.circle),
                        child: Icon(_reviewOutcomeIcon(report.outcome), color: color, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(incident?.alertType.toUpperCase() ?? 'INCIDENT',
                                style: TextStyle(
                                    color: AppColors.textMain(context),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2)),
                            const SizedBox(height: 3),
                            Text(
                              'Sent ${_formatSentTime(report.submittedAt)}',
                              style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Divider(height: 1, color: AppColors.border(context)),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                            color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(7)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_reviewOutcomeIcon(report.outcome), size: 12, color: color),
                            const SizedBox(width: 5),
                            Text(_reviewOutcomeLabel(report.outcome),
                                style: TextStyle(
                                    color: color, fontSize: 11, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                      if (bundle.camera != null) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Row(
                            children: [
                              Icon(Icons.location_on_outlined,
                                  size: 14, color: AppColors.textMuted(context)),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  bundle.camera!.displayLocation,
                                  style:
                                      TextStyle(color: AppColors.textMuted(context), fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // --- Responding team (lead + all members) ---
            if (assignment != null && reviewTeam.isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionLabel(context, 'RESPONDING TEAM · ${reviewTeam.length}'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: _cardDecoration(context),
                child: Column(
                  children: [
                    for (var i = 0; i < reviewTeam.length; i++)
                      _teamMemberRow(
                        context,
                        reviewTeam[i],
                        assignment.teamLeadId,
                        isLast: i == reviewTeam.length - 1,
                      ),
                  ],
                ),
              ),
            ],

            // --- Structured report sections ---
            if (report.sections.isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionLabel(context, 'REPORT DETAILS'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: _cardDecoration(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < report.sections.length; i++) ...[
                      _sectionBlock(context, report.sections[i]),
                      if (i != report.sections.length - 1) ...[
                        const SizedBox(height: 14),
                        Divider(height: 1, color: AppColors.border(context)),
                        const SizedBox(height: 14),
                      ],
                    ],
                  ],
                ),
              ),
            ],

            // --- Narrative (the one editable field on this screen) ---
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _sectionLabel(context, 'WHAT HAPPENED'),
                if (widget.isSavingEdits)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton.icon(
                    onPressed: _hasUnsavedChanges ? _saveNarrative : null,
                    icon: const Icon(Icons.check, size: 15),
                    label: const Text('SAVE'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accentBlue,
                      disabledForegroundColor: AppColors.textMuted(context).withOpacity(0.4),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: _cardDecoration(context),
              child: TextField(
                controller: _narrativeController,
                maxLines: null,
                minLines: 5,
                style: TextStyle(color: AppColors.textMain(context), fontSize: 13.5, height: 1.55),
                decoration: _editDecoration(context, hint: 'Describe what happened…'),
              ),
            ),

            // --- Photos (view-only, not editable) ---
            if (report.photoPaths.isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionLabel(context, 'PHOTOS · ${report.photoPaths.length}'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: _cardDecoration(context),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: report.photoPaths.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemBuilder: (context, i) {
                    final url = _reviewPhotoUrl(report.photoPaths[i]);
                    return GestureDetector(
                      onTap: () => _openPhoto(context, report.photoPaths, i),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          url,
                          fit: BoxFit.cover,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return Container(
                              color: AppColors.sunken(context),
                              child: Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: AppColors.accentBlue),
                                ),
                              ),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: AppColors.sunken(context),
                            child: Icon(Icons.broken_image_outlined,
                                size: 20, color: AppColors.textMuted(context)),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          12 + MediaQuery.of(context).padding.bottom,
        ),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          border: Border(top: BorderSide(color: AppColors.border(context), width: 1)),
        ),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            // Blocked while there's an unsaved description edit sitting in
            // the field, so a leader can't submit before it's written back.
            onPressed: (widget.isSubmitting || _hasUnsavedChanges) ? null : widget.onSubmit,
            icon: widget.isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                  )
                : const Icon(Icons.send_outlined, size: 18),
            label: Text(
              widget.isSubmitting
                  ? 'SUBMITTING…'
                  : (_hasUnsavedChanges ? 'SAVE DESCRIPTION FIRST' : 'SUBMIT TO COMMAND CENTER'),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentGreen,
              disabledBackgroundColor: AppColors.accentGreen.withOpacity(0.4),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen swipeable photo viewer for the review screen — same simple
/// swipe/tap-to-dismiss viewer TanodReportHistoryScreen uses, duplicated
/// locally (rather than imported) to match this file's existing
/// one-class-per-file convention for private widgets.
class _ReviewPhotoViewerDialog extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;

  const _ReviewPhotoViewerDialog({required this.urls, required this.initialIndex});

  @override
  State<_ReviewPhotoViewerDialog> createState() => _ReviewPhotoViewerDialogState();
}

class _ReviewPhotoViewerDialogState extends State<_ReviewPhotoViewerDialog> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _currentIndex = widget.initialIndex;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.urls.length,
                onPageChanged: (i) => setState(() => _currentIndex = i),
                itemBuilder: (context, i) => InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: Image.network(
                      widget.urls[i],
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.broken_image_outlined,
                        size: 48,
                        color: Colors.white.withOpacity(0.6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 40,
            right: 16,
            child: SafeArea(
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.close, color: Colors.white, size: 20),
                ),
              ),
            ),
          ),
          if (widget.urls.length > 1)
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  '${_currentIndex + 1} / ${widget.urls.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
    );
  }
}