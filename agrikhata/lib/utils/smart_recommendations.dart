import '../models/sale_models.dart';
import 'season_utils.dart';

/// Agronomic input rule used by Smart Recommendations.
///
/// Dosage is expressed in shop sellable units per acre (bags, bottles, kg packs).
/// Stage windows are day offsets from the active season start.
class InputRecommendationRule {
  final String id;
  final String label;
  final List<String> namePatterns;
  final List<String>? cropKeywords;
  final ProductType? requiredType;
  final double dosagePerAcre;
  final int stageStartDay;
  final int stageEndDay;
  final int priority;

  const InputRecommendationRule({
    required this.id,
    required this.label,
    required this.namePatterns,
    this.cropKeywords,
    this.requiredType,
    required this.dosagePerAcre,
    required this.stageStartDay,
    required this.stageEndDay,
    this.priority = 100,
  });

  bool matchesCrop(String crop) {
    if (cropKeywords == null || cropKeywords!.isEmpty) return true;
    final c = crop.toLowerCase();
    return cropKeywords!.any((k) => c.contains(k.toLowerCase()));
  }

  bool isActiveForDay(int daysElapsed) =>
      daysElapsed >= stageStartDay && daysElapsed <= stageEndDay;

  bool matchesProduct(Product product) {
    if (requiredType != null && product.type != requiredType) return false;
    if (namePatterns.isEmpty) return true;
    final n = product.name.toLowerCase();
    if (namePatterns.any((p) => n.contains(p.toLowerCase()))) return true;
    // Seed SKUs are often variety codes without the word "seed".
    return requiredType == ProductType.seed;
  }
}

/// Built recommendation with remaining qty after purchase + cart deduction.
class SmartRecommendationResult {
  final Product product;
  final int quantity;
  final String displayQuantity;
  final String ruleId;
  final String stageLabel;

  const SmartRecommendationResult({
    required this.product,
    required this.quantity,
    required this.displayQuantity,
    required this.ruleId,
    required this.stageLabel,
  });

  Recommendation toRecommendation() => Recommendation(
    product: product,
    quantity: quantity.toDouble(),
    displayQuantity: displayQuantity,
  );
}

/// Catalog + calculator for season-stage Smart Recommendations.
class SmartRecommendationEngine {
  SmartRecommendationEngine._();

  /// Pakistan-oriented seasonal windows (Kharif Apr–Sep / Rabi Oct–Mar).
  /// Early: soil prep / basal. Mid: nitrogen + protectants. Late: late sprays.
  static const List<InputRecommendationRule> catalog = [
    InputRecommendationRule(
      id: 'seed_rice',
      label: 'Rice Seed',
      namePatterns: ['seed', 'seedling', 'variety'],
      cropKeywords: ['rice', 'paddy'],
      requiredType: ProductType.seed,
      dosagePerAcre: 5,
      stageStartDay: 0,
      stageEndDay: 40,
      priority: 10,
    ),
    InputRecommendationRule(
      id: 'seed_wheat',
      label: 'Wheat Seed',
      namePatterns: ['seed', 'variety'],
      cropKeywords: ['wheat'],
      requiredType: ProductType.seed,
      dosagePerAcre: 2,
      stageStartDay: 0,
      stageEndDay: 40,
      priority: 10,
    ),
    InputRecommendationRule(
      id: 'seed_cotton',
      label: 'Cotton Seed',
      namePatterns: ['seed', 'bt', 'cotton'],
      cropKeywords: ['cotton'],
      requiredType: ProductType.seed,
      dosagePerAcre: 2,
      stageStartDay: 0,
      stageEndDay: 45,
      priority: 10,
    ),
    InputRecommendationRule(
      id: 'dap',
      label: 'DAP',
      namePatterns: ['dap'],
      requiredType: ProductType.fertilizer,
      dosagePerAcre: 1,
      stageStartDay: 0,
      stageEndDay: 50,
      priority: 20,
    ),
    InputRecommendationRule(
      id: 'npk',
      label: 'NPK',
      namePatterns: ['npk', 'nitrophos', 'sop'],
      requiredType: ProductType.fertilizer,
      dosagePerAcre: 1,
      stageStartDay: 15,
      stageEndDay: 90,
      priority: 30,
    ),
    InputRecommendationRule(
      id: 'urea',
      label: 'Urea',
      namePatterns: ['urea'],
      requiredType: ProductType.fertilizer,
      dosagePerAcre: 2,
      stageStartDay: 30,
      stageEndDay: 120,
      priority: 40,
    ),
    InputRecommendationRule(
      id: 'cartap',
      label: 'Cartap',
      namePatterns: ['cartap'],
      cropKeywords: ['rice', 'paddy'],
      requiredType: ProductType.pesticide,
      dosagePerAcre: 0.5,
      stageStartDay: 45,
      stageEndDay: 130,
      priority: 50,
    ),
    InputRecommendationRule(
      id: 'protectant',
      label: 'Crop Protectant',
      namePatterns: [
        'karate',
        'confidor',
        'lambda',
        'imidacloprid',
        'herbicide',
        'insecticide',
        'fungicide',
      ],
      requiredType: ProductType.pesticide,
      dosagePerAcre: 0.5,
      stageStartDay: 40,
      stageEndDay: 150,
      priority: 60,
    ),
  ];

  /// Computes remaining recommendations for a Kisaan.
  ///
  /// [purchasedLineItems] — season invoice totals:
  /// `{productName, productType, quantity}`.
  /// [inStockProducts] — only products with available_stock > 0.
  /// [cartQuantitiesByProductId] — optional live cart deduction.
  static List<SmartRecommendationResult> build({
    required Kisaan kisaan,
    required List<Product> inStockProducts,
    required List<Map<String, dynamic>> purchasedLineItems,
    Map<String, int> cartQuantitiesByProductId = const {},
    DateTime? referenceDate,
    int maxResults = 4,
  }) {
    if (inStockProducts.isEmpty || kisaan.acres <= 0) return const [];

    final daysElapsed = SeasonUtils.daysElapsedInSeason(referenceDate);
    final stageLabel = SeasonUtils.seasonStageLabel(referenceDate);
    final crop = kisaan.crop;
    final acres = kisaan.acres;

    final activeRules =
        catalog
            .where((r) => r.matchesCrop(crop) && r.isActiveForDay(daysElapsed))
            .toList()
          ..sort((a, b) => a.priority.compareTo(b.priority));

    final results = <SmartRecommendationResult>[];
    final usedProductIds = <String>{};

    for (final rule in activeRules) {
      if (results.length >= maxResults) break;

      final candidates = inStockProducts
          .where(
            (p) => !usedProductIds.contains(p.id) && rule.matchesProduct(p),
          )
          .toList();
      if (candidates.isEmpty) continue;

      // Prefer the highest-stock match when several products fit the category.
      candidates.sort((a, b) {
        final stockA = _stockHint(a);
        final stockB = _stockHint(b);
        return stockB.compareTo(stockA);
      });
      final product = candidates.first;

      final maxNeeded = acres * rule.dosagePerAcre;
      final alreadyBought = _purchasedForRule(purchasedLineItems, rule);
      final inCart = cartQuantitiesByProductId[product.id] ?? 0;
      final remaining = maxNeeded - alreadyBought - inCart;
      if (remaining <= 0) continue;

      var qty = remaining.ceil();
      if (qty <= 0) continue;

      // Never recommend more than live shelf stock.
      final stockCap = _stockHint(product);
      if (stockCap > 0 && qty > stockCap) qty = stockCap;
      if (qty <= 0) continue;

      usedProductIds.add(product.id);
      results.add(
        SmartRecommendationResult(
          product: product,
          quantity: qty,
          displayQuantity: _formatQty(qty, product.unit),
          ruleId: rule.id,
          stageLabel: stageLabel,
        ),
      );
    }

    return results;
  }

  static double _purchasedForRule(
    List<Map<String, dynamic>> purchasedLineItems,
    InputRecommendationRule rule,
  ) {
    var sum = 0.0;
    for (final row in purchasedLineItems) {
      final name = (row['productName'] as String?) ?? '';
      final typeStr = ((row['productType'] as String?) ?? '').toLowerCase();
      final qty = (row['quantity'] as num?)?.toDouble() ?? 0;
      if (qty <= 0 || name.isEmpty) continue;

      final nameLower = name.toLowerCase();
      final nameHit = rule.namePatterns.any(
        (p) => nameLower.contains(p.toLowerCase()),
      );
      if (nameHit) {
        sum += qty;
        continue;
      }

      // Category fallback for variety-coded seeds / typed line items.
      if (rule.requiredType == ProductType.seed && typeStr.contains('seed')) {
        sum += qty;
      } else if (rule.requiredType == ProductType.fertilizer &&
          typeStr.contains('fertilizer') &&
          rule.namePatterns.any((p) => nameLower.contains(p.toLowerCase()))) {
        sum += qty;
      } else if (rule.requiredType == ProductType.pesticide &&
          (typeStr.contains('pesticide') || typeStr.contains('herbicide')) &&
          rule.namePatterns.any((p) => nameLower.contains(p.toLowerCase()))) {
        sum += qty;
      }
    }
    return sum;
  }

  static int _stockHint(Product product) {
    if (product is ProductWithStock) return product.availableStock;
    return 1 << 30;
  }

  static String _formatQty(int qty, String unit) {
    final formatted = qty >= 1000
        ? qty.toString().replaceAllMapped(
            RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
            (m) => '${m[1]},',
          )
        : '$qty';
    return '$formatted $unit';
  }
}

/// Thin product wrapper that carries live available_stock for capping.
class ProductWithStock extends Product {
  @override
  final int availableStock;

  ProductWithStock({
    required super.id,
    required super.name,
    required super.type,
    required super.basePrice,
    required super.unit,
    required this.availableStock,
  });
}
