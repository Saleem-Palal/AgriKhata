import 'package:agrikhata/theme/app_button.dart';
import 'package:agrikhata/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Standardized dialog shell with top-right close and bottom actions.
class AppDialog extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget content;
  final List<Widget>? actions;
  final double maxWidth;
  final bool showCloseButton;
  final VoidCallback? onClose;

  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    this.subtitle,
    this.actions,
    this.maxWidth = 440,
    this.showCloseButton = true,
    this.onClose,
  });

  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required Widget content,
    String? subtitle,
    List<Widget>? actions,
    double maxWidth = 440,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => AppDialog(
        title: title,
        subtitle: subtitle,
        content: content,
        actions: actions,
        maxWidth: maxWidth,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  static Future<bool?> confirm({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) {
    return show<bool>(
      context: context,
      title: title,
      content: Text(message, style: AppTextStyles.body),
      actions: [
        AppButton.secondary(
          label: cancelLabel,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        if (danger)
          AppButton.danger(
            label: confirmLabel,
            onPressed: () => Navigator.of(context).pop(true),
          )
        else
          AppButton.primary(
            label: confirmLabel,
            onPressed: () => Navigator.of(context).pop(true),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.cardSurface,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: AppTextStyles.dialogTitle),
                        if (subtitle != null && subtitle!.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(subtitle!, style: AppTextStyles.pageSubtitle),
                        ],
                      ],
                    ),
                  ),
                  if (showCloseButton)
                    IconButton(
                      onPressed:
                          onClose ?? () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close, size: 18),
                      color: AppColors.textMuted,
                      splashRadius: 18,
                      tooltip: 'Close',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              content,
              if (actions != null && actions!.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    alignment: WrapAlignment.end,
                    children: actions!,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
