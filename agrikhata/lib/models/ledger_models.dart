/// Data models for Ledger screen
library;

enum LedgerType {
  sales,
  purchases;

  String get displayName {
    switch (this) {
      case LedgerType.sales:
        return 'Sales Ledger';
      case LedgerType.purchases:
        return 'Purchases Ledger';
    }
  }
}

enum PaymentStatus {
  paid,
  partial,
  unpaid;

  String get displayName {
    switch (this) {
      case PaymentStatus.paid:
        return 'Paid';
      case PaymentStatus.partial:
        return 'Partial';
      case PaymentStatus.unpaid:
        return 'Unpaid Credit';
    }
  }

  String get statusLabel {
    switch (this) {
      case PaymentStatus.paid:
        return 'Paid';
      case PaymentStatus.partial:
        return 'Partial: ';
      case PaymentStatus.unpaid:
        return 'Unpaid Credit';
    }
  }
}

class Season {
  final String name;
  final int year;
  final DateTime startDate;
  final DateTime endDate;

  Season({
    required this.name,
    required this.year,
    required this.startDate,
    required this.endDate,
  });

  static final Season all = Season(
    name: 'All Seasons',
    year: 0,
    startDate: DateTime(2000),
    endDate: DateTime(2100, 12, 31, 23, 59, 59),
  );

  bool get isAllSeasons => name == 'All Seasons';

  String get displayName => isAllSeasons ? 'All Seasons' : '$name $year';

  bool containsDate(DateTime date) {
    if (isAllSeasons) return true;
    return date.isAfter(startDate.subtract(const Duration(days: 1))) &&
        date.isBefore(endDate.add(const Duration(days: 1)));
  }

  @override
  String toString() => displayName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Season &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          year == other.year;

  @override
  int get hashCode => name.hashCode ^ year.hashCode;
}

class LedgerEntry {
  final int id;
  final String invoiceNumber;
  final DateTime date;
  final String stakeholderName;
  final String? kisaanName;
  final List<LineItem> items;
  final double total;
  final double paid;
  final PaymentStatus status;
  final String season;
  final bool isWalkInCustomer;

  /// Purchase payment terms label: Cash / Udhaar / Partial (purchases only).
  final String? purchaseTerms;

  /// Invoice-level summary (purchases / cash advances).
  final String? description;

  /// Sales `transaction_type` (e.g. PRODUCT_SALE, CASH_ADVANCE).
  final String? transactionType;

  /// Invoice-level base (gross) before seasonal / discounts (sales only).
  /// Equals `sum(qty * unit_price)` — does not include seasonal increment.
  final double? grossSubtotal;

  /// Invoice-level seasonal increment total: `sum(qty * seasonal_inc_per_unit)`.
  final double? seasonalIncrementTotal;

  /// Invoice-level item discounts total: `sum(qty * discount_per_unit)`.
  final double? itemDiscountsTotal;

  /// Invoice-level overall discount (sales only).
  final double? overallDiscount;

  /// Permanent actor snapshot from the invoice row (never a live user lookup).
  final String? createdByUserId;
  final String? createdByUserName;
  final DateTime? createdAt;

  LedgerEntry({
    required this.id,
    required this.invoiceNumber,
    required this.date,
    required this.stakeholderName,
    this.kisaanName,
    required this.items,
    required this.total,
    required this.paid,
    required this.status,
    required this.season,
    this.isWalkInCustomer = false,
    this.purchaseTerms,
    this.description,
    this.transactionType,
    this.grossSubtotal,
    this.seasonalIncrementTotal,
    this.itemDiscountsTotal,
    this.overallDiscount,
    this.createdByUserId,
    this.createdByUserName,
    this.createdAt,
  });

  bool get isCashAdvance => transactionType == 'CASH_ADVANCE';
  bool get isAdvance =>
      transactionType == 'CASH_ADVANCE' ||
      transactionType == 'DIESEL_ADVANCE' ||
      transactionType == 'PETROL_ADVANCE';

  bool get isProductSale =>
      transactionType == null || transactionType == 'PRODUCT_SALE';

  bool get hasSaleDiscountBreakdown =>
      isProductSale &&
      (grossSubtotal != null ||
          (seasonalIncrementTotal ?? 0) > 0 ||
          (itemDiscountsTotal ?? 0) > 0 ||
          (overallDiscount ?? 0) > 0);

  bool get hasVisibleDiscounts =>
      (itemDiscountsTotal ?? 0) > 0 || (overallDiscount ?? 0) > 0;

  bool get hasVisiblePricingAdjustments =>
      (seasonalIncrementTotal ?? 0) > 0 || hasVisibleDiscounts;

  /// Base + seasonal (pre-discount merchandise total).
  double get preDiscountTotal =>
      (grossSubtotal ?? 0) + (seasonalIncrementTotal ?? 0);

  double get netPayable => total;

  double get outstanding => total - paid;

  String get itemsSummary {
    if (items.isEmpty) return 'No items';
    return items
        .map((item) {
          final qtyStr = item.quantity % 1 == 0
              ? item.quantity.toInt().toString()
              : item.quantity.toString();
          return '${item.productName} x$qtyStr';
        })
        .join(', ');
  }

  /// User-entered invoice remarks / notes (sales, advances, purchases).
  String get invoiceDescriptionText {
    final d = description?.trim();
    if (d != null && d.isNotEmpty) return d;
    return '—';
  }

  /// Prefers invoice description when set; otherwise line-item summary.
  String get ledgerSummary {
    final d = description?.trim();
    if (d != null && d.isNotEmpty) return d;
    return itemsSummary;
  }
}

class LineItem {
  final String productName;
  final double quantity;
  final String unit;
  final double unitPrice;

  /// Per-unit seasonal increment.
  final double seasonalIncrement;

  /// Per-unit discount.
  final double discount;

  LineItem({
    required this.productName,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    this.seasonalIncrement = 0,
    this.discount = 0,
  });

  double get effectiveUnitPrice => unitPrice + seasonalIncrement - discount;
  double get subtotal => effectiveUnitPrice * quantity;
  double get totalItemDiscount => discount * quantity;
  double get totalItemSeasonalInc => seasonalIncrement * quantity;

  /// Net line total (discount already applied in [subtotal]).
  double get total => subtotal;
}

class LedgerSummary {
  final double totalVolume;
  final double totalCashReceived;
  final double outstandingCredit;

  /// Σ base sales (`sum(qty * unit_price)`).
  final double grossSales;

  /// Σ seasonal increments applied.
  final double totalSeasonalIncrements;

  /// Σ item discounts + overall discounts.
  final double totalDiscountsGiven;

  LedgerSummary({
    required this.totalVolume,
    required this.totalCashReceived,
    required this.outstandingCredit,
    this.grossSales = 0,
    this.totalSeasonalIncrements = 0,
    this.totalDiscountsGiven = 0,
  });

  factory LedgerSummary.fromEntries(List<LedgerEntry> entries) {
    double totalVolume = 0;
    double totalCashReceived = 0;
    double outstandingCredit = 0;
    double grossSales = 0;
    double totalSeasonalIncrements = 0;
    double totalDiscountsGiven = 0;

    for (final entry in entries) {
      totalVolume += entry.total;
      totalCashReceived += entry.paid;
      outstandingCredit += entry.outstanding;
      if (entry.isProductSale) {
        grossSales += entry.grossSubtotal ?? 0;
        totalSeasonalIncrements += entry.seasonalIncrementTotal ?? 0;
        totalDiscountsGiven +=
            (entry.itemDiscountsTotal ?? 0) + (entry.overallDiscount ?? 0);
      }
    }

    return LedgerSummary(
      totalVolume: totalVolume,
      totalCashReceived: totalCashReceived,
      outstandingCredit: outstandingCredit,
      grossSales: grossSales,
      totalSeasonalIncrements: totalSeasonalIncrements,
      totalDiscountsGiven: totalDiscountsGiven,
    );
  }

  static LedgerSummary empty() =>
      LedgerSummary(totalVolume: 0, totalCashReceived: 0, outstandingCredit: 0);
}

class PaymentLedgerEntry {
  final String paymentId;
  final String? invoiceNumber;
  final DateTime date;
  final String zamindarName;
  final String? kisaanName;
  final double amountPaid;
  final String paymentMethod;
  final String season;
  final String itemsSummary;
  final DateTime? editedAt;
  final String? editedBy;
  final double? originalAmount;
  final String? notes;

  PaymentLedgerEntry({
    required this.paymentId,
    this.invoiceNumber,
    required this.date,
    required this.zamindarName,
    this.kisaanName,
    required this.amountPaid,
    required this.paymentMethod,
    required this.season,
    this.itemsSummary = '',
    this.editedAt,
    this.editedBy,
    this.originalAmount,
    this.notes,
  });

  bool get isAdvanceCollection => invoiceNumber == null;
  bool get isWalletDeduction => paymentMethod == 'Advance Wallet Deduction';
  bool get isAdvanceSummary => itemsSummary == 'N/A (Advance Collection)';
  bool get isEdited => editedAt != null;

  /// Label for wallet drawdowns: `Advance payments deducted for (Products)`.
  static String formatAdvanceDeductionSummary(String? products) {
    final trimmed = (products ?? '').trim();
    if (trimmed.startsWith('Advance payments deducted')) {
      return trimmed;
    }
    final isGeneric =
        trimmed.isEmpty ||
        trimmed == '—' ||
        trimmed == 'N/A (Advance Collection)' ||
        trimmed.toLowerCase() == 'advance wallet deduction';
    if (isGeneric) return 'Advance payments deducted';
    return 'Advance payments deducted for ($trimmed)';
  }

  factory PaymentLedgerEntry.fromMap(Map<String, dynamic> map) {
    final method = map['payment_method'] as String;
    var summary = map['items_summary'] as String? ?? '';
    if (method == 'Advance Wallet Deduction') {
      summary = formatAdvanceDeductionSummary(summary);
    }
    final editedRaw = map['edited_at'] as String?;
    return PaymentLedgerEntry(
      paymentId: map['payment_id'] as String,
      invoiceNumber: map['invoice_number'] as String?,
      date: DateTime.parse(map['date_time'] as String),
      // Names come from SQL JOINs (not denormalized payment columns).
      zamindarName: (map['zamindar_name'] as String?) ?? '',
      kisaanName: map['kisaan_name'] as String?,
      amountPaid: (map['amount_paid'] as num).toDouble(),
      paymentMethod: method,
      season: map['season'] as String,
      itemsSummary: summary,
      editedAt: editedRaw != null && editedRaw.isNotEmpty
          ? DateTime.tryParse(editedRaw)
          : null,
      editedBy: map['edited_by'] as String?,
      originalAmount: (map['original_amount'] as num?)?.toDouble(),
      notes: map['notes'] as String?,
    );
  }
}

class PaymentSummary {
  final double totalPaymentsReceived;
  final double totalAdvanceCollected;
  final double totalWalletDeductions;

  PaymentSummary({
    required this.totalPaymentsReceived,
    required this.totalAdvanceCollected,
    required this.totalWalletDeductions,
  });

  factory PaymentSummary.fromEntries(List<PaymentLedgerEntry> entries) {
    double total = 0;
    double advance = 0;
    double wallet = 0;

    for (final entry in entries) {
      if (entry.isWalletDeduction) {
        wallet += entry.amountPaid;
        continue;
      }
      total += entry.amountPaid;
      if (entry.isAdvanceCollection) {
        advance += entry.amountPaid;
      }
    }

    return PaymentSummary(
      totalPaymentsReceived: total,
      totalAdvanceCollected: advance,
      totalWalletDeductions: wallet,
    );
  }

  static PaymentSummary empty() => PaymentSummary(
    totalPaymentsReceived: 0,
    totalAdvanceCollected: 0,
    totalWalletDeductions: 0,
  );
}

class BillSettlementInvoiceSummary {
  final String invoiceNumber;
  final double cashPaidNow;
  final double totalPaidCash;
  final double remainingBalance;
  final double invoiceTotal;

  const BillSettlementInvoiceSummary({
    required this.invoiceNumber,
    required this.cashPaidNow,
    required this.totalPaidCash,
    required this.remainingBalance,
    required this.invoiceTotal,
  });
}

class BillSettlementResult {
  final int zamindarId;
  final String zamindarName;
  final int? kisaanId;
  final String kisaanName;
  final double amountPaid;
  final double walletDeductionAmount;
  final double cashReceivedAmount;
  final String? remarks;
  final List<String> invoiceNumbers;
  final String? paymentId;
  final DateTime dateTime;
  final String description;
  final String paymentMethod;
  final List<BillSettlementInvoiceSummary> invoiceSummaries;

  const BillSettlementResult({
    required this.zamindarId,
    required this.zamindarName,
    this.kisaanId,
    required this.kisaanName,
    required this.amountPaid,
    this.walletDeductionAmount = 0,
    double? cashReceivedAmount,
    this.remarks,
    required this.invoiceNumbers,
    this.paymentId,
    required this.dateTime,
    required this.description,
    required this.paymentMethod,
    required this.invoiceSummaries,
  }) : cashReceivedAmount =
           cashReceivedAmount ?? (amountPaid - walletDeductionAmount);
}
