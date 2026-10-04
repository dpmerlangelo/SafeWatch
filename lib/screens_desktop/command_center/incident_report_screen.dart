import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:file_saver/file_saver.dart';
import '../../services/realtime_stream_service.dart';
import '../../services/incident_report_link_service.dart';
import '../../constants/app_colors.dart';

// This screen borrows UsersScreen's dashboard shell — page header with
// title/subtitle/primary action, a row of stat cards, a toolbar with a
// search field + segmented filters, and a bordered content card with a
// header row and a footer pager — so command center's screens read as one
// consistent design system.
//
// The report list is intentionally a table (rows), NOT a card grid: reports
// are dense, comparable records (time / source / incident / outcome /
// reporter / location).
//
// DETAILS: tapping a row opens a centered dialog (two columns on wide
// screens, one on narrow). The main column holds the narrative, structured
// report details and photos; the side column holds the linked incident, the
// full responding team (leader + members, with a marker on whoever sent the
// report) and the endorsement.
//
// TEAM: `incident_reports.source_id` is treated as the id of the dispatch row
// the report came from (`task_force_dispatches` for 'task_force',
// `tanod_dispatches` for 'tanod'); both carry `team_lead_id` + `member_ids`.
//
// LINKING: the detail dialog has a "Linked incident" card that asks the
// IncidentReportLinkService to open the incident on the Incidents screen,
// and this screen listens for requests from the Incidents screen to open a
// specific report (see `_handleLinkRequest`).
//
// EXPORT: the header "Export PDF" button builds a portrait A4 PDF containing
// just a simple bordered report table for the reports currently shown, and downloads it straight away
// through `file_saver` — no print dialog. Needs `pdf` + `file_saver`.

// --- MODELS -----------------------------------------------------------

/// One structured category from `report_sections`: either a one-line
/// `value` or a bulleted `items` list. Headers are free-text, editable
/// from the Supabase table editor, and matched loosely by keyword in
/// `_reportSectionMeta` below.
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

/// One row from `incident_reports`, either source_type.
class _IncidentReport {
  final String id;
  final String incidentId;
  final String sourceType; // 'task_force' | 'tanod'
  final String sourceId;
  final String? reportedBy;
  final List<_ReportSection> sections;
  final String narrative;
  final String? outcome;
  final String? status;
  final List<String> photoPaths;
  final DateTime submittedAt;
  final String? endorsedBy;
  final String? endorsedNote;
  final DateTime? endorsedAt;

  _IncidentReport({
    required this.id,
    required this.incidentId,
    required this.sourceType,
    required this.sourceId,
    required this.reportedBy,
    required this.sections,
    required this.narrative,
    required this.outcome,
    required this.status,
    required this.photoPaths,
    required this.submittedAt,
    required this.endorsedBy,
    required this.endorsedNote,
    required this.endorsedAt,
  });

  factory _IncidentReport.fromMap(Map<String, dynamic> row) {
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

    return _IncidentReport(
      id: row['id'].toString(),
      incidentId: (row['incident_id'] ?? '').toString(),
      sourceType: (row['source_type'] ?? '').toString(),
      sourceId: (row['source_id'] ?? '').toString(),
      reportedBy: row['reported_by']?.toString(),
      sections: sections,
      narrative: (row['report_text'] ?? '').toString(),
      outcome: row['outcome'] as String?,
      status: row['status'] as String?,
      photoPaths: photoPaths,
      submittedAt:
          DateTime.tryParse(row['submitted_at']?.toString() ?? '')?.toLocal() ??
              DateTime.now(),
      endorsedBy: row['endorsed_by']?.toString(),
      endorsedNote: row['endorsed_note'] as String?,
      endorsedAt: DateTime.tryParse(row['endorsed_at']?.toString() ?? '')?.toLocal(),
    );
  }
}

/// Resolved `incidents` row so the grid/dialog can show the detected
/// incident type ("Violence", "Fire", ...) instead of a raw uuid.
class _IncidentMeta {
  final String id;
  final String alertType;
  final String? alertLevel;
  final String? cameraId;
  final DateTime? occurredAt;

  _IncidentMeta({
    required this.id,
    required this.alertType,
    required this.alertLevel,
    required this.cameraId,
    required this.occurredAt,
  });

  factory _IncidentMeta.fromMap(Map<String, dynamic> row) {
    return _IncidentMeta(
      id: row['id'].toString(),
      alertType: (row['alert_type'] ?? '').toString(),
      alertLevel: row['alert_level'] as String?,
      cameraId: row['camera_id']?.toString(),
      occurredAt: DateTime.tryParse(row['occurred_at']?.toString() ?? '')?.toLocal(),
    );
  }
}

/// Resolved `cameras` row, for a real place name instead of a uuid.
class _CameraMeta {
  final String location;
  _CameraMeta({required this.location});
  factory _CameraMeta.fromMap(Map<String, dynamic> row) {
    final loc = (row['location'] ?? row['name'] ?? row['label'] ?? '').toString().trim();
    return _CameraMeta(location: loc.isEmpty ? 'Unknown location' : loc);
  }
}

/// A resolved `profiles` row — used for `reported_by`, `endorsed_by` and
/// every member of the responding team, since they're all user ids on the
/// same table.
class _ProfileMeta {
  final String fullName;
  final String role;
  _ProfileMeta({required this.fullName, required this.role});
  factory _ProfileMeta.fromMap(Map<String, dynamic> row) {
    final first = (row['first_name'] ?? '').toString().trim();
    final last = (row['last_name'] ?? '').toString().trim();
    final name = '$first $last'.trim();
    return _ProfileMeta(
      fullName: name.isEmpty ? 'Unnamed user' : name,
      role: (row['role'] ?? '').toString().trim(),
    );
  }
}

/// Team assigned to the dispatch a report came from: the leader plus the
/// member ids (which may or may not include the leader).
class _DispatchTeam {
  final String? leadId;
  final List<String> memberIds;
  _DispatchTeam({required this.leadId, required this.memberIds});

  factory _DispatchTeam.fromMap(Map<String, dynamic> row) {
    final raw = row['member_ids'];
    return _DispatchTeam(
      leadId: row['team_lead_id']?.toString(),
      memberIds: raw is List
          ? raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
          : <String>[],
    );
  }
}

typedef _OutcomeMeta = ({String label, Color color, IconData icon});
typedef _AlertMeta = ({String label, Color color, IconData icon});
typedef _SourceMeta = ({String label, Color color, IconData icon});
typedef _ReportSectionMeta = ({IconData icon, Color color});

String _titleCase(String s) {
  if (s.isEmpty) return s;
  return s.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

_OutcomeMeta _outcomeMeta(String? outcome) {
  switch (outcome) {
    case 'resolved':
      return (label: 'Resolved on scene', color: AppColors.accentGreen, icon: Icons.check_circle_outline);
    case 'escalated':
      return (label: 'Escalated further', color: AppColors.accentRed, icon: Icons.arrow_upward);
    case 'false_alarm':
      return (label: 'False alarm', color: AppColors.accentOrange, icon: Icons.info_outline);
    case 'ongoing':
      return (label: 'Ongoing — monitoring', color: AppColors.accentBlue, icon: Icons.autorenew);
    case 'no_action_needed':
      return (label: 'No action needed', color: AppColors.accentPurple, icon: Icons.remove_circle_outline);
    default:
      return (label: outcome ?? 'Unspecified', color: AppColors.accentBlue, icon: Icons.help_outline);
  }
}

_AlertMeta _alertMeta(String? alertType) {
  final normalized = (alertType ?? '').trim().toLowerCase();
  switch (normalized) {
    case 'violence':
      return (label: 'Violence', color: AppColors.accentRed, icon: Icons.warning_amber_outlined);
    case 'fire':
      return (label: 'Fire', color: AppColors.accentOrange, icon: Icons.local_fire_department_outlined);
    case 'theft':
      return (label: 'Theft', color: AppColors.accentPurple, icon: Icons.shopping_bag_outlined);
    case 'accident':
      return (label: 'Accident', color: AppColors.accentBlue, icon: Icons.car_crash_outlined);
    case 'medical':
      return (label: 'Medical', color: AppColors.accentGreen, icon: Icons.medical_services_outlined);
    case '':
      return (label: 'Incident', color: AppColors.accentBlue, icon: Icons.report_problem_outlined);
    default:
      return (label: _titleCase(normalized), color: AppColors.accentBlue, icon: Icons.report_problem_outlined);
  }
}

_SourceMeta _sourceMeta(String sourceType) {
  switch (sourceType) {
    case 'task_force':
      return (label: 'Task Force', color: AppColors.accentBlue, icon: Icons.shield_outlined);
    case 'tanod':
      return (label: 'Tanod', color: AppColors.accentPurple, icon: Icons.local_police_outlined);
    default:
      return (label: sourceType.isEmpty ? 'Unknown' : _titleCase(sourceType), color: Colors.blueGrey, icon: Icons.group_outlined);
  }
}

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

/// Public URL for a photo under the `incident_report` bucket. Swap for
/// `createSignedUrl` if that bucket is actually private.
String _photoUrl(String path) =>
    Supabase.instance.client.storage.from('incident_report').getPublicUrl(path);

/// Small pill badge — colored dot/icon + label — used for outcome and
/// source in the details dialog header.
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

// --- DASHBOARD-STYLE SHARED WIDGETS (mirrors UsersScreen) --------------

/// Same stat-card shape/behavior as UsersScreen's `_StatCard`: icon chip,
/// big number, label, caption and a share bar, selectable to double as a
/// filter shortcut.
class _ReportStatCard extends StatefulWidget {
  final String label;
  final int value;
  final String caption;
  final IconData icon;
  final Color color;
  final double share;
  final bool selected;
  final VoidCallback onTap;

  const _ReportStatCard({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
    required this.share,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ReportStatCard> createState() => _ReportStatCardState();
}

class _ReportStatCardState extends State<_ReportStatCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.selected
                  ? c
                  : (_hover ? c.withOpacity(0.5) : AppColors.border(context)),
              width: widget.selected ? 1.6 : 1,
            ),
            boxShadow: _hover
                ? [BoxShadow(color: c.withOpacity(0.14), blurRadius: 18, offset: const Offset(0, 8))]
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
                    decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.circular(10)),
                    child: Icon(widget.icon, size: 18, color: c),
                  ),
                  const Spacer(),
                  Text(widget.caption,
                      style: TextStyle(color: AppColors.textMuted(context), fontSize: 11, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '${widget.value}',
                style: TextStyle(color: AppColors.textMain(context), fontSize: 28, height: 1, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                widget.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 12, fontWeight: FontWeight.w600),
              ),
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

/// Segmented source filter — same one-continuous-pill treatment as
/// UsersScreen's role filter.
class _SourceFilterSegmented extends StatelessWidget {
  final String selected; // 'All' | 'task_force' | 'tanod'
  final ValueChanged<String> onChanged;
  const _SourceFilterSegmented({required this.selected, required this.onChanged});

  Widget _segment(BuildContext context, String label, String value, Color color) {
    final isSelected = selected == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 30,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              // NOTE: animate to/from the SAME color at opacity 0, never
              // Colors.transparent (transparent *black*) — lerping through it
              // flashes a dark tint.
              color: isSelected ? color.withOpacity(0.16) : color.withOpacity(0),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? AppColors.textMain(context) : AppColors.textMuted(context),
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          _segment(context, 'All Sources', 'All', AppColors.accentBlue),
          _segment(context, _sourceMeta('task_force').label, 'task_force', _sourceMeta('task_force').color),
          _segment(context, _sourceMeta('tanod').label, 'tanod', _sourceMeta('tanod').color),
        ],
      ),
    );
  }
}

/// A hover-highlighted table row — same interaction language as
/// UsersScreen's `_UserRowTile`.
///
/// Hover fix: the row now animates between two REAL colors (card ->
/// sunken/selected tint) instead of Colors.transparent -> color, which
/// lerped through transparent black and flashed dark. The chevron fades with
/// AnimatedOpacity, and a slim accent bar on the left marks hover/selection.
class _ReportRowTile extends StatefulWidget {
  final _IncidentReport report;
  final _AlertMeta alert;
  final _OutcomeMeta outcome;
  final _SourceMeta source;
  final String reporterName;
  final String locationLabel;
  final String timeLabel;
  final bool isSelected;
  final VoidCallback onTap;

  const _ReportRowTile({
    super.key,
    required this.report,
    required this.alert,
    required this.outcome,
    required this.source,
    required this.reporterName,
    required this.locationLabel,
    required this.timeLabel,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_ReportRowTile> createState() => _ReportRowTileState();
}

class _ReportRowTileState extends State<_ReportRowTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final base = AppColors.card(context);
    final bg = widget.isSelected
        ? Color.alphaBlend(AppColors.accentBlue.withOpacity(0.10), base)
        : (_hover ? AppColors.sunken(context) : base);
    final highlighted = widget.isSelected || _hover;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: bg,
            border: Border(bottom: BorderSide(color: AppColors.border(context), width: 1)),
          ),
          // 17 + 3px accent bar = the 20px the header row uses, so columns
          // stay aligned with the table header.
          padding: const EdgeInsets.fromLTRB(17, 10, 20, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 3,
                height: 22,
                decoration: BoxDecoration(
                  color: AppColors.accentBlue.withOpacity(highlighted ? 1 : 0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(
                width: 70,
                child: Text(widget.timeLabel,
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 110,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.source.icon, size: 13, color: widget.source.color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(widget.source.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 150,
                child: Text(widget.alert.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppColors.textMain(context), fontWeight: FontWeight.w600, fontSize: 12.5)),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 150,
                child: Text(widget.outcome.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: widget.outcome.color, fontSize: 12.5, fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 150,
                child: Text(widget.reporterName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  widget.locationLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5),
                ),
              ),
              SizedBox(
                width: 22,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: highlighted ? 1 : 0,
                  child: Icon(Icons.chevron_right, size: 16, color: AppColors.textMain(context)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One person in the responding-team card: initials avatar (or a badge icon
/// for the leader), name, role, and chips for "Leader" / "Sent report".
class _TeamMemberTile extends StatelessWidget {
  final String name;
  final String role;
  final bool isLeader;
  final bool sentReport;
  const _TeamMemberTile({
    required this.name,
    required this.role,
    required this.isLeader,
    required this.sentReport,
  });

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
        child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    final color = isLeader ? AppColors.accentOrange : AppColors.accentBlue;
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color.withOpacity(0.14), shape: BoxShape.circle),
          child: isLeader
              ? Icon(Icons.workspace_premium_outlined, size: 17, color: color)
              : Text(_initials(name),
                  style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppColors.textMain(context), fontSize: 13, fontWeight: FontWeight.w700)),
              if (role.isNotEmpty)
                Text(_titleCase(role),
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Wrap(
          spacing: 4,
          children: [
            if (isLeader) _chip('Leader', AppColors.accentOrange),
            if (sentReport) _chip('Sent report', AppColors.accentGreen),
          ],
        ),
      ],
    );
  }
}

// --- SCREEN -------------------------------------------------------------

class IncidentReportScreen extends StatefulWidget {
  final bool isActive;
  const IncidentReportScreen({super.key, this.isActive = true});

  @override
  State<IncidentReportScreen> createState() => _IncidentReportScreenState();
}

class _IncidentReportScreenState extends State<IncidentReportScreen>
    with AutomaticKeepAliveClientMixin {
  Stream<List<Map<String, dynamic>>>? _reportsStream;

  _IncidentReport? _selectedReport;
  String _searchQuery = '';
  String _sourceFilter = 'All'; // 'All' | 'task_force' | 'tanod'
  String _outcomeFilter = 'All';

  // Latest parsed reports, so a link request from the Incidents screen can
  // find the report it wants to open.
  List<_IncidentReport> _latestReports = const [];
  bool _reportsLoaded = false;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // Details dialog state. `_dialogTick` is bumped whenever a lookup cache
  // changes so the (separate-route) dialog rebuilds with fresh names,
  // locations and team members.
  bool _dialogOpen = false;
  int _dialogToken = 0;
  final ValueNotifier<int> _dialogTick = ValueNotifier<int>(0);

  // Fullscreen photo viewer — pushed onto the root Overlay, which always
  // stacks above the dialog route.
  OverlayEntry? _photoOverlayEntry;

  // PDF export in progress (disables the Export button + shows a spinner).
  bool _exporting = false;

  int _currentPage = 0;
  static const int _rowsPerPage = 50;

  // --- RESOLUTION CACHES ---
  final Map<String, _IncidentMeta> _incidentCache = {};
  final Set<String> _incidentFetchInFlight = {};
  final Set<String> _incidentFetchFailed = {};

  final Map<String, _CameraMeta> _cameraCache = {};
  final Set<String> _cameraFetchInFlight = {};
  final Set<String> _cameraFetchFailed = {};

  // Keyed by user id, shared between reporter, endorser and team members.
  final Map<String, _ProfileMeta> _profileCache = {};
  final Set<String> _profileFetchInFlight = {};
  final Set<String> _profileFetchFailed = {};

  // Keyed by '<source_type>:<source_id>' -> the dispatch's team.
  final Map<String, _DispatchTeam> _teamCache = {};
  final Set<String> _teamFetchInFlight = {};
  final Set<String> _teamFetchFailed = {};

  final Map<String, _DispatchTeam?> _requesterTeamCache = {};
  final Set<String> _requesterInFlight = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initReportsStream();
    _searchFocusNode.addListener(() => setState(() {}));
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
        _currentPage = 0;
      });
    });
    IncidentReportLinkService.instance.pending.addListener(_handleLinkRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleLinkRequest());
  }

  @override
  void dispose() {
    IncidentReportLinkService.instance.pending.removeListener(_handleLinkRequest);
    _photoOverlayEntry?.remove();
    _dialogTick.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant IncidentReportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closeDetailDialog();
      });
    }
  }

  Future<void> _initReportsStream() async {
    final client = Supabase.instance.client;
    final session = await RealtimeStreamService.instance.waitForSession();
    if (session != null) {
      await client.realtime.setAuth(session.accessToken);
    }
    if (!mounted) return;
    setState(() {
      _reportsStream = RealtimeStreamService.instance
          .streamTable('incident_reports', primaryKey: ['id']);
    });
  }

  // --- DETAILS DIALOG OPEN / CLOSE ---

  void _closeDetailDialog() {
    _closePhotoViewer();
    if (_dialogOpen) Navigator.of(context, rootNavigator: true).pop();
  }

  void _openReportDialog(_IncidentReport report) {
    HapticFeedback.selectionClick();
    if (_dialogOpen) Navigator.of(context, rootNavigator: true).pop();
    final token = ++_dialogToken;
    setState(() {
      _selectedReport = report;
      _dialogOpen = true;
    });
    _ensureTeamLoaded(report);
    _ensureRequesterTeamLoaded(report);

    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (dialogContext) => ValueListenableBuilder<int>(
        valueListenable: _dialogTick,
        builder: (_, __, ___) => _buildReportDialog(dialogContext, report),
      ),
    ).then((_) {
      _closePhotoViewer();
      if (!mounted || token != _dialogToken) return;
      setState(() {
        _selectedReport = null;
        _dialogOpen = false;
      });
    });
  }

  /// Opens a specific report when the Incidents screen asks for it. Waits
  /// until the reports stream has delivered data; the build method retries
  /// every frame until then.
  void _handleLinkRequest() {
    final svc = IncidentReportLinkService.instance;
    final req = svc.pending.value;
    if (req == null || req.target != LinkTarget.report || !_reportsLoaded) return;
    svc.consume();

    final match = _latestReports.where((r) => r.id == req.id).firstOrNull;
    if (match == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That report could not be found.')),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _searchController.clear();
      _sourceFilter = 'All';
      _outcomeFilter = 'All';
      _currentPage = 0;
    });
    _openReportDialog(match);
  }

  // --- LOOKUP RESOLUTION (same "fetch what's missing, cache, retry on
  // failure only via a transient-vs-permanent split" pattern used
  // elsewhere in this app) ---

  Future<void> _ensureIncidentsLoaded(Iterable<String> ids) async {
    final toFetch = ids
        .where((id) => id.isNotEmpty)
        .where((id) => !_incidentCache.containsKey(id))
        .where((id) => !_incidentFetchInFlight.contains(id))
        .where((id) => !_incidentFetchFailed.contains(id))
        .toSet();
    if (toFetch.isEmpty) return;

    _incidentFetchInFlight.addAll(toFetch);
    try {
      final rows = await Supabase.instance.client
          .from('incidents')
          .select('id, alert_type, alert_level, camera_id, occurred_at')
          .inFilter('id', toFetch.toList());
      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final meta = _IncidentMeta.fromMap(r);
        _incidentCache[meta.id] = meta;
      }
      for (final id in toFetch) {
        if (!_incidentCache.containsKey(id)) _incidentFetchFailed.add(id);
      }
    } catch (_) {
      // Leave out of both caches so a transient failure retries next tick.
    } finally {
      _incidentFetchInFlight.removeAll(toFetch);
      if (mounted) {
        setState(() {});
        _dialogTick.value++;
      }
    }
  }

  Future<void> _ensureCamerasLoaded(Iterable<String> ids) async {
    final toFetch = ids
        .where((id) => id.isNotEmpty)
        .where((id) => !_cameraCache.containsKey(id))
        .where((id) => !_cameraFetchInFlight.contains(id))
        .where((id) => !_cameraFetchFailed.contains(id))
        .toSet();
    if (toFetch.isEmpty) return;

    _cameraFetchInFlight.addAll(toFetch);
    try {
      final rows = await Supabase.instance.client
          .from('cameras')
          .select('id, location')
          .inFilter('id', toFetch.toList());
      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        _cameraCache[r['id'].toString()] = _CameraMeta.fromMap(r);
      }
      for (final id in toFetch) {
        if (!_cameraCache.containsKey(id)) _cameraFetchFailed.add(id);
      }
    } catch (_) {
      // retried next tick
    } finally {
      _cameraFetchInFlight.removeAll(toFetch);
      if (mounted) {
        setState(() {});
        _dialogTick.value++;
      }
    }
  }

  Future<void> _ensureProfilesLoaded(Iterable<String> ids) async {
    final toFetch = ids
        .where((id) => id.isNotEmpty)
        .where((id) => !_profileCache.containsKey(id))
        .where((id) => !_profileFetchInFlight.contains(id))
        .where((id) => !_profileFetchFailed.contains(id))
        .toSet();
    if (toFetch.isEmpty) return;

    _profileFetchInFlight.addAll(toFetch);
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select('id, first_name, last_name, role')
          .inFilter('id', toFetch.toList());
      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        _profileCache[r['id'].toString()] = _ProfileMeta.fromMap(r);
      }
      for (final id in toFetch) {
        if (!_profileCache.containsKey(id)) _profileFetchFailed.add(id);
      }
    } catch (_) {
      // retried next tick
    } finally {
      _profileFetchInFlight.removeAll(toFetch);
      if (mounted) {
        setState(() {});
        _dialogTick.value++;
      }
    }
  }

  String _teamKey(_IncidentReport r) => '${r.sourceType}:${r.sourceId}';

  /// Loads the dispatch (task_force_dispatches / tanod_dispatches) this
  /// report came from, then the profiles of its leader + members.
  Future<void> _ensureTeamLoaded(_IncidentReport r) async {
    final key = _teamKey(r);
    if (r.sourceId.isEmpty ||
        _teamCache.containsKey(key) ||
        _teamFetchInFlight.contains(key) ||
        _teamFetchFailed.contains(key)) {
      return;
    }
    final String? table = switch (r.sourceType) {
      'task_force' => 'task_force_dispatches',
      'tanod' => 'tanod_dispatches',
      _ => null,
    };
    if (table == null) {
      _teamFetchFailed.add(key);
      if (mounted) _dialogTick.value++;
      return;
    }

    _teamFetchInFlight.add(key);
    try {
      final row = await Supabase.instance.client
          .from(table)
          .select('id, team_lead_id, member_ids')
          .eq('id', r.sourceId)
          .maybeSingle();
      if (row == null) {
        _teamFetchFailed.add(key);
      } else {
        final team = _DispatchTeam.fromMap(row);
        _teamCache[key] = team;
        await _ensureProfilesLoaded([
          if (team.leadId != null) team.leadId!,
          ...team.memberIds,
        ]);
      }
    } catch (_) {
      // transient failure: retried the next time a report is opened
    } finally {
      _teamFetchInFlight.remove(key);
      if (mounted) _dialogTick.value++;
    }
  }

  Future<void> _ensureRequesterTeamLoaded(_IncidentReport r) async {
    if (r.sourceType != 'task_force' || r.sourceId.isEmpty) return;
    final key = _teamKey(r);
    if (_requesterTeamCache.containsKey(key) || _requesterInFlight.contains(key)) return;

    _requesterInFlight.add(key);
    if (mounted) _dialogTick.value++;
    try {
      final client = Supabase.instance.client;

      final tf = await client
          .from('task_force_dispatches')
          .select('source_tanod_dispatch_id, taskforce_request_id')
          .eq('id', r.sourceId)
          .maybeSingle();

      // 1) direct link
      String tanodId = tf?['source_tanod_dispatch_id']?.toString() ?? '';

      // 2) via the taskforce request
      if (tanodId.isEmpty) {
        final reqId = tf?['taskforce_request_id']?.toString() ?? '';
        if (reqId.isNotEmpty) {
          final req = await client
              .from('taskforce_requests')
              .select('tanod_dispatch_id')
              .eq('id', reqId)
              .maybeSingle();
          tanodId = req?['tanod_dispatch_id']?.toString() ?? '';
        }
      }

      // 3) reverse link from the tanod dispatch
      if (tanodId.isEmpty) {
        final esc = await client
            .from('tanod_dispatches')
            .select('id')
            .eq('escalated_task_force_dispatch_id', r.sourceId)
            .limit(1)
            .maybeSingle();
        tanodId = esc?['id']?.toString() ?? '';
      }

      if (tanodId.isEmpty) {
        _requesterTeamCache[key] = null; // not requested by a tanod
      } else {
        final row = await client
            .from('tanod_dispatches')
            .select('id, team_lead_id, member_ids')
            .eq('id', tanodId)
            .maybeSingle();
        if (row == null) {
          _requesterTeamCache[key] = null;
        } else {
          final team = _DispatchTeam.fromMap(row);
          _requesterTeamCache[key] = team;
          await _ensureProfilesLoaded([
            if (team.leadId != null) team.leadId!,
            ...team.memberIds,
          ]);
        }
      }
    } catch (_) {
      // transient failure: not cached, retried next time the report is opened
    } finally {
      _requesterInFlight.remove(key);
      if (mounted) _dialogTick.value++;
    }
  }

  String _formatTimeOnly(DateTime d) => DateFormat('HH:mm:ss').format(d);
  String _formatFull(DateTime d) => DateFormat('MMM d, yyyy • h:mm a').format(d);

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin

    return _reportsStream == null
        ? const Center(child: CircularProgressIndicator(color: AppColors.accentBlue))
        : StreamBuilder<List<Map<String, dynamic>>>(
            stream: _reportsStream,
            builder: (context, snapshot) {
              final loading = snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData;

              final reports = (snapshot.data ?? const <Map<String, dynamic>>[])
                  .map((row) => _IncidentReport.fromMap(row))
                  .toList()
                ..sort((a, b) => b.submittedAt.compareTo(a.submittedAt));

              // Keep the latest list for link requests from the Incidents
              // screen, and retry any pending request once data is here.
              _latestReports = reports;
              _reportsLoaded = snapshot.hasData;
              WidgetsBinding.instance.addPostFrameCallback((_) => _handleLinkRequest());

              // Resolve incidents -> cameras -> profiles. Camera ids depend
              // on incidents having resolved first, so this set may start
              // empty and grow over the next couple of stream ticks —
              // expected.
              final incidentIds = reports.map((r) => r.incidentId).where((id) => id.isNotEmpty).toSet();
              final cameraIds = reports
                  .map((r) => _incidentCache[r.incidentId]?.cameraId)
                  .whereType<String>()
                  .where((id) => id.isNotEmpty)
                  .toSet();
              final profileIds = <String>{
                ...reports.map((r) => r.reportedBy).whereType<String>(),
                ...reports.map((r) => r.endorsedBy).whereType<String>(),
              }..removeWhere((id) => id.isEmpty);

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _ensureIncidentsLoaded(incidentIds);
                  _ensureCamerasLoaded(cameraIds);
                  _ensureProfilesLoaded(profileIds);
                }
              });

              final taskForceCount = reports.where((r) => r.sourceType == 'task_force').length;
              final tanodCount = reports.where((r) => r.sourceType == 'tanod').length;
              final escalatedCount = reports.where((r) => r.outcome == 'escalated').length;

              final filtered = reports.where((r) {
                final matchesSource = _sourceFilter == 'All' || r.sourceType == _sourceFilter;
                final matchesOutcome = _outcomeFilter == 'All' || r.outcome == _outcomeFilter;
                final alertLabel = _alertMeta(_incidentCache[r.incidentId]?.alertType).label.toLowerCase();
                final reporterName = (_profileCache[r.reportedBy]?.fullName ?? '').toLowerCase();
                final matchesSearch = _searchQuery.isEmpty ||
                    alertLabel.contains(_searchQuery) ||
                    reporterName.contains(_searchQuery) ||
                    r.narrative.toLowerCase().contains(_searchQuery);
                return matchesSource && matchesOutcome && matchesSearch;
              }).toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(reports.length),
                  const SizedBox(height: 18),
                  _buildStatCards(reports.length, taskForceCount, tanodCount, escalatedCount),
                  const SizedBox(height: 18),
                  _buildToolbar(filtered),
                  const SizedBox(height: 14),
                  Expanded(child: _buildContent(loading, reports, filtered)),
                ],
              );
            },
          );
  }

  // --- HEADER (title + subtitle + primary action, matches UsersScreen) ---

  Widget _buildHeader(int total) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Incident Reports',
                style: TextStyle(color: AppColors.textMain(context), fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                'Unified oversight of Task Force and Tanod field reports',
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- PDF EXPORT -------------------------------------------------------

  /// Exports the reports currently shown (filters applied) as a portrait PDF
  /// and downloads it immediately. Loads any missing incident / camera /
  /// profile lookups first so the table has real names and places.
  Future<void> _exportPdf(List<_IncidentReport> rows) async {
    if (_exporting || rows.isEmpty) return;
    setState(() => _exporting = true);
    try {
      await _ensureIncidentsLoaded(rows.map((r) => r.incidentId));
      await _ensureCamerasLoaded(
        rows.map((r) => _incidentCache[r.incidentId]?.cameraId).whereType<String>(),
      );
      await _ensureProfilesLoaded(rows.map((r) => r.reportedBy).whereType<String>());

      // Who is exporting: current signed-in user + their profile.
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) await _ensureProfilesLoaded([user.id]);
      final me = user == null ? null : _profileCache[user.id];
      final exportedBy = me?.fullName ?? user?.email ?? 'Unknown user';
      final exportedRole = me?.role ?? '';

      final bytes = await _buildPdf(rows, exportedBy: exportedBy, exportedRole: exportedRole);
      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await FileSaver.instance.saveFile(
        name: 'safewatch_incident_reports_$stamp',
        bytes: bytes,
        ext: 'pdf',
        mimeType: MimeType.pdf,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Downloaded ${rows.length} report${rows.length == 1 ? '' : 's'} as PDF'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not export PDF: $e')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// The built-in PDF fonts only cover Latin-1; swap common punctuation and
  /// replace anything else so text never renders as missing glyphs.
  String _pdfSafe(String s) {
    return s
        .replaceAll('•', '-')
        .replaceAll('—', '-')
        .replaceAll('–', '-')
        .replaceAll('…', '...')
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .runes
        .map((r) => r <= 0xFF ? String.fromCharCode(r) : '?')
        .join();
  }

  PdfColor _pdfColor(Color c) => PdfColor.fromInt(c.value);

  /// Portrait PDF: SafeWatch header block, an export-details box (who, when,
  /// counts, filters) and then one simple bordered table.
  Future<Uint8List> _buildPdf(
    List<_IncidentReport> rows, {
    required String exportedBy,
    required String exportedRole,
  }) async {
    const ink = PdfColor.fromInt(0xFF0F172A);
    const line = PdfColor.fromInt(0xFFCBD5E1);
    final headerColor = _pdfColor(AppColors.accentBlue);

    const muted = PdfColor.fromInt(0xFF64748B);
    const boxBg = PdfColor.fromInt(0xFFF8FAFC);
    final accent = _pdfColor(AppColors.accentBlue);

    String t(String s) => _pdfSafe(s);

    final now = DateTime.now();
    final exportedOn = DateFormat('MMMM d, yyyy').format(now);
    final exportedAt = DateFormat('h:mm:ss a').format(now);
    final taskForce = rows.where((r) => r.sourceType == 'task_force').length;
    final tanod = rows.where((r) => r.sourceType == 'tanod').length;
    final escalated = rows.where((r) => r.outcome == 'escalated').length;
    final filters = <String>[
      if (_sourceFilter != 'All') 'Source: ${_sourceMeta(_sourceFilter).label}',
      if (_outcomeFilter != 'All') 'Outcome: ${_outcomeMeta(_outcomeFilter).label}',
      if (_searchQuery.isNotEmpty) 'Search: "$_searchQuery"',
    ];
    final exporterLine =
        exportedRole.isEmpty ? exportedBy : '$exportedBy (${_titleCase(exportedRole)})';

    pw.Widget info(String label, String value) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(label.toUpperCase(),
                  style: pw.TextStyle(
                      fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: muted, letterSpacing: 0.6)),
              pw.SizedBox(height: 2),
              pw.Text(t(value),
                  style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: ink)),
            ],
          ),
        );

    final data = <List<String>>[
      for (var i = 0; i < rows.length; i++)
        () {
          final r = rows[i];
          final incident = _incidentCache[r.incidentId];
          final camera = incident?.cameraId != null ? _cameraCache[incident!.cameraId] : null;
          final reporter = _profileCache[r.reportedBy];
          return <String>[
            '${i + 1}',
            DateFormat('yyyy-MM-dd h:mm a').format(r.submittedAt),
            t(_sourceMeta(r.sourceType).label),
            t(_alertMeta(incident?.alertType).label),
            t(_outcomeMeta(r.outcome).label),
            t(reporter?.fullName ?? '-'),
            t(camera?.location ?? '-'),
          ];
        }(),
    ];

    final doc = pw.Document(title: 'Incident Reports', author: 'SafeWatch');

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(t('SafeWatch  |  Incident Reports  |  Exported by $exportedBy'),
                style: const pw.TextStyle(fontSize: 7.5, color: muted)),
            pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 7.5, color: muted)),
          ],
        ),
        build: (ctx) => [
          // --- Document header ---
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Container(
                width: 4,
                height: 36,
                decoration: pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(2)),
              ),
              pw.SizedBox(width: 10),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('SAFEWATCH',
                        style: pw.TextStyle(
                            fontSize: 8, fontWeight: pw.FontWeight.bold, color: accent, letterSpacing: 1.4)),
                    pw.SizedBox(height: 2),
                    pw.Text('Incident Reports',
                        style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: ink)),
                    pw.SizedBox(height: 2),
                    pw.Text('Task Force and Tanod field reports',
                        style: const pw.TextStyle(fontSize: 8.5, color: muted)),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          // --- Export details ---
          pw.Container(
            padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 4),
            decoration: pw.BoxDecoration(
              color: boxBg,
              borderRadius: pw.BorderRadius.circular(4),
              border: pw.Border.all(color: line, width: 0.6),
            ),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  flex: 5,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      info('Exported by', exporterLine),
                      info('Date exported', exportedOn),
                      info('Time exported', exportedAt),
                    ],
                  ),
                ),
                pw.Expanded(
                  flex: 4,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      info('Total reports', '${rows.length}'),
                      info('Task Force / Tanod', '$taskForce / $tanod'),
                      info('Escalated', '$escalated'),
                    ],
                  ),
                ),
                pw.Expanded(
                  flex: 5,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      info('Filters applied', filters.isEmpty ? 'None (all reports)' : filters.join(', ')),
                      info('Reports dated',
                          '${DateFormat('MMM d, yyyy').format(rows.last.submittedAt)} - ${DateFormat('MMM d, yyyy').format(rows.first.submittedAt)}'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          // --- Table ---
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Date & Time', 'Source', 'Incident', 'Outcome', 'Reported By', 'Location'],
            data: data,
            headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: pw.BoxDecoration(color: headerColor),
            cellStyle: const pw.TextStyle(fontSize: 8.5, color: ink),
            border: pw.TableBorder.all(color: line, width: 0.6),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 6),
            cellAlignment: pw.Alignment.centerLeft,
            headerAlignment: pw.Alignment.centerLeft,
            cellAlignments: {0: pw.Alignment.center},
            headerAlignments: {0: pw.Alignment.center},
            columnWidths: {
              0: const pw.FlexColumnWidth(0.45),
              1: const pw.FlexColumnWidth(1.6),
              2: const pw.FlexColumnWidth(1.0),
              3: const pw.FlexColumnWidth(1.0),
              4: const pw.FlexColumnWidth(1.4),
              5: const pw.FlexColumnWidth(1.4),
              6: const pw.FlexColumnWidth(1.6),
            },
          ),
        ],
      ),
    );

    return doc.save();
  }

  // --- STAT CARDS (summary row, doubles as quick filters) ---

  Widget _buildStatCards(int total, int taskForceCount, int tanodCount, int escalatedCount) {
    final cards = <Widget>[
      _ReportStatCard(
        label: 'Total reports',
        value: total,
        caption: 'All sources',
        icon: Icons.assignment_outlined,
        color: AppColors.accentBlue,
        share: total == 0 ? 0 : 1,
        selected: _sourceFilter == 'All' && _outcomeFilter == 'All',
        onTap: () => setState(() {
          _sourceFilter = 'All';
          _outcomeFilter = 'All';
          _currentPage = 0;
        }),
      ),
      _ReportStatCard(
        label: _sourceMeta('task_force').label,
        value: taskForceCount,
        caption: total == 0 ? '0%' : '${((taskForceCount / total) * 100).round()}%',
        icon: _sourceMeta('task_force').icon,
        color: _sourceMeta('task_force').color,
        share: total == 0 ? 0 : taskForceCount / total,
        selected: _sourceFilter == 'task_force',
        onTap: () => setState(() {
          _sourceFilter = _sourceFilter == 'task_force' ? 'All' : 'task_force';
          _currentPage = 0;
        }),
      ),
      _ReportStatCard(
        label: _sourceMeta('tanod').label,
        value: tanodCount,
        caption: total == 0 ? '0%' : '${((tanodCount / total) * 100).round()}%',
        icon: _sourceMeta('tanod').icon,
        color: _sourceMeta('tanod').color,
        share: total == 0 ? 0 : tanodCount / total,
        selected: _sourceFilter == 'tanod',
        onTap: () => setState(() {
          _sourceFilter = _sourceFilter == 'tanod' ? 'All' : 'tanod';
          _currentPage = 0;
        }),
      ),
      _ReportStatCard(
        label: _outcomeMeta('escalated').label,
        value: escalatedCount,
        caption: total == 0 ? '0%' : '${((escalatedCount / total) * 100).round()}%',
        icon: _outcomeMeta('escalated').icon,
        color: _outcomeMeta('escalated').color,
        share: total == 0 ? 0 : escalatedCount / total,
        selected: _outcomeFilter == 'escalated',
        onTap: () => setState(() {
          _outcomeFilter = _outcomeFilter == 'escalated' ? 'All' : 'escalated';
          _currentPage = 0;
        }),
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        const gap = 14.0;
        final perRow = c.maxWidth >= 900 ? 4 : (c.maxWidth >= 560 ? 2 : 1);
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final card in cards) SizedBox(width: w, child: card)],
        );
      },
    );
  }

  // --- TOOLBAR (search + segmented source filter + outcome filter) ---

  Widget _buildToolbar(List<_IncidentReport> filtered) {
    return Row(
      children: [
        SizedBox(
          width: 280,
          height: 38,
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search incident reports',
              hintStyle: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
              prefixIcon: Icon(
                Icons.search,
                size: 17,
                color: _searchFocusNode.hasFocus ? AppColors.accentBlue : AppColors.textMuted(context),
              ),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.close, size: 16, color: AppColors.textMuted(context)),
                      splashRadius: 14,
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
              filled: true,
              fillColor: AppColors.card(context),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
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
                borderSide: const BorderSide(color: AppColors.accentBlue, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _SourceFilterSegmented(
            selected: _sourceFilter,
            onChanged: (v) => setState(() {
              _sourceFilter = v;
              _currentPage = 0;
            }),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(height: 38, child: _buildOutcomeDropdown()),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Copy ${filtered.length} reports as CSV',
          child: SizedBox(
            height: 38,
            width: 38,
            child: OutlinedButton(
              onPressed: filtered.isEmpty ? null : () => _copyCsv(filtered),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textMuted(context),
                backgroundColor: AppColors.card(context),
                side: BorderSide(color: AppColors.border(context)),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Icon(Icons.copy_outlined, size: 16),
            ),
          ),
        ),
                const SizedBox(width: 8),
        Tooltip(
          message: filtered.isEmpty
              ? 'No reports to export'
              : 'Export ${filtered.length} report${filtered.length == 1 ? '' : 's'} as PDF',
          child: SizedBox(
            height: 38,
            width: 38,
            child: OutlinedButton(
              onPressed: (_exporting || filtered.isEmpty) ? null : () => _exportPdf(filtered),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textMuted(context),
                backgroundColor: AppColors.card(context),
                side: BorderSide(color: AppColors.border(context)),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: _exporting
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentBlue),
                    )
                  : const Icon(Icons.picture_as_pdf_outlined, size: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOutcomeDropdown() {
    const options = ['All', 'resolved', 'ongoing', 'escalated', 'false_alarm', 'no_action_needed'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _outcomeFilter,
          dropdownColor: AppColors.card(context),
          style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
          icon: Icon(Icons.filter_list, color: AppColors.textMuted(context), size: 16),
          items: options
              .map((o) => DropdownMenuItem(
                    value: o,
                    child: Text(o == 'All' ? 'All Outcomes' : _outcomeMeta(o).label),
                  ))
              .toList(),
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _outcomeFilter = val;
                _currentPage = 0;
              });
            }
          },
        ),
      ),
    );
  }

  Future<void> _copyCsv(List<_IncidentReport> rows) async {
    String esc(dynamic v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';

    final buf = StringBuffer('Time,Source,Incident,Outcome,Reported By,Location\n');
    for (final r in rows) {
      final incident = _incidentCache[r.incidentId];
      final camera = incident?.cameraId != null ? _cameraCache[incident!.cameraId] : null;
      final reporter = _profileCache[r.reportedBy];
      buf.writeln([
        _formatFull(r.submittedAt),
        _sourceMeta(r.sourceType).label,
        _alertMeta(incident?.alertType).label,
        _outcomeMeta(r.outcome).label,
        reporter?.fullName ?? '',
        camera?.location ?? '',
      ].map(esc).join(','));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${rows.length} reports as CSV'), duration: const Duration(seconds: 2)),
    );
  }

  // --- CONTENT (bordered card: header row, table body, footer pager) ---

  Widget _buildContent(bool loading, List<_IncidentReport> all, List<_IncidentReport> filtered) {
    Widget shell(Widget child) => Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: child,
        );

    Widget message(IconData icon, String text) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: AppColors.textMuted(context)),
              const SizedBox(height: 10),
              Text(text, style: TextStyle(color: AppColors.textMuted(context), fontSize: 13)),
            ],
          ),
        );

    if (loading) {
      return shell(const Center(child: CircularProgressIndicator(color: AppColors.accentBlue)));
    }
    if (all.isEmpty) {
      return shell(message(Icons.assignment_outlined, 'No incident reports found.'));
    }
    if (filtered.isEmpty) {
      return shell(message(Icons.search_off_rounded, 'No reports match your filters.'));
    }

    final totalPages = (filtered.length / _rowsPerPage).ceil();
    final safePage = _currentPage >= totalPages ? totalPages - 1 : _currentPage;
    if (safePage != _currentPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _currentPage = safePage);
      });
    }
    final pageStart = safePage * _rowsPerPage;
    final pageEnd = (pageStart + _rowsPerPage).clamp(0, filtered.length);
    final pageReports = filtered.sublist(pageStart, pageEnd);

    return shell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGridHeader(),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          Expanded(
            child: ListView.builder(
              itemCount: pageReports.length,
              itemBuilder: (context, index) => _buildReportRow(pageReports[index]),
            ),
          ),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          Container(
            width: double.infinity,
            color: AppColors.sunken(context),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
            child: Row(
              children: [
                Text(
                  'Showing ${pageStart + 1}–$pageEnd of ${filtered.length}'
                  '${_searchQuery.isNotEmpty ? ' matching "$_searchQuery"' : ''}',
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5, fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                _buildPagePicker(currentPage: safePage, totalPages: totalPages),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridHeader() {
    Widget label(String text, {double? width}) {
      final style = TextStyle(
        color: AppColors.textMuted(context),
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      );
      return width != null ? SizedBox(width: width, child: Text(text, style: style)) : Text(text, style: style);
    }

    return Container(
      color: AppColors.sunken(context),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
      child: Row(
        children: [
          label('TIME', width: 70),
          const SizedBox(width: 16),
          label('SOURCE', width: 110),
          const SizedBox(width: 16),
          label('INCIDENT', width: 150),
          const SizedBox(width: 16),
          label('OUTCOME', width: 150),
          const SizedBox(width: 16),
          label('REPORTED BY', width: 150),
          const SizedBox(width: 16),
          Expanded(child: label('LOCATION')),
          const SizedBox(width: 22),
        ],
      ),
    );
  }

  Widget _buildReportRow(_IncidentReport report) {
    final incident = _incidentCache[report.incidentId];
    final camera = incident?.cameraId != null ? _cameraCache[incident!.cameraId] : null;
    final reporter = _profileCache[report.reportedBy];

    return _ReportRowTile(
      key: ValueKey(report.id),
      report: report,
      alert: _alertMeta(incident?.alertType),
      outcome: _outcomeMeta(report.outcome),
      source: _sourceMeta(report.sourceType),
      reporterName: reporter?.fullName ?? '—',
      locationLabel: camera?.location ?? (incident?.cameraId != null ? 'Resolving…' : '—'),
      timeLabel: _formatTimeOnly(report.submittedAt),
      isSelected: _selectedReport?.id == report.id,
      onTap: () => _openReportDialog(report),
    );
  }

  Widget _buildPagePicker({required int currentPage, required int totalPages}) {
    const int windowSize = 1;

    List<int> pageNumbers() {
      final pages = <int>{0, totalPages - 1, currentPage};
      for (int i = 1; i <= windowSize; i++) {
        if (currentPage - i >= 0) pages.add(currentPage - i);
        if (currentPage + i < totalPages) pages.add(currentPage + i);
      }
      return pages.toList()..sort();
    }

    Widget arrowButton(IconData icon, VoidCallback? onTap) {
      return SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          padding: EdgeInsets.zero,
          onPressed: onTap,
          icon: Icon(icon, size: 16, color: onTap == null ? AppColors.textMuted(context) : AppColors.textMain(context)),
          splashRadius: 16,
        ),
      );
    }

    Widget pageButton(int pageIndex) {
      final isCurrent = pageIndex == currentPage;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: isCurrent ? null : () => setState(() => _currentPage = pageIndex),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isCurrent ? AppColors.accentBlue : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: isCurrent ? null : Border.all(color: AppColors.border(context)),
          ),
          child: Text(
            '${pageIndex + 1}',
            style: TextStyle(
              color: isCurrent ? Colors.white : AppColors.textMuted(context),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    final pages = pageNumbers();
    final widgets = <Widget>[
      arrowButton(Icons.chevron_left, currentPage > 0 ? () => setState(() => _currentPage--) : null),
      const SizedBox(width: 4),
    ];
    for (int i = 0; i < pages.length; i++) {
      if (i > 0 && pages[i] - pages[i - 1] > 1) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('…', style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
        ));
      }
      widgets.add(pageButton(pages[i]));
      if (i != pages.length - 1) widgets.add(const SizedBox(width: 4));
    }
    widgets.add(const SizedBox(width: 4));
    widgets.add(arrowButton(
      Icons.chevron_right,
      currentPage < totalPages - 1 ? () => setState(() => _currentPage++) : null,
    ));

    return Row(mainAxisSize: MainAxisSize.min, children: widgets);
  }

  // --- DETAILS DIALOG ---------------------------------------------------

  /// Small uppercase label with a muted accent bar in front, used above
  /// each card in the dialog.
  Widget _sectionLabel(String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
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
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  /// Card chrome shared by every block in the dialog.
  BoxDecoration _panelCardDecoration() => BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      );

  List<Widget> _spaced(List<Widget> items, {double gap = 18}) => [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          items[i],
        ],
      ];

  Widget _labeled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_sectionLabel(label), const SizedBox(height: 8), child],
      );

  Widget _sectionBlock(_ReportSection section) {
    final meta = _reportSectionMeta(section.header);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(color: meta.color.withOpacity(0.12), shape: BoxShape.circle),
          child: Icon(meta.icon, size: 14, color: meta.color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(section.header,
                  style: TextStyle(color: AppColors.textMain(context), fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              if (section.items.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < section.items.length; i++)
                      Padding(
                        padding: EdgeInsets.only(bottom: i == section.items.length - 1 ? 0 : 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(top: 6, right: 8),
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: meta.color),
                            ),
                            Expanded(
                              child: Text(section.items[i],
                                  style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5, height: 1.4)),
                            ),
                          ],
                        ),
                      ),
                  ],
                )
              else
                Text(section.value ?? '—',
                    style: TextStyle(color: AppColors.textMain(context), fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
    );
  }

  void _openPhoto(List<String> paths, int startIndex) {
    HapticFeedback.selectionClick();
    _photoOverlayEntry?.remove();
    final entry = OverlayEntry(
      builder: (_) => _PhotoViewerOverlay(
        urls: paths.map(_photoUrl).toList(),
        initialIndex: startIndex,
        onClose: _closePhotoViewer,
      ),
    );
    _photoOverlayEntry = entry;
    // Inserted into the root overlay, after the dialog route, so it always
    // paints on top of the dialog.
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _closePhotoViewer() {
    _photoOverlayEntry?.remove();
    _photoOverlayEntry = null;
  }

  Widget _buildReportDialog(BuildContext dialogContext, _IncidentReport initial) {
    // Prefer the freshest copy of the report (stream updates, endorsements).
    final report = _latestReports.where((r) => r.id == initial.id).firstOrNull ?? initial;
    final incident = _incidentCache[report.incidentId];
    final alert = _alertMeta(incident?.alertType);
    final outcome = _outcomeMeta(report.outcome);
    final source = _sourceMeta(report.sourceType);
    final maxH = MediaQuery.of(dialogContext).size.height * 0.88;

    return Dialog(
      backgroundColor: AppColors.card(context),
      elevation: 16,
      shadowColor: Colors.black,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.border(context)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 860, maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- HEADER ---
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 12, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: alert.color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(alert.icon, color: alert.color, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${alert.label} report',
                            style: TextStyle(
                                color: AppColors.textMain(context),
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3)),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(Icons.schedule_outlined, size: 13, color: AppColors.textMuted(context)),
                            const SizedBox(width: 5),
                            Text('Submitted ${_formatFull(report.submittedAt)}',
                                style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _badge(outcome.label, outcome.color, outcome.icon),
                            _badge(source.label, source.color, source.icon),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _closeDetailDialog,
                    icon: Icon(Icons.close, size: 20, color: AppColors.textMuted(context)),
                  ),
                ],
              ),
            ),
            Divider(color: AppColors.border(context), height: 1, thickness: 1),

            // --- BODY ---
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: LayoutBuilder(
                  builder: (context, c) {
                    final wide = c.maxWidth >= 660;
                    final mainCol = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _spaced(_mainBlocks(report)),
                    );
                    final sideCol = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _spaced(_sideBlocks(report, incident, alert)),
                    );
                    return Padding(
                      padding: const EdgeInsets.all(22),
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 6, child: mainCol),
                                const SizedBox(width: 20),
                                Expanded(flex: 4, child: sideCol),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [sideCol, const SizedBox(height: 18), mainCol],
                            ),
                    );
                  },
                ),
              ),
            ),

            // --- FOOTER ---
            Divider(color: AppColors.border(context), height: 1, thickness: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 16),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _copyReport(report),
                    icon: Icon(Icons.copy_outlined, size: 15, color: AppColors.textMain(context)),
                    label: Text('Copy report',
                        style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5, fontWeight: FontWeight.w600)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: AppColors.border(context)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: _closeDetailDialog,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Close', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Main column: what happened, structured details, photos.
  List<Widget> _mainBlocks(_IncidentReport report) {
    final blocks = <Widget>[];

    if (report.narrative.trim().isNotEmpty) {
      blocks.add(_labeled(
        'WHAT HAPPENED',
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: _panelCardDecoration(),
          child: SelectableText(
            report.narrative,
            style: TextStyle(color: AppColors.textMain(context), fontSize: 13, height: 1.55),
          ),
        ),
      ));
    }

    if (report.sections.isNotEmpty) {
      blocks.add(_labeled(
        'REPORT DETAILS',
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: _panelCardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < report.sections.length; i++) ...[
                _sectionBlock(report.sections[i]),
                if (i != report.sections.length - 1) ...[
                  const SizedBox(height: 12),
                  Divider(color: AppColors.border(context), height: 1),
                  const SizedBox(height: 12),
                ],
              ],
            ],
          ),
        ),
      ));
    }

    if (report.photoPaths.isNotEmpty) {
      blocks.add(_labeled(
        'PHOTOS · ${report.photoPaths.length}',
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: _panelCardDecoration(),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: report.photoPaths.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 120,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemBuilder: (context, i) => GestureDetector(
              onTap: () => _openPhoto(report.photoPaths, i),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  _photoUrl(report.photoPaths[i]),
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : Container(
                          color: AppColors.sunken(context),
                          child: const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentBlue),
                            ),
                          ),
                        ),
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: AppColors.sunken(context),
                    child: Icon(Icons.broken_image_outlined, size: 20, color: AppColors.textMuted(context)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
    }

    if (blocks.isEmpty) {
      blocks.add(Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28),
        decoration: _panelCardDecoration(),
        child: Column(
          children: [
            Icon(Icons.description_outlined, size: 28, color: AppColors.textMuted(context)),
            const SizedBox(height: 8),
            Text('No written details were submitted.',
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5)),
          ],
        ),
      ));
    }
    return blocks;
  }

  /// Side column: linked incident, responding team, endorsement.
  List<Widget> _sideBlocks(_IncidentReport report, _IncidentMeta? incident, _AlertMeta alert) {
    final camera = incident?.cameraId != null ? _cameraCache[incident!.cameraId] : null;
    final hasCameraInfo = incident?.cameraId != null && incident!.cameraId!.isNotEmpty;
    final endorser = report.endorsedBy != null ? _profileCache[report.endorsedBy] : null;
    final blocks = <Widget>[];

    if (report.incidentId.isNotEmpty) {
      blocks.add(_labeled(
        'LINKED INCIDENT',
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            final id = report.incidentId;
            _closeDetailDialog();
            IncidentReportLinkService.instance.openIncident(id);
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: _panelCardDecoration(),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: alert.color.withOpacity(0.12), shape: BoxShape.circle),
                  child: Icon(alert.icon, size: 16, color: alert.color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('View Incident',
                          style: TextStyle(
                              color: AppColors.textMain(context), fontSize: 13, fontWeight: FontWeight.w700)),
                      if (hasCameraInfo)
                        Text(camera?.location ?? 'Resolving location…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
                      if (incident?.occurredAt != null)
                        Text('Occurred ${_formatFull(incident!.occurredAt!)}',
                            style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward, size: 16, color: AppColors.textMuted(context)),
              ],
            ),
          ),
        ),
      ));
    }

    blocks.addAll(_buildTeamSections(report));

    if (report.endorsedBy != null) {
      blocks.add(_labeled(
        'ENDORSEMENT',
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: _panelCardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(endorser?.fullName ?? 'Unknown endorser',
                  style: TextStyle(
                      color: AppColors.textMain(context), fontSize: 12.5, fontWeight: FontWeight.w700)),
              if (report.endorsedAt != null)
                Text(_formatFull(report.endorsedAt!),
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 11)),
              if ((report.endorsedNote ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(report.endorsedNote!,
                    style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5, height: 1.4)),
              ],
            ],
          ),
        ),
      ));
    }
    return blocks;
  }

  /// Responding team: leader first, then every member, and always the person
  /// who actually sent the report (even if they're not in `member_ids`).
  List<Widget> _buildTeamSections(_IncidentReport report) {
    final key = _teamKey(report);
    final isTaskForce = report.sourceType == 'task_force';

    final main = _teamCard(
      title: isTaskForce ? 'TASK FORCE TEAM' : 'TANOD TEAM',
      team: _teamCache[key],
      loading: _teamCache[key] == null && !_teamFetchFailed.contains(key),
      reporterId: report.reportedBy ?? '',
      showUnavailableNote: true,
    );

    if (!isTaskForce) return [main];

    final requester = _requesterTeamCache[key];
    final requesterLoading = _requesterInFlight.contains(key);
    return [
      main,
      if (requesterLoading || requester != null)
        _teamCard(
          title: 'REQUESTED BY TANOD TEAM',
          team: requester,
          loading: requesterLoading && requester == null,
          reporterId: '',
          showUnavailableNote: false,
        ),
    ];
  }

  Widget _teamCard({
    required String title,
    required _DispatchTeam? team,
    required bool loading,
    required String reporterId,
    required bool showUnavailableNote,
  }) {
    final leadId = team?.leadId ?? '';
    final ids = <String>[];
    void add(String? id) {
      if (id != null && id.isNotEmpty && !ids.contains(id)) ids.add(id);
    }

    add(team?.leadId);
    for (final m in team?.memberIds ?? const <String>[]) {
      add(m);
    }
    add(reporterId);

    final Widget content = loading
        ? Row(children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentBlue),
            ),
            const SizedBox(width: 10),
            Text('Loading team…', style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5)),
          ])
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < ids.length; i++) ...[
                if (i > 0) ...[
                  const SizedBox(height: 10),
                  Divider(color: AppColors.border(context), height: 1),
                  const SizedBox(height: 10),
                ],
                _TeamMemberTile(
                  name: _profileCache[ids[i]]?.fullName ??
                      (_profileFetchInFlight.contains(ids[i]) ? 'Loading…' : 'Unknown user'),
                  role: _profileCache[ids[i]]?.role ?? '',
                  isLeader: ids[i] == leadId,
                  sentReport: reporterId.isNotEmpty && ids[i] == reporterId,
                ),
              ],
              if (team == null && showUnavailableNote) ...[
                const SizedBox(height: 10),
                Text("Full team roster isn't available for this dispatch.",
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
              ],
            ],
          );

    return _labeled(
      loading ? title : '$title · ${ids.length}',
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: _panelCardDecoration(),
        child: content,
      ),
    );
  }

  void _copyReport(_IncidentReport report) {
    final incident = _incidentCache[report.incidentId];
    final alert = _alertMeta(incident?.alertType);
    final outcome = _outcomeMeta(report.outcome);
    final source = _sourceMeta(report.sourceType);
    final reporter = _profileCache[report.reportedBy];
    final team = _teamCache[_teamKey(report)];
    String nameOf(String id) => _profileCache[id]?.fullName ?? 'Unknown user';

    final buffer = StringBuffer()
      ..writeln('[${_formatFull(report.submittedAt)}] [${source.label}] ${reporter?.fullName ?? "Unknown"}')
      ..writeln('${alert.label} — ${outcome.label}');
    if (team != null) {
      final lead = team.leadId;
      if (lead != null && lead.isNotEmpty) buffer.writeln('Team leader: ${nameOf(lead)}');
      final members = team.memberIds.where((id) => id != lead).map(nameOf).toList();
      if (members.isNotEmpty) buffer.writeln('Members: ${members.join(', ')}');
    }
    buffer.writeln(report.narrative);

    final requester = _requesterTeamCache[_teamKey(report)];
    if (requester != null) {
      final rl = requester.leadId;
      if (rl != null && rl.isNotEmpty) buffer.writeln('Requested by Tanod leader: ${nameOf(rl)}');
      final rm = requester.memberIds.where((id) => id != rl).map(nameOf).toList();
      if (rm.isNotEmpty) buffer.writeln('Tanod members: ${rm.join(', ')}');
    }

    Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report copied'), duration: Duration(milliseconds: 1500)),
    );
  }
}

/// Full-screen swipeable photo viewer. Inserted directly as an
/// OverlayEntry on the root Overlay so it is guaranteed to render above the
/// details dialog — it isn't a dialog route, so it can never end up stacked
/// behind another route.
class _PhotoViewerOverlay extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;
  final VoidCallback onClose;

  const _PhotoViewerOverlay({
    required this.urls,
    required this.initialIndex,
    required this.onClose,
  });

  @override
  State<_PhotoViewerOverlay> createState() => _PhotoViewerOverlayState();
}

class _PhotoViewerOverlayState extends State<_PhotoViewerOverlay> {
  late final PageController _pageController = PageController(initialPage: widget.initialIndex);
  late int _currentIndex = widget.initialIndex;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: Colors.black87,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onClose,
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
                        errorBuilder: (context, error, stackTrace) =>
                            Icon(Icons.broken_image_outlined, size: 48, color: Colors.white.withOpacity(0.6)),
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
                  onTap: widget.onClose,
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
                  child: Text('${_currentIndex + 1} / ${widget.urls.length}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}