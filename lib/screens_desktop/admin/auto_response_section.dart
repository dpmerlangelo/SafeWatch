import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../command_center/cctv_live_screen.dart' show AlertLevel;
import '../../constants/app_colors.dart';
import '../../services/auto_dispatch_config.dart';

const Color _amber = Color(0xFFF59E0B);

String _levelDisplayName(AlertLevel level) {
  final name = level.toString().split('.').last;
  if (name.isEmpty) return name;
  return name[0].toUpperCase() + name.substring(1);
}

/// Admin > Settings > Auto Response.
/// Reads/writes the `app_settings` row with key = 'auto_dispatch'. Each
/// AlertLevel gets its own row: what to do automatically (nothing / send to
/// Purok Leader / dispatch Task Force) and how many minutes an incident of
/// that level may sit unhandled before it fires.
class AutoResponseSection extends StatefulWidget {
  const AutoResponseSection({super.key});

  @override
  State<AutoResponseSection> createState() => _AutoResponseSectionState();
}

class _AutoResponseSectionState extends State<AutoResponseSection> {
  final _supabase = Supabase.instance.client;

  AutoDispatchConfig _saved = AutoDispatchConfig.defaults;
  late AutoDispatchConfig _draft = _saved;

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cfg = await AutoDispatchConfig.load(_supabase);
      _saved = cfg;
      _draft = cfg;
    } catch (_) {
      // keep defaults — save() will create the row
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _dirty => _draft.toValue().toString() != _saved.toValue().toString();

  void _setRule(AlertLevel level, LevelRule rule) {
    setState(() => _draft = _draft.copyWithRule(level, rule));
  }

  void _setAction(AlertLevel level, DispatchAction action) {
    final current = _draft.ruleFor(level);
    final now = DateTime.now();
    // Stamp "since" the moment a level goes from OFF to ON, so switching it
    // on never fires on old backlog incidents. Switching between the two
    // active actions (Purok Leader <-> Task Force) keeps the original since.
    final since = action == DispatchAction.none
        ? null
        : (current.isOn ? (current.since ?? now) : now);
    _setRule(level, current.copyWith(action: action, since: since, clearSince: action == DispatchAction.none));
  }

  void _setMinutes(AlertLevel level, int minutes) {
    final current = _draft.ruleFor(level);
    _setRule(level, current.copyWith(afterMinutes: minutes));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _supabase.from('app_settings').upsert({
        'key': AutoDispatchConfig.settingsKey,
        'value': _draft.toValue(),
        'updated_by': _supabase.auth.currentUser?.id,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (!mounted) return;
      setState(() => _saved = _draft);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Auto response settings saved')),
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

  // ---------------------------------------------------------------- UI

  Widget _actionChip({
    required String label,
    required IconData icon,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color.withOpacity(0.14) : AppColors.bg(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? color : AppColors.border(context),
              width: selected ? 1.3 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: selected ? color : AppColors.textMuted(context)),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? color : AppColors.textMuted(context),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepperButton(BuildContext context, IconData icon, VoidCallback? onTap) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 15,
        splashRadius: 15,
        onPressed: onTap,
        icon: Icon(icon,
            color: onTap == null
                ? AppColors.textMuted(context).withOpacity(0.4)
                : AppColors.textMain(context)),
      ),
    );
  }

  Widget _minutesStepper({
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepperButton(context, Icons.remove,
              value > AutoDispatchConfig.minMinutes ? () => onChanged(value - 1) : null),
          SizedBox(
            width: 64,
            child: Text('$value min',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
          _stepperButton(context, Icons.add,
              value < AutoDispatchConfig.maxMinutes ? () => onChanged(value + 1) : null),
        ],
      ),
    );
  }

  Widget _levelCard(AlertLevel level) {
    final rule = _draft.ruleFor(level);
    final label = _levelDisplayName(level);
    final levelColor = level.color;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: rule.isOn ? levelColor.withOpacity(0.5) : AppColors.border(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: levelColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$label alerts',
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700)),
              ),
              if (rule.isOn) _minutesStepper(
                value: rule.afterMinutes,
                onChanged: (m) => _setMinutes(level, m),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _actionChip(
                label: 'Do nothing',
                icon: Icons.pause_circle_outline,
                color: AppColors.textMuted(context),
                selected: rule.action == DispatchAction.none,
                onTap: () => _setAction(level, DispatchAction.none),
              ),
              const SizedBox(width: 8),
              _actionChip(
                label: 'Purok Leader',
                icon: Icons.person_pin_circle_outlined,
                color: AppColors.accentBlue,
                selected: rule.action == DispatchAction.purokLeader,
                onTap: () => _setAction(level, DispatchAction.purokLeader),
              ),
              const SizedBox(width: 8),
              _actionChip(
                label: 'Task Force',
                icon: Icons.groups_outlined,
                color: AppColors.accentRed,
                selected: rule.action == DispatchAction.taskForce,
                onTap: () => _setAction(level, DispatchAction.taskForce),
              ),
            ],
          ),
          if (rule.isOn) ...[
            const SizedBox(height: 8),
            Text(
              rule.action == DispatchAction.taskForce
                  ? 'A $label incident left unhandled for ${rule.afterMinutes} min '
                      'auto-dispatches the nearest available Task Force team.'
                  : 'A $label incident left unhandled for ${rule.afterMinutes} min '
                      'auto-sends a request to the nearest Purok Leader.',
              style: TextStyle(
                  color: AppColors.textMuted(context), fontSize: 11, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stepper({
    required String label,
    required String hint,
    required int value,
    required int min,
    required int max,
    required String unit,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(hint,
                  style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 11.5,
                      height: 1.35)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.bg(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _stepperButton(context, Icons.remove,
                  value > min ? () => onChanged(value - 1) : null),
              SizedBox(
                width: 72,
                child: Text('$value $unit',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
              ),
              _stepperButton(context, Icons.add,
                  value < max ? () => onChanged(value + 1) : null),
            ],
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
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Auto Response',
              style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'For each alert level, decide what happens automatically if an '
            'incident sits unhandled ("Needs action") for too long — and for '
            'how many minutes it should wait first.',
            style: TextStyle(
                color: AppColors.textMuted(context), fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 18),

          for (final level in AlertLevel.values) ...[
            _levelCard(level),
            const SizedBox(height: 12),
          ],

          const SizedBox(height: 4),

          // --- Team size (used by manual + auto dispatch) ---
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _amber.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.group_add_outlined, color: _amber, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Task Force team size',
                              style: TextStyle(
                                  color: AppColors.textMain(context),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text(
                            'How many responders go out on one dispatch. '
                            'Used by auto-dispatch and pre-selected in the '
                            'manual dispatch picker.',
                            style: TextStyle(
                                color: AppColors.textMuted(context),
                                fontSize: 12,
                                height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Divider(color: AppColors.border(context), height: 1, thickness: 1),
                const SizedBox(height: 14),
                _stepper(
                  label: 'Responders per dispatch',
                  hint: 'Only members not already on duty are counted.',
                  value: _draft.taskForceTeamSize,
                  min: AutoDispatchConfig.minTeamSize,
                  max: AutoDispatchConfig.maxTeamSize,
                  unit: _draft.taskForceTeamSize == 1 ? 'member' : 'members',
                  onChanged: (v) =>
                      setState(() => _draft = _draft.copyWithTeamSize(v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 14, color: AppColors.textMuted(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Rules only apply to incidents that arrive after they are '
                  'switched on for that level. Auto-response runs while the '
                  'Incidents screen is open in the app.',
                  style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 11.5,
                      height: 1.4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          Row(
            children: [
              SizedBox(
                width: 160,
                child: ElevatedButton(
                  onPressed: (_saving || !_dirty) ? null : _save,
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
              if (_dirty) ...[
                const SizedBox(width: 12),
                Text('Unsaved changes',
                    style: TextStyle(
                        color: AppColors.textMuted(context), fontSize: 11.5)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}