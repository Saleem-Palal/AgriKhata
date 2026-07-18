// Data models for New Sale screen

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

  Product({
    required this.id,
    required this.name,
    required this.type,
    required this.basePrice,
    required this.unit,
  });
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

  double get effectiveUnitPrice => product.basePrice + seasonalIncrement;
  
  double get subtotal {
    return (effectiveUnitPrice * quantity) - discount;
  }

  double get totalSeasonalIncrement => seasonalIncrement * quantity;
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
    return items.fold(0, (sum, item) => sum + (item.effectiveUnitPrice * item.quantity));
  }

  double get itemDiscounts {
    return items.fold(0, (sum, item) => sum + item.discount);
  }

  double get totalSeasonalIncrements {
    return items.fold(0, (sum, item) => sum + item.totalSeasonalIncrement);
  }

  double get totalPayable {
    return subtotal - itemDiscounts - overallDiscount;
  }

  int get itemCount => items.length;
}
