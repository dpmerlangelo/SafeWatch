import 'dart:math' as math;
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../constants/app_colors.dart';
import 'cctv_live_screen.dart' show AlertLevel;

// COMMAND CENTER DASHBOARD
//
// Overview screen for the command center: headline stat cards, a Detection
// Accuracy analytics panel (how many detections turned out to be real vs
// false alarms — broken down by alert type, over time, and by model
// confidence), a camera status summary, and a recent-incidents feed.
// Mirrors the stat-card / bordered-card language already used by
// UsersScreen, CctvScreen and IncidentsScreen so it reads as the same
// design system.
//
// ACCURACY DEFINITION
// An incident only counts toward accuracy once a human has reviewed it —
// i.e. `incidents.status` is no longer empty ("Needs action"). Of reviewed
// incidents, `status == 'false_detection'` is a false alarm; everything
// else (leader_notified, tanod_dispatched, task_force_dispatched, or any
// other resolution) counts as a confirmed real incident. This avoids
// treating today's still-pending incidents as if they were guaranteed
// correct.
//
// DATA USED
// Reads straight from the existing `incidents` table (alert_type,
// alert_level, occurred_at, status, confidence — confidence is optional
// and the confidence panel simply hides itself if none of the reviewed
// rows have it set), plus lightweight counts from `cameras` and
// `profiles` for the top stat row.

class _DashIncident {
  final String id;
  final String cameraId;
  final String alertType;
  final AlertLevel alertLevel;
  final DateTime occurredAt;
  final String? status;
  final double? confidence;

  _DashIncident({
    required this.id,
    required this.cameraId,
    required this.alertType,
    required this.alertLevel,
    required this.occurredAt,
    required this.status,
    required this.confidence,
  });

  factory _DashIncident.fromMap(Map<String, dynamic> row) {
    return _DashIncident(
      id: row['id'].toString(),
      cameraId: (row['camera_id'] ?? '').toString(),
      alertType: (row['alert_type'] ?? '').toString(),
      alertLevel:
          AlertLevel.fromString(row['alert_level'] as String?) ?? AlertLevel.priority,
      occurredAt: DateTime.tryParse(row['occurred_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      status: row['status'] as String?,
      confidence: (row['confidence'] as num?)?.toDouble(),
    );
  }

  bool get isReviewed => (status ?? '').trim().isNotEmpty;
  bool get isFalseDetection => status == 'false_detection';
  bool get isConfirmed => isReviewed && !isFalseDetection;
}

enum _Range { sevenDays, thirtyDays, allTime }

extension on _Range {
  String get label => switch (this) {
        _Range.sevenDays => '7 days',
        _Range.thirtyDays => '30 days',
        _Range.allTime => 'All time',
      };

  int? get days => switch (this) {
        _Range.sevenDays => 7,
        _Range.thirtyDays => 30,
        _Range.allTime => null,
      };
}

/// Per-alert-type rollup used by the breakdown list.
class _TypeAccuracy {
  final String type;
  final Color color;
  final int total;
  final int falseCount;

  const _TypeAccuracy({
    required this.type,
    required this.color,
    required this.total,
    required this.falseCount,
  });

  int get confirmed => total - falseCount;
  double get accuracy => total == 0 ? 0 : confirmed / total;
}

/// One day's worth of reviewed/false counts, for the trend chart.
class _DayPoint {
  final DateTime day;
  final int reviewed;
  final int falseCount;

  const _DayPoint({required this.day, required this.reviewed, required this.falseCount});

  /// Null (rather than 0) when nothing was reviewed that day, so the chart
  /// can skip the point instead of drawing a misleading dip to 0%.
  double? get accuracy => reviewed == 0 ? null : (reviewed - falseCount) / reviewed;
}

Color _colorForAlertType(String alertType) {
  switch (alertType.trim().toLowerCase()) {
    case 'violence':
      return AppColors.accentRed;
    case 'fire':
      return AppColors.accentOrange;
    case 'theft':
      return AppColors.accentPurple;
    case 'accident':
      return AppColors.accentBlue;
    case 'medical':
      return AppColors.accentGreen;
    case 'curfew':
      return const Color(0xFFFFC107);
    case 'traffic':
      return AppColors.accentOrange;
    default:
      return AppColors.accentBlue;
  }
}

class CommandCenterDashboardScreen extends StatefulWidget {
  final bool isActive;
  const CommandCenterDashboardScreen({super.key, this.isActive = true});

  @override
  State<CommandCenterDashboardScreen> createState() =>
      _CommandCenterDashboardScreenState();
}

class _CommandCenterDashboardScreenState extends State<CommandCenterDashboardScreen> {
  late final Stream<List<Map<String, dynamic>>> _incidentsStream;
  late final Stream<List<Map<String, dynamic>>> _camerasStream;
  late final Stream<List<Map<String, dynamic>>> _profilesStream;

  _Range _range = _Range.thirtyDays;

  @override
  void initState() {
    super.initState();
    final client = Supabase.instance.client;
    _incidentsStream = client
        .from('incidents')
        .stream(primaryKey: ['id'])
        .order('occurred_at', ascending: false);
    _camerasStream = client.from('cameras').stream(primaryKey: ['id']);
    _profilesStream = client.from('profiles').stream(primaryKey: ['id']);
  }

  List<_DashIncident> _inRange(List<_DashIncident> all) {
    final days = _range.days;
    if (days == null) return all;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return all.where((i) => i.occurredAt.isAfter(cutoff)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _incidentsStream,
      builder: (context, incidentSnap) {
        final allIncidents = (incidentSnap.data ?? const <Map<String, dynamic>>[])
            .map((r) => _DashIncident.fromMap(r))
            .toList();
        final loading =
            incidentSnap.connectionState == ConnectionState.waiting && !incidentSnap.hasData;

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: _camerasStream,
          builder: (context, camSnap) {
            final cameras = camSnap.data ?? const <Map<String, dynamic>>[];
            final onlineCameras = cameras
                .where((c) => (c['status'] ?? '').toString().toUpperCase() == 'ONLINE')
                .length;

            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: _profilesStream,
              builder: (context, profSnap) {
                final profiles = profSnap.data ?? const <Map<String, dynamic>>[];
                const fieldRoles = {'Tanod', 'Task Force', 'Purok Leader'};
                final personnelCount = profiles
                    .where((p) => fieldRoles.contains((p['role'] ?? '').toString()))
                    .length;

                return _buildBody(
                  loading: loading,
                  allIncidents: allIncidents,
                  totalCameras: cameras.length,
                  onlineCameras: onlineCameras,
                  personnelCount: personnelCount,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildBody({
    required bool loading,
    required List<_DashIncident> allIncidents,
    required int totalCameras,
    required int onlineCameras,
    required int personnelCount,
  }) {
    if (loading) {
      return Center(child: CircularProgressIndicator(color: AppColors.accentBlue));
    }

    final ranged = _inRange(allIncidents);
    final reviewed = ranged.where((i) => i.isReviewed).toList();
    final falseDetections = reviewed.where((i) => i.isFalseDetection).length;
    final confirmed = reviewed.length - falseDetections;
    final accuracy = reviewed.isEmpty ? null : confirmed / reviewed.length;

    final today = DateTime.now();
    final todayCount = allIncidents
        .where((i) =>
            i.occurredAt.year == today.year &&
            i.occurredAt.month == today.month &&
            i.occurredAt.day == today.day)
        .length;
    final needsActionCount = allIncidents.where((i) => !i.isReviewed).length;

    final typeBreakdown = _buildTypeBreakdown(reviewed);
    final dayPoints = _buildDayPoints(allIncidents);

    final confirmedConfidences = reviewed
        .where((i) => i.isConfirmed && i.confidence != null)
        .map((i) => i.confidence!)
        .toList();
    final falseConfidences = reviewed
        .where((i) => i.isFalseDetection && i.confidence != null)
        .map((i) => i.confidence!)
        .toList();
    final hasConfidenceData = confirmedConfidences.isNotEmpty || falseConfidences.isNotEmpty;

    final recent = List<_DashIncident>.from(allIncidents)
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

        return Scrollbar(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 18),
            _buildStatRow(
              todayCount: todayCount,
              needsAction: needsActionCount,
              accuracy: accuracy,
              onlineCameras: onlineCameras,
              totalCameras: totalCameras,
              personnelCount: personnelCount,
            ),
            const SizedBox(height: 18),
            LayoutBuilder(builder: (context, c) {
              final stacked = c.maxWidth < 980;

              final analyticsPanel = _AccuracyAnalyticsCard(
                range: _range,
                onRangeChanged: (r) => setState(() => _range = r),
                reviewedCount: reviewed.length,
                confirmedCount: confirmed,
                falseCount: falseDetections,
                accuracy: accuracy,
                typeBreakdown: typeBreakdown,
                dayPoints: dayPoints,
                hasConfidenceData: hasConfidenceData,
                avgConfirmedConfidence: _avg(confirmedConfidences),
                avgFalseConfidence: _avg(falseConfidences),
              );

              final sideColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CameraStatusCard(total: totalCameras, online: onlineCameras),
                  const SizedBox(height: 16),
                  _RecentIncidentsCard(incidents: recent.take(6).toList()),
                ],
              );

              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [analyticsPanel, const SizedBox(height: 16), sideColumn],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: analyticsPanel),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: sideColumn),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  double? _avg(List<double> values) {
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  List<_TypeAccuracy> _buildTypeBreakdown(List<_DashIncident> reviewed) {
    final byType = <String, List<_DashIncident>>{};
    for (final i in reviewed) {
      final key = i.alertType.trim().isEmpty ? 'Unknown' : i.alertType.trim();
      byType.putIfAbsent(key, () => []).add(i);
    }
    final list = byType.entries.map((e) {
      final falseCount = e.value.where((i) => i.isFalseDetection).length;
      return _TypeAccuracy(
        type: e.key,
        color: _colorForAlertType(e.key),
        total: e.value.length,
        falseCount: falseCount,
      );
    }).toList();
    list.sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  /// Always the last 14 calendar days, independent of the range toggle
  /// above the ring: the ring answers "how are we doing over the selected
  /// range", the trend line answers "is that changing lately".
  List<_DayPoint> _buildDayPoints(List<_DashIncident> allIncidents) {
    const windowDays = 14;
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final buckets = <DateTime, List<_DashIncident>>{
      for (var i = windowDays - 1; i >= 0; i--) today.subtract(Duration(days: i)): [],
    };
    for (final incident in allIncidents) {
      if (!incident.isReviewed) continue;
      final day =
          DateTime(incident.occurredAt.year, incident.occurredAt.month, incident.occurredAt.day);
      if (buckets.containsKey(day)) buckets[day]!.add(incident);
    }
    return buckets.entries.map((e) {
      final falseCount = e.value.where((i) => i.isFalseDetection).length;
      return _DayPoint(day: e.key, reviewed: e.value.length, falseCount: falseCount);
    }).toList();
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Command Center',
                  style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 24,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('Live overview of cameras, personnel and incident detection',
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatRow({
    required int todayCount,
    required int needsAction,
    required double? accuracy,
    required int onlineCameras,
    required int totalCameras,
    required int personnelCount,
  }) {
    final cards = <Widget>[
      _DashStatCard(
        label: 'Incidents today',
        value: '$todayCount',
        caption: 'Since midnight',
        icon: Icons.warning_amber_rounded,
        color: AppColors.accentBlue,
      ),
      _DashStatCard(
        label: 'Needs action',
        value: '$needsAction',
        caption: needsAction == 0 ? 'All caught up' : 'Awaiting response',
        icon: Icons.notifications_active_outlined,
        color: const Color(0xFFF59E0B),
      ),
      _DashStatCard(
        label: 'Detection accuracy',
        value: accuracy == null ? '—' : '${(accuracy * 100).round()}%',
        caption: accuracy == null ? 'No reviewed incidents yet' : 'Of reviewed detections',
        icon: Icons.track_changes_outlined,
        color: accuracy == null
            ? AppColors.textMuted(context)
            : (accuracy >= 0.85
                ? AppColors.accentGreen
                : accuracy >= 0.6
                    ? const Color(0xFFF59E0B)
                    : AppColors.accentRed),
      ),
      _DashStatCard(
        label: 'Cameras online',
        value: '$onlineCameras/$totalCameras',
        caption: totalCameras == 0
            ? 'None configured'
            : '${((onlineCameras / totalCameras) * 100).round()}% online',
        icon: Icons.videocam_outlined,
        color: AppColors.accentGreen,
      ),
      _DashStatCard(
        label: 'Field personnel',
        value: '$personnelCount',
        caption: 'Tanod, Task Force, Purok Leaders',
        icon: Icons.groups_outlined,
        color: AppColors.accentPurple,
      ),
    ];

    return LayoutBuilder(builder: (context, c) {
      const gap = 14.0;
      final perRow = c.maxWidth >= 1180 ? 5 : (c.maxWidth >= 760 ? 3 : (c.maxWidth >= 460 ? 2 : 1));
      final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final card in cards) SizedBox(width: w, child: card)],
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Stat card (top row) — icon chip, big value, label, small caption.
// ---------------------------------------------------------------------------

class _DashStatCard extends StatefulWidget {
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color color;

  const _DashStatCard({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
  });

  @override
  State<_DashStatCard> createState() => _DashStatCardState();
}

class _DashStatCardState extends State<_DashStatCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _hover ? c.withOpacity(0.5) : AppColors.border(context)),
          boxShadow: _hover
              ? [BoxShadow(color: c.withOpacity(0.14), blurRadius: 18, offset: const Offset(0, 8))]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration:
                  BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.circular(10)),
              child: Icon(widget.icon, size: 18, color: c),
            ),
            const SizedBox(height: 14),
            Text(widget.value,
                style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 24,
                    height: 1,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(widget.label,
                style: TextStyle(
                    color: AppColors.textMuted(context), fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(widget.caption,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textMuted(context).withOpacity(0.85), fontSize: 10.5)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detection Accuracy analytics panel
// ---------------------------------------------------------------------------

class _AccuracyAnalyticsCard extends StatelessWidget {
  final _Range range;
  final ValueChanged<_Range> onRangeChanged;
  final int reviewedCount;
  final int confirmedCount;
  final int falseCount;
  final double? accuracy;
  final List<_TypeAccuracy> typeBreakdown;
  final List<_DayPoint> dayPoints;
  final bool hasConfidenceData;
  final double? avgConfirmedConfidence;
  final double? avgFalseConfidence;

  const _AccuracyAnalyticsCard({
    required this.range,
    required this.onRangeChanged,
    required this.reviewedCount,
    required this.confirmedCount,
    required this.falseCount,
    required this.accuracy,
    required this.typeBreakdown,
    required this.dayPoints,
    required this.hasConfidenceData,
    required this.avgConfirmedConfidence,
    required this.avgFalseConfidence,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Detection Accuracy',
                        style: TextStyle(
                            color: AppColors.textMain(context),
                            fontSize: 15,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(width: 6),
                    Tooltip(
                      message:
                          'Based on incidents that have been reviewed and marked either confirmed '
                          'or "False detection". Incidents still awaiting review are excluded.',
                      child: Icon(Icons.info_outline, size: 14, color: AppColors.textMuted(context)),
                    ),
                  ],
                ),
              ),
              _RangeSegmented(selected: range, onChanged: onRangeChanged),
            ],
          ),
          const SizedBox(height: 18),
          if (reviewedCount == 0)
            _emptyState(context)
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AccuracyRing(accuracy: accuracy!, size: 116),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _countRow(context, AppColors.accentGreen, 'Confirmed real', confirmedCount),
                      const SizedBox(height: 8),
                      _countRow(context, AppColors.accentRed, 'False detections', falseCount),
                      const SizedBox(height: 8),
                      _countRow(
                          context, AppColors.textMuted(context), 'Total reviewed', reviewedCount),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Divider(color: AppColors.border(context), height: 1),
            const SizedBox(height: 18),
            Text('BY ALERT TYPE',
                style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
            const SizedBox(height: 12),
            for (final t in typeBreakdown) ...[
              _TypeAccuracyRow(data: t),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 6),
            Divider(color: AppColors.border(context), height: 1),
            const SizedBox(height: 18),
            Text('ACCURACY TREND · LAST 14 DAYS',
                style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
            const SizedBox(height: 12),
            SizedBox(height: 140, child: _TrendChart(points: dayPoints)),
            if (hasConfidenceData) ...[
              const SizedBox(height: 22),
              Divider(color: AppColors.border(context), height: 1),
              const SizedBox(height: 18),
              Text('AVERAGE MODEL CONFIDENCE',
                  style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6)),
              const SizedBox(height: 12),
              _ConfidenceCompare(
                confirmedAvg: avgConfirmedConfidence,
                falseAvg: avgFalseConfidence,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _countRow(BuildContext context, Color color, String label, int count) {
    return Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5)),
        ),
        Text('$count',
            style: TextStyle(color: AppColors.textMain(context), fontSize: 13, fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fact_check_outlined, size: 30, color: AppColors.textMuted(context)),
            const SizedBox(height: 10),
            Text('No reviewed incidents in this range yet',
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

class _RangeSegmented extends StatelessWidget {
  final _Range selected;
  final ValueChanged<_Range> onChanged;
  const _RangeSegmented({required this.selected, required this.onChanged});

  Widget _seg(BuildContext context, _Range r) {
    final isSelected = selected == r;
    return GestureDetector(
      onTap: () => onChanged(r),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.accentBlue.withOpacity(0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(r.label,
              style: TextStyle(
                color: isSelected ? AppColors.accentBlue : AppColors.textMuted(context),
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
              )),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.sunken(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final r in _Range.values) _seg(context, r)],
      ),
    );
  }
}

class _TypeAccuracyRow extends StatelessWidget {
  final _TypeAccuracy data;
  const _TypeAccuracyRow({required this.data});

  Color _accuracyColor() {
    if (data.accuracy >= 0.85) return AppColors.accentGreen;
    if (data.accuracy >= 0.6) return const Color(0xFFF59E0B);
    return AppColors.accentRed;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: data.color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(data.type,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppColors.textMain(context), fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            Text('${data.confirmed}/${data.total} confirmed',
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 11)),
            const SizedBox(width: 8),
            Text('${(data.accuracy * 100).round()}%',
                style:
                    TextStyle(color: _accuracyColor(), fontSize: 12, fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: data.accuracy,
            minHeight: 5,
            backgroundColor: data.color.withOpacity(0.14),
            valueColor: AlwaysStoppedAnimation<Color>(data.color),
          ),
        ),
      ],
    );
  }
}

/// Donut-style accuracy ring drawn with CustomPaint (no chart dependency).
class _AccuracyRing extends StatelessWidget {
  final double accuracy; // 0..1
  final double size;
  const _AccuracyRing({required this.accuracy, required this.size});

  Color _colorFor(double a) {
    if (a >= 0.85) return AppColors.accentGreen;
    if (a >= 0.6) return const Color(0xFFF59E0B);
    return AppColors.accentRed;
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(accuracy);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _RingPainter(progress: accuracy, color: color, track: AppColors.border(context)),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${(accuracy * 100).round()}%',
                  style:
                      TextStyle(color: AppColors.textMain(context), fontSize: 22, fontWeight: FontWeight.w800)),
              Text('accurate', style: TextStyle(color: AppColors.textMuted(context), fontSize: 10.5)),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color track;
  _RingPainter({required this.progress, required this.color, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.width * 0.11;
    final center = (Offset.zero & size).center;
    final radius = (size.width - strokeWidth) / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color || oldDelegate.track != track;
}

/// Line + area trend chart of daily accuracy (reviewed incidents only),
/// drawn with CustomPaint. Days with no reviewed incidents are skipped
/// rather than drawn as a dip to 0%.
class _TrendChart extends StatelessWidget {
  final List<_DayPoint> points;
  const _TrendChart({required this.points});

  @override
  Widget build(BuildContext context) {
    final hasAnyData = points.any((p) => p.reviewed > 0);
    if (!hasAnyData) {
      return Center(
        child: Text('Not enough reviewed incidents yet to chart a trend',
            style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
      );
    }
    return CustomPaint(
      size: Size.infinite,
      painter: _TrendChartPainter(
        points: points,
        lineColor: AppColors.accentBlue,
        gridColor: AppColors.border(context),
        labelColor: AppColors.textMuted(context),
      ),
    );
  }
}

class _TrendChartPainter extends CustomPainter {
  final List<_DayPoint> points;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;

  _TrendChartPainter({
    required this.points,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const leftAxisWidth = 34.0;
    const bottomAxisHeight = 18.0;
    final chartRect = Rect.fromLTWH(
        leftAxisWidth, 4, size.width - leftAxisWidth - 4, size.height - bottomAxisHeight - 4);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final frac in [0.0, 0.5, 1.0]) {
      final y = chartRect.top + chartRect.height * (1 - frac);
      canvas.drawLine(Offset(chartRect.left, y), Offset(chartRect.right, y), gridPaint);
      _drawText(canvas, '${(frac * 100).round()}%', Offset(0, y - 6), labelColor, 9.5);
    }

    final validIndices = <int>[
      for (var i = 0; i < points.length; i++)
        if (points[i].reviewed > 0) i,
    ];
    if (validIndices.isEmpty) return;

    Offset offsetFor(int index) {
      final dx = points.length <= 1 ? 0.0 : index / (points.length - 1);
      final acc = points[index].accuracy ?? 0;
      return Offset(chartRect.left + chartRect.width * dx, chartRect.top + chartRect.height * (1 - acc));
    }

    final linePath = Path();
    final fillPath = Path();
    for (var i = 0; i < validIndices.length; i++) {
      final p = offsetFor(validIndices[i]);
      if (i == 0) {
        linePath.moveTo(p.dx, p.dy);
        fillPath.moveTo(p.dx, chartRect.bottom);
        fillPath.lineTo(p.dx, p.dy);
      } else {
        linePath.lineTo(p.dx, p.dy);
        fillPath.lineTo(p.dx, p.dy);
      }
    }
    final lastPoint = offsetFor(validIndices.last);
    fillPath.lineTo(lastPoint.dx, chartRect.bottom);
    fillPath.close();

    canvas.drawPath(fillPath, Paint()..color = lineColor.withOpacity(0.12)..style = PaintingStyle.fill);
    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final dotPaint = Paint()..color = lineColor;
    for (final idx in validIndices) {
      canvas.drawCircle(offsetFor(idx), 2.6, dotPaint);
    }

    // First / middle / last day labels only, to keep the axis readable.
    final labelIndices = {0, points.length ~/ 2, points.length - 1};
    for (final idx in labelIndices) {
      if (idx < 0 || idx >= points.length) continue;
      final dx = points.length <= 1 ? 0.0 : idx / (points.length - 1);
      final x = chartRect.left + chartRect.width * dx;
      _drawText(canvas, DateFormat('M/d').format(points[idx].day), Offset(x - 12, chartRect.bottom + 4),
          labelColor, 9.5);
    }
  }

  void _drawText(Canvas canvas, String text, Offset offset, Color color, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _TrendChartPainter oldDelegate) => true;
}

/// Two horizontal bars comparing average model confidence on confirmed
/// real detections vs. false detections — a useful signal for tuning
/// auto-triage/auto-escalation confidence thresholds.
class _ConfidenceCompare extends StatelessWidget {
  final double? confirmedAvg;
  final double? falseAvg;
  const _ConfidenceCompare({required this.confirmedAvg, required this.falseAvg});

  Widget _bar(BuildContext context, String label, double? value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: AppColors.textMain(context), fontSize: 12))),
              Text(value == null ? '—' : '${(value * 100).round()}%',
                  style: TextStyle(color: AppColors.textMain(context), fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value ?? 0,
              minHeight: 6,
              backgroundColor: color.withOpacity(0.12),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bar(context, 'Confirmed real detections', confirmedAvg, AppColors.accentGreen),
        _bar(context, 'False detections', falseAvg, AppColors.accentRed),
        const SizedBox(height: 2),
        Text(
          'A meaningfully lower confidence score on false detections suggests the '
          'model\'s confidence is a useful signal for auto-triage thresholds.',
          style: TextStyle(color: AppColors.textMuted(context), fontSize: 10.5, height: 1.4),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Side column: camera status + recent incidents
// ---------------------------------------------------------------------------

class _CameraStatusCard extends StatelessWidget {
  final int total;
  final int online;
  const _CameraStatusCard({required this.total, required this.online});

  @override
  Widget build(BuildContext context) {
    final offline = total - online;
    final onlineShare = total == 0 ? 0.0 : online / total;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Camera Status',
              style: TextStyle(color: AppColors.textMain(context), fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$online',
                        style:
                            TextStyle(color: AppColors.accentGreen, fontSize: 22, fontWeight: FontWeight.w800)),
                    Text('Online', style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$offline',
                        style:
                            TextStyle(color: AppColors.accentRed, fontSize: 22, fontWeight: FontWeight.w800)),
                    Text('Offline', style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: onlineShare,
              minHeight: 6,
              backgroundColor: AppColors.accentRed.withOpacity(0.14),
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.accentGreen),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentIncidentsCard extends StatelessWidget {
  final List<_DashIncident> incidents;
  const _RecentIncidentsCard({required this.incidents});

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recent Incidents',
              style: TextStyle(color: AppColors.textMain(context), fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          if (incidents.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No incidents recorded yet.',
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5)),
            )
          else
            for (var i = 0; i < incidents.length; i++) ...[
              _row(context, incidents[i]),
              if (i != incidents.length - 1) Divider(color: AppColors.border(context), height: 18),
            ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, _DashIncident incident) {
    final title = incident.alertType.isEmpty ? 'Unknown type' : incident.alertType;
    final isFalse = incident.isFalseDetection;
    final isReviewed = incident.isReviewed;
    return Row(
      children: [
        Container(
            width: 8, height: 8, decoration: BoxDecoration(color: incident.alertLevel.color, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5, fontWeight: FontWeight.w600)),
              Text(_relativeTime(incident.occurredAt),
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 11)),
            ],
          ),
        ),
        Text(
          !isReviewed ? 'Pending' : (isFalse ? 'False' : 'Confirmed'),
          style: TextStyle(
            color: !isReviewed
                ? const Color(0xFFF59E0B)
                : (isFalse ? AppColors.textMuted(context) : AppColors.accentGreen),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}