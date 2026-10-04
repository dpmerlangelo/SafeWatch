import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import 'auto_response_section.dart';

/// One entry in the Settings screen's left-hand section list.
class _SettingsSection {
  final String id;
  final String label;
  final IconData icon;
  final WidgetBuilder builder;

  const _SettingsSection({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
  });
}

class AdminSettingsScreen extends StatefulWidget {
  final bool isActive;
  const AdminSettingsScreen({super.key, required this.isActive});

  @override
  State<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends State<AdminSettingsScreen> {
  late final List<_SettingsSection> _sections = [
    _SettingsSection(
      id: 'emergency_contacts',
      label: 'Emergency Numbers',
      icon: Icons.emergency_outlined,
      builder: (_) => const EmergencyContactsSection(),
    ),
    _SettingsSection(
      id: 'auto_response',
      label: 'Auto Response',
      icon: Icons.timer_outlined,
      builder: (_) => const AutoResponseSection(),
    ),
    _SettingsSection(
      id: 'detection_timing',
      label: 'Detection Timing',
      icon: Icons.av_timer_outlined,
      builder: (_) => const DetectionTimingSection(),
    ),
    // Add more admin configs here.
  ];

  String _selectedId = 'emergency_contacts';

  @override
  Widget build(BuildContext context) {
    final selected = _sections.firstWhere((s) => s.id == _selectedId);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Section list ---
        Container(
          width: 220,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: AppColors.border(context))),
          ),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final section in _sections)
                _sectionTile(section, isSelected: section.id == _selectedId),
            ],
          ),
        ),
        // --- Selected section content ---
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: selected.builder(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTile(_SettingsSection section, {required bool isSelected}) {
    final color = isSelected ? AppColors.accentBlue : AppColors.textMuted(context);
    return Material(
      color: isSelected ? AppColors.accentBlue.withOpacity(0.08) : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedId = section.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(section.icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  section.label,
                  style: TextStyle(
                    color: isSelected ? AppColors.textMain(context) : AppColors.textMuted(context),
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ---------------------------------------------------------------
/// Emergency Numbers section — reads/writes `app_settings` row with
/// key = 'emergency_contacts', value = {"fire": "...", "ambulance": "..."}.
/// ---------------------------------------------------------------
class EmergencyContactsSection extends StatefulWidget {
  const EmergencyContactsSection({super.key});

  @override
  State<EmergencyContactsSection> createState() => _EmergencyContactsSectionState();
}

class _EmergencyContactsSectionState extends State<EmergencyContactsSection> {
  final _supabase = Supabase.instance.client;
  final _fireController = TextEditingController();
  final _ambulanceController = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _fireController.dispose();
    _ambulanceController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final row = await _supabase
          .from('app_settings')
          .select('value')
          .eq('key', 'emergency_contacts')
          .maybeSingle();
      final value = (row?['value'] as Map<String, dynamic>?) ?? {};
      _fireController.text = (value['fire'] ?? '').toString();
      _ambulanceController.text = (value['ambulance'] ?? '').toString();
    } catch (_) {
      // leave fields blank — save() below will still create the row
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _supabase.from('app_settings').upsert({
        'key': 'emergency_contacts',
        'value': {
          'fire': _fireController.text.trim(),
          'ambulance': _ambulanceController.text.trim(),
        },
        'updated_by': _supabase.auth.currentUser?.id,
        'updated_at': DateTime.now().toIso8601String(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Emergency numbers saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String label, TextEditingController controller, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, size: 18, color: AppColors.textMuted(context)),
            hintText: 'e.g. +63 900 000 0000',
            hintStyle: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
            filled: true,
            fillColor: AppColors.bg(context),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppColors.border(context)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppColors.border(context)),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Emergency Numbers',
              style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'These numbers power the "Call Fire Dept" / "Call Ambulance" '
            'buttons tanods see on active dispatches.',
            style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 20),
          _field('FIRE DEPARTMENT', _fireController, Icons.local_fire_department_outlined),
          const SizedBox(height: 16),
          _field('AMBULANCE', _ambulanceController, Icons.local_hospital_outlined),
          const SizedBox(height: 22),
          SizedBox(
            width: 160,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(_saving ? 'SAVING…' : 'SAVE CHANGES',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------
/// Detection Timing section — reads/writes `app_settings` row with
/// key = 'detection_settings',
/// value = {
///   "confirm_seconds": 2.0,
///   "border_seconds": 4.0,
///   "curfew_enabled": true,
///   "curfew_start": "22:00",   // 24h HH:MM
///   "curfew_end": "04:00",     // 24h HH:MM, may cross midnight
///   "curfew_min_persons": 1,   // people in view needed to raise curfew
///   "curfew_confirm_seconds": 5.0  // how long they must stay (0 = instant)
/// }.
///
/// The Python detection service re-reads this row every ~10 seconds, so
/// changes apply without restarting it.
///
///  - confirm_seconds: how long the AI must keep detecting the same
///    incident before it is confirmed and sent to the cameras
///    (0 = send immediately).
///  - border_seconds: how long the coloured alert border/label stays on
///    the camera tile after the last detection.
///  - curfew_*: whether curfew alerts are on, and the hours during which
///    a person on camera triggers one. The times are read by the service
///    in its own timezone (CURFEW_TIMEZONE in yolo_detection_service.py,
///    Asia/Manila by default).
/// ---------------------------------------------------------------
class DetectionTimingSection extends StatefulWidget {
  const DetectionTimingSection({super.key});

  @override
  State<DetectionTimingSection> createState() => _DetectionTimingSectionState();
}

class _DetectionTimingSectionState extends State<DetectionTimingSection> {
  static const String _settingsKey = 'detection_settings';

  // Must match the limits in yolo_detection_service.py.
  static const double _confirmMin = 0;
  static const double _confirmMax = 30;
  static const double _borderMin = 1;
  static const double _borderMax = 60;

  static const double _defaultConfirm = 2;
  static const double _defaultBorder = 4;

  // Must match DEFAULT_CURFEW_* in yolo_detection_service.py.
  static const bool _defaultCurfewEnabled = true;
  static const TimeOfDay _defaultCurfewStart = TimeOfDay(hour: 22, minute: 0);
  static const TimeOfDay _defaultCurfewEnd = TimeOfDay(hour: 4, minute: 0);
  static const int _defaultCurfewMinPersons = 1;
  static const double _defaultCurfewConfirm = 5;

  // Must match MIN/MAX_CURFEW_* in yolo_detection_service.py.
  static const int _curfewMinPersonsMin = 1;
  static const int _curfewMinPersonsMax = 20;
  static const double _curfewConfirmMin = 0;
  static const double _curfewConfirmMax = 600; // 10 minutes

  final _supabase = Supabase.instance.client;
  double _confirmSeconds = _defaultConfirm;
  double _borderSeconds = _defaultBorder;
  bool _curfewEnabled = _defaultCurfewEnabled;
  TimeOfDay _curfewStart = _defaultCurfewStart;
  TimeOfDay _curfewEnd = _defaultCurfewEnd;
  int _curfewMinPersons = _defaultCurfewMinPersons;
  double _curfewConfirmSeconds = _defaultCurfewConfirm;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// "22:30" -> TimeOfDay(22, 30). Returns null if invalid.
  TimeOfDay? _parseTime(dynamic raw) {
    if (raw is! String) return null;
    final parts = raw.trim().split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    if (h < 0 || h > 23 || m < 0 || m > 59) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  /// TimeOfDay -> "HH:MM" (24h), the format the Python service reads.
  String _time24(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _load() async {
    try {
      final row = await _supabase
          .from('app_settings')
          .select('value')
          .eq('key', _settingsKey)
          .maybeSingle();
      final value = (row?['value'] as Map<String, dynamic>?) ?? {};
      final confirm = (value['confirm_seconds'] as num?)?.toDouble();
      final border = (value['border_seconds'] as num?)?.toDouble();
      if (confirm != null) {
        _confirmSeconds = confirm.clamp(_confirmMin, _confirmMax).toDouble();
      }
      if (border != null) {
        _borderSeconds = border.clamp(_borderMin, _borderMax).toDouble();
      }

      final curfewEnabled = value['curfew_enabled'];
      if (curfewEnabled is bool) _curfewEnabled = curfewEnabled;
      final start = _parseTime(value['curfew_start']);
      if (start != null) _curfewStart = start;
      final end = _parseTime(value['curfew_end']);
      if (end != null) _curfewEnd = end;

      final minPersons = (value['curfew_min_persons'] as num?)?.toInt();
      if (minPersons != null) {
        _curfewMinPersons =
            minPersons.clamp(_curfewMinPersonsMin, _curfewMinPersonsMax).toInt();
      }
      final curfewConfirm = (value['curfew_confirm_seconds'] as num?)?.toDouble();
      if (curfewConfirm != null) {
        _curfewConfirmSeconds =
            curfewConfirm.clamp(_curfewConfirmMin, _curfewConfirmMax).toDouble();
      }
    } catch (_) {
      // keep defaults — save() will create the row
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _supabase.from('app_settings').upsert({
        'key': _settingsKey,
        'value': {
          'confirm_seconds': _confirmSeconds,
          'border_seconds': _borderSeconds,
          'curfew_enabled': _curfewEnabled,
          'curfew_start': _time24(_curfewStart),
          'curfew_end': _time24(_curfewEnd),
          'curfew_min_persons': _curfewMinPersons,
          'curfew_confirm_seconds': _curfewConfirmSeconds,
        },
        'updated_by': _supabase.auth.currentUser?.id,
        'updated_at': DateTime.now().toIso8601String(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Detection settings saved (applies within ~10 seconds)')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetDefaults() {
    setState(() {
      _confirmSeconds = _defaultConfirm;
      _borderSeconds = _defaultBorder;
      _curfewEnabled = _defaultCurfewEnabled;
      _curfewStart = _defaultCurfewStart;
      _curfewEnd = _defaultCurfewEnd;
      _curfewMinPersons = _defaultCurfewMinPersons;
      _curfewConfirmSeconds = _defaultCurfewConfirm;
    });
  }

  Future<void> _pickTime({required bool isStart}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _curfewStart : _curfewEnd,
      helpText: isStart ? 'CURFEW STARTS' : 'CURFEW ENDS',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _curfewStart = picked;
      } else {
        _curfewEnd = picked;
      }
    });
  }

  String _fmt(double v) {
    if (v >= 60) {
      final total = v.round();
      final m = total ~/ 60;
      final s = total % 60;
      return s == 0 ? '$m min' : '$m min $s s';
    }
    return v == v.roundToDouble() ? '${v.toInt()} s' : '${v.toStringAsFixed(1)} s';
  }

  Widget _slider({
    required String label,
    required String description,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    String? valueOverride,
    double step = 0.5,
  }) {
    final divisions = ((max - min) / step).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.sunken(context),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                valueOverride ?? _fmt(value),
                style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: AppColors.accentBlue,
          onChanged: onChanged,
        ),
        Text(
          description,
          style: TextStyle(
              color: AppColors.textMuted(context), fontSize: 12, height: 1.4),
        ),
      ],
    );
  }

  Widget _timeButton({
    required String label,
    required TimeOfDay time,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: AppColors.textMuted(context),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4)),
          const SizedBox(height: 6),
          InkWell(
            onTap: _curfewEnabled ? onTap : null,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.bg(context),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule,
                      size: 18, color: AppColors.textMuted(context)),
                  const SizedBox(width: 8),
                  Text(
                    time.format(context),
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Human-readable description of the current curfew window.
  String _curfewSummary() {
    final s = _minutes(_curfewStart);
    final e = _minutes(_curfewEnd);
    if (s == e) {
      return 'Start and end are the same, so curfew will never trigger. '
          'Pick different times.';
    }
    final start = _curfewStart.format(context);
    final end = _curfewEnd.format(context);
    final overnight = s > e;
    return 'Curfew alerts are active from $start to $end'
        '${overnight ? ' (overnight, ending the next day)' : ''}.';
  }

  Widget _stepper({
    required String label,
    required String description,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              color: AppColors.textMuted(context),
              onPressed: value > min ? () => onChanged(value - 1) : null,
            ),
            Container(
              constraints: const BoxConstraints(minWidth: 40),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.sunken(context),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$value',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_circle_outline, size: 20),
              color: AppColors.textMuted(context),
              onPressed: value < max ? () => onChanged(value + 1) : null,
            ),
          ],
        ),
        Text(
          description,
          style: TextStyle(
              color: AppColors.textMuted(context), fontSize: 12, height: 1.4),
        ),
      ],
    );
  }

  Widget _curfewSection() {
    final misconfigured = _minutes(_curfewStart) == _minutes(_curfewEnd);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('CURFEW HOURS',
                  style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4)),
            ),
            Switch(
              value: _curfewEnabled,
              activeColor: AppColors.accentBlue,
              onChanged: (v) => setState(() => _curfewEnabled = v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Opacity(
          opacity: _curfewEnabled ? 1 : 0.5,
          child: Row(
            children: [
              _timeButton(
                label: 'STARTS',
                time: _curfewStart,
                onTap: () => _pickTime(isStart: true),
              ),
              const SizedBox(width: 12),
              _timeButton(
                label: 'ENDS',
                time: _curfewEnd,
                onTap: () => _pickTime(isStart: false),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _curfewEnabled
              ? _curfewSummary()
              : 'Curfew alerts are turned off.',
          style: TextStyle(
              color: (_curfewEnabled && misconfigured)
                  ? Colors.orange
                  : AppColors.textMuted(context),
              fontSize: 12,
              height: 1.4),
        ),
        const SizedBox(height: 16),
        Opacity(
          opacity: _curfewEnabled ? 1 : 0.5,
          child: IgnorePointer(
            ignoring: !_curfewEnabled,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _stepper(
                  label: 'MINIMUM PEOPLE',
                  description:
                      'How many people must be in view at the same time to '
                      'count as a curfew violation.',
                  value: _curfewMinPersons,
                  min: _curfewMinPersonsMin,
                  max: _curfewMinPersonsMax,
                  onChanged: (v) => setState(() => _curfewMinPersons = v),
                ),
                const SizedBox(height: 16),
                _slider(
                  label: 'CURFEW CONFIRMATION TIME',
                  description:
                      'How long that many people must stay in view during '
                      'curfew hours before a curfew alert is raised. Longer = '
                      'fewer alerts for people just passing by. This replaces '
                      'the general confirmation time for curfew only. '
                      'Up to 10 minutes, in 5-second steps. '
                      '0 alerts immediately.',
                  value: _curfewConfirmSeconds,
                  min: _curfewConfirmMin,
                  max: _curfewConfirmMax,
                  step: 5,
                  valueOverride: _curfewConfirmSeconds == 0 ? 'Instant' : null,
                  onChanged: (v) => setState(() => _curfewConfirmSeconds = v),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Detection Timing',
              style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Control how quickly the AI confirms an incident, how long the '
            'alert border stays on the camera, and when curfew alerts apply. '
            'Changes reach the detection service automatically within about '
            '10 seconds.',
            style: TextStyle(
                color: AppColors.textMuted(context), fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 22),
          _slider(
            label: 'CONFIRMATION TIME',
            description:
                'The AI must keep detecting the same incident for this long '
                'before it is confirmed, shown on the camera, and recorded. '
                'Higher = fewer false alarms but slower alerts. '
                '0 sends the alert immediately.',
            value: _confirmSeconds,
            min: _confirmMin,
            max: _confirmMax,
            valueOverride: _confirmSeconds == 0 ? 'Instant' : null,
            onChanged: (v) => setState(() => _confirmSeconds = v),
          ),
          const SizedBox(height: 20),
          _slider(
            label: 'ALERT BORDER DURATION',
            description:
                'How long the coloured alert border and label stay on the '
                'camera tile after the last detection.',
            value: _borderSeconds,
            min: _borderMin,
            max: _borderMax,
            onChanged: (v) => setState(() => _borderSeconds = v),
          ),
          const SizedBox(height: 24),
          _curfewSection(),
          const SizedBox(height: 22),
          Row(
            children: [
              SizedBox(
                width: 160,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(_saving ? 'SAVING…' : 'SAVE CHANGES',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5)),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _saving ? null : _resetDefaults,
                child: Text('Reset to defaults',
                    style: TextStyle(
                        color: AppColors.textMuted(context), fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}