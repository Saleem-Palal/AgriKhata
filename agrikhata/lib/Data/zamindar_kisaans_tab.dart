import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/app_auto_suggest_field.dart';
import 'package:agrikhata/services/whatsapp_urdu_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:agrikhata/utils/pdf_generator.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';

class ZamindarKisaansTab extends StatefulWidget {
  final int zamindarId;
  final String zamindarName;
  final bool autoOpenAdd;
  final void Function(int kisaanId)? onNavigateToSale;

  const ZamindarKisaansTab({
    super.key,
    required this.zamindarId,
    required this.zamindarName,
    this.autoOpenAdd = false,
    this.onNavigateToSale,
  });

  @override
  State<ZamindarKisaansTab> createState() => _ZamindarKisaansTabState();
}

class _ZamindarKisaansTabState extends State<ZamindarKisaansTab> {
  final TextEditingController _searchController = TextEditingController();
  List<Kisaan> _kisaans = [];
  Map<int, double> _kisaanBalances = {};
  ZamindarLandAllocationSummary? _landSummary;
  String _zamindarWhatsapp = '';
  bool _isLoading = true;
  String? _loadError;

  List<Kisaan> get _filteredKisaans {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _kisaans;

    return _kisaans.where((k) {
      return k.name.toLowerCase().contains(query) ||
          k.village.toLowerCase().contains(query) ||
          k.currentCrop.toLowerCase().contains(query) ||
          (k.phone?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
    _loadKisaans();
    if (widget.autoOpenAdd) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openKisaanPanel();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onDatabaseChanged() => _loadKisaans(showLoading: false);

  Future<void> _loadKisaans({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final kisaans = await DatabaseHelper.instance.getKisaansForZamindar(
        widget.zamindarId,
      );
      final landSummary = await DatabaseHelper.instance
          .getZamindarLandAllocationSummary(widget.zamindarId);
      final zamindar = await DatabaseHelper.instance.getZamindar(
        widget.zamindarId,
      );

      final Map<int, double> balances = {};
      for (final kisaan in kisaans) {
        if (kisaan.id != null) {
          final balance = await DatabaseHelper.instance.getKisaanBalanceDue(
            kisaan.id!,
          );
          balances[kisaan.id!] = balance;
        }
      }

      if (!mounted) return;
      setState(() {
        _kisaans = kisaans;
        _kisaanBalances = balances;
        _landSummary = landSummary;
        _zamindarWhatsapp = zamindar?.whatsappNumber ?? '';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Failed to load kisaans: $e';
      });
    }
  }

  void _openKisaanPanel({Kisaan? editTarget}) async {
    if (editTarget != null && _isSelfKisaan(editTarget)) {
      _showSelfEditBlockedDialog();
      return;
    }

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: editTarget == null ? "Add Kisaan" : "Edit Kisaan",
      barrierColor: AppColors.darkGreen.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 340,
            height: double.infinity,
            child: _AddKisaanPanel(
              zamindarId: widget.zamindarId,
              zamindarName: widget.zamindarName,
              editTarget: editTarget,
              onSaved: (kisaan) async {
                try {
                  final nameExists = await DatabaseHelper.instance
                      .kisaanNameExistsForZamindar(
                        zamindarId: widget.zamindarId,
                        name: kisaan.name,
                        excludeKisaanId: editTarget?.id,
                      );

                  if (nameExists) {
                    if (mounted) {
                      AppToast.showError(
                        context,
                        'A Kisaan named "${kisaan.name}" already exists under ${widget.zamindarName}. Please use a different name.',
                      );
                    }
                    return;
                  }

                  final summary = await DatabaseHelper.instance
                      .getZamindarLandAllocationSummary(
                        widget.zamindarId,
                        excludeKisaanId: editTarget?.id,
                      );

                  final newAllocationInZamindarUnit =
                      DatabaseHelper.landAcresToUnit(
                        kisaan.landAcres,
                        summary.landUnit,
                      );
                  final newTotalInZamindarUnit =
                      summary.allocatedLand + newAllocationInZamindarUnit;

                  if (newTotalInZamindarUnit > summary.totalLand + 1e-9) {
                    if (mounted) {
                      AppToast.showError(
                        context,
                        'Cannot allocate land. Total assigned (${newTotalInZamindarUnit.toStringAsFixed(2)} ${summary.landUnit}) exceeds Zamindar\'s limit (${summary.totalLand.toStringAsFixed(2)} ${summary.landUnit}).',
                      );
                    }
                    return;
                  }

                  if (editTarget == null) {
                    await DatabaseHelper.instance.insertKisaan(kisaan);
                  } else {
                    await DatabaseHelper.instance.updateKisaan(kisaan);
                  }

                  Navigator.pop(context);
                  await _loadKisaans();

                  if (mounted) {
                    AppToast.showSuccess(
                      context,
                      editTarget == null
                          ? '✓ Kisaan "${kisaan.name}" created successfully!'
                          : '✓ Kisaan "${kisaan.name}" updated successfully!',
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    AppToast.showError(context, 'Error saving kisaan: $e');
                  }
                }
              },
              onCancel: () => Navigator.pop(context),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        final offset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOut));
        return SlideTransition(position: offset, child: child);
      },
    );
  }

  bool _isSelfKisaan(Kisaan kisaan) => kisaan.name == 'Self';

  void _showSelfEditBlockedDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Cannot Edit 'Self'"),
        content: const Text("You can't edit information about 'Self'."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleDeleteKisaan(Kisaan kisaan) async {
    if (kisaan.id == null) return;

    if (_isSelfKisaan(kisaan)) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Cannot Delete 'Self'"),
          content: const Text(
            "You can't delete 'Self'. You can clear all the data associated with it instead.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('clear'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF791F1F),
              ),
              child: const Text('Clear Data'),
            ),
          ],
        ),
      );

      if (action == 'clear') {
        await _confirmClearSelfData(kisaan);
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${kisaan.name}?'),
        content: Text(
          'This will permanently delete ${kisaan.name} and all associated sales, payments, and ledger records. This action cannot be undone.',
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
      await DatabaseHelper.instance.deleteKisaan(kisaan.id!);
      if (mounted) {
        AppToast.showSuccess(context, 'Kisaan "${kisaan.name}" deleted');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to delete kisaan: $e');
      }
    }
  }

  Future<void> _confirmClearSelfData(Kisaan kisaan) async {
    if (kisaan.id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Clear 'Self' Data?"),
        content: const Text(
          'This will remove all sales, payments, and ledger records linked to Self. The Self kisaan record will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF791F1F),
            ),
            child: const Text('Clear Data'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await DatabaseHelper.instance.clearKisaanTransactionData(kisaan.id!);
      if (mounted) {
        AppToast.showSuccess(
          context,
          "Cleared all data associated with 'Self'",
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to clear data: $e');
      }
    }
  }

  void _viewKisaanLedger(Kisaan kisaan) async {
    if (kisaan.id == null) return;

    List<LedgerTransaction> transactions = [];
    try {
      final allTransactions = await DatabaseHelper.instance
          .getLedgerTransactionsForZamindar(widget.zamindarId);
      transactions = allTransactions
          .where((t) => t.kisaanId == kisaan.id)
          .toList();
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Error loading ledger: $e');
      }
      return;
    }

    if (!mounted) return;

    final outstanding = _kisaanBalances[kisaan.id] ?? 0;
    final totalDebit = transactions
        .where((t) => t.type == LedgerTransactionType.debit)
        .fold<int>(0, (sum, t) => sum + t.amount);
    final totalCredit = transactions
        .where((t) => t.type == LedgerTransactionType.credit)
        .fold<int>(0, (sum, t) => sum + t.amount);

    Future<void> exportOrShare({required bool share}) async {
      try {
        final rows = transactions
            .map(
              (t) => <String, dynamic>{
                ...t.toMap(),
                'kisaan_name': kisaan.name,
                if (t.id != null) LedgerTransactionTable.id: t.id,
              },
            )
            .toList();
        final file =
            await PdfGenerator.saveZamindarTransactionLedgerToDocuments(
              zamindarName: '${kisaan.name} · ${widget.zamindarName}',
              seasonLabel: 'All seasons',
              transactions: rows,
              outstandingBalance: 'Rs ${_fmt(outstanding)}',
              totalPaymentsReceived: totalCredit,
              totalDebit: totalDebit,
            );
        if (share) {
          final shopName = await ShopSettings.getShopName();
          final phone = (kisaan.phone?.trim().isNotEmpty ?? false)
              ? kisaan.phone!.trim()
              : _zamindarWhatsapp;
          await WhatsAppUrduService.sharePdfWithUrduCaption(
            phone: phone,
            zamindarName: kisaan.name,
            shopName: shopName,
            amount: outstanding.toDouble(),
            pdfPath: file.path,
            detailLines: [
              'زمیندار: ${widget.zamindarName}',
              'کل خریداری: Rs ${_fmt(totalDebit.toDouble())}',
              'کل وصولی: Rs ${_fmt(totalCredit.toDouble())}',
            ],
            subject: 'Kisaan Statement — ${kisaan.name}',
          );
        } else if (mounted) {
          AppToast.showSuccess(context, 'PDF saved to ${file.path}');
        }
      } catch (e) {
        if (mounted) {
          AppToast.showError(context, 'Failed: $e');
        }
      }
    }

    Future<void> printStatement() async {
      try {
        final rows = transactions
            .map(
              (t) => <String, dynamic>{
                ...t.toMap(),
                'kisaan_name': kisaan.name,
                if (t.id != null) LedgerTransactionTable.id: t.id,
              },
            )
            .toList();
        final pdf = await PdfGenerator.generateZamindarTransactionLedgerPdf(
          zamindarName: '${kisaan.name} · ${widget.zamindarName}',
          seasonLabel: 'All seasons',
          transactions: rows,
          outstandingBalance: 'Rs ${_fmt(outstanding)}',
          totalPaymentsReceived: totalCredit,
          totalDebit: totalDebit,
        );
        await PdfGenerator.printDocument(pdf);
      } catch (e) {
        if (mounted) {
          AppToast.showError(context, 'Failed to print: $e');
        }
      }
    }

    final maxDialogHeight = MediaQuery.of(context).size.height * 0.82;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        contentPadding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: SizedBox(
          width: 650,
          height: maxDialogHeight.clamp(420.0, 720.0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.darkGreen,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            kisaan.name.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "Kisaan Account Statement · Under ${widget.zamindarName}",
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFFA7C4A0),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: "Print Statement",
                          icon: const Icon(
                            Icons.print_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: printStatement,
                        ),
                        IconButton(
                          tooltip: "Share via WhatsApp",
                          icon: const Icon(
                            Icons.share_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () => exportOrShare(share: true),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F7F1),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "TOTAL OUTSTANDING",
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "Rs ${_fmt(outstanding)}",
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFA32D2D),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F7F1),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "CROP AREA DETAILS",
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "${_formatKisaanLand(kisaan)} · ${kisaan.currentCrop}",
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.darkGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 20, right: 20),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border, width: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: transactions.isEmpty
                          ? const Center(
                              child: Text(
                                'No transactions yet',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            )
                          : SingleChildScrollView(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minWidth: 610,
                                  ),
                                  child: DataTable(
                                    headingRowHeight: 34,
                                    dataRowMinHeight: 36,
                                    dataRowMaxHeight: 38,
                                    headingRowColor: WidgetStateProperty.all(
                                      const Color(0xFFEAF3DE),
                                    ),
                                    horizontalMargin: 12,
                                    columns: const [
                                      DataColumn(
                                        label: Text(
                                          'Date',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.darkGreen,
                                          ),
                                        ),
                                      ),
                                      DataColumn(
                                        label: Text(
                                          'Description',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.darkGreen,
                                          ),
                                        ),
                                      ),
                                      DataColumn(
                                        label: Text(
                                          'Type',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.darkGreen,
                                          ),
                                        ),
                                      ),
                                      DataColumn(
                                        label: Text(
                                          'Amount',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.darkGreen,
                                          ),
                                        ),
                                      ),
                                    ],
                                    rows: transactions
                                        .map(
                                          (t) => DataRow(
                                            cells: [
                                              DataCell(
                                                Text(
                                                  "${t.dateTime.day}/${t.dateTime.month}/${t.dateTime.year}",
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ),
                                              DataCell(
                                                Text(
                                                  t.description,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              DataCell(
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 2,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        t.type ==
                                                            LedgerTransactionType
                                                                .debit
                                                        ? const Color(
                                                            0xFFFCEBEB,
                                                          )
                                                        : const Color(
                                                            0xFFE6F1FB,
                                                          ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    t.type ==
                                                            LedgerTransactionType
                                                                .debit
                                                        ? 'Debit'
                                                        : 'Credit',
                                                    style: TextStyle(
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color:
                                                          t.type ==
                                                              LedgerTransactionType
                                                                  .debit
                                                          ? const Color(
                                                              0xFF791F1F,
                                                            )
                                                          : const Color(
                                                              0xFF0C447C,
                                                            ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              DataCell(
                                                Text(
                                                  "Rs ${_fmt(t.amount.toDouble())}",
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFFFAFAFA),
                  border: Border(
                    top: BorderSide(color: AppColors.border, width: 0.5),
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => exportOrShare(share: false),
                      icon: const Icon(Icons.picture_as_pdf_outlined, size: 14),
                      label: const Text(
                        "Export PDF Receipt",
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => exportOrShare(share: true),
                      icon: const Icon(Icons.send, size: 14),
                      label: const Text(
                        "WhatsApp Statement",
                        style: TextStyle(fontSize: 11),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                      ),
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

  void _openSettlementForm() async {
    await showDialog(
      context: context,
      builder: (context) => _BillSettlementDialog(
        zamindarId: widget.zamindarId,
        zamindarName: widget.zamindarName,
        kisaans: _kisaans,
        onSettlementApplied: (selectedKisaanId, kisaanName, amount) async {
          try {
            await DatabaseHelper.instance.settleKisaanBulkPayment(
              zamindarId: widget.zamindarId,
              kisaanName: kisaanName,
              amountPaid: amount,
              paymentMethod: 'Cash',
              season: '',
            );
            await _loadKisaans();
            if (mounted) {
              AppToast.showSuccess(
                context,
                'Payment of Rs ${amount.toStringAsFixed(0)} recorded successfully',
              );
            }
          } catch (e) {
            if (mounted) {
              AppToast.showError(context, 'Error recording payment: $e');
            }
          }
        },
      ),
    );
  }

  String _formatKisaanLand(Kisaan kisaan) {
    final unit = _landSummary?.landUnit ?? 'Acre';
    final value = DatabaseHelper.landAcresToUnit(kisaan.landAcres, unit);
    return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 2)} $unit';
  }

  List<Map<String, dynamic>> _buildKisaanSummaryRows(
    Map<int, DateTime> lastPurchaseDates,
  ) {
    return _kisaans.map((k) {
      final lastPurchase = k.id != null ? lastPurchaseDates[k.id!] : null;
      return <String, dynamic>{
        'name': k.name,
        'village': k.village,
        'athaas': DatabaseHelper.landAcresToUnit(k.landAcres, 'Athaas'),
        'current_crop': k.currentCrop,
        'last_purchase_date': lastPurchase,
        'balance_due': k.id != null ? (_kisaanBalances[k.id] ?? 0.0) : 0.0,
      };
    }).toList();
  }

  Future<void> _exportOrShareKisaanSummary({required bool share}) async {
    if (_kisaans.isEmpty) {
      if (!mounted) return;
      AppToast.showWarning(context, 'No kisaans to include in the summary PDF');
      return;
    }

    try {
      Map<int, DateTime> lastPurchaseDates = {};
      try {
        lastPurchaseDates = await DatabaseHelper.instance
            .getLastPurchaseDatesForZamindar(widget.zamindarId);
      } catch (_) {
        // Keep exporting even if last-purchase lookup fails.
      }
      final rows = _buildKisaanSummaryRows(lastPurchaseDates);
      final file = await PdfGenerator.saveKisaanSummaryToDocuments(
        zamindarName: widget.zamindarName,
        rows: rows,
      );
      if (share) {
        final shopName = await ShopSettings.getShopName();
        final totalDue = _kisaanBalances.values.fold<double>(
          0,
          (sum, value) => sum + value,
        );
        final kisaanLines = _kisaans.map((k) {
          final due = k.id != null ? (_kisaanBalances[k.id] ?? 0.0) : 0.0;
          return '${k.name} — Rs ${_fmt(due)}';
        }).toList();

        // Itemized Urdu chat + PDF with matching caption.
        if (WhatsAppUrduService.normalizePhone(_zamindarWhatsapp) != null) {
          await WhatsAppUrduService.sendKisaanSummaryLedger(
            phone: _zamindarWhatsapp,
            zamindarName: widget.zamindarName,
            shopName: shopName,
            amount: totalDue,
            kisaanLines: kisaanLines,
          );
        } else if (mounted) {
          AppToast.showWarning(
            context,
            'No WhatsApp number on file — sharing PDF only.',
          );
        }

        await WhatsAppUrduService.sharePdfWithUrduCaption(
          phone: _zamindarWhatsapp,
          zamindarName: widget.zamindarName,
          shopName: shopName,
          amount: totalDue,
          pdfPath: file.path,
          detailLines: kisaanLines,
          subject: 'Kisaan Summary — ${widget.zamindarName}',
        );
      } else if (mounted) {
        AppToast.showSuccess(context, 'PDF saved to ${file.path}');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed: $e');
      }
    }
  }

  Widget _buildLandAllocationSummary() {
    final summary = _landSummary;
    if (summary == null) return const SizedBox.shrink();

    final activeUnit = summary.landUnit;
    final allocatedText =
        '${summary.allocatedLand.toStringAsFixed(2)} $activeUnit';
    final totalText = '${summary.totalLand.toStringAsFixed(2)} $activeUnit';
    final remainingText =
        '${summary.remainingLand.toStringAsFixed(2)} $activeUnit';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        border: Border(
          bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Total land allocated: $allocatedText / $totalText',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Flexible(
            child: Text(
              'Remaining: $remainingText',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: summary.remainingLand <= 0
                    ? const Color(0xFFA32D2D)
                    : const Color(0xFF27500A),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
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
            OutlinedButton(onPressed: _loadKisaans, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppColors.border, width: 0.5),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        "${_filteredKisaans.length}${_searchController.text.trim().isNotEmpty ? ' of ${_kisaans.length}' : ''} Kisaans under ${widget.zamindarName}",
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.darkGreen,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () =>
                              _exportOrShareKisaanSummary(share: false),
                          icon: const Icon(
                            Icons.picture_as_pdf_outlined,
                            size: 14,
                            color: Color(0xFF27500A),
                          ),
                          label: const Text(
                            "Summary PDF",
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF27500A),
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF27500A)),
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () =>
                              _exportOrShareKisaanSummary(share: true),
                          icon: const Icon(Icons.send, size: 14),
                          label: const Text(
                            "WhatsApp PDF",
                            style: TextStyle(fontSize: 12),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF25D366),
                            foregroundColor: Colors.white,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _openSettlementForm,
                          icon: const Icon(
                            Icons.payment_outlined,
                            size: 14,
                            color: Color(0xFF27500A),
                          ),
                          label: const Text(
                            "Bill Settlement",
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF27500A),
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF27500A)),
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _openKisaanPanel(),
                          icon: const Icon(Icons.person_add_outlined, size: 15),
                          label: const Text("Add Kisaan"),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _buildLandAllocationSummary(),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.sidebarBg, width: 0.5),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.search,
                        size: 16,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(fontSize: 12),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText:
                                'Search by name, village, crop, or phone...',
                            hintStyle: TextStyle(
                              fontSize: 12,
                              color: AppColors.sidebarText,
                            ),
                          ),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        InkWell(
                          onTap: () => _searchController.clear(),
                          child: const Icon(
                            Icons.close,
                            size: 16,
                            color: AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _kisaans.isEmpty
                    ? const Center(
                        child: Text(
                          'No kisaans yet',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                      )
                    : _filteredKisaans.isEmpty
                    ? const Center(
                        child: Text(
                          'No matching kisaans',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filteredKisaans.length,
                        itemBuilder: (context, i) => _kisaanRow(
                          _filteredKisaans[i],
                          isLast: i == _filteredKisaans.length - 1,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kisaanRow(Kisaan k, {required bool isLast}) {
    final initials = k.name
        .split(' ')
        .where((e) => e.isNotEmpty)
        .map((e) => e[0].toUpperCase())
        .take(2)
        .join();
    final balanceDue = _kisaanBalances[k.id] ?? 0;
    final isSettled = balanceDue == 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: const Color(0xFFEAF3DE),
            child: Text(
              initials,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF27500A),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  k.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.darkGreen,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  "${k.village} · ${_formatKisaanLand(k)} · ${k.currentCrop}",
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                "Rs ${_fmt(balanceDue)}",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isSettled
                      ? const Color(0xFF27500A)
                      : const Color(0xFFA32D2D),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                isSettled ? "Settled" : "Balance due",
                style: const TextStyle(fontSize: 9, color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              _smallBtn(Icons.receipt_long_outlined, "Sale", () {
                if (k.id != null && widget.onNavigateToSale != null) {
                  widget.onNavigateToSale!(k.id!);
                }
              }),
              _smallBtn(
                Icons.menu_book_outlined,
                "Ledger",
                () => _viewKisaanLedger(k),
              ),
              _smallBtn(
                Icons.edit_outlined,
                "Edit",
                () => _openKisaanPanel(editTarget: k),
              ),
              _smallBtn(
                Icons.delete_outline,
                "Delete",
                () => _handleDeleteKisaan(k),
                destructive: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _smallBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool destructive = false,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 12),
      label: Text(label, style: const TextStyle(fontSize: 10)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        foregroundColor: destructive ? const Color(0xFFDC3545) : null,
        side: BorderSide(
          color: destructive ? const Color(0xFFF5C6C6) : AppColors.sidebarBg,
          width: 0.5,
        ),
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

class _AddKisaanPanel extends StatefulWidget {
  final int zamindarId;
  final String zamindarName;
  final Kisaan? editTarget;
  final void Function(Kisaan kisaan) onSaved;
  final VoidCallback onCancel;

  const _AddKisaanPanel({
    required this.zamindarId,
    required this.zamindarName,
    this.editTarget,
    required this.onSaved,
    required this.onCancel,
  });

  @override
  State<_AddKisaanPanel> createState() => _AddKisaanPanelState();
}

class _AddKisaanPanelState extends State<_AddKisaanPanel> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _villageController = TextEditingController();
  final _phoneController = TextEditingController();
  final _landController = TextEditingController();
  String _landUnit = "Acre";
  ZamindarLandAllocationSummary? _landSummary;
  List<String> _availableCrops = [];
  final Set<String> _selectedCrops = {};
  bool _loadingCrops = true;
  bool _loadingLandSummary = true;

  @override
  void initState() {
    super.initState();
    _loadZamindarContext();
  }

  Future<void> _loadZamindarContext() async {
    try {
      final summary = await DatabaseHelper.instance
          .getZamindarLandAllocationSummary(
            widget.zamindarId,
            excludeKisaanId: widget.editTarget?.id,
          );
      final zamindar = await DatabaseHelper.instance.getZamindar(
        widget.zamindarId,
      );
      final crops = zamindar?.activeCrops ?? const <String>[];

      if (widget.editTarget != null) {
        _nameController.text = widget.editTarget!.name;
        _villageController.text = widget.editTarget!.village;
        _phoneController.text = widget.editTarget!.phone ?? '';
        final displayLand = DatabaseHelper.landAcresToUnit(
          widget.editTarget!.landAcres,
          summary.landUnit,
        );
        _landController.text = displayLand.toStringAsFixed(2);
        final existing = widget.editTarget!.currentCrop
            .split(',')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty);
        _selectedCrops.addAll(existing);
      }

      if (!mounted) return;
      setState(() {
        _landUnit = summary.landUnit;
        _landSummary = summary;
        _availableCrops = List<String>.from(crops);
        for (final crop in _selectedCrops) {
          if (!_availableCrops.contains(crop)) {
            _availableCrops.add(crop);
          }
        }
        _loadingCrops = false;
        _loadingLandSummary = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingCrops = false;
        _loadingLandSummary = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _villageController.dispose();
    _phoneController.dispose();
    _landController.dispose();
    super.dispose();
  }

  double _convertToAcres(double value, String unit) {
    return DatabaseHelper.landUnitToAcres(value, unit);
  }

  String? _validateLandAllocation(String? val) {
    if (val == null || val.trim().isEmpty) {
      return 'Land area is required';
    }
    final number = double.tryParse(val.trim());
    if (number == null || number <= 0) {
      return 'Enter valid land area';
    }

    final summary = _landSummary;
    if (summary == null) return null;

    final proposedInZamindarUnit = DatabaseHelper.landAcresToUnit(
      _convertToAcres(number, _landUnit),
      summary.landUnit,
    );
    if (proposedInZamindarUnit > summary.remainingLand + 1e-9) {
      return 'Exceeds remaining ${summary.remainingLand.toStringAsFixed(2)} ${summary.landUnit}';
    }
    return null;
  }

  String _otherLandUnitLabel() {
    return _landUnit == 'Acre' ? 'Athaas' : 'Acre';
  }

  String _getConversionText() {
    final inputValue = double.tryParse(_landController.text);
    if (inputValue == null || inputValue == 0) return "";

    if (_landUnit == "Acre") {
      final athaas = inputValue / 4;
      return "= ${athaas.toStringAsFixed(2)} ${_otherLandUnitLabel()}";
    } else {
      final acres = inputValue * 4;
      return "= ${acres.toStringAsFixed(2)} ${_otherLandUnitLabel()}";
    }
  }

  void _toggleCrop(String crop) {
    setState(() {
      if (_selectedCrops.contains(crop)) {
        _selectedCrops.remove(crop);
      } else {
        _selectedCrops.add(crop);
      }
    });
  }

  Widget _buildLandUnitToggle() {
    const units = ['Acre', 'Athaas'];
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4EC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: units.map((unit) {
          final isSelected = _landUnit == unit;
          return GestureDetector(
            onTap: () {
              if (_landUnit == unit) return;
              setState(() => _landUnit = unit);
              _formKey.currentState?.validate();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: AppColors.darkGreen.withValues(alpha: 0.08),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                unit,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected ? AppColors.darkGreen : AppColors.textMuted,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCropPill(String crop) {
    final isSelected = _selectedCrops.contains(crop);
    return GestureDetector(
      onTap: () => _toggleCrop(crop),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF1F8E9) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? AppColors.darkGreen.withValues(alpha: 0.5)
                : AppColors.sidebarBg,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected)
              const Icon(Icons.check, size: 14, color: AppColors.darkGreen),
            if (isSelected) const SizedBox(width: 4),
            Text(
              crop,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? AppColors.darkGreen : AppColors.textMuted,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedCrops.isEmpty) {
      AppToast.showError(context, 'Select at least one crop');
      return;
    }

    final landValue = double.tryParse(_landController.text) ?? 0.0;
    final landInAcres = _convertToAcres(landValue, _landUnit);

    final kisaan = Kisaan(
      id: widget.editTarget?.id,
      zamindarId: widget.zamindarId,
      name: _nameController.text.trim(),
      village: _villageController.text.trim(),
      phone: _phoneController.text.trim().isEmpty
          ? null
          : _phoneController.text.trim(),
      landAcres: landInAcres,
      currentCrop: _selectedCrops.join(', '),
    );
    widget.onSaved(kisaan);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            Container(
              color: AppColors.darkGreen,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.editTarget == null
                          ? "Add Kisaan"
                          : "Update Kisaan Profile",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: widget.onCancel,
                    child: const Icon(
                      Icons.close,
                      size: 18,
                      color: Color(0xFFA7C4A0),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppAutoSuggestField(
                      controller: _nameController,
                      labelText: 'Full name',
                      isRequired: true,
                      fetchSuggestions: (text) => DatabaseHelper.instance
                          .fetchNameSuggestions(KisaanTable.name, text),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Name is required';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _buildFormField(
                            label: "Village",
                            controller: _villageController,
                            required: true,
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Village is required';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildFormField(
                            label: "Phone",
                            controller: _phoneController,
                            required: false,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_loadingLandSummary)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else if (_landSummary != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7F9F4),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppColors.border.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          'Remaining unallocated land: ${_landSummary!.remainingLand.toStringAsFixed(2)} ${_landSummary!.landUnit}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.darkGreen,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Row(
                      children: [
                        const Text(
                          "Land",
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Text(
                          " *",
                          style: TextStyle(color: Colors.red, fontSize: 10),
                        ),
                        const Spacer(),
                        _buildLandUnitToggle(),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _landController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        suffixText: _landUnit,
                        suffixStyle: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.darkGreen,
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
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(7),
                          borderSide: const BorderSide(
                            color: Colors.red,
                            width: 1,
                          ),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(7),
                          borderSide: const BorderSide(
                            color: Colors.red,
                            width: 1,
                          ),
                        ),
                        errorStyle: const TextStyle(fontSize: 9),
                      ),
                      validator: _validateLandAllocation,
                    ),
                    if (_getConversionText().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        _getConversionText(),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.accentGreen,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Text(
                              "Crops",
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              " *",
                              style: TextStyle(color: Colors.red, fontSize: 10),
                            ),
                          ],
                        ),
                        Text(
                          "tap to select",
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.textMuted.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_loadingCrops)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else if (_availableCrops.isEmpty)
                      const Text(
                        "No crops on this Zamindar's profile. Add crops when editing the Zamindar.",
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _availableCrops
                            .map((crop) => _buildCropPill(crop))
                            .toList(),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.border, width: 0.5),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: widget.onCancel,
                    child: const Text("Cancel"),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _save,
                    child: Text(
                      widget.editTarget == null
                          ? "Save Kisaan"
                          : "Update Kisaan",
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormField({
    required String label,
    required TextEditingController controller,
    bool required = false,
    bool isNumber = false,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (required)
              const Text(
                " *",
                style: TextStyle(color: Colors.red, fontSize: 10),
              ),
          ],
        ),
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          keyboardType: isNumber ? TextInputType.number : TextInputType.text,
          style: const TextStyle(fontSize: 12),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
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
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(color: Colors.red, width: 1),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(color: Colors.red, width: 1),
            ),
            errorStyle: const TextStyle(fontSize: 9),
          ),
          validator: validator,
        ),
      ],
    );
  }
}

// Professional & Polished Bill Settlement Window UI Layout Component
class _BillSettlementDialog extends StatefulWidget {
  final int zamindarId;
  final String zamindarName;
  final List<Kisaan> kisaans;
  final void Function(int selectedKisaanId, String kisaanName, double amount)
  onSettlementApplied;

  const _BillSettlementDialog({
    required this.zamindarId,
    required this.zamindarName,
    required this.kisaans,
    required this.onSettlementApplied,
  });

  @override
  State<_BillSettlementDialog> createState() => _BillSettlementDialogState();
}

class _BillSettlementDialogState extends State<_BillSettlementDialog> {
  final _formKey = GlobalKey<FormState>();
  int? _selectedKisaanId;
  final _amountController = TextEditingController();
  bool _showReceiptActions = false;
  String _lastSettledKisaanName = "";
  double _kisaanDebt = 0;
  bool _isLoadingDebt = false;

  @override
  void initState() {
    super.initState();
    if (widget.kisaans.isNotEmpty && widget.kisaans.first.id != null) {
      _selectedKisaanId = widget.kisaans.first.id;
      _loadKisaanDebt(_selectedKisaanId!);
    }
    _amountController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _loadKisaanDebt(int kisaanId) async {
    setState(() => _isLoadingDebt = true);
    try {
      final debt = await DatabaseHelper.instance
          .getKisaanSalesOutstandingDebtById(
            zamindarId: widget.zamindarId,
            kisaanId: kisaanId,
          );
      if (!mounted) return;
      setState(() {
        _kisaanDebt = debt;
        _isLoadingDebt = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _kisaanDebt = 0;
        _isLoadingDebt = false;
      });
    }
  }

  void _onKisaanChanged(int? kisaanId) {
    setState(() {
      _selectedKisaanId = kisaanId;
      _amountController.clear();
    });
    if (kisaanId != null) {
      _loadKisaanDebt(kisaanId);
    } else {
      setState(() => _kisaanDebt = 0);
    }
  }

  double? get _enteredAmount => double.tryParse(_amountController.text.trim());

  bool get _canSubmit {
    if (_selectedKisaanId == null || _isLoadingDebt) return false;
    final amt = _enteredAmount;
    if (amt == null || amt <= 0) return false;
    if (amt > _kisaanDebt) return false;
    return true;
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Panel Header Block
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
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
                        "Recovery & Bill Settlement",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: const Icon(
                        Icons.close,
                        color: Color(0xFFA7C4A0),
                        size: 18,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              if (!_showReceiptActions) ...[
                // Input Workflow View
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F7F1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: AppColors.border,
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.business_outlined,
                                size: 16,
                                color: AppColors.darkGreen,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                "Payer Zamindar: ${widget.zamindarName}",
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.darkGreen,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          "Select Kisaan Account",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<int>(
                          initialValue: _selectedKisaanId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(7),
                              borderSide: const BorderSide(
                                color: AppColors.sidebarBg,
                                width: 0.5,
                              ),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(7),
                            ),
                          ),
                          items: widget.kisaans
                              .where((k) => k.id != null)
                              .map(
                                (k) => DropdownMenuItem(
                                  value: k.id,
                                  child: Text(
                                    k.name,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _onKisaanChanged,
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFCEBEB),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(0xFFE8B4B4),
                              width: 0.5,
                            ),
                          ),
                          child: _isLoadingDebt
                              ? const Row(
                                  children: [
                                    SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Calculating outstanding debt...',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                )
                              : Text(
                                  'Kisaan Remaining Debt: Rs. ${_fmt(_kisaanDebt)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFA32D2D),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          "Collected Amount Payment (Rs)",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: _amountController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.darkGreen,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            prefixText: "Rs ",
                            prefixStyle: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: AppColors.darkGreen,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            hintText: "0",
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
                              borderSide: const BorderSide(
                                color: Colors.red,
                                width: 1,
                              ),
                            ),
                            focusedErrorBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(7),
                              borderSide: const BorderSide(
                                color: Colors.red,
                                width: 1,
                              ),
                            ),
                            errorStyle: const TextStyle(fontSize: 9),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Enter payment amount';
                            }
                            final amt = double.tryParse(value.trim());
                            if (amt == null || amt <= 0) {
                              return 'Enter a valid amount';
                            }
                            if (amt > _kisaanDebt) {
                              return 'Cannot exceed Kisaan debt (Rs ${_fmt(_kisaanDebt)})';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                // Regular Footer Panel Action
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFAFAFA),
                    border: Border(
                      top: BorderSide(color: AppColors.border, width: 0.5),
                    ),
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          "Cancel",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _canSubmit
                            ? () {
                                if (!_formKey.currentState!.validate()) return;
                                final amt = _enteredAmount!;
                                final targetKisaan = widget.kisaans.firstWhere(
                                  (k) => k.id == _selectedKisaanId,
                                );
                                widget.onSettlementApplied(
                                  _selectedKisaanId!,
                                  targetKisaan.name,
                                  amt,
                                );
                                setState(() {
                                  _lastSettledKisaanName = targetKisaan.name;
                                  _showReceiptActions = true;
                                });
                              }
                            : null,
                        child: const Text(
                          "Post Voucher Entry",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Modern Success Voucher Receipts Actions Panel View Look
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const CircleAvatar(
                        radius: 20,
                        backgroundColor: Color(0xFFEAF3DE),
                        child: Icon(
                          Icons.check_circle_outline,
                          color: Color(0xFF27500A),
                          size: 24,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        "Ledger Updated Successfully",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.darkGreen,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Voucher allocated to $_lastSettledKisaanName",
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFAFAFA),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Amount Settled:",
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              "Rs ${_amountController.text}",
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF27500A),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {},
                              icon: const Icon(Icons.print, size: 14),
                              label: const Text(
                                "Print Receipt",
                                style: TextStyle(fontSize: 11),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {},
                              icon: const Icon(Icons.send, size: 14),
                              label: const Text(
                                "WhatsApp PDF",
                                style: TextStyle(fontSize: 11),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF25D366),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          "Done & Close Window",
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
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
