import 'dart:async';
import 'package:flutter/material.dart';
import '../constants/app_colors.dart';

/// Bottom-right toast notification that follows the app theme (light/dark).
/// Colors come from [AppColors], the same helpers the screens use, so the
/// toast switches with the theme automatically, even while it is on screen.
///
/// Usage:
///   AppToast.success(context, 'Camera updated successfully');
///   AppToast.error(context, 'Failed to remove camera: $e');
///   AppToast.info(context, 'No cameras found on this network.');
enum AppToastType { success, error, info }

class AppToast {
  AppToast._();

  // Tracks how many toasts are currently stacked so new ones appear above
  // older ones instead of overlapping.
  static int _activeCount = 0;

  static void show(
    BuildContext context, {
    required String message,
    AppToastType type = AppToastType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final index = _activeCount++;
    late OverlayEntry entry;
    bool removed = false;

    void removeOnce() {
      if (removed) return;
      removed = true;
      entry.remove();
      _activeCount--;
    }

    entry = OverlayEntry(
      builder: (_) => _ToastCard(
        message: message,
        type: type,
        duration: duration,
        bottomOffset: 20.0 + index * 62.0,
        onDismissed: removeOnce,
      ),
    );

    overlay.insert(entry);
  }

  static void success(BuildContext context, String message,
          {Duration duration = const Duration(seconds: 3)}) =>
      show(context,
          message: message, type: AppToastType.success, duration: duration);

  static void error(BuildContext context, String message,
          {Duration duration = const Duration(seconds: 4)}) =>
      show(context,
          message: message, type: AppToastType.error, duration: duration);

  static void info(BuildContext context, String message,
          {Duration duration = const Duration(seconds: 3)}) =>
      show(context,
          message: message, type: AppToastType.info, duration: duration);
}

class _ToastCard extends StatefulWidget {
  final String message;
  final AppToastType type;
  final Duration duration;
  final double bottomOffset;
  final VoidCallback onDismissed;

  const _ToastCard({
    required this.message,
    required this.type,
    required this.duration,
    required this.bottomOffset,
    required this.onDismissed,
  });

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.25),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);

  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _timer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _timer?.cancel();
    if (mounted) {
      await _controller.reverse();
    }
    widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Color get _accentColor {
    switch (widget.type) {
      case AppToastType.success:
        return AppColors.accentGreen;
      case AppToastType.error:
        return AppColors.accentRed;
      case AppToastType.info:
        return AppColors.accentBlue;
    }
  }

  IconData get _icon {
    switch (widget.type) {
      case AppToastType.success:
        return Icons.check_circle_outline;
      case AppToastType.error:
        return Icons.error_outline;
      case AppToastType.info:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Soften the shadow in light mode so it doesn't look heavy.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = _accentColor;

    return Positioned(
      right: 20,
      bottom: widget.bottomOffset,
      child: SafeArea(
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _fade,
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 380, minWidth: 260),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                  decoration: BoxDecoration(
                    color: AppColors.card(context),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border(context)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.35 : 0.12),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(isDark ? 0.12 : 0.14),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(_icon, color: accent, size: 16),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            widget.message,
                            style: TextStyle(
                              color: AppColors.textMain(context),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: _dismiss,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close,
                              size: 14, color: AppColors.textMuted(context)),
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
    );
  }
}