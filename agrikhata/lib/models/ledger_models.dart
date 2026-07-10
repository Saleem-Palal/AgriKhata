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

  String get displayName => '$name $year';

  bool containsDate(DateTime date) {
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
  });

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
}

class LineItem {
  final String productName;
  final double quantity;
  final String unit;
  final double unitPrice;
  final double seasonalIncrement;
  final double discount;

  LineItem({
    required this.productName,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    this.seasonalIncrement = 0,
    this.discount = 0,
  });

  double get effectiveUnitPrice => unitPrice + seasonalIncrement;
  double get subtotal => effectiveUnitPrice * quantity;
  double get total => subtotal - discount;
}

class LedgerSummary {
  final double totalVolume;
  final double totalCashReceived;
  final double outstandingCredit;

  LedgerSummary({
    required this.totalVolume,
    required this.totalCashReceived,
    required this.outstandingCredit,
  });

  factory LedgerSummary.fromEntries(List<LedgerEntry> entries) {
    double totalVolume = 0;
    double totalCashReceived = 0;
    double outstandingCredit = 0;

    for (final entry in entries) {
      totalVolume += entry.total;
      totalCashReceived += entry.paid;
      outstandingCredit += entry.outstanding;
    }

    return LedgerSummary(
      totalVolume: totalVolume,
      totalCashReceived: totalCashReceived,
      outstandingCredit: outstandingCredit,
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

  PaymentLedgerEntry({
    required this.paymentId,
    this.invoiceNumber,
    required this.date,
    required this.zamindarName,
    this.kisaanName,
    required this.amountPaid,
    required this.paymentMethod,
    required this.season,
  });

  bool get isAdvanceCollection => invoiceNumber == null;
  bool get isWalletDeduction => paymentMethod == 'Advance Wallet Deduction';

  factory PaymentLedgerEntry.fromMap(Map<String, dynamic> map) {
    return PaymentLedgerEntry(
      paymentId: map['payment_id'] as String,
      invoiceNumber: map['invoice_number'] as String?,
      date: DateTime.parse(map['date_time'] as String),
      zamindarName: map['zamindar_name'] as String,
      kisaanName: map['kisaan_name'] as String?,
      amountPaid: (map['amount_paid'] as num).toDouble(),
      paymentMethod: map['payment_method'] as String,
      season: map['season'] as String,
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
