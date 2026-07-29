import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/models/product_model.dart';

/// Central rules for Cash Advance / Fuel Disbursal checkout lines.
///
/// These are **zero-margin loan reminders** on the Zamindar khaata:
/// - no stock movement
/// - cash-drawer impact = 0
/// - COGS forced equal to sale price (profit = Rs 0)
/// - ledger debit category [advanceLoanRecord]
class SalesService {
  SalesService._();
  static final SalesService instance = SalesService._();

  /// Ledger category written for advance loan / fuel slip debits.
  static const String advanceLoanRecord = 'ADVANCE_LOAN_RECORD';

  /// True when a sales.transaction_type is a khaata loan (cash or fuel).
  bool isAdvanceLoanTransaction(String? transactionType) =>
      SaleTransactionType.isAdvance(transactionType);

  /// True for ledger categories that represent advance loans (incl. legacy).
  bool isAdvanceLoanLedgerCategory(String? category) {
    final c = (category ?? '').toUpperCase();
    return c == advanceLoanRecord ||
        c == SaleTransactionType.cashAdvance ||
        c == SaleTransactionType.dieselAdvance ||
        c == SaleTransactionType.petrolAdvance;
  }

  String serviceKindForTransaction(String? transactionType) =>
      ProductServiceKind.fromSaleTransactionType(transactionType);

  /// Receipt / sale_items line label.
  String lineItemLabel({
    required String transactionType,
    double? fuelQuantityLiters,
  }) {
    final kind = serviceKindForTransaction(transactionType);
    return ProductServiceKind.receiptLabel(
      kind,
      liters: SaleTransactionType.isFuelAdvance(transactionType)
          ? fuelQuantityLiters
          : null,
    );
  }

  /// Ledger description stored on the DEBIT row.
  String ledgerDescription({
    required String transactionType,
    String? remarks,
    double? fuelQuantityLiters,
  }) {
    final base = lineItemLabel(
      transactionType: transactionType,
      fuelQuantityLiters: fuelQuantityLiters,
    );
    final note = remarks?.trim() ?? '';
    if (note.isEmpty) return base;
    return '$base: $note';
  }

  /// Always 0 for advance loans — never add/deduct counter cash.
  double cashDrawerImpact({
    required String transactionType,
    required double amount,
  }) {
    return ProductServiceKind.cashDrawerImpact(
      kind: serviceKindForTransaction(transactionType),
      amount: amount,
    );
  }

  /// COGS equals sale amount → Rs 0 margin for partner / seasonal splits.
  double cogsForAdvanceLoan(double saleAmount) => saleAmount;

  double marginForLine({
    required String? transactionType,
    required double saleAmount,
    required double catalogCost,
  }) {
    return ProductServiceKind.profitMargin(
      kind: serviceKindForTransaction(transactionType),
      saleAmount: saleAmount,
      catalogCost: catalogCost,
    );
  }

  bool adjustsStock(String? transactionType) =>
      ProductServiceKind.adjustsStock(
        serviceKindForTransaction(transactionType),
      );

  /// Human type chip for dashboard / mini-tables: Cash vs Fuel.
  String advanceTypeChip(String? transactionType) {
    if (SaleTransactionType.isFuelAdvance(transactionType)) return 'Fuel';
    if (transactionType == SaleTransactionType.cashAdvance) return 'Cash';
    return 'Advance';
  }
}
