import 'dart:async';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/activity_logger.dart';
import '../../services/realtime_stream_service.dart';
import '../../widgets/app_toast.dart';
import '../../constants/app_colors.dart';

/// Wraps any tappable widget to show a pointer (hand) cursor on hover.
/// Pass `enabled: false` to keep the plain arrow cursor on disabled buttons.
class HoverPop extends StatelessWidget {
  final Widget child;
  final bool enabled;

  const HoverPop({
    super.key,
    required this.child,
    this.enabled = true,
    // Kept for backwards compatibility with old call sites — no effect.
    double? scale,
    Duration? duration,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const List<String> _kRoleOptions = [
  'Command Center',
  'Tanod',
  'Task Force',
  'Purok Leader',
];

String _initialsFor(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'U';
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length >= 2) {
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }
  return parts[0][0].toUpperCase();
}

String _fullNameOf(Map<String, dynamic> d, {bool withMiddle = false}) {
  final parts = <dynamic>[
    d['first_name'],
    if (withMiddle) d['middle_name'],
    d['last_name'],
  ].map((e) => (e ?? '').toString().trim()).where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? 'Unnamed' : parts.join(' ');
}

String _titleCase(String s) {
  return s
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

Color _roleColor(BuildContext context, String role) {
  switch (role.toUpperCase()) {
    case 'COMMAND CENTER':
      return AppColors.accentBlue;
    case 'TANOD':
      return AppColors.accentGreen;
    case 'TASK FORCE':
      return AppColors.accentOrange;
    case 'PUROK LEADER':
      return AppColors.accentPurple;
    default:
      return AppColors.textMuted(context);
  }
}

IconData _roleIcon(String role) {
  switch (role.toUpperCase()) {
    case 'COMMAND CENTER':
      return Icons.hub_outlined;
    case 'TANOD':
      return Icons.security_outlined;
    case 'TASK FORCE':
      return Icons.groups_2_outlined;
    case 'PUROK LEADER':
      return Icons.flag_outlined;
    default:
      return Icons.person_outline;
  }
}

/// Tinted pill with a colored dot — used for roles everywhere.
class _RoleChip extends StatelessWidget {
  final String role;
  const _RoleChip({required this.role});

  @override
  Widget build(BuildContext context) {
    final color = _roleColor(context, role);
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
              role.toUpperCase(),
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

/// Circular avatar with a soft role-colored ring. Falls back to initials.
class _Avatar extends StatelessWidget {
  final String url;
  final String name;
  final Color color;
  final double size;
  final Uint8List? bytes;

  const _Avatar({
    required this.url,
    required this.name,
    required this.color,
    required this.size,
    this.bytes,
  });

  Widget _initials(BuildContext context) {
    return Container(
      color: color.withOpacity(0.16),
      alignment: Alignment.center,
      child: Text(
        _initialsFor(name),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.34,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget inner;
    if (bytes != null) {
      inner = Image.memory(bytes!, fit: BoxFit.cover);
    } else if (url.isNotEmpty) {
      inner = Image.network(
        url,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        errorBuilder: (_, __, ___) => _initials(context),
      );
    } else {
      inner = _initials(context);
    }
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.045),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.card(context),
        border: Border.all(color: color.withOpacity(0.55), width: 2),
      ),
      child: ClipOval(child: inner),
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
          // Plain Container (not AnimatedContainer) so theme switches are instant.
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

/// Tags a details-modal field so `_detailSection` knows whether it should
/// span the full row instead of half of it.
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
        // MaterialApp's theme fade without any key/teardown. The child
        // Column is built once and reused across animation frames.
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

/// Segmented role filter — replaces the old row of individual filter chips.
/// Behaves like [_ViewToggle]: one continuous pill, one segment highlighted.
class _RoleFilterSegmented extends StatelessWidget {
  final String? selected; // null = All
  final ValueChanged<String?> onChanged;
  const _RoleFilterSegmented({required this.selected, required this.onChanged});

  Widget _segment(BuildContext context, String label, String? value) {
    final isSelected = selected == value;
    final color = value == null ? AppColors.accentBlue : _roleColor(context, value);
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
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
          _segment(context, 'All', null),
          for (final role in _kRoleOptions) _segment(context, role, role),
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
          child: Container(
            width: 36,
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withOpacity(selected ? 0.16 : 0),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon,
                size: 17,
                color: selected ? AppColors.accentBlue : AppColors.textMuted(context)),
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

class _UserCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _UserCard({
    required this.data,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_UserCard> createState() => _UserCardState();
}

class _UserCardState extends State<_UserCard> {
  bool _hover = false;

  Widget _line(BuildContext context, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 13, color: AppColors.textMuted(context)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final name = _fullNameOf(d);
    final email = (d['email'] ?? 'N/A').toString();
    final phone = (d['phone_number'] ?? 'N/A').toString();
    final role = (d['role'] ?? 'user').toString();
    final avatarUrl = (d['avatar_url'] ?? '').toString().trim();
    final color = _roleColor(context, role);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // Only the hover is animated locally (t: 0 -> 1). Theme colors are
        // read fresh from the ThemeExtension on every rebuild, so they follow
        // MaterialApp's theme fade without any key/teardown. The child
        // Column is built once and reused across animation frames.
        //
        // NOTE: the avatar overlap uses a Stack (which reports correct height)
        // plus a single Expanded spacer, so the footer never overflows the
        // GridView's fixed `mainAxisExtent`.
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
                      child: _Avatar(url: avatarUrl, name: name, color: color, size: 60),
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
                    _RoleChip(role: role),
                    const SizedBox(height: 12),
                    _line(context, Icons.mail_outline, email),
                    const SizedBox(height: 5),
                    _line(context, Icons.phone_outlined, phone),
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
                        'View profile',
                        style: TextStyle(
                          color: AppColors.accentBlue,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _MiniIconButton(
                        icon: Icons.edit_outlined, tooltip: 'Edit', onTap: widget.onEdit),
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

class _UserRowTile extends StatefulWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _UserRowTile({
    required this.data,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_UserRowTile> createState() => _UserRowTileState();
}

class _UserRowTileState extends State<_UserRowTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final name = _fullNameOf(d);
    final email = (d['email'] ?? 'N/A').toString();
    final phone = (d['phone_number'] ?? 'N/A').toString();
    final role = (d['role'] ?? 'user').toString();
    final purok = (d['purok'] ?? '').toString().trim();
    final avatarUrl = (d['avatar_url'] ?? '').toString().trim();
    final color = _roleColor(context, role);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // Plain Container so the row follows the theme instantly.
        child: Container(
          color: AppColors.sunken(context).withOpacity(_hover ? 1 : 0),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    _Avatar(url: avatarUrl, name: name, color: color, size: 38),
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
                            email,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppColors.textMuted(context), fontSize: 11.5),
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
                  phone,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _RoleChip(role: role),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  purok.isEmpty ? '—' : purok,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5),
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
                        icon: Icons.edit_outlined, tooltip: 'Edit', onTap: widget.onEdit),
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

/// Renders the Users dashboard (stat cards, filters, grid/list) and shows
/// view / add / edit inside a centered modal. Lives inside DashboardShell's
/// IndexedStack; `isActive` tells it when its tab is hidden.
///
/// EXPORT: the header "Export PDF" button builds a portrait A4 PDF (SafeWatch
/// header, who exported it + date/time, counts, filters, then a simple
/// bordered users table) for the users currently shown, and downloads it
/// straight away through `file_saver`. Needs `pdf` + `file_saver`.
///
/// CHANGE PASSWORD: in Edit mode there is an optional "Change password"
/// section. When filled in, the new password is sent to the `update-user`
/// edge function as `password` (see the edge function note in the reply).
class UsersScreen extends StatefulWidget {
  final bool isActive;

  const UsersScreen({super.key, this.isActive = true});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  Stream<List<Map<String, dynamic>>>? _usersStream;

  Map<String, dynamic>? _selectedUser;
  String _searchQuery = '';
  String? _roleFilter; // null = all roles

  bool _gridView = false;

  int _currentPage = 0;
  static const int _usersPerPage = 50;

  // null (closed), 'view', 'add', 'edit'
  String? _rightPanelMode;
  // Remembers the last open mode so the modal keeps its content while it
  // animates closed.
  String _lastMode = 'view';

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

  final _firstNameController = TextEditingController();
  final _middleNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  // In Add mode: the account password. In Edit mode: the OPTIONAL new
  // password (blank = keep the current one).
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _purokController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  String _selectedRole = _kRoleOptions.first;

  // Snapshot when Edit opened — for dirty checking.
  String _originalFirstName = '';
  String _originalMiddleName = '';
  String _originalLastName = '';
  String _originalPhone = '';
  String _originalRole = '';
  String _originalPurok = '';

  Uint8List? _pickedAvatarBytes;
  String? _pickedAvatarExtension;
  String? _existingAvatarUrl;
  bool _isUploadingAvatar = false;
  bool _isPickerOpen = false;

  bool _isSaving = false;
  bool _isDeleting = false;
  bool get _isProcessing => _isSaving || _isDeleting;

  // PDF export in progress (disables the Export button + shows a spinner).
  bool _exporting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _usersStream = RealtimeStreamService.instance
        .streamTable('profiles', primaryKey: ['id']);
    _searchFocusNode.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _modalEntry?.remove();
    _modalAnim.dispose();
    _confirmOverlayEntry?.remove();
    _confirmAnimController.dispose();
    _firstNameController.dispose();
    _middleNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _purokController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant UsersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      _closeRightPanel();
    }
  }

  void _closeRightPanel() {
    if (_rightPanelMode == null) return;
    setState(() => _rightPanelMode = null);
  }

  bool _roleRequiresPurok(String role) {
    final r = role.trim().toLowerCase();
    return r == 'tanod' || r == 'purok leader';
  }

  void _clearForm() {
    _firstNameController.clear();
    _middleNameController.clear();
    _lastNameController.clear();
    _emailController.clear();
    _phoneController.clear();
    _passwordController.clear();
    _confirmPasswordController.clear();
    _purokController.clear();
    _selectedRole = _kRoleOptions.first;
    _pickedAvatarBytes = null;
    _pickedAvatarExtension = null;
    _existingAvatarUrl = null;
  }

  void _populateEditForm(Map<String, dynamic> user) {
    _firstNameController.text = user['first_name'] ?? '';
    _middleNameController.text = user['middle_name'] ?? '';
    _lastNameController.text = user['last_name'] ?? '';
    _emailController.text = user['email'] ?? '';
    _phoneController.text = user['phone_number'] ?? '';
    final existingRole = (user['role'] ?? '').toString();
    _selectedRole = _kRoleOptions.firstWhere(
      (r) => r.toLowerCase() == existingRole.toLowerCase(),
      orElse: () => _kRoleOptions.first,
    );
    // Password fields start blank in Edit mode (blank = don't change).
    _passwordController.clear();
    _confirmPasswordController.clear();
    _purokController.text = (user['purok'] ?? '').toString();
    _pickedAvatarBytes = null;
    _pickedAvatarExtension = null;
    _existingAvatarUrl = (user['avatar_url'] ?? '').toString().trim().isEmpty
        ? null
        : user['avatar_url'].toString();

    _originalFirstName = _firstNameController.text.trim();
    _originalMiddleName = _middleNameController.text.trim();
    _originalLastName = _lastNameController.text.trim();
    _originalPhone = _phoneController.text.trim();
    _originalRole = _selectedRole;
    _originalPurok = _purokController.text.trim();
  }

  bool _hasEditChanges() {
    if (_pickedAvatarBytes != null) return true;
    // Typing a new password counts as a change.
    if (_passwordController.text.isNotEmpty) return true;
    if (_firstNameController.text.trim() != _originalFirstName) return true;
    if (_middleNameController.text.trim() != _originalMiddleName) return true;
    if (_lastNameController.text.trim() != _originalLastName) return true;
    if (_phoneController.text.trim() != _originalPhone) return true;
    if (_selectedRole != _originalRole) return true;
    if (_roleRequiresPurok(_selectedRole) &&
        _purokController.text.trim() != _originalPurok) {
      return true;
    }
    return false;
  }

  bool _canCreate() {
    if (_firstNameController.text.trim().isEmpty) return false;
    if (_lastNameController.text.trim().isEmpty) return false;
    if (_emailController.text.trim().isEmpty) return false;
    if (_phoneController.text.trim().isEmpty) return false;
    if (_passwordController.text.isEmpty) return false;
    if (_confirmPasswordController.text.isEmpty) return false;
    if (_roleRequiresPurok(_selectedRole) &&
        _purokController.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  // --- AVATAR PICK / UPLOAD ---

  Future<void> _pickAvatarImage() async {
    if (_isPickerOpen) return;
    _isPickerOpen = true;
    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (picked == null) return;
      if (!mounted) return;

      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.')
          ? picked.name.split('.').last.toLowerCase()
          : 'jpg';

      if (!mounted) return;
      setState(() {
        _pickedAvatarBytes = bytes;
        _pickedAvatarExtension = ext;
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Could not select image: $e');
    } finally {
      _isPickerOpen = false;
    }
  }

  Future<String?> _uploadAvatarIfNeeded(String userId) async {
    if (_pickedAvatarBytes == null) return _existingAvatarUrl;
    if (!mounted) return _existingAvatarUrl;

    setState(() => _isUploadingAvatar = true);
    try {
      final storage = Supabase.instance.client.storage.from('avatars');
      final ext = _pickedAvatarExtension ?? 'jpg';
      final path = '$userId/avatar.$ext';

      await storage.uploadBinary(
        path,
        _pickedAvatarBytes!,
        fileOptions: const FileOptions(upsert: true),
      );

      final publicUrl = storage.getPublicUrl(path);
      return '$publicUrl?updated=${DateTime.now().millisecondsSinceEpoch}';
    } finally {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
  }

  // --- BUILD ---

  @override
  Widget build(BuildContext context) {
    super.build(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncModalOverlay());

    final currentUser = Supabase.instance.client.auth.currentUser;
    final currentUid = currentUser?.id;
    final currentEmail = currentUser?.email?.toLowerCase();

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _usersStream,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData;

        // Everyone except the signed-in admin.
        final all = (snapshot.data ?? const <Map<String, dynamic>>[])
            .map((r) => Map<String, dynamic>.from(r))
            .where((data) {
              final rowId = data['id']?.toString();
              if (currentUid != null && rowId == currentUid) return false;
              final docEmail = (data['email'] ?? '').toString().toLowerCase();
              if (currentEmail != null &&
                  docEmail.isNotEmpty &&
                  docEmail == currentEmail) {
                return false;
              }
              return true;
            })
            .map((data) {
              data['doc_id'] = data['id'];
              return data;
            })
            .toList();

        final counts = <String, int>{
          for (final r in _kRoleOptions) r.toUpperCase(): 0,
        };
        for (final u in all) {
          final key = (u['role'] ?? '').toString().toUpperCase();
          if (counts.containsKey(key)) counts[key] = counts[key]! + 1;
        }

        final filtered = all.where((data) {
          if (_roleFilter != null &&
              (data['role'] ?? '').toString().toUpperCase() !=
                  _roleFilter!.toUpperCase()) {
            return false;
          }
          if (_searchQuery.isEmpty) return true;
          final haystack = [
            _fullNameOf(data, withMiddle: true),
            data['email'],
            data['phone_number'],
            data['role'],
          ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
          return haystack.contains(_searchQuery);
        }).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(all.length),
            const SizedBox(height: 18),
            _buildStatCards(all.length, counts),
            const SizedBox(height: 18),
            _buildToolbar(filtered),
            const SizedBox(height: 14),
            Expanded(child: _buildContent(loading, all, filtered)),
          ],
        );
      },
    );
  }

  // --- HEADER ---

  Widget _buildHeader(int total) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Users',
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Manage accounts, roles and purok assignments',
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
              ),
            ],
          ),
        ),
        HoverPop(
          child: SizedBox(
            height: 40,
            child: ElevatedButton.icon(
              onPressed: () {
                _clearForm();
                setState(() {
                  _selectedUser = null;
                  _rightPanelMode = 'add';
                });
              },
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
              label: const Text('Add User',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
        label: 'Total users',
        value: total,
        caption: 'All roles',
        icon: Icons.people_alt_outlined,
        color: AppColors.accentBlue,
        share: total == 0 ? 0 : 1,
        selected: _roleFilter == null,
        onTap: () => setState(() {
          _roleFilter = null;
          _currentPage = 0;
        }),
      ),
      for (final role in _kRoleOptions)
        _StatCard(
          label: role,
          value: counts[role.toUpperCase()] ?? 0,
          caption: total == 0
              ? '0%'
              : '${(((counts[role.toUpperCase()] ?? 0) / total) * 100).round()}%',
          icon: _roleIcon(role),
          color: _roleColor(context, role),
          share: total == 0 ? 0 : (counts[role.toUpperCase()] ?? 0) / total,
          selected: _roleFilter == role,
          onTap: () => setState(() {
            _roleFilter = _roleFilter == role ? null : role;
            _currentPage = 0;
          }),
        ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        const gap = 14.0;
        final perRow = c.maxWidth >= 980 ? 5 : (c.maxWidth >= 640 ? 3 : 2);
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
              hintText: 'Search name, email, phone…',
              hintStyle: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
              prefixIcon: Icon(
                Icons.search,
                size: 17,
                color: _searchFocusNode.hasFocus
                    ? AppColors.accentBlue
                    : AppColors.textMuted(context),
              ),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.close, size: 16, color: AppColors.textMuted(context)),
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
                borderSide: const BorderSide(color: AppColors.accentBlue, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        // Segmented role filter (replaces the old scrolling row of chips).
        Expanded(
          child: _RoleFilterSegmented(
            selected: _roleFilter,
            onChanged: (role) => setState(() {
              _roleFilter = role;
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
          message: 'Copy ${filtered.length} users as CSV',
          child: HoverPop(
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
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: filtered.isEmpty
              ? 'No users to export'
              : 'Export ${filtered.length} user${filtered.length == 1 ? '' : 's'} as PDF',
          child: HoverPop(
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

  Future<void> _copyCsv(List<Map<String, dynamic>> rows) async {
    String esc(dynamic v) {
      final s = (v ?? '').toString().replaceAll('"', '""');
      return '"$s"';
    }

    final buf = StringBuffer('First Name,Middle Name,Last Name,Email,Phone,Role,Purok\n');
    for (final r in rows) {
      buf.writeln([
        r['first_name'],
        r['middle_name'],
        r['last_name'],
        r['email'],
        r['phone_number'],
        r['role'],
        r['purok'],
      ].map(esc).join(','));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    AppToast.success(context, 'Copied ${rows.length} users as CSV');
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
        final name = _fullNameOf(row);
        return (
          name: name == 'Unnamed' ? (user.email ?? 'Unknown user') : name,
          role: (row['role'] ?? '').toString(),
        );
      }
    } catch (_) {
      // fall through to the email fallback
    }
    return (name: user.email ?? 'Unknown user', role: '');
  }

  /// Exports the users currently shown (filters applied) as a portrait PDF
  /// and downloads it immediately — no print dialog.
  Future<void> _exportPdf(List<Map<String, dynamic>> rows) async {
    if (_exporting || rows.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final me = await _currentExporter();
      final bytes = await _buildUsersPdf(rows, exportedBy: me.name, exportedRole: me.role);
      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await FileSaver.instance.saveFile(
        name: 'safewatch_users_$stamp',
        bytes: bytes,
        ext: 'pdf',
        mimeType: MimeType.pdf,
      );
      if (!mounted) return;
      AppToast.success(
          context, 'Downloaded ${rows.length} user${rows.length == 1 ? '' : 's'} as PDF');
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
  /// counts, filters) and then one simple bordered table.
  Future<Uint8List> _buildUsersPdf(
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

    final roleCounts = <String, int>{
      for (final r in _kRoleOptions) r: 0,
    };
    for (final u in rows) {
      final key = (u['role'] ?? '').toString().toUpperCase();
      for (final r in _kRoleOptions) {
        if (r.toUpperCase() == key) roleCounts[r] = roleCounts[r]! + 1;
      }
    }
    final roleBreakdown =
        _kRoleOptions.map((r) => '$r: ${roleCounts[r]}').join('\n');

    final filters = <String>[
      if (_roleFilter != null) 'Role: $_roleFilter',
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
          final u = rows[i];
          final purok = (u['purok'] ?? '').toString().trim();
          return <String>[
            '${i + 1}',
            t(_fullNameOf(u, withMiddle: true)),
            t((u['email'] ?? '-').toString()),
            t((u['phone_number'] ?? '-').toString()),
            t(_titleCase((u['role'] ?? '-').toString())),
            t(purok.isEmpty ? '-' : purok),
          ];
        }(),
    ];

    final doc = pw.Document(title: 'SafeWatch Users', author: 'SafeWatch');

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(t('SafeWatch  |  Users  |  Exported by $exportedBy'),
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
                    pw.Text('Users',
                        style: pw.TextStyle(
                            fontSize: 20, fontWeight: pw.FontWeight.bold, color: ink)),
                    pw.SizedBox(height: 2),
                    pw.Text('Accounts, roles and purok assignments',
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
                      info('Total users', '${rows.length}'),
                      info('By role', roleBreakdown),
                    ],
                  ),
                ),
                pw.Expanded(
                  flex: 5,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      info('Filters applied',
                          filters.isEmpty ? 'None (all users)' : filters.join(', ')),
                    ],
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          // --- Table ---
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Name', 'Email', 'Phone', 'Role', 'Purok'],
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
              1: const pw.FlexColumnWidth(1.7),
              2: const pw.FlexColumnWidth(2.1),
              3: const pw.FlexColumnWidth(1.3),
              4: const pw.FlexColumnWidth(1.3),
              5: const pw.FlexColumnWidth(1.0),
            },
          ),
        ],
      ),
    );

    return doc.save();
  }

  // --- CONTENT (grid / list + pager) ---

  Widget _buildContent(
    bool loading,
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
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 13)),
            ],
          ),
        );

    if (loading) {
      return shell(const Center(
          child: CircularProgressIndicator(color: AppColors.accentBlue)));
    }
    if (all.isEmpty) {
      return shell(message(Icons.people_outline, 'No users found.'));
    }
    if (filtered.isEmpty) {
      return shell(message(Icons.search_off_rounded, 'No users match your filters.'));
    }

    final totalPages = (filtered.length / _usersPerPage).ceil();
    final safePage = _currentPage >= totalPages ? totalPages - 1 : _currentPage;
    if (safePage != _currentPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _currentPage = safePage);
      });
    }
    final pageStart = safePage * _usersPerPage;
    final pageEnd = (pageStart + _usersPerPage).clamp(0, filtered.length);
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
                  _headerCell('USER', 5),
                  _headerCell('PHONE', 3),
                  _headerCell('ROLE', 3),
                  _headerCell('PUROK', 2),
                  const SizedBox(width: 96),
                ],
              ),
            ),
            Divider(color: AppColors.border(context), height: 1, thickness: 1),
          ],
          Expanded(
            child: _gridView ? _buildUserGrid(pageDocs) : _buildUserList(pageDocs),
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
      _selectedUser = data;
      _rightPanelMode = 'view';
    });
  }

  void _openEdit(Map<String, dynamic> data) {
    _populateEditForm(data);
    setState(() {
      _selectedUser = data;
      _rightPanelMode = 'edit';
    });
  }

  void _openDelete(Map<String, dynamic> data) {
    setState(() => _selectedUser = data);
    _showDeleteConfirmDialog();
  }

  Widget _buildUserGrid(List<Map<String, dynamic>> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 250,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        // Content measures ~220px (header 74 + name/chip/info + footer 42),
        // so 232 leaves a little slack without a tall empty gap.
        mainAxisExtent: 232,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final data = items[index];
        return _UserCard(
          data: data,
          onTap: () => _openView(data),
          onEdit: () => _openEdit(data),
          onDelete: () => _openDelete(data),
        );
      },
    );
  }

  Widget _buildUserList(List<Map<String, dynamic>> items) {
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
      itemBuilder: (context, index) {
        final data = items[index];
        return _UserRowTile(
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
      return HoverPop(
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
      return HoverPop(
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
              border: isCurrent ? null : Border.all(color: AppColors.border(context)),
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
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5)),
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
    double maxWidth;
    if (mode == 'view') {
      content = _selectedUser == null
          ? const SizedBox.shrink()
          : _buildDetailsModal(_selectedUser!);
      // Wider than before: the redesigned profile layout is two-pane.
      maxWidth = 780;
    } else {
      content = _buildFormModal(isEditMode: mode == 'edit');
      maxWidth = 780;
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
                final t = Curves.easeOutCubic.transform(_modalAnim.value.clamp(0.0, 1.0));
                return Opacity(
                  opacity: t,
                  child: Transform.scale(scale: 0.95 + 0.05 * t, child: child),
                );
              },
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
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

  Widget _modalCloseButton({bool onBanner = false}) {
    return HoverPop(
      child: GestureDetector(
        onTap: _closeRightPanel,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: onBanner
                ? Colors.black.withOpacity(0.25)
                : AppColors.border(context).withOpacity(0.6),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.close,
              size: 17, color: onBanner ? Colors.white : AppColors.textMain(context)),
        ),
      ),
    );
  }

  ButtonStyle _footerButtonStyle({required Color bg, required Color fg, Color? disabledBg}) {
    return ElevatedButton.styleFrom(
      backgroundColor: bg,
      foregroundColor: fg,
      disabledBackgroundColor: disabledBg,
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }

  // --- VIEW MODAL (REDESIGNED) ---
  //
  // Profile layout: slim title bar, a left rail (portrait, name, role, purok,
  // quick-copy buttons) and a right side with PERSONAL / CONTACT / ASSIGNMENT
  // sections using label-over-value fields. Stacks on narrow widths.

  Future<void> _copyText(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    AppToast.success(context, '$label copied');
  }

  Widget _buildDetailsModal(Map<String, dynamic> user) {
    final name = _fullNameOf(user, withMiddle: true);
    final roleRaw = (user['role'] ?? 'Employee').toString();
    final avatarUrl = (user['avatar_url'] ?? '').toString().trim();
    final purok = (user['purok'] ?? '').toString().trim();
    final email = (user['email'] ?? '').toString().trim();
    final phone = (user['phone_number'] ?? '').toString().trim();
    final needsPurok = _roleRequiresPurok(roleRaw);
    final roleColor = _roleColor(context, roleRaw);

    // ---- Left rail ----
    Widget rail() {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _detailPortrait(avatarUrl, name, roleColor),
            const SizedBox(height: 16),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textMain(context),
                fontSize: 17,
                height: 1.25,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            _RoleChip(role: roleRaw),
            if (needsPurok && purok.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 12, color: AppColors.textMuted(context)),
                    const SizedBox(width: 4),
                    Text(
                      purok,
                      style: TextStyle(
                        color: AppColors.textMuted(context),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Divider(color: AppColors.border(context), height: 1),
            const SizedBox(height: 16),
            _railAction(Icons.mail_outline, 'Copy email',
                email.isEmpty ? null : () => _copyText(email, 'Email')),
            const SizedBox(height: 8),
            _railAction(Icons.phone_outlined, 'Copy phone',
                phone.isEmpty ? null : () => _copyText(phone, 'Phone number')),
          ],
        ),
      );
    }

    // ---- Right side ----
    Widget details() {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailSection('PERSONAL', Icons.badge_outlined, [
              _detailField('FIRST NAME', (user['first_name'] ?? '').toString()),
              _detailField('LAST NAME', (user['last_name'] ?? '').toString()),
              _detailField('MIDDLE NAME', (user['middle_name'] ?? '').toString()),
            ]),
            const SizedBox(height: 22),
            _detailSection('CONTACT', Icons.contact_mail_outlined, [
              _detailField('PHONE', phone,
                  icon: Icons.phone_outlined, copyable: true),
              _detailField('EMAIL', email,
                  icon: Icons.mail_outline, copyable: true, full: true),
            ]),
            const SizedBox(height: 22),
            _detailSection('ASSIGNMENT', _roleIcon(roleRaw), [
              _detailField('ROLE', roleRaw.toUpperCase(),
                  icon: _roleIcon(roleRaw), iconColor: roleColor),
              if (needsPurok) _detailField('PUROK', purok),
            ]),
          ],
        ),
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
              Icon(Icons.person_outline,
                  size: 18, color: AppColors.textMuted(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'User profile',
                  style: TextStyle(
                    color: AppColors.textMain(context),
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _modalCloseButton(),
            ],
          ),
        ),
        Divider(color: AppColors.border(context), height: 1, thickness: 1),

        // Body
        Flexible(
          child: SingleChildScrollView(
            child: LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 560;
                if (!wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(color: AppColors.sunken(context), child: rail()),
                      details(),
                    ],
                  );
                }
                // Paint the full-height rail background with a hard-stop
                // gradient instead of IntrinsicHeight.
                final frac = (240 / c.maxWidth).clamp(0.0, 1.0);
                final railBg = AppColors.sunken(context);
                final paneBg = AppColors.card(context);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [railBg, railBg, paneBg, paneBg],
                      stops: [0.0, frac, frac, 1.0],
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 240, child: rail()),
                      Expanded(child: details()),
                    ],
                  ),
                );
              },
            ),
          ),
        ),

        // Footer
        Divider(color: AppColors.border(context), height: 1, thickness: 1),
        Container(
          color: AppColors.card(context),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Spacer(),
              HoverPop(
                child: ElevatedButton(
                  onPressed: _closeRightPanel,
                  style: _footerButtonStyle(
                      bg: AppColors.border(context), fg: AppColors.textMain(context)),
                  child: const Text('CLOSE',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(width: 10),
              HoverPop(
                child: ElevatedButton.icon(
                  onPressed: () {
                    _populateEditForm(user);
                    setState(() => _rightPanelMode = 'edit');
                  },
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  style: _footerButtonStyle(bg: AppColors.accentBlue, fg: Colors.white),
                  label: const Text('EDIT USER',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Large rounded portrait; falls back to role-tinted initials.
  Widget _detailPortrait(String url, String name, Color color) {
    Widget initials() => Container(
          color: color.withOpacity(0.12),
          alignment: Alignment.center,
          child: Text(
            _initialsFor(name),
            style: TextStyle(
              color: color,
              fontSize: 44,
              fontWeight: FontWeight.w800,
            ),
          ),
        );

    return Container(
      width: 168,
      height: 192,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.10),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: url.isEmpty
          ? initials()
          : Image.network(
              url,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, __, ___) => initials(),
            ),
    );
  }

  /// Full-width compact outlined button for the left rail.
  Widget _railAction(IconData icon, String label, VoidCallback? onTap) {
    return HoverPop(
      enabled: onTap != null,
      child: SizedBox(
        width: double.infinity,
        height: 36,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 15),
          label: Text(label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textMain(context),
            backgroundColor: AppColors.card(context),
            side: BorderSide(color: AppColors.border(context)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
  }

  /// Section title + 2-column grid of fields. Fields flagged `full` span the row.
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

  /// Lays fields out two per row (a `full` field gets its own row).
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
                    ),
                  ),
                ),
                if (copyable && !empty) ...[
                  const SizedBox(width: 4),
                  _MiniIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: 'Copy',
                    onTap: () => _copyText(
                        value, label[0] + label.substring(1).toLowerCase()),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- ADD / EDIT MODAL (REDESIGNED) ---
  //
  // Same profile-style layout as the details modal: slim title bar, left rail
  // with the photo picker, right side with PERSONAL / CONTACT / ACCOUNT (add
  // only) / CHANGE PASSWORD (edit only) / ASSIGNMENT sections. "Remove user"
  // lives here (edit mode only).

  Widget _buildFormModal({required bool isEditMode}) {
    final selected = _selectedUser;
    final headerName = isEditMode && selected != null
        ? _fullNameOf(selected, withMiddle: true)
        : 'New user';
    final hasImage = _pickedAvatarBytes != null ||
        (_existingAvatarUrl != null && _existingAvatarUrl!.isNotEmpty);
    final needsPurok = _roleRequiresPurok(_selectedRole);

    Widget field(Widget child, {bool full = false}) =>
        _DetailFieldMarker(full: full, child: child);

    // ---- Photo picker ----
    Widget photoPicker() {
      final busy = _isUploadingAvatar || _isPickerOpen;
      return HoverPop(
        enabled: !busy,
        child: GestureDetector(
          onTap: busy ? null : _pickAvatarImage,
          child: Container(
            width: 168,
            height: 192,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border(context)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.10),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_pickedAvatarBytes != null)
                  Image.memory(_pickedAvatarBytes!, fit: BoxFit.cover)
                else if (_existingAvatarUrl != null && _existingAvatarUrl!.isNotEmpty)
                  Image.network(
                    _existingAvatarUrl!,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    errorBuilder: (_, __, ___) => _buildPhotoUploadPrompt(),
                  )
                else
                  _buildPhotoUploadPrompt(),
                if (_isUploadingAvatar)
                  Container(
                    color: Colors.black.withOpacity(0.5),
                    child: const Center(
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5),
                    ),
                  ),
                if (!_isUploadingAvatar && hasImage)
                  Positioned(
                    bottom: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.accentBlue,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.card(context), width: 2.5),
                      ),
                      child: const Icon(Icons.camera_alt, color: Colors.white, size: 15),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // ---- Left rail ----
    Widget rail() {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            photoPicker(),
            const SizedBox(height: 12),
            Text(
              hasImage ? 'Click the photo to change it' : 'Click to upload a photo',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 18),
            Divider(color: AppColors.border(context), height: 1),
            const SizedBox(height: 16),
            _RoleChip(role: _selectedRole),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: AppColors.textMuted(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isEditMode
                        ? 'The email address can’t be changed after the account is created. Leave the password fields blank to keep the current password.'
                        : 'Password must be at least 6 characters.',
                    style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // ---- Role dropdown ----
    Widget roleDropdown() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ROLE',
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          DropdownMenu<String>(
            initialSelection: _selectedRole,
            enableFilter: false,
            enableSearch: false,
            requestFocusOnTap: false,
            expandedInsets: EdgeInsets.zero,
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: AppColors.bg(context),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: AppColors.border(context)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.accentBlue, width: 1.5),
              ),
            ),
            menuStyle: MenuStyle(
              backgroundColor: WidgetStateProperty.all(AppColors.card(context)),
            ),
            textStyle: TextStyle(color: AppColors.textMain(context), fontSize: 13),
            dropdownMenuEntries: _kRoleOptions
                .map((role) => DropdownMenuEntry<String>(
                      value: role,
                      label: role,
                      style: ButtonStyle(
                        foregroundColor:
                            WidgetStateProperty.all(AppColors.textMain(context)),
                      ),
                    ))
                .toList(),
            onSelected: (val) {
              if (val != null) {
                setState(() {
                  _selectedRole = val;
                  if (!_roleRequiresPurok(val)) _purokController.clear();
                });
              }
            },
          ),
        ],
      );
    }

    // ---- Right side ----
    Widget fields() {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailSection('PERSONAL', Icons.badge_outlined, [
              field(_buildInputField('FIRST NAME', _firstNameController, 'John',
                  isRequired: true,
                  validator: (v) => _requiredValidator(v, 'First name'))),
              field(_buildInputField('LAST NAME', _lastNameController, 'Doe',
                  isRequired: true,
                  validator: (v) => _requiredValidator(v, 'Last name'))),
              field(_buildInputField('MIDDLE NAME', _middleNameController, 'S')),
            ]),
            const SizedBox(height: 22),
            _detailSection('CONTACT', Icons.contact_mail_outlined, [
              field(_buildInputField('PHONE NUMBER', _phoneController, '09123456789',
                  isRequired: true,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(13),
                  ],
                  validator: _phoneValidator)),
              field(_buildInputField('EMAIL', _emailController, 'user@domain.com',
                  enabled: !isEditMode,
                  isRequired: true,
                  keyboardType: TextInputType.emailAddress,
                  validator: _emailValidator)),
            ]),
            if (!isEditMode) ...[
              const SizedBox(height: 22),
              _detailSection('ACCOUNT', Icons.lock_outline, [
                field(_buildInputField('PASSWORD', _passwordController, '••••••••',
                    isPassword: true,
                    isRequired: true,
                    validator: _passwordValidator)),
                field(_buildInputField(
                    'CONFIRM PASSWORD', _confirmPasswordController, '••••••••',
                    isPassword: true,
                    isRequired: true,
                    validator: _confirmPasswordValidator)),
              ]),
            ],
            if (isEditMode) ...[
              const SizedBox(height: 22),
              _detailSection('CHANGE PASSWORD (OPTIONAL)', Icons.lock_reset, [
                field(_buildInputField(
                    'NEW PASSWORD', _passwordController, 'Leave blank to keep current',
                    isPassword: true, validator: _newPasswordValidator)),
                field(_buildInputField('CONFIRM NEW PASSWORD',
                    _confirmPasswordController, 'Re-enter new password',
                    isPassword: true, validator: _confirmNewPasswordValidator)),
              ]),
            ],
            const SizedBox(height: 22),
            _detailSection('ASSIGNMENT', _roleIcon(_selectedRole), [
              field(roleDropdown()),
              if (needsPurok)
                field(_buildInputField('PUROK', _purokController, 'e.g. Purok 3',
                    isRequired: true,
                    validator: (v) => _requiredValidator(v, 'Purok'))),
            ]),
          ],
        ),
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
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.accentBlue.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isEditMode ? Icons.edit_outlined : Icons.person_add_alt_1_rounded,
                  color: AppColors.accentBlue,
                  size: 17,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isEditMode ? 'Edit user' : 'Add new user',
                      style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      isEditMode ? headerName : 'Create an account and assign a role',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              _modalCloseButton(),
            ],
          ),
        ),
        Divider(color: AppColors.border(context), height: 1, thickness: 1),

        // Body
        Flexible(
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: LayoutBuilder(
                builder: (context, c) {
                  final wide = c.maxWidth >= 560;
                  if (!wide) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(color: AppColors.sunken(context), child: rail()),
                        fields(),
                      ],
                    );
                  }
                  final frac = (240 / c.maxWidth).clamp(0.0, 1.0);
                  final railBg = AppColors.sunken(context);
                  final paneBg = AppColors.card(context);
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [railBg, railBg, paneBg, paneBg],
                        stops: [0.0, frac, frac, 1.0],
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 240, child: rail()),
                        Expanded(child: fields()),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),

        // Footer
        Divider(color: AppColors.border(context), height: 1, thickness: 1),
        Container(
          color: AppColors.card(context),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (isEditMode)
                HoverPop(
                  child: TextButton.icon(
                    onPressed: _showDeleteConfirmDialogFromPanel,
                    icon: const Icon(Icons.delete_outline,
                        size: 17, color: AppColors.accentRed),
                    label: const Text('Remove user',
                        style: TextStyle(
                            color: AppColors.accentRed,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              const Spacer(),
              HoverPop(
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
                  _firstNameController,
                  _middleNameController,
                  _lastNameController,
                  _emailController,
                  _phoneController,
                  _passwordController,
                  _confirmPasswordController,
                  _purokController,
                ]),
                builder: (context, _) {
                  final canSave =
                      !_isProcessing && (isEditMode ? _hasEditChanges() : _canCreate());
                  return HoverPop(
                    enabled: canSave,
                    child: ElevatedButton(
                      onPressed: !canSave
                          ? null
                          : () async {
                              if (!(_formKey.currentState?.validate() ?? false)) return;

                              if (isEditMode) {
                                final changingPassword =
                                    _passwordController.text.isNotEmpty;
                                final confirmed = await _showActionConfirmDialog(
                                  title: 'Save changes?',
                                  message:
                                      'This will update "$headerName"\'s information with role "$_selectedRole".'
                                      '${changingPassword ? ' Their password will also be changed.' : ''}'
                                      ' Continue?',
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
                              await _handleSaveUser(isEditMode: isEditMode);
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
                          : Text(isEditMode ? 'SAVE CHANGES' : 'CREATE USER',
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w800)),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- BLOCKING LOADER ---

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

  // --- SAVE / DELETE HANDLERS ---

  Future<String> _createAdminUserAccount({
    required String email,
    required String password,
    required String firstName,
    required String middleName,
    required String lastName,
    required String phoneNumber,
    required String role,
    String? purok,
  }) async {
    final response = await Supabase.instance.client.functions.invoke(
      'create-user',
      body: {
        'email': email,
        'password': password,
        'firstName': firstName,
        'middleName': middleName,
        'lastName': lastName,
        'phoneNumber': phoneNumber,
        'role': role,
        if (purok != null) 'purok': purok,
      },
    );

    if (response.status != 200) {
      final errorData = response.data;
      final errorMsg = (errorData is Map && errorData.containsKey('error'))
          ? errorData['error']
          : 'Failed to create user account.';
      throw Exception(errorMsg);
    }

    final data = response.data;
    if (data is Map && data['warning'] != null) {
      if (mounted) AppToast.error(context, data['warning'].toString());
    }

    final newUserId = (data is Map)
        ? (data['id'] ??
            (data['user'] is Map ? data['user']['id'] : null) ??
            data['userId'])
        : null;

    if (newUserId == null) {
      throw Exception('User account was created, but no user id was returned — '
          'update the create-user edge function to include it.');
    }
    return newUserId.toString();
  }

  Future<Map<String, dynamic>> _updateAdminUserAccount({
    required String userId,
    required String firstName,
    required String middleName,
    required String lastName,
    required String phoneNumber,
    required String role,
    String? email,
    String? purok,
    String? avatarUrl,
    String? password,
  }) async {
    final response = await Supabase.instance.client.functions.invoke(
      'update-user',
      body: {
        'userId': userId,
        'firstName': firstName,
        'middleName': middleName,
        'lastName': lastName,
        'phoneNumber': phoneNumber,
        'role': role,
        if (email != null) 'email': email,
        'purok': purok,
        'avatarUrl': avatarUrl,
        // Only sent when an admin typed a new password.
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );

    if (response.status != 200) {
      final errorData = response.data;
      final errorMsg = (errorData is Map && errorData.containsKey('error'))
          ? errorData['error']
          : 'Failed to update user account.';
      throw Exception(errorMsg);
    }

    final data = response.data;
    final profile = (data is Map && data['profile'] is Map)
        ? Map<String, dynamic>.from(data['profile'])
        : <String, dynamic>{};

    if (profile.isEmpty) {
      throw Exception('User account was updated, but no profile data was returned — '
          'check the update-user edge function response.');
    }
    return profile;
  }

  Future<void> _handleSaveUser({required bool isEditMode}) async {
    setState(() => _isSaving = true);
    _showBlockingLoader(isEditMode ? 'Saving changes...' : 'Creating user...');
    try {
      if (isEditMode) {
        final docId = _selectedUser?['doc_id'];
        if (docId != null) {
          final newFirstName = _firstNameController.text.trim();
          final newMiddleName = _middleNameController.text.trim();
          final newLastName = _lastNameController.text.trim();
          final newPhone = _phoneController.text.trim();
          final newPassword = _passwordController.text;
          final changedPassword = newPassword.isNotEmpty;

          final oldFirstName = (_selectedUser?['first_name'] ?? '').toString();
          final oldMiddleName = (_selectedUser?['middle_name'] ?? '').toString();
          final oldLastName = (_selectedUser?['last_name'] ?? '').toString();
          final oldPhone = (_selectedUser?['phone_number'] ?? '').toString();
          final oldRole = (_selectedUser?['role'] ?? '').toString();
          final oldPurok = (_selectedUser?['purok'] ?? '').toString();
          final newPurok = _roleRequiresPurok(_selectedRole)
              ? _purokController.text.trim()
              : null;
          final hadAvatar =
              (_selectedUser?['avatar_url'] ?? '').toString().trim().isNotEmpty;

          final avatarUrl = await _uploadAvatarIfNeeded(docId.toString());

          final updatedProfile = await _updateAdminUserAccount(
            userId: docId.toString(),
            firstName: newFirstName,
            middleName: newMiddleName,
            lastName: newLastName,
            phoneNumber: newPhone,
            role: _selectedRole,
            purok: newPurok,
            avatarUrl: avatarUrl,
            password: changedPassword ? newPassword : null,
          );

          final changes = <LogChange>[
            if (oldFirstName != newFirstName)
              LogChange(field: 'First Name', from: oldFirstName, to: newFirstName),
            if (oldMiddleName != newMiddleName)
              LogChange(field: 'Middle Name', from: oldMiddleName, to: newMiddleName),
            if (oldLastName != newLastName)
              LogChange(field: 'Last Name', from: oldLastName, to: newLastName),
            if (oldPhone != newPhone)
              LogChange(field: 'Phone Number', from: oldPhone, to: newPhone),
            if (oldRole.toLowerCase() != _selectedRole.toLowerCase())
              LogChange(
                field: 'Role',
                from: oldRole.isEmpty ? 'Unknown' : oldRole,
                to: _selectedRole,
              ),
            if (oldPurok != (newPurok ?? ''))
              LogChange(
                field: 'Purok',
                from: oldPurok.isEmpty ? 'None' : oldPurok,
                to: (newPurok ?? '').isEmpty ? 'None' : newPurok!,
              ),
            if (_pickedAvatarBytes != null)
              LogChange(
                field: 'Photo',
                from: hadAvatar ? 'Previous photo' : 'None',
                to: 'New photo',
              ),
            // Never log the password itself — only that it was changed.
            if (changedPassword)
              LogChange(field: 'Password', from: '••••••', to: 'Changed'),
          ];

          await ActivityLogger.log(
            action: 'UPDATE_USER',
            details: 'Updated user "$newFirstName $newLastName"',
            changes: changes,
          );

          // Don't keep the typed password around after a successful save.
          _passwordController.clear();
          _confirmPasswordController.clear();

          if (!mounted) return;
          setState(() {
            _selectedUser = {
              ..._selectedUser!,
              ...updatedProfile,
              'doc_id': docId,
            };
          });

          if (!mounted) return;
          AppToast.success(
              context,
              changedPassword
                  ? 'User updated and password changed'
                  : 'User updated successfully');
        }
      } else {
        final newFirstName = _firstNameController.text.trim();
        final newLastName = _lastNameController.text.trim();
        final newEmail = _emailController.text.trim();
        final newPassword = _passwordController.text;

        final newUserId = await _createAdminUserAccount(
          email: newEmail,
          password: newPassword,
          firstName: newFirstName,
          middleName: _middleNameController.text.trim(),
          lastName: newLastName,
          phoneNumber: _phoneController.text.trim(),
          role: _selectedRole,
          purok: _roleRequiresPurok(_selectedRole)
              ? _purokController.text.trim()
              : null,
        );

        if (_pickedAvatarBytes != null) {
          final avatarUrl = await _uploadAvatarIfNeeded(newUserId);
          await Supabase.instance.client
              .from('profiles')
              .update({'avatar_url': avatarUrl}).eq('id', newUserId);
        }

        final newPurok =
            _roleRequiresPurok(_selectedRole) ? _purokController.text.trim() : null;

        await ActivityLogger.log(
          action: 'CREATE_USER',
          details: 'Created user "$newFirstName $newLastName"',
          metadata: {
            'role': _selectedRole,
            'email': newEmail,
            if (newPurok != null) 'purok': newPurok,
          },
        );

        if (!mounted) return;
        _clearForm();

        if (!mounted) return;
        AppToast.success(context, 'Employee account created successfully');
      }
    } on PostgrestException catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Error: ${e.message}');
      setState(() => _rightPanelMode = isEditMode ? 'edit' : 'add');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Error: ${e.toString().replaceAll('Exception: ', '')}');
      setState(() => _rightPanelMode = isEditMode ? 'edit' : 'add');
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
                                    child: HoverPop(
                                      child: OutlinedButton(
                                        onPressed: onCancel,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppColors.textMain(context),
                                          side: BorderSide(color: AppColors.border(context)),
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(10)),
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
                                    child: HoverPop(
                                      child: ElevatedButton(
                                        onPressed: onConfirm,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: confirmColor,
                                          foregroundColor: Colors.white,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(10)),
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

  /// Delete from inside the modal (view or edit). The confirm dialog
  /// stacks on top of the still-open modal.
  Future<void> _showDeleteConfirmDialogFromPanel() => _showDeleteConfirmDialog();

  Future<void> _showDeleteConfirmDialog() async {
    final docId = _selectedUser?['doc_id'];
    if (docId == null) return;

    final first = (_selectedUser?['first_name'] ?? '').toString();
    final last = (_selectedUser?['last_name'] ?? '').toString();
    final label =
        '$first $last'.trim().isEmpty ? docId.toString() : '$first $last'.trim();

    final confirmed = await _showActionConfirmDialog(
      title: 'Remove this user?',
      message: 'Are you sure you want to remove "$label"? This action cannot be undone.',
      confirmLabel: 'REMOVE',
      confirmColor: AppColors.accentRed,
      icon: Icons.delete_outline,
    );

    if (confirmed) {
      await _handleDeleteUser(docId: docId.toString(), label: label);
    }
  }

  Future<void> _handleDeleteUser({
    required String docId,
    required String label,
  }) async {
    setState(() {
      _isDeleting = true;
      _rightPanelMode = null;
      _selectedUser = null;
    });
    _clearForm();
    _showBlockingLoader('Removing user...');

    try {
      // Auth account + Storage avatar removal need the service-role key,
      // so it's delegated to the delete-user edge function.
      final response = await Supabase.instance.client.functions.invoke(
        'delete-user',
        body: {'userId': docId},
      );

      if (response.status != 200) {
        final errorData = response.data;
        final errorMsg = (errorData is Map && errorData.containsKey('error'))
            ? errorData['error']
            : 'Failed to remove user.';
        throw Exception(errorMsg);
      }

      await ActivityLogger.log(
        action: 'DELETE_USER',
        details: 'Removed user "$label"',
        changes: [
          const LogChange(field: 'Status', from: 'Active', to: 'Removed'),
        ],
      );

      if (!mounted) return;
      AppToast.success(context, 'User removed successfully');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(
          context, 'Failed to remove user: ${e.toString().replaceAll('Exception: ', '')}');
    } finally {
      _hideBlockingLoader();
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  // --- VALIDATORS ---

  String? _requiredValidator(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) return '$fieldName is required';
    return null;
  }

  String? _emailValidator(String? value) {
    if (value == null || value.trim().isEmpty) return 'Email is required';
    final emailRegex = RegExp(r'^[\w\.\-]+@([\w\-]+\.)+[a-zA-Z]{2,}$');
    if (!emailRegex.hasMatch(value.trim())) return 'Enter a valid email address';
    return null;
  }

  String? _phoneValidator(String? value) {
    if (value == null || value.trim().isEmpty) return 'Phone number is required';
    if (!RegExp(r'^[0-9]{10,13}$').hasMatch(value.trim())) {
      return 'Enter a valid phone number (10-13 digits)';
    }
    return null;
  }

  String? _passwordValidator(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    if (value.length < 6) return 'Must be at least 6 characters';
    return null;
  }

  String? _confirmPasswordValidator(String? value) {
    if (value == null || value.isEmpty) return 'Please confirm the password';
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  /// Edit mode: the new password is optional — blank means "keep current".
  String? _newPasswordValidator(String? value) {
    if (value == null || value.isEmpty) return null;
    if (value.length < 6) return 'Must be at least 6 characters';
    return null;
  }

  String? _confirmNewPasswordValidator(String? value) {
    final newPassword = _passwordController.text;
    if (newPassword.isEmpty && (value == null || value.isEmpty)) return null;
    if (value == null || value.isEmpty) return 'Please confirm the new password';
    if (value != newPassword) return 'Passwords do not match';
    return null;
  }

  // --- SMALL WIDGET HELPERS ---

  Widget _buildInputField(
    String label,
    TextEditingController controller,
    String hint, {
    bool isPassword = false,
    bool enabled = true,
    bool isRequired = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
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
          obscureText: isPassword,
          enabled: enabled,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          validator: validator,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
            filled: true,
            fillColor: enabled ? AppColors.bg(context) : AppColors.border(context),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            border: border(AppColors.border(context)),
            enabledBorder: border(AppColors.border(context)),
            disabledBorder: border(AppColors.border(context)),
            focusedBorder: border(AppColors.accentBlue, width: 1.5),
            errorBorder: border(AppColors.accentRed),
            focusedErrorBorder: border(AppColors.accentRed, width: 1.5),
            errorStyle: const TextStyle(color: AppColors.accentRed, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoUploadPrompt() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.add_a_photo_outlined,
                color: AppColors.accentBlue, size: 26),
          ),
          const SizedBox(height: 10),
          Text(
            'Upload Photo',
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}