import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/models/partner_model.dart';

/// Equity math + partner orchestration helpers.
///
/// Overhead expenses (rent, electricity, salaries) are always split equally
/// among active partners — independent of equity percentage.
class PartnerService {
  PartnerService._();
  static final PartnerService instance = PartnerService._();

  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Categories treated as store overheads for the 50-50 (equal) split ledger.
  static const Set<String> overheadCategories = {
    'Shop Rent',
    'Electricity / Utilities',
    'Employee Salaries',
    'Helper Salary',
  };

  // ── Equity calculations ────────────────────────────────────────────────

  double totalBusinessCapital(List<PartnerModel> partners) {
    return partners
        .where((p) => p.isActive)
        .fold<double>(0, (sum, p) => sum + partnerEquity(p));
  }

  double partnerEquity(PartnerModel partner) =>
      partner.initialCapital + partner.reinvestedProfit;

  double partnerEquitySharePct(
    PartnerModel partner,
    List<PartnerModel> partners,
  ) {
    final total = totalBusinessCapital(partners);
    if (total <= 0) return 0;
    return (partnerEquity(partner) / total) * 100;
  }

  double totalActiveDrawings(List<PartnerModel> partners) {
    return partners
        .where((p) => p.isActive)
        .fold<double>(0, (sum, p) => sum + p.activeDrawings);
  }

  /// Equal overhead share for each active partner (50-50 when N=2).
  double overheadSharePerPartner(double amount, int activePartnerCount) {
    if (activePartnerCount <= 0 || amount <= 0) return 0;
    return amount / activePartnerCount;
  }

  bool isOverheadCategory(String category) =>
      overheadCategories.contains(category.trim());

  // ── Persistence facades ────────────────────────────────────────────────

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

  Future<PartnerModel> addPartner({
    required String name,
    required String phone,
    required double initialCapital,
    String? userAccountId,
    String? zamindarId,
    DateTime? createdAt,
  }) {
    return _db.insertPartner(
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
  }

  Future<PartnerModel> updatePartner(PartnerModel partner) =>
      _db.updatePartner(partner);

  Future<PartnerDrawingModel> recordDrawing({
    required String partnerId,
    required double amount,
    required String type,
    String? notes,
    DateTime? date,
  }) {
    return _db.recordPartnerDrawing(
      partnerId: partnerId,
      amount: amount,
      type: type,
      notes: notes,
      date: date,
    );
  }

  Future<void> settleDrawing(String drawingId) =>
      _db.settlePartnerDrawing(drawingId);

  Future<List<PartnerDrawingModel>> getDrawings({String? partnerId}) =>
      _db.getPartnerDrawings(partnerId: partnerId);

  /// Distributes [netProfit] by current equity ratio into each partner's
  /// `reinvestedProfit`, offsetting linked Zamindar crop debt first.
  Future<List<PartnerSettlementShare>> runSeasonalSettlement({
    required double netProfit,
    required String seasonLabel,
    DateTime? settledAt,
  }) async {
    // Timestamp retained for callers / future settlement audit trail.
    settledAt ??= DateTime.now();
    if (netProfit <= 0) {
      throw ArgumentError('Net profit must be greater than zero');
    }

    final partners = await getActivePartners();
    if (partners.isEmpty) {
      throw StateError('No active partners to settle');
    }

    final total = totalBusinessCapital(partners);
    if (total <= 0) {
      throw StateError('Total business capital is zero — add capital first');
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
      final reinvestAdd = netCredit - drawingsClear;

      final updated = partner.copyWith(
        reinvestedProfit: partner.reinvestedProfit + reinvestAdd,
        activeDrawings: partner.activeDrawings - drawingsClear,
      );
      await _db.updatePartner(updated);

      shares.add(
        PartnerSettlementShare(
          partner: updated,
          equitySharePct: pct,
          profitCredit: profitCredit,
          zamindarDebtOffset: debtOffset,
          netReinvestedCredit: reinvestAdd,
        ),
      );
    }

    // Log settlement note as a zero-amount drawing marker is unnecessary;
    // season label is retained by the caller UI toast.
    return shares;
  }

  /// Builds equal-split rows for overhead expenses in the current month.
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
        shareByPartnerId: {
          for (final p in partners) p.id: per,
        },
        partners: partners,
      );
    }).toList();
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
