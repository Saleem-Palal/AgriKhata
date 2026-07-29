// Data models for New Sale screen

/// Paisa-safe rounding used by cart line math and bill totals.
double moneyRound(double value) {
  if (value.isNaN || value.isInfinite) return 0;
  return double.parse(value.toStringAsFixed(2));
}

class Zamindar {
  final String id;
  final String name;
  final String location;
  final int kisaanCount;
  final bool isOverLimit;
  final List<String> paymentTerms;
  final String whatsappNumber;
  final List<Kisaan> kisaans;

  Zamindar({
    required this.id,
    required this.name,
    required this.location,
    required this.kisaanCount,
    this.isOverLimit = false,
    this.paymentTerms = const [],
    this.whatsappNumber = '',
    required this.kisaans,
  });

  String get initials {
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, 2).toUpperCase();
  }
}

class Kisaan {
  final String id;
  final String name;
  final String village;
  final String crop;
  final double acres;
  final String zamindarId;

  Kisaan({
    required this.id,
    required this.name,
    required this.village,
    required this.crop,
    required this.acres,
    required this.zamindarId,
  });
}

class Product {
  final String id;
  final String name;
  final ProductType type;
  final double basePrice;
  final String unit;
  final String brand;
  final double costPrice;
  final int availableStock;
  final double seasonalIncrement;

  Product({
    required this.id,
    required this.name,
    required this.type,
    required this.basePrice,
    required this.unit,
    this.brand = '',
    this.costPrice = 0,
    this.availableStock = 0,
    this.seasonalIncrement = 0,
  });

  bool get hasSeasonalIncrement => seasonalIncrement > 0;
}

enum ProductType {
  fertilizer,
  pesticide,
  seed,
  other;

  String get displayName {
    switch (this) {
      case ProductType.fertilizer:
        return 'Fertilizer';
      case ProductType.pesticide:
        return 'Pesticide';
      case ProductType.seed:
        return 'Seed';
      case ProductType.other:
        return 'Other';
    }
  }
}

class CartItem {
  final String id;
  final Product product;
  int quantity;
  double seasonalIncrement;
  double discount;

  CartItem({
    required this.id,
    required this.product,
    required this.quantity,
    this.seasonalIncrement = 0,
    this.discount = 0,
  });

  double get effectiveUnitPrice =>
      moneyRound(product.basePrice + seasonalIncrement);

  double get subtotal {
    return moneyRound((effectiveUnitPrice * quantity) - discount);
  }

  double get totalSeasonalIncrement =>
      moneyRound(seasonalIncrement * quantity);
}

class Recommendation {
  final Product product;
  final double quantity;
  final String displayQuantity;

  Recommendation({
    required this.product,
    required this.quantity,
    required this.displayQuantity,
  });
}

enum PaymentMethod {
  credit,
  cash;

  String get displayName {
    switch (this) {
      case PaymentMethod.credit:
        return 'Credit (Udhaar)';
      case PaymentMethod.cash:
        return 'Cash';
    }
  }
}

class SaleSummary {
  final List<CartItem> items;
  final double overallDiscount;
  final PaymentMethod paymentMethod;

  SaleSummary({
    required this.items,
    this.overallDiscount = 0,
    this.paymentMethod = PaymentMethod.credit,
  });

  double get subtotal {
    return moneyRound(
      items.fold<double>(
        0,
        (sum, item) => sum + (item.effectiveUnitPrice * item.quantity),
      ),
    );
  }

  double get itemDiscounts {
    return moneyRound(
      items.fold<double>(0, (sum, item) => sum + item.discount),
    );
  }

  double get totalSeasonalIncrements {
    return moneyRound(
      items.fold<double>(0, (sum, item) => sum + item.totalSeasonalIncrement),
    );
  }

  double get totalPayable {
    final total = moneyRound(subtotal - itemDiscounts - overallDiscount);
    return total < 0 ? 0 : total;
  }

  int get itemCount => items.length;
}
