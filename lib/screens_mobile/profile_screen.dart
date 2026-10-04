import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/app_colors.dart';
import '../controllers/location_sharing_controller.dart';
import '../controllers/theme_controller.dart';
import '../services/location_tracking_service.dart';
import '../services/realtime_stream_service.dart';
import '../widgets/app_toast.dart';

// NOTE: `LocationSharingController` used to be declared in THIS file as
// well as in controllers/location_sharing_controller.dart. Those were two
// different singletons, so the switch below flipped one while
// TanodHomeScreen listened to the other — that's why the button did
// nothing. It now lives ONLY in controllers/location_sharing_controller.dart
// and is imported above. Actual tracking is done app-wide by
// LocationTrackingService (services/location_tracking_service.dart).

/// Shared "Profile" tab for Tanod, Task Force, and Purok Leader accounts.
/// Layout is a simplified settings-list style (wave header with avatar,
/// flat grouped rows) rather than the denser admin-dashboard look —
/// colors still come from AppColors so it stays correct in both light
/// and dark mode.
class ProfileScreen extends StatefulWidget {
  final bool isActive;

  const ProfileScreen({super.key, this.isActive = true});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _supabase = Supabase.instance.client;

  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final response = await _supabase
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _profile = response;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  bool _roleRequiresPurok(String role) {
    final r = role.trim().toLowerCase();
    return r == 'tanod' || r == 'purok leader';
  }

  String _getInitials(String name) {
    if (name.trim().isEmpty) return 'U';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return parts[0][0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin

    if (_loading) {
      return Container(
        color: AppColors.bg(context),
        child: const Center(
            child: CircularProgressIndicator(color: AppColors.accentBlue)),
      );
    }

    final profile = _profile ?? {};
    final firstName = (profile['first_name'] ?? '').toString();
    final middleName = (profile['middle_name'] ?? '').toString();
    final lastName = (profile['last_name'] ?? '').toString();
    final fullName = [firstName, middleName, lastName]
        .where((s) => s.trim().isNotEmpty)
        .join(' ');
    final displayName = fullName.trim().isEmpty ? 'Unnamed User' : fullName;
    final role = (profile['role'] ?? 'User').toString();
    final avatarUrl = (profile['avatar_url'] ?? '').toString().trim();
    final email = (profile['email'] ?? '').toString();
    final phone = (profile['phone_number'] ?? '').toString();
    final purok = (profile['purok'] ?? '').toString();

    final contactLine =
        [email, phone].where((s) => s.trim().isNotEmpty).join('   |   ');

    return Container(
      color: AppColors.bg(context),
      child: RefreshIndicator(
        color: AppColors.accentBlue,
        onRefresh: _loadProfile,
        child: ListView(
          padding: EdgeInsets.zero,
          physics:
              const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          children: [
            _buildHeader(
              name: displayName,
              avatarUrl: avatarUrl,
              contactLine: contactLine,
              onTapAvatar: () => _openEditProfileSheet(
                firstName: firstName,
                middleName: middleName,
                lastName: lastName,
                phone: phone,
                role: role,
                purok: purok,
                avatarUrl: avatarUrl,
              ),
            ),
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionLabel('Account'),
                  _buildCard([
                    _buildRow(
                      icon: Icons.badge_outlined,
                      label: 'Edit profile information',
                      onTap: () => _openEditProfileSheet(
                        firstName: firstName,
                        middleName: middleName,
                        lastName: lastName,
                        phone: phone,
                        role: role,
                        purok: purok,
                        avatarUrl: avatarUrl,
                      ),
                    ),
                    _buildRow(
                      icon: Icons.lock_outline,
                      label: 'Change password',
                      onTap: _openChangePasswordSheet,
                    ),
                  ]),
                  const SizedBox(height: 20),
                  _buildSectionLabel('Preferences'),
                  ValueListenableBuilder<bool>(
                    valueListenable: LocationSharingController.instance,
                    builder: (context, sharing, _) {
                      return ListenableBuilder(
                        listenable: themeController,
                        builder: (context, __) {
                          final isDark =
                              themeController.mode == ThemeMode.dark;
                          return _buildCard([
                            _buildRow(
                              icon: Icons.location_on_outlined,
                              label: 'Location sharing',
                              onTap: () => LocationSharingController.instance
                                  .setEnabled(!sharing),
                              trailingWidget: Switch.adaptive(
                                value: sharing,
                                activeColor: AppColors.accentGreen,
                                onChanged: (val) => LocationSharingController
                                    .instance
                                    .setEnabled(val),
                              ),
                            ),
                            _buildRow(
                              icon: isDark
                                  ? Icons.dark_mode_outlined
                                  : Icons.light_mode_outlined,
                              label: 'Appearance',
                              onTap: () => themeController.toggle(),
                              trailingWidget: Switch.adaptive(
                                value: isDark,
                                activeColor: AppColors.accentBlue,
                                onChanged: (_) => themeController.toggle(),
                              ),
                            ),
                          ]);
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  _buildSectionLabel('Session'),
                  _buildCard([
                    _buildRow(
                      icon: Icons.logout,
                      label: 'Log out',
                      labelColor: AppColors.accentRed,
                      iconColor: AppColors.accentRed,
                      onTap: _confirmLogout,
                    ),
                  ]),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- HEADER: wave background + avatar + name + contact line ---

  Widget _buildHeader({
    required String name,
    required String avatarUrl,
    required String contactLine,
    required VoidCallback onTapAvatar,
  }) {
    const double waveHeight = 128;
    const double avatarSize = 108;

    return SizedBox(
      height: waveHeight + avatarSize / 2 + 78,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipPath(
            clipper: _WaveClipper(),
            child: Container(height: waveHeight, color: AppColors.sunken(context)),
          ),
          Positioned(
            top: waveHeight - avatarSize / 2,
            left: 0,
            right: 0,
            child: Column(
              children: [
                GestureDetector(
                  onTap: onTapAvatar,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: avatarSize,
                        height: avatarSize,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.bg(context),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.12),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: Container(
                            color: AppColors.card(context),
                            child: avatarUrl.isNotEmpty
                                ? Image.network(
                                    avatarUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Center(
                                      child: Text(_getInitials(name),
                                          style: TextStyle(
                                              color: AppColors.textMuted(context),
                                              fontSize: 32,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  )
                                : Center(
                                    child: Text(_getInitials(name),
                                        style: TextStyle(
                                            color: AppColors.textMuted(context),
                                            fontSize: 32,
                                            fontWeight: FontWeight.bold)),
                                  ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 2,
                        right: 2,
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.card(context),
                            border: Border.all(color: AppColors.border(context)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.edit,
                              size: 14, color: AppColors.accentBlue),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(name,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 19,
                        fontWeight: FontWeight.bold)),
                if (contactLine.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(contactLine,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppColors.textMuted(context), fontSize: 12.5)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- SECTION LABEL ---

  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: AppColors.textMuted(context),
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  // --- FLAT GROUPED CARD + ROW ---

  Widget _buildCard(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Widget _buildRow({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    String? trailing,
    Widget? trailingWidget,
    Color? statusDotColor,
    Color? labelColor,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: 18, vertical: trailingWidget != null ? 8 : 15),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor ?? AppColors.textMuted(context)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: labelColor ?? AppColors.textMain(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
            ),
            if (statusDotColor != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: statusDotColor),
              ),
              const SizedBox(width: 6),
            ],
            if (trailingWidget != null)
              trailingWidget
            else if (trailing != null)
              Text(trailing,
                  style: const TextStyle(
                      color: AppColors.accentBlue,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // --- EDIT PROFILE ---

  void _openEditProfileSheet({
    required String firstName,
    required String middleName,
    required String lastName,
    required String phone,
    required String role,
    required String purok,
    required String avatarUrl,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditProfileSheet(
        firstName: firstName,
        middleName: middleName,
        lastName: lastName,
        phone: phone,
        role: role,
        roleRequiresPurok: _roleRequiresPurok(role),
        purok: purok,
        avatarUrl: avatarUrl,
        onSaved: () {
          _loadProfile();
          AppToast.success(context, 'Profile updated');
        },
      ),
    );
  }

  // --- CHANGE PASSWORD ---

  void _openChangePasswordSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ChangePasswordSheet(
        onSaved: () => AppToast.success(context, 'Password updated'),
      ),
    );
  }

  // --- LOGOUT ---

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.border(context)),
        ),
        title:
            Text('Log out?', style: TextStyle(color: AppColors.textMain(context))),
        content: Text('You will need to sign in again to continue.',
            style: TextStyle(color: AppColors.textMuted(context))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                Text('CANCEL', style: TextStyle(color: AppColors.textMuted(context))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('LOG OUT',
                style:
                    TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Stop broadcasting and mark this user's live_gps row as "not sharing"
    // BEFORE signing out — after signOut() there's no session, so the
    // UPDATE would be rejected by RLS.
    await LocationTrackingService.instance.stopAndMarkOffline();

    // Same order as AppSidebar's onLogout on desktop: drop cached realtime
    // channels first, then sign out. This assumes an auth-state listener
    // higher up (e.g. AuthGate) swaps to the login screen automatically
    // once signOut() fires.
    RealtimeStreamService.instance.clear();
    await Supabase.instance.client.auth.signOut();
  }
}

/// Shallow downward arc clipped from a rectangle — the soft "wave" band
/// behind the avatar in the reference design.
class _WaveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.lineTo(0, size.height - 36);
    path.quadraticBezierTo(
      size.width / 2,
      size.height + 36,
      size.width,
      size.height - 36,
    );
    path.lineTo(size.width, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

// ============================================================
// EDIT PROFILE SHEET
// ============================================================

class _EditProfileSheet extends StatefulWidget {
  final String firstName;
  final String middleName;
  final String lastName;
  final String phone;
  final String role;
  final bool roleRequiresPurok;
  final String purok;
  final String avatarUrl;
  final VoidCallback onSaved;

  const _EditProfileSheet({
    required this.firstName,
    required this.middleName,
    required this.lastName,
    required this.phone,
    required this.role,
    required this.roleRequiresPurok,
    required this.purok,
    required this.avatarUrl,
    required this.onSaved,
  });

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstController;
  late final TextEditingController _middleController;
  late final TextEditingController _lastController;
  late final TextEditingController _phoneController;

  Uint8List? _pickedBytes;
  String? _pickedExt;
  bool _isPickerOpen = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _firstController = TextEditingController(text: widget.firstName);
    _middleController = TextEditingController(text: widget.middleName);
    _lastController = TextEditingController(text: widget.lastName);
    _phoneController = TextEditingController(text: widget.phone);
  }

  @override
  void dispose() {
    _firstController.dispose();
    _middleController.dispose();
    _lastController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    if (_isPickerOpen) return;
    _isPickerOpen = true;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.')
          ? picked.name.split('.').last.toLowerCase()
          : 'jpg';
      if (!mounted) return;
      setState(() {
        _pickedBytes = bytes;
        _pickedExt = ext;
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Could not select image: $e');
    } finally {
      _isPickerOpen = false;
    }
  }

  String? _required(String? v, String field) =>
      (v == null || v.trim().isEmpty) ? '$field is required' : null;

  String? _validatePhone(String? v) {
    if (v == null || v.trim().isEmpty) return 'Phone number is required';
    if (!RegExp(r'^[0-9]{10,13}$').hasMatch(v.trim())) {
      return 'Enter a valid phone number (10-13 digits)';
    }
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    setState(() => _saving = true);
    try {
      String? avatarUrl = widget.avatarUrl.isEmpty ? null : widget.avatarUrl;

      if (_pickedBytes != null) {
        final storage = Supabase.instance.client.storage.from('avatars');
        final ext = _pickedExt ?? 'jpg';
        final path = '$userId/avatar.$ext';
        await storage.uploadBinary(
          path,
          _pickedBytes!,
          fileOptions: const FileOptions(upsert: true),
        );
        avatarUrl =
            '${storage.getPublicUrl(path)}?updated=${DateTime.now().millisecondsSinceEpoch}';
      }

      final newFirst = _firstController.text.trim();
      final newMiddle = _middleController.text.trim();
      final newLast = _lastController.text.trim();
      final newPhone = _phoneController.text.trim();

      // Route the whole update through the `update-user` Edge Function.
      // It runs with the service-role key server-side and calls
      // auth.admin.updateUserById(), which writes `phone`/user_metadata
      // directly to auth.users with NO OTP/verification step — that's the
      // admin API, distinct from the client-side auth.updateUser() flow
      // used above for password changes, which always requires
      // verification for the signed-in user's own account.
      final functionResponse =
          await Supabase.instance.client.functions.invoke(
        'update-user',
        body: {
          'userId': userId,
          'phoneNumber': newPhone,
          'firstName': newFirst,
          'middleName': newMiddle,
          'lastName': newLast,
          'role': widget.role,
          'purok': widget.roleRequiresPurok ? widget.purok : null,
          if (avatarUrl != null) 'avatarUrl': avatarUrl,
        },
      );

      if (functionResponse.status != 200) {
        final body = functionResponse.data;
        final message = (body is Map && body['error'] != null)
            ? body['error'].toString()
            : 'Failed to update profile (status ${functionResponse.status}).';
        throw Exception(message);
      }

      if (!mounted) return;
      widget.onSaved();
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _pickedBytes != null || widget.avatarUrl.isNotEmpty;
    final canSave = !_saving;

    return _SheetShell(
      title: 'Edit Profile',
      onClose: () => Navigator.pop(context),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: GestureDetector(
                onTap: _isPickerOpen ? null : _pickAvatar,
                child: Stack(
                  children: [
                    ClipOval(
                      child: Container(
                        width: 96,
                        height: 96,
                        color: AppColors.sunken(context),
                        child: _pickedBytes != null
                            ? Image.memory(_pickedBytes!, fit: BoxFit.cover)
                            : hasImage
                                ? Image.network(widget.avatarUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Icon(
                                        Icons.person,
                                        color: AppColors.textMuted(context),
                                        size: 40))
                                : Icon(Icons.person,
                                    color: AppColors.textMuted(context), size: 40),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppColors.accentBlue,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: AppColors.card(context), width: 2),
                        ),
                        child:
                            const Icon(Icons.camera_alt, color: Colors.white, size: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _SheetField(
              label: 'FIRST NAME',
              controller: _firstController,
              hint: 'John',
              isRequired: true,
              validator: (v) => _required(v, 'First name'),
            ),
            const SizedBox(height: 12),
            _SheetField(
              label: 'MIDDLE NAME',
              controller: _middleController,
              hint: 'S',
            ),
            const SizedBox(height: 12),
            _SheetField(
              label: 'LAST NAME',
              controller: _lastController,
              hint: 'Doe',
              isRequired: true,
              validator: (v) => _required(v, 'Last name'),
            ),
            const SizedBox(height: 12),
            _SheetField(
              label: 'PHONE NUMBER',
              controller: _phoneController,
              hint: '09123456789',
              isRequired: true,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(13),
              ],
              validator: _validatePhone,
            ),
            if (widget.roleRequiresPurok) ...[
              const SizedBox(height: 12),
              _SheetField(
                label: 'PUROK',
                controller: TextEditingController(text: widget.purok),
                hint: '—',
                enabled: false,
              ),
              const SizedBox(height: 4),
              Text('Purok is managed by Command Center.',
                  style: TextStyle(
                      color: AppColors.textMuted(context), fontSize: 11)),
            ],
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canSave ? _save : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentBlue,
                  disabledBackgroundColor: AppColors.accentBlue.withOpacity(0.4),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _saving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('SAVE CHANGES',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CHANGE PASSWORD SHEET
// ============================================================

class _ChangePasswordSheet extends StatefulWidget {
  final VoidCallback onSaved;

  const _ChangePasswordSheet({required this.onSaved});

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _formKey = GlobalKey<FormState>();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String? _validatePassword(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < 6) return 'Must be at least 6 characters';
    return null;
  }

  String? _validateConfirm(String? v) {
    if (v == null || v.isEmpty) return 'Please confirm the password';
    if (v != _newPasswordController.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      // This one genuinely updates Supabase Auth's password directly — it
      // was always in sync, unlike phone/name which live in profiles too.
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: _newPasswordController.text),
      );
      if (!mounted) return;
      widget.onSaved();
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      title: 'Change Password',
      onClose: () => Navigator.pop(context),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetField(
              label: 'NEW PASSWORD',
              controller: _newPasswordController,
              hint: '••••••••',
              isPassword: true,
              isRequired: true,
              validator: _validatePassword,
            ),
            const SizedBox(height: 12),
            _SheetField(
              label: 'CONFIRM NEW PASSWORD',
              controller: _confirmPasswordController,
              hint: '••••••••',
              isPassword: true,
              isRequired: true,
              validator: _validateConfirm,
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentBlue,
                  disabledBackgroundColor: AppColors.accentBlue.withOpacity(0.4),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _saving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('UPDATE PASSWORD',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// SHARED SHEET CHROME + FIELD
// ============================================================

/// Common bottom-sheet chrome (drag handle, title + close, keyboard-safe
/// padding) shared by the edit-profile and change-password sheets.
class _SheetShell extends StatelessWidget {
  final String title;
  final VoidCallback onClose;
  final Widget child;

  const _SheetShell({
    required this.title,
    required this.onClose,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints:
                BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.border(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(title,
                          style: TextStyle(
                              color: AppColors.textMain(context),
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      InkWell(
                        onTap: onClose,
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close,
                              color: AppColors.textMuted(context), size: 20),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Labeled text field matching UsersScreen's `_buildInputField` styling.
class _SheetField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final bool isPassword;
  final bool enabled;
  final bool isRequired;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;

  const _SheetField({
    required this.label,
    required this.controller,
    required this.hint,
    this.isPassword = false,
    this.enabled = true,
    this.isRequired = false,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color color, {double width = 1}) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: TextStyle(
                    color: AppColors.textMuted(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
            if (isRequired) ...[
              const SizedBox(width: 3),
              const Text('*',
                  style: TextStyle(
                      color: AppColors.accentRed,
                      fontSize: 12,
                      fontWeight: FontWeight.w800)),
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
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
}