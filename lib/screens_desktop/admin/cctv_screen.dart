import 'dart:async';
import 'dart:io';
import 'dart:isolate';
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
import '../../utils/camera_discovery_service.dart';
import '../../hikvision_sdk.dart';
import '../../constants/barangay_boundary.dart';
import '../../widgets/app_toast.dart';
import '../../constants/app_colors.dart';

/// CCTV cameras screen. Mirrors UsersScreen so both tabs feel like one
/// product:
///   • header (title + Export PDF / Scan / Add actions)
///   • clickable stat cards that double as status filters
///   • toolbar: search, segmented status filter, grid/list toggle
///   • card grid or list rows with a pager
///   • a centered single-column modal for view / add / edit (compact header
///     with a small status avatar + sectioned fields), with the confirm
///     dialog stacked above it
///
/// Statuses are Online / Offline only (set automatically by the health
/// monitor and on save).
///
/// Behavior: the client-side health monitor (SADP + TCP probe, IP-drift
/// correction by serial number), Hikvision SDK serial lookup on a worker
/// isolate, network discovery / cross-subnet fix, the inline map location
/// picker (swapped in *inside* the modal), and activity logging.
///
/// EXPORT: the header "Export PDF" button builds a portrait A4 PDF (SafeWatch
/// header, who exported it + date/time, counts, filters, then a simple
/// bordered cameras table) for the cameras currently shown, and downloads it
/// straight away through `file_saver`. Camera usernames/passwords are never
/// included. Needs `pdf` + `file_saver`.
///
/// Supabase table `cameras`:
///   id, name, ip_address, port, sdk_port, username, password, stream_url,
///   location, latitude, longitude, status, serial_number, channel_num,
///   ip_channel_num, serial_lookup_error, created_at
class CctvScreen extends StatefulWidget {
  final bool isActive;

  const CctvScreen({super.key, this.isActive = true});

  @override
  State<CctvScreen> createState() => _CctvScreenState();
}

// ---------------------------------------------------------------------
// Isolate-safe params/result + entry point for the Hikvision SDK login
// call. Top level because Isolate.run needs a plain function and the data
// crossing the isolate boundary must be simple/serializable. Offloads the
// blocking FFI call (sdk.login) off the UI isolate so the loading dialog
// paints smoothly.
// ---------------------------------------------------------------------
class _SdkLookupParams {
  final String ip;
  final int sdkPort;
  final String username;
  final String password;
  const _SdkLookupParams(this.ip, this.sdkPort, this.username, this.password);
}

class _SdkLookupResult {
  final String? serialNumber;
  final int? channelNum;
  final int? ipChannelNum;
  final String? error;
  const _SdkLookupResult({
    this.serialNumber,
    this.channelNum,
    this.ipChannelNum,
    this.error,
  });
}

_SdkLookupResult _runHikvisionLookup(_SdkLookupParams p) {
  HikvisionSdk? sdk;
  try {
    sdk = HikvisionSdk();
    final result = sdk.login(
      ip: p.ip,
      username: p.username,
      password: p.password,
      port: p.sdkPort,
    );
    sdk.logout(result.userId);

    if (result.serialNumber.isEmpty) {
      return const _SdkLookupResult(
        error:
            'Logged in successfully, but the camera returned an empty serial number.',
      );
    }
    return _SdkLookupResult(
      serialNumber: result.serialNumber,
      channelNum: result.channelNum,
      ipChannelNum: result.ipChannelNum,
    );
  } catch (e) {
    return _SdkLookupResult(error: e.toString());
  } finally {
    try {
      sdk?.cleanup();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Shared helpers / small widgets (private to this file)
// ---------------------------------------------------------------------------

const List<String> _kStatusOptions = ['Online', 'Offline'];

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
      return Icons.videocam_off_outlined;
    default:
      return Icons.videocam_outlined;
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

/// Circular camera avatar with a soft status-colored ring.
class _CameraAvatar extends StatelessWidget {
  final String status;
  final double size;
  const _CameraAvatar({required this.status, required this.size});

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
          child: Icon(Icons.videocam_outlined, color: color, size: size * 0.42),
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
          // Plain Container (not AnimatedContainer) so theme switches are
          // followed exactly instead of trailing behind the fade.
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

/// Segmented status filter: one continuous pill, one segment highlighted.
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

class _CameraCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CameraCard({
    required this.data,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_CameraCard> createState() => _CameraCardState();
}

class _CameraCardState extends State<_CameraCard> {
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
    final location = (d['location'] ?? 'N/A').toString();
    final ip = (d['ip_address'] ?? 'N/A').toString();
    final port = (d['port'] ?? '').toString();
    final ipDisplay = port.isEmpty ? ip : '$ip:$port';
    final status = (d['status'] ?? 'Offline').toString();
    final color = _statusColor(context, status);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // Only the hover is animated locally (t: 0 -> 1). Theme colors come
        // from the ThemeExtension on every rebuild, so they follow the theme
        // fade with no key/teardown. The child Column is built once and
        // reused across animation frames.
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
                      child: _CameraAvatar(status: status, size: 60),
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
                    _line(context, Icons.place_outlined, location),
                    const SizedBox(height: 5),
                    _line(context, Icons.lan_outlined, ipDisplay, mono: true),
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

class _CameraRowTile extends StatefulWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CameraRowTile({
    required this.data,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_CameraRowTile> createState() => _CameraRowTileState();
}

class _CameraRowTileState extends State<_CameraRowTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final name = (d['name'] ?? 'Unnamed').toString();
    final location = (d['location'] ?? 'N/A').toString();
    final ip = (d['ip_address'] ?? 'N/A').toString();
    final port = (d['port'] ?? '').toString();
    final ipDisplay = port.isEmpty ? ip : '$ip:$port';
    final status = (d['status'] ?? 'Offline').toString();
    final hasPin = d['latitude'] is num && d['longitude'] is num;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // Plain Container so the row follows the theme fade directly.
        child: Container(
          color: AppColors.sunken(context).withOpacity(_hover ? 1 : 0),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    _CameraAvatar(status: status, size: 38),
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
                            location,
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

class _CctvScreenState extends State<CctvScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  late final Stream<List<Map<String, dynamic>>> _cctvStream;
  final CameraDiscoveryService _discoveryService = CameraDiscoveryService();
  final SupabaseClient _supabase = Supabase.instance.client;

  Map<String, dynamic>? _selectedCamera;
  String _searchQuery = '';
  String? _statusFilter; // null = all statuses
  bool _gridView = false;

  // null (closed), 'view', 'add', 'edit'
  String? _rightPanelMode;
  // Remembers the last open mode so the modal keeps its content while it
  // animates closed.
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
  final _ipAddressController = TextEditingController();
  final _portController = TextEditingController(text: '554');
  final _sdkPortController = TextEditingController(text: '8000');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _locationController = TextEditingController();

  bool _obscurePassword = true;

  double? _selectedLat;
  double? _selectedLng;

  // Snapshot of the values when Edit opened — for dirty checking.
  String _originalName = '';
  String _originalLocation = '';
  String _originalIpAddress = '';
  String _originalPort = '';
  String _originalSdkPort = '';
  String _originalUsername = '';
  String _originalPassword = '';
  double? _originalLat;
  double? _originalLng;

  // Inline map picker state (swaps in place of the form inside the modal).
  bool _isPickingLocationInline = false;
  LatLng? _inlinePickedPoint;

  bool _isSaving = false;
  bool _isDeleting = false;
  bool _isScanning = false;

  // PDF export in progress (disables the Export button + shows a spinner).
  bool _exporting = false;

  bool get _isProcessing => _isSaving || _isDeleting;

  int _currentPage = 0;
  static const int _camerasPerPage = 50;

  // -------------------------------------------------------------------
  // Derived-data cache.
  //
  // build() reruns on every frame of the theme fade (AppColors reads the
  // Theme). Copying rows, counting statuses and filtering on each of those
  // frames is wasted work, so the results are cached and only recomputed
  // when the stream data or a filter actually changes.
  // -------------------------------------------------------------------
  List<Map<String, dynamic>>? _srcData;
  List<Map<String, dynamic>> _all = const [];
  Map<String, int> _counts = const {};
  String? _filterKey;
  List<Map<String, dynamic>> _filtered = const [];

  // --- HEALTH MONITOR ---
  Timer? _healthCheckTimer;
  bool _healthCheckRunning = false;
  static const Duration _healthCheckInterval = Duration(seconds: 45);
  static const Duration _healthCheckSadpTimeout = Duration(seconds: 6);

  // --- HIKVISION SDK DEVICE INFO ---
  String? _fetchedSerialNumber;
  int? _fetchedChannelNum;
  int? _fetchedIpChannelNum;
  bool _serialLookupFailed = false;
  String? _serialLookupErrorMessage;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant CctvScreen oldWidget) {
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
    _cctvStream = _supabase
        .from('cameras')
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
    _ipAddressController.dispose();
    _portController.dispose();
    _sdkPortController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _locationController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _clearForm() {
    _nameController.clear();
    _ipAddressController.clear();
    _portController.text = '554';
    _sdkPortController.text = '8000';
    _usernameController.clear();
    _passwordController.clear();
    _locationController.clear();
    _obscurePassword = true;
    _selectedLat = null;
    _selectedLng = null;
    _isPickingLocationInline = false;
    _inlinePickedPoint = null;
    _fetchedSerialNumber = null;
    _fetchedChannelNum = null;
    _fetchedIpChannelNum = null;
    _serialLookupFailed = false;
    _serialLookupErrorMessage = null;
  }

  void _populateEditForm(Map<String, dynamic> camera) {
    _nameController.text = camera['name'] ?? '';
    _ipAddressController.text = camera['ip_address'] ?? '';
    _portController.text = camera['port'] ?? '554';
    _sdkPortController.text = (camera['sdk_port'] ?? '8000').toString();
    _usernameController.text = camera['username'] ?? '';
    _passwordController.text = camera['password'] ?? '';
    _locationController.text = camera['location'] ?? '';
    _obscurePassword = true;
    final lat = camera['latitude'];
    final lng = camera['longitude'];
    _selectedLat = (lat is num) ? lat.toDouble() : null;
    _selectedLng = (lng is num) ? lng.toDouble() : null;
    _isPickingLocationInline = false;
    _inlinePickedPoint = null;
    _fetchedSerialNumber = (camera['serial_number'] as String?);
    _fetchedChannelNum = camera['channel_num'] as int?;
    _fetchedIpChannelNum = camera['ip_channel_num'] as int?;
    _serialLookupErrorMessage = (camera['serial_lookup_error'] as String?);
    _serialLookupFailed = _serialLookupErrorMessage != null &&
        _serialLookupErrorMessage!.isNotEmpty;

    _originalName = _nameController.text.trim();
    _originalLocation = _locationController.text.trim();
    _originalIpAddress = _ipAddressController.text.trim();
    _originalPort = _portController.text.trim();
    _originalSdkPort = _sdkPortController.text.trim();
    _originalUsername = _usernameController.text.trim();
    _originalPassword = _passwordController.text;
    _originalLat = _selectedLat;
    _originalLng = _selectedLng;
  }

  bool _hasEditChanges() {
    if (_nameController.text.trim() != _originalName) return true;
    if (_locationController.text.trim() != _originalLocation) return true;
    if (_ipAddressController.text.trim() != _originalIpAddress) return true;
    if (_portController.text.trim() != _originalPort) return true;
    if (_sdkPortController.text.trim() != _originalSdkPort) return true;
    if (_usernameController.text.trim() != _originalUsername) return true;
    if (_passwordController.text != _originalPassword) return true;
    if (_selectedLat != _originalLat) return true;
    if (_selectedLng != _originalLng) return true;
    return false;
  }

  bool _canCreate() {
    if (_nameController.text.trim().isEmpty) return false;
    if (_locationController.text.trim().isEmpty) return false;
    if (_ipAddressController.text.trim().isEmpty) return false;
    if (_portController.text.trim().isEmpty) return false;
    if (_sdkPortController.text.trim().isEmpty) return false;
    if (_usernameController.text.trim().isEmpty) return false;
    if (_passwordController.text.isEmpty) return false;
    return true;
  }

  String _buildStreamUrl() {
    final ip = _ipAddressController.text.trim();
    final port = _portController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    return 'rtsp://$username:$password@$ip:$port/Streaming/Channels/101';
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

  Future<bool> _isCameraReachable(String ip, int port) async {
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

  // -----------------------------------------------------------------------
  // PDF EXPORT
  // -----------------------------------------------------------------------

  /// Name + role of whoever is signed in (the person exporting).
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
    } catch (_) {
      // fall through to the email fallback
    }
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

  /// Exports the cameras currently shown (filters applied) as a portrait PDF
  /// and downloads it immediately — no print dialog.
  Future<void> _exportPdf(List<Map<String, dynamic>> rows) async {
    if (_exporting || rows.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final me = await _currentExporter();
      final bytes = await _buildCamerasPdf(rows, exportedBy: me.name, exportedRole: me.role);
      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await FileSaver.instance.saveFile(
        name: 'safewatch_cameras_$stamp',
        bytes: bytes,
        ext: 'pdf',
        mimeType: MimeType.pdf,
      );
      if (!mounted) return;
      AppToast.success(
          context, 'Downloaded ${rows.length} camera${rows.length == 1 ? '' : 's'} as PDF');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Could not export PDF: $e');
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
  /// counts, filters) and then one simple bordered table. Credentials
  /// (username / password / stream URL) are deliberately left out.
  Future<Uint8List> _buildCamerasPdf(
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
        .where((r) => (r['status'] ?? '').toString().toUpperCase() == s.toUpperCase())
        .length;
    final online = countStatus('Online');
    final offline = countStatus('Offline');
    final pinned =
        rows.where((r) => r['latitude'] is num && r['longitude'] is num).length;

    final filters = <String>[
      if (_statusFilter != null) 'Status: $_statusFilter',
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
                      fontSize: 6.5,
                      fontWeight: pw.FontWeight.bold,
                      color: muted,
                      letterSpacing: 0.6)),
              pw.SizedBox(height: 2),
              pw.Text(t(value),
                  style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: ink)),
            ],
          ),
        );

    final data = <List<String>>[
      for (var i = 0; i < rows.length; i++)
        () {
          final c = rows[i];
          final ip = (c['ip_address'] ?? '-').toString();
          final port = (c['port'] ?? '').toString();
          final hasPin = c['latitude'] is num && c['longitude'] is num;
          final status = (c['status'] ?? '-').toString();
          return <String>[
            '${i + 1}',
            t((c['name'] ?? 'Unnamed').toString()),
            t((c['location'] ?? '-').toString()),
            port.isEmpty ? ip : '$ip:$port',
            status == '-' ? '-' : _titleCase(status),
            hasPin ? 'Pinned' : 'No pin',
          ];
        }(),
    ];

    final doc = pw.Document(title: 'SafeWatch CCTV Cameras', author: 'SafeWatch');

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(t('SafeWatch  |  CCTV Cameras  |  Exported by $exportedBy'),
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
                decoration:
                    pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(2)),
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
                    pw.Text('CCTV Cameras',
                        style: pw.TextStyle(
                            fontSize: 20, fontWeight: pw.FontWeight.bold, color: ink)),
                    pw.SizedBox(height: 2),
                    pw.Text('Camera status, locations and network details',
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
                      info('Total cameras', '${rows.length}'),
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
                          filters.isEmpty ? 'None (all cameras)' : filters.join(', ')),
                    ],
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          // --- Table ---
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Camera', 'Location', 'IP Address', 'Status', 'Map Pin'],
            data: data,
            headerStyle: pw.TextStyle(
                fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: pw.BoxDecoration(color: accent),
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
              2: const pw.FlexColumnWidth(1.9),
              3: const pw.FlexColumnWidth(1.5),
              4: const pw.FlexColumnWidth(0.9),
              5: const pw.FlexColumnWidth(0.9),
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

  /// One health-check pass over every saved camera: SADP discovery indexed
  /// by serial number, IP-drift correction on a match, and a TCP probe
  /// fallback for cameras with no serial / no SADP reply. Writes only when
  /// the status or IP actually changed. Any legacy 'Maintenance' rows are
  /// normalized to Online/Offline here on the next pass.
  Future<void> _runHealthCheckPass() async {
    if (!mounted || _healthCheckRunning) return;
    _healthCheckRunning = true;

    try {
      List<Map<String, dynamic>> cameras;
      try {
        cameras = await _supabase.from('cameras').select();
      } catch (e) {
        debugPrint('Health check: failed to load cameras — $e');
        return;
      }
      if (cameras.isEmpty) return;

      List<DiscoveredCamera> discovered;
      try {
        discovered = await _discoveryService.discoverSadpCameras(
          timeout: _healthCheckSadpTimeout,
        );
      } catch (e) {
        debugPrint('Health check: SADP discovery failed — $e');
        discovered = const [];
      }

      final bySerial = <String, DiscoveredCamera>{
        for (final d in discovered)
          if (d.serialNumber != null && d.serialNumber!.isNotEmpty)
            d.serialNumber!: d,
      };

      for (final row in cameras) {
        if (!mounted) return;
        final id = row['id'];
        if (id == null) continue;

        final storedSerial = (row['serial_number'] as String?)?.trim();
        final storedIp = (row['ip_address'] as String?)?.trim() ?? '';
        final storedPort = int.tryParse((row['port'] as String?)?.trim() ?? '');

        final match = (storedSerial != null && storedSerial.isNotEmpty)
            ? bySerial[storedSerial]
            : null;

        String newStatus;
        String? newIp;

        if (match != null) {
          newStatus = match.crossSubnet ? 'Offline' : 'Online';
          if (match.ip != storedIp) {
            newIp = match.ip;
            debugPrint(
                'Health check: camera $id IP drifted "$storedIp" -> "${match.ip}" (matched by serial $storedSerial)');
          }
        } else {
          final reachable = (storedIp.isNotEmpty && storedPort != null)
              ? await _isCameraReachable(storedIp, storedPort)
              : false;
          newStatus = reachable ? 'Online' : 'Offline';
        }

        final currentStatus = (row['status'] as String?) ?? '';
        if (newStatus == currentStatus && newIp == null) {
          continue;
        }

        try {
          await _supabase.from('cameras').update({
            'status': newStatus,
            if (newIp != null) 'ip_address': newIp,
          }).eq('id', id);

          final cameraName = (row['name'] as String?)?.trim();
          final label = (cameraName != null && cameraName.isNotEmpty)
              ? cameraName
              : 'Camera $id';
          await ActivityLogger.logSystem(
            action: 'CCTV_STATUS_CHANGE',
            details:
                'Camera "$label" was checked automatically by the health monitor',
            systemLabel: 'System (Health Monitor)',
            changes: [
              LogChange(
                field: 'Status',
                from: currentStatus.isEmpty ? 'Unknown' : currentStatus,
                to: newStatus,
              ),
              if (newIp != null)
                LogChange(field: 'IP Address', from: storedIp, to: newIp),
            ],
            metadata: {
              'camera_id': id,
              'matched_by':
                  match != null ? 'serial number (SADP)' : 'TCP probe',
            },
          );
        } catch (e) {
          debugPrint('Health check: failed to update camera $id — $e');
        }
      }
    } finally {
      _healthCheckRunning = false;
    }
  }

  // -----------------------------------------------------------------------
  // HIKVISION SDK DEVICE INFO
  // -----------------------------------------------------------------------

  Future<void> _lookupDeviceInfoViaSdk() async {
    _serialLookupFailed = false;
    _serialLookupErrorMessage = null;

    if (!Platform.isWindows) {
      _serialLookupFailed = true;
      _serialLookupErrorMessage =
          'Serial lookup needs the Hikvision SDK, which only runs on Windows.';
      return;
    }

    final ip = _ipAddressController.text.trim();
    final sdkPort = int.tryParse(_sdkPortController.text.trim());
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    if (ip.isEmpty || sdkPort == null || username.isEmpty || password.isEmpty) {
      _serialLookupFailed = true;
      _serialLookupErrorMessage =
          'Missing IP address, SDK port, username, or password.';
      return;
    }

    // Runs on a short-lived worker isolate so the blocking FFI login call
    // never freezes UI painting.
    final result = await Isolate.run(
      () => _runHikvisionLookup(
        _SdkLookupParams(ip, sdkPort, username, password),
      ),
    );

    if (result.error != null) {
      _serialLookupFailed = true;
      _serialLookupErrorMessage = result.error;
      debugPrint(
          'Hikvision SDK serial lookup failed for $ip:$sdkPort — ${result.error}');
      return;
    }
    _fetchedSerialNumber = result.serialNumber;
    _fetchedChannelNum = result.channelNum;
    _fetchedIpChannelNum = result.ipChannelNum;
  }

  // -----------------------------------------------------------------------
  // NETWORK CAMERA DISCOVERY
  // -----------------------------------------------------------------------

  Future<void> _runNetworkScanFromToolbar() async {
    setState(() => _isScanning = true);
    try {
      final results = await _discoveryService.discoverAll();
      if (!mounted) return;

      if (results.isEmpty) {
        AppToast.info(
            context,
            'No cameras found on this network. Make sure the camera '
            'and this device are on the same Wi-Fi/LAN.');
        return;
      }

      final picked = await _showDiscoveryResultsSheet(results, returnPick: true);
      if (picked == null || !mounted) return;

      if (picked.crossSubnet) {
        final proceed = await _showCrossSubnetWarning(picked);
        if (!proceed || !mounted) return;
      }

      _clearForm();
      _ipAddressController.text = picked.ip;
      if (picked.source == DiscoverySource.portScan) {
        _portController.text = picked.port.toString();
      }
      setState(() {
        _selectedCamera = null;
        _rightPanelMode = 'add';
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<bool> _showCrossSubnetWarning(DiscoveredCamera device) async {
    RoundedRectangleBorder dialogShape() => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.border(context)),
        );
    TextStyle cancelStyle() =>
        TextStyle(color: AppColors.textMuted(context), fontSize: 12);
    Text dialogTitle() => Text(
          'Camera is on a different network',
          style: TextStyle(
              color: AppColors.textMain(context),
              fontSize: 15,
              fontWeight: FontWeight.bold),
        );

    if (Platform.isWindows) {
      final choice = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.card(context),
          shape: dialogShape(),
          title: dialogTitle(),
          content: Text(
            '${device.ip} was found but isn\'t reachable from this network '
            'yet. This device can add a secondary IP to your network '
            'adapter so it can reach ${device.ip} directly.',
            style: TextStyle(
                color: AppColors.textMuted(context), fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('cancel'),
              child: Text('CANCEL', style: cancelStyle()),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('skip'),
              child: Text('ADD WITHOUT FIXING', style: cancelStyle()),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop('fix'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('FIX NETWORK & CONTINUE',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (choice == null || choice == 'cancel') return false;
      if (choice == 'skip') return true;
      return _attemptCrossSubnetFix(device);
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.card(context),
        shape: dialogShape(),
        title: dialogTitle(),
        content: Text(
          '${device.ip} was found but isn\'t on the same subnet as this device.',
          style: TextStyle(
              color: AppColors.textMuted(context), fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('CANCEL', style: cancelStyle()),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('CONTINUE ANYWAY',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _attemptCrossSubnetFix(DiscoveredCamera device) async {
    _showBlockingLoader('Fixing network access to ${device.ip}...');
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isEmpty) {
        if (mounted) {
          AppToast.error(context, 'No active network adapter found to fix.');
        }
        return false;
      }

      final iface = interfaces.first;
      final secondaryIp = _discoveryService.suggestSecondaryIp(device.ip);

      final added = await _discoveryService.addWindowsSecondaryIp(
        interfaceName: iface.name,
        secondaryIp: secondaryIp,
      );

      if (!added) {
        if (mounted) {
          AppToast.error(
              context,
              'Couldn\'t add the secondary IP automatically — try running '
              'this app as Administrator.');
        }
        return false;
      }

      await Future.delayed(const Duration(milliseconds: 800));
      final reachable = await _isCameraReachable(device.ip, device.port);

      if (mounted) {
        if (reachable) {
          AppToast.success(
              context, 'Network fixed — ${device.ip} is now reachable.');
        } else {
          AppToast.error(context,
              'Secondary IP added, but ${device.ip} still isn\'t responding.');
        }
      }
      return true;
    } finally {
      _hideBlockingLoader();
    }
  }

  Future<DiscoveredCamera?> _showDiscoveryResultsSheet(
      List<DiscoveredCamera> results,
      {bool returnPick = false}) async {
    final picked = await showModalBottomSheet<DiscoveredCamera>(
      context: context,
      backgroundColor: AppColors.card(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cameras found on your network',
                  style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap a device to fill in its IP address and port.',
                  style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 12,
                      height: 1.4),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: results.length,
                    separatorBuilder: (_, __) =>
                        Divider(color: AppColors.border(context), height: 1),
                    itemBuilder: (context, index) {
                      final device = results[index];
                      final isOnvif = device.source == DiscoverySource.onvif;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: isOnvif
                              ? AppColors.accentBlue.withOpacity(0.15)
                              : AppColors.textMuted(context).withOpacity(0.15),
                          child: Icon(
                            Icons.videocam_outlined,
                            size: 18,
                            color: isOnvif
                                ? AppColors.accentBlue
                                : AppColors.textMuted(context),
                          ),
                        ),
                        title: Text(
                          '${device.ip}:${device.port}',
                          style: TextStyle(
                            color: AppColors.textMain(context),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                        subtitle: Row(
                          children: [
                            Text(
                              device.label,
                              style: TextStyle(
                                color: isOnvif
                                    ? AppColors.accentBlue
                                    : AppColors.textMuted(context),
                                fontSize: 11,
                              ),
                            ),
                            if (device.crossSubnet) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.orangeAccent.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'DIFFERENT NETWORK',
                                  style: TextStyle(
                                    color: Colors.orangeAccent,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        onTap: () => Navigator.of(sheetContext).pop(device),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (picked != null && !returnPick) {
      setState(() {
        _ipAddressController.text = picked.ip;
        if (picked.source == DiscoverySource.portScan) {
          _portController.text = picked.port.toString();
        }
      });
    }
    return picked;
  }

  // -----------------------------------------------------------------------
  // BUILD
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncModalOverlay());

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cctvStream,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData;
        final error = snapshot.error;

        // Recompute derived data only when the stream emitted a new list.
        // During a theme fade the same list instance comes back every
        // frame, so all of this is skipped.
        final data = snapshot.data ?? const <Map<String, dynamic>>[];
        if (!identical(data, _srcData)) {
          _srcData = data;
          _filterKey = null; // force a refilter
          _all = data.map((r) => Map<String, dynamic>.from(r)).toList();

          final counts = <String, int>{
            for (final s in _kStatusOptions) s.toUpperCase(): 0,
          };
          for (final c in _all) {
            final key = (c['status'] ?? '').toString().toUpperCase();
            if (counts.containsKey(key)) counts[key] = counts[key]! + 1;
          }
          _counts = counts;
        }
        final all = _all;
        final counts = _counts;

        // Refilter only when the search text or status filter changes.
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
              row['location'],
              row['ip_address'],
              row['serial_number'],
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
                'CCTV Cameras',
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Monitor camera status, locations and network details',
                style: TextStyle(
                    color: AppColors.textMuted(context), fontSize: 13),
              ),
            ],
          ),
        ),
        _HoverPop(
          enabled: !_isScanning,
          child: SizedBox(
            height: 40,
            child: OutlinedButton.icon(
              onPressed: _isScanning ? null : _runNetworkScanFromToolbar,
              icon: _isScanning
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          color: AppColors.textMuted(context), strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_find_outlined, size: 17),
              label: Text(
                _isScanning ? 'Scanning...' : 'Scan for Cameras',
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
                  _selectedCamera = null;
                  _rightPanelMode = 'add';
                });
              },
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add Camera',
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
        label: 'Total cameras',
        value: total,
        caption: 'All statuses',
        icon: Icons.videocam_outlined,
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
              hintText: 'Search name, location, IP…',
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
              ? 'No cameras to export'
              : 'Export ${filtered.length} camera${filtered.length == 1 ? '' : 's'} as PDF',
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
          Icons.error_outline_rounded, 'Error loading cameras: $error'));
    }
    if (all.isEmpty) {
      return shell(message(Icons.videocam_off_outlined, 'No cameras found.'));
    }
    if (filtered.isEmpty) {
      return shell(
          message(Icons.search_off_rounded, 'No cameras match your filters.'));
    }

    final totalPages = (filtered.length / _camerasPerPage).ceil();
    final safePage = _currentPage >= totalPages ? totalPages - 1 : _currentPage;
    if (safePage != _currentPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _currentPage = safePage);
      });
    }
    final pageStart = safePage * _camerasPerPage;
    final pageEnd = (pageStart + _camerasPerPage).clamp(0, filtered.length);
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
                  _headerCell('CAMERA', 5),
                  _headerCell('IP ADDRESS', 3),
                  _headerCell('STATUS', 3),
                  _headerCell('MAP PIN', 2),
                  const SizedBox(width: 96),
                ],
              ),
            ),
            Divider(color: AppColors.border(context), height: 1, thickness: 1),
          ],
          Expanded(
            child:
                _gridView ? _buildCameraGrid(pageDocs) : _buildCameraList(pageDocs),
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
      _selectedCamera = data;
      _rightPanelMode = 'view';
    });
  }

  void _openEdit(Map<String, dynamic> data) {
    _populateEditForm(data);
    setState(() {
      _selectedCamera = data;
      _rightPanelMode = 'edit';
    });
  }

  void _openDelete(Map<String, dynamic> data) {
    setState(() => _selectedCamera = data);
    _showDeleteConfirmDialog();
  }

  Widget _buildCameraGrid(List<Map<String, dynamic>> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 250,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        mainAxisExtent: 232,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final data = items[index];
        return _CameraCard(
          data: data,
          onTap: () => _openView(data),
          onEdit: () => _openEdit(data),
          onDelete: () => _openDelete(data),
        );
      },
    );
  }

  Widget _buildCameraList(List<Map<String, dynamic>> items) {
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
      itemBuilder: (context, index) {
        final data = items[index];
        return _CameraRowTile(
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
              border:
                  isCurrent ? null : Border.all(color: AppColors.border(context)),
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
              style:
                  TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
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

    // Keep the confirm dialog in step with theme changes. Its AnimatedBuilder
    // only ticks during the fade-in, so without this it would keep stale
    // colors if the theme flips while it's open. Runs before any early
    // return so it also covers "only the confirm dialog is open".
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
      content = _selectedCamera == null
          ? const SizedBox.shrink()
          : _buildDetailsModal(_selectedCamera!);
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
                final t =
                    Curves.easeOutCubic.transform(_modalAnim.value.clamp(0.0, 1.0));
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
                    // Swallow taps so they don't reach the scrim.
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

  /// Section title + fields laid out two per row (`full` fields get a row).
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

  /// Label above value. Optional leading icon and copy button.
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

  Widget _buildDetailsModal(Map<String, dynamic> camera) {
    final name = (camera['name'] ?? 'Unnamed Camera').toString();
    final location = (camera['location'] ?? '').toString().trim();
    final ipAddress = (camera['ip_address'] ?? '').toString().trim();
    final port = (camera['port'] ?? '').toString().trim();
    final sdkPort = (camera['sdk_port'] ?? '').toString().trim();
    final username = (camera['username'] ?? '').toString().trim();
    final status = (camera['status'] ?? 'Offline').toString();
    final createdAt = _formatTimestamp(camera['created_at']);
    final serialNumber = (camera['serial_number'] as String?)?.trim() ?? '';
    final hasSerial = serialNumber.isNotEmpty;
    final lookupError = (camera['serial_lookup_error'] as String?)?.trim();
    final camLat = camera['latitude'];
    final camLng = camera['longitude'];
    final hasMapPin = camLat is num && camLng is num;
    final mapPinDisplay = hasMapPin
        ? '${camLat.toStringAsFixed(6)}, ${camLng.toStringAsFixed(6)}'
        : '';
    final color = _statusColor(context, status);

    Widget pane() {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailSection('LOCATION', Icons.place_outlined, [
              _detailField('LOCATION/STREET NAME', location,
                  icon: Icons.place_outlined, full: true),
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
            _detailSection('NETWORK', Icons.lan_outlined, [
              _detailField('IP ADDRESS', ipAddress,
                  copyable: true, copyLabel: 'IP address', mono: true),
              _detailField('RTSP PORT', port, mono: true),
              _detailField('SDK PORT', sdkPort, mono: true),
              _detailField('USERNAME', username),
            ]),
            const SizedBox(height: 22),
            _detailSection('DEVICE', Icons.memory_outlined, [
              _detailField('SERIAL NUMBER', serialNumber,
                  copyable: hasSerial,
                  copyLabel: 'Serial number',
                  mono: true,
                  full: true),
              _detailField('STATUS', status.toUpperCase(),
                  icon: _statusIcon(status), iconColor: color),
              _detailField('ADDED ON', createdAt),
              if (!hasSerial)
                _DetailFieldMarker(
                  full: true,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.sunken(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline,
                            size: 14, color: AppColors.textMuted(context)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            (lookupError != null && lookupError.isNotEmpty)
                                ? 'Serial number not available — $lookupError'
                                : 'Serial number not available — the device '
                                    'wasn\'t reachable via the Hikvision SDK '
                                    'when this camera was last saved.',
                            style: TextStyle(
                              color: AppColors.textMuted(context),
                              fontSize: 11.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ]),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header: small avatar + name + location + status
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
          child: Row(
            children: [
              _CameraAvatar(status: status, size: 44),
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
                      location.isEmpty ? 'No location set' : location,
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

        // Body
        Flexible(child: SingleChildScrollView(child: pane())),

        // Footer
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
                    _populateEditForm(camera);
                    setState(() => _rightPanelMode = 'edit');
                  },
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  style: _footerButtonStyle(
                      bg: AppColors.accentBlue, fg: Colors.white),
                  label: const Text('EDIT CAMERA',
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
    final selected = _selectedCamera;
    final headerName = isEditMode && selected != null
        ? (selected['name'] ?? 'Unnamed Camera').toString()
        : 'New camera';
    final editStatus = (selected?['status'] ?? 'Offline').toString();
    final size = MediaQuery.of(context).size;
    final mapHeight = (size.height - 300).clamp(300.0, 520.0);

    Widget field(Widget child, {bool full = false}) =>
        _DetailFieldMarker(full: full, child: child);

    // ---- Form body (single column of sections) ----
    Widget fields() {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailSection('GENERAL', Icons.videocam_outlined, [
              field(_buildInputField('CAMERA NAME', _nameController, 'Gate 2 Cam',
                  isRequired: true,
                  validator: (v) => _requiredValidator(v, 'Camera name'))),
              field(_buildInputField('LOCATION/STREET NAME', _locationController,
                  'Barangay Hall Entrance',
                  isRequired: true,
                  validator: (v) => _requiredValidator(v, 'Location'))),
            ]),
            const SizedBox(height: 22),
            _detailSection('MAP LOCATION', Icons.map_outlined, [
              field(_buildLocationPickerField(), full: true),
            ]),
            const SizedBox(height: 22),
            _detailSection('NETWORK', Icons.lan_outlined, [
              field(_buildInputField('IP ADDRESS', _ipAddressController,
                  '192.168.1.45',
                  isRequired: true,
                  keyboardType: TextInputType.number,
                  validator: _ipAddressValidator)),
              field(_buildInputField('RTSP PORT', _portController, '554',
                  isRequired: true,
                  keyboardType: TextInputType.number,
                  validator: _portValidator)),
              field(_buildInputField('SDK PORT', _sdkPortController, '8000',
                  isRequired: true,
                  keyboardType: TextInputType.number,
                  validator: _portValidator)),
              field(Padding(
                padding: const EdgeInsets.only(top: 22),
                child: Text(
                  'Used only to read the serial number via the Hikvision SDK '
                  '(Windows only) — usually 8000.',
                  style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              )),
            ]),
            const SizedBox(height: 22),
            _detailSection('ACCESS', Icons.lock_outline, [
              field(_buildInputField('USERNAME', _usernameController, 'admin',
                  isRequired: true,
                  validator: (v) => _requiredValidator(v, 'Username'))),
              field(_buildPasswordField()),
            ]),
            const SizedBox(height: 22),
            _detailSection('DEVICE', Icons.memory_outlined, [
              field(_buildSerialPreviewBox(), full: true),
            ]),
          ],
        ),
      );
    }

    // ---- Footers (keyed so Flutter remounts instead of lerping styles) ----
    Widget formFooter() {
      return Row(
        children: [
          if (isEditMode)
            _HoverPop(
              child: TextButton.icon(
                onPressed: _showDeleteConfirmDialogFromPanel,
                icon: const Icon(Icons.delete_outline,
                    size: 17, color: AppColors.accentRed),
                label: const Text('Remove camera',
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
              _locationController,
              _ipAddressController,
              _portController,
              _sdkPortController,
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
                          await _handleSaveCamera(isEditMode: isEditMode);
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
                      : Text(isEditMode ? 'SAVE CHANGES' : 'ADD CAMERA',
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
        // Title bar
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
                _CameraAvatar(status: editStatus, size: 40)
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
                          ? 'Set camera location'
                          : (isEditMode ? 'Edit camera' : 'Add new camera'),
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
                              : 'Register a camera on your network'),
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

        // Body: form, or the inline map picker
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

        // Footer
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
                      : 'Drop a pin so this camera shows up on the Tanod Location map.',
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

  // --- INLINE MAP LOCATION PICKER ---

  static const LatLng _mapDefaultCenter = LatLng(14.6837, 121.0766);

  static const List<LatLng> _mapMaskOuterRing = [
    LatLng(-85, -180),
    LatLng(-85, 180),
    LatLng(85, 180),
    LatLng(85, -180),
  ];
  static const Color _mapBoundaryColor = Color(0xFF10B981);

  // Cached map layers. The modal rebuilds on every theme-fade frame while it
  // is open; reusing the same widget instances lets Flutter skip
  // reprocessing the tile layer and the barangay mask (a polygon with a
  // hole) each time. Neither layer depends on the theme.
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
                  style:
                      TextStyle(color: AppColors.textMuted(context), fontSize: 12),
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

  Widget _buildSerialPreviewBox() {
    final serial = _fetchedSerialNumber;
    final hasSerial = serial != null && serial.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
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
              Icon(Icons.badge_outlined,
                  color: AppColors.textMuted(context), size: 14),
              const SizedBox(width: 6),
              Text(
                'SERIAL NUMBER',
                style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            hasSerial
                ? serial
                : (_serialLookupErrorMessage != null &&
                        _serialLookupErrorMessage!.isNotEmpty)
                    ? _serialLookupErrorMessage!
                    : 'Read automatically from the camera when you save '
                        '(Windows only, requires the SDK port). Status is '
                        'also set automatically.',
            style: TextStyle(
              color: hasSerial
                  ? AppColors.textMain(context)
                  : (_serialLookupFailed
                      ? AppColors.accentRed
                      : AppColors.textMuted(context)),
              fontSize: hasSerial ? 12.5 : 11,
              fontFamily: hasSerial ? 'monospace' : null,
              height: 1.35,
            ),
          ),
        ],
      ),
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

  Future<void> _handleSaveCamera({required bool isEditMode}) async {
    setState(() => _isSaving = true);
    _showBlockingLoader(isEditMode ? 'Saving changes...' : 'Adding camera...');
    try {
      final newName = _nameController.text.trim();
      final newLocation = _locationController.text.trim();
      final newIpAddress = _ipAddressController.text.trim();
      final newPort = _portController.text.trim();
      final newSdkPort = _sdkPortController.text.trim();
      final newUsername = _usernameController.text.trim();
      final newPassword = _passwordController.text.trim();
      final newStreamUrl = _buildStreamUrl();
      final newLat = _selectedLat;
      final newLng = _selectedLng;

      String resolvedStatus = 'Offline';
      final portForCheck = int.tryParse(newPort);
      if (portForCheck != null && newIpAddress.isNotEmpty) {
        final reachable = await _isCameraReachable(newIpAddress, portForCheck);
        resolvedStatus = reachable ? 'Online' : 'Offline';
      }

      await _lookupDeviceInfoViaSdk();

      final cameraData = {
        'name': newName,
        'location': newLocation,
        'ip_address': newIpAddress,
        'port': newPort,
        'sdk_port': newSdkPort,
        'username': newUsername,
        'password': newPassword,
        'stream_url': newStreamUrl,
        'status': resolvedStatus,
        'latitude': newLat,
        'longitude': newLng,
        if (_fetchedSerialNumber != null) 'serial_number': _fetchedSerialNumber,
        if (_fetchedChannelNum != null) 'channel_num': _fetchedChannelNum,
        if (_fetchedIpChannelNum != null)
          'ip_channel_num': _fetchedIpChannelNum,
        'serial_lookup_error': _serialLookupErrorMessage,
      };

      if (isEditMode) {
        final camId = _selectedCamera?['id'];
        if (camId != null) {
          final oldName = (_selectedCamera?['name'] ?? '').toString();
          final oldLocation = (_selectedCamera?['location'] ?? '').toString();
          final oldIpAddress = (_selectedCamera?['ip_address'] ?? '').toString();
          final oldPort = (_selectedCamera?['port'] ?? '').toString();
          final oldSdkPort = (_selectedCamera?['sdk_port'] ?? '').toString();
          final oldUsername = (_selectedCamera?['username'] ?? '').toString();
          final oldPassword = (_selectedCamera?['password'] ?? '').toString();
          final oldStatus = (_selectedCamera?['status'] ?? '').toString();
          final oldLatRaw = _selectedCamera?['latitude'];
          final oldLngRaw = _selectedCamera?['longitude'];
          final oldLat = (oldLatRaw is num) ? oldLatRaw.toDouble() : null;
          final oldLng = (oldLngRaw is num) ? oldLngRaw.toDouble() : null;
          final oldPin = _formatPin(oldLat, oldLng);
          final newPin = _formatPin(newLat, newLng);

          final updated = await _supabase
              .from('cameras')
              .update(cameraData)
              .eq('id', camId)
              .select(); // [] if RLS blocked the write

          if (updated.isEmpty) {
            throw Exception(
              "You don't have permission to update this camera.",
            );
          }

          final changes = <LogChange>[
            if (oldName != newName)
              LogChange(field: 'Name', from: oldName, to: newName),
            if (oldLocation != newLocation)
              LogChange(field: 'Location', from: oldLocation, to: newLocation),
            if (oldIpAddress != newIpAddress)
              LogChange(
                  field: 'IP Address', from: oldIpAddress, to: newIpAddress),
            if (oldPort != newPort)
              LogChange(field: 'RTSP Port', from: oldPort, to: newPort),
            if (oldSdkPort != newSdkPort)
              LogChange(field: 'SDK Port', from: oldSdkPort, to: newSdkPort),
            if (oldUsername != newUsername)
              LogChange(field: 'Username', from: oldUsername, to: newUsername),
            if (oldPassword != newPassword)
              const LogChange(
                field: 'Password',
                from: 'Previous password',
                to: 'New password',
              ),
            if (oldStatus.toLowerCase() != resolvedStatus.toLowerCase())
              LogChange(
                field: 'Status',
                from: oldStatus.isEmpty ? 'Unknown' : oldStatus,
                to: resolvedStatus,
              ),
            if (oldPin != newPin)
              LogChange(field: 'Map Location', from: oldPin, to: newPin),
          ];

          await ActivityLogger.log(
            action: 'UPDATE_CCTV',
            details: 'Updated "$newName"',
            changes: changes,
          );

          if (!mounted) return;
          setState(() {
            _selectedCamera = {
              ..._selectedCamera!,
              'name': newName,
              'location': newLocation,
              'ip_address': newIpAddress,
              'port': newPort,
              'sdk_port': newSdkPort,
              'username': newUsername,
              'password': newPassword,
              'stream_url': newStreamUrl,
              'status': resolvedStatus,
              'latitude': newLat,
              'longitude': newLng,
              if (_fetchedSerialNumber != null)
                'serial_number': _fetchedSerialNumber,
              if (_fetchedChannelNum != null) 'channel_num': _fetchedChannelNum,
              if (_fetchedIpChannelNum != null)
                'ip_channel_num': _fetchedIpChannelNum,
              'serial_lookup_error': _serialLookupErrorMessage,
            };
          });

          if (!mounted) return;
          if (_serialLookupFailed) {
            AppToast.error(context,
                'Camera updated (serial number lookup failed — check SDK port/credentials)');
          } else {
            AppToast.success(context, 'Camera updated successfully');
          }
        }
      } else {
        await _supabase.from('cameras').insert(cameraData);

        await ActivityLogger.log(
          action: 'CREATE_CCTV',
          details: 'Added new camera "$newName"',
          metadata: {
            'location': newLocation,
            'ip_address': newIpAddress,
            'status': resolvedStatus,
          },
        );

        if (!mounted) return;
        _clearForm();

        if (!mounted) return;
        if (_serialLookupFailed) {
          AppToast.error(context,
              'Camera added (serial number lookup failed — check SDK port/credentials)');
        } else {
          AppToast.success(context, 'Camera added successfully');
        }
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Error: $e');
      // Reopen the form (data still in the controllers) instead of
      // leaving the user stranded with nothing saved.
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

    // Deferred to a fresh event-loop turn so inserting an interactive
    // overlay from inside a tap callback doesn't trip the mouse tracker's
    // '!_debugDuringDeviceUpdate' assertion on desktop/web.
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

  /// Delete from inside the edit modal. The confirm dialog stacks on top of
  /// the still-open modal; cancelling leaves it untouched.
  Future<void> _showDeleteConfirmDialogFromPanel() => _showDeleteConfirmDialog();

  Future<void> _showDeleteConfirmDialog() async {
    final camId = _selectedCamera?['id'];
    if (camId == null) return;

    final name = (_selectedCamera?['name'] ?? '').toString();
    final status = (_selectedCamera?['status'] ?? '').toString();
    final label = name.trim().isEmpty ? camId.toString() : name.trim();

    final confirmed = await _showActionConfirmDialog(
      title: 'Remove this camera?',
      message:
          'Are you sure you want to remove "$label"? This action cannot be undone.',
      confirmLabel: 'REMOVE',
      confirmColor: AppColors.accentRed,
      icon: Icons.delete_outline,
    );

    if (confirmed) {
      await _handleDeleteCamera(camId: camId, label: label, status: status);
    }
  }

  Future<void> _handleDeleteCamera({
    required dynamic camId,
    required String label,
    required String status,
  }) async {
    setState(() {
      _isDeleting = true;
      _rightPanelMode = null;
      _selectedCamera = null;
    });
    _clearForm();
    _showBlockingLoader('Removing camera...');

    try {
      await _supabase.from('cameras').delete().eq('id', camId);

      await ActivityLogger.log(
        action: 'DELETE_CCTV',
        details: 'Removed camera "$label"',
        changes: [
          LogChange(
            field: 'Status',
            from: status.isEmpty ? 'Unknown' : status,
            to: 'Removed',
          ),
        ],
      );

      if (!mounted) return;
      AppToast.success(context, 'Camera removed successfully');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Failed to remove camera: $e');
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

  Widget _buildInputField(
    String label,
    TextEditingController controller,
    String hint, {
    bool isRequired = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    OutlineInputBorder border(Color color, {double width = 1}) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 11,
                fontWeight: FontWeight.w700,
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
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          validator: validator,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle:
                TextStyle(color: AppColors.textMuted(context), fontSize: 12),
            filled: true,
            fillColor: AppColors.bg(context),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            border: border(AppColors.border(context)),
            enabledBorder: border(AppColors.border(context)),
            focusedBorder: border(AppColors.accentBlue, width: 1.5),
            errorBorder: border(AppColors.accentRed),
            focusedErrorBorder: border(AppColors.accentRed, width: 1.5),
            errorStyle:
                const TextStyle(color: AppColors.accentRed, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordField() {
    OutlineInputBorder border(Color color, {double width = 1}) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'PASSWORD',
              style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
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
        ),
        const SizedBox(height: 6),
        StatefulBuilder(
          builder: (context, setFieldState) {
            return TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              validator: (v) => _requiredValidator(v, 'Password'),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
              decoration: InputDecoration(
                hintText: '••••••••',
                hintStyle:
                    TextStyle(color: AppColors.textMuted(context), fontSize: 12),
                filled: true,
                fillColor: AppColors.bg(context),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                border: border(AppColors.border(context)),
                enabledBorder: border(AppColors.border(context)),
                focusedBorder: border(AppColors.accentBlue, width: 1.5),
                errorBorder: border(AppColors.accentRed),
                focusedErrorBorder: border(AppColors.accentRed, width: 1.5),
                errorStyle:
                    const TextStyle(color: AppColors.accentRed, fontSize: 11),
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