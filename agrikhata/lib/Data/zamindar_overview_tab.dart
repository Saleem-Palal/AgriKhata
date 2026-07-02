import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:flutter/material.dart';

class ZamindarOverviewTab extends StatefulWidget {
  final Zamindar zamindar;
  final VoidCallback onNavigateToAddKisaan;
  final VoidCallback? onNavigateToLedger;
  final VoidCallback? onRefresh;

  const ZamindarOverviewTab({
    super.key,
    required this.zamindar,
    required this.onNavigateToAddKisaan,
    this.onNavigateToLedger,
    this.onRefresh,
  });

  @override
  State<ZamindarOverviewTab> createState() => _ZamindarOverviewTabState();
}

class _ZamindarOverviewTabState extends State<ZamindarOverviewTab> {
  Map<String, Object>? _balanceData;
  List<LedgerTransaction> _recentTransactions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (widget.zamindar.id == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final balances = await DatabaseHelper.instance.getZamindarBalancesSafe(
        widget.zamindar.id!,
      );
      final allTransactions = await DatabaseHelper.instance
          .getLedgerTransactionsForZamindar(widget.zamindar.id!);

      if (!mounted) return;
      setState(() {
        _balanceData = balances;
        _recentTransactions = allTransactions.take(3).toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Material(
      color: Colors.transparent,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Column(
                children: [
                  _buildLandCreditCard(),
                  const SizedBox(height: 14),
                  _buildCropsCard(),
                  const SizedBox(height: 14),
                  _buildRecentTransactionsCard(),
                ],
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 220,
              child: Column(
                children: [
                  _buildQuickActionsCard(context),
                  const SizedBox(height: 14),
                  _buildPaymentTermsCard(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.darkGreen,
                    ),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.all(14), child: child),
        ],
      ),
    );
  }

  Widget _buildLandCreditCard() {
    final outstandingBalance =
        (_balanceData?['outstandingBalance'] as int? ?? 0).toDouble();
    final creditLimit = widget.zamindar.creditLimit.toDouble();
    final isOverLimit = _balanceData?['isOverLimit'] as bool? ?? false;
    final usedColor = isOverLimit
        ? const Color(0xFFA32D2D)
        : const Color(0xFF27500A);

    return _card(
      title: "Land & credit details",
      child: Row(
        children: [
          Expanded(
            child: _infoItem(
              "Total land",
              "${widget.zamindar.totalLandAcres.toStringAsFixed(0)} ${widget.zamindar.landUnit}",
              "",
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _infoItem(
              "Credit limit",
              "Rs ${_fmt(creditLimit)}",
              "Set by owner",
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _infoItem(
              "Amount used",
              "Rs ${_fmt(outstandingBalance)}",
              isOverLimit
                  ? "Rs ${_fmt(outstandingBalance - creditLimit)} over"
                  : "Within limit",
              valueColor: usedColor,
              subColor: usedColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoItem(
    String label,
    String value,
    String sub, {
    Color? valueColor,
    Color? subColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: valueColor ?? AppColors.darkGreen,
            ),
          ),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              sub,
              style: TextStyle(
                fontSize: 10,
                color: subColor ?? AppColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCropsCard() {
    final seasons = widget.zamindar.activeSeasons;
    final crops = widget.zamindar.activeCrops;

    return _card(
      title: "Seasons & crops",
      child: seasons.isEmpty && crops.isEmpty
          ? const Text(
              'No seasons or crops configured',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            )
          : Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ...seasons.map(
                  (s) => _chip(
                    s,
                    const Color(0xFFFAEEDA),
                    const Color(0xFF633806),
                  ),
                ),
                ...crops.map(
                  (c) => _chip(
                    c,
                    const Color(0xFFEAF3DE),
                    const Color(0xFF27500A),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _chip(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: fg),
      ),
    );
  }

  Widget _buildRecentTransactionsCard() {
    return _card(
      title: "Recent transactions",
      trailing: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onNavigateToLedger,
          child: const Text(
            "View full ledger",
            style: TextStyle(fontSize: 11, color: AppColors.accentGreen),
          ),
        ),
      ),
      child: _recentTransactions.isEmpty
          ? const Text(
              'No transactions yet',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            )
          : Column(
              children: _recentTransactions.map((txn) => _txnRow(txn)).toList(),
            ),
    );
  }

  Widget _txnRow(LedgerTransaction txn) {
    final isDebit = txn.type == LedgerTransactionType.debit;
    final formattedDate = _formatDate(txn.dateTime);
    final formattedAmount =
        "${isDebit ? '+' : '−'}Rs ${_fmt(txn.amount.toDouble())}";

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: isDebit
                  ? const Color(0xFFC0DD97)
                  : const Color(0xFF85B7EB),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  txn.description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.darkGreen,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  formattedDate,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Text(
            formattedAmount,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDebit
                  ? const Color(0xFFA32D2D)
                  : const Color(0xFF0C447C),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  Widget _buildQuickActionsCard(BuildContext context) {
    return _card(
      title: "Quick actions",
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                _showPlaceholderDialog(
                  context,
                  "New Sale",
                  "Navigate to Sell Page with ${widget.zamindar.name} pre-selected.",
                );
              },
              icon: const Icon(Icons.receipt_long_outlined, size: 15),
              label: const Text("New sale for this Zamindar"),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget
                  .onNavigateToAddKisaan, // Navigates to Kisaans tab & opens drawer
              icon: const Icon(Icons.person_add_outlined, size: 15),
              label: const Text("Add Kisaan"),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                _showPlaceholderDialog(
                  context,
                  "Send via WhatsApp",
                  "Send ledger summary to ${widget.zamindar.name} via WhatsApp.",
                );
              },
              icon: const Icon(Icons.send_outlined, size: 15),
              label: const Text("Send via WhatsApp"),
            ),
          ),
        ],
      ),
    );
  }

  void _showPlaceholderDialog(
    BuildContext context,
    String title,
    String message,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(color: AppColors.darkGreen, fontSize: 16),
        ),
        content: Text(message, style: const TextStyle(fontSize: 13)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Got it"),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentTermsCard() {
    return _card(
      title: "Payment terms",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.zamindar.paymentTerms,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.darkGreen,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.zamindar.paymentTerms == 'Seasonal'
                ? "Payment expected after harvest — ${widget.zamindar.activeSeasons.join(' / ')}"
                : "Custom payment arrangement",
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

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
}
