import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/models/ledger_models.dart';
import 'package:agrikhata/models/partner_model.dart';
import 'package:agrikhata/services/partner_accounting_service.dart';
import 'package:agrikhata/utils/season_utils.dart';

/// Aggregates seasonal cash / recovered-credit margins and overheads for
/// partner profit distribution.
class SettlementService {
  SettlementService._();
  static final SettlementService instance = SettlementService._();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final PartnerAccountingService _acct = PartnerAccountingService.instance;

  /// Live seasonal P&L used by the Seasonal Settlement dialog.
  Future<SeasonalProfitSummary> aggregateSeasonProfit({
    Season? season,
    DateTime? rangeStart,
    DateTime? rangeEnd,
    String? seasonLabel,
  }) async {
    final resolved = _resolveWindow(
      season: season,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      seasonLabel: seasonLabel,
    );

    final partners = await _acct.getActivePartners();
    final productCosts = await _productCostByName();
    final sales = await _db.getAllSalesWithDetails();
    final overheads = await _db.getExpensesInRange(
      start: resolved.start,
      end: resolved.end,
    );

    var totalCashSalesMargin = 0.0;
    var totalRecoveredCreditMargin = 0.0;
    var totalUnrecoveredCreditMargin = 0.0;

    for (final wrap in sales) {
      final sale = wrap['sale'] as Map<String, dynamic>? ?? wrap;
      final txType = sale[SalesTable.transactionType] as String? ??
          SaleTransactionType.productSale;
      // Advance loans are zero-margin khaata records — exclude from P&L.
      if (SaleTransactionType.isAdvance(txType)) continue;

      final items =
          (wrap['items'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final payments =
          (wrap['payments'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];

      final invoiceAmount =
          (sale[SalesTable.totalPayable] as num?)?.toDouble() ?? 0;
      if (invoiceAmount <= 0.009) continue;

      final cogs = _cogsForItems(items, productCosts);
      final margin = invoiceAmount - cogs;
      final marginPerRupee = margin / invoiceAmount;

      final method =
          (sale[SalesTable.paymentMethod] as String? ?? '').trim();
      final saleSeason =
          (sale[SalesTable.season] as String? ?? '').trim();
      final saleDate = DateTime.tryParse(
            sale[SalesTable.dateTime] as String? ?? '',
          ) ??
          DateTime.now();
      final saleInSeason = _saleBelongsToSeason(
        saleSeason: saleSeason,
        saleDate: saleDate,
        label: resolved.label,
        start: resolved.start,
        end: resolved.end,
      );

      final isCash = method.toLowerCase() == 'cash';
      final isCredit = !isCash;

      if (isCash && saleInSeason) {
        totalCashSalesMargin += margin;
        continue;
      }

      if (!isCredit) continue;

      final collected =
          (wrap['totalCollected'] as num?)?.toDouble() ?? 0;
      final remaining =
          (invoiceAmount - collected).clamp(0.0, invoiceAmount);

      if (saleInSeason) {
        totalUnrecoveredCreditMargin += marginPerRupee * remaining;
      }

      totalRecoveredCreditMargin += _recoveredMarginInWindow(
        invoiceAmount: invoiceAmount,
        marginPerRupee: marginPerRupee,
        saleDate: saleDate,
        saleInSeason: saleInSeason,
        paidAmountOnSale:
            (sale[SalesTable.paidAmount] as num?)?.toDouble() ?? 0,
        payments: payments,
        start: resolved.start,
        end: resolved.end,
      );
    }

    final totalSeasonOverheads = overheads
        .where((e) => _acct.isOverheadCategory(e.category))
        .fold<double>(0, (sum, e) => sum + e.amount);

    final netDistributableProfit =
        (totalCashSalesMargin + totalRecoveredCreditMargin) -
            totalSeasonOverheads;

    final totalEq = _acct.totalBusinessEquity(partners);
    final partnerShares = partners
        .map((p) {
          final pct = p.equityPercentage(totalEq);
          return SeasonalPartnerSplit(
            partner: p,
            equitySharePct: pct,
            profitCredit: netDistributableProfit > 0
                ? netDistributableProfit * (pct / 100)
                : 0,
          );
        })
        .toList();

    final alreadySettled =
        await _acct.isSeasonAlreadySettled(resolved.label);
    final archived = await _db.isSeasonArchived(resolved.label);

    return SeasonalProfitSummary(
      seasonLabel: resolved.label,
      start: resolved.start,
      end: resolved.end,
      totalCashSalesMargin: totalCashSalesMargin,
      totalRecoveredCreditMargin: totalRecoveredCreditMargin,
      totalUnrecoveredCreditMargin: totalUnrecoveredCreditMargin,
      totalSeasonOverheads: totalSeasonOverheads,
      netDistributableProfit: netDistributableProfit,
      partnerShares: partnerShares,
      alreadySettled: alreadySettled,
      isArchived: archived,
    );
  }

  _SeasonWindow _resolveWindow({
    Season? season,
    DateTime? rangeStart,
    DateTime? rangeEnd,
    String? seasonLabel,
  }) {
    if (season != null) {
      return _SeasonWindow(
        label: season.displayName,
        start: season.startDate,
        end: season.endDate,
      );
    }
    if (rangeStart != null && rangeEnd != null) {
      final label = (seasonLabel != null && seasonLabel.trim().isNotEmpty)
          ? seasonLabel.trim()
          : '${_fmtDay(rangeStart)} → ${_fmtDay(rangeEnd)}';
      return _SeasonWindow(
        label: label,
        start: rangeStart,
        end: rangeEnd,
      );
    }
    final parsed = seasonLabel != null
        ? SeasonUtils.parseSeasonDisplayName(seasonLabel)
        : null;
    final s = parsed ?? SeasonUtils.getCurrentSeason();
    return _SeasonWindow(
      label: s.displayName,
      start: s.startDate,
      end: s.endDate,
    );
  }

  bool _saleBelongsToSeason({
    required String saleSeason,
    required DateTime saleDate,
    required String label,
    required DateTime start,
    required DateTime end,
  }) {
    if (saleSeason == label) return true;
    return !saleDate.isBefore(start) && !saleDate.isAfter(end);
  }

  double _recoveredMarginInWindow({
    required double invoiceAmount,
    required double marginPerRupee,
    required DateTime saleDate,
    required bool saleInSeason,
    required double paidAmountOnSale,
    required List<Map<String, dynamic>> payments,
    required DateTime start,
    required DateTime end,
  }) {
    if (payments.isNotEmpty) {
      var recovered = 0.0;
      for (final p in payments) {
        final method =
            (p[PaymentsTable.paymentMethod] as String? ?? '').trim();
        if (method == 'Advance Wallet Deduction') {
          // Still realizes khata; count it as recovery.
        }
        final amount =
            (p[PaymentsTable.amountPaid] as num?)?.toDouble() ?? 0;
        if (amount <= 0) continue;
        final paidAt = DateTime.tryParse(
              p[PaymentsTable.dateTime] as String? ?? '',
            ) ??
            saleDate;
        if (!paidAt.isBefore(start) && !paidAt.isAfter(end)) {
          recovered += marginPerRupee * amount;
        }
      }
      return recovered;
    }

    // Fallback when no payment rows: credit down-payment on sale date.
    if (saleInSeason && paidAmountOnSale > 0) {
      final capped = paidAmountOnSale.clamp(0.0, invoiceAmount);
      return marginPerRupee * capped;
    }
    return 0;
  }

  double _cogsForItems(
    List<Map<String, dynamic>> items,
    Map<String, double> productCosts,
  ) {
    var cogs = 0.0;
    for (final item in items) {
      final name = item[SaleItemsTable.productName] as String? ?? '';
      final qty = (item[SaleItemsTable.quantity] as num?)?.toInt() ?? 0;
      cogs += qty * (productCosts[name] ?? 0);
    }
    return cogs;
  }

  Future<Map<String, double>> _productCostByName() async {
    final products = await _db.getAllProducts();
    return {for (final p in products) p.name: p.costPrice.toDouble()};
  }

  String _fmtDay(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _SeasonWindow {
  final String label;
  final DateTime start;
  final DateTime end;

  const _SeasonWindow({
    required this.label,
    required this.start,
    required this.end,
  });
}

/// Result of [SettlementService.aggregateSeasonProfit].
class SeasonalProfitSummary {
  final String seasonLabel;
  final DateTime start;
  final DateTime end;
  final double totalCashSalesMargin;
  final double totalRecoveredCreditMargin;
  final double totalUnrecoveredCreditMargin;
  final double totalSeasonOverheads;
  final double netDistributableProfit;
  final List<SeasonalPartnerSplit> partnerShares;
  final bool alreadySettled;
  final bool isArchived;

  const SeasonalProfitSummary({
    required this.seasonLabel,
    required this.start,
    required this.end,
    required this.totalCashSalesMargin,
    required this.totalRecoveredCreditMargin,
    required this.totalUnrecoveredCreditMargin,
    required this.totalSeasonOverheads,
    required this.netDistributableProfit,
    required this.partnerShares,
    this.alreadySettled = false,
    this.isArchived = false,
  });

  bool get canSettle =>
      netDistributableProfit > 0.009 && !alreadySettled;
}

class SeasonalPartnerSplit {
  final PartnerModel partner;
  final double equitySharePct;
  final double profitCredit;

  const SeasonalPartnerSplit({
    required this.partner,
    required this.equitySharePct,
    required this.profitCredit,
  });
}
