import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../services/realtime_stream_service.dart';
import '../../constants/app_colors.dart';
// HoverPop is defined (and public) in users_screen.dart. Imported here
// rather than duplicated so both screens share one implementation and
// stay visually identical. Adjust the path if your folder layout
// differs — ideally this gets hoisted into its own
// `widgets/hover_pop.dart` shared by both screens.
import 'users_screen.dart' show HoverPop;

/// Preset ranges for the date filter dropdown. `custom` opens a small
/// popup calendar and stores the chosen bounds in `_customStart`/`_customEnd`.
enum _DateFilterOption { all, today, yesterday, last7, last30, custom }

extension on _DateFilterOption {
  String get label {
    switch (this) {
      case _DateFilterOption.all:
        return 'All Dates';
      case _DateFilterOption.today:
        return 'Today';
      case _DateFilterOption.yesterday:
        return 'Yesterday';
      case _DateFilterOption.last7:
        return 'Last 7 days';
      case _DateFilterOption.last30:
        return 'Last 30 days';
      case _DateFilterOption.custom:
        return 'Custom range';
    }
  }
}

/// A single parsed field-level change from a log entry's `details` text
/// (encoded by `LogChange._encode()` in ActivityLogger as
/// `»field|from|to`).
class _ParsedChange {
  final String field;
  final String from;
  final String to;
  const _ParsedChange(this.field, this.from, this.to);
}

/// Result of splitting a raw `details` string back into its parts: the
/// plain summary line, any structured field changes, and any leftover
/// plain-text metadata line.
class _ParsedLogDetails {
  final String summary;
  final List<_ParsedChange> changes;
  final String? extra;
  const _ParsedLogDetails({
    required this.summary,
    required this.changes,
    this.extra,
  });
}

/// Marker item used to flatten date-group headers and rows into a single
/// list, so the feed's ListView.builder can build lazily.
class _GroupHeader {
  final String label;
  final int count;
  const _GroupHeader(this.label, this.count);
}

String _titleCase(String s) {
  return s
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

/// Renders the Logs feed as a terminal-styled, real-time console
/// (grouped by day, single-line entries), backed by a Supabase Realtime
/// Stream.
///
/// EXPORT: the "Export PDF" button in the table controls builds a portrait
/// A4 PDF (SafeWatch header, who exported it + date/time, counts, filters,
/// then a simple bordered table) for the entries currently shown, and
/// downloads it straight away through `file_saver`. Needs `pdf` +
/// `file_saver`.
class LogsScreen extends StatefulWidget {
  final bool isActive;
  const LogsScreen({super.key, this.isActive = true});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  Stream<List<Map<String, dynamic>>>? _logsStream;

  Map<String, dynamic>? _selectedLog;
  String _searchQuery = '';
  String _actionFilter = 'All';
  String? _rightPanelMode;
  _DateFilterOption _dateFilter = _DateFilterOption.all;
  DateTime? _customStart;
  DateTime? _customEnd;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // Anchors the custom-range calendar popup under the date filter pill.
  final GlobalKey _dateBtnKey = GlobalKey();

  // PDF export in progress (disables the Export button + shows a spinner).
  bool _exporting = false;

  // Floating side-panel overlay. Lives on the app's root Overlay so it
  // floats above everything (including the top bar) without taking any
  // layout space away from the console. Same approach as UsersScreen.
  OverlayEntry? _panelOverlayEntry;
  late final AnimationController _panelAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<Offset> _panelSlide = Tween<Offset>(
    begin: const Offset(1, 0),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _panelAnimController,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  ));

  // Pagination
  int _currentPage = 0;
  static const int _logsPerPage = 50;

  static const String monoFont = 'monospace';

  // -------------------------------------------------------------------
  // Derived-data cache.
  //
  // build() reruns on every frame of the theme fade (AppColors reads the
  // Theme). Sorting, parsing timestamps, counting and filtering all logs
  // on each of those frames is the dominant cost of a theme switch, so
  // the results are cached here and only recomputed when the stream data
  // or a filter actually changes.
  // -------------------------------------------------------------------
  List<Map<String, dynamic>>? _srcData;
  List<Map<String, dynamic>> _all = const [];
  Map<Map<String, dynamic>, DateTime?> _times = Map.identity();
  int _todayCount = 0;
  int _criticalCount = 0;
  int _actorCount = 0;

  String? _filterKey;
  List<Map<String, dynamic>> _filtered = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initLogsStream();
    _searchFocusNode.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _panelOverlayEntry?.remove();
    _panelAnimController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initLogsStream() async {
    final client = Supabase.instance.client;
    final session = await RealtimeStreamService.instance.waitForSession();

    if (session != null) {
      await client.realtime.setAuth(session.accessToken);
    }

    if (!mounted) return;
    setState(() {
      _logsStream = RealtimeStreamService.instance
          .streamTable('logs', primaryKey: ['id']);
    });
  }

  @override
  void didUpdateWidget(covariant LogsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      _closeRightPanel();
    }
  }

  void _closeRightPanel() {
    if (_rightPanelMode == null && _selectedLog == null) return;
    setState(() {
      _rightPanelMode = null;
      _selectedLog = null;
    });
  }

  DateTime? _parseDateTime(dynamic ts) {
    if (ts == null) return null;
    if (ts is DateTime) return ts;
    return DateTime.tryParse(ts.toString())?.toLocal();
  }

  String _formatTimestamp(dynamic ts) {
    final date = _parseDateTime(ts);
    if (date == null) return 'N/A';
    return DateFormat('MMM d, yyyy • h:mm a').format(date);
  }

  String _formatTimeOnly(dynamic ts) {
    final date = _parseDateTime(ts);
    if (date == null) return '--:--:--';
    return DateFormat('HH:mm:ss').format(date);
  }

  /// The row list and search only ever need the plain summary line — the
  /// first line of `details`, before any encoded `»field|from|to` change
  /// rows or trailing metadata. Returns the raw string unchanged for
  /// entries that don't use the structured format at all (nothing to
  /// split on).
  String _summaryLine(String rawDetails) {
    final idx = rawDetails.indexOf('\n');
    return idx == -1 ? rawDetails : rawDetails.substring(0, idx);
  }

  /// Splits a raw `details` string into its summary line, any structured
  /// `»field|from|to` change rows (written by ActivityLogger's
  /// `LogChange`), and any other leftover line (the older flat
  /// `metadata` format, or anything else). Malformed change lines are
  /// treated as plain extra text rather than dropped, so nothing is ever
  /// silently lost even if the format doesn't match exactly.
  _ParsedLogDetails _parseLogDetails(String raw) {
    final lines = raw.split('\n');
    final summary = lines.isEmpty ? '' : lines.first;
    final changes = <_ParsedChange>[];
    final extraLines = <String>[];

    for (final line in lines.skip(1)) {
      if (line.startsWith('»')) {
        final parts = line.substring(1).split('|');
        if (parts.length == 3) {
          changes.add(_ParsedChange(parts[0], parts[1], parts[2]));
          continue;
        }
      }
      if (line.trim().isNotEmpty) extraLines.add(line);
    }

    return _ParsedLogDetails(
      summary: summary,
      changes: changes,
      extra: extraLines.isEmpty ? null : extraLines.join('\n'),
    );
  }

  /// Resolves the active date filter into an inclusive [start, end)
  /// range. Returns null for "All Dates" (no filtering applied).
  ({DateTime start, DateTime end})? _resolveDateRange() {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    switch (_dateFilter) {
      case _DateFilterOption.all:
        return null;
      case _DateFilterOption.today:
        return (start: startOfToday, end: startOfToday.add(const Duration(days: 1)));
      case _DateFilterOption.yesterday:
        final y = startOfToday.subtract(const Duration(days: 1));
        return (start: y, end: startOfToday);
      case _DateFilterOption.last7:
        return (
          start: startOfToday.subtract(const Duration(days: 6)),
          end: startOfToday.add(const Duration(days: 1)),
        );
      case _DateFilterOption.last30:
        return (
          start: startOfToday.subtract(const Duration(days: 29)),
          end: startOfToday.add(const Duration(days: 1)),
        );
      case _DateFilterOption.custom:
        if (_customStart == null || _customEnd == null) return null;
        final s = DateTime(_customStart!.year, _customStart!.month, _customStart!.day);
        final e = DateTime(_customEnd!.year, _customEnd!.month, _customEnd!.day)
            .add(const Duration(days: 1));
        return (start: s, end: e);
    }
  }

  bool _matchesDateFilter(DateTime? ts, ({DateTime start, DateTime end})? range) {
    if (range == null) return true;
    if (ts == null) return false;
    return !ts.isBefore(range.start) && ts.isBefore(range.end);
  }

  /// Short label shown on the date filter pill itself, e.g. "Mar 1–5"
  /// for a custom range, or the preset's own label otherwise.
  String get _dateFilterPillLabel {
    if (_dateFilter == _DateFilterOption.custom &&
        _customStart != null &&
        _customEnd != null) {
      final fmt = DateFormat('MMM d');
      return '${fmt.format(_customStart!)}–${fmt.format(_customEnd!)}';
    }
    return _dateFilter.label;
  }

  /// Opens a small calendar popup anchored under the date filter pill
  /// (instead of a full-screen date range picker).
  Future<void> _pickCustomRange() async {
    final box = _dateBtnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.of(context).size;
    const popupW = _RangeCalendarPopup.width;
    const popupH = 344.0;

    var left = origin.dx;
    final maxLeft = screen.width - popupW - 12;
    if (left > maxLeft) left = maxLeft;
    if (left < 12) left = 12;

    var top = origin.dy + box.size.height + 6;
    if (top + popupH > screen.height - 12) {
      top = origin.dy - popupH - 6;
      if (top < 12) top = 12;
    }

    final now = DateTime.now();
    final picked = await showGeneralDialog<DateTimeRange>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close calendar',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (ctx, _, __) => Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            child: _RangeCalendarPopup(
              initialStart: _customStart,
              initialEnd: _customEnd,
              firstDate: DateTime(now.year - 3),
              lastDate: now,
            ),
          ),
        ],
      ),
      transitionBuilder: (ctx, anim, _, child) {
        final t = Curves.easeOutCubic.transform(anim.value);
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: 0.96 + 0.04 * t,
            alignment: Alignment.topLeft,
            child: child,
          ),
        );
      },
    );

    if (picked == null || !mounted) return;
    setState(() {
      _customStart = picked.start;
      _customEnd = picked.end;
      _dateFilter = _DateFilterOption.custom;
      _currentPage = 0;
    });
  }

  Color _colorForAction(String action) {
    switch (action.toUpperCase()) {
      case 'LOGIN':
        return AppColors.accentGreen;
      case 'LOGOUT':
        return Colors.blueGrey;
      case 'CREATE_USER':
      case 'CREATE_TANOD':
      case 'CREATE_CCTV':
        return AppColors.accentBlue;
      case 'UPDATE_USER':
      case 'UPDATE_TANOD':
      case 'UPDATE_CCTV':
      case 'CCTV_STATUS_CHANGE':
        return AppColors.accentOrange;
      case 'DELETE_USER':
      case 'DELETE_TANOD':
      case 'DELETE_CCTV':
        return AppColors.accentRed;
      default:
        return AppColors.textMuted(context);
    }
  }

  /// "TODAY" / "YESTERDAY" / a weekday+date label, uppercased — used as
  /// the `# ` comment-style section header between groups of entries in
  /// the feed view.
  String _dateGroupLabel(DateTime? dt) {
    if (dt == null) return 'UNKNOWN DATE';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'TODAY';
    if (diff == 1) return 'YESTERDAY';
    return DateFormat('EEEE, MMM d, yyyy').format(dt).toUpperCase();
  }

  /// Groups an already-newest-first list of rows into consecutive
  /// same-day buckets, preserving order. Grouping happens per page (not
  /// across the whole filtered set) so a date group can occasionally
  /// split across a page boundary — an acceptable trade-off for keeping
  /// pagination simple and bounded.
  List<MapEntry<String, List<Map<String, dynamic>>>> _groupByDate(
      List<Map<String, dynamic>> rows) {
    final order = <String>[];
    final map = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final label = _dateGroupLabel(_times[r] ?? _parseDateTime(r['timestamp']));
      if (!map.containsKey(label)) {
        map[label] = [];
        order.add(label);
      }
      map[label]!.add(r);
    }
    return [for (final l in order) MapEntry(l, map[l]!)];
  }

  // --- DERIVED DATA (cached) ---

  /// Parses every timestamp once, sorts newest-first, and computes the
  /// stat-strip counters. Only runs when the stream emits new data.
  void _recomputeAll(List<Map<String, dynamic>> data) {
    final times = Map<Map<String, dynamic>, DateTime?>.identity();
    for (final r in data) {
      times[r] = _parseDateTime(r['timestamp']);
    }

    final sorted = List<Map<String, dynamic>>.from(data)
      ..sort((a, b) =>
          (times[b] ?? DateTime(0)).compareTo(times[a] ?? DateTime(0)));

    final now = DateTime.now();
    var today = 0;
    var critical = 0;
    final actors = <String>{};
    for (final r in sorted) {
      final dt = times[r];
      if (dt != null &&
          dt.year == now.year &&
          dt.month == now.month &&
          dt.day == now.day) {
        today++;
      }
      if ((r['action'] ?? '').toString().toUpperCase().startsWith('DELETE')) {
        critical++;
      }
      final actor = (r['user_name'] ?? '').toString().trim();
      if (actor.isNotEmpty) actors.add(actor);
    }

    _times = times;
    _all = sorted;
    _todayCount = today;
    _criticalCount = critical;
    _actorCount = actors.length;
  }

  /// Returns the filtered list, recomputing only when the search text,
  /// action filter, date filter, or calendar day changes.
  List<Map<String, dynamic>> _filteredFor() {
    final now = DateTime.now();
    final key = '$_searchQuery|$_actionFilter|${_dateFilter.name}|'
        '${_customStart?.millisecondsSinceEpoch}|'
        '${_customEnd?.millisecondsSinceEpoch}|'
        '${now.year}-${now.month}-${now.day}';
    if (key == _filterKey) return _filtered;
    _filterKey = key;

    final range = _resolveDateRange();
    _filtered = _all.where((data) {
      final userName = (data['user_name'] ?? '').toString().toLowerCase();
      final details = (data['details'] ?? '').toString().toLowerCase();
      final action = (data['action'] ?? '').toString();

      final matchesSearch = _searchQuery.isEmpty ||
          userName.contains(_searchQuery) ||
          details.contains(_searchQuery);
      final matchesFilter = _actionFilter == 'All' || action == _actionFilter;
      final matchesDate = _matchesDateFilter(_times[data], range);

      return matchesSearch && matchesFilter && matchesDate;
    }).toList();
    return _filtered;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin

    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPanelOverlay());

    if (_logsStream == null) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accentBlue));
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _logsStream,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData;
        final connected = snapshot.hasData;

        // Recompute derived data only when the stream emitted a new list.
        // During a theme fade the same list instance comes back every
        // frame, so all of this is skipped.
        final data = snapshot.data ?? const <Map<String, dynamic>>[];
        if (!identical(data, _srcData)) {
          _srcData = data;
          _filterKey = null; // force a refilter
          _recomputeAll(data);
        }
        final all = _all;
        final filtered = _filteredFor();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 18),
            _buildStatStrip(
                all.length, _todayCount, _criticalCount, _actorCount),
            const SizedBox(height: 18),
            Expanded(
              child: _buildConsoleCard(loading, connected, all, filtered),
            ),
          ],
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
                'Logs',
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Track every action across the system in real time',
                style:
                    TextStyle(color: AppColors.textMuted(context), fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- STAT STRIP ---

  Widget _buildStatStrip(
      int total, int todayCount, int criticalCount, int actorCount) {
    String pct(int v) => total == 0 ? '0%' : '${((v / total) * 100).round()}%';

    final cards = <Widget>[
      _LogStatCard(
        label: 'Total events',
        value: total,
        caption: 'All time',
        icon: Icons.receipt_long_outlined,
        color: AppColors.accentBlue,
      ),
      _LogStatCard(
        label: 'Today',
        value: todayCount,
        caption: todayCount == 0 ? '—' : pct(todayCount),
        icon: Icons.today_outlined,
        color: AppColors.accentGreen,
      ),
      _LogStatCard(
        label: 'Critical actions',
        value: criticalCount,
        caption: pct(criticalCount),
        icon: Icons.warning_amber_rounded,
        color: AppColors.accentRed,
      ),
      _LogStatCard(
        label: 'Active actors',
        value: actorCount,
        caption: 'Unique',
        icon: Icons.groups_outlined,
        color: AppColors.accentPurple,
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

  // --- CONSOLE CARD (chrome bar + toolbar + feed + footer) ---

  Widget _buildConsoleCard(
    bool loading,
    bool connected,
    List<Map<String, dynamic>> all,
    List<Map<String, dynamic>> filtered,
  ) {
    Widget message(IconData icon, String text) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: AppColors.textMuted(context)),
              const SizedBox(height: 10),
              Text(text,
                  style:
                      TextStyle(color: AppColors.textMuted(context), fontSize: 13)),
            ],
          ),
        );

    Widget body;
    int totalPages = 1;
    int safePage = 0;
    int pageStart = 0;
    int pageEnd = 0;
    List<Map<String, dynamic>> pageLogs = const [];

    if (loading) {
      body = const Center(
          child: CircularProgressIndicator(color: AppColors.accentBlue));
    } else if (all.isEmpty) {
      body = message(Icons.terminal, 'No log entries yet.');
    } else if (filtered.isEmpty) {
      body = message(Icons.search_off_rounded, 'No entries match your filters.');
    } else {
      totalPages = (filtered.length / _logsPerPage).ceil();
      safePage = _currentPage >= totalPages ? totalPages - 1 : _currentPage;
      if (safePage != _currentPage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _currentPage = safePage);
        });
      }
      pageStart = safePage * _logsPerPage;
      pageEnd = (pageStart + _logsPerPage).clamp(0, filtered.length);
      pageLogs = filtered.sublist(pageStart, pageEnd);
      body = _buildFeedBody(pageLogs);
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTerminalChrome(connected),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          _buildToolbar(filtered),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          Expanded(child: body),
          if (!loading && filtered.isNotEmpty) ...[
            Divider(color: AppColors.border(context), height: 1, thickness: 1),
            Container(
              width: double.infinity,
              color: AppColors.sunken(context),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
              child: Row(
                children: [
                  Text(
                    'Showing ${pageStart + 1}–$pageEnd of ${filtered.length}'
                    '${_searchQuery.isNotEmpty ? ' matching "$_searchQuery"' : ''}',
                    style: TextStyle(
                        color: AppColors.textMuted(context),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500),
                  ),
                  const Spacer(),
                  _buildPagePicker(currentPage: safePage, totalPages: totalPages),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Decorative terminal title bar — traffic-light dots, a filename, and
  /// a live/connecting indicator wired to the actual stream state.
  Widget _buildTerminalChrome(bool connected) {
    Widget dot(Color c) => Container(
          width: 10,
          height: 10,
          decoration:
              BoxDecoration(shape: BoxShape.circle, color: c.withOpacity(0.85)),
        );

    return Container(
      color: AppColors.sunken(context),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Row(children: [
            dot(AppColors.accentRed),
            const SizedBox(width: 6),
            dot(AppColors.accentOrange),
            const SizedBox(width: 6),
            dot(AppColors.accentGreen),
          ]),
          const SizedBox(width: 14),
          Icon(Icons.terminal, size: 14, color: AppColors.textMuted(context)),
          const SizedBox(width: 6),
          Text(
            'logs.log',
            style: TextStyle(
              color: AppColors.textMain(context),
              fontFamily: monoFont,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  connected ? AppColors.accentGreen : AppColors.textMuted(context),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            connected ? 'LIVE' : 'CONNECTING…',
            style: TextStyle(
              color:
                  connected ? AppColors.accentGreen : AppColors.textMuted(context),
              fontFamily: monoFont,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  // --- TOOLBAR ---

  Widget _buildToolbar(List<Map<String, dynamic>> filtered) {
    final canExport = !_exporting && filtered.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          SizedBox(
            width: 300,
            height: 38,
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              style: TextStyle(
                  color: AppColors.textMain(context),
                  fontFamily: monoFont,
                  fontSize: 12.5),
              onChanged: (val) => setState(() {
                _searchQuery = val.trim().toLowerCase();
                _currentPage = 0;
              }),
              decoration: InputDecoration(
                hintText: 'Search logs...',
                hintStyle: TextStyle(
                    color: AppColors.textMuted(context),
                    fontFamily: monoFont,
                    fontSize: 12),
                prefixIcon: Icon(
                  Icons.search,
                  size: 17,
                  color: _searchFocusNode.hasFocus
                      ? AppColors.accentBlue
                      : AppColors.textMuted(context),
                ),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.close,
                            size: 16, color: AppColors.textMuted(context)),
                        splashRadius: 14,
                        onPressed: () => setState(() {
                          _searchController.clear();
                          _searchQuery = '';
                          _currentPage = 0;
                        }),
                      )
                    : null,
                filled: true,
                fillColor: AppColors.bg(context),
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
                  borderSide:
                      const BorderSide(color: AppColors.accentBlue, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(height: 38, child: _buildActionFilterDropdown()),
          const SizedBox(width: 10),
          SizedBox(height: 38, child: _buildDateFilterDropdown()),
          const Spacer(),
          Tooltip(
            message: filtered.isEmpty
                ? 'No logs to export'
                : 'Export ${filtered.length} log${filtered.length == 1 ? '' : 's'} as PDF',
            child: HoverPop(
              enabled: canExport,
              child: SizedBox(
                height: 38,
                child: OutlinedButton.icon(
                  onPressed: canExport ? () => _exportPdf(filtered) : null,
                  icon: _exporting
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.accentBlue),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined, size: 16),
                  label: Text(_exporting ? 'Preparing…' : 'Export PDF',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12.5)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textMain(context),
                    backgroundColor: AppColors.card(context),
                    side: BorderSide(color: AppColors.border(context)),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Shared compact styling for every popup-menu dropdown item in this
  // toolbar (date filter + action filter), so both menus render with the
  // same tight row height/padding instead of PopupMenuItem's oversized
  // 48px default.
  static const double _menuItemHeight = 34;
  static const EdgeInsets _menuItemPadding =
      EdgeInsets.symmetric(horizontal: 12);
  static const double _menuItemFontSize = 12.5;
  static const double _menuCheckIconSize = 14;

  Widget _buildDateFilterDropdown() {
    return HoverPop(
      child: PopupMenuButton<_DateFilterOption>(
        tooltip: '',
        offset: const Offset(0, 42),
        color: AppColors.card(context),
        constraints: const BoxConstraints(minWidth: 170, maxWidth: 200),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: AppColors.border(context)),
        ),
        onSelected: (opt) {
          if (opt == _DateFilterOption.custom) {
            // Wait a frame so the menu route has fully closed before the
            // calendar popup opens.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _pickCustomRange();
            });
          } else {
            setState(() {
              _dateFilter = opt;
              _currentPage = 0;
            });
          }
        },
        itemBuilder: (context) => [
          for (final opt in _DateFilterOption.values)
            PopupMenuItem(
              value: opt,
              height: _menuItemHeight,
              padding: _menuItemPadding,
              child: Row(
                children: [
                  if (opt == _dateFilter)
                    Icon(Icons.check,
                        size: _menuCheckIconSize, color: AppColors.accentBlue)
                  else
                    SizedBox(width: _menuCheckIconSize),
                  const SizedBox(width: 8),
                  Text(
                    opt.label,
                    style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: _menuItemFontSize,
                      fontWeight:
                          opt == _dateFilter ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
        ],
        child: Container(
          key: _dateBtnKey,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _dateFilter == _DateFilterOption.all
                  ? AppColors.border(context)
                  : AppColors.accentBlue.withOpacity(0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.calendar_today_outlined,
                  size: 15,
                  color: _dateFilter == _DateFilterOption.all
                      ? AppColors.textMuted(context)
                      : AppColors.accentBlue),
              const SizedBox(width: 8),
              Text(
                _dateFilterPillLabel,
                style: TextStyle(
                  color: _dateFilter == _DateFilterOption.all
                      ? AppColors.textMain(context)
                      : AppColors.accentBlue,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down,
                  size: 18, color: AppColors.textMuted(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionFilterDropdown() {
    const actionOptions = [
      'All',
      'LOGIN',
      'LOGOUT',
      'CREATE_USER',
      'UPDATE_USER',
      'DELETE_USER',
      'CREATE_CCTV',
      'UPDATE_CCTV',
      'DELETE_CCTV',
      'CCTV_STATUS_CHANGE',
    ];

    final isActive = _actionFilter != 'All';

    return HoverPop(
      child: PopupMenuButton<String>(
        tooltip: '',
        offset: const Offset(0, 42),
        color: AppColors.card(context),
        constraints: const BoxConstraints(minWidth: 190, maxWidth: 220),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: AppColors.border(context)),
        ),
        onSelected: (val) => setState(() {
          _actionFilter = val;
          _currentPage = 0;
        }),
        itemBuilder: (context) => [
          for (final action in actionOptions)
            PopupMenuItem(
              value: action,
              height: _menuItemHeight,
              padding: _menuItemPadding,
              child: Row(
                children: [
                  if (action == _actionFilter)
                    Icon(Icons.check,
                        size: _menuCheckIconSize, color: AppColors.accentBlue)
                  else
                    SizedBox(width: _menuCheckIconSize),
                  const SizedBox(width: 8),
                  Text(
                    action == 'All' ? 'All Actions' : action,
                    style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: _menuItemFontSize,
                      fontWeight: action == _actionFilter
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          height: 38,
          constraints: const BoxConstraints(maxWidth: 180),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isActive
                  ? AppColors.accentBlue.withOpacity(0.5)
                  : AppColors.border(context),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.filter_list,
                  size: 15,
                  color: isActive
                      ? AppColors.accentBlue
                      : AppColors.textMuted(context)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _actionFilter == 'All' ? 'All Actions' : _actionFilter,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isActive
                        ? AppColors.accentBlue
                        : AppColors.textMain(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down,
                  size: 18, color: AppColors.textMuted(context)),
            ],
          ),
        ),
      ),
    );
  }

  // --- PDF EXPORT -------------------------------------------------------

  /// Name + role of whoever is signed in (the person exporting).
  Future<({String name, String role})> _currentExporter() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return (name: 'Unknown user', role: '');
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('first_name, last_name, role')
          .eq('id', user.id)
          .maybeSingle();
      if (row != null) {
        final name = [row['first_name'], row['last_name']]
            .map((e) => (e ?? '').toString().trim())
            .where((s) => s.isNotEmpty)
            .join(' ');
        return (
          name: name.isEmpty ? (user.email ?? 'Unknown user') : name,
          role: (row['role'] ?? '').toString(),
        );
      }
    } catch (_) {
      // fall through to the email fallback
    }
    return (name: user.email ?? 'Unknown user', role: '');
  }

  /// Exports the log entries currently shown (filters applied) as a
  /// portrait PDF and downloads it immediately — no print dialog.
  Future<void> _exportPdf(List<Map<String, dynamic>> rows) async {
    if (_exporting || rows.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final me = await _currentExporter();
      final bytes = await _buildLogsPdf(rows,
          exportedBy: me.name, exportedRole: me.role);
      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await FileSaver.instance.saveFile(
        name: 'safewatch_logs_$stamp',
        bytes: bytes,
        ext: 'pdf',
        mimeType: MimeType.pdf,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Downloaded ${rows.length} log${rows.length == 1 ? '' : 's'} as PDF'),
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
        .replaceAll('→', '->')
        .replaceAll('»', '>')
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .runes
        .map((r) => r <= 0xFF ? String.fromCharCode(r) : '?')
        .join();
  }

  PdfColor _pdfColor(Color c) => PdfColor.fromInt(c.value);

  /// Summary line plus any field changes, flattened into one string for
  /// the PDF's "Details" column.
  String _pdfDetails(Map<String, dynamic> row) {
    final parsed = _parseLogDetails((row['details'] ?? '').toString());
    final buf = StringBuffer(parsed.summary.isEmpty ? '-' : parsed.summary);
    if (parsed.changes.isNotEmpty) {
      buf.write(' (');
      buf.write(parsed.changes
          .map((c) => '${c.field}: ${c.from} -> ${c.to}')
          .join('; '));
      buf.write(')');
    }
    return buf.toString();
  }

  /// Portrait PDF: SafeWatch header block, an export-details box (who, when,
  /// counts, filters) and then one simple bordered table.
  Future<Uint8List> _buildLogsPdf(
    List<Map<String, dynamic>> rows, {
    required String exportedBy,
    required String exportedRole,
  }) async {
    const ink = PdfColor.fromInt(0xFF0F172A);
    const line = PdfColor.fromInt(0xFFCBD5E1);
    const muted = PdfColor.fromInt(0xFF64748B);
    const boxBg = PdfColor.fromInt(0xFFF8FAFC);
    final accent = _pdfColor(AppColors.accentBlue);

    String t(String s) => _pdfSafe(s);

    final now = DateTime.now();
    final exportedOn = DateFormat('MMMM d, yyyy').format(now);
    final exportedAt = DateFormat('h:mm:ss a').format(now);

    final deleteCount = rows
        .where((r) =>
            (r['action'] ?? '').toString().toUpperCase().startsWith('DELETE'))
        .length;
    final actorCount = rows
        .map((r) => (r['user_name'] ?? '').toString().trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .length;

    // Rows are newest-first, so first = newest and last = oldest.
    final newest = _times[rows.first] ?? _parseDateTime(rows.first['timestamp']);
    final oldest = _times[rows.last] ?? _parseDateTime(rows.last['timestamp']);
    String dayLabel(DateTime? d) =>
        d == null ? '-' : DateFormat('MMM d, yyyy').format(d);

    final filters = <String>[
      if (_actionFilter != 'All') 'Action: $_actionFilter',
      if (_dateFilter != _DateFilterOption.all) 'Date: $_dateFilterPillLabel',
      if (_searchQuery.isNotEmpty) 'Search: "$_searchQuery"',
    ];
    final exporterLine = exportedRole.isEmpty
        ? exportedBy
        : '$exportedBy (${_titleCase(exportedRole)})';

    pw.Widget info(String label, String value) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(label.toUpperCase(),
                  style: pw.TextStyle(
                      fontSize: 6.5,
                      fontWeight: pw.FontWeight.bold,
                      color: muted,
                      letterSpacing: 0.6)),
              pw.SizedBox(height: 2),
              pw.Text(t(value),
                  style: pw.TextStyle(
                      fontSize: 8.5,
                      fontWeight: pw.FontWeight.bold,
                      color: ink)),
            ],
          ),
        );

    final data = <List<String>>[
      for (var i = 0; i < rows.length; i++)
        () {
          final r = rows[i];
          final ts = _times[r] ?? _parseDateTime(r['timestamp']);
          return <String>[
            '${i + 1}',
            ts == null ? '-' : DateFormat('yyyy-MM-dd h:mm:ss a').format(ts),
            t((r['action'] ?? '-').toString()),
            t((r['user_name'] ?? '-').toString()),
            t(_pdfDetails(r)),
          ];
        }(),
    ];

    final doc = pw.Document(title: 'SafeWatch Logs', author: 'SafeWatch');

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(t('SafeWatch  |  Logs  |  Exported by $exportedBy'),
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
                decoration: pw.BoxDecoration(
                    color: accent, borderRadius: pw.BorderRadius.circular(2)),
              ),
              pw.SizedBox(width: 10),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('SAFEWATCH',
                        style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                            color: accent,
                            letterSpacing: 1.4)),
                    pw.SizedBox(height: 2),
                    pw.Text('Logs',
                        style: pw.TextStyle(
                            fontSize: 20,
                            fontWeight: pw.FontWeight.bold,
                            color: ink)),
                    pw.SizedBox(height: 2),
                    pw.Text('System activity across the platform',
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
                      info('Total entries', '${rows.length}'),
                      info('Delete actions', '$deleteCount'),
                      info('Unique actors', '$actorCount'),
                    ],
                  ),
                ),
                pw.Expanded(
                  flex: 5,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      info('Filters applied',
                          filters.isEmpty ? 'None (all logs)' : filters.join(', ')),
                      info('Logs dated',
                          '${dayLabel(oldest)} - ${dayLabel(newest)}'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          // --- Table ---
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Date & Time', 'Action', 'User', 'Details'],
            data: data,
            headerStyle: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white),
            headerDecoration: pw.BoxDecoration(color: accent),
            cellStyle: const pw.TextStyle(fontSize: 8, color: ink),
            border: pw.TableBorder.all(color: line, width: 0.6),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 6),
            cellAlignment: pw.Alignment.centerLeft,
            headerAlignment: pw.Alignment.centerLeft,
            cellAlignments: {0: pw.Alignment.center},
            headerAlignments: {0: pw.Alignment.center},
            columnWidths: {
              0: const pw.FlexColumnWidth(0.4),
              1: const pw.FlexColumnWidth(1.7),
              2: const pw.FlexColumnWidth(1.7),
              3: const pw.FlexColumnWidth(1.3),
              4: const pw.FlexColumnWidth(2.9),
            },
          ),
        ],
      ),
    );

    return doc.save();
  }

  // --- FEED VIEW (default) ---

  /// Headers and rows are flattened into one list so ListView.builder
  /// only builds what's actually on screen (previously each day group
  /// was a Column that built all of its rows at once).
  Widget _buildFeedBody(List<Map<String, dynamic>> pageLogs) {
    final items = <Object>[];
    for (final g in _groupByDate(pageLogs)) {
      items.add(_GroupHeader(g.key, g.value.length));
      items.addAll(g.value);
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        if (item is _GroupHeader) {
          return _dateGroupHeader(item.label, item.count);
        }
        final row = item as Map<String, dynamic>;
        return _LogFeedRow(
          key: ValueKey(row['id'] ?? row.hashCode),
          isSelected: _selectedLog?['id'] == row['id'],
          time: _formatTimeOnly(row['timestamp']),
          action: (row['action'] ?? 'N/A').toString(),
          userName: (row['user_name'] ?? 'Unknown').toString(),
          message: _summaryLine((row['details'] ?? 'No details').toString()),
          color: _colorForAction((row['action'] ?? '').toString()),
          onTap: () => setState(() {
            _selectedLog = row;
            _rightPanelMode = 'view';
          }),
        );
      },
    );
  }

  /// `# TODAY  ··········  12 EVENTS` — a comment-style separator
  /// between day groups, styled like a log-viewer section break rather
  /// than a table header.
  Widget _dateGroupHeader(String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Text(
            '# $label',
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontFamily: monoFont,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: AppColors.border(context), height: 1)),
          const SizedBox(width: 10),
          Text(
            '$count EVENT${count == 1 ? '' : 'S'}',
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontFamily: monoFont,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  /// Compact pager: prev/next arrows plus page number buttons.
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
      return HoverPop(
        enabled: onTap != null,
        child: SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            padding: EdgeInsets.zero,
            onPressed: onTap,
            icon: Icon(icon,
                size: 16,
                color: onTap == null
                    ? AppColors.textMuted(context)
                    : AppColors.textMain(context)),
            splashRadius: 16,
          ),
        ),
      );
    }

    Widget pageButton(int pageIndex) {
      final isCurrent = pageIndex == currentPage;
      return HoverPop(
        enabled: !isCurrent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: isCurrent ? null : () => setState(() => _currentPage = pageIndex),
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isCurrent ? AppColors.accentBlue : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border:
                  isCurrent ? null : Border.all(color: AppColors.border(context)),
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
        ),
      );
    }

    final pages = pageNumbers();
    final widgets = <Widget>[
      arrowButton(Icons.chevron_left,
          currentPage > 0 ? () => setState(() => _currentPage--) : null),
      const SizedBox(width: 4),
    ];

    for (int i = 0; i < pages.length; i++) {
      if (i > 0 && pages[i] - pages[i - 1] > 1) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('…',
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
        ));
      }
      widgets.add(pageButton(pages[i]));
      if (i != pages.length - 1) widgets.add(const SizedBox(width: 4));
    }

    widgets.add(const SizedBox(width: 4));
    widgets.add(arrowButton(Icons.chevron_right,
        currentPage < totalPages - 1 ? () => setState(() => _currentPage++) : null));

    return Row(mainAxisSize: MainAxisSize.min, children: widgets);
  }

  // --- FLOATING PANEL OVERLAY ---

  void _syncPanelOverlay() {
    if (!mounted) return;

    if (_rightPanelMode != null) {
      if (_panelOverlayEntry == null) {
        _panelOverlayEntry = OverlayEntry(builder: (_) => _buildPanelOverlay());
        Overlay.of(context, rootOverlay: true).insert(_panelOverlayEntry!);
        _panelAnimController.forward(from: 0);
      } else {
        _panelOverlayEntry!.markNeedsBuild();
        // Re-opened while a close animation was running (or finished).
        if (_panelAnimController.status == AnimationStatus.reverse ||
            _panelAnimController.status == AnimationStatus.dismissed) {
          _panelAnimController.forward();
        }
      }
    } else if (_panelOverlayEntry != null) {
      // Only start the close animation once; this method runs after every
      // build (including each theme-fade frame).
      if (_panelAnimController.status != AnimationStatus.reverse &&
          _panelAnimController.status != AnimationStatus.dismissed) {
        _panelAnimController.reverse().then((_) {
          if (_rightPanelMode == null) {
            _panelOverlayEntry?.remove();
            _panelOverlayEntry = null;
          }
        });
      }
    }
  }

  Widget _buildPanelOverlay() {
    return Positioned.fill(
      child: Stack(
        children: [
          AnimatedBuilder(
            animation: _panelAnimController,
            builder: (context, _) => Positioned.fill(
              child: GestureDetector(
                onTap: _closeRightPanel,
                child: Container(
                  color: Colors.black.withOpacity(0.5 * _panelAnimController.value),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: 440,
            child: SlideTransition(
              position: _panelSlide,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 24,
                        offset: const Offset(-4, 0),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: GestureDetector(
                      onTap: () {},
                      child: SafeArea(child: _buildDetailsSidePanel()),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsSidePanel() {
    if (_selectedLog == null) return const SizedBox.shrink();

    final log = _selectedLog!;
    final userName = (log['user_name'] ?? 'Unknown').toString();
    final action = (log['action'] ?? 'N/A').toString();
    final rawDetails = (log['details'] ?? 'No details provided.').toString();
    final parsed = _parseLogDetails(rawDetails);
    final timestamp = _formatTimestamp(log['timestamp']);
    final color = _colorForAction(action);
    final isSystemEntry = userName.toLowerCase().startsWith('system');
    final logId = (log['id'] ?? '').toString();

    Widget sectionLabel(String text, {IconData? icon}) {
      return Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: AppColors.textMain(context)),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              color: AppColors.textMain(context),
              fontFamily: monoFont,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
        ],
      );
    }

    Widget dot(Color c) => Container(
          width: 8,
          height: 8,
          decoration:
              BoxDecoration(shape: BoxShape.circle, color: c.withOpacity(0.85)),
        );

    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Same traffic-light chrome as the main console, so the panel
          // reads as part of the same terminal rather than a separate
          // dialog style.
          Container(
            color: AppColors.sunken(context),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              dot(AppColors.accentRed),
              const SizedBox(width: 6),
              dot(AppColors.accentOrange),
              const SizedBox(width: 6),
              dot(AppColors.accentGreen),
            ]),
          ),
          Container(
            color: AppColors.sunken(context),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Row(
              children: [
                HoverPop(
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _selectedLog = null;
                      _rightPanelMode = null;
                    }),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.border(context).withOpacity(0.6),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.arrow_back,
                          size: 17, color: AppColors.textMain(context)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'LOG_ENTRY',
                        style: TextStyle(
                          color: AppColors.textMain(context),
                          fontFamily: monoFont,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      if (logId.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'ref=${logId.length > 8 ? logId.substring(0, 8) : logId}',
                          style: TextStyle(
                            color: AppColors.textMuted(context),
                            fontFamily: monoFont,
                            fontSize: 10.5,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),

          Expanded(
            child: ClipRect(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: color.withOpacity(0.3)),
                          ),
                          child: Text(
                            '[${action.toUpperCase()}]',
                            style: TextStyle(
                              color: color,
                              fontFamily: monoFont,
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(
                          isSystemEntry
                              ? Icons.smart_toy_outlined
                              : Icons.person_outline,
                          size: 15,
                          color: isSystemEntry
                              ? Colors.orangeAccent
                              : AppColors.accentBlue,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            userName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textMain(context),
                              fontFamily: monoFont,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      timestamp,
                      style: TextStyle(
                        color: AppColors.textMuted(context),
                        fontFamily: monoFont,
                        fontSize: 11.5,
                      ),
                    ),

                    const SizedBox(height: 20),
                    sectionLabel('EVENT SUMMARY', icon: Icons.description_outlined),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.sunken(context),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border(context)),
                      ),
                      child: SelectableText(
                        parsed.summary,
                        style: TextStyle(
                          color: AppColors.textMain(context),
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),

                    if (parsed.changes.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      sectionLabel('FIELD CHANGES (${parsed.changes.length})',
                          icon: Icons.compare_arrows),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: AppColors.sunken(context),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border(context)),
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 110,
                                    child: Text(
                                      'FIELD',
                                      style: TextStyle(
                                        color: AppColors.textMuted(context),
                                        fontFamily: monoFont,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Text(
                                          'BEFORE',
                                          style: TextStyle(
                                            color: AppColors.textMuted(context),
                                            fontFamily: monoFont,
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.8,
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          'AFTER',
                                          style: TextStyle(
                                            color: AppColors.textMuted(context),
                                            fontFamily: monoFont,
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.8,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Divider(color: AppColors.border(context), height: 1),
                            for (int i = 0; i < parsed.changes.length; i++) ...[
                              if (i != 0)
                                Divider(color: AppColors.border(context), height: 1),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                child: _buildChangeRow(parsed.changes[i]),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],

                    if (parsed.extra != null) ...[
                      const SizedBox(height: 20),
                      sectionLabel('METADATA', icon: Icons.data_object),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.sunken(context),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border(context)),
                        ),
                        child: SelectableText(
                          parsed.extra!,
                          style: TextStyle(
                            color: AppColors.textMuted(context),
                            fontFamily: monoFont,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerRight,
                      child: HoverPop(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            final buffer = StringBuffer()
                              ..writeln('[$timestamp] [${action.toUpperCase()}] $userName')
                              ..writeln(parsed.summary);
                            for (final c in parsed.changes) {
                              buffer.writeln('- ${c.field}: ${c.from} → ${c.to}');
                            }
                            if (parsed.extra != null) buffer.writeln(parsed.extra);
                            Clipboard.setData(
                                ClipboardData(text: buffer.toString().trim()));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Log entry copied'),
                                duration: Duration(seconds: 1, milliseconds: 500),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.copy_rounded,
                                    size: 13, color: AppColors.textMuted(context)),
                                const SizedBox(width: 5),
                                Text(
                                  'COPY ENTRY',
                                  style: TextStyle(
                                    color: AppColors.textMuted(context),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          Divider(color: AppColors.border(context), height: 1, thickness: 1),

          Container(
            color: AppColors.sunken(context),
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: HoverPop(
                child: ElevatedButton(
                  onPressed: () => setState(() {
                    _selectedLog = null;
                    _rightPanelMode = null;
                  }),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.border(context),
                    foregroundColor: AppColors.textMain(context),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text(
                    'CLOSE',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChangeRow(_ParsedChange change) {
    Widget valueChip(String text, {required bool isNew}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isNew
              ? AppColors.accentGreen.withOpacity(0.12)
              : AppColors.accentRed.withOpacity(0.08),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: isNew
                ? AppColors.accentGreen.withOpacity(0.35)
                : AppColors.accentRed.withOpacity(0.25),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isNew ? AppColors.accentGreen : AppColors.accentRed,
            fontFamily: monoFont,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            decoration: isNew ? null : TextDecoration.lineThrough,
            decorationColor: AppColors.accentRed.withOpacity(0.6),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            change.field,
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              valueChip(change.from, isNew: false),
              Icon(Icons.arrow_forward, size: 13, color: AppColors.textMuted(context)),
              valueChip(change.to, isNew: true),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Small range-calendar popup — opened under the date filter pill when
// "Custom range" is picked. Tap a start day, tap an end day, hit Apply.
// Pops a DateTimeRange (or null when cancelled / dismissed).
// ---------------------------------------------------------------------------

class _RangeCalendarPopup extends StatefulWidget {
  static const double width = 282;

  final DateTime? initialStart;
  final DateTime? initialEnd;
  final DateTime firstDate;
  final DateTime lastDate;

  const _RangeCalendarPopup({
    required this.initialStart,
    required this.initialEnd,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<_RangeCalendarPopup> createState() => _RangeCalendarPopupState();
}

class _RangeCalendarPopupState extends State<_RangeCalendarPopup> {
  late DateTime _month; // always the 1st of the visible month
  DateTime? _start;
  DateTime? _end;

  static const _weekdays = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  DateTime _d(DateTime x) => DateTime(x.year, x.month, x.day);

  @override
  void initState() {
    super.initState();
    _start = widget.initialStart == null ? null : _d(widget.initialStart!);
    _end = widget.initialEnd == null ? null : _d(widget.initialEnd!);
    final anchor = _end ?? _start ?? widget.lastDate;
    _month = DateTime(anchor.year, anchor.month);
  }

  bool get _canGoPrev {
    final first = DateTime(widget.firstDate.year, widget.firstDate.month);
    return _month.isAfter(first);
  }

  bool get _canGoNext {
    final last = DateTime(widget.lastDate.year, widget.lastDate.month);
    return _month.isBefore(last);
  }

  bool _isDisabled(DateTime day) =>
      day.isBefore(_d(widget.firstDate)) || day.isAfter(_d(widget.lastDate));

  void _tapDay(DateTime day) {
    setState(() {
      if (_start == null || (_start != null && _end != null)) {
        _start = day;
        _end = null;
      } else if (day.isBefore(_start!)) {
        _start = day;
      } else {
        _end = day;
      }
    });
  }

  bool _inRange(DateTime day) =>
      _start != null &&
      _end != null &&
      day.isAfter(_start!) &&
      day.isBefore(_end!);

  Widget _navButton(IconData icon, VoidCallback? onTap) {
    return HoverPop(
      enabled: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          color: Colors.transparent,
          child: Icon(icon,
              size: 18,
              color: onTap == null
                  ? AppColors.textMuted(context).withOpacity(0.4)
                  : AppColors.textMain(context)),
        ),
      ),
    );
  }

  Widget _dayCell(DateTime day) {
    final disabled = _isDisabled(day);
    final isStart = _start != null && day == _start;
    final isEnd = _end != null && day == _end;
    final selected = isStart || isEnd;
    final inRange = _inRange(day);
    final today = _d(DateTime.now());
    final isToday = day == today;

    final textColor = selected
        ? Colors.white
        : disabled
            ? AppColors.textMuted(context).withOpacity(0.4)
            : AppColors.textMain(context);

    return HoverPop(
      enabled: !disabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled ? null : () => _tapDay(day),
        child: Container(
          width: 36,
          height: 32,
          alignment: Alignment.center,
          // Range band behind the circle.
          color: inRange ? AppColors.accentBlue.withOpacity(0.12) : Colors.transparent,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? AppColors.accentBlue : Colors.transparent,
              shape: BoxShape.circle,
              border: isToday && !selected
                  ? Border.all(color: AppColors.accentBlue.withOpacity(0.6))
                  : null,
            ),
            child: Text(
              '${day.day}',
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: selected || isToday ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = _month.weekday % 7; // Sunday-first grid
    final cells = <Widget>[
      for (var i = 0; i < leading; i++) const SizedBox(width: 36, height: 32),
      for (var day = 1; day <= daysInMonth; day++)
        _dayCell(DateTime(_month.year, _month.month, day)),
    ];
    while (cells.length % 7 != 0) {
      cells.add(const SizedBox(width: 36, height: 32));
    }
    final rows = <Widget>[
      for (var i = 0; i < cells.length; i += 7)
        Row(children: cells.sublist(i, i + 7)),
    ];

    final fmt = DateFormat('MMM d');
    final summary = _start == null
        ? 'Select a start date'
        : _end == null
            ? '${fmt.format(_start!)} – pick an end date'
            : '${fmt.format(_start!)} – ${fmt.format(_end!)}';

    return Material(
      color: AppColors.card(context),
      elevation: 12,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: _RangeCalendarPopup.width,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Month header
            Row(
              children: [
                _navButton(
                  Icons.chevron_left,
                  _canGoPrev
                      ? () => setState(() =>
                          _month = DateTime(_month.year, _month.month - 1))
                      : null,
                ),
                Expanded(
                  child: Text(
                    DateFormat('MMMM yyyy').format(_month),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _navButton(
                  Icons.chevron_right,
                  _canGoNext
                      ? () => setState(() =>
                          _month = DateTime(_month.year, _month.month + 1))
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Weekday labels
            Row(
              children: [
                for (final w in _weekdays)
                  SizedBox(
                    width: 36,
                    height: 22,
                    child: Center(
                      child: Text(
                        w,
                        style: TextStyle(
                          color: AppColors.textMuted(context),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            ...rows,
            const SizedBox(height: 8),
            Divider(color: AppColors.border(context), height: 1),
            const SizedBox(height: 10),
            Text(
              summary,
              style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: HoverPop(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textMain(context),
                        side: BorderSide(color: AppColors.border(context)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('CANCEL',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: HoverPop(
                    enabled: _start != null,
                    child: ElevatedButton(
                      onPressed: _start == null
                          ? null
                          : () => Navigator.of(context).pop(
                                DateTimeRange(
                                  start: _start!,
                                  end: _end ?? _start!,
                                ),
                              ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accentBlue,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            AppColors.accentBlue.withOpacity(0.4),
                        disabledForegroundColor: Colors.white70,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('APPLY',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stat card — same visual language as Users' dashboard cards.
// The misleading progress bar (value share vs. total events) has been
// removed: it wasn't a meaningful ratio for every metric (e.g. unique
// actor count against total event count) and just added visual noise.
// ---------------------------------------------------------------------------

class _LogStatCard extends StatefulWidget {
  final String label;
  final int value;
  final String caption;
  final IconData icon;
  final Color color;

  const _LogStatCard({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
  });

  @override
  State<_LogStatCard> createState() => _LogStatCardState();
}

class _LogStatCardState extends State<_LogStatCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Only the hover is animated locally (t: 0 -> 1). Theme colors are
      // read fresh from the ThemeExtension on every rebuild, so they follow
      // MaterialApp's theme fade with no key/teardown. The child Column is
      // built once and reused across animation frames.
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _hover ? 1.0 : 0.0),
        duration: const Duration(milliseconds: 160),
        builder: (context, t, child) => Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Color.lerp(
                  AppColors.border(context), c.withOpacity(0.5), t)!,
            ),
            boxShadow: [
              BoxShadow(
                color: c.withOpacity(0.14 * t),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
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
                Text(
                  widget.caption,
                  style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '${widget.value}',
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
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Feed row — a single console line: dot, time, [ACTION] chip, actor,
// message. This is the primary, default view.
// ---------------------------------------------------------------------------

class _LogFeedRow extends StatefulWidget {
  final bool isSelected;
  final String time;
  final String action;
  final String userName;
  final String message;
  final Color color;
  final VoidCallback onTap;

  const _LogFeedRow({
    super.key,
    required this.isSelected,
    required this.time,
    required this.action,
    required this.userName,
    required this.message,
    required this.color,
    required this.onTap,
  });

  @override
  State<_LogFeedRow> createState() => _LogFeedRowState();
}

class _LogFeedRowState extends State<_LogFeedRow> {
  bool _hover = false;
  static const String _mono = 'monospace';

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // Plain Container (not AnimatedContainer) so the row background
        // follows the theme fade directly instead of trailing behind it.
        child: Container(
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.accentBlue.withOpacity(0.08)
                : AppColors.sunken(context).withOpacity(_hover ? 1 : 0),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
              ),
              SizedBox(
                width: 66,
                child: Text(
                  widget.time,
                  style: TextStyle(
                      color: AppColors.textMuted(context), fontFamily: _mono, fontSize: 11.5),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '[${widget.action.toUpperCase()}]',
                  style: TextStyle(
                    color: widget.color,
                    fontFamily: _mono,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 130,
                child: Text(
                  widget.userName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMain(context),
                    fontFamily: _mono,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppColors.textMuted(context), fontFamily: _mono, fontSize: 11.5),
                ),
              ),
              AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: Icon(Icons.chevron_right, size: 16, color: AppColors.textMuted(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}