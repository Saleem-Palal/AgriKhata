import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ledger_models.dart';
import '../services/season_service.dart';
import '../services/whatsapp_urdu_service.dart';
import '../utils/season_utils.dart';
import '../utils/pdf_generator.dart';
import '../utils/shop_settings.dart';
import '../Widgets/edit_cash_advance_dialog.dart';
import '../Widgets/edit_payment_dialog.dart';
import '../Widgets/ledger_widgets.dart';
import '../Widgets/past_season_guard.dart';
import '../Widgets/season_management_widgets.dart';
import '../Database/database_helper.dart' as db;
import '../theme/theme.dart';
import '../Data/agri_header.dart';

class MainLedgerScreen extends StatefulWidget {
  final Function(String)? onEditInvoice;

  const MainLedgerScreen({super.key, this.onEditInvoice});

  @override
  State<MainLedgerScreen> createState() => _MainLedgerScreenState();
}

class _MainLedgerScreenState extends State<MainLedgerScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // Keep state alive

  late TabController _tabController;
  late Season _selectedSeason;
  late List<Season> _availableSeasons;
  List<String> _dbSeasonLabels = const [];

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  List<LedgerEntry> _salesEntries = [];
  List<LedgerEntry> _purchasesEntries = [];
  List<PaymentLedgerEntry> _paymentsEntries = [];
  Map<String, double> _purchaseKpis = const {
    'totalPurchases': 0,
    'paidCash': 0,
    'outstandingDebt': 0,
  };
  bool _isLoading = true;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {});
      }
    });
    _selectedSeason = _resolveActiveLedgerSeason();
    _availableSeasons = [
      Season.all,
      ...SeasonUtils.getAvailableSeasons(yearsBack: 3),
    ];
    _loadSeasonOptions();
    _loadLedgerData();

    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });

    db.DatabaseHelper.instance.addListener(_onDatabaseChanged);
    SeasonService.instance.activeSeasonNotifier.addListener(_onActiveSeasonChanged);
  }

  Season _resolveActiveLedgerSeason() {
    final activeName = SeasonService.instance.activeSeasonName;
    if (activeName != null && activeName.isNotEmpty) {
      return SeasonUtils.parseSeasonDisplayName(activeName) ??
          SeasonUtils.getCurrentSeason();
    }
    return SeasonUtils.getCurrentSeason();
  }

  void _onActiveSeasonChanged() {
    if (!mounted) return;
    setState(() => _selectedSeason = _resolveActiveLedgerSeason());
    _loadLedgerData(showLoading: false);
  }

  @override
  void dispose() {
    SeasonService.instance.activeSeasonNotifier
        .removeListener(_onActiveSeasonChanged);
    db.DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onDatabaseChanged() {
    _loadSeasonOptions();
    _loadLedgerData(showLoading: false);
  }

  Future<void> _loadSeasonOptions() async {
    try {
      final seasonNames =
          await db.DatabaseHelper.instance.getDistinctLedgerSeasons();
      var parsed = SeasonUtils.seasonsFromDisplayNames(seasonNames);

      final purchaseDates =
          await db.DatabaseHelper.instance.getPurchaseInvoiceDates();
      for (final date in purchaseDates) {
        final season = SeasonUtils.getCurrentSeason(date);
        if (!parsed.contains(season)) parsed.add(season);
      }

      if (parsed.isEmpty) {
        parsed = [SeasonUtils.getCurrentSeason()];
      }

      parsed.sort((a, b) {
        if (a.isAllSeasons) return -1;
        if (b.isAllSeasons) return 1;
        return b.startDate.compareTo(a.startDate);
      });

      final withAll = [Season.all, ...parsed.where((s) => !s.isAllSeasons)];

      if (!withAll.contains(_selectedSeason)) {
        _selectedSeason = withAll.firstWhere(
          (s) => !s.isAllSeasons,
          orElse: () => Season.all,
        );
      }

      if (mounted) {
        setState(() {
          _dbSeasonLabels = seasonNames;
          _availableSeasons = withAll;
        });
      }
    } catch (e) {
      debugPrint('Failed to load season options: $e');
    }
  }

  DateTime? get _seasonStart =>
      _selectedSeason.isAllSeasons ? null : _selectedSeason.startDate;

  DateTime? get _seasonEnd =>
      _selectedSeason.isAllSeasons ? null : _selectedSeason.endDate;

  /// Prefer the managed season's exact DB name (e.g. `Rabi 2026-27`).
  String? get _seasonFilterName {
    if (_selectedSeason.isAllSeasons) return null;
    final active = SeasonService.instance.activeSeason;
    if (active != null) {
      final parsed = SeasonUtils.parseSeasonDisplayName(active.name);
      if (parsed == _selectedSeason) return active.name;
    }
    for (final label in _dbSeasonLabels) {
      final parsed = SeasonUtils.parseSeasonDisplayName(label);
      if (parsed == _selectedSeason) return label;
    }
    return _selectedSeason.displayName;
  }

  int? get _seasonFilterId {
    if (_selectedSeason.isAllSeasons) return null;
    final active = SeasonService.instance.activeSeason;
    if (active == null) return null;
    final parsed = SeasonUtils.parseSeasonDisplayName(active.name);
    if (parsed == _selectedSeason) return active.id;
    return null;
  }

  List<LineItem> _parseProductSummary(String? summary) {
    if (summary == null || summary.trim().isEmpty) return [];
    return summary.split(', ').map((part) {
      final match = RegExp(r'^(.*) x(\d+)$').firstMatch(part.trim());
      if (match != null) {
        return LineItem(
          productName: match.group(1)!,
          quantity: double.parse(match.group(2)!),
          unit: '',
          unitPrice: 0,
        );
      }
      return LineItem(
        productName: part.trim(),
        quantity: 0,
        unit: '',
        unitPrice: 0,
      );
    }).toList();
  }

  PaymentStatus _purchaseStatusFromTerms(String terms, double paid, double total) {
    switch (terms) {
      case db.PurchasePaymentType.cash:
        return PaymentStatus.paid;
      case db.PurchasePaymentType.partial:
        return PaymentStatus.partial;
      default:
        if (paid <= 0) return PaymentStatus.unpaid;
        if (paid >= total) return PaymentStatus.paid;
        return PaymentStatus.partial;
    }
  }

  Future<void> _loadLedgerData({bool showLoading = true}) async {
    if (showLoading) setState(() => _isLoading = true);

    try {
      final salesWithDetails = await db.DatabaseHelper.instance
          .getAllSalesWithDetails(
            season: _seasonFilterName,
            seasonId: _seasonFilterId,
          );
      final paymentsData = await db.DatabaseHelper.instance.getAllPayments(
        season: _seasonFilterName,
        seasonId: _seasonFilterId,
      );

      final purchaseRows = await db.DatabaseHelper.instance
          .fetchPurchaseLedgerMatrix(
            seasonStart: _seasonStart,
            seasonEnd: _seasonEnd,
          );

      final purchaseKpis = await db.DatabaseHelper.instance
          .fetchPurchaseLedgerKpis(
            seasonStart: _seasonStart,
            seasonEnd: _seasonEnd,
          );

      final registeredZamindars = await db.DatabaseHelper.instance
          .getAllZamindars();
      final registeredZamindarNames = registeredZamindars
          .map((zamindar) => zamindar.name)
          .toSet();

      final salesEntries = <LedgerEntry>[];

      for (final saleData in salesWithDetails) {
        final sale = saleData['sale'] as Map<String, dynamic>;
        final itemsList = saleData['items'] as List<Map<String, dynamic>>;
        final totalCollected = saleData['totalCollected'] as double;

        final invoiceNumber = sale[db.SalesTable.invoiceNumber] as String;
        final dateTimeStr = sale[db.SalesTable.dateTime] as String;
        final zamindarName =
            sale[db.SalesTable.zamindarName] as String? ?? 'Walk-in Customer';
        final kisaanName = sale[db.SalesTable.kisaanName] as String?;
        final totalPayable =
            (sale[db.SalesTable.totalPayable] as num).toDouble();
        final transactionType =
            sale[db.SalesTable.transactionType] as String? ??
            db.SaleTransactionType.productSale;
        final remarks = (sale[db.SalesTable.remarks] as String?)?.trim();

        final items = itemsList.map((item) {
          return LineItem(
            productName: item[db.SaleItemsTable.productName] as String,
            quantity: (item[db.SaleItemsTable.quantity] as num).toDouble(),
            unit: '',
            unitPrice: (item[db.SaleItemsTable.unitPrice] as num).toDouble(),
            seasonalIncrement:
                (item[db.SaleItemsTable.seasonalIncrement] as num?)
                        ?.toDouble() ??
                    0,
            discount:
                (item[db.SaleItemsTable.itemDiscount] as num?)?.toDouble() ??
                    0,
          );
        }).toList();

        PaymentStatus status;
        if (totalCollected >= totalPayable) {
          status = PaymentStatus.paid;
        } else if (totalCollected > 0) {
          status = PaymentStatus.partial;
        } else {
          status = PaymentStatus.unpaid;
        }

        String? advanceDescription;
        if (db.SaleTransactionType.isAdvance(transactionType)) {
          final label = db.SaleTransactionType.displayLabel(transactionType);
          advanceDescription = (remarks != null && remarks.isNotEmpty)
              ? '$label: $remarks'
              : label;
        }

        salesEntries.add(
          LedgerEntry(
            id: 0,
            invoiceNumber: invoiceNumber,
            date: DateTime.parse(dateTimeStr),
            stakeholderName: zamindarName,
            kisaanName: kisaanName,
            items: items,
            total: totalPayable,
            paid: totalCollected,
            status: status,
            season: _selectedSeason.displayName,
            isWalkInCustomer: !registeredZamindarNames.contains(zamindarName),
            description: advanceDescription,
            transactionType: transactionType,
            createdByUserId:
                sale[db.ActorColumns.createdByUserId]?.toString(),
            createdByUserName:
                sale[db.ActorColumns.createdByUserName] as String?,
            createdAt: DateTime.tryParse(
              sale[db.ActorColumns.createdAt] as String? ?? '',
            ),
          ),
        );
      }

      salesEntries.sort((a, b) => b.date.compareTo(a.date));

      final purchasesEntries = <LedgerEntry>[];
      for (final row in purchaseRows) {
        final invoice =
            row[db.PurchaseInvoicesTable.invoiceNumber] as String? ?? '';
        final dateRaw = row[db.PurchaseInvoicesTable.dateTime] as String?;
        final date = dateRaw != null
            ? (DateTime.tryParse(dateRaw) ?? DateTime.now())
            : DateTime.now();
        final wholesaler =
            row['wholesaler_name'] as String? ??
            row[db.PurchaseInvoicesTable.wholesalerName] as String? ??
            '—';
        final total =
            (row[db.PurchaseInvoicesTable.grandTotal] as num?)?.toDouble() ??
            0;
        final paid =
            (row[db.PurchaseInvoicesTable.amountPaid] as num?)?.toDouble() ??
            0;
        final terms =
            row[db.PurchaseInvoicesTable.paymentType] as String? ??
            db.PurchasePaymentType.udhaar;
        final items = _parseProductSummary(
          row['product_summary'] as String?,
        );
        final description =
            row[db.PurchaseInvoicesTable.description] as String?;

        purchasesEntries.add(
          LedgerEntry(
            id: 0,
            invoiceNumber: invoice,
            date: date,
            stakeholderName: wholesaler,
            items: items,
            total: total,
            paid: paid,
            status: _purchaseStatusFromTerms(terms, paid, total),
            season: _selectedSeason.displayName,
            purchaseTerms: terms,
            description: description,
            createdByUserId:
                row[db.ActorColumns.createdByUserId]?.toString(),
            createdByUserName:
                row[db.ActorColumns.createdByUserName] as String?,
            createdAt: DateTime.tryParse(
              row[db.ActorColumns.createdAt] as String? ?? '',
            ),
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _salesEntries = salesEntries;
        _purchasesEntries = purchasesEntries;
        _paymentsEntries = paymentsData
            .map(PaymentLedgerEntry.fromMap)
            .toList();
        _purchaseKpis = purchaseKpis;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading ledger data: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        AppToast.showError(context, 'Failed to load ledger data: $e');
      }
    }
  }

  @override
  void didUpdateWidget(MainLedgerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadLedgerData();
  }

  List<LedgerEntry> get _filteredSalesEntries {
    if (_searchQuery.isEmpty) return _salesEntries;
    return _salesEntries.where((entry) {
      return entry.invoiceNumber.toLowerCase().contains(_searchQuery) ||
          entry.stakeholderName.toLowerCase().contains(_searchQuery) ||
          (entry.kisaanName?.toLowerCase().contains(_searchQuery) ?? false) ||
          entry.ledgerSummary.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  List<LedgerEntry> get _filteredPurchasesEntries {
    if (_searchQuery.isEmpty) return _purchasesEntries;
    return _purchasesEntries.where((entry) {
      return entry.invoiceNumber.toLowerCase().contains(_searchQuery) ||
          entry.stakeholderName.toLowerCase().contains(_searchQuery) ||
          (entry.kisaanName?.toLowerCase().contains(_searchQuery) ?? false) ||
          entry.ledgerSummary.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  List<PaymentLedgerEntry> get _filteredPaymentsEntries {
    if (_searchQuery.isEmpty) return _paymentsEntries;
    return _paymentsEntries.where((entry) {
      return entry.paymentId.toLowerCase().contains(_searchQuery) ||
          (entry.invoiceNumber?.toLowerCase().contains(_searchQuery) ??
              false) ||
          entry.zamindarName.toLowerCase().contains(_searchQuery) ||
          (entry.kisaanName?.toLowerCase().contains(_searchQuery) ?? false) ||
          entry.itemsSummary.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  Future<void> _handleExportStatement() async {
    setState(() => _isExporting = true);

    try {
      final isPurchases = _tabController.index == 1;
      await PdfGenerator.saveConsolidatedLedgerToDocuments(
        salesEntries: isPurchases ? const [] : _filteredSalesEntries,
        purchasesEntries: isPurchases
            ? _filteredPurchasesEntries
            : (_tabController.index == 0
                ? const []
                : _filteredPurchasesEntries),
        paymentEntries: _tabController.index == 2
            ? _filteredPaymentsEntries
            : const [],
        season: _selectedSeason,
      );

      if (mounted) {
        AppToast.showSuccess(
          context,
          isPurchases
              ? 'Purchase Ledger PDF saved successfully'
              : 'PDF Saved Successfully to Local Storage',
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to export: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _handleShareViaWhatsApp() async {
    setState(() => _isExporting = true);

    try {
      final shopName = await ShopSettings.getShopName();
      final tabIndex = _tabController.index;
      final seasonLabel = _selectedSeason.displayName;

      final String recipientLabel;
      final double amount;
      final List<String> detailLines;
      final String subject;
      final String pdfPath;

      if (tabIndex == 1) {
        // Purchases / Wholesalers ledger
        final outstanding = _purchaseKpis['outstandingDebt'] ?? 0;
        final totalPurchases = _purchaseKpis['totalPurchases'] ?? 0;
        final paidCash = _purchaseKpis['paidCash'] ?? 0;
        final file = await PdfGenerator.saveConsolidatedLedgerToDocuments(
          salesEntries: const [],
          purchasesEntries: _filteredPurchasesEntries,
          paymentEntries: const [],
          season: _selectedSeason,
        );
        recipientLabel = 'محترم تھوک فروش';
        amount = outstanding;
        detailLines = [
          'رپورٹ: خریداری کھاتہ — $seasonLabel',
          'کل خریداری: ${WhatsAppUrduService.formatAmount(totalPurchases)}',
          'ادا شدہ نقد: ${WhatsAppUrduService.formatAmount(paidCash)}',
          'رسیدیں: ${_filteredPurchasesEntries.length}',
        ];
        subject = 'AgriKhata Purchase Ledger';
        pdfPath = file.path;
      } else if (tabIndex == 2) {
        // Payments ledger
        final summary = PaymentSummary.fromEntries(_filteredPaymentsEntries);
        final file = await PdfGenerator.saveConsolidatedLedgerToDocuments(
          salesEntries: const [],
          purchasesEntries: const [],
          paymentEntries: _filteredPaymentsEntries,
          season: _selectedSeason,
        );
        recipientLabel = 'محترم گاہک';
        amount = summary.totalPaymentsReceived;
        detailLines = [
          'رپورٹ: وصولی کھاتہ — $seasonLabel',
          'کل وصولیاں: ${WhatsAppUrduService.formatAmount(summary.totalPaymentsReceived)}',
          'ایڈوانس: ${WhatsAppUrduService.formatAmount(summary.totalAdvanceCollected)}',
        ];
        subject = 'AgriKhata Payments Ledger';
        pdfPath = file.path;
      } else {
        // Sales / Zamindars (+ Kisaans) ledger
        final summary = LedgerSummary.fromEntries(_filteredSalesEntries);
        final file = await PdfGenerator.saveConsolidatedLedgerToDocuments(
          salesEntries: _filteredSalesEntries,
          purchasesEntries: const [],
          paymentEntries: const [],
          season: _selectedSeason,
        );
        recipientLabel = 'محترم زمیندار';
        amount = summary.outstandingCredit;
        detailLines = [
          'رپورٹ: فروخت کھاتہ — $seasonLabel',
          'کل فروخت: ${WhatsAppUrduService.formatAmount(summary.totalVolume)}',
          'نقد وصولی: ${WhatsAppUrduService.formatAmount(summary.totalCashReceived)}',
          'رسیدیں: ${_filteredSalesEntries.length}',
        ];
        subject = 'AgriKhata Sales Ledger';
        pdfPath = file.path;
      }

      await WhatsAppUrduService.sharePdfWithUrduCaption(
        phone: '',
        zamindarName: recipientLabel,
        shopName: shopName,
        amount: amount,
        pdfPath: pdfPath,
        detailLines: detailLines,
        subject: subject,
      );
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to share via WhatsApp: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          AgriHeader(
            breadcrumbs: const ['Finance', 'Ledger'],
            actions: const [
              ActiveSeasonBadge(),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  _buildTabsCard(),
                  const SizedBox(height: 14),
                  _buildFilterRow(),
                  const SizedBox(height: 14),
                  _buildKpiRow(),
                  const SizedBox(height: 14),
                  Expanded(child: _buildLedgerCard()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                _tabController.animateTo(0);
                setState(() {});
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _tabController.index == 0
                      ? const Color(0xFFF7F9F4)
                      : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: _tabController.index == 0
                          ? const Color(0xFF1B4332)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
                child: Text(
                  'Sales Ledger',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: _tabController.index == 0
                        ? const Color(0xFF1B4332)
                        : const Color(0xFF95B89A),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                _tabController.animateTo(1);
                setState(() {});
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _tabController.index == 1
                      ? const Color(0xFFF7F9F4)
                      : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: _tabController.index == 1
                          ? const Color(0xFF1B4332)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  'Purchases Ledger',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: _tabController.index == 1
                        ? const Color(0xFF1B4332)
                        : const Color(0xFF95B89A),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                _tabController.animateTo(2);
                setState(() {});
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _tabController.index == 2
                      ? const Color(0xFFF7F9F4)
                      : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: _tabController.index == 2
                          ? const Color(0xFF1B4332)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(10),
                    bottomRight: Radius.circular(10),
                  ),
                ),
                child: Text(
                  'Payments Ledger',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: _tabController.index == 2
                        ? const Color(0xFF1B4332)
                        : const Color(0xFF95B89A),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    final searchHint = _tabController.index == 1
        ? 'Search Invoice # or Wholesaler name...'
        : _tabController.index == 2
            ? 'Search Payment ID, Invoice # or Zamindar...'
            : 'Search Invoice #, Zamindar or Kisaan name...';

    return AppSearchBar(
      controller: _searchController,
      hintText: searchHint,
      breakpoint: 720,
      filters: [
        SeasonDropdown(
          selectedSeason: _selectedSeason,
          availableSeasons: _availableSeasons,
          onChanged: (season) {
            if (season != null && season != _selectedSeason) {
              setState(() => _selectedSeason = season);
              _loadLedgerData();
            }
          },
        ),
        AppButton.secondary(
          label: 'Export Statement',
          icon: Icons.file_download_outlined,
          loading: _isExporting,
          onPressed: _isExporting ? null : _handleExportStatement,
        ),
        AppButton.whatsapp(
          label: 'Share via WhatsApp',
          loading: _isExporting,
          onPressed: _isExporting ? null : _handleShareViaWhatsApp,
        ),
      ],
    );
  }

  Widget _buildKpiRow() {
    if (_isLoading) {
      return const SizedBox.shrink();
    }

    if (_tabController.index == 2) {
      final summary = PaymentSummary.fromEntries(_filteredPaymentsEntries);
      return Row(
        children: [
          Expanded(
            child: _buildKpiCard(
              'Total Payments Received',
              summary.totalPaymentsReceived,
              const Color(0xFF1B4332),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              'Total Advance Collected',
              summary.totalAdvanceCollected,
              const Color(0xFF2D6A4F),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              'Total Wallet Deductions',
              summary.totalWalletDeductions,
              const Color(0xFF1565C0),
            ),
          ),
        ],
      );
    }

    if (_tabController.index == 1) {
      final useLiveFilter = _searchQuery.isNotEmpty;
      final summary = useLiveFilter
          ? LedgerSummary.fromEntries(_filteredPurchasesEntries)
          : LedgerSummary(
              totalVolume: _purchaseKpis['totalPurchases'] ?? 0,
              totalCashReceived: _purchaseKpis['paidCash'] ?? 0,
              outstandingCredit: _purchaseKpis['outstandingDebt'] ?? 0,
            );
      return Row(
        children: [
          Expanded(
            child: _buildKpiCard(
              'Total Purchases',
              summary.totalVolume,
              const Color(0xFF1B4332),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              'Paid Cash Outflow',
              summary.totalCashReceived,
              const Color(0xFF2D6A4F),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              'Outstanding Supplier Debt',
              summary.outstandingCredit,
              const Color(0xFFA32D2D),
            ),
          ),
        ],
      );
    }

    final summary = LedgerSummary.fromEntries(_filteredSalesEntries);

    return Row(
      children: [
        Expanded(
          child: _buildKpiCard(
            'Total Volume Sold',
            summary.totalVolume,
            const Color(0xFF1B4332),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildKpiCard(
            'Total Cash Received',
            summary.totalCashReceived,
            const Color(0xFF2D6A4F),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildKpiCard(
            'Outstanding Credit',
            summary.outstandingCredit,
            const Color(0xFFA32D2D),
          ),
        ),
      ],
    );
  }

  Widget _buildKpiCard(String label, double value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: Color(0xFF95B89A),
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '₨ ${NumberFormat('#,##,##0').format(value)}',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerCard() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1B4332)),
        ),
      );
    }

    if (_tabController.index == 0) {
      return LedgerTable(
        entries: _filteredSalesEntries,
        onRefresh: _loadLedgerData,
        onEdit: _handleEditInvoice,
        onDelete: _handleDeleteInvoice,
      );
    } else if (_tabController.index == 1) {
      return PurchaseLedgerTable(
        entries: _filteredPurchasesEntries,
        onRefresh: _loadLedgerData,
      );
    } else {
      return PaymentsLedgerTable(
        entries: _filteredPaymentsEntries,
        onEditPayment: _handleEditPayment,
      );
    }
  }

  Future<void> _handleEditPayment(PaymentLedgerEntry entry) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonLabel: entry.season,
    );
    if (!allowed || !mounted) return;

    final updated = await showEditPaymentDialog(
      context: context,
      paymentId: entry.paymentId,
    );
    if (updated && mounted) {
      AppToast.showSuccess(context, 'Payment updated');
      await _loadLedgerData(showLoading: false);
    }
  }

  Future<void> _handleEditInvoice(LedgerEntry entry) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonLabel: entry.season,
    );
    if (!allowed || !mounted) return;

    if (entry.isAdvance) {
      await showEditCashAdvanceDialog(
        context: context,
        invoiceNumber: entry.invoiceNumber,
      );
      return;
    }

    // Use the callback from Shell instead of Navigator.push
    // Pass the actual invoice_number string instead of the fake runtime counter
    if (widget.onEditInvoice != null) {
      widget.onEditInvoice!(entry.invoiceNumber);
    }
  }

  Future<void> _handleDeleteInvoice(LedgerEntry entry) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonLabel: entry.season,
    );
    if (!allowed || !mounted) return;

    final confirmed = await AppDialog.confirm(
      context: context,
      title: 'Delete Transaction?',
      message:
          'Are you sure you want to delete this transaction and all associated payments?',
      confirmLabel: 'Delete',
      danger: true,
    );

    if (confirmed != true) return;

    try {
      await db.DatabaseHelper.instance.deleteInvoiceEntirely(entry.invoiceNumber);
      if (mounted) {
        AppToast.showSuccess(
          context,
          'Invoice ${entry.invoiceNumber} deleted',
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to delete invoice: $e');
      }
    }
  }
}
