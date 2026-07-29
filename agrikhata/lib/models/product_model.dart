/// Product / service kinds used at checkout and in profit calculations.
///
/// Cash advances and fuel slips are **non-stock, zero-margin loan records** —
/// they hit the Zamindar/Kisaan khaata as receivables without moving inventory
/// or contributing to partner profit / cash-drawer totals.
library;

/// Service categories for special line items (not ordinary inventory SKUs).
class ProductServiceKind {
  ProductServiceKind._();

  /// Cash loan recorded on khaata (legacy TX: [CASH_ADVANCE]).
  static const String cashAdvance = 'CASH_ADVANCE';

  /// Fuel slip recorded on khaata (legacy TX: DIESEL/PETROL_ADVANCE).
  static const String fuelDisbursal = 'FUEL_DISBURSAL';

  /// Ordinary inventoriable product sale.
  static const String inventory = 'INVENTORY';

  static const Set<String> zeroMarginLoanKinds = {
    cashAdvance,
    fuelDisbursal,
  };

  static bool isZeroMarginLoan(String? kind) =>
      kind != null && zeroMarginLoanKinds.contains(kind);

  /// Advances never consume warehouse stock.
  static bool adjustsStock(String? kind) => !isZeroMarginLoan(kind);

  /// Advances never move counter cash (in or out).
  static double cashDrawerImpact({
    required String? kind,
    required double amount,
  }) {
    if (isZeroMarginLoan(kind)) return 0;
    return amount;
  }

  /// Force COGS = sale price so margin is exactly Rs 0.
  static double effectiveCogs({
    required String? kind,
    required double saleAmount,
    required double catalogCost,
  }) {
    if (isZeroMarginLoan(kind)) return saleAmount;
    return catalogCost;
  }

  static double profitMargin({
    required String? kind,
    required double saleAmount,
    required double catalogCost,
  }) {
    final cogs = effectiveCogs(
      kind: kind,
      saleAmount: saleAmount,
      catalogCost: catalogCost,
    );
    return saleAmount - cogs;
  }

  /// Maps sales.transaction_type → service kind.
  static String fromSaleTransactionType(String? transactionType) {
    switch (transactionType) {
      case 'CASH_ADVANCE':
        return cashAdvance;
      case 'DIESEL_ADVANCE':
      case 'PETROL_ADVANCE':
        return fuelDisbursal;
      default:
        return inventory;
    }
  }

  /// Print / receipt line label for khaata loan records.
  static String receiptLabel(String? kind, {double? liters}) {
    if (kind == fuelDisbursal) {
      if (liters != null && liters > 0) {
        final lit = liters == liters.roundToDouble()
            ? liters.toStringAsFixed(0)
            : liters
                .toStringAsFixed(2)
                .replaceFirst(RegExp(r'0+$'), '')
                .replaceFirst(RegExp(r'\.$'), '');
        return 'Fuel Slip (Khaata Record) ($lit L)';
      }
      return 'Fuel Slip (Khaata Record)';
    }
    if (kind == cashAdvance) {
      return 'Advance Loan (Khaata Record)';
    }
    return 'Product Sale';
  }
}
