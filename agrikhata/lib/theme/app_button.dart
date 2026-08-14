import 'package:agrikhata/theme/app_theme.dart';
import 'package:flutter/material.dart';

enum AppButtonVariant {
  primary,
  secondary,
  whatsapp,
  pdf,
  danger,
  ghost,
}

/// Standardized action button — height 38, radius 12, icon + label.
class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final IconData icon;
  final bool loading;
  final bool compact;
  final bool expanded;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.icon,
    this.variant = AppButtonVariant.primary,
    this.loading = false,
    this.compact = false,
    this.expanded = false,
  });

  factory AppButton.primary({
    Key? key,
    required String label,
    required VoidCallback? onPressed,
    IconData icon = Icons.check,
    bool loading = false,
    bool expanded = false,
  }) =>
      AppButton(
        key: key,
        label: label,
        onPressed: onPressed,
        icon: icon,
        loading: loading,
        expanded: expanded,
      );

  factory AppButton.secondary({
    Key? key,
    required String label,
    required VoidCallback? onPressed,
    IconData icon = Icons.tune,
    bool loading = false,
    bool compact = false,
    bool expanded = false,
  }) =>
      AppButton(
        key: key,
        label: label,
        onPressed: onPressed,
        variant: AppButtonVariant.secondary,
        icon: icon,
        loading: loading,
        compact: compact,
        expanded: expanded,
      );

  factory AppButton.whatsapp({
    Key? key,
    String label = 'WhatsApp',
    required VoidCallback? onPressed,
    bool loading = false,
    bool compact = false,
    bool expanded = false,
  }) =>
      AppButton(
        key: key,
        label: label,
        onPressed: onPressed,
        variant: AppButtonVariant.whatsapp,
        icon: Icons.chat,
        loading: loading,
        compact: compact,
        expanded: expanded,
      );

  factory AppButton.pdf({
    Key? key,
    String label = 'Generate PDF',
    required VoidCallback? onPressed,
    bool loading = false,
    bool compact = false,
    bool expanded = false,
  }) =>
      AppButton(
        key: key,
        label: label,
        onPressed: onPressed,
        variant: AppButtonVariant.pdf,
        icon: Icons.picture_as_pdf_outlined,
        loading: loading,
        compact: compact,
        expanded: expanded,
      );

  factory AppButton.danger({
    Key? key,
    required String label,
    required VoidCallback? onPressed,
    IconData icon = Icons.delete_outline,
    bool expanded = false,
  }) =>
      AppButton(
        key: key,
        label: label,
        onPressed: onPressed,
        variant: AppButtonVariant.danger,
        icon: icon,
        expanded: expanded,
      );

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final colors = _colorsFor(variant);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: AppRadius.buttonAll,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: enabled ? 1 : 0.55,
          child: Container(
            width: expanded ? double.infinity : null,
            height: 38,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? AppSpacing.md : AppSpacing.lg,
            ),
            decoration: BoxDecoration(
              color: colors.fill,
              borderRadius: AppRadius.buttonAll,
              border: colors.borderColor != null
                  ? Border.all(color: colors.borderColor!, width: 1)
                  : null,
            ),
            child: Row(
              mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: expanded
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                if (loading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        colors.iconFg ?? colors.fg,
                      ),
                    ),
                  )
                else
                  Icon(icon, size: 15, color: colors.iconFg ?? colors.fg),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: expanded ? TextAlign.center : TextAlign.start,
                    style: AppTextStyles.button.copyWith(color: colors.fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static _BtnColors _colorsFor(AppButtonVariant variant) {
    switch (variant) {
      case AppButtonVariant.primary:
        return const _BtnColors(fill: AppColors.primary, fg: Colors.white);
      case AppButtonVariant.secondary:
        return const _BtnColors(
          fill: AppColors.surface,
          fg: AppColors.primary,
          borderColor: AppColors.inputBorder,
        );
      case AppButtonVariant.whatsapp:
        return const _BtnColors(
          fill: AppColors.whatsapp,
          fg: Color(0xFF0B3D1C),
          iconFg: Colors.white,
        );
      case AppButtonVariant.pdf:
        return const _BtnColors(
          fill: AppColors.surface,
          fg: AppColors.primary,
          borderColor: AppColors.primary,
        );
      case AppButtonVariant.danger:
        return const _BtnColors(
          fill: AppColors.cardSurface,
          fg: AppColors.dangerText,
          borderColor: Color(0xFFF09595),
        );
      case AppButtonVariant.ghost:
        return const _BtnColors(
          fill: Colors.transparent,
          fg: AppColors.textPrimary,
          borderColor: AppColors.border,
        );
    }
  }
}

class _BtnColors {
  final Color fill;
  final Color fg;
  final Color? borderColor;
  final Color? iconFg;

  const _BtnColors({
    required this.fill,
    required this.fg,
    this.borderColor,
    this.iconFg,
  });
}

/// Compact, borderless WhatsApp icon for table/list rows.
class AppWhatsAppIconButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final String tooltip;

  const AppWhatsAppIconButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'Share via WhatsApp',
  });

  @override
  State<AppWhatsAppIconButton> createState() => _AppWhatsAppIconButtonState();
}

class _AppWhatsAppIconButtonState extends State<AppWhatsAppIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: AppRadius.buttonAll,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hovered
                    ? AppColors.whatsapp.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: AppRadius.buttonAll,
              ),
              child: const Icon(
                Icons.chat,
                size: 16,
                color: AppColors.whatsapp,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
