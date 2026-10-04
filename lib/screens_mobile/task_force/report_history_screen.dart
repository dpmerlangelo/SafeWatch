import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../constants/app_colors.dart';

/// One row from `incident_reports` where source_type = 'task_force'.
///
/// `sourceId`: the `task_force_dispatches.id` this report belongs to —
/// used to look up who was actually dispatched (team lead + members)
/// so the history screen can show that roster and decide who besides
/// the report's author is allowed to see it.
/// `reportSections`: the structured categories (Individuals Involved,
/// Injuries/Casualties, incident-type details, etc.), read from the
/// `report_sections` jsonb column. Each entry's `header` can be renamed
/// straight from the Supabase table editor without touching this app.
/// `reportText`: the free-text "what happened" narrative.
/// `photoPaths`: Storage paths from `photo_paths`, resolved into
/// viewable thumbnails.
/// `status`: review/workflow status of the report itself (separate
/// from `outcome`, which is what happened on scene). Currently every
/// report is simply "Submitted", so this is kept on the model but no
/// longer shown as a status badge in the UI (see `_statusMeta`
/// removal below).
class _TaskForceReport {
  final String id;
  final String incidentId;
  final String sourceId;
  final List<_ReportSection> sections;
  final String narrative;
  final String? outcome;
  final String? status;
  final List<String> photoPaths;
  final DateTime submittedAt;

  _TaskForceReport({
    required this.id,
    required this.incidentId,
    required this.sourceId,
    required this.sections,
    required this.narrative,
    required this.outcome,
    required this.status,
    required this.photoPaths,
    required this.submittedAt,
  });

  factory _TaskForceReport.fromMap(Map<String, dynamic> row) {
    final rawSections = row['report_sections'];
    final sections = rawSections is List
        ? rawSections
            .whereType<Map>()
            .map((e) => _ReportSection.fromMap(e.cast<String, dynamic>()))
            .toList()
        : <_ReportSection>[];

    final rawPhotos = row['photo_paths'];
    final photoPaths = rawPhotos is List
        ? rawPhotos.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    return _TaskForceReport(
      id: row['id'].toString(),
      incidentId: row['incident_id'].toString(),
      sourceId: (row['source_id'] ?? '').toString(),
      sections: sections,
      narrative: (row['report_text'] ?? '').toString(),
      outcome: row['outcome'] as String?,
      status: row['status'] as String?,
      photoPaths: photoPaths,
      submittedAt:
          DateTime.tryParse(row['submitted_at']?.toString() ?? '')?.toLocal() ??
              DateTime.now(),
    );
  }
}

/// A single structured category from `report_sections`: either a
/// one-line `value` (e.g. "Individuals Involved: 3") or a bulleted
/// `items` list (e.g. the incident-type-specific block).
class _ReportSection {
  final String header;
  final String? value;
  final List<String> items;

  _ReportSection({required this.header, required this.value, required this.items});

  factory _ReportSection.fromMap(Map<String, dynamic> map) {
    final rawItems = map['items'];
    return _ReportSection(
      header: (map['header'] ?? '').toString(),
      value: map['value'] as String?,
      items: rawItems is List ? rawItems.map((e) => e.toString()).toList() : const [],
    );
  }
}

/// The detected-incident record this report is about, resolved from
/// the `incidents` table (the same table backing the alerts grid —
/// id / camera_id / alert_type / alert_level / occurred_at / image_path
/// / video_path). Used so the history list can show *what* was
/// detected ("Violence", "Fire", ...) instead of a raw incident uuid.
/// `cameraId` is further resolved to a human-readable place name via
/// `_CameraMeta` / `_ensureCamerasLoaded` below.
class _IncidentMeta {
  final String id;
  final String alertType;
  final String? alertLevel;
  final String? cameraId;
  final DateTime? occurredAt;
  final String? imagePath;
  final String? videoPath;

  _IncidentMeta({
    required this.id,
    required this.alertType,
    required this.alertLevel,
    required this.cameraId,
    required this.occurredAt,
    required this.imagePath,
    required this.videoPath,
  });

  factory _IncidentMeta.fromMap(Map<String, dynamic> row) {
    return _IncidentMeta(
      id: row['id'].toString(),
      alertType: (row['alert_type'] ?? '').toString(),
      alertLevel: row['alert_level'] as String?,
      cameraId: row['camera_id']?.toString(),
      occurredAt: DateTime.tryParse(row['occurred_at']?.toString() ?? '')?.toLocal(),
      imagePath: row['image_path'] as String?,
      videoPath: row['video_path'] as String?,
    );
  }
}

/// A resolved `cameras` row, so the history/detail screens can show a
/// real place name ("Lobby — Main Entrance") instead of a raw camera
/// uuid. Adjust the column read in `fromMap` if your `cameras` table
/// names its human-readable field something other than `location`
/// (e.g. `name` or `label` — both are tried as a fallback).
class _CameraMeta {
  final String id;
  final String location;

  _CameraMeta({required this.id, required this.location});

  factory _CameraMeta.fromMap(Map<String, dynamic> row) {
    final loc = (row['location'] ?? row['name'] ?? row['label'] ?? '').toString().trim();
    return _CameraMeta(
      id: row['id'].toString(),
      location: loc.isEmpty ? 'Unknown location' : loc,
    );
  }
}

/// One assigned Task Force member's profile, resolved from `profiles`
/// so the history screen can show real names/roles instead of raw
/// uuids for the dispatch a report came from.
class _MemberProfile {
  final String id;
  final String fullName;
  final String role;

  _MemberProfile({required this.id, required this.fullName, required this.role});

  factory _MemberProfile.fromMap(Map<String, dynamic> row) {
    final first = (row['first_name'] ?? '').toString().trim();
    final last = (row['last_name'] ?? '').toString().trim();
    final name = '$first $last'.trim();
    return _MemberProfile(
      id: row['id'].toString(),
      fullName: name.isEmpty ? 'Unnamed member' : name,
      role: (row['role'] ?? '').toString().trim(),
    );
  }

  String get initials {
    final parts = fullName.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

/// The resolved team (lead + members) for one `task_force_dispatches`
/// row, keyed by dispatch id in `_teamCache` below. `members` is
/// already sorted lead-first the same way the home screen's roster is.
class _DispatchTeam {
  final String? teamLeadId;
  final List<String> memberIds;
  final List<_MemberProfile> members;

  _DispatchTeam({required this.teamLeadId, required this.memberIds, required this.members});

  /// A report tied to this dispatch is visible to `userId` if they
  /// were the lead OR anywhere in the assigned member list — not just
  /// whoever happened to tap SUBMIT REPORT.
  bool includesUser(String userId) =>
      userId.isNotEmpty && (teamLeadId == userId || memberIds.contains(userId));

  _MemberProfile? get lead =>
      members.where((m) => m.id == teamLeadId).cast<_MemberProfile?>().firstOrNull;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

typedef _OutcomeMeta = ({String label, Color color, IconData icon});
typedef _AlertMeta = ({String label, Color color, IconData icon});
typedef _ReportSectionMeta = ({IconData icon, Color color});

String _titleCase(String s) {
  if (s.isEmpty) return s;
  return s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

/// Maps a report's `outcome` (what happened on scene) to a label/color/icon.
_OutcomeMeta _outcomeMeta(String? outcome) {
  switch (outcome) {
    case 'resolved':
      return (
        label: 'Resolved on scene',
        color: AppColors.accentGreen,
        icon: Icons.check_circle_outline,
      );
    case 'escalated':
      return (
        label: 'Escalated further',
        color: AppColors.accentRed,
        icon: Icons.arrow_upward,
      );
    case 'false_alarm':
      return (
        label: 'False alarm',
        color: AppColors.accentOrange,
        icon: Icons.info_outline,
      );
    case 'ongoing':
      return (
        label: 'Ongoing — monitoring',
        color: AppColors.accentBlue,
        icon: Icons.autorenew,
      );
    case 'no_action_needed':
      return (
        label: 'No action needed',
        color: AppColors.accentPurple,
        icon: Icons.remove_circle_outline,
      );
    default:
      return (
        label: outcome ?? 'Unspecified',
        color: AppColors.accentBlue,
        icon: Icons.help_outline,
      );
  }
}

/// Maps the detected incident's `alert_type` to a label/color/icon so
/// the history list can lead with "what was detected" rather than an
/// incident uuid. Falls back to a generic look while the incident
/// record is still being resolved or if the type is unrecognized.
_AlertMeta _alertMeta(String? alertType) {
  final normalized = (alertType ?? '').trim().toLowerCase();
  switch (normalized) {
    case 'violence':
      return (
        label: 'Violence',
        color: AppColors.accentRed,
        icon: Icons.warning_amber_outlined,
      );
    case 'fire':
      return (
        label: 'Fire',
        color: AppColors.accentOrange,
        icon: Icons.local_fire_department_outlined,
      );
    case 'theft':
      return (
        label: 'Theft',
        color: AppColors.accentPurple,
        icon: Icons.shopping_bag_outlined,
      );
    case 'accident':
      return (
        label: 'Accident',
        color: AppColors.accentBlue,
        icon: Icons.car_crash_outlined,
      );
    case 'medical':
      return (
        label: 'Medical',
        color: AppColors.accentGreen,
        icon: Icons.medical_services_outlined,
      );
    case '':
      return (
        label: 'Incident',
        color: AppColors.accentBlue,
        icon: Icons.report_problem_outlined,
      );
    default:
      return (
        label: _titleCase(normalized),
        color: AppColors.accentBlue,
        icon: Icons.report_problem_outlined,
      );
  }
}

/// Maps a `_ReportSection.header` (a free-text label set from the
/// Supabase table editor) to an icon/color so the Report Details card
/// reads as a scannable list of categories rather than a wall of
/// labeled text. Matched loosely by keyword since headers are
/// editable and not a fixed enum; falls back to a generic look for
/// anything unrecognized.
_ReportSectionMeta _reportSectionMeta(String header) {
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

/// Public URL for a photo stored under the `incident_report` bucket.
/// If that bucket is actually private, swap this for
/// `createSignedUrl(path, expiresIn)` instead.
String _photoUrl(String path) =>
    Supabase.instance.client.storage.from('incident_report').getPublicUrl(path);

/// Read-only history of Task Force reports, shown as a simple grouped
/// table (icon / detected incident / camera & time), same pattern as
/// a bank statement or transaction list. Tapping a row opens a
/// full-screen report detail rather than expanding in place.
///
/// VISIBILITY: a report is visible to a member if they were the team
/// lead OR anywhere in `member_ids` on the `task_force_dispatches` row
/// the report came from (`incident_reports.source_id`), resolved via
/// `_ensureTeamsLoaded` below and cached in `_teamCache` per dispatch
/// id.
///
/// IMPORTANT — this is UI-side filtering only. If `incident_reports`'
/// RLS currently restricts SELECT to `reported_by = auth.uid()`,
/// non-lead members' Supabase queries won't even receive those rows
/// over the realtime stream, so this screen will still look empty for
/// them regardless of this filtering. You'll want an RLS policy
/// roughly like:
///   USING (
///     reported_by = auth.uid()
///     OR EXISTS (
///       SELECT 1 FROM task_force_dispatches d
///       WHERE d.id = incident_reports.source_id
///         AND (d.team_lead_id = auth.uid()
///              OR d.member_ids @> to_jsonb(auth.uid()::text))
///     )
///   )
/// so a member can actually read reports for dispatches they were
/// assigned to, not just ones they personally filed.
class TaskForceReportHistoryScreen extends StatefulWidget {
  final bool isActive;
  const TaskForceReportHistoryScreen({super.key, required this.isActive});

  @override
  State<TaskForceReportHistoryScreen> createState() =>
      _TaskForceReportHistoryScreenState();
}

class _TaskForceReportHistoryScreenState extends State<TaskForceReportHistoryScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  late final Stream<List<Map<String, dynamic>>> _reportsStream;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _outcomeFilter; // null = all outcomes

  // --- TEAM RESOLUTION ------------------------------------------------
  //
  // Resolved team (lead + members) per `task_force_dispatches.id`,
  // populated lazily as reports referencing that dispatch stream in.
  // Drives both the visibility check (`_DispatchTeam.includesUser`) and
  // the roster shown on each report.
  final Map<String, _DispatchTeam> _teamCache = {};
  final Set<String> _teamFetchInFlight = {};
  // Dispatch ids we've already tried and gotten nothing back for
  // (deleted dispatch, or blocked by RLS) — kept separately from
  // `_teamCache` so we don't retry every single stream tick, but the
  // report itself then simply never becomes visible rather than
  // crashing the screen.
  final Set<String> _teamFetchFailed = {};

  // --- INCIDENT RESOLUTION ---------------------------------------------
  //
  // Resolved `incidents` row per `incident_reports.incident_id`, so the
  // list/detail screens can show the detected incident type
  // ("Violence", "Fire", ...) instead of a raw incident uuid.
  final Map<String, _IncidentMeta> _incidentCache = {};
  final Set<String> _incidentFetchInFlight = {};
  final Set<String> _incidentFetchFailed = {};

  // --- CAMERA RESOLUTION ------------------------------------------------
  //
  // Resolved `cameras` row per `incidents.camera_id`, so the list/detail
  // screens can show a real place name instead of a raw camera uuid.
  // Populated once the owning incident has resolved (camera ids come
  // from `_incidentCache`, not directly from the report).
  final Map<String, _CameraMeta> _cameraCache = {};
  final Set<String> _cameraFetchInFlight = {};
  final Set<String> _cameraFetchFailed = {};

  @override
  void initState() {
    super.initState();
    // Filtered client-side below by dispatch membership, since
    // `.stream()` filters only support a single eq on the primary key
    // path — same constraint the desktop screens work around
    // elsewhere in this app.
    _reportsStream = _supabase
        .from('incident_reports')
        .stream(primaryKey: ['id'])
        .order('submitted_at', ascending: false);

    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String get _userId => _supabase.auth.currentUser?.id ?? '';

  /// Fetches (and caches) the team — lead + members, resolved to real
  /// names/roles — for every dispatch id in `dispatchIds` not already
  /// known or already tried and failed. Safe to call repeatedly (e.g.
  /// once per stream tick); it only ever fetches what's missing.
  Future<void> _ensureTeamsLoaded(Iterable<String> dispatchIds) async {
    final toFetch = dispatchIds
        .where((id) => id.isNotEmpty)
        .where((id) => !_teamCache.containsKey(id))
        .where((id) => !_teamFetchInFlight.contains(id))
        .where((id) => !_teamFetchFailed.contains(id))
        .toSet();
    if (toFetch.isEmpty) return;

    _teamFetchInFlight.addAll(toFetch);
    try {
      final dispatchRows = await _supabase
          .from('task_force_dispatches')
          .select('id, team_lead_id, member_ids')
          .inFilter('id', toFetch.toList());

      final rows = (dispatchRows as List).cast<Map<String, dynamic>>();

      // Batch-resolve every lead/member id across all of these
      // dispatches in one `profiles` query instead of one per dispatch.
      final allIds = <String>{};
      for (final row in rows) {
        final leadId = row['team_lead_id']?.toString();
        if (leadId != null && leadId.isNotEmpty) allIds.add(leadId);
        allIds.addAll(((row['member_ids'] as List?) ?? []).map((e) => e.toString()));
      }

      final profileById = <String, _MemberProfile>{};
      if (allIds.isNotEmpty) {
        final profileRows = await _supabase
            .from('profiles')
            .select('id, first_name, last_name, role')
            .inFilter('id', allIds.toList());
        for (final r in (profileRows as List).cast<Map<String, dynamic>>()) {
          final p = _MemberProfile.fromMap(r);
          profileById[p.id] = p;
        }
      }

      for (final row in rows) {
        final dispatchId = row['id'].toString();
        final leadId = row['team_lead_id']?.toString();
        final memberIds =
            ((row['member_ids'] as List?) ?? []).map((e) => e.toString()).toList();

        final resolvedIds = <String>{
          if (leadId != null && leadId.isNotEmpty) leadId,
          ...memberIds,
        };
        final members = resolvedIds
            .map((id) =>
                profileById[id] ?? _MemberProfile(id: id, fullName: 'Unnamed member', role: ''))
            .toList()
          ..sort((a, b) {
            final aLead = a.id == leadId;
            final bLead = b.id == leadId;
            if (aLead == bLead) return a.fullName.compareTo(b.fullName);
            return aLead ? -1 : 1; // lead always first
          });

        _teamCache[dispatchId] =
            _DispatchTeam(teamLeadId: leadId, memberIds: memberIds, members: members);
      }

      // Anything requested that didn't come back (deleted dispatch, or
      // blocked by RLS) — remember so we stop retrying it every tick.
      for (final id in toFetch) {
        if (!_teamCache.containsKey(id)) _teamFetchFailed.add(id);
      }
    } catch (_) {
      // Leave these ids out of both _teamCache and _teamFetchFailed so
      // a transient network blip gets retried on the next stream tick
      // instead of permanently hiding the report.
    } finally {
      _teamFetchInFlight.removeAll(toFetch);
      if (mounted) setState(() {});
    }
  }

  /// Fetches (and caches) the detected-incident record — alert type,
  /// camera, timestamps — for every incident id in `incidentIds` not
  /// already known or already tried and failed. Mirrors
  /// `_ensureTeamsLoaded` above. Assumes the alerts table is named
  /// `incidents`; rename the `.from(...)` call below if yours differs.
  Future<void> _ensureIncidentsLoaded(Iterable<String> incidentIds) async {
    final toFetch = incidentIds
        .where((id) => id.isNotEmpty)
        .where((id) => !_incidentCache.containsKey(id))
        .where((id) => !_incidentFetchInFlight.contains(id))
        .where((id) => !_incidentFetchFailed.contains(id))
        .toSet();
    if (toFetch.isEmpty) return;

    _incidentFetchInFlight.addAll(toFetch);
    try {
      final rows = await _supabase
          .from('incidents')
          .select('id, alert_type, alert_level, camera_id, occurred_at, image_path, video_path')
          .inFilter('id', toFetch.toList());

      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final meta = _IncidentMeta.fromMap(r);
        _incidentCache[meta.id] = meta;
      }

      for (final id in toFetch) {
        if (!_incidentCache.containsKey(id)) _incidentFetchFailed.add(id);
      }
    } catch (_) {
      // Retry on the next stream tick instead of hiding the row.
    } finally {
      _incidentFetchInFlight.removeAll(toFetch);
      if (mounted) setState(() {});
    }
  }

  /// Fetches (and caches) the camera location — for every camera id in
  /// `cameraIds` not already known or already tried and failed. Mirrors
  /// `_ensureIncidentsLoaded` above. Assumes the table is named
  /// `cameras`; rename the `.from(...)` call below if yours differs.
  Future<void> _ensureCamerasLoaded(Iterable<String> cameraIds) async {
    final toFetch = cameraIds
        .where((id) => id.isNotEmpty)
        .where((id) => !_cameraCache.containsKey(id))
        .where((id) => !_cameraFetchInFlight.contains(id))
        .where((id) => !_cameraFetchFailed.contains(id))
        .toSet();
    if (toFetch.isEmpty) return;

    _cameraFetchInFlight.addAll(toFetch);
    try {
      final rows = await _supabase
          .from('cameras')
          .select('id, location')
          .inFilter('id', toFetch.toList());

      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final meta = _CameraMeta.fromMap(r);
        _cameraCache[meta.id] = meta;
      }

      for (final id in toFetch) {
        if (!_cameraCache.containsKey(id)) _cameraFetchFailed.add(id);
      }
    } catch (_) {
      // Retry on the next stream tick instead of hiding the row.
    } finally {
      _cameraFetchInFlight.removeAll(toFetch);
      if (mounted) setState(() {});
    }
  }

  void _openDetail(_TaskForceReport report) {
    HapticFeedback.selectionClick();
    final incident = _incidentCache[report.incidentId];
    final camera = incident?.cameraId != null ? _cameraCache[incident!.cameraId] : null;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => _TaskForceReportDetailScreen(
          report: report,
          incident: incident,
          camera: camera,
          team: _teamCache[report.sourceId],
          currentUserId: _userId,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // Incoming screen slides in from the right; the screen
          // underneath nudges slightly left to sell the depth,
          // and both reverse on pop.
          final slideIn = Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));

          final slideOutUnderneath = Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(-0.15, 0),
          ).animate(CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOutCubic));

          return SlideTransition(
            position: slideOutUnderneath,
            child: SlideTransition(
              position: slideIn,
              child: child,
            ),
          );
        },
      ),
    );
  }

  /// Buckets reports into "Today" / "Yesterday" / a formatted date,
  /// preserving the incoming (already newest-first) order within each
  /// bucket.
  List<MapEntry<String, List<_TaskForceReport>>> _groupByDate(
      List<_TaskForceReport> reports) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final map = <String, List<_TaskForceReport>>{};
    for (final r in reports) {
      final d = DateTime(r.submittedAt.year, r.submittedAt.month, r.submittedAt.day);
      final String key;
      if (d == today) {
        key = 'Today';
      } else if (d == yesterday) {
        key = 'Yesterday';
      } else {
        key = DateFormat('MMMM d, yyyy').format(d);
      }
      map.putIfAbsent(key, () => []).add(r);
    }
    return map.entries.toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bg(context),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _reportsStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _buildSkeletonList(context);
          }
          if (snapshot.hasError) {
            return _buildErrorState(context, snapshot.error.toString());
          }

          final taskForceReports = (snapshot.data ?? [])
              .where((row) => row['source_type'] == 'task_force')
              .map((row) => _TaskForceReport.fromMap(row))
              .toList();

          // Make sure we have (or are fetching) the team, the
          // detected-incident record, and the camera location for
          // everything referenced here. Camera ids can only be
          // computed once their owning incident has resolved, so this
          // set may start empty and grow over the next couple of
          // stream ticks — that's expected.
          final dispatchIds =
              taskForceReports.map((r) => r.sourceId).where((id) => id.isNotEmpty).toSet();
          final incidentIds =
              taskForceReports.map((r) => r.incidentId).where((id) => id.isNotEmpty).toSet();
          final cameraIds = taskForceReports
              .map((r) => _incidentCache[r.incidentId]?.cameraId)
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toSet();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _ensureTeamsLoaded(dispatchIds);
              _ensureIncidentsLoaded(incidentIds);
              _ensureCamerasLoaded(cameraIds);
            }
          });

          final stillResolving = dispatchIds
              .any((id) => !_teamCache.containsKey(id) && !_teamFetchFailed.contains(id));

          final allReports = taskForceReports.where((r) {
            final team = _teamCache[r.sourceId];
            return team != null && team.includesUser(_userId);
          }).toList();

          if (allReports.isEmpty) {
            // Distinguish "still figuring out which reports you can
            // see" from "you really don't have any" so the list
            // doesn't flash an empty state for a split second on
            // every load.
            if (stillResolving) return _buildSkeletonList(context);
            return _buildEmptyState(context);
          }

          final filtered = allReports.where((r) {
            final matchesOutcome = _outcomeFilter == null || r.outcome == _outcomeFilter;
            final alertLabel = _alertMeta(_incidentCache[r.incidentId]?.alertType)
                .label
                .toLowerCase();
            final matchesSearch = _searchQuery.isEmpty ||
                alertLabel.contains(_searchQuery) ||
                r.incidentId.toLowerCase().contains(_searchQuery);
            return matchesOutcome && matchesSearch;
          }).toList();

          final grouped = _groupByDate(filtered);

          return Column(
            children: [
              _buildFilterBar(context, allReports, filtered.length),
              Expanded(
                child: filtered.isEmpty
                    ? _buildNoResultsState(context)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics()),
                        itemCount: grouped.length,
                        itemBuilder: (context, sectionIndex) {
                          final entry = grouped[sectionIndex];
                          return Padding(
                            padding: EdgeInsets.only(
                                top: sectionIndex == 0 ? 12 : 22, bottom: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildDateHeader(context, entry.key, entry.value.length),
                                const SizedBox(height: 10),
                                _buildReportsTable(context, entry.value),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  // --- TABLE-STYLE REPORT LIST ---

  /// One rounded "table" per date group: a flat list of rows separated
  /// by thin dividers, like a bank statement — icon, detected incident,
  /// camera location & time, chevron. Tapping a row opens the full
  /// detail screen.
  Widget _buildReportsTable(BuildContext context, List<_TaskForceReport> reports) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < reports.length; i++) ...[
            _ReportRow(
              report: reports[i],
              incident: _incidentCache[reports[i].incidentId],
              camera: _incidentCache[reports[i].incidentId]?.cameraId != null
                  ? _cameraCache[_incidentCache[reports[i].incidentId]!.cameraId]
                  : null,
              team: _teamCache[reports[i].sourceId],
              currentUserId: _userId,
              onTap: () => _openDetail(reports[i]),
            ),
            if (i != reports.length - 1)
              Divider(height: 1, indent: 62, color: AppColors.border(context)),
          ],
        ],
      ),
    );
  }

  // --- FILTER BAR ---

  Widget _buildFilterBar(
      BuildContext context, List<_TaskForceReport> allReports, int resultCount) {
    final outcomes = <String?>[
      null,
      'resolved',
      'ongoing',
      'escalated',
      'false_alarm',
      'no_action_needed',
    ].where((o) => o == null || allReports.any((r) => r.outcome == o)).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        border: Border(bottom: BorderSide(color: AppColors.border(context))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.sunken(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search,
                          size: 18, color: AppColors.textMuted(context)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          style: TextStyle(
                              color: AppColors.textMain(context), fontSize: 13.5),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'Search by incident type',
                            hintStyle: TextStyle(
                                color: AppColors.textMuted(context), fontSize: 13.5),
                          ),
                        ),
                      ),
                      if (_searchQuery.isNotEmpty)
                        GestureDetector(
                          onTap: () => _searchController.clear(),
                          child: Icon(Icons.close,
                              size: 16, color: AppColors.textMuted(context)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 30,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: outcomes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final outcome = outcomes[i];
                final selected = _outcomeFilter == outcome;
                final label = outcome == null ? 'All' : _outcomeMeta(outcome).label;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _outcomeFilter = selected ? null : outcome);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.textMain(context)
                          : AppColors.sunken(context),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? AppColors.bg(context)
                            : AppColors.textMuted(context),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // --- DATE SECTION HEADER ---

  Widget _buildDateHeader(BuildContext context, String label, int count) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMain(context),
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '· $count',
          style: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
        ),
      ],
    );
  }

  // --- EMPTY / ERROR / NO-RESULTS STATES ---

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.sunken(context),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.fact_check_outlined,
                  size: 34, color: AppColors.textMuted(context)),
            ),
            const SizedBox(height: 16),
            Text(
              "No reports for your dispatches yet",
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              "Reports filed for dispatches you're part of — as lead or team member — will show up here.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResultsState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_alt_off_outlined,
                size: 30, color: AppColors.textMuted(context)),
            const SizedBox(height: 12),
            Text(
              'No reports match your filters',
              style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () {
                _searchController.clear();
                setState(() => _outcomeFilter = null);
              },
              child: Text(
                'Clear filters',
                style: TextStyle(
                    color: AppColors.accentBlue,
                    fontSize: 13,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 30, color: AppColors.accentRed),
            const SizedBox(height: 12),
            Text(
              "Couldn't load your reports",
              style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // --- SKELETON LOADING ---

  Widget _buildSkeletonList(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border(context)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < 5; i++) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      _ShimmerBox(
                          width: 38, height: 38, borderRadius: BorderRadius.circular(19)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _ShimmerBox(width: 100, height: 12),
                            const SizedBox(height: 6),
                            _ShimmerBox(width: 140, height: 10),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (i != 4) Divider(height: 1, indent: 62, color: AppColors.border(context)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One row in the table-style history list: icon (colored by detected
/// incident type), the detected incident label, a subtitle (team lead
/// or camera location + time), and a chevron. Tapping opens the full
/// report detail screen.
class _ReportRow extends StatelessWidget {
  final _TaskForceReport report;
  final _IncidentMeta? incident;
  final _CameraMeta? camera;
  final _DispatchTeam? team;
  final String currentUserId;
  final VoidCallback onTap;

  const _ReportRow({
    required this.report,
    required this.incident,
    required this.camera,
    required this.team,
    required this.currentUserId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final alert = _alertMeta(incident?.alertType);
    final lead = team?.lead;

    final subtitleParts = <String>[];
    if (lead != null) {
      subtitleParts.add(lead.id == currentUserId ? '${lead.fullName} (You)' : lead.fullName);
    } else if (camera != null) {
      subtitleParts.add(camera!.location);
    } else if (incident?.cameraId != null && incident!.cameraId!.isNotEmpty) {
      // Camera location hasn't resolved yet — show a neutral
      // placeholder rather than a raw uuid.
      subtitleParts.add('Camera');
    }
    subtitleParts.add(DateFormat('h:mm a').format(report.submittedAt));
    final subtitle = subtitleParts.join(' · ');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: alert.color.withOpacity(0.12), shape: BoxShape.circle),
              child: Icon(alert.icon, size: 18, color: alert.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alert.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 14,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted(context)),
          ],
        ),
      ),
    );
  }
}

Widget _badge(String label, Color color, IconData? icon) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
        ] else ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 6),
        ],
        Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

/// One row in the "Dispatched Team" roster: initials avatar, name
/// (+ "(You)" for the signed-in member), role, and a LEAD badge for
/// the team lead.
///
/// `isLast` suppresses the row's own bottom gap so the surrounding
/// card's padding is the only thing determining the space above the
/// first row and below the last one — otherwise the last row would
/// get its own bottom margin *plus* the card's padding, making the
/// bottom of the roster noticeably taller than the top.
Widget _teamMemberRow(
  BuildContext context,
  _MemberProfile member,
  String? teamLeadId,
  String currentUserId, {
  bool isLast = false,
}) {
  final isLead = member.id == teamLeadId;
  final isMe = member.id == currentUserId;
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
                  isMe ? '${member.fullName} (You)' : member.fullName,
                  style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
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

/// Renders one structured report category as a scannable row: a
/// colored icon (picked from the header's keywords via
/// `_reportSectionMeta`), the header with an item-count chip when it's
/// a list, and either the single value or a bulleted list of items
/// styled as compact tick marks rather than plain bullet dots.
Widget _sectionBlock(BuildContext context, _ReportSection section) {
  final meta = _reportSectionMeta(section.header);

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

/// Shared card chrome for every block on the detail screen — same
/// radius, border, and a very soft shadow, so the whole screen reads
/// as one consistent design system instead of a stack of ad-hoc boxes.
BoxDecoration _detailCardDecoration(BuildContext context) => BoxDecoration(
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

/// Full-screen report detail, opened by tapping a row in the history
/// table. Shows the detected incident, outcome, camera location,
/// dispatched team, structured report sections, the narrative, and
/// photos.
class _TaskForceReportDetailScreen extends StatelessWidget {
  final _TaskForceReport report;
  final _IncidentMeta? incident;
  final _CameraMeta? camera;
  final _DispatchTeam? team;
  final String currentUserId;

  const _TaskForceReportDetailScreen({
    required this.report,
    required this.incident,
    required this.camera,
    required this.team,
    required this.currentUserId,
  });

  void _openPhoto(BuildContext context, List<String> paths, int startIndex) {
    HapticFeedback.selectionClick();
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _PhotoViewerDialog(
        urls: paths.map(_photoUrl).toList(),
        initialIndex: startIndex,
      ),
    );
  }

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

  @override
  Widget build(BuildContext context) {
    final alert = _alertMeta(incident?.alertType);
    final outcome = _outcomeMeta(report.outcome);
    final hasCameraInfo = incident?.cameraId != null && incident!.cameraId!.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.card(context),
            border: Border(
              bottom: BorderSide(color: AppColors.border(context), width: 1),
            ),
          ),
          child: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: AppColors.textMain(context),
            centerTitle: true,
            title: Text('Report Details',
                style: TextStyle(
                    color: AppColors.textMain(context), fontSize: 18, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Header: detected incident, timestamp, outcome, location ---
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: _detailCardDecoration(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration:
                            BoxDecoration(color: alert.color.withOpacity(0.12), shape: BoxShape.circle),
                        child: Icon(alert.icon, color: alert.color, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(alert.label,
                                style: TextStyle(
                                    color: AppColors.textMain(context),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2)),
                            const SizedBox(height: 3),
                            Text(
                              DateFormat('MMMM d, yyyy · h:mm a').format(report.submittedAt),
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
                      _badge(outcome.label, outcome.color, outcome.icon),
                      if (hasCameraInfo) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Row(
                            children: [
                              Icon(Icons.location_on_outlined,
                                  size: 14, color: AppColors.textMuted(context)),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  camera?.location ?? 'Resolving location…',
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

            // --- Dispatched team ---
            if (team != null && team!.members.isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionLabel(context, 'DISPATCHED TEAM'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: _detailCardDecoration(context),
                child: Column(
                  children: [
                    for (var i = 0; i < team!.members.length; i++)
                      _teamMemberRow(
                        context,
                        team!.members[i],
                        team!.teamLeadId,
                        currentUserId,
                        isLast: i == team!.members.length - 1,
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
                decoration: _detailCardDecoration(context),
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

            // --- Narrative ---
            if (report.narrative.trim().isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionLabel(context, 'WHAT HAPPENED'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: _detailCardDecoration(context),
                child: Text(
                  report.narrative,
                  style: TextStyle(color: AppColors.textMain(context), fontSize: 13.5, height: 1.55),
                ),
              ),
            ],

            // --- Photos ---
            if (report.photoPaths.isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionLabel(context, 'PHOTOS · ${report.photoPaths.length}'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: _detailCardDecoration(context),
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
                    final url = _photoUrl(report.photoPaths[i]);
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
    );
  }
}

/// Lightweight pulsing placeholder used while the stream's first page
/// is loading, so the list doesn't jump from a bare spinner straight
/// to content.
class _ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;

  const _ShimmerBox({required this.width, required this.height, this.borderRadius});

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: AppColors.sunken(context).withOpacity(0.4 + _controller.value * 0.4),
            borderRadius: widget.borderRadius ?? BorderRadius.circular(6),
          ),
        );
      },
    );
  }
}

/// Full-screen swipeable viewer for report photos, opened by tapping a
/// thumbnail. Simple pinch-free viewer — swipe between photos, tap the
/// close button or backdrop to dismiss.
class _PhotoViewerDialog extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;

  const _PhotoViewerDialog({required this.urls, required this.initialIndex});

  @override
  State<_PhotoViewerDialog> createState() => _PhotoViewerDialogState();
}

class _PhotoViewerDialogState extends State<_PhotoViewerDialog> {
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
                  decoration: const BoxDecoration(
                      color: Colors.black54, shape: BoxShape.circle),
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