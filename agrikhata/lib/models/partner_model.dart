/// Equity partner linked optionally to a shop login and/or Zamindar khata.
class PartnerModel {
  final String id;
  final String name;
  final String phone;
  final String? userAccountId;
  final String? zamindarId;
  final double initialCapital;
  final double reinvestedProfit;
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
    this.reinvestedProfit = 0,
    this.activeDrawings = 0,
    this.isActive = true,
    required this.createdAt,
  });

  double get equity => initialCapital + reinvestedProfit;

  PartnerModel copyWith({
    String? id,
    String? name,
    String? phone,
    String? userAccountId,
    bool clearUserAccountId = false,
    String? zamindarId,
    bool clearZamindarId = false,
    double? initialCapital,
    double? reinvestedProfit,
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
      reinvestedProfit: reinvestedProfit ?? this.reinvestedProfit,
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
        'reinvested_profit': reinvestedProfit,
        'active_drawings': activeDrawings,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory PartnerModel.fromMap(Map<String, Object?> map) {
    final rawId = map['id'];
    final rawCreated = map['created_at'] as String? ?? '';
    return PartnerModel(
      id: rawId?.toString() ?? '',
      name: map['name'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      userAccountId: map['user_account_id'] as String?,
      zamindarId: map['zamindar_id']?.toString(),
      initialCapital: (map['initial_capital'] as num?)?.toDouble() ?? 0,
      reinvestedProfit: (map['reinvested_profit'] as num?)?.toDouble() ?? 0,
      activeDrawings: (map['active_drawings'] as num?)?.toDouble() ?? 0,
      isActive: (map['is_active'] as int?) != 0,
      createdAt: DateTime.tryParse(rawCreated) ?? DateTime.now(),
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

  /// Permanent actor snapshot at insert time (never look up live users).
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

/// Drawing type constants.
class PartnerDrawingType {
  static const String taken = 'TAKEN';
  static const String returned = 'RETURNED';
}

/// Result of a seasonal profit settlement for one partner.
class PartnerSettlementShare {
  final PartnerModel partner;
  final double equitySharePct;
  final double profitCredit;
  final double zamindarDebtOffset;
  final double netReinvestedCredit;

  const PartnerSettlementShare({
    required this.partner,
    required this.equitySharePct,
    required this.profitCredit,
    required this.zamindarDebtOffset,
    required this.netReinvestedCredit,
  });
}
