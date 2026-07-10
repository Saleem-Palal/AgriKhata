import 'dart:async';

import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:flutter/material.dart';

/// Global navigator key — set on [MaterialApp.navigatorKey] in main.dart.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Displays a bottom-right overlay summarising advance wallet usage after checkout.
class AdvanceCheckoutOverlay {
  AdvanceCheckoutOverlay._();

  static final AdvanceCheckoutOverlay instance = AdvanceCheckoutOverlay._();

  OverlayEntry? _entry;
  Timer? _dismissTimer;

  void show({
    required String zamindarName,
    required String? kisaanName,
    required double totalAdvanceBefore,
    required double deductedAmount,
    required double remainingAdvance,
    required double remainingPhysicalCash,
  }) {
    dismiss();

    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;

    _entry = OverlayEntry(
      builder: (context) => _AdvanceCheckoutCard(
        zamindarName: zamindarName,
        kisaanName: kisaanName,
        totalAdvanceBefore: totalAdvanceBefore,
        deductedAmount: deductedAmount,
        remainingAdvance: remainingAdvance,
        remainingPhysicalCash: remainingPhysicalCash,
        onClose: dismiss,
      ),
    );

    overlay.insert(_entry!);
    _dismissTimer = Timer(const Duration(seconds: 30), dismiss);
  }

  void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _AdvanceCheckoutCard extends StatelessWidget {
  final String zamindarName;
  final String? kisaanName;
  final double totalAdvanceBefore;
  final double deductedAmount;
  final double remainingAdvance;
  final double remainingPhysicalCash;
  final VoidCallback onClose;

  const _AdvanceCheckoutCard({
    required this.zamindarName,
    required this.kisaanName,
    required this.totalAdvanceBefore,
    required this.deductedAmount,
    required this.remainingAdvance,
    required this.remainingPhysicalCash,
    required this.onClose,
  });

  String _fmt(double value) {
    final formatted = value.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final buffer = StringBuffer();
    for (int i = 0; i < chars.length; i++) {
      buffer.write(chars[i]);
      final pos = i + 1;
      if (pos == 3 || (pos > 3 && (pos - 3) % 2 == 0)) {
        if (i != chars.length - 1) buffer.write(',');
      }
    }
    return buffer.toString().split('').reversed.join('');
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 320,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                decoration: const BoxDecoration(
                  color: AppColors.darkGreen,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.account_balance_wallet_outlined,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Advance Wallet Applied',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: onClose,
                      borderRadius: BorderRadius.circular(4),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close,
                          color: Color(0xFFA7C4A0),
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _partyRow('Zamindar', zamindarName),
                    const SizedBox(height: 6),
                    _partyRow(
                      'Kisaan',
                      kisaanName?.trim().isNotEmpty == true
                          ? kisaanName!.trim()
                          : 'Self',
                    ),
                    const Divider(height: 20),
                    _metricRow(
                      'Total Advance Payment',
                      'Rs ${_fmt(totalAdvanceBefore)}',
                    ),
                    const SizedBox(height: 8),
                    _metricRow(
                      'Deducted Amount',
                      'Rs ${_fmt(deductedAmount)}',
                      valueColor: const Color(0xFF0C447C),
                    ),
                    const SizedBox(height: 8),
                    _metricRow(
                      'Remaining Advance',
                      'Rs ${_fmt(remainingAdvance)}',
                      valueColor: const Color(0xFF27500A),
                    ),
                    const Divider(height: 20),
                    _metricRow(
                      'Cash to Collect',
                      'Rs ${_fmt(remainingPhysicalCash)}',
                      valueColor: remainingPhysicalCash > 0
                          ? const Color(0xFFA32D2D)
                          : AppColors.textMuted,
                      emphasized: true,
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

  Widget _partyRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.darkGreen,
            ),
          ),
        ),
      ],
    );
  }

  Widget _metricRow(
    String label,
    String value, {
    Color? valueColor,
    bool emphasized = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: emphasized ? 12 : 11,
            color: AppColors.textMuted,
            fontWeight: emphasized ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: emphasized ? 14 : 12,
            fontWeight: FontWeight.w600,
            color: valueColor ?? AppColors.darkGreen,
          ),
        ),
      ],
    );
  }
}
