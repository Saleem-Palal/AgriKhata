import 'dart:math' as math;

import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';

/// Shared wallet-split + remarks controls for Kisaan/Zamindar bill settlement.
class SettlementSplitFields extends StatelessWidget {
  static const deductionExceedsLimitMessage =
      'Deduction amount cannot exceed available wallet balance or outstanding dues.';

  final double availableAdvance;
  final double outstandingDues;
  final double settlementAmount;
  final bool deductFromWallet;
  final ValueChanged<bool> onDeductFromWalletChanged;
  final TextEditingController walletAmountController;
  final TextEditingController remarksController;
  final String Function(double value) formatAmount;

  const SettlementSplitFields({
    super.key,
    required this.availableAdvance,
    required this.outstandingDues,
    required this.settlementAmount,
    required this.deductFromWallet,
    required this.onDeductFromWalletChanged,
    required this.walletAmountController,
    required this.remarksController,
    required this.formatAmount,
  });

  static double maxDeduction({
    required double availableAdvance,
    required double outstandingDues,
    required double settlementAmount,
  }) {
    final cap = math.min(availableAdvance, outstandingDues);
    if (settlementAmount > 0) {
      return math.min(cap, settlementAmount);
    }
    return cap;
  }

  static double? parseAmount(String raw) => double.tryParse(raw.trim());

  static String? walletInlineError({
    required bool deductFromWallet,
    required String rawText,
    required double availableAdvance,
    required double outstandingDues,
    required double settlementAmount,
  }) {
    if (!deductFromWallet) return null;
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) return null;
    final amount = parseAmount(trimmed);
    if (amount == null || amount <= 0) {
      return 'Enter a valid deduction amount';
    }
    final maxAllowed = maxDeduction(
      availableAdvance: availableAdvance,
      outstandingDues: outstandingDues,
      settlementAmount: settlementAmount,
    );
    if (amount > maxAllowed + 0.01) {
      return deductionExceedsLimitMessage;
    }
    return null;
  }

  static bool isWalletDeductionValid({
    required bool deductFromWallet,
    required String rawText,
    required double availableAdvance,
    required double outstandingDues,
    required double settlementAmount,
  }) {
    if (!deductFromWallet) return true;
    final amount = parseAmount(rawText);
    if (amount == null || amount <= 0) return false;
    return walletInlineError(
          deductFromWallet: deductFromWallet,
          rawText: rawText,
          availableAdvance: availableAdvance,
          outstandingDues: outstandingDues,
          settlementAmount: settlementAmount,
        ) ==
        null;
  }

  static double walletDeductionAmount({
    required bool deductFromWallet,
    required String rawText,
  }) {
    if (!deductFromWallet) return 0;
    return parseAmount(rawText) ?? 0;
  }

  static double remainingCash({
    required double settlementAmount,
    required bool deductFromWallet,
    required String rawText,
  }) {
    final wallet = walletDeductionAmount(
      deductFromWallet: deductFromWallet,
      rawText: rawText,
    );
    final remaining = settlementAmount - wallet;
    return remaining < 0 ? 0 : remaining;
  }

  String? get _errorText => walletInlineError(
    deductFromWallet: deductFromWallet,
    rawText: walletAmountController.text,
    availableAdvance: availableAdvance,
    outstandingDues: outstandingDues,
    settlementAmount: settlementAmount,
  );

  bool get _canEnableToggle => availableAdvance > 0 && outstandingDues > 0;

  @override
  Widget build(BuildContext context) {
    final remaining = remainingCash(
      settlementAmount: settlementAmount,
      deductFromWallet: deductFromWallet,
      rawText: walletAmountController.text,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFEAF3DE),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFC5D9B8), width: 0.5),
          ),
          child: Text(
            'Available Advance: Rs ${formatAmount(availableAdvance)}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.darkGreen,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: deductFromWallet,
          onChanged: _canEnableToggle ? onDeductFromWalletChanged : null,
          title: const Text(
            'Deduct from Advance Payment Wallet',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.darkGreen,
            ),
          ),
          subtitle: Text(
            _canEnableToggle
                ? 'Apply a custom amount from the advance wallet'
                : 'No advance wallet balance available',
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
          ),
          activeThumbColor: AppColors.darkGreen,
        ),
        if (deductFromWallet) ...[
          const SizedBox(height: 8),
          const Text(
            'Amount to Deduct from Advance Wallet',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: walletAmountController,
            keyboardType: TextInputType.number,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.darkGreen,
            ),
            decoration: InputDecoration(
              isDense: true,
              prefixText: 'Rs ',
              prefixStyle: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColors.darkGreen,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              hintText: '0',
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(
                  color: AppColors.sidebarBg,
                  width: 0.5,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(
                  color: AppColors.darkGreen,
                  width: 1,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: Colors.red, width: 1),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: Colors.red, width: 1),
              ),
              errorText: _errorText,
              errorMaxLines: 2,
              errorStyle: const TextStyle(fontSize: 9),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: remaining > 0
                  ? const Color(0xFFFCEBEB)
                  : const Color(0xFFEAF3DE),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: remaining > 0
                    ? const Color(0xFFE8B4B4)
                    : const Color(0xFFC5D9B8),
                width: 0.5,
              ),
            ),
            child: Text(
              'Remaining Cash Receivable: Rs ${formatAmount(remaining)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: remaining > 0
                    ? const Color(0xFFA32D2D)
                    : AppColors.darkGreen,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Remarks / Description (Optional)',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: remarksController,
          minLines: 1,
          maxLines: 2,
          style: const TextStyle(fontSize: 12, color: AppColors.darkGreen),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Enter settlement notes or adjustment reference...',
            hintStyle: const TextStyle(
              fontSize: 11,
              color: AppColors.textMuted,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(
                color: AppColors.sidebarBg,
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(
                color: AppColors.darkGreen,
                width: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
