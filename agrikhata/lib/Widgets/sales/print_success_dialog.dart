import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// Post-checkout action chosen by the cashier.
enum PostCheckoutPrintAction { thermal, a4, skip }

/// Desktop-first "Sale Complete" dialog shown after a successful checkout.
///
/// Hierarchy: primary thermal print (Enter) → secondary A4 → ghost skip (Esc).
class PrintSuccessDialog extends StatefulWidget {
  final String invoiceNumber;
  final String stakeholderName;
  final bool isCreditSale;

  const PrintSuccessDialog({
    super.key,
    required this.invoiceNumber,
    required this.stakeholderName,
    required this.isCreditSale,
  });

  /// Shows the dialog and returns the chosen print action (or [skip] / null).
  static Future<PostCheckoutPrintAction?> show({
    required BuildContext context,
    required String invoiceNumber,
    required String stakeholderName,
    required bool isCreditSale,
  }) {
    return showDialog<PostCheckoutPrintAction>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PrintSuccessDialog(
        invoiceNumber: invoiceNumber,
        stakeholderName: stakeholderName,
        isCreditSale: isCreditSale,
      ),
    );
  }

  @override
  State<PrintSuccessDialog> createState() => _PrintSuccessDialogState();
}

class _PrintSuccessDialogState extends State<PrintSuccessDialog> {
  final FocusNode _primaryFocus = FocusNode(debugLabel: 'printThermal');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _primaryFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _primaryFocus.dispose();
    super.dispose();
  }

  void _pop(PostCheckoutPrintAction action) {
    if (!mounted) return;
    Navigator.of(context).pop(action);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () =>
            _pop(PostCheckoutPrintAction.thermal),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
            _pop(PostCheckoutPrintAction.thermal),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _pop(PostCheckoutPrintAction.skip),
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
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 48,
                      color: Color(0xFF2D6A4F),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Sale Complete',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F4EE),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFD8E5D6)),
                    ),
                    child: Text(
                      'Invoice ${widget.invoiceNumber} • Saved for ${widget.stakeholderName}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                        height: 1.35,
                      ),
                    ),
                  ),
                  if (widget.isCreditSale) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF8E8),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE8C56A)),
                      ),
                      child: const Text(
                        '⚠️ Reminder: Obtain Zamindar thumbprint/signature '
                        'on the printed copy for credit record.',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF7A5A10),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    focusNode: _primaryFocus,
                    onPressed: () => _pop(PostCheckoutPrintAction.thermal),
                    icon: const Icon(Icons.print, size: 18),
                    label: const Text(
                      'Print Thermal Receipt (Thumbprint)',
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4332),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => _pop(PostCheckoutPrintAction.a4),
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text(
                      'Print A4 Full Statement',
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1B4332),
                      side: const BorderSide(
                        color: Color(0xFF1B4332),
                        width: 1.25,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: () => _pop(PostCheckoutPrintAction.skip),
                    icon: const Icon(Icons.skip_next_outlined, size: 18),
                    label: const Text('Skip & Next Sale (Esc)'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF6B8F71),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
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
