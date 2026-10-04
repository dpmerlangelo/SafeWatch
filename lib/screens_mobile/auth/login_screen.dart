// lib/screens_mobile/login_screen.dart
//
// Mobile login for tanod and purok leader accounts. Follows light/dark mode
// from the app theme (Theme.of(context).brightness), laid out for phones:
// full-screen form, thumb-sized controls, keyboard-friendly scrolling, and a
// bottom sheet for password reset.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Shared theme constants — kept identical to the rest of the app so
/// every screen reads as one product. These are the DARK values and are left
/// unchanged so other files that use them keep working. This screen itself
/// uses [_Palette] below, which switches between light and dark.
/// If you've already created lib/theme/app_theme.dart, delete this class and
/// `import '../theme/app_theme.dart';` instead.
class AppColors {
  static const Color bgDark = Color(0xFF121316);
  static const Color cardDark = Color(0xFF1A1C20);
  static const Color cardDarkAlt = Color(0xFF17191D);
  static const Color accentBlue = Color(0xFF2082E2);
  static const Color dangerRed = Color(0xFFE53935);
  static const Color success = Color(0xFF10B981);
  static const Color textMain = Color(0xFFE1E4EA);
  static const Color textMuted = Color(0xFF8A8F9B);
  static const Color border = Color(0xFF262930);
}

/// Colors for this screen, resolved from the current theme brightness.
/// Accent, danger, and success colors are the same in both modes.
class _Palette {
  final Color bg;
  final Color field; // input fill + bottom sheet background
  final Color border;
  final Color textMain;
  final Color textMuted;
  final Color errorText;
  final bool isDark;

  const _Palette._({
    required this.bg,
    required this.field,
    required this.border,
    required this.textMain,
    required this.textMuted,
    required this.errorText,
    required this.isDark,
  });

  static const _Palette _dark = _Palette._(
    bg: Color(0xFF121316),
    field: Color(0xFF1A1C20),
    border: Color(0xFF262930),
    textMain: Color(0xFFE1E4EA),
    textMuted: Color(0xFF8A8F9B),
    errorText: Color(0xFFEF9A9A),
    isDark: true,
  );

  static const _Palette _light = _Palette._(
    bg: Color(0xFFF5F6F8),
    field: Color(0xFFFFFFFF),
    border: Color(0xFFDDE1E7),
    textMain: Color(0xFF1A1C20),
    textMuted: Color(0xFF6B7280),
    errorText: Color(0xFFC62828),
    isDark: false,
  );

  static _Palette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  static const Color accent = AppColors.accentBlue;
  static const Color danger = AppColors.dangerRed;
  static const Color success = AppColors.success;
}

final RegExp _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? _validateEmail(String? v) {
  final value = (v ?? '').trim();
  if (value.isEmpty) return 'Enter your email address';
  if (!_emailRegex.hasMatch(value)) return "That doesn't look like an email address";
  return null;
}

// =============================================================================
// LOGIN SCREEN
// =============================================================================

class LoginScreen extends StatefulWidget {
  /// Optional message shown as soon as the screen mounts — used by
  /// AuthGate to explain *why* the user was bounced back here (e.g.
  /// they signed in with a non-tanod account on the mobile app).
  final String? initialError;

  const LoginScreen({super.key, this.initialError});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocus = FocusNode();

  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _errorMessage = widget.initialError;
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // No Navigator call needed — AuthGate listens to onAuthStateChange
      // and swaps to the right home screen automatically on success.
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      TextInput.finishAutofillContext();
    } on AuthException catch (e) {
      if (mounted) setState(() => _errorMessage = _friendlyError(e.message));
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage =
            "Couldn't reach the server. Check your connection and try again.");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _friendlyError(String message) {
    if (message.contains('Invalid login credentials')) {
      return 'Incorrect email or password. Check both and try again.';
    }
    if (message.contains('Email not confirmed')) {
      return 'Confirm your email before signing in.';
    }
    if (message.contains('Too many requests')) {
      return 'Too many attempts. Wait a moment and try again.';
    }
    return message;
  }

  Future<void> _openForgotPassword() {
    final p = _Palette.of(context);
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.field,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) =>
          _ForgotPasswordSheet(prefillEmail: _emailController.text.trim()),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette.of(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Keep status bar icons readable in both modes.
      value: (p.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: p.bg,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            child: Center(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: AutofillGroup(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _BrandMark(),
                          const SizedBox(height: 40),
                          Text(
                            'Sign in',
                            style: TextStyle(
                              color: p.textMain,
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'For task force, tanod, and purok leader accounts.',
                            style: TextStyle(
                              color: p.textMuted,
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 28),

                          AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            alignment: Alignment.topCenter,
                            child: _errorMessage == null
                                ? const SizedBox(width: double.infinity)
                                : _ErrorBanner(
                                    message: _errorMessage!,
                                    margin: const EdgeInsets.only(bottom: 20),
                                  ),
                          ),

                          const _FieldLabel('Email address'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _emailController,
                            enabled: !_isLoading,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.email],
                            autocorrect: false,
                            enableSuggestions: false,
                            onFieldSubmitted: (_) =>
                                _passwordFocus.requestFocus(),
                            autovalidateMode:
                                AutovalidateMode.onUserInteraction,
                            style: TextStyle(color: p.textMain, fontSize: 15),
                            decoration: _fieldDecoration(
                              p,
                              hint: 'you@example.com',
                              icon: Icons.mail_outline,
                            ),
                            validator: _validateEmail,
                          ),
                          const SizedBox(height: 20),

                          const _FieldLabel('Password'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _passwordController,
                            focusNode: _passwordFocus,
                            enabled: !_isLoading,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.password],
                            onFieldSubmitted: (_) =>
                                _isLoading ? null : _login(),
                            style: TextStyle(color: p.textMain, fontSize: 15),
                            decoration: _fieldDecoration(
                              p,
                              hint: 'Enter your password',
                              icon: Icons.lock_outline,
                              suffixIcon: IconButton(
                                tooltip: _obscurePassword
                                    ? 'Show password'
                                    : 'Hide password',
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  color: p.textMuted,
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword),
                              ),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Enter your password'
                                : null,
                          ),

                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed:
                                  _isLoading ? null : _openForgotPassword,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 44),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                foregroundColor: _Palette.accent,
                                textStyle: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                              child: const Text('Forgot password?'),
                            ),
                          ),
                          const SizedBox(height: 12),

                          SizedBox(
                            height: 52,
                            child: FilledButton(
                              onPressed: _isLoading ? null : _login,
                              style: FilledButton.styleFrom(
                                backgroundColor: _Palette.accent,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor:
                                    _Palette.accent.withOpacity(0.55),
                                disabledForegroundColor: Colors.white70,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                textStyle: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: _isLoading
                                    ? const Row(
                                        key: ValueKey('loading'),
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white),
                                          ),
                                          SizedBox(width: 12),
                                          Text('Signing in…'),
                                        ],
                                      )
                                    : const Text('Sign in',
                                        key: ValueKey('idle')),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SHARED PIECES
// =============================================================================

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final p = _Palette.of(context);
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _Palette.accent,
            borderRadius: BorderRadius.circular(10),
          ),
          child:
              const Icon(Icons.shield_outlined, color: Colors.white, size: 21),
        ),
        const SizedBox(width: 12),
        Text(
          'SAFEWATCH',
          style: TextStyle(
            color: p.textMain,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.8,
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final EdgeInsetsGeometry margin;
  const _ErrorBanner({required this.message, this.margin = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    final p = _Palette.of(context);
    return Container(
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _Palette.danger.withOpacity(p.isDark ? 0.10 : 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _Palette.danger.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: _Palette.danger, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: p.errorText,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: _Palette.of(context).textMain,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

InputDecoration _fieldDecoration(
  _Palette p, {
  required String hint,
  required IconData icon,
  Widget? suffixIcon,
}) {
  OutlineInputBorder border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: p.textMuted, fontSize: 14.5),
    prefixIcon: Icon(icon, color: p.textMuted, size: 20),
    suffixIcon: suffixIcon,
    filled: true,
    fillColor: p.field,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
    border: border(p.border),
    enabledBorder: border(p.border),
    disabledBorder: border(p.border),
    focusedBorder: border(_Palette.accent, width: 1.5),
    errorBorder: border(_Palette.danger),
    focusedErrorBorder: border(_Palette.danger, width: 1.5),
    errorStyle: TextStyle(color: p.errorText, fontSize: 12),
  );
}

// =============================================================================
// FORGOT PASSWORD — bottom sheet
// =============================================================================

/// Collects an email and sends a Supabase password-reset link. Always shows
/// the success state after sending — even if the email doesn't exist — so
/// the sheet can't be used to find accounts.
class _ForgotPasswordSheet extends StatefulWidget {
  final String prefillEmail;
  const _ForgotPasswordSheet({required this.prefillEmail});

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  late final TextEditingController _emailController =
      TextEditingController(text: widget.prefillEmail);
  final _formKey = GlobalKey<FormState>();

  bool _isSending = false;
  bool _sent = false;
  String? _errorMessage;

  Future<void> _sendResetLink() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isSending = true;
      _errorMessage = null;
    });

    try {
      await Supabase.instance.client.auth
          .resetPasswordForEmail(_emailController.text.trim());
      if (mounted) setState(() => _sent = true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _errorMessage = "Couldn't reach the server. Please try again.");
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette.of(context);
    // Lift the sheet above the keyboard.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + bottomInset),
        child: SingleChildScrollView(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: p.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _sent ? _buildSent(p) : _buildForm(p),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(_Palette p) {
    // The sheet background is the same color as the input fill in dark mode,
    // so inputs inside the sheet use the page background to stay visible.
    final fieldPalette = p.isDark ? _Palette._dark.withSheetFields() : p;

    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Reset your password',
            style: TextStyle(
              color: p.textMain,
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Enter the email linked to your account and we'll send you a link to reset your password.",
            style: TextStyle(color: p.textMuted, fontSize: 13.5, height: 1.45),
          ),
          const SizedBox(height: 20),
          if (_errorMessage != null)
            _ErrorBanner(
              message: _errorMessage!,
              margin: const EdgeInsets.only(bottom: 16),
            ),
          const _FieldLabel('Email address'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _emailController,
            autofocus: true,
            enabled: !_isSending,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            enableSuggestions: false,
            onFieldSubmitted: (_) => _isSending ? null : _sendResetLink(),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            style: TextStyle(color: p.textMain, fontSize: 15),
            decoration: _fieldDecoration(
              fieldPalette,
              hint: 'you@example.com',
              icon: Icons.mail_outline,
            ),
            validator: _validateEmail,
          ),
          const SizedBox(height: 22),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _isSending ? null : _sendResetLink,
              style: FilledButton.styleFrom(
                backgroundColor: _Palette.accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _Palette.accent.withOpacity(0.55),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              child: _isSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Send reset link'),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: _isSending ? null : () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: p.textMuted,
              textStyle:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildSent(_Palette p) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: _Palette.success.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mark_email_read_outlined,
                color: _Palette.success, size: 28),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Check your inbox',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: p.textMain,
            fontSize: 19,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'If an account exists for ${_emailController.text.trim()}, '
          'a password reset link is on its way.',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.textMuted, fontSize: 13.5, height: 1.45),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: _Palette.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              textStyle:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

extension on _Palette {
  /// In dark mode the sheet and the input fill are the same color, so the
  /// input inside the sheet is filled with the page background instead.
  _Palette withSheetFields() => _Palette._(
        bg: bg,
        field: bg,
        border: border,
        textMain: textMain,
        textMuted: textMuted,
        errorText: errorText,
        isDark: isDark,
      );
}