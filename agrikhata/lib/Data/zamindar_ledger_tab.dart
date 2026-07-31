import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/edit_cash_advance_dialog.dart';
import 'package:agrikhata/Widgets/edit_payment_dialog.dart';
import 'package:agrikhata/Widgets/ledger_widgets.dart';
import 'package:agrikhata/Widgets/past_season_guard.dart';
import 'package:agrikhata/models/season.dart';
import 'package:agrikhata/screens/new_sale_screen.dart';
import 'package:agrikhata/services/season_service.dart';
import 'package:agrikhata/services/whatsapp_urdu_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:agrikhata/utils/pdf_generator.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';

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
  final TextEditingController _searchController = TextEditingController();
  String _selectedSeason = SeasonFilterOption.current;
  List<Map<String, dynamic>> _allTransactions = [];
  Map<String, String> _invoiceItemSummaries = {};
  Map<String, Map<String, double>> _invoiceCollections = {};
  String _outstandingBalanceDisplay = "Rs. 0";
  double _outstandingBalanceAmount = 0;
  int _totalPaymentsReceived = 0;
  bool _isLoading = true;
  bool _isExporting = false;
  String? _loadError;
  String _zamindarName = 'Zamindar';
  String _zamindarWhatsapp = '';

  List<String> _seasons = [SeasonFilterOption.current, SeasonFilterOption.allTime];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadLedgerData();
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
    SeasonService.instance.activeSeasonNotifier.addListener(_onSeasonChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    SeasonService.instance.activeSeasonNotifier.removeListener(_onSeasonChanged);
    super.dispose();
  }

  void _onDatabaseChanged() => _loadLedgerData(showLoading: false);

  void _onSeasonChanged() {
    if (_selectedSeason == SeasonFilterOption.current) {
      _loadLedgerData(showLoading: false);
    } else {
      setState(() {});
    }
  }

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
      final filterLabels = await SeasonService.instance.zamindarFilterLabels();
      // Keep named prior seasons from ledger that aren't the previous slot.
      final previous = await SeasonService.instance.getPreviousSeason();
      final extras = distinctSeasons.where((s) {
        if (previous != null && s == previous.name) return false;
        final active = SeasonService.instance.activeSeasonName;
        if (active != null && s == active) return false;
        return true;
      });
      final seasons = <String>[
        ...filterLabels,
        ...extras.where((s) => !filterLabels.contains(s)),
      ];
      final zamindar = await DatabaseHelper.instance.getZamindar(
        widget.zamindarId,
      );
      final balances = await DatabaseHelper.instance.getZamindarBalancesSafe(
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
        _outstandingBalanceAmount =
            (balances?['outstandingBalance'] as num?)?.toDouble() ?? 0;
        _totalPaymentsReceived = totalPayments;
        _seasons = seasons;
        if (!_seasons.contains(_selectedSeason)) {
          _selectedSeason = SeasonFilterOption.current;
        }
        _zamindarName = zamindar?.name ?? 'Zamindar';
        _zamindarWhatsapp = zamindar?.whatsappNumber ?? '';
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
    final query = _searchController.text.trim().toLowerCase();

    return _allTransactions.where((row) {
      final season = row[LedgerTransactionTable.season] as String? ?? '';
      final activeName = SeasonService.instance.activeSeasonName;
      if (_selectedSeason == SeasonFilterOption.current) {
        if (activeName != null &&
            activeName.isNotEmpty &&
            season != activeName) {
          return false;
        }
      } else if (_selectedSeason != SeasonFilterOption.allTime) {
        if (season != _selectedSeason) return false;
      }

      if (query.isEmpty) return true;

      final invoiceNumber =
          row[LedgerTransactionTable.invoiceNumber] as String? ?? '';
      final kisaan = (row['kisaan_name'] as String? ?? '').toLowerCase();
      final description =
          (row[LedgerTransactionTable.description] as String? ?? '')
              .toLowerCase();
      final category =
          (row[LedgerTransactionTable.category] as String? ?? '').toLowerCase();
      final items =
          (_invoiceItemSummaries[invoiceNumber] ?? '').toLowerCase();

      return invoiceNumber.toLowerCase().contains(query) ||
          kisaan.contains(query) ||
          description.contains(query) ||
          category.contains(query) ||
          items.contains(query);
    }).toList();
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

  Future<List<Map<String, dynamic>>> _salesRowsForExport() async {
    if (_selectedSeason == SeasonFilterOption.allTime) {
      return DatabaseHelper.instance.getZamindarLedgerPdfRows(
        zamindarId: widget.zamindarId,
      );
    }
    final label = _selectedSeason == SeasonFilterOption.current
        ? SeasonService.instance.activeSeasonName
        : _selectedSeason;
    final seasons = (label == null || label.isEmpty) ? null : {label};
    return DatabaseHelper.instance.getZamindarLedgerPdfRows(
      zamindarId: widget.zamindarId,
      seasons: seasons,
    );
  }

  double _cumulativeRemaining(List<Map<String, dynamic>> rows) {
    return rows.fold<double>(
      0,
      (sum, row) => sum + ((row['remaining'] as num?)?.toDouble() ?? 0),
    );
  }

  Future<void> _handleExportPdf() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final rows = await _salesRowsForExport();
      final file = await PdfGenerator.saveZamindarLedgerToDocuments(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        rows: rows,
        outstandingBalance: _outstandingBalanceDisplay,
        cumulativeRemaining: _cumulativeRemaining(rows),
      );
      if (!mounted) return;
      AppToast.showSuccess(context, 'PDF saved to ${file.path}');
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Failed to export PDF: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handleShareWhatsAppPdf() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final rows = await _salesRowsForExport();
      final file = await PdfGenerator.saveZamindarLedgerToDocuments(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        rows: rows,
        outstandingBalance: _outstandingBalanceDisplay,
        cumulativeRemaining: _cumulativeRemaining(rows),
      );

      final shopName = await ShopSettings.getShopName();
      await WhatsAppUrduService.sharePdfWithUrduCaption(
        phone: _zamindarWhatsapp,
        zamindarName: _zamindarName,
        shopName: shopName,
        amount: _outstandingBalanceAmount,
        pdfPath: file.path,
        subject: 'AgriKhata Ledger — $_zamindarName',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Failed to share via WhatsApp: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handlePrint() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final rows = await _salesRowsForExport();
      final pdf = await PdfGenerator.generateZamindarLedgerPdf(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        rows: rows,
        outstandingBalance: _outstandingBalanceDisplay,
        cumulativeRemaining: _cumulativeRemaining(rows),
      );
      await PdfGenerator.printDocument(pdf);
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Failed to print: $e');
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return AppSearchBar(
      controller: _searchController,
      hintText: 'Search Invoice #, Kisaan or items...',
      breakpoint: 720,
      filters: [
        AppFilterDropdown(
          options: _seasons,
          value: _selectedSeason,
          onChanged: (val) {
            if (val != null) setState(() => _selectedSeason = val);
          },
        ),
        Text(
          "${_filteredTransactions.length} transactions",
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        AppButton.secondary(
          label: 'Print',
          icon: Icons.print_outlined,
          loading: _isExporting,
          onPressed: _isExporting ? null : _handlePrint,
        ),
        AppButton.whatsapp(
          label: 'WhatsApp PDF',
          loading: _isExporting,
          onPressed: _isExporting ? null : _handleShareWhatsAppPdf,
        ),
        AppButton.pdf(
          label: 'Export PDF',
          loading: _isExporting,
          onPressed: _isExporting ? null : _handleExportPdf,
        ),
      ],
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
              actionsWidth: 120,
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
    final hasInvoice = invoiceNumber != null && invoiceNumber.isNotEmpty;
    final isSale = category == 'SALE' && isDebit && hasInvoice;
    final isAdvance = isDebit &&
        hasInvoice &&
        (category == 'ADVANCE_LOAN_RECORD' ||
            category == 'CASH_ADVANCE' ||
            category == 'DIESEL_ADVANCE' ||
            category == 'PETROL_ADVANCE');
    final isPayment = row.isEditablePayment;

    if (!isSale && !isAdvance && !isPayment) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (isPayment)
          _actionIconButton(
            icon: Icons.edit_outlined,
            iconColor: const Color(0xFF1B4332),
            borderColor: const Color(0xFFC6DEC9),
            tooltip: 'Edit Payment',
            onTap: () => _handleEditPayment(
              row.paymentId!,
              seasonLabel: source[LedgerTransactionTable.season] as String?,
              seasonId: source[LedgerTransactionTable.seasonId] as int?,
            ),
          ),
        if (isSale || isAdvance) ...[
          _actionIconButton(
            icon: Icons.edit_outlined,
            iconColor: const Color(0xFF1B4332),
            borderColor: const Color(0xFFC6DEC9),
            tooltip: 'Edit',
            onTap: () => isAdvance
                ? _handleEditAdvance(
                    invoiceNumber,
                    seasonLabel:
                        source[LedgerTransactionTable.season] as String?,
                    seasonId: source[LedgerTransactionTable.seasonId] as int?,
                  )
                : _handleEditInvoice(
                    invoiceNumber,
                    seasonLabel:
                        source[LedgerTransactionTable.season] as String?,
                    seasonId: source[LedgerTransactionTable.seasonId] as int?,
                  ),
          ),
          const SizedBox(width: 6),
          _actionIconButton(
            icon: Icons.delete_outline,
            iconColor: const Color(0xFFDC3545),
            borderColor: const Color(0xFFF5C6C6),
            tooltip: 'Delete',
            onTap: () => _handleDeleteInvoice(
              invoiceNumber,
              seasonLabel: source[LedgerTransactionTable.season] as String?,
              seasonId: source[LedgerTransactionTable.seasonId] as int?,
            ),
          ),
          const SizedBox(width: 6),
          _actionIconButton(
            icon: Icons.payments_outlined,
            iconColor: const Color(0xFF1B4332),
            borderColor: const Color(0xFFC6DEC9),
            tooltip: 'Bill Settlement',
            onTap: () => _showBillSettlementDialog(source),
          ),
        ],
      ],
    );
  }

  Future<void> _handleEditPayment(
    String paymentId, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

    final updated = await showEditPaymentDialog(
      context: context,
      paymentId: paymentId,
    );
    if (updated && mounted) {
      AppToast.showSuccess(context, 'Payment updated');
      await _loadLedgerData(showLoading: false);
    }
  }

  Future<void> _handleEditAdvance(
    String invoiceNumber, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

    final updated = await showEditCashAdvanceDialog(
      context: context,
      invoiceNumber: invoiceNumber,
    );
    if (updated && mounted) {
      await _loadLedgerData(showLoading: false);
    }
  }

  Future<void> _handleEditInvoice(
    String invoiceNumber, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

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

  Future<void> _handleDeleteInvoice(
    String invoiceNumber, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

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
        AppToast.showSuccess(context, 'Invoice $invoiceNumber deleted');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to delete invoice: $e');
      }
    }
  }

  Widget _actionIconButton({
    required IconData icon,
    required Color iconColor,
    required Color borderColor,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final button = InkWell(
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
    if (tooltip == null || tooltip.isEmpty) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Future<void> _showBillSettlementDialog(Map<String, dynamic> row) async {
    final transaction = LedgerTransaction.fromMap(row);
    final invoiceNumber = transaction.invoiceNumber;

    if (invoiceNumber == null || invoiceNumber.isEmpty) {
      if (mounted) {
        AppToast.showError(context, 'This sale is not linked to an invoice.');
      }
      return;
    }

    double remainingBalance;
    try {
      remainingBalance = await DatabaseHelper.instance
          .getInvoiceRemainingBalance(invoiceNumber);
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Could not load invoice balance: $e');
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
                            AppToast.showSuccess(context, 'Payment of Rs ${_fmt(amount)} recorded successfully',);
                            _loadLedgerData();
                          }
                        } catch (e) {
                          if (context.mounted) {
                            AppToast.showError(context, 'Failed to record payment: $e');
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
