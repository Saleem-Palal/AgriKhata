/// Equity partner linked optionally to a shop login and/or Zamindar khata.
class PartnerModel {
  final String id;
  final String name;
  final String phone;
  final String? userAccountId;
  final String? zamindarId;
  final double initialCapital;
  final double outOfPocketInjections;
  final double reinvestedProfit;
  final double totalDrawings;
  final double permanentCapitalWithdrawals;
  final double unsettledProfit;
  /// Pending counter-cash debt still awaiting settlement (legacy + UI KPI).
  final double activeDrawings;
  final bool isActive;
  final DateTime createdAt;

  const PartnerModel({
    required this.id,
    required this.name,
    this.phone = '',
    this.userAccountId,
    this.zamindarId,
    this.initialCapital = 0,
    this.outOfPocketInjections = 0,
    this.reinvestedProfit = 0,
    this.totalDrawings = 0,
    this.permanentCapitalWithdrawals = 0,
    this.unsettledProfit = 0,
    this.activeDrawings = 0,
    this.isActive = true,
    required this.createdAt,
  });

  /// Permanent business equity (excludes unsettled profit pool).
  double get totalEquity =>
      (initialCapital + outOfPocketInjections + reinvestedProfit) -
      permanentCapitalWithdrawals;

  /// Legacy alias used by older call sites.
  double get equity => totalEquity;

  double equityPercentage(double totalBusinessEquity) {
    if (totalBusinessEquity <= 0) return 0;
    return (totalEquity / totalBusinessEquity) * 100;
  }

  PartnerModel copyWith({
    String? id,
    String? name,
    String? phone,
    String? userAccountId,
    bool clearUserAccountId = false,
    String? zamindarId,
    bool clearZamindarId = false,
    double? initialCapital,
    double? outOfPocketInjections,
    double? reinvestedProfit,
    double? totalDrawings,
    double? permanentCapitalWithdrawals,
    double? unsettledProfit,
    double? activeDrawings,
    bool? isActive,
    DateTime? createdAt,
  }) {
    return PartnerModel(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      userAccountId:
          clearUserAccountId ? null : (userAccountId ?? this.userAccountId),
      zamindarId: clearZamindarId ? null : (zamindarId ?? this.zamindarId),
      initialCapital: initialCapital ?? this.initialCapital,
      outOfPocketInjections:
          outOfPocketInjections ?? this.outOfPocketInjections,
      reinvestedProfit: reinvestedProfit ?? this.reinvestedProfit,
      totalDrawings: totalDrawings ?? this.totalDrawings,
      permanentCapitalWithdrawals:
          permanentCapitalWithdrawals ?? this.permanentCapitalWithdrawals,
      unsettledProfit: unsettledProfit ?? this.unsettledProfit,
      activeDrawings: activeDrawings ?? this.activeDrawings,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() => {
        if (id.isNotEmpty) 'id': int.tryParse(id),
        'name': name,
        'phone': phone,
        'user_account_id': userAccountId,
        'zamindar_id': zamindarId == null ? null : int.tryParse(zamindarId!),
        'initial_capital': initialCapital,
        'out_of_pocket_injections': outOfPocketInjections,
        'reinvested_profit': reinvestedProfit,
        'total_drawings': totalDrawings,
        'permanent_capital_withdrawals': permanentCapitalWithdrawals,
        'unsettled_profit': unsettledProfit,
        'active_drawings': activeDrawings,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory PartnerModel.fromMap(Map<String, Object?> map) {
    final rawId = map['id'];
    final rawCreated = map['created_at'] as String? ?? '';
    final active = (map['active_drawings'] as num?)?.toDouble() ?? 0;
    final totalDraw =
        (map['total_drawings'] as num?)?.toDouble() ?? active;
    return PartnerModel(
      id: rawId?.toString() ?? '',
      name: map['name'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      userAccountId: map['user_account_id'] as String?,
      zamindarId: map['zamindar_id']?.toString(),
      initialCapital: (map['initial_capital'] as num?)?.toDouble() ?? 0,
      outOfPocketInjections:
          (map['out_of_pocket_injections'] as num?)?.toDouble() ?? 0,
      reinvestedProfit: (map['reinvested_profit'] as num?)?.toDouble() ?? 0,
      totalDrawings: totalDraw,
      permanentCapitalWithdrawals:
          (map['permanent_capital_withdrawals'] as num?)?.toDouble() ?? 0,
      unsettledProfit: (map['unsettled_profit'] as num?)?.toDouble() ?? 0,
      activeDrawings: active,
      isActive: (map['is_active'] as int?) != 0,
      createdAt: DateTime.tryParse(rawCreated) ?? DateTime.now(),
    );
  }
}

/// Partner ledger transaction type codes.
class PartnerTransactionType {
  static const String capitalInjection = 'CAPITAL_INJECTION';
  static const String profitReinvestment = 'PROFIT_REINVESTMENT';
  static const String cashDrawing = 'CASH_DRAWING';
  static const String overheadShare = 'OVERHEAD_SHARE';
  static const String seasonalSettlement = 'SEASONAL_SETTLEMENT';

  static const List<String> all = [
    capitalInjection,
    profitReinvestment,
    cashDrawing,
    overheadShare,
    seasonalSettlement,
  ];
}

/// Payment channel for out-of-pocket capital injections.
class PartnerCapitalPaymentSource {
  static const String directSupplierPayment = 'Direct Supplier Payment';
  static const String shopCounterCashDeposit = 'Shop Counter Cash Deposit';
  static const String shopBankAccountDeposit = 'Shop Bank Account Deposit';

  static const List<String> all = [
    directSupplierPayment,
    shopCounterCashDeposit,
    shopBankAccountDeposit,
  ];
}

/// Unified partner equity ledger entry.
class PartnerTransactionModel {
  final String id;
  final String partnerId;
  final String type;
  final double amount;
  final DateTime date;
  final String? paymentChannel;
  final String? reference;
  final String? notes;
  final String? seasonLabel;
  final double? equityPctBefore;
  final double? equityPctAfter;
  final String? invoiceNumber;
  final String createdByUserId;
  final String createdByUserName;
  final DateTime createdAt;

  const PartnerTransactionModel({
    required this.id,
    required this.partnerId,
    required this.type,
    required this.amount,
    required this.date,
    this.paymentChannel,
    this.reference,
    this.notes,
    this.seasonLabel,
    this.equityPctBefore,
    this.equityPctAfter,
    this.invoiceNumber,
    this.createdByUserId = '',
    this.createdByUserName = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? date;

  factory PartnerTransactionModel.fromMap(Map<String, Object?> map) {
    final rawDate = map['date'] as String? ?? '';
    final date = DateTime.tryParse(rawDate) ?? DateTime.now();
    final rawCreated = map['created_at'] as String?;
    return PartnerTransactionModel(
      id: map['id']?.toString() ?? '',
      partnerId: map['partner_id']?.toString() ?? '',
      type: map['type'] as String? ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      date: date,
      paymentChannel: map['payment_channel'] as String?,
      reference: map['reference'] as String?,
      notes: map['notes'] as String?,
      seasonLabel: map['season_label'] as String?,
      equityPctBefore: (map['equity_pct_before'] as num?)?.toDouble(),
      equityPctAfter: (map['equity_pct_after'] as num?)?.toDouble(),
      invoiceNumber: map['invoice_number'] as String?,
      createdByUserId: map['created_by_user_id']?.toString() ?? '',
      createdByUserName: map['created_by_user_name'] as String? ?? '',
      createdAt: DateTime.tryParse(rawCreated ?? '') ?? date,
    );
  }
}

/// Cash drawing log for a partner (`TAKEN` increases debt, `RETURNED` reduces it).
class PartnerDrawingModel {
  final String id;
  final String partnerId;
  final double amount;
  final String type; // TAKEN | RETURNED
  final DateTime date;
  final String? notes;
  final bool isSettled;
  final String createdByUserId;
  final String createdByUserName;
  final DateTime createdAt;

  const PartnerDrawingModel({
    required this.id,
    required this.partnerId,
    required this.amount,
    required this.type,
    required this.date,
    this.notes,
    this.isSettled = false,
    this.createdByUserId = '',
    this.createdByUserName = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? date;

  bool get isTaken => type.toUpperCase() == 'TAKEN';
  bool get isReturned => type.toUpperCase() == 'RETURNED';

  PartnerDrawingModel copyWith({
    String? id,
    String? partnerId,
    double? amount,
    String? type,
    DateTime? date,
    String? notes,
    bool? isSettled,
    String? createdByUserId,
    String? createdByUserName,
    DateTime? createdAt,
  }) {
    return PartnerDrawingModel(
      id: id ?? this.id,
      partnerId: partnerId ?? this.partnerId,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      date: date ?? this.date,
      notes: notes ?? this.notes,
      isSettled: isSettled ?? this.isSettled,
      createdByUserId: createdByUserId ?? this.createdByUserId,
      createdByUserName: createdByUserName ?? this.createdByUserName,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() => {
        if (id.isNotEmpty) 'id': int.tryParse(id),
        'partner_id': int.tryParse(partnerId) ?? partnerId,
        'amount': amount,
        'type': type.toUpperCase(),
        'date': date.toIso8601String(),
        'notes': notes,
        'is_settled': isSettled ? 1 : 0,
        'created_by_user_id': createdByUserId,
        'created_by_user_name': createdByUserName,
        'created_at': createdAt.toIso8601String(),
      };

  factory PartnerDrawingModel.fromMap(Map<String, Object?> map) {
    final rawDate = map['date'] as String? ?? '';
    final date = DateTime.tryParse(rawDate) ?? DateTime.now();
    final rawCreated = map['created_at'] as String?;
    return PartnerDrawingModel(
      id: map['id']?.toString() ?? '',
      partnerId: map['partner_id']?.toString() ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      type: (map['type'] as String? ?? 'TAKEN').toUpperCase(),
      date: date,
      notes: map['notes'] as String?,
      isSettled: (map['is_settled'] as int?) == 1,
      createdByUserId: map['created_by_user_id']?.toString() ?? '',
      createdByUserName: map['created_by_user_name'] as String? ?? '',
      createdAt: DateTime.tryParse(rawCreated ?? '') ?? date,
    );
  }
}

class PartnerDrawingType {
  static const String taken = 'TAKEN';
  static const String returned = 'RETURNED';
}

class PartnerSettlementShare {
  final PartnerModel partner;
  final double equitySharePct;
  final double profitCredit;
  final double zamindarDebtOffset;
  final double netUnsettledCredit;

  const PartnerSettlementShare({
    required this.partner,
    required this.equitySharePct,
    required this.profitCredit,
    required this.zamindarDebtOffset,
    required this.netUnsettledCredit,
  });
}

/// Live invoice margin row for the Invoice Profit Margin Splits tab.
class InvoiceMarginSplitRow {
  final String invoiceNumber;
  final DateTime date;
  final String customerName;
  final double invoiceAmount;
  final double cogs;
  final double netMargin;
  final Map<String, double> shareByPartnerId;
  final Map<String, double> equityPctByPartnerId;
  final List<Map<String, dynamic>> items;

  const InvoiceMarginSplitRow({
    required this.invoiceNumber,
    required this.date,
    required this.customerName,
    required this.invoiceAmount,
    required this.cogs,
    required this.netMargin,
    required this.shareByPartnerId,
    required this.equityPctByPartnerId,
    required this.items,
  });
}
