import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/ledger_widgets.dart';
import 'package:agrikhata/utils/pdf_generator.dart';
import 'package:agrikhata/utils/season_utils.dart';
import 'package:flutter/material.dart';

class ZamindarOverviewTab extends StatefulWidget {
  final Zamindar zamindar;
  final VoidCallback onNavigateToAddKisaan;
  final VoidCallback? onNavigateToLedger;
  final VoidCallback? onRefresh;
  final VoidCallback? onNavigateToSaleWithZamindar;

  const ZamindarOverviewTab({
    super.key,
    required this.zamindar,
    required this.onNavigateToAddKisaan,
    this.onNavigateToLedger,
    this.onRefresh,
    this.onNavigateToSaleWithZamindar,
  });

  @override
  State<ZamindarOverviewTab> createState() => _ZamindarOverviewTabState();
}

class _ZamindarOverviewTabState extends State<ZamindarOverviewTab> {
  String _outstandingBalanceDisplay = "Rs. 0";
  bool _isLoading = true;
  int _advanceBalance = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
    // Listen for database changes and auto-refresh
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
  }

  @override
  void dispose() {
    // Remove database listener to prevent memory leaks
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(ZamindarOverviewTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload data whenever widget updates (e.g., when tab becomes visible)
    _loadData();
  }

  void _onDatabaseChanged() => _loadData(showLoading: false);

  Future<void> _loadData({bool showLoading = true}) async {
    if (widget.zamindar.id == null) {
      if (showLoading) setState(() => _isLoading = false);
      return;
    }

    if (showLoading) setState(() => _isLoading = true);

    try {
      // Use centralized method for outstanding balance
      final outstandingBalance = await DatabaseHelper.instance
          .getOutstandingBalanceString(widget.zamindar.id!);
      final advBalance = await DatabaseHelper.instance.getAdvanceBalance(
        widget.zamindar.id!,
      );

      if (!mounted) return;
      setState(() {
        _outstandingBalanceDisplay = outstandingBalance;
        _advanceBalance = advBalance;
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
                  const SizedBox(height: 14),
                  _buildAdvancePaymentCard(),
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
    bool padChild = true,
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
                ?trailing,
              ],
            ),
          ),
          if (padChild)
            Padding(padding: const EdgeInsets.all(14), child: child)
          else
            child,
        ],
      ),
    );
  }

  Widget _buildLandCreditCard() {
    // Extract numeric value from display string for limit checking
    final outstandingValue = int.tryParse(
      _outstandingBalanceDisplay.replaceAll(RegExp(r'[^0-9]'), '')
    ) ?? 0;
    
    final creditLimit = widget.zamindar.creditLimit.toDouble();
    final isOverLimit = outstandingValue > creditLimit;
    final usedColor = isOverLimit
        ? const Color(0xFFA32D2D)
        : const Color(0xFF27500A);

    return _card(
      title: "Land & credit details",
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: _infoItem(
              "Total land",
              "${widget.zamindar.totalLandAcres.toStringAsFixed(0)} ${widget.zamindar.landUnit}",
              "",
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 1,
            child: _infoItem(
              "Credit limit",
              "Rs ${_fmt(creditLimit)}",
              "Set by owner",
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 1,
            child: _infoItem(
              "Total outstanding balance",
              _outstandingBalanceDisplay,
              isOverLimit
                  ? "Rs ${_fmt((outstandingValue - creditLimit).clamp(0.0, double.infinity))} over"
                  : "Within limit",
              valueColor: usedColor,
              subColor: usedColor,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 1,
            child: _infoItem(
              "Advance paid",
              "Rs ${_fmt(_advanceBalance.toDouble())}",
              "Pre-payment",
              valueColor: Colors.blue[700],
              subColor: Colors.blue[600],
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: valueColor ?? AppColors.darkGreen,
              letterSpacing: -0.2,
            ),
          ),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              sub,
              style: TextStyle(
                fontSize: 11,
                color: subColor ?? AppColors.textMuted,
                fontWeight: FontWeight.w500,
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
      padChild: false,
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
      child: FutureBuilder<List<ZamindarLedgerRow>>(
        future: _loadRecentLedgerRows(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(14),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }

          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Failed to load transactions',
                style: TextStyle(fontSize: 11, color: Colors.red[700]),
              ),
            );
          }

          final rows = snapshot.data ?? [];
          if (rows.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'No transactions yet',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth < 720
                  ? 720.0
                  : constraints.maxWidth;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  child: ZamindarLedgerTable(
                    rows: rows,
                    shrinkWrap: true,
                    embedded: true,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<List<ZamindarLedgerRow>> _loadRecentLedgerRows() async {
    if (widget.zamindar.id == null) return const [];

    final transactions = await DatabaseHelper.instance.getLedgerTransactions(
      widget.zamindar.id!,
      limit: 4,
    );
    if (transactions.isEmpty) return const [];

    final invoiceNumbers = transactions
        .map((row) => row[LedgerTransactionTable.invoiceNumber] as String?)
        .whereType<String>()
        .toList();

    final itemSummaries = await DatabaseHelper.instance
        .getSaleItemsSummariesForInvoices(invoiceNumbers);
    final collections = await DatabaseHelper.instance
        .getInvoiceCollectionSummaries(invoiceNumbers);

    return ZamindarLedgerRow.fromTransactions(
      transactions: transactions,
      itemSummaries: itemSummaries,
      collections: collections,
    );
  }

  Widget _buildQuickActionsCard(BuildContext context) {
    return _card(
      title: "Quick actions",
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.onNavigateToSaleWithZamindar,
              icon: const Icon(Icons.receipt_long_outlined, size: 15),
              label: const Text("New sale for this Zamindar"),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.onNavigateToAddKisaan,
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
          if (widget.zamindar.paymentTerms.isEmpty)
            const Text(
              '—',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: widget.zamindar.paymentTerms
                  .map(
                    (term) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.tagGreenBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        term,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.tagGreenText,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 4),
          Text(
            widget.zamindar.paymentTerms.contains('After Harvest')
                ? "Payment expected after harvest — ${widget.zamindar.activeSeasons.join(' / ')}"
                : "Agreed payment schedule for credit sales",
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancePaymentCard() {
    return _card(
      title: "Advance payment",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 32,
                color: Colors.blue[700],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Current balance",
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Rs ${_fmt(_advanceBalance.toDouble())}",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue[700],
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _showReceiveAdvancePaymentDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: const Icon(Icons.add_circle_outline, size: 15),
              label: const Text("Receive advance payment"),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Pre-payments that will be adjusted against future sales",
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  void _showReceiveAdvancePaymentDialog() {
    final amountController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.payment, color: Colors.blue[700], size: 20),
              const SizedBox(width: 8),
              const Text(
                'Receive Advance Payment',
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Zamindar: ${widget.zamindar.name}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.darkGreen,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Amount',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Enter amount (e.g., 50000)',
                  prefixText: 'Rs ',
                  prefixStyle: const TextStyle(
                    fontSize: 14,
                    color: AppColors.darkGreen,
                    fontWeight: FontWeight.w600,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide(color: Colors.blue[700]!, width: 2),
                  ),
                ),
              ),
            ],
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final amount = int.tryParse(
                  amountController.text.replaceAll(RegExp(r'[^0-9]'), ''),
                );

                if (amount == null || amount <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please enter a valid amount'),
                      backgroundColor: Colors.red,
                      duration: Duration(minutes: 1),
                    ),
                  );
                  return;
                }

                try {
                  await DatabaseHelper.instance.receiveAdvancePayment(
                    zamindarId: widget.zamindar.id!,
                    amount: amount,
                    dateTime: DateTime.now(),
                    season: SeasonUtils.getSeasonString(DateTime.now()),
                  );

                  // Reload data
                  await _loadData();

                  // Call parent refresh
                  widget.onRefresh?.call();

                  if (!mounted) return;
                  Navigator.pop(ctx);

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Advance payment of Rs ${_fmt(amount.toDouble())} received successfully',
                      ),
                      duration: Duration(minutes: 1),
                      backgroundColor: Colors.green,
                    ),
                  );

                  // Trigger receipt printing
                  try {
                    await PdfGenerator.printAdvancePaymentReceipt(
                      zamindarName: widget.zamindar.name,
                      amount: amount,
                      date: DateTime.now(),
                    );
                  } catch (e) {
                    debugPrint('Error printing receipt: $e');
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Payment saved but receipt print failed: $e',
                        ),
                        duration: Duration(minutes: 1),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error: $e'),

                      backgroundColor: Colors.red,
                      duration: Duration(minutes: 1),
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[700],
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.print, size: 15),
              label: const Text('Save & Print Receipt'),
            ),
          ],
        );
      },
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
