/// Immutable user footprint stamped once when a transactional row is written.
///
/// Past invoices must keep showing this snapshot even if the user is later
/// renamed, role-changed, or deleted.
class UserFootprint {
  final String createdByUserId;
  final String createdByUserName;
  final DateTime createdAt;

  const UserFootprint({
    required this.createdByUserId,
    required this.createdByUserName,
    required this.createdAt,
  });

  /// Reads footprint columns; falls back to [fallbackCreatedAt] for legacy rows.
  factory UserFootprint.fromMap(
    Map<String, Object?> map, {
    DateTime? fallbackCreatedAt,
  }) {
    final rawCreated = map['created_at'] as String?;
    return UserFootprint(
      createdByUserId: map['created_by_user_id']?.toString() ?? '',
      createdByUserName: map['created_by_user_name'] as String? ?? '',
      createdAt: DateTime.tryParse(rawCreated ?? '') ??
          fallbackCreatedAt ??
          DateTime.now(),
    );
  }

  Map<String, Object?> toMap() => {
        'created_by_user_id': createdByUserId,
        'created_by_user_name': createdByUserName,
        'created_at': createdAt.toIso8601String(),
      };

  bool get isEmpty =>
      createdByUserId.isEmpty && createdByUserName.trim().isEmpty;
}

/// Sale invoice header with a permanent actor footprint.
class SaleModel {
  final String invoiceNumber;
  final DateTime dateTime;
  final double totalPayable;
  final double paidAmount;
  final String paymentMethod;
  final String season;
  final int? zamindarId;
  final int? kisaanId;
  final String createdByUserId;
  final String createdByUserName;
  final DateTime createdAt;

  const SaleModel({
    required this.invoiceNumber,
    required this.dateTime,
    required this.totalPayable,
    required this.paidAmount,
    required this.paymentMethod,
    required this.season,
    this.zamindarId,
    this.kisaanId,
    required this.createdByUserId,
    required this.createdByUserName,
    required this.createdAt,
  });

  factory SaleModel.fromMap(Map<String, Object?> map) {
    final dateRaw = map['date_time'] as String? ?? '';
    final dateTime = DateTime.tryParse(dateRaw) ?? DateTime.now();
    final footprint = UserFootprint.fromMap(map, fallbackCreatedAt: dateTime);
    return SaleModel(
      invoiceNumber: map['invoice_number'] as String? ?? '',
      dateTime: dateTime,
      totalPayable: (map['total_payable'] as num?)?.toDouble() ?? 0,
      paidAmount: (map['paid_amount'] as num?)?.toDouble() ?? 0,
      paymentMethod: map['payment_method'] as String? ?? '',
      season: map['season'] as String? ?? '',
      zamindarId: map['zamindar_id'] as int?,
      kisaanId: map['kisaan_id'] as int?,
      createdByUserId: footprint.createdByUserId,
      createdByUserName: footprint.createdByUserName,
      createdAt: footprint.createdAt,
    );
  }
}

/// Purchase invoice / batch header with a permanent actor footprint.
class PurchaseBatchModel {
  final String invoiceNumber;
  final int wholesalerId;
  final DateTime dateTime;
  final double grandTotal;
  final double amountPaid;
  final String paymentType;
  final String? description;
  final String createdByUserId;
  final String createdByUserName;
  final DateTime createdAt;

  const PurchaseBatchModel({
    required this.invoiceNumber,
    required this.wholesalerId,
    required this.dateTime,
    required this.grandTotal,
    required this.amountPaid,
    required this.paymentType,
    this.description,
    required this.createdByUserId,
    required this.createdByUserName,
    required this.createdAt,
  });

  factory PurchaseBatchModel.fromMap(Map<String, Object?> map) {
    final dateRaw = map['date_time'] as String? ?? '';
    final dateTime = DateTime.tryParse(dateRaw) ?? DateTime.now();
    final footprint = UserFootprint.fromMap(map, fallbackCreatedAt: dateTime);
    return PurchaseBatchModel(
      invoiceNumber: map['invoice_number'] as String? ?? '',
      wholesalerId: map['wholesaler_id'] as int? ?? 0,
      dateTime: dateTime,
      grandTotal: (map['grand_total'] as num?)?.toDouble() ?? 0,
      amountPaid: (map['amount_paid'] as num?)?.toDouble() ?? 0,
      paymentType: map['payment_type'] as String? ?? '',
      description: map['description'] as String?,
      createdByUserId: footprint.createdByUserId,
      createdByUserName: footprint.createdByUserName,
      createdAt: footprint.createdAt,
    );
  }
}
