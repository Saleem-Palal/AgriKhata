import '../models/product_model.dart';
import '../models/sale_models.dart';

/// Shared POS cart / money helpers for the New Sale checkout screen.
///
/// Keeps line-item identity, rounding, and payment-mode side effects out of
/// the widget tree so cart mutations stay targeted and totals stay accurate.
class SaleController {
  SaleController();

  int _cartIdSeq = 0;

  /// Unique per line — never keyed by [Product.id] (that collapses duplicates).
  String nextCartItemId() {
    _cartIdSeq += 1;
    return 'c${DateTime.now().microsecondsSinceEpoch}_$_cartIdSeq';
  }

  /// Standard financial double rounding to 2 decimal places (paisa).
  static double moneyRound(double value) {
    if (value.isNaN || value.isInfinite) return 0;
    return double.parse(value.toStringAsFixed(2));
  }

  static double parseMoney(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 0;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.\-]'), '');
    return moneyRound(double.tryParse(cleaned) ?? 0);
  }

  /// Remove exactly one cart line by its unique [cartItemId].
  /// Returns `true` if a line was removed.
  static bool removeCartItemById(List<CartItem> cartItems, String cartItemId) {
    final index = cartItems.indexWhere((item) => item.id == cartItemId);
    if (index < 0) return false;
    cartItems.removeAt(index);
    return true;
  }

  /// Recalculate bill totals with paisa-safe rounding.
  static SaleBillTotals computeTotals({
    required List<CartItem> items,
    required double overallDiscount,
    bool includeSeasonalIncrement = true,
  }) {
    var subtotal = 0.0;
    var itemDiscounts = 0.0;
    var seasonalIncrements = 0.0;

    for (final item in items) {
      final baseLine = moneyRound(item.product.basePrice * item.quantity);
      final seasonal = includeSeasonalIncrement
          ? item.totalItemSeasonalInc
          : 0.0;
      // Discount is per-unit — scale by quantity like seasonal increment.
      final lineDiscount = item.totalItemDiscount;
      subtotal = moneyRound(subtotal + baseLine + seasonal);
      itemDiscounts = moneyRound(itemDiscounts + lineDiscount);
      seasonalIncrements = moneyRound(seasonalIncrements + seasonal);
    }

    final overall = moneyRound(overallDiscount);
    final totalPayable = moneyRound(subtotal - itemDiscounts - overall);

    return SaleBillTotals(
      subtotal: subtotal,
      itemDiscounts: itemDiscounts,
      seasonalIncrements: seasonalIncrements,
      overallDiscount: overall,
      totalPayable: totalPayable < 0 ? 0 : totalPayable,
      itemCount: items.length,
    );
  }

  /// Cash ↔ Udhaar switch: clear cash-only / credit-only fields without
  /// touching cart line items (avoids accidental full-cart wipe).
  static PaymentModeSwitchResult applyPaymentMethodSwitch({
    required PaymentMethod next,
    required List<String> zamindarPaymentTerms,
  }) {
    if (next == PaymentMethod.cash) {
      return const PaymentModeSwitchResult(
        paymentMethod: PaymentMethod.cash,
        paymentTerm: null,
        cashReceivedText: '0',
        clearSeasonalIncrements: true,
      );
    }

    String? term;
    if (zamindarPaymentTerms.length == 1) {
      term = zamindarPaymentTerms.first;
    }
    return PaymentModeSwitchResult(
      paymentMethod: PaymentMethod.credit,
      paymentTerm: term,
      cashReceivedText: '0',
      clearSeasonalIncrements: term != 'After Harvest',
    );
  }

  /// Advances never consume stock and must not contribute profit margin.
  static bool bypassesStockValidation(String? serviceKind) =>
      ProductServiceKind.isZeroMarginLoan(serviceKind);

  static double profitContribution({
    required String? serviceKind,
    required double saleAmount,
    required double catalogCost,
  }) {
    return ProductServiceKind.profitMargin(
      kind: serviceKind,
      saleAmount: moneyRound(saleAmount),
      catalogCost: moneyRound(catalogCost),
    );
  }

  /// Fully flush POS session state so edit-mode carts cannot bleed into a
  /// fresh sale. Caller still owns TextEditingControllers.
  static void flushCartSession({
    required List<CartItem> cartItems,
  }) {
    cartItems.clear();
  }
}

class SaleBillTotals {
  final double subtotal;
  final double itemDiscounts;
  final double seasonalIncrements;
  final double overallDiscount;
  final double totalPayable;
  final int itemCount;

  const SaleBillTotals({
    required this.subtotal,
    required this.itemDiscounts,
    required this.seasonalIncrements,
    required this.overallDiscount,
    required this.totalPayable,
    required this.itemCount,
  });
}

class PaymentModeSwitchResult {
  final PaymentMethod paymentMethod;
  final String? paymentTerm;
  final String cashReceivedText;
  final bool clearSeasonalIncrements;

  const PaymentModeSwitchResult({
    required this.paymentMethod,
    required this.paymentTerm,
    required this.cashReceivedText,
    required this.clearSeasonalIncrements,
  });
}
