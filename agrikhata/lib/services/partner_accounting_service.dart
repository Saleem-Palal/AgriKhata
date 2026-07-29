import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/models/partner_model.dart';

/// Partner equity ledger engine.
///
/// - Overhead expenses (rent, salaries, utilities) → equal split (50-50 for 2).
/// - Invoice profit margins → split by dynamic Net Equity Share %.
class PartnerAccountingService {
  PartnerAccountingService._();
  static final PartnerAccountingService instance = PartnerAccountingService._();

  final DatabaseHelper _db = DatabaseHelper.instance;

  static const Set<String> overheadCategories = {
    'Shop Rent',
    'Electricity / Utilities',
    'Employee Salaries',
    'Helper Salary',
  };

  // ── Equity math ────────────────────────────────────────────────────────

  double totalBusinessEquity(List<PartnerModel> partners) {
    return partners
        .where((p) => p.isActive)
        .fold<double>(0, (sum, p) => sum + p.totalEquity);
  }

  double partnerEquitySharePct(
    PartnerModel partner,
    List<PartnerModel> partners,
  ) {
    return partner.equityPercentage(totalBusinessEquity(partners));
  }

  double totalActiveDrawings(List<PartnerModel> partners) {
    return partners
        .where((p) => p.isActive)
        .fold<double>(0, (sum, p) => sum + p.activeDrawings);
  }

  double overheadSharePerPartner(double amount, int activePartnerCount) {
    if (activePartnerCount <= 0 || amount <= 0) return 0;
    return amount / activePartnerCount;
  }

  bool isOverheadCategory(String category) =>
      overheadCategories.contains(category.trim());

  // ── Reads ──────────────────────────────────────────────────────────────

  Future<List<PartnerModel>> getActivePartners() =>
      _db.getPartners(activeOnly: true);

  Future<List<PartnerModel>> getAllPartners() => _db.getPartners();

  Future<PartnerModel?> getPartner(String id) => _db.getPartnerById(id);

  Future<PartnerModel?> getPartnerByZamindarId(String zamindarId) =>
      _db.getPartnerByZamindarId(zamindarId);

  Future<bool> isPartnerLinkedZamindar(int? zamindarId) async {
    if (zamindarId == null) return false;
    final partner = await getPartnerByZamindarId(zamindarId.toString());
    return partner != null && partner.isActive;
  }

  Future<List<PartnerTransactionModel>> getTransactions({
    String? type,
    String? partnerId,
  }) =>
      _db.getPartnerTransactions(type: type, partnerId: partnerId);

  Future<List<PartnerDrawingModel>> getDrawings({String? partnerId}) =>
      _db.getPartnerDrawings(partnerId: partnerId);

  Future<bool> isSeasonAlreadySettled(String seasonLabel) async {
    final label = seasonLabel.trim();
    if (label.isEmpty) return false;
    final txs = await getTransactions(
      type: PartnerTransactionType.seasonalSettlement,
    );
    return txs.any((t) => (t.seasonLabel ?? '').trim() == label);
  }

  // ── Mutations ──────────────────────────────────────────────────────────

  Future<PartnerModel> addPartner({
    required String name,
    required String phone,
    required double initialCapital,
    String? userAccountId,
    String? zamindarId,
    DateTime? createdAt,
  }) async {
    final partner = await _db.insertPartner(
      PartnerModel(
        id: '',
        name: name.trim(),
        phone: phone.trim(),
        userAccountId: userAccountId,
        zamindarId: zamindarId,
        initialCapital: initialCapital,
        createdAt: createdAt ?? DateTime.now(),
      ),
    );
    if (initialCapital > 0) {
      await _db.insertPartnerTransaction(
        partnerId: partner.id,
        type: PartnerTransactionType.capitalInjection,
        amount: initialCapital,
        date: createdAt ?? DateTime.now(),
        paymentChannel: PartnerCapitalPaymentSource.shopCounterCashDeposit,
        reference: 'INITIAL-CAPITAL',
        notes: 'Opening partner capital',
        equityPctAfter: 100,
      );
    }
    return partner;
  }

  Future<PartnerModel> updatePartner(PartnerModel partner) =>
      _db.updatePartner(partner);

  /// Inject fresh out-of-pocket capital and recalculate equity shares.
  Future<PartnerTransactionModel> injectOutOfPocketCapital({
    required String partnerId,
    required double amount,
    required String paymentSource,
    required String reference,
    String? notes,
    DateTime? date,
  }) async {
    if (amount <= 0) throw ArgumentError('Amount must be greater than zero');
    if (reference.trim().isEmpty) {
      throw ArgumentError('Reference / Receipt # is required');
    }

    final partners = await getActivePartners();
    PartnerModel? partner;
    for (final p in partners) {
      if (p.id == partnerId) partner = p;
    }
    if (partner == null) throw StateError('Partner not found');

    final beforePct = partnerEquitySharePct(partner, partners);
    final updated = partner.copyWith(
      outOfPocketInjections: partner.outOfPocketInjections + amount,
    );
    await _db.updatePartner(updated);

    final afterPartners = partners
        .map((p) => p.id == partnerId ? updated : p)
        .toList();
    final afterPct = partnerEquitySharePct(updated, afterPartners);

    return _db.insertPartnerTransaction(
      partnerId: partnerId,
      type: PartnerTransactionType.capitalInjection,
      amount: amount,
      date: date ?? DateTime.now(),
      paymentChannel: paymentSource,
      reference: reference.trim(),
      notes: notes?.trim(),
      equityPctBefore: beforePct,
      equityPctAfter: afterPct,
    );
  }

  /// Convert unsettled profit into permanent reinvested capital.
  Future<PartnerTransactionModel> reinvestRetainedProfit({
    required String partnerId,
    required double amount,
    String? seasonLabel,
    String? notes,
    DateTime? date,
  }) async {
    if (amount <= 0) throw ArgumentError('Amount must be greater than zero');

    final partners = await getActivePartners();
    PartnerModel? partner;
    for (final p in partners) {
      if (p.id == partnerId) partner = p;
    }
    if (partner == null) throw StateError('Partner not found');
    if (amount > partner.unsettledProfit + 0.009) {
      throw StateError(
        'Amount exceeds unsettled profit '
        '(${partner.unsettledProfit.toStringAsFixed(0)} PKR available)',
      );
    }

    final beforePct = partnerEquitySharePct(partner, partners);
    final updated = partner.copyWith(
      unsettledProfit: partner.unsettledProfit - amount,
      reinvestedProfit: partner.reinvestedProfit + amount,
    );
    await _db.updatePartner(updated);

    final afterPartners = partners
        .map((p) => p.id == partnerId ? updated : p)
        .toList();
    final afterPct = partnerEquitySharePct(updated, afterPartners);

    return _db.insertPartnerTransaction(
      partnerId: partnerId,
      type: PartnerTransactionType.profitReinvestment,
      amount: amount,
      date: date ?? DateTime.now(),
      seasonLabel: seasonLabel,
      notes: notes?.trim(),
      reference: seasonLabel,
      equityPctBefore: beforePct,
      equityPctAfter: afterPct,
    );
  }

  Future<PartnerDrawingModel> recordDrawing({
    required String partnerId,
    required double amount,
    required String type,
    String? notes,
    DateTime? date,
  }) async {
    final drawing = await _db.recordPartnerDrawing(
      partnerId: partnerId,
      amount: amount,
      type: type,
      notes: notes,
      date: date,
    );
    await _db.insertPartnerTransaction(
      partnerId: partnerId,
      type: PartnerTransactionType.cashDrawing,
      amount: type.toUpperCase() == PartnerDrawingType.returned
          ? -amount
          : amount,
      date: date ?? DateTime.now(),
      notes: notes,
      reference: type.toUpperCase(),
    );
    return drawing;
  }

  Future<void> settleDrawing(String drawingId) =>
      _db.settlePartnerDrawing(drawingId);

  /// Credits each partner's unsettled profit pool by equity ratio.
  ///
  /// When [lockAndArchiveSeason] is true, the season ledger is locked so past
  /// invoices tagged with [seasonLabel] cannot be edited.
  Future<List<PartnerSettlementShare>> runSeasonalSettlement({
    required double netProfit,
    required String seasonLabel,
    DateTime? settledAt,
    bool lockAndArchiveSeason = false,
  }) async {
    settledAt ??= DateTime.now();
    if (netProfit <= 0) {
      throw ArgumentError('Net profit must be greater than zero');
    }
    if (await isSeasonAlreadySettled(seasonLabel)) {
      throw StateError(
        'Season "$seasonLabel" has already been settled',
      );
    }

    final partners = await getActivePartners();
    if (partners.isEmpty) {
      throw StateError('No active partners to settle');
    }
    final total = totalBusinessEquity(partners);
    if (total <= 0) {
      throw StateError('Total business equity is zero — add capital first');
    }

    final shares = <PartnerSettlementShare>[];
    for (final partner in partners) {
      final pct = partnerEquitySharePct(partner, partners);
      final profitCredit = netProfit * (pct / 100);

      double debtOffset = 0;
      final zId = int.tryParse(partner.zamindarId ?? '');
      if (zId != null) {
        final balances = await _db.getZamindarBalancesSafe(zId);
        final outstanding =
            (balances?['outstandingBalance'] as num?)?.toDouble() ?? 0;
        if (outstanding > 0) {
          debtOffset = outstanding > profitCredit ? profitCredit : outstanding;
        }
      }

      final netCredit = profitCredit - debtOffset;
      final drawingsClear = partner.activeDrawings > 0
          ? (netCredit > partner.activeDrawings
              ? partner.activeDrawings
              : netCredit)
          : 0.0;
      final unsettledAdd = netCredit - drawingsClear;

      final updated = partner.copyWith(
        unsettledProfit: partner.unsettledProfit + unsettledAdd,
        activeDrawings: partner.activeDrawings - drawingsClear,
      );
      await _db.updatePartner(updated);
      await _db.insertPartnerTransaction(
        partnerId: partner.id,
        type: PartnerTransactionType.seasonalSettlement,
        amount: unsettledAdd,
        date: settledAt,
        seasonLabel: seasonLabel,
        notes: debtOffset > 0
            ? 'Zamindar debt offset ₨ ${debtOffset.round()}'
            : 'Credited to unsettled profit',
        reference: seasonLabel,
        equityPctBefore: pct,
        equityPctAfter: pct,
      );

      shares.add(
        PartnerSettlementShare(
          partner: updated,
          equitySharePct: pct,
          profitCredit: profitCredit,
          zamindarDebtOffset: debtOffset,
          netUnsettledCredit: unsettledAdd,
        ),
      );
    }

    if (lockAndArchiveSeason) {
      await _db.archiveSeason(
        seasonLabel,
        notes: 'Locked on seasonal settlement ${settledAt.toIso8601String()}',
      );
    }
    return shares;
  }

  /// Posts equal overhead shares for a saved store overhead expense.
  Future<void> postOverheadExpenseSplit({
    required String category,
    required double amount,
    DateTime? date,
    String? expenseId,
  }) async {
    if (!isOverheadCategory(category) || amount <= 0) return;
    final partners = await getActivePartners();
    if (partners.isEmpty) return;
    final share = overheadSharePerPartner(amount, partners.length);
    final when = date ?? DateTime.now();
    for (final p in partners) {
      await _db.insertPartnerTransaction(
        partnerId: p.id,
        type: PartnerTransactionType.overheadShare,
        amount: share,
        date: when,
        notes: category,
        reference: expenseId,
      );
    }
  }

  Future<List<OverheadSplitRow>> getOverheadSplitRows({
    String filterType = 'This Month',
  }) async {
    final partners = await getActivePartners();
    final expenses = await _db.getExpensesFilter(filterType: filterType);
    final overheads =
        expenses.where((e) => isOverheadCategory(e.category)).toList();
    final n = partners.isEmpty ? 1 : partners.length;
    return overheads.map((e) {
      final per = overheadSharePerPartner(e.amount, n);
      return OverheadSplitRow(
        expense: e,
        shareByPartnerId: {for (final p in partners) p.id: per},
        partners: partners,
      );
    }).toList();
  }

  /// Live invoice → COGS → margin → equity-weighted partner shares.
  Future<List<InvoiceMarginSplitRow>> getInvoiceMarginSplits({
    int limit = 80,
  }) async {
    final partners = await getActivePartners();
    if (partners.isEmpty) return [];

    final sales = await _db.getAllSalesWithDetails();
    final productCosts = await _productCostByName();
    final totalEq = totalBusinessEquity(partners);
    final pctById = {
      for (final p in partners) p.id: p.equityPercentage(totalEq),
    };

    final rows = <InvoiceMarginSplitRow>[];
    for (final saleWrap in sales.take(limit)) {
      final sale = saleWrap['sale'] as Map<String, dynamic>? ?? saleWrap;
      final items = (saleWrap['items'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];

      final invoiceNumber =
          sale[SalesTable.invoiceNumber]?.toString() ?? '';
      if (invoiceNumber.isEmpty) continue;

      final invoiceAmount =
          (sale[SalesTable.totalPayable] as num?)?.toDouble() ?? 0;
      final overallDiscount =
          (sale[SalesTable.overallDiscount] as num?)?.toDouble() ?? 0;
      final txType = sale[SalesTable.transactionType] as String? ??
          SaleTransactionType.productSale;

      double cogs = 0;
      if (SaleTransactionType.isAdvance(txType)) {
        // Zero-margin loan: COGS = sale price → Rs 0 partner margin.
        cogs = invoiceAmount;
      } else {
        for (final item in items) {
          final name = item[SaleItemsTable.productName] as String? ?? '';
          final qty = (item[SaleItemsTable.quantity] as num?)?.toInt() ?? 0;
          final cost = productCosts[name] ?? 0;
          cogs += qty * cost;
        }
      }

      final netMargin = invoiceAmount - cogs;
      // Discounts already reflected in total_payable; overallDiscount kept for UI.
      final _ = overallDiscount;

      final shareById = <String, double>{
        for (final p in partners)
          p.id: netMargin * ((pctById[p.id] ?? 0) / 100),
      };

      final rawDate = sale[SalesTable.dateTime] as String? ?? '';
      rows.add(
        InvoiceMarginSplitRow(
          invoiceNumber: invoiceNumber,
          date: DateTime.tryParse(rawDate) ?? DateTime.now(),
          customerName: sale[SalesTable.zamindarName] as String? ??
              sale['zamindar_name'] as String? ??
              'Walk-in Customer',
          invoiceAmount: invoiceAmount,
          cogs: cogs,
          netMargin: netMargin,
          shareByPartnerId: shareById,
          equityPctByPartnerId: Map.of(pctById),
          items: items,
        ),
      );
    }
    return rows;
  }

  Future<Map<String, double>> _productCostByName() async {
    final products = await _db.getAllProducts();
    return {
      for (final p in products) p.name: p.costPrice.toDouble(),
    };
  }
}

class OverheadSplitRow {
  final DbExpense expense;
  final Map<String, double> shareByPartnerId;
  final List<PartnerModel> partners;

  const OverheadSplitRow({
    required this.expense,
    required this.shareByPartnerId,
    required this.partners,
  });
}

/// Thin compatibility facade — existing screens keep importing PartnerService.
class PartnerService {
  PartnerService._();
  static final PartnerService instance = PartnerService._();

  final PartnerAccountingService _acct = PartnerAccountingService.instance;

  static Set<String> get overheadCategories =>
      PartnerAccountingService.overheadCategories;

  double totalBusinessCapital(List<PartnerModel> partners) =>
      _acct.totalBusinessEquity(partners);

  double partnerEquity(PartnerModel partner) => partner.totalEquity;

  double partnerEquitySharePct(
    PartnerModel partner,
    List<PartnerModel> partners,
  ) =>
      _acct.partnerEquitySharePct(partner, partners);

  double totalActiveDrawings(List<PartnerModel> partners) =>
      _acct.totalActiveDrawings(partners);

  double overheadSharePerPartner(double amount, int activePartnerCount) =>
      _acct.overheadSharePerPartner(amount, activePartnerCount);

  bool isOverheadCategory(String category) =>
      _acct.isOverheadCategory(category);

  Future<List<PartnerModel>> getActivePartners() => _acct.getActivePartners();
  Future<List<PartnerModel>> getAllPartners() => _acct.getAllPartners();
  Future<PartnerModel?> getPartner(String id) => _acct.getPartner(id);
  Future<PartnerModel?> getPartnerByZamindarId(String zamindarId) =>
      _acct.getPartnerByZamindarId(zamindarId);
  Future<bool> isPartnerLinkedZamindar(int? zamindarId) =>
      _acct.isPartnerLinkedZamindar(zamindarId);

  Future<PartnerModel> addPartner({
    required String name,
    required String phone,
    required double initialCapital,
    String? userAccountId,
    String? zamindarId,
    DateTime? createdAt,
  }) =>
      _acct.addPartner(
        name: name,
        phone: phone,
        initialCapital: initialCapital,
        userAccountId: userAccountId,
        zamindarId: zamindarId,
        createdAt: createdAt,
      );

  Future<PartnerModel> updatePartner(PartnerModel partner) =>
      _acct.updatePartner(partner);

  Future<PartnerDrawingModel> recordDrawing({
    required String partnerId,
    required double amount,
    required String type,
    String? notes,
    DateTime? date,
  }) =>
      _acct.recordDrawing(
        partnerId: partnerId,
        amount: amount,
        type: type,
        notes: notes,
        date: date,
      );

  Future<void> settleDrawing(String drawingId) =>
      _acct.settleDrawing(drawingId);

  Future<List<PartnerDrawingModel>> getDrawings({String? partnerId}) =>
      _acct.getDrawings(partnerId: partnerId);

  Future<List<PartnerSettlementShare>> runSeasonalSettlement({
    required double netProfit,
    required String seasonLabel,
    DateTime? settledAt,
    bool lockAndArchiveSeason = false,
  }) =>
      _acct.runSeasonalSettlement(
        netProfit: netProfit,
        seasonLabel: seasonLabel,
        settledAt: settledAt,
        lockAndArchiveSeason: lockAndArchiveSeason,
      );

  Future<List<OverheadSplitRow>> getOverheadSplitRows({
    String filterType = 'This Month',
  }) =>
      _acct.getOverheadSplitRows(filterType: filterType);
}
