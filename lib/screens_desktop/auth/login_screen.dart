// lib/screens_desktop/login_screen.dart
//
// Centered card login with clear states: inline validation, an error
// banner, caps lock warning, loading state, and a forgot-password dialog.
// AuthGate listens to onAuthStateChange, so no navigation is needed here.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Adjust this path to wherever your login screen lives.
import '../../constants/app_colors.dart';

final RegExp _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? _validateEmail(String? v) {
  final value = (v ?? '').trim();
  if (value.isEmpty) return 'Enter your email address';
  if (!_emailRegex.hasMatch(value)) return 'That doesn\'t look like an email address';
  return null;
}

// =============================================================================
// LOGIN SCREEN
// =============================================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

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
  bool _capsLockOn = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _passwordFocus.addListener(_syncCapsLock);
  }

  void _syncCapsLock() {
    final on = HardwareKeyboard.instance.lockModesEnabled
        .contains(KeyboardLockMode.capsLock);
    if (on != _capsLockOn && mounted) setState(() => _capsLockOn = on);
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // No Navigator call needed: AuthGate swaps to DesktopShell on success.
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      TextInput.finishAutofillContext();
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _errorMessage = _friendlyError(e.message));
        _passwordFocus.requestFocus();
      }
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

  Future<void> _openForgotPasswordDialog() {
    return showDialog(
      context: context,
      builder: (_) =>
          _ForgotPasswordDialog(prefillEmail: _emailController.text.trim()),
    );
  }

  @override
  void dispose() {
    _passwordFocus.removeListener(_syncCapsLock);
    _emailController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Stack(
        children: [
          // Faint dot grid so the page isn't a flat color.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _DotGridPainter(
                  AppColors.border(context).withOpacity(isDark ? 0.7 : 0.9),
                ),
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildBrand(),
                    const SizedBox(height: 24),
                    _buildCard(isDark),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrand() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.accentBlue,
            borderRadius: BorderRadius.circular(10),
          ),
          child:
              const Icon(Icons.shield_outlined, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 12),
        Text(
          'SAFEWATCH',
          style: TextStyle(
            color: AppColors.textMain(context),
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.8,
          ),
        ),
      ],
    );
  }

  Widget _buildCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.35 : 0.06),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Welcome back',
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Sign in to monitor cameras, alerts, and incidents.',
                style: TextStyle(
                  color: AppColors.textMuted(context),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),

              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: _errorMessage == null
                    ? const SizedBox(width: double.infinity)
                    : _ErrorBanner(
                        message: _errorMessage!,
                        margin: const EdgeInsets.only(bottom: 18),
                      ),
              ),

              const _FieldLabel('Email address'),
              const SizedBox(height: 6),
              TextFormField(
                controller: _emailController,
                enabled: !_isLoading,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                autocorrect: false,
                enableSuggestions: false,
                onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                style:
                    TextStyle(color: AppColors.textMain(context), fontSize: 14.5),
                decoration: _fieldDecoration(context,
                    hint: 'you@example.com', icon: Icons.mail_outline),
                validator: _validateEmail,
              ),
              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const _FieldLabel('Password'),
                  InkWell(
                    onTap: _isLoading ? null : _openForgotPasswordDialog,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                      child: Text(
                        'Forgot password?',
                        style: TextStyle(
                          color: AppColors.accentBlue,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _passwordController,
                focusNode: _passwordFocus,
                enabled: !_isLoading,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                onChanged: (_) => _syncCapsLock(),
                onFieldSubmitted: (_) => _isLoading ? null : _login(),
                style:
                    TextStyle(color: AppColors.textMain(context), fontSize: 14.5),
                decoration: _fieldDecoration(
                  context,
                  hint: 'Enter your password',
                  icon: Icons.lock_outline,
                  suffixIcon: IconButton(
                    tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                    splashRadius: 18,
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: AppColors.textMuted(context),
                      size: 19,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Enter your password' : null,
              ),

              // Caps lock hint — only takes space when it's needed.
              AnimatedSize(
                duration: const Duration(milliseconds: 150),
                alignment: Alignment.topLeft,
                child: _capsLockOn
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Icon(Icons.keyboard_capslock,
                                size: 15, color: AppColors.accentBlue),
                            const SizedBox(width: 6),
                            Text(
                              'Caps Lock is on',
                              style: TextStyle(
                                  color: AppColors.textMuted(context),
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 24),

              SizedBox(
                height: 46,
                child: FilledButton(
                  onPressed: _isLoading ? null : _login,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentBlue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        AppColors.accentBlue.withOpacity(0.55),
                    disabledForegroundColor: Colors.white70,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _isLoading
                        ? const Row(
                            key: ValueKey('loading'),
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              ),
                              SizedBox(width: 12),
                              Text('Signing in…'),
                            ],
                          )
                        : const Text('Sign in', key: ValueKey('idle')),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline,
                      size: 13, color: AppColors.textMuted(context)),
                  const SizedBox(width: 6),
                  Text(
                    'Authorized personnel only',
                    style: TextStyle(
                        color: AppColors.textMuted(context), fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SHARED PIECES
// =============================================================================

class _DotGridPainter extends CustomPainter {
  final Color color;
  _DotGridPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 28.0;
    for (double y = step / 2; y < size.height; y += step) {
      for (double x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => old.color != color;
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final EdgeInsetsGeometry margin;
  const _ErrorBanner({required this.message, this.margin = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.accentRed.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accentRed.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: AppColors.accentRed, size: 17),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  color: AppColors.accentRed, fontSize: 12.5, height: 1.35),
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
        color: AppColors.textMain(context),
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

InputDecoration _fieldDecoration(
  BuildContext context, {
  required String hint,
  required IconData icon,
  Widget? suffixIcon,
}) {
  OutlineInputBorder border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: color, width: width),
      );

  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(
        color: AppColors.textMuted(context).withOpacity(0.8), fontSize: 14),
    prefixIcon: Icon(icon, color: AppColors.textMuted(context), size: 19),
    suffixIcon: suffixIcon,
    filled: true,
    fillColor: AppColors.sunken(context),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
    border: border(AppColors.border(context)),
    enabledBorder: border(AppColors.border(context)),
    disabledBorder: border(AppColors.border(context)),
    focusedBorder: border(AppColors.accentBlue, width: 1.5),
    errorBorder: border(AppColors.accentRed),
    focusedErrorBorder: border(AppColors.accentRed, width: 1.5),
    errorStyle: TextStyle(color: AppColors.accentRed, fontSize: 11.5),
  );
}

// =============================================================================
// FORGOT PASSWORD DIALOG
// =============================================================================

/// Sends a Supabase password-reset link. Always shows the success state, even
/// if the email doesn't exist, so it can't be used to find accounts.
class _ForgotPasswordDialog extends StatefulWidget {
  final String prefillEmail;
  const _ForgotPasswordDialog({required this.prefillEmail});

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border(context)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.4 : 0.10),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _sent ? _buildSent() : _buildForm(),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Reset your password',
            style: TextStyle(
              color: AppColors.textMain(context),
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Enter the email linked to your account and we'll send you a link to reset your password.",
            style: TextStyle(
                color: AppColors.textMuted(context), fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 18),
          if (_errorMessage != null)
            _ErrorBanner(
              message: _errorMessage!,
              margin: const EdgeInsets.only(bottom: 14),
            ),
          const _FieldLabel('Email address'),
          const SizedBox(height: 6),
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
            style: TextStyle(color: AppColors.textMain(context), fontSize: 14.5),
            decoration: _fieldDecoration(context,
                hint: 'you@example.com', icon: Icons.mail_outline),
            validator: _validateEmail,
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      _isSending ? null : () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textMain(context),
                    side: BorderSide(color: AppColors.border(context)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _isSending ? null : _sendResetLink,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentBlue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        AppColors.accentBlue.withOpacity(0.55),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  child: _isSending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Send reset link'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppColors.accentGreen.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.mark_email_read_outlined,
              color: AppColors.accentGreen, size: 26),
        ),
        const SizedBox(height: 16),
        Text(
          'Check your inbox',
          style: TextStyle(
            color: AppColors.textMain(context),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'If an account exists for ${_emailController.text.trim()}, '
          'a password reset link is on its way.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: AppColors.textMuted(context), fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}