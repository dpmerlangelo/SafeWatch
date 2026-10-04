import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../utils/activity_logger.dart';
import '../../constants/barangay_boundary.dart';
import '../../widgets/app_toast.dart';
import '../../constants/app_colors.dart';
import '../../services/pa_audio_service.dart';

/// IP Public Address (PA) speakers screen. Mirrors CctvScreen:
///   • header (title + Check status / Add actions)
///   • clickable stat cards that double as status filters
///   • toolbar: search, segmented status filter, grid/list toggle, PDF export
///   • card grid or list rows with a pager
///   • centered modal for view / add / edit, with the confirm dialog stacked
///     above it and an inline map picker swapped in *inside* the modal
///
/// Statuses are Online / Offline only. They are set by a client-side health
/// monitor (TCP probe of ip:port every 45 s) and on save.
///
/// Supabase table `pa_speakers` (see pa_speakers.sql):
///   id, name, zone, location, ip_address, port, protocol, sip_extension,
///   username, password, volume, status, latitude, longitude, created_at
class SpeakerScreen extends StatefulWidget {
  final bool isActive;

  const SpeakerScreen({super.key, this.isActive = true});

  @override
  State<SpeakerScreen> createState() => _SpeakerScreenState();
}

// ---------------------------------------------------------------------------
// Shared helpers / small widgets (private to this file)
// ---------------------------------------------------------------------------

const List<String> _kStatusOptions = ['Online', 'Offline'];
const List<String> _kProtocols = ['SIP', 'HTTP API', 'RTP Multicast'];
const Map<String, String> _kDefaultPorts = {
  'SIP': '5060',
  'HTTP API': '80',
  'RTP Multicast': '5004',
};

Color _statusColor(BuildContext context, String status) {
  switch (status.toUpperCase()) {
    case 'ONLINE':
      return AppColors.accentGreen;
    case 'OFFLINE':
      return AppColors.accentRed;
    default:
      return AppColors.textMuted(context);
  }
}

IconData _statusIcon(String status) {
  switch (status.toUpperCase()) {
    case 'ONLINE':
      return Icons.check_circle_outline;
    case 'OFFLINE':
      return Icons.volume_off_outlined;
    default:
      return Icons.campaign_outlined;
  }
}

/// Pointer cursor on hover. `enabled: false` keeps the arrow cursor.
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

class _AnnouncementAudioBar extends StatelessWidget {
  const _AnnouncementAudioBar();

  @override
  Widget build(BuildContext context) {
    final svc = PaAudioService.instance;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final has = svc.hasFile;
        final color = has ? AppColors.accentGreen : AppColors.textMuted(context);

        Widget outlined(IconData icon, String label, VoidCallback onTap,
            {Color? fg}) {
          final c = fg ?? AppColors.accentBlue;
          return _HoverPop(
            child: OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 15),
              label: Text(label),
              style: OutlinedButton.styleFrom(
                foregroundColor: c,
                side: BorderSide(color: c.withOpacity(0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3),
              ),
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.audiotrack_outlined, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fire announcement audio',
                      style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      has
                          ? svc.fileName
                          : 'No MP3 selected — plays on the default audio output when a fire incident is dispatched.',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (has) ...[
                if (svc.isPlaying)
                  outlined(Icons.stop_rounded, 'STOP', () => svc.stop(),
                      fg: AppColors.accentRed)
                else
                  outlined(Icons.play_arrow_rounded, 'TEST', () async {
                    final ok = await svc.play();
                    if (!ok && context.mounted) {
                      AppToast.error(context,
                          'Could not play the file. Was it moved or deleted?');
                    }
                  }),
                const SizedBox(width: 8),
                outlined(Icons.close, 'CLEAR', () => svc.clear(),
                    fg: AppColors.textMuted(context)),
                const SizedBox(width: 8),
              ],
              outlined(
                Icons.folder_open_outlined,
                has ? 'CHANGE' : 'PICK MP3',
                () async {
                  final ok = await svc.pick();
                  if (ok && context.mounted) {
                    AppToast.success(context, 'Announcement audio set');
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Tinted pill with a colored dot — used for statuses everywhere.
class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, status);
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
          Flexible(
            child: Text(
              status.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textMain(context),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small outlined tag (used for the protocol).
class _TagChip extends StatelessWidget {
  final String text;
  const _TagChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: AppColors.textMuted(context),
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Circular speaker avatar with a soft status-colored ring.
class _SpeakerAvatar extends StatelessWidget {
  final String status;
  final double size;
  const _SpeakerAvatar({required this.status, required this.size});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, status);
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
          child: Icon(Icons.campaign_outlined, color: color, size: size * 0.46),
        ),
      ),
    );
  }
}

/// Small square icon button used in rows and cards.
class _MiniIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;
  const _MiniIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  State<_MiniIconButton> createState() => _MiniIconButtonState();
}

class _MiniIconButtonState extends State<_MiniIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color ?? AppColors.textMuted(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: base.withOpacity(_hover ? 0.14 : 0),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.icon, size: 16, color: base),
          ),
        ),
      ),
    );
  }
}

/// Tags a modal field so `_detailRows` knows whether it spans the full row.
class _DetailFieldMarker extends StatelessWidget {
  final Widget child;
  final bool full;
  const _DetailFieldMarker({required this.child, this.full = false});

  @override
  Widget build(BuildContext context) => child;
}

// ---------------------------------------------------------------------------
// Dashboard stat card
// ---------------------------------------------------------------------------

class _StatCard extends StatefulWidget {
  final String label;
  final int value;
  final String caption;
  final IconData icon;
  final Color color;
  final double share;
  final bool selected;
  final VoidCallback onTap;

  const _StatCard({
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
  State<_StatCard> createState() => _StatCardState();
}

class _StatCardState extends State<_StatCard> {
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
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _hover ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 160),
          builder: (context, t, child) => Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: widget.selected
                    ? c
                    : Color.lerp(
                        AppColors.border(context), c.withOpacity(0.5), t)!,
                width: widget.selected ? 1.6 : 1,
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

// ---------------------------------------------------------------------------
// Toolbar bits
// ---------------------------------------------------------------------------

class _StatusFilterSegmented extends StatelessWidget {
  final String? selected; // null = All
  final ValueChanged<String?> onChanged;
  const _StatusFilterSegmented({required this.selected, required this.onChanged});

  Widget _segment(BuildContext context, String label, String? value) {
    final isSelected = selected == value;
    final color =
        value == null ? AppColors.accentBlue : _statusColor(context, value);
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
              color: isSelected ? color.withOpacity(0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected
                    ? AppColors.textMain(context)
                    : AppColors.textMuted(context),
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
          _segment(context, 'All', null),
          for (final s in _kStatusOptions) _segment(context, s, s),
        ],
      ),
    );
  }
}

class _ViewToggle extends StatelessWidget {
  final bool grid;
  final ValueChanged<bool> onChanged;
  const _ViewToggle({required this.grid, required this.onChanged});

  Widget _segment(BuildContext context, IconData icon, bool isGrid, String tip) {
    final selected = grid == isGrid;
    return Tooltip(
      message: tip,
      child: GestureDetector(
        onTap: () => onChanged(isGrid),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 36,
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withOpacity(selected ? 0.16 : 0),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon,
                size: 17,
                color: selected
                    ? AppColors.accentBlue
                    : AppColors.textMuted(context)),
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
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(context, Icons.grid_view_rounded, true, 'Card view'),
          _segment(context, Icons.view_list_rounded, false, 'List view'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grid card
// ---------------------------------------------------------------------------

class _SpeakerCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SpeakerCard({
    required this.data,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_SpeakerCard> createState() => _SpeakerCardState();
}

class _SpeakerCardState extends State<_SpeakerCard> {
  bool _hover = false;

  Widget _line(BuildContext context, IconData icon, String text,
      {bool mono = false}) {
    return Row(
      children: [
        Icon(icon, size: 13, color: AppColors.textMuted(context)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 11.5,
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final name = (d['name'] ?? 'Unnamed').toString();
    final zone = (d['zone'] ?? 'N/A').toString();
    final ip = (d['ip_address'] ?? 'N/A').toString();
    final port = (d['port'] ?? '').toString();
    final ipDisplay = port.isEmpty ? ip : '$ip:$port';
    final protocol = (d['protocol'] ?? '').toString();
    final volume = d['volume'];
    final status = (d['status'] ?? 'Offline').toString();
    final color = _statusColor(context, status);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _hover ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 160),
          builder: (context, t, child) => Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Color.lerp(
                    AppColors.border(context), color.withOpacity(0.6), t)!,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.12 * t),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: child,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              SizedBox(
                height: 74,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.topCenter,
                  children: [
                    Container(
                      height: 46,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [color.withOpacity(0.28), color.withOpacity(0.05)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 16,
                      child: _SpeakerAvatar(status: status, size: 60),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                child: Column(
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _StatusChip(status: status),
                    const SizedBox(height: 12),
                    _line(context, Icons.grid_view_outlined, zone),
                    const SizedBox(height: 5),
                    _line(context, Icons.lan_outlined, ipDisplay, mono: true),
                    const SizedBox(height: 5),
                    _line(
                      context,
                      Icons.volume_up_outlined,
                      '${protocol.isEmpty ? '—' : protocol}'
                      '${volume is num ? '  •  Vol ${volume.toInt()}%' : ''}',
                    ),
                  ],
                ),
              ),
              const Expanded(child: SizedBox()),
              Divider(height: 1, color: AppColors.border(context)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'View details',
                        style: TextStyle(
                          color: AppColors.accentBlue,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _MiniIconButton(
                        icon: Icons.edit_outlined,
                        tooltip: 'Edit',
                        onTap: widget.onEdit),
                    _MiniIconButton(
                      icon: Icons.delete_outline,
                      tooltip: 'Remove',
                      onTap: widget.onDelete,
                      color: AppColors.accentRed,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// List row
// ---------------------------------------------------------------------------

class _SpeakerRowTile extends StatefulWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SpeakerRowTile({
    required this.data,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_SpeakerRowTile> createState() => _SpeakerRowTileState();
}

class _SpeakerRowTileState extends State<_SpeakerRowTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final name = (d['name'] ?? 'Unnamed').toString();
    final zone = (d['zone'] ?? 'N/A').toString();
    final ip = (d['ip_address'] ?? 'N/A').toString();
    final port = (d['port'] ?? '').toString();
    final ipDisplay = port.isEmpty ? ip : '$ip:$port';
    final protocol = (d['protocol'] ?? '').toString();
    final status = (d['status'] ?? 'Offline').toString();
    final hasPin = d['latitude'] is num && d['longitude'] is num;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          color: AppColors.sunken(context).withOpacity(_hover ? 1 : 0),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    _SpeakerAvatar(status: status, size: 38),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textMain(context),
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            zone,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppColors.textMuted(context),
                                fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  ipDisplay,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: protocol.isEmpty
                      ? Text('—',
                          style: TextStyle(color: AppColors.textMuted(context)))
                      : _TagChip(text: protocol),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _StatusChip(status: status),
                ),
              ),
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    Icon(
                      hasPin ? Icons.location_on : Icons.location_off_outlined,
                      size: 14,
                      color: hasPin
                          ? AppColors.accentBlue
                          : AppColors.textMuted(context),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      hasPin ? 'Pinned' : 'No pin',
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 96,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _MiniIconButton(
                        icon: Icons.visibility_outlined,
                        tooltip: 'View',
                        onTap: widget.onTap),
                    _MiniIconButton(
                        icon: Icons.edit_outlined,
                        tooltip: 'Edit',
                        onTap: widget.onEdit),
                    _MiniIconButton(
                      icon: Icons.delete_outline,
                      tooltip: 'Remove',
                      onTap: widget.onDelete,
                      color: AppColors.accentRed,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class _SpeakerScreenState extends State<SpeakerScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  late final Stream<List<Map<String, dynamic>>> _speakerStream;
  final SupabaseClient _supabase = Supabase.instance.client;

  Map<String, dynamic>? _selectedSpeaker;
  String _searchQuery = '';
  String? _statusFilter; // null = all statuses
  bool _gridView = false;

  // null (closed), 'view', 'add', 'edit'
  String? _rightPanelMode;
  String _lastMode = 'view';

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // Centered modal, hosted on the root Overlay.
  OverlayEntry? _modalEntry;
  late final AnimationController _modalAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  // Confirmation dialog, inserted above the modal.
  OverlayEntry? _confirmOverlayEntry;
  late final AnimationController _confirmAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  final _formKey = GlobalKey<FormState>();

  // Controllers for Add / Edit
  final _nameController = TextEditingController();
  final _zoneController = TextEditingController();
  final _locationController = TextEditingController();
  final _ipAddressController = TextEditingController();
  final _portController = TextEditingController(text: '80');
  final _extensionController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  String _protocol = 'HTTP API';
  double _volume = 70;
  bool _obscurePassword = true;

  double? _selectedLat;
  double? _selectedLng;

  // Snapshot of the values when Edit opened — for dirty checking.
  String _originalName = '';
  String _originalZone = '';
  String _originalLocation = '';
  String _originalIpAddress = '';
  String _originalPort = '';
  String _originalExtension = '';
  String _originalUsername = '';
  String _originalPassword = '';
  String _originalProtocol = 'HTTP API';
  double _originalVolume = 70;
  double? _originalLat;
  double? _originalLng;

  // Inline map picker state (swaps in place of the form inside the modal).
  bool _isPickingLocationInline = false;
  LatLng? _inlinePickedPoint;

  bool _isSaving = false;
  bool _isDeleting = false;
  bool _isTesting = false; // "Test connection" in the form
  bool _exporting = false; // PDF export in progress

  bool get _isProcessing => _isSaving || _isDeleting;

  int _currentPage = 0;
  static const int _speakersPerPage = 50;

  // Derived-data cache (recomputed only when stream data / filters change).
  List<Map<String, dynamic>>? _srcData;
  List<Map<String, dynamic>> _all = const [];
  Map<String, int> _counts = const {};
  String? _filterKey;
  List<Map<String, dynamic>> _filtered = const [];

  // --- HEALTH MONITOR ---
  Timer? _healthCheckTimer;
  bool _healthCheckRunning = false;
  bool _checkingNow = false; // manual "Check status" button
  static const Duration _healthCheckInterval = Duration(seconds: 45);

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant SpeakerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      _closeRightPanel();
    }
  }

  void _closeRightPanel() {
    if (_rightPanelMode == null) return;
    setState(() {
      _rightPanelMode = null;
      _isPickingLocationInline = false;
      _inlinePickedPoint = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _speakerStream = _supabase
        .from('pa_speakers')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false);
    _startHealthMonitor();
    _searchFocusNode.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _stopHealthMonitor();
    _modalEntry?.remove();
    _modalAnim.dispose();
    _confirmOverlayEntry?.remove();
    _confirmAnimController.dispose();
    _nameController.dispose();
    _zoneController.dispose();
    _locationController.dispose();
    _ipAddressController.dispose();
    _portController.dispose();
    _extensionController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _clearForm() {
    _nameController.clear();
    _zoneController.clear();
    _locationController.clear();
    _ipAddressController.clear();
    _extensionController.clear();
    _usernameController.clear();
    _passwordController.clear();
    _protocol = 'HTTP API';
    _portController.text = _kDefaultPorts[_protocol]!;
    _volume = 70;
    _obscurePassword = true;
    _selectedLat = null;
    _selectedLng = null;
    _isPickingLocationInline = false;
    _inlinePickedPoint = null;
  }

  void _populateEditForm(Map<String, dynamic> s) {
    _nameController.text = (s['name'] ?? '').toString();
    _zoneController.text = (s['zone'] ?? '').toString();
    _locationController.text = (s['location'] ?? '').toString();
    _ipAddressController.text = (s['ip_address'] ?? '').toString();
    _portController.text = (s['port'] ?? '80').toString();
    _extensionController.text = (s['sip_extension'] ?? '').toString();
    _usernameController.text = (s['username'] ?? '').toString();
    _passwordController.text = (s['password'] ?? '').toString();
    final proto = (s['protocol'] ?? 'HTTP API').toString();
    _protocol = _kProtocols.contains(proto) ? proto : 'HTTP API';
    final vol = s['volume'];
    _volume = (vol is num) ? vol.toDouble().clamp(0, 100) : 70;
    _obscurePassword = true;
    final lat = s['latitude'];
    final lng = s['longitude'];
    _selectedLat = (lat is num) ? lat.toDouble() : null;
    _selectedLng = (lng is num) ? lng.toDouble() : null;
    _isPickingLocationInline = false;
    _inlinePickedPoint = null;

    _originalName = _nameController.text.trim();
    _originalZone = _zoneController.text.trim();
    _originalLocation = _locationController.text.trim();
    _originalIpAddress = _ipAddressController.text.trim();
    _originalPort = _portController.text.trim();
    _originalExtension = _extensionController.text.trim();
    _originalUsername = _usernameController.text.trim();
    _originalPassword = _passwordController.text;
    _originalProtocol = _protocol;
    _originalVolume = _volume;
    _originalLat = _selectedLat;
    _originalLng = _selectedLng;
  }

  bool _hasEditChanges() {
    if (_nameController.text.trim() != _originalName) return true;
    if (_zoneController.text.trim() != _originalZone) return true;
    if (_locationController.text.trim() != _originalLocation) return true;
    if (_ipAddressController.text.trim() != _originalIpAddress) return true;
    if (_portController.text.trim() != _originalPort) return true;
    if (_extensionController.text.trim() != _originalExtension) return true;
    if (_usernameController.text.trim() != _originalUsername) return true;
    if (_passwordController.text != _originalPassword) return true;
    if (_protocol != _originalProtocol) return true;
    if (_volume.round() != _originalVolume.round()) return true;
    if (_selectedLat != _originalLat) return true;
    if (_selectedLng != _originalLng) return true;
    return false;
  }

  bool _canCreate() {
    if (_nameController.text.trim().isEmpty) return false;
    if (_zoneController.text.trim().isEmpty) return false;
    if (_locationController.text.trim().isEmpty) return false;
    if (_ipAddressController.text.trim().isEmpty) return false;
    if (_portController.text.trim().isEmpty) return false;
    return true;
  }

  void _onProtocolChanged(String proto) {
    setState(() {
      // Swap the port only if it's still one of the untouched defaults.
      final current = _portController.text.trim();
      if (current.isEmpty || _kDefaultPorts.containsValue(current)) {
        _portController.text = _kDefaultPorts[proto]!;
      }
      _protocol = proto;
    });
  }

  String _formatTimestamp(dynamic ts) {
    if (ts == null) return 'N/A';
    DateTime? dateTime;
    if (ts is String) {
      dateTime = DateTime.tryParse(ts);
    } else if (ts is DateTime) {
      dateTime = ts;
    }
    if (dateTime == null) return 'N/A';
    return DateFormat('MMM d, yyyy • h:mm a').format(dateTime.toLocal());
  }

  String _formatPin(double? lat, double? lng) {
    if (lat == null || lng == null) return 'Not set';
    return '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
  }

  Future<bool> _isSpeakerReachable(String ip, int port) async {
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _copyText(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    AppToast.success(context, '$label copied');
  }

  /// "Test connection" button in the form.
  Future<void> _testConnection() async {
    final ip = _ipAddressController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (_ipAddressValidator(ip) != null || port == null) {
      AppToast.error(context, 'Enter a valid IP address and port first.');
      return;
    }
    setState(() => _isTesting = true);
    final ok = await _isSpeakerReachable(ip, port);
    if (!mounted) return;
    setState(() => _isTesting = false);
    if (ok) {
      AppToast.success(context, '$ip:$port is reachable');
    } else {
      AppToast.error(context, 'Could not reach $ip:$port');
    }
  }

  // -----------------------------------------------------------------------
  // PDF EXPORT
  // -----------------------------------------------------------------------

  Future<({String name, String role})> _currentExporter() async {
    final user = _supabase.auth.currentUser;
    if (user == null) return (name: 'Unknown user', role: '');
    try {
      final row = await _supabase
          .from('profiles')
          .select('first_name, last_name, role')
          .eq('id', user.id)
          .maybeSingle();
      if (row != null) {
        final first = (row['first_name'] ?? '').toString().trim();
        final last = (row['last_name'] ?? '').toString().trim();
        final full = '$first $last'.trim();
        return (
          name: full.isEmpty ? (user.email ?? 'Unknown user') : full,
          role: (row['role'] ?? '').toString().trim(),
        );
      }
    } catch (_) {}
    return (name: user.email ?? 'Unknown user', role: '');
  }

  String _titleCase(String s) {
    return s
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  Future<void> _exportPdf(List<Map<String, dynamic>> rows) async {
    if (_exporting || rows.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final me = await _currentExporter();
      final bytes = await _buildSpeakersPdf(rows,
          exportedBy: me.name, exportedRole: me.role);
      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await FileSaver.instance.saveFile(
        name: 'safewatch_speakers_$stamp',
        bytes: bytes,
        ext: 'pdf',
        mimeType: MimeType.pdf,
      );
      if (!mounted) return;
      AppToast.success(context,
          'Downloaded ${rows.length} speaker${rows.length == 1 ? '' : 's'} as PDF');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Could not export PDF: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Built-in PDF fonts only cover Latin-1.
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

  /// Credentials (username / password) are deliberately left out.
  Future<Uint8List> _buildSpeakersPdf(
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

    int countStatus(String s) => rows
        .where((r) =>
            (r['status'] ?? '').toString().toUpperCase() == s.toUpperCase())
        .length;
    final online = countStatus('Online');
    final offline = countStatus('Offline');
    final pinned =
        rows.where((r) => r['latitude'] is num && r['longitude'] is num).length;

    final filters = <String>[
      if (_statusFilter != null) 'Status: $_statusFilter',
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
                      fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: ink)),
            ],
          ),
        );

    final data = <List<String>>[
      for (var i = 0; i < rows.length; i++)
        () {
          final s = rows[i];
          final ip = (s['ip_address'] ?? '-').toString();
          final port = (s['port'] ?? '').toString();
          final status = (s['status'] ?? '-').toString();
          final vol = s['volume'];
          return <String>[
            '${i + 1}',
            t((s['name'] ?? 'Unnamed').toString()),
            t((s['zone'] ?? '-').toString()),
            t((s['location'] ?? '-').toString()),
            port.isEmpty ? ip : '$ip:$port',
            t((s['protocol'] ?? '-').toString()),
            vol is num ? '${vol.toInt()}%' : '-',
            status == '-' ? '-' : _titleCase(status),
          ];
        }(),
    ];

    final doc =
        pw.Document(title: 'SafeWatch PA Speakers', author: 'SafeWatch');

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(t('SafeWatch  |  PA Speakers  |  Exported by $exportedBy'),
                style: const pw.TextStyle(fontSize: 7.5, color: muted)),
            pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 7.5, color: muted)),
          ],
        ),
        build: (ctx) => [
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
                    pw.Text('PA Speakers',
                        style: pw.TextStyle(
                            fontSize: 20,
                            fontWeight: pw.FontWeight.bold,
                            color: ink)),
                    pw.SizedBox(height: 2),
                    pw.Text('Speaker status, zones and network details',
                        style: const pw.TextStyle(fontSize: 8.5, color: muted)),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 14),
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
                      info('Total speakers', '${rows.length}'),
                      info('Online / Offline', '$online / $offline'),
                      info('With map pin', '$pinned'),
                    ],
                  ),
                ),
                pw.Expanded(
                  flex: 5,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      info('Filters applied',
                          filters.isEmpty ? 'None (all speakers)' : filters.join(', ')),
                    ],
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: const [
              '#',
              'Speaker',
              'Zone',
              'Location',
              'IP Address',
              'Protocol',
              'Vol',
              'Status',
            ],
            data: data,
            headerStyle: pw.TextStyle(
                fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: pw.BoxDecoration(color: accent),
            cellStyle: const pw.TextStyle(fontSize: 8, color: ink),
            border: pw.TableBorder.all(color: line, width: 0.6),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            cellAlignment: pw.Alignment.centerLeft,
            headerAlignment: pw.Alignment.centerLeft,
            cellAlignments: {0: pw.Alignment.center},
            headerAlignments: {0: pw.Alignment.center},
            columnWidths: {
              0: const pw.FlexColumnWidth(0.4),
              1: const pw.FlexColumnWidth(1.5),
              2: const pw.FlexColumnWidth(1.2),
              3: const pw.FlexColumnWidth(1.5),
              4: const pw.FlexColumnWidth(1.4),
              5: const pw.FlexColumnWidth(1.0),
              6: const pw.FlexColumnWidth(0.6),
              7: const pw.FlexColumnWidth(0.8),
            },
          ),
        ],
      ),
    );

    return doc.save();
  }

  // -----------------------------------------------------------------------
  // HEALTH MONITOR
  // -----------------------------------------------------------------------

  void _startHealthMonitor() {
    _healthCheckTimer?.cancel();
    unawaited(_runHealthCheckPass());
    _healthCheckTimer = Timer.periodic(
      _healthCheckInterval,
      (_) => unawaited(_runHealthCheckPass()),
    );
  }

  void _stopHealthMonitor() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  /// One pass over every saved speaker: TCP probe of ip:port. Writes only
  /// when the status actually changed (and logs it). Any legacy
  /// 'Maintenance' rows are normalized to Online/Offline here.
  Future<void> _runHealthCheckPass() async {
    if (!mounted || _healthCheckRunning) return;
    _healthCheckRunning = true;

    try {
      List<Map<String, dynamic>> speakers;
      try {
        speakers = await _supabase.from('pa_speakers').select();
      } catch (e) {
        debugPrint('Speaker health check: failed to load speakers — $e');
        return;
      }
      if (speakers.isEmpty) return;

      // Probe in parallel so one dead host doesn't stall the whole pass.
      final results = await Future.wait(speakers.map((row) async {
        final ip = (row['ip_address'] as String?)?.trim() ?? '';
        final port = int.tryParse((row['port'] ?? '').toString());
        if (ip.isEmpty || port == null) return false;
        return _isSpeakerReachable(ip, port);
      }));

      for (var i = 0; i < speakers.length; i++) {
        if (!mounted) return;
        final row = speakers[i];
        final id = row['id'];
        if (id == null) continue;

        final newStatus = results[i] ? 'Online' : 'Offline';
        final currentStatus = (row['status'] as String?) ?? '';
        if (newStatus == currentStatus) continue;

        try {
          await _supabase
              .from('pa_speakers')
              .update({'status': newStatus}).eq('id', id);

          final speakerName = (row['name'] as String?)?.trim();
          final label = (speakerName != null && speakerName.isNotEmpty)
              ? speakerName
              : 'Speaker $id';
          await ActivityLogger.logSystem(
            action: 'SPEAKER_STATUS_CHANGE',
            details: 'Speaker "$label" was checked automatically by the health monitor',
            systemLabel: 'System (Health Monitor)',
            changes: [
              LogChange(
                field: 'Status',
                from: currentStatus.isEmpty ? 'Unknown' : currentStatus,
                to: newStatus,
              ),
            ],
            metadata: {'speaker_id': id, 'matched_by': 'TCP probe'},
          );
        } catch (e) {
          debugPrint('Speaker health check: failed to update $id — $e');
        }
      }
    } finally {
      _healthCheckRunning = false;
    }
  }

  Future<void> _checkNow() async {
    if (_checkingNow) return;
    setState(() => _checkingNow = true);
    await _runHealthCheckPass();
    if (!mounted) return;
    setState(() => _checkingNow = false);
    AppToast.success(context, 'Status check complete');
  }

  // -----------------------------------------------------------------------
  // BUILD
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncModalOverlay());

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _speakerStream,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData;
        final error = snapshot.error;

        final data = snapshot.data ?? const <Map<String, dynamic>>[];
        if (!identical(data, _srcData)) {
          _srcData = data;
          _filterKey = null;
          _all = data.map((r) => Map<String, dynamic>.from(r)).toList();

          final counts = <String, int>{
            for (final s in _kStatusOptions) s.toUpperCase(): 0,
          };
          for (final s in _all) {
            final key = (s['status'] ?? '').toString().toUpperCase();
            if (counts.containsKey(key)) counts[key] = counts[key]! + 1;
          }
          _counts = counts;
        }
        final all = _all;
        final counts = _counts;

        final key = '$_searchQuery|$_statusFilter';
        if (key != _filterKey) {
          _filterKey = key;
          _filtered = all.where((row) {
            if (_statusFilter != null &&
                (row['status'] ?? '').toString().toUpperCase() !=
                    _statusFilter!.toUpperCase()) {
              return false;
            }
            if (_searchQuery.isEmpty) return true;
            final haystack = [
              row['name'],
              row['zone'],
              row['location'],
              row['ip_address'],
              row['protocol'],
            ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
            return haystack.contains(_searchQuery);
          }).toList();
        }
        final filtered = _filtered;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 18),
            _buildStatCards(all.length, counts),
            const SizedBox(height: 18),
            const _AnnouncementAudioBar(), 
            const SizedBox(height: 18),
            _buildToolbar(filtered),
            const SizedBox(height: 14),
            Expanded(child: _buildContent(loading, error, all, filtered)),
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
                'PA Speakers',
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Monitor IP public address speakers, zones and connections',
                style: TextStyle(
                    color: AppColors.textMuted(context), fontSize: 13),
              ),
            ],
          ),
        ),
        _HoverPop(
          enabled: !_checkingNow,
          child: SizedBox(
            height: 40,
            child: OutlinedButton.icon(
              onPressed: _checkingNow ? null : _checkNow,
              icon: _checkingNow
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          color: AppColors.textMuted(context), strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 17),
              label: Text(
                _checkingNow ? 'Checking...' : 'Check Status',
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
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
        const SizedBox(width: 10),
        _HoverPop(
          child: SizedBox(
            height: 40,
            child: ElevatedButton.icon(
              onPressed: () {
                _clearForm();
                setState(() {
                  _selectedSpeaker = null;
                  _rightPanelMode = 'add';
                });
              },
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add Speaker',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 18),
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

  Widget _buildStatCards(int total, Map<String, int> counts) {
    final cards = <Widget>[
      _StatCard(
        label: 'Total speakers',
        value: total,
        caption: 'All statuses',
        icon: Icons.campaign_outlined,
        color: AppColors.accentBlue,
        share: total == 0 ? 0 : 1,
        selected: _statusFilter == null,
        onTap: () => setState(() {
          _statusFilter = null;
          _currentPage = 0;
        }),
      ),
      for (final status in _kStatusOptions)
        _StatCard(
          label: status,
          value: counts[status.toUpperCase()] ?? 0,
          caption: total == 0
              ? '0%'
              : '${(((counts[status.toUpperCase()] ?? 0) / total) * 100).round()}%',
          icon: _statusIcon(status),
          color: _statusColor(context, status),
          share: total == 0 ? 0 : (counts[status.toUpperCase()] ?? 0) / total,
          selected: _statusFilter == status,
          onTap: () => setState(() {
            _statusFilter = _statusFilter == status ? null : status;
            _currentPage = 0;
          }),
        ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        const gap = 14.0;
        final perRow = c.maxWidth >= 520 ? 3 : 1;
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final card in cards) SizedBox(width: w, child: card)],
        );
      },
    );
  }

  // --- TOOLBAR ---

  Widget _buildToolbar(List<Map<String, dynamic>> filtered) {
    return Row(
      children: [
        SizedBox(
          width: 280,
          height: 38,
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
            onChanged: (val) => setState(() {
              _searchQuery = val.trim().toLowerCase();
              _currentPage = 0;
            }),
            decoration: InputDecoration(
              hintText: 'Search name, zone, IP…',
              hintStyle:
                  TextStyle(color: AppColors.textMuted(context), fontSize: 13),
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
                borderSide:
                    const BorderSide(color: AppColors.accentBlue, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _StatusFilterSegmented(
            selected: _statusFilter,
            onChanged: (status) => setState(() {
              _statusFilter = status;
              _currentPage = 0;
            }),
          ),
        ),
        const SizedBox(width: 12),
        _ViewToggle(
          grid: _gridView,
          onChanged: (grid) => setState(() => _gridView = grid),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: filtered.isEmpty
              ? 'No speakers to export'
              : 'Export ${filtered.length} speaker${filtered.length == 1 ? '' : 's'} as PDF',
          child: _HoverPop(
            enabled: !_exporting && filtered.isNotEmpty,
            child: SizedBox(
              height: 38,
              width: 38,
              child: OutlinedButton(
                onPressed: (_exporting || filtered.isEmpty)
                    ? null
                    : () => _exportPdf(filtered),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textMuted(context),
                  backgroundColor: AppColors.card(context),
                  side: BorderSide(color: AppColors.border(context)),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _exporting
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.accentBlue),
                      )
                    : const Icon(Icons.picture_as_pdf_outlined, size: 16),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --- CONTENT (grid / list + pager) ---

  Widget _buildContent(
    bool loading,
    Object? error,
    List<Map<String, dynamic>> all,
    List<Map<String, dynamic>> filtered,
  ) {
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
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textMuted(context), fontSize: 13)),
            ],
          ),
        );

    if (loading) {
      return shell(const Center(
          child: CircularProgressIndicator(color: AppColors.accentBlue)));
    }
    if (error != null && all.isEmpty) {
      return shell(message(
          Icons.error_outline_rounded, 'Error loading speakers: $error'));
    }
    if (all.isEmpty) {
      return shell(message(Icons.volume_off_outlined, 'No speakers found.'));
    }
    if (filtered.isEmpty) {
      return shell(
          message(Icons.search_off_rounded, 'No speakers match your filters.'));
    }

    final totalPages = (filtered.length / _speakersPerPage).ceil();
    final safePage = _currentPage >= totalPages ? totalPages - 1 : _currentPage;
    if (safePage != _currentPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _currentPage = safePage);
      });
    }
    final pageStart = safePage * _speakersPerPage;
    final pageEnd = (pageStart + _speakersPerPage).clamp(0, filtered.length);
    final pageDocs = filtered.sublist(pageStart, pageEnd);

    return shell(
      Column(
        children: [
          if (!_gridView) ...[
            Container(
              color: AppColors.sunken(context),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
              child: Row(
                children: [
                  _headerCell('SPEAKER', 5),
                  _headerCell('IP ADDRESS', 3),
                  _headerCell('PROTOCOL', 2),
                  _headerCell('STATUS', 3),
                  _headerCell('MAP PIN', 2),
                  const SizedBox(width: 96),
                ],
              ),
            ),
            Divider(color: AppColors.border(context), height: 1, thickness: 1),
          ],
          Expanded(
            child: _gridView
                ? _buildSpeakerGrid(pageDocs)
                : _buildSpeakerList(pageDocs),
          ),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          Container(
            width: double.infinity,
            color: AppColors.sunken(context),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
            child: Row(
              children: [
                Text(
                  'Showing ${pageStart + 1}–$pageEnd of ${filtered.length}',
                  style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
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

  Widget _headerCell(String text, int flex) {
    return Expanded(
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
  }

  void _openView(Map<String, dynamic> data) {
    setState(() {
      _selectedSpeaker = data;
      _rightPanelMode = 'view';
    });
  }

  void _openEdit(Map<String, dynamic> data) {
    _populateEditForm(data);
    setState(() {
      _selectedSpeaker = data;
      _rightPanelMode = 'edit';
    });
  }

  void _openDelete(Map<String, dynamic> data) {
    setState(() => _selectedSpeaker = data);
    _showDeleteConfirmDialog();
  }

  Widget _buildSpeakerGrid(List<Map<String, dynamic>> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 250,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        mainAxisExtent: 256,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final data = items[index];
        return _SpeakerCard(
          data: data,
          onTap: () => _openView(data),
          onEdit: () => _openEdit(data),
          onDelete: () => _openDelete(data),
        );
      },
    );
  }

  Widget _buildSpeakerList(List<Map<String, dynamic>> items) {
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
      itemBuilder: (context, index) {
        final data = items[index];
        return _SpeakerRowTile(
          data: data,
          onTap: () => _openView(data),
          onEdit: () => _openEdit(data),
          onDelete: () => _openDelete(data),
        );
      },
    );
  }

  Widget _buildPagePicker({required int currentPage, required int totalPages}) {
    List<int> pageNumbers() {
      final pages = <int>{0, totalPages - 1, currentPage};
      if (currentPage - 1 >= 0) pages.add(currentPage - 1);
      if (currentPage + 1 < totalPages) pages.add(currentPage + 1);
      return pages.toList()..sort();
    }

    Widget arrow(IconData icon, VoidCallback? onTap) {
      return _HoverPop(
        enabled: onTap != null,
        child: SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            padding: EdgeInsets.zero,
            onPressed: onTap,
            splashRadius: 16,
            icon: Icon(icon,
                size: 16,
                color: onTap == null
                    ? AppColors.textMuted(context)
                    : AppColors.textMain(context)),
          ),
        ),
      );
    }

    Widget pageButton(int i) {
      final isCurrent = i == currentPage;
      return _HoverPop(
        enabled: !isCurrent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: isCurrent ? null : () => setState(() => _currentPage = i),
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isCurrent ? AppColors.accentBlue : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: isCurrent
                  ? null
                  : Border.all(color: AppColors.border(context)),
            ),
            child: Text(
              '${i + 1}',
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
      arrow(Icons.chevron_left,
          currentPage > 0 ? () => setState(() => _currentPage--) : null),
      const SizedBox(width: 4),
    ];
    for (int i = 0; i < pages.length; i++) {
      if (i > 0 && pages[i] - pages[i - 1] > 1) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('…',
              style: TextStyle(
                  color: AppColors.textMuted(context), fontSize: 11.5)),
        ));
      }
      widgets.add(pageButton(pages[i]));
      if (i != pages.length - 1) widgets.add(const SizedBox(width: 4));
    }
    widgets.add(const SizedBox(width: 4));
    widgets.add(arrow(Icons.chevron_right,
        currentPage < totalPages - 1 ? () => setState(() => _currentPage++) : null));

    return Row(mainAxisSize: MainAxisSize.min, children: widgets);
  }

  // ---------------------------------------------------------------------
  // CENTERED MODAL
  // ---------------------------------------------------------------------

  void _syncModalOverlay() {
    if (!mounted) return;

    // Keep the confirm dialog in step with theme changes.
    _confirmOverlayEntry?.markNeedsBuild();

    if (_rightPanelMode != null) {
      _lastMode = _rightPanelMode!;
      if (_modalEntry == null) {
        _modalEntry = OverlayEntry(builder: (_) => _buildModalOverlay());
        Overlay.of(context, rootOverlay: true).insert(_modalEntry!);
        _modalAnim.forward(from: 0);
      } else {
        _modalEntry!.markNeedsBuild();
        if (_modalAnim.status == AnimationStatus.reverse ||
            _modalAnim.status == AnimationStatus.dismissed) {
          _modalAnim.forward();
        }
      }
    } else if (_modalEntry != null) {
      if (_modalAnim.status != AnimationStatus.reverse &&
          _modalAnim.status != AnimationStatus.dismissed) {
        _modalAnim.reverse().then((_) {
          if (_rightPanelMode == null) {
            _modalEntry?.remove();
            _modalEntry = null;
          }
        });
      }
    }
  }

  Widget _buildModalOverlay() {
    final mode = _rightPanelMode ?? _lastMode;
    Widget content;
    if (mode == 'view') {
      content = _selectedSpeaker == null
          ? const SizedBox.shrink()
          : _buildDetailsModal(_selectedSpeaker!);
    } else {
      content = _buildFormModal(isEditMode: mode == 'edit');
    }

    final size = MediaQuery.of(context).size;

    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeRightPanel,
              child: AnimatedBuilder(
                animation: _modalAnim,
                builder: (_, __) => Container(
                  color: Colors.black.withOpacity(0.5 * _modalAnim.value),
                ),
              ),
            ),
          ),
          Center(
            child: AnimatedBuilder(
              animation: _modalAnim,
              builder: (_, child) {
                final t = Curves.easeOutCubic
                    .transform(_modalAnim.value.clamp(0.0, 1.0));
                return Opacity(
                  opacity: t,
                  child: Transform.scale(scale: 0.95 + 0.05 * t, child: child),
                );
              },
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 640,
                  maxHeight: size.height - 48,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Material(
                    color: AppColors.card(context),
                    clipBehavior: Clip.antiAlias,
                    elevation: 24,
                    shadowColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: AppColors.border(context)),
                    ),
                    child: GestureDetector(onTap: () {}, child: content),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modalCloseButton() {
    return _HoverPop(
      child: GestureDetector(
        onTap: _closeRightPanel,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: AppColors.border(context).withOpacity(0.6),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.close, size: 17, color: AppColors.textMain(context)),
        ),
      ),
    );
  }

  ButtonStyle _footerButtonStyle(
      {required Color bg, required Color fg, Color? disabledBg}) {
    return ElevatedButton.styleFrom(
      backgroundColor: bg,
      foregroundColor: fg,
      disabledBackgroundColor: disabledBg,
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }

  // Shared modal building blocks --------------------------------------

  Widget _detailSection(String title, IconData icon, List<Widget> fields) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: AppColors.textMuted(context)),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                color: AppColors.textMain(context),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.9,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Divider(color: AppColors.border(context), height: 1)),
          ],
        ),
        const SizedBox(height: 14),
        ..._detailRows(fields),
      ],
    );
  }

  List<Widget> _detailRows(List<Widget> fields) {
    final rows = <Widget>[];
    var pending = <Widget>[];

    void flush() {
      if (pending.isEmpty) return;
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 16));
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: pending[0]),
          const SizedBox(width: 20),
          Expanded(child: pending.length > 1 ? pending[1] : const SizedBox()),
        ],
      ));
      pending = [];
    }

    for (final f in fields) {
      if (f is _DetailFieldMarker && f.full) {
        flush();
        if (rows.isNotEmpty) rows.add(const SizedBox(height: 16));
        rows.add(f);
      } else {
        pending.add(f);
        if (pending.length == 2) flush();
      }
    }
    flush();
    return rows;
  }

  Widget _detailField(
    String label,
    String value, {
    IconData? icon,
    Color? iconColor,
    bool copyable = false,
    String? copyLabel,
    bool mono = false,
    bool full = false,
  }) {
    final empty = value.trim().isEmpty;
    return _DetailFieldMarker(
      full: full,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 30,
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon,
                      size: 15, color: iconColor ?? AppColors.textMuted(context)),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    empty ? '—' : value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: empty
                          ? AppColors.textMuted(context)
                          : AppColors.textMain(context),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      fontFamily: mono ? 'monospace' : null,
                    ),
                  ),
                ),
                if (copyable && !empty) ...[
                  const SizedBox(width: 4),
                  _MiniIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: 'Copy',
                    onTap: () => _copyText(value, copyLabel ?? label),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- VIEW MODAL ---

  Widget _buildDetailsModal(Map<String, dynamic> speaker) {
    final name = (speaker['name'] ?? 'Unnamed Speaker').toString();
    final zone = (speaker['zone'] ?? '').toString().trim();
    final location = (speaker['location'] ?? '').toString().trim();
    final ipAddress = (speaker['ip_address'] ?? '').toString().trim();
    final port = (speaker['port'] ?? '').toString().trim();
    final protocol = (speaker['protocol'] ?? '').toString().trim();
    final extension = (speaker['sip_extension'] ?? '').toString().trim();
    final username = (speaker['username'] ?? '').toString().trim();
    final volumeRaw = speaker['volume'];
    final volume = volumeRaw is num ? '${volumeRaw.toInt()}%' : '';
    final status = (speaker['status'] ?? 'Offline').toString();
    final createdAt = _formatTimestamp(speaker['created_at']);
    final lat = speaker['latitude'];
    final lng = speaker['longitude'];
    final hasMapPin = lat is num && lng is num;
    final mapPinDisplay = hasMapPin
        ? '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}'
        : '';
    final color = _statusColor(context, status);

    Widget pane() {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailSection('LOCATION', Icons.place_outlined, [
              _detailField('ZONE', zone, icon: Icons.grid_view_outlined),
              _detailField('LOCATION/STREET NAME', location,
                  icon: Icons.place_outlined),
              _detailField(
                  'MAP PIN', mapPinDisplay.isEmpty ? 'Not set' : mapPinDisplay,
                  icon: hasMapPin ? Icons.location_on : Icons.location_off_outlined,
                  iconColor: hasMapPin ? AppColors.accentBlue : null,
                  copyable: hasMapPin,
                  copyLabel: 'Map pin',
                  mono: hasMapPin,
                  full: true),
            ]),
            const SizedBox(height: 22),
            _detailSection('CONNECTION', Icons.lan_outlined, [
              _detailField('IP ADDRESS', ipAddress,
                  copyable: true, copyLabel: 'IP address', mono: true),
              _detailField('PORT', port, mono: true),
              _detailField('PROTOCOL', protocol),
              _detailField('EXTENSION / MULTICAST', extension, mono: true),
              _detailField('USERNAME', username, full: true),
            ]),
            const SizedBox(height: 22),
            _detailSection('DEVICE', Icons.memory_outlined, [
              _detailField('VOLUME', volume, icon: Icons.volume_up_outlined),
              _detailField('STATUS', status.toUpperCase(),
                  icon: _statusIcon(status), iconColor: color),
              _detailField('ADDED ON', createdAt, full: true),
            ]),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
          child: Row(
            children: [
              _SpeakerAvatar(status: status, size: 44),
              const SizedBox(width: 14),
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
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      zone.isEmpty ? 'No zone set' : zone,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _StatusChip(status: status),
              const SizedBox(width: 12),
              _modalCloseButton(),
            ],
          ),
        ),
        Divider(color: AppColors.border(context), height: 1, thickness: 1),
        Flexible(child: SingleChildScrollView(child: pane())),
        Divider(color: AppColors.border(context), height: 1, thickness: 1),
        Container(
          color: AppColors.card(context),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Spacer(),
              _HoverPop(
                child: ElevatedButton(
                  onPressed: _closeRightPanel,
                  style: _footerButtonStyle(
                      bg: AppColors.border(context),
                      fg: AppColors.textMain(context)),
                  child: const Text('CLOSE',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(width: 10),
              _HoverPop(
                child: ElevatedButton.icon(
                  onPressed: () {
                    _populateEditForm(speaker);
                    setState(() => _rightPanelMode = 'edit');
                  },
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  style: _footerButtonStyle(
                      bg: AppColors.accentBlue, fg: Colors.white),
                  label: const Text('EDIT SPEAKER',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- ADD / EDIT MODAL ---

  Widget _buildFormModal({required bool isEditMode}) {
    final selected = _selectedSpeaker;
    final headerName = isEditMode && selected != null
        ? (selected['name'] ?? 'Unnamed Speaker').toString()
        : 'New speaker';
    final editStatus = (selected?['status'] ?? 'Offline').toString();
    final size = MediaQuery.of(context).size;
    final mapHeight = (size.height - 300).clamp(300.0, 520.0);

    Widget field(Widget child, {bool full = false}) =>
        _DetailFieldMarker(full: full, child: child);

    Widget fields() {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailSection('GENERAL', Icons.campaign_outlined, [
              field(_buildInputField('SPEAKER NAME', _nameController,
                  'Gate 2 Horn Speaker',
                  isRequired: true,
                  validator: (v) => _requiredValidator(v, 'Speaker name'))),
              field(_buildInputField('ZONE', _zoneController, 'Zone A - Plaza',
                  isRequired: true,
                  validator: (v) => _requiredValidator(v, 'Zone'))),
              field(
                  _buildInputField('LOCATION/STREET NAME', _locationController,
                      'Barangay Hall Entrance',
                      isRequired: true,
                      validator: (v) => _requiredValidator(v, 'Location')),
                  full: true),
            ]),
            const SizedBox(height: 22),
            _detailSection('MAP LOCATION', Icons.map_outlined, [
              field(_buildLocationPickerField(), full: true),
            ]),
            const SizedBox(height: 22),
            _detailSection('CONNECTION', Icons.lan_outlined, [
              field(_buildProtocolField()),
              field(_buildInputField('IP ADDRESS', _ipAddressController,
                  '192.168.1.45',
                  isRequired: true,
                  keyboardType: TextInputType.number,
                  validator: _ipAddressValidator)),
              field(_buildInputField('PORT', _portController, '80',
                  isRequired: true,
                  keyboardType: TextInputType.number,
                  validator: _portValidator)),
              field(_buildInputField('EXTENSION / MULTICAST (OPTIONAL)',
                  _extensionController, '1001 or 239.255.0.1')),
              field(_buildTestConnectionBox(), full: true),
            ]),
            const SizedBox(height: 22),
            _detailSection('ACCESS (OPTIONAL)', Icons.lock_outline, [
              field(_buildInputField('USERNAME', _usernameController, 'admin')),
              field(_buildPasswordField()),
            ]),
            const SizedBox(height: 22),
            _detailSection('AUDIO', Icons.volume_up_outlined, [
              field(_buildVolumeField(), full: true),
            ]),
          ],
        ),
      );
    }

    Widget formFooter() {
      return Row(
        children: [
          if (isEditMode)
            _HoverPop(
              child: TextButton.icon(
                onPressed: _showDeleteConfirmDialogFromPanel,
                icon: const Icon(Icons.delete_outline,
                    size: 17, color: AppColors.accentRed),
                label: const Text('Remove speaker',
                    style: TextStyle(
                        color: AppColors.accentRed,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          const Spacer(),
          _HoverPop(
            child: ElevatedButton(
              onPressed: () => setState(() {
                _rightPanelMode = isEditMode ? 'view' : null;
              }),
              style: _footerButtonStyle(
                  bg: AppColors.border(context), fg: AppColors.textMain(context)),
              child: const Text('CANCEL',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 10),
          AnimatedBuilder(
            animation: Listenable.merge([
              _nameController,
              _zoneController,
              _locationController,
              _ipAddressController,
              _portController,
              _extensionController,
              _usernameController,
              _passwordController,
            ]),
            builder: (context, _) {
              final canSave = !_isProcessing &&
                  (isEditMode ? _hasEditChanges() : _canCreate());
              return _HoverPop(
                enabled: canSave,
                child: ElevatedButton(
                  onPressed: !canSave
                      ? null
                      : () async {
                          if (!(_formKey.currentState?.validate() ?? false)) {
                            return;
                          }

                          if (isEditMode) {
                            final confirmed = await _showActionConfirmDialog(
                              title: 'Save changes?',
                              message:
                                  'This will update "$headerName". Continue?',
                              confirmLabel: 'SAVE',
                              confirmColor: AppColors.accentBlue,
                              icon: Icons.edit_outlined,
                            );
                            if (!confirmed) return;
                          }

                          // Close the modal before the async work so the
                          // blocking loader is the only layer on screen.
                          if (mounted) setState(() => _rightPanelMode = null);
                          await Future.delayed(const Duration(milliseconds: 120));
                          await _handleSaveSpeaker(isEditMode: isEditMode);
                        },
                  style: _footerButtonStyle(
                    bg: AppColors.accentBlue,
                    fg: Colors.white,
                    disabledBg: AppColors.accentBlue.withOpacity(0.4),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : Text(isEditMode ? 'SAVE CHANGES' : 'ADD SPEAKER',
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w800)),
                ),
              );
            },
          ),
        ],
      );
    }

    Widget pickerFooter() {
      final hasPoint = _inlinePickedPoint != null;
      return Row(
        children: [
          const Spacer(),
          _HoverPop(
            child: ElevatedButton(
              onPressed: () => setState(() {
                _isPickingLocationInline = false;
                _inlinePickedPoint = null;
              }),
              style: _footerButtonStyle(
                  bg: AppColors.border(context), fg: AppColors.textMain(context)),
              child: const Text('CANCEL',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 10),
          _HoverPop(
            enabled: hasPoint,
            child: ElevatedButton.icon(
              onPressed: hasPoint
                  ? () => setState(() {
                        _selectedLat = _inlinePickedPoint!.latitude;
                        _selectedLng = _inlinePickedPoint!.longitude;
                        _isPickingLocationInline = false;
                        _inlinePickedPoint = null;
                      })
                  : null,
              icon: const Icon(Icons.check, size: 16),
              style: _footerButtonStyle(
                bg: AppColors.accentBlue,
                fg: Colors.white,
                disabledBg: AppColors.accentBlue.withOpacity(0.4),
              ),
              label: const Text('CONFIRM LOCATION',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 16, 14),
          child: Row(
            children: [
              if (_isPickingLocationInline)
                _HoverPop(
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _isPickingLocationInline = false;
                      _inlinePickedPoint = null;
                    }),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.border(context).withOpacity(0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.arrow_back,
                          color: AppColors.textMain(context), size: 17),
                    ),
                  ),
                )
              else if (isEditMode)
                _SpeakerAvatar(status: editStatus, size: 40)
              else
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accentBlue.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.add_rounded,
                      color: AppColors.accentBlue, size: 17),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isPickingLocationInline
                          ? 'Set speaker location'
                          : (isEditMode ? 'Edit speaker' : 'Add new speaker'),
                      style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _isPickingLocationInline
                          ? 'Tap the map to drop a pin inside the barangay'
                          : (isEditMode
                              ? headerName
                              : 'Register a PA speaker on your network'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (isEditMode && !_isPickingLocationInline) ...[
                _StatusChip(status: editStatus),
                const SizedBox(width: 12),
              ],
              _modalCloseButton(),
            ],
          ),
        ),
        Divider(color: AppColors.border(context), height: 1, thickness: 1),
        if (_isPickingLocationInline)
          SizedBox(height: mapHeight, child: _buildInlineLocationPicker())
        else
          Flexible(
            child: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: fields(),
              ),
            ),
          ),
        Divider(color: AppColors.border(context), height: 1, thickness: 1),
        Container(
          color: AppColors.card(context),
          padding: const EdgeInsets.all(16),
          child: _isPickingLocationInline
              ? KeyedSubtree(
                  key: const ValueKey('picker_footer'), child: pickerFooter())
              : KeyedSubtree(
                  key: const ValueKey('form_footer'), child: formFooter()),
        ),
      ],
    );
  }

  Widget _buildLocationPickerField() {
    final hasPoint = _selectedLat != null && _selectedLng != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.sunken(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasPoint
              ? AppColors.accentBlue.withOpacity(0.35)
              : AppColors.border(context),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: (hasPoint
                      ? AppColors.accentBlue
                      : AppColors.textMuted(context))
                  .withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              hasPoint ? Icons.location_on : Icons.map_outlined,
              color:
                  hasPoint ? AppColors.accentBlue : AppColors.textMuted(context),
              size: 17,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasPoint ? 'Pin set' : 'No pin set',
                  style: TextStyle(
                    color: hasPoint
                        ? AppColors.textMain(context)
                        : AppColors.textMuted(context),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasPoint
                      ? '${_selectedLat!.toStringAsFixed(6)}, ${_selectedLng!.toStringAsFixed(6)}'
                      : 'Drop a pin so this speaker shows up on the map.',
                  style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 11.5,
                    height: 1.35,
                    fontFamily: hasPoint ? 'monospace' : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (hasPoint)
            _MiniIconButton(
              icon: Icons.close,
              tooltip: 'Clear pin',
              onTap: () => setState(() {
                _selectedLat = null;
                _selectedLng = null;
              }),
            ),
          _HoverPop(
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _inlinePickedPoint =
                      (_selectedLat != null && _selectedLng != null)
                          ? LatLng(_selectedLat!, _selectedLng!)
                          : null;
                  _isPickingLocationInline = true;
                });
              },
              icon: Icon(
                hasPoint
                    ? Icons.edit_location_alt_outlined
                    : Icons.add_location_alt_outlined,
                size: 15,
              ),
              label: Text(hasPoint ? 'CHANGE' : 'SET ON MAP'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentBlue,
                side: BorderSide(color: AppColors.accentBlue.withOpacity(0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Protocol dropdown.
  Widget _buildProtocolField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'PROTOCOL',
              style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 3),
            const Text('*',
                style: TextStyle(
                    color: AppColors.accentRed,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.bg(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _protocol,
              isExpanded: true,
              dropdownColor: AppColors.card(context),
              borderRadius: BorderRadius.circular(10),
              icon: Icon(Icons.expand_more_rounded,
                  size: 18, color: AppColors.textMuted(context)),
              style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
              items: [
                for (final p in _kProtocols)
                  DropdownMenuItem(value: p, child: Text(p)),
              ],
              onChanged: (v) {
                if (v != null) _onProtocolChanged(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  /// "Test connection" helper shown under the connection fields.
  Widget _buildTestConnectionBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.sunken(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: AppColors.textMuted(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Status is set automatically: the app opens a TCP connection to '
              'this IP and port every 45 seconds. Use the web/control port if '
              'the speaker only listens for SIP/RTP over UDP.',
              style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _HoverPop(
            enabled: !_isTesting,
            child: OutlinedButton.icon(
              onPressed: _isTesting ? null : _testConnection,
              icon: _isTesting
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accentBlue),
                    )
                  : const Icon(Icons.wifi_tethering_rounded, size: 15),
              label: Text(_isTesting ? 'TESTING' : 'TEST'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentBlue,
                side: BorderSide(color: AppColors.accentBlue.withOpacity(0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeField() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      decoration: BoxDecoration(
        color: AppColors.sunken(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _volume <= 0
                    ? Icons.volume_off_outlined
                    : (_volume < 50
                        ? Icons.volume_down_outlined
                        : Icons.volume_up_outlined),
                size: 15,
                color: AppColors.textMuted(context),
              ),
              const SizedBox(width: 8),
              Text(
                'DEFAULT VOLUME',
                style: TextStyle(
                  color: AppColors.textMuted(context),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              Text(
                '${_volume.round()}%',
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accentBlue,
              thumbColor: AppColors.accentBlue,
              inactiveTrackColor: AppColors.accentBlue.withOpacity(0.18),
              overlayColor: AppColors.accentBlue.withOpacity(0.12),
              trackHeight: 4,
            ),
            child: Slider(
              value: _volume,
              min: 0,
              max: 100,
              divisions: 20,
              onChanged: (v) => setState(() => _volume = v),
            ),
          ),
        ],
      ),
    );
  }

  // --- INLINE MAP LOCATION PICKER ---

  static const LatLng _mapDefaultCenter = LatLng(14.6837, 121.0766);

  static const List<LatLng> _mapMaskOuterRing = [
    LatLng(-85, -180),
    LatLng(-85, 180),
    LatLng(85, 180),
    LatLng(85, -180),
  ];
  static const Color _mapBoundaryColor = Color(0xFF10B981);

  // Cached map layers (theme-independent) so theme-fade rebuilds skip them.
  late final TileLayer _tileLayer = TileLayer(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    userAgentPackageName: 'com.yourcompany.admin_app',
  );

  late final PolygonLayer? _boundaryLayer = BarangayBoundary.points.isEmpty
      ? null
      : PolygonLayer(
          polygons: [
            Polygon(
              points: _mapMaskOuterRing,
              holePointsList: [BarangayBoundary.points],
              color: Colors.black.withOpacity(0.55),
              isFilled: true,
            ),
            Polygon(
              points: BarangayBoundary.points,
              color: Colors.transparent,
              borderColor: _mapBoundaryColor,
              borderStrokeWidth: 3,
              isFilled: false,
            ),
          ],
        );

  Widget _buildInlineLocationPicker() {
    final hasPoint = _inlinePickedPoint != null;
    final initialCenter = _inlinePickedPoint ??
        (BarangayBoundary.points.isNotEmpty
            ? BarangayBoundary.points.first
            : _mapDefaultCenter);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
          child: Row(
            children: [
              Icon(
                hasPoint ? Icons.open_with_rounded : Icons.touch_app_outlined,
                color: AppColors.accentBlue,
                size: 15,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hasPoint
                      ? 'Tap anywhere to move the pin'
                      : 'Tap the map to drop a pin',
                  style: TextStyle(
                      color: AppColors.textMuted(context), fontSize: 12),
                ),
              ),
              if (hasPoint)
                InkWell(
                  onTap: () => setState(() => _inlinePickedPoint = null),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close,
                        size: 15, color: AppColors.textMuted(context)),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: initialCenter,
                        initialZoom: 16,
                        minZoom: 14,
                        maxZoom: 19,
                        onTap: (tapPosition, point) {
                          setState(() => _inlinePickedPoint = point);
                        },
                      ),
                      children: [
                        _tileLayer,
                        if (_boundaryLayer != null) _boundaryLayer!,
                        if (_inlinePickedPoint != null)
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: _inlinePickedPoint!,
                                width: 46,
                                height: 46,
                                alignment: Alignment.topCenter,
                                child: const _MapPinIcon(),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  if (hasPoint)
                    Positioned(
                      left: 10,
                      bottom: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: AppColors.card(context).withOpacity(0.94),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border(context)),
                          boxShadow: const [
                            BoxShadow(
                                color: Colors.black38,
                                blurRadius: 6,
                                offset: Offset(0, 2)),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.my_location,
                                color: AppColors.textMuted(context), size: 12),
                            const SizedBox(width: 6),
                            Text(
                              '${_inlinePickedPoint!.latitude.toStringAsFixed(6)}, '
                              '${_inlinePickedPoint!.longitude.toStringAsFixed(6)}',
                              style: TextStyle(
                                color: AppColors.textMain(context),
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // BLOCKING LOADER
  // -----------------------------------------------------------------------

  void _showBlockingLoader(String message) {
    showDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (_) => Center(child: _buildLoadingCard(message)),
    );
  }

  void _hideBlockingLoader() {
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) navigator.pop();
  }

  Widget _buildLoadingCard(String message) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border(context)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                  color: AppColors.accentBlue, strokeWidth: 3),
            ),
            const SizedBox(height: 14),
            Text(
              message,
              style: TextStyle(
                color: AppColors.textMain(context),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // SAVE / DELETE HANDLERS
  // -----------------------------------------------------------------------

  Future<void> _handleSaveSpeaker({required bool isEditMode}) async {
    setState(() => _isSaving = true);
    _showBlockingLoader(isEditMode ? 'Saving changes...' : 'Adding speaker...');
    try {
      final newName = _nameController.text.trim();
      final newZone = _zoneController.text.trim();
      final newLocation = _locationController.text.trim();
      final newIp = _ipAddressController.text.trim();
      final newPortText = _portController.text.trim();
      final newPort = int.tryParse(newPortText) ?? 80;
      final newExtension = _extensionController.text.trim();
      final newUsername = _usernameController.text.trim();
      final newPassword = _passwordController.text.trim();
      final newProtocol = _protocol;
      final newVolume = _volume.round();
      final newLat = _selectedLat;
      final newLng = _selectedLng;

      String resolvedStatus = 'Offline';
      if (newIp.isNotEmpty) {
        final reachable = await _isSpeakerReachable(newIp, newPort);
        resolvedStatus = reachable ? 'Online' : 'Offline';
      }

      final speakerData = {
        'name': newName,
        'zone': newZone,
        'location': newLocation,
        'ip_address': newIp,
        'port': newPort,
        'protocol': newProtocol,
        'sip_extension': newExtension.isEmpty ? null : newExtension,
        'username': newUsername.isEmpty ? null : newUsername,
        'password': newPassword.isEmpty ? null : newPassword,
        'volume': newVolume,
        'status': resolvedStatus,
        'latitude': newLat,
        'longitude': newLng,
      };

      if (isEditMode) {
        final id = _selectedSpeaker?['id'];
        if (id != null) {
          final old = _selectedSpeaker!;
          String s(String k) => (old[k] ?? '').toString();
          final oldLatRaw = old['latitude'];
          final oldLngRaw = old['longitude'];
          final oldPin = _formatPin(
            (oldLatRaw is num) ? oldLatRaw.toDouble() : null,
            (oldLngRaw is num) ? oldLngRaw.toDouble() : null,
          );
          final newPin = _formatPin(newLat, newLng);

          final updated = await _supabase
              .from('pa_speakers')
              .update(speakerData)
              .eq('id', id)
              .select(); // [] if RLS blocked the write

          if (updated.isEmpty) {
            throw Exception("You don't have permission to update this speaker.");
          }

          final changes = <LogChange>[
            if (s('name') != newName)
              LogChange(field: 'Name', from: s('name'), to: newName),
            if (s('zone') != newZone)
              LogChange(field: 'Zone', from: s('zone'), to: newZone),
            if (s('location') != newLocation)
              LogChange(field: 'Location', from: s('location'), to: newLocation),
            if (s('ip_address') != newIp)
              LogChange(field: 'IP Address', from: s('ip_address'), to: newIp),
            if (s('port') != '$newPort')
              LogChange(field: 'Port', from: s('port'), to: '$newPort'),
            if (s('protocol') != newProtocol)
              LogChange(field: 'Protocol', from: s('protocol'), to: newProtocol),
            if (s('sip_extension') != newExtension)
              LogChange(
                  field: 'Extension / Multicast',
                  from: s('sip_extension'),
                  to: newExtension),
            if (s('username') != newUsername)
              LogChange(field: 'Username', from: s('username'), to: newUsername),
            if (s('password') != newPassword)
              const LogChange(
                field: 'Password',
                from: 'Previous password',
                to: 'New password',
              ),
            if (s('volume') != '$newVolume')
              LogChange(field: 'Volume', from: '${s('volume')}%', to: '$newVolume%'),
            if (s('status').toLowerCase() != resolvedStatus.toLowerCase())
              LogChange(
                field: 'Status',
                from: s('status').isEmpty ? 'Unknown' : s('status'),
                to: resolvedStatus,
              ),
            if (oldPin != newPin)
              LogChange(field: 'Map Location', from: oldPin, to: newPin),
          ];

          await ActivityLogger.log(
            action: 'UPDATE_SPEAKER',
            details: 'Updated "$newName"',
            changes: changes,
          );

          if (!mounted) return;
          setState(() {
            _selectedSpeaker = {..._selectedSpeaker!, ...speakerData};
          });

          if (!mounted) return;
          AppToast.success(context, 'Speaker updated successfully');
        }
      } else {
        await _supabase.from('pa_speakers').insert(speakerData);

        await ActivityLogger.log(
          action: 'CREATE_SPEAKER',
          details: 'Added new speaker "$newName"',
          metadata: {
            'zone': newZone,
            'location': newLocation,
            'ip_address': newIp,
            'protocol': newProtocol,
            'status': resolvedStatus,
          },
        );

        if (!mounted) return;
        _clearForm();
        AppToast.success(context, 'Speaker added successfully');
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Error: $e');
      // Reopen the form (data still in the controllers).
      setState(() {
        _rightPanelMode = isEditMode ? 'edit' : 'add';
      });
    } finally {
      _hideBlockingLoader();
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // --- CONFIRM DIALOG (renders above the modal) ---

  Future<bool> _showActionConfirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
    required Color confirmColor,
    required IconData icon,
  }) async {
    final completer = Completer<bool>();
    var completed = false;

    void respond(bool result) {
      if (completed) return;
      completed = true;
      _confirmAnimController.reverse().then((_) {
        _confirmOverlayEntry?.remove();
        _confirmOverlayEntry = null;
        if (!completer.isCompleted) completer.complete(result);
      });
    }

    _confirmOverlayEntry = OverlayEntry(
      builder: (_) => _buildConfirmDialogOverlay(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        confirmColor: confirmColor,
        icon: icon,
        onScrimTap: () => respond(false),
        onCancel: () => respond(false),
        onConfirm: () => respond(true),
      ),
    );

    // Deferred so inserting an interactive overlay from inside a tap callback
    // doesn't trip the mouse tracker assertion on desktop/web.
    Future.delayed(Duration.zero, () {
      if (!mounted) return;
      Overlay.of(context, rootOverlay: true).insert(
        _confirmOverlayEntry!,
        above: _modalEntry,
      );
      _confirmAnimController.forward(from: 0);
    });

    return completer.future;
  }

  Widget _buildConfirmDialogOverlay({
    required String title,
    required String message,
    required String confirmLabel,
    required Color confirmColor,
    required IconData icon,
    required VoidCallback onScrimTap,
    required VoidCallback onCancel,
    required VoidCallback onConfirm,
  }) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _confirmAnimController,
        builder: (context, _) {
          final t = Curves.easeOutCubic
              .transform(_confirmAnimController.value)
              .clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: onScrimTap,
                  child: Container(color: Colors.black.withOpacity(0.55 * t)),
                ),
              ),
              Center(
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.94 + (0.06 * t),
                    child: Material(
                      color: Colors.transparent,
                      child: GestureDetector(
                        onTap: () {},
                        child: Container(
                          width: 360,
                          padding: const EdgeInsets.all(22),
                          decoration: BoxDecoration(
                            color: AppColors.card(context),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.border(context)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.5),
                                blurRadius: 40,
                                offset: const Offset(0, 16),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: confirmColor.withOpacity(0.14),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(icon, color: confirmColor, size: 20),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                title,
                                style: TextStyle(
                                  color: AppColors.textMain(context),
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                message,
                                style: TextStyle(
                                  color: AppColors.textMuted(context),
                                  fontSize: 13,
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 22),
                              Row(
                                children: [
                                  Expanded(
                                    child: _HoverPop(
                                      child: OutlinedButton(
                                        onPressed: onCancel,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor:
                                              AppColors.textMain(context),
                                          side: BorderSide(
                                              color: AppColors.border(context)),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 14),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10)),
                                        ),
                                        child: const Text('CANCEL',
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.5)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _HoverPop(
                                      child: ElevatedButton(
                                        onPressed: onConfirm,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: confirmColor,
                                          foregroundColor: Colors.white,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 14),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10)),
                                        ),
                                        child: Text(confirmLabel,
                                            style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.5)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showDeleteConfirmDialogFromPanel() => _showDeleteConfirmDialog();

  Future<void> _showDeleteConfirmDialog() async {
    final id = _selectedSpeaker?['id'];
    if (id == null) return;

    final name = (_selectedSpeaker?['name'] ?? '').toString();
    final status = (_selectedSpeaker?['status'] ?? '').toString();
    final label = name.trim().isEmpty ? id.toString() : name.trim();

    final confirmed = await _showActionConfirmDialog(
      title: 'Remove this speaker?',
      message:
          'Are you sure you want to remove "$label"? This action cannot be undone, '
          'and the speaker will no longer receive broadcast audio.',
      confirmLabel: 'REMOVE',
      confirmColor: AppColors.accentRed,
      icon: Icons.delete_outline,
    );

    if (confirmed) {
      await _handleDeleteSpeaker(id: id, label: label, status: status);
    }
  }

  Future<void> _handleDeleteSpeaker({
    required dynamic id,
    required String label,
    required String status,
  }) async {
    setState(() {
      _isDeleting = true;
      _rightPanelMode = null;
      _selectedSpeaker = null;
    });
    _clearForm();
    _showBlockingLoader('Removing speaker...');

    try {
      await _supabase.from('pa_speakers').delete().eq('id', id);

      await ActivityLogger.log(
        action: 'DELETE_SPEAKER',
        details: 'Removed speaker "$label"',
        changes: [
          LogChange(
            field: 'Status',
            from: status.isEmpty ? 'Unknown' : status,
            to: 'Removed',
          ),
        ],
      );

      if (!mounted) return;
      AppToast.success(context, 'Speaker removed successfully');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Failed to remove speaker: $e');
    } finally {
      _hideBlockingLoader();
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  // -----------------------------------------------------------------------
  // VALIDATORS
  // -----------------------------------------------------------------------

  String? _requiredValidator(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required';
    }
    return null;
  }

  String? _ipAddressValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'IP address is required';
    }
    final ip = value.trim();
    final ipRegex = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
    final match = ipRegex.firstMatch(ip);
    if (match == null) {
      return 'Enter a valid IP address, e.g. 192.168.1.45';
    }
    for (int i = 1; i <= 4; i++) {
      final octet = int.tryParse(match.group(i)!);
      if (octet == null || octet < 0 || octet > 255) {
        return 'Each IP segment must be 0-255';
      }
    }
    return null;
  }

  String? _portValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Port is required';
    }
    final port = int.tryParse(value.trim());
    if (port == null || port < 1 || port > 65535) {
      return 'Port must be 1-65535';
    }
    return null;
  }

  // -----------------------------------------------------------------------
  // SMALL WIDGET HELPERS
  // -----------------------------------------------------------------------

  OutlineInputBorder _border(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  InputDecoration _inputDecoration(String hint, {Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
      filled: true,
      fillColor: AppColors.bg(context),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: _border(AppColors.border(context)),
      enabledBorder: _border(AppColors.border(context)),
      focusedBorder: _border(AppColors.accentBlue, width: 1.5),
      errorBorder: _border(AppColors.accentRed),
      focusedErrorBorder: _border(AppColors.accentRed, width: 1.5),
      errorStyle: const TextStyle(color: AppColors.accentRed, fontSize: 11),
      suffixIcon: suffixIcon,
    );
  }

  Widget _fieldLabel(String label, {bool isRequired = false}) {
    return Row(
      children: [
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (isRequired) ...[
          const SizedBox(width: 3),
          const Text(
            '*',
            style: TextStyle(
              color: AppColors.accentRed,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildInputField(
    String label,
    TextEditingController controller,
    String hint, {
    bool isRequired = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(label, isRequired: isRequired),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          validator: validator,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
          decoration: _inputDecoration(hint),
        ),
      ],
    );
  }

  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('PASSWORD'),
        const SizedBox(height: 6),
        StatefulBuilder(
          builder: (context, setFieldState) {
            return TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
              decoration: _inputDecoration(
                '••••••••',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    color: AppColors.textMuted(context),
                    size: 18,
                  ),
                  onPressed: () {
                    setFieldState(() {});
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _MapPinIcon extends StatelessWidget {
  const _MapPinIcon();

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.location_on,
      color: Colors.redAccent,
      size: 46,
      shadows: [
        Shadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2)),
      ],
    );
  }
}