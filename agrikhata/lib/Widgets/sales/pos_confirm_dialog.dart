import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// Desktop POS confirm dialog: Enter = Yes, Esc = No.
class PosConfirmDialog extends StatefulWidget {
  final String title;
  final String message;
  final String yesLabel;
  final String noLabel;
  final bool danger;

  const PosConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.yesLabel = 'Yes (Enter)',
    this.noLabel = 'No (Esc)',
    this.danger = false,
  });

  /// Returns `true` for Yes, `false` for No, `null` if dismissed.
  static Future<bool> ask({
    required BuildContext context,
    required String title,
    required String message,
    String yesLabel = 'Yes (Enter)',
    String noLabel = 'No (Esc)',
    bool danger = false,
    bool barrierDismissible = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (_) => PosConfirmDialog(
        title: title,
        message: message,
        yesLabel: yesLabel,
        noLabel: noLabel,
        danger: danger,
      ),
    );
    return result == true;
  }

  @override
  State<PosConfirmDialog> createState() => _PosConfirmDialogState();
}

class _PosConfirmDialogState extends State<PosConfirmDialog> {
  final FocusNode _yesFocus = FocusNode(debugLabel: 'posConfirmYes');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _yesFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _yesFocus.dispose();
    super.dispose();
  }

  void _pop(bool value) {
    if (!mounted) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final yesColor = widget.danger
        ? const Color(0xFFA32D2D)
        : const Color(0xFF1B4332);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () => _pop(true),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () => _pop(true),
        const SingleActivator(LogicalKeyboardKey.escape): () => _pop(false),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.message,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _pop(false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textMuted,
                            side: const BorderSide(color: AppColors.border),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text(widget.noLabel),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          focusNode: _yesFocus,
                          onPressed: () => _pop(true),
                          style: FilledButton.styleFrom(
                            backgroundColor: yesColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text(widget.yesLabel),
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
    );
  }
}
