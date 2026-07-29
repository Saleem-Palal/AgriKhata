import 'package:agrikhata/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Toast priority drives color and on-screen duration.
enum AppToastPriority {
  /// Red — critical errors (45s).
  high,

  /// Orange — warnings (30s).
  medium,

  /// Green — success / low-priority confirmations (8s).
  low,

  /// Blue — informational messages (5s).
  info,
}

/// Floating rounded snack banner matching the AgriKhata design reference.
class AppToast {
  AppToast._();

  static const Color _high = Color(0xFFC62828);
  static const Color _medium = Color(0xFFE67E22);
  static const Color _low = Color(0xFF1B4332);
  static const Color _info = Color(0xFF1565C0);

  static Color colorFor(AppToastPriority priority) {
    switch (priority) {
      case AppToastPriority.high:
        return _high;
      case AppToastPriority.medium:
        return _medium;
      case AppToastPriority.low:
        return _low;
      case AppToastPriority.info:
        return _info;
    }
  }

  static Duration durationFor(AppToastPriority priority) {
    switch (priority) {
      case AppToastPriority.high:
        return const Duration(seconds: 45);
      case AppToastPriority.medium:
        return const Duration(seconds: 30);
      case AppToastPriority.low:
        return const Duration(seconds: 8);
      case AppToastPriority.info:
        return const Duration(seconds: 5);
    }
  }

  /// Generic show with explicit priority.
  static void show(
    BuildContext context,
    String message, {
    AppToastPriority priority = AppToastPriority.low,
  }) {
    _present(context, message: message, priority: priority);
  }

  /// Green success banner (8s).
  static void showSuccess(BuildContext context, String message) {
    _present(context, message: message, priority: AppToastPriority.low);
  }

  /// Red error banner (45s).
  static void showError(BuildContext context, String message) {
    _present(context, message: message, priority: AppToastPriority.high);
  }

  /// Orange warning banner (30s).
  static void showWarning(BuildContext context, String message) {
    _present(context, message: message, priority: AppToastPriority.medium);
  }

  /// Blue info banner (5s).
  static void showInfo(BuildContext context, String message) {
    _present(context, message: message, priority: AppToastPriority.info);
  }

  static void _present(
    BuildContext context, {
    required String message,
    required AppToastPriority priority,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: durationFor(priority),
        backgroundColor: colorFor(priority),
        elevation: 6,
        margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: 14,
        ),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}
