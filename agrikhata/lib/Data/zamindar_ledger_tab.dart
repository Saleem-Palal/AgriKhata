import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/ledger_widgets.dart';
import 'package:agrikhata/screens/new_sale_screen.dart';
import 'package:agrikhata/utils/pdf_generator.dart';
import 'package:agrikhata/utils/pdf_share.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class ZamindarLedgerTab extends StatefulWidget {
  final int zamindarId;
  final void Function(String invoiceNumber)? onEditInvoice;

  const ZamindarLedgerTab({
    super.key,
    required this.zamindarId,
    this.onEditInvoice,
  });

  @override
  State<ZamindarLedgerTab> createState() => _ZamindarLedgerTabState();
}

class _ZamindarLedgerTabState extends State<ZamindarLedgerTab> {
  String _selectedSeason = "All seasons";
  List<Map<String, dynamic>> _allTransactions = [];
  Map<String, String> _invoiceItemSummaries = {};
  Map<String, Map<String, double>> _invoiceCollections = {};
  String _outstandingBalanceDisplay = "Rs. 0";
  int _totalPaymentsReceived = 0;
  bool _isLoading = true;
  bool _isExporting = false;
  String? _loadError;
  String _zamindarName = 'Zamindar';

  List<String> _seasons = ["All seasons"];

  @override
  void initState() {
    super.initState();
    _loadLedgerData();
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onDatabaseChanged() => _loadLedgerData(showLoading: false);

  Future<void> _loadLedgerData({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final transactions = await DatabaseHelper.instance.getLedgerTransactions(
        widget.zamindarId,
      );
      final outstandingBalance = await DatabaseHelper.instance
          .getOutstandingBalanceString(widget.zamindarId);
      final totalPayments = await DatabaseHelper.instance
          .getTotalPaymentsReceived(widget.zamindarId);
      final distinctSeasons = await DatabaseHelper.instance
          .getDistinctSeasonsForZamindar(widget.zamindarId);
      final zamindar = await DatabaseHelper.instance.getZamindar(
        widget.zamindarId,
      );

      final invoiceNumbers = transactions
          .map((row) => row[LedgerTransactionTable.invoiceNumber] as String?)
          .whereType<String>()
          .toList();

      final itemSummaries = await DatabaseHelper.instance
          .getSaleItemsSummariesForInvoices(invoiceNumbers);
      final collections = await DatabaseHelper.instance
          .getInvoiceCollectionSummaries(invoiceNumbers);

      if (!mounted) return;
      setState(() {
        _allTransactions = transactions;
        _invoiceItemSummaries = itemSummaries;
        _invoiceCollections = collections;
        _outstandingBalanceDisplay = outstandingBalance;
        _totalPaymentsReceived = totalPayments;
        _seasons = ["All seasons", ...distinctSeasons];
        if (!_seasons.contains(_selectedSeason)) {
          _selectedSeason = "All seasons";
        }
        _zamindarName = zamindar?.name ?? 'Zamindar';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Failed to load ledger: $e';
      });
    }
  }

  List<Map<String, dynamic>> get _filteredTransactions {
    if (_selectedSeason == "All seasons") {
      return _allTransactions;
    }
    return _allTransactions
        .where(
          (row) =>
              (row[LedgerTransactionTable.season] as String? ?? '') ==
              _selectedSeason,
        )
        .toList();
  }

  int get _totalDebit => _allTransactions
      .where(
        (row) =>
            (row[LedgerTransactionTable.type] as String?) ==
            LedgerTransactionType.debit,
      )
      .fold<int>(
        0,
        (sum, row) =>
            sum + ((row[LedgerTransactionTable.amount] as num?)?.round() ?? 0),
      );

  String _displayDescription(Map<String, dynamic> row) {
    final base = row[LedgerTransactionTable.description] as String? ?? '';
    final category = (row[LedgerTransactionTable.category] as String? ?? '')
        .toUpperCase();
    final invoiceNumber =
        row[LedgerTransactionTable.invoiceNumber] as String?;

    final needsItems =
        category == 'PAYMENT' ||
        category == 'WALLET_DEDUCTION' ||
        category == 'CASH_PAYMENT';

    if (!needsItems || invoiceNumber == null || invoiceNumber.isEmpty) {
      return base;
    }

    final items = _invoiceItemSummaries[invoiceNumber];
    if (items == null || items.isEmpty) return base;
    if (base.contains('[$items]')) return base;
    return '$base [$items]';
  }

  List<Map<String, dynamic>> _transactionsForExport() {
    return _filteredTransactions.map((row) {
      final copy = Map<String, dynamic>.from(row);
      copy[LedgerTransactionTable.description] = _displayDescription(row);
      return copy;
    }).toList();
  }

  Future<void> _handleExportPdf() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final file = await PdfGenerator.saveZamindarLedgerToDocuments(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        transactions: _transactionsForExport(),
        outstandingBalance: _outstandingBalanceDisplay,
        totalPaymentsReceived: _totalPaymentsReceived,
        totalDebit: _totalDebit,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PDF saved to ${file.path}'),
          backgroundColor: const Color(0xFF2D6A4F),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to export PDF: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handleShareWhatsAppPdf() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final file = await PdfGenerator.saveZamindarLedgerToDocuments(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        transactions: _transactionsForExport(),
        outstandingBalance: _outstandingBalanceDisplay,
        totalPaymentsReceived: _totalPaymentsReceived,
        totalDebit: _totalDebit,
      );

      await PdfShare.sharePdfFile(
        file: file,
        fileName: p.basename(file.path),
        text: 'AgriKhata Ledger — $_zamindarName ($_selectedSeason)',
        subject: 'AgriKhata Ledger PDF',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to share via WhatsApp: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handlePrint() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final pdf = await PdfGenerator.generateZamindarLedgerPdf(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        transactions: _transactionsForExport(),
        outstandingBalance: _outstandingBalanceDisplay,
        totalPaymentsReceived: _totalPaymentsReceived,
        totalDebit: _totalDebit,
      );
      await PdfGenerator.printDocument(pdf);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to print: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              style: const TextStyle(color: AppColors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _loadLedgerData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _summaryCard(
                    "Total sales (debit)",
                    "Rs ${_fmt(_totalDebit.toDouble())}",
                    const Color(0xFFA32D2D),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _summaryCard(
                    "Total payments received",
                    "Rs ${_fmt(_totalPaymentsReceived.toDouble())}",
                    const Color(0xFF0C447C),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _summaryCard(
                    "Total outstanding balance",
                    _outstandingBalanceDisplay,
                    const Color(0xFF27500A),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildFilterBar(),
            const SizedBox(height: 14),
            Expanded(child: _buildLedgerList()),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Row(
      children: [
        _dropdown(
          _seasons,
          _selectedSeason,
          (val) => setState(() => _selectedSeason = val!),
        ),
        const Spacer(),
        Text(
          "${_filteredTransactions.length} transactions",
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        const SizedBox(width: 14),
        _exportBtn(Icons.print_outlined, "Print", _handlePrint),
        const SizedBox(width: 8),
        _exportBtn(
          Icons.chat_outlined,
          "WhatsApp PDF",
          _handleShareWhatsAppPdf,
        ),
        const SizedBox(width: 8),
        _exportBtn(
          Icons.picture_as_pdf_outlined,
          "Export PDF",
          _handleExportPdf,
        ),
      ],
    );
  }

  Widget _dropdown(
    List<String> options,
    String value,
    ValueChanged<String?> onChanged,
  ) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.sidebarBg, width: 0.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 16,
            color: AppColors.textMuted,
          ),
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          items: options
              .map((opt) => DropdownMenuItem(value: opt, child: Text(opt)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _exportBtn(IconData icon, String label, VoidCallback onPressed) {
    return OutlinedButton.icon(
      onPressed: _isExporting ? null : onPressed,
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: AppColors.sidebarBg, width: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }

  List<ZamindarLedgerRow> get _filteredLedgerRows {
    return ZamindarLedgerRow.fromTransactions(
      transactions: _filteredTransactions,
      itemSummaries: _invoiceItemSummaries,
      collections: _invoiceCollections,
    );
  }

  Widget _buildLedgerList() {
    final rows = _filteredLedgerRows;

    if (rows.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No ledger entries yet',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final minWidth = 980.0;
        final width =
            constraints.maxWidth < minWidth ? minWidth : constraints.maxWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: constraints.maxHeight,
            child: ZamindarLedgerTable(
              rows: rows,
              actionsWidth: 220,
              actionsBuilder: (context, row) => _buildRowActions(row),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRowActions(ZamindarLedgerRow row) {
    final source = row.source;
    final category = row.category;
    final isDebit = row.isDebit;
    final invoiceNumber =
        source[LedgerTransactionTable.invoiceNumber] as String?;
    final isSale =
        category == 'SALE' &&
        isDebit &&
        invoiceNumber != null &&
        invoiceNumber.isNotEmpty;

    if (!isSale) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _actionIconButton(
          icon: Icons.edit_outlined,
          iconColor: const Color(0xFF1B4332),
          borderColor: const Color(0xFFC6DEC9),
          onTap: () => _handleEditInvoice(invoiceNumber),
        ),
        const SizedBox(width: 6),
        _actionIconButton(
          icon: Icons.delete_outline,
          iconColor: const Color(0xFFDC3545),
          borderColor: const Color(0xFFF5C6C6),
          onTap: () => _handleDeleteInvoice(invoiceNumber),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () => _showBillSettlementDialog(source),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF1B4332), width: 0.5),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text(
            'Bill Settlement',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1B4332),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _handleEditInvoice(String invoiceNumber) async {
    if (widget.onEditInvoice != null) {
      widget.onEditInvoice!(invoiceNumber);
      return;
    }

    // Fallback when opened outside Shell (e.g. pushed profile).
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => NewSaleScreen(
          editInvoiceNumber: invoiceNumber,
          onCancelEdit: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  Future<void> _handleDeleteInvoice(String invoiceNumber) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Transaction?'),
        content: const Text(
          'Are you sure you want to delete this transaction and all associated payments?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFDC3545),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await DatabaseHelper.instance.deleteInvoiceEntirely(invoiceNumber);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invoice $invoiceNumber deleted'),
            backgroundColor: const Color(0xFF28A745),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete invoice: $e'),
            backgroundColor: const Color(0xFFDC3545),
          ),
        );
      }
    }
  }

  Widget _actionIconButton({
    required IconData icon,
    required Color iconColor,
    required Color borderColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: Icon(icon, size: 14, color: iconColor),
      ),
    );
  }

  Future<void> _showBillSettlementDialog(Map<String, dynamic> row) async {
    final transaction = LedgerTransaction.fromMap(row);
    final invoiceNumber = transaction.invoiceNumber;

    if (invoiceNumber == null || invoiceNumber.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This sale is not linked to an invoice.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    double remainingBalance;
    try {
      remainingBalance = await DatabaseHelper.instance
          .getInvoiceRemainingBalance(invoiceNumber);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load invoice balance: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final totalAmount = transaction.amount.toDouble();
    final amountController = TextEditingController(
      text: remainingBalance > 0
          ? remainingBalance.toStringAsFixed(0)
          : '',
    );

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final enteredAmount =
              double.tryParse(amountController.text.trim()) ?? 0;
          final isOverLimit = enteredAmount > remainingBalance;
          final isValidAmount = enteredAmount > 0 && !isOverLimit;
          final canSave = remainingBalance > 0 && isValidAmount;

          return AlertDialog(
            title: const Text(
              'Bill Settlement',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1B4332),
              ),
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDialogRow('Invoice:', invoiceNumber),
                  const SizedBox(height: 8),
                  _buildDialogRow('Invoice Total:', 'Rs ${_fmt(totalAmount)}'),
                  const SizedBox(height: 8),
                  _buildDialogRow(
                    'Remaining Balance:',
                    'Rs ${_fmt(remainingBalance)}',
                    valueColor: const Color(0xFFA32D2D),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 16),
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 14),
                    onChanged: (value) {
                      final amt = double.tryParse(value.trim());
                      if (amt != null && amt > remainingBalance) {
                        amountController.text = remainingBalance
                            .toStringAsFixed(0);
                        amountController.selection = TextSelection.fromPosition(
                          TextPosition(
                            offset: amountController.text.length,
                          ),
                        );
                      }
                      setDialogState(() {});
                    },
                    decoration: InputDecoration(
                      labelText: 'Amount Paid',
                      hintText: 'Enter payment amount',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      prefixText: 'Rs ',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      errorText: amountController.text.trim().isNotEmpty &&
                              isOverLimit
                          ? 'Cannot exceed remaining balance (Rs ${_fmt(remainingBalance)})'
                          : amountController.text.trim().isNotEmpty &&
                                enteredAmount <= 0
                          ? 'Enter a valid amount'
                          : null,
                      errorStyle: const TextStyle(fontSize: 10),
                    ),
                  ),
                  if (remainingBalance <= 0) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'This invoice is already fully settled.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFFA32D2D),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: canSave
                    ? () async {
                        final amount = enteredAmount;

                        try {
                          final zamindar =
                              await DatabaseHelper.instance.getZamindar(
                            transaction.zamindarId,
                          );

                          String? kisaanName = row['kisaan_name'] as String?;
                          if (kisaanName == null &&
                              transaction.kisaanId != null) {
                            final kisaan =
                                await DatabaseHelper.instance.getKisaan(
                              transaction.kisaanId!,
                            );
                            kisaanName = kisaan?.name;
                          }

                          await DatabaseHelper.instance.insertPayment(
                            invoiceNumber: invoiceNumber,
                            zamindarId: transaction.zamindarId,
                            dateTime: DateTime.now(),
                            zamindarName: zamindar?.name ?? 'Unknown',
                            kisaanName: kisaanName,
                            kisaanId: transaction.kisaanId,
                            amountPaid: amount,
                            paymentMethod: 'Cash',
                            season: transaction.season,
                          );

                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Payment of Rs ${_fmt(amount)} recorded successfully',
                                ),
                                backgroundColor: const Color(0xFF2D6A4F),
                              ),
                            );
                            _loadLedgerData();
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Failed to record payment: $e'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B4332),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFB0B0B0),
                ),
                child: const Text('Save Payment'),
              ),
            ],
          );
        },
      ),
    );
    amountController.dispose();
  }

  Widget _buildDialogRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: valueColor ?? AppColors.darkGreen,
          ),
        ),
      ],
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
