import 'package:flutter/material.dart';
import 'package:agrikhata/Database/database_helper.dart';

class SaleScreen extends StatefulWidget {
  const SaleScreen({super.key});

  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> {
  // Color Palette - Deep Agricultural Green Theme
  static const Color primaryBackground = Color(0xFFF7F9F4);
  static const Color sidebarDark = Color(0xFF1B4332);
  static const Color activeGreen = Color(0xFF2D6A4F);
  static const Color checkoutButton = Color(0xFF40916C);
  static const Color lightGreenSurface = Color(0xFFEAF3DE);
  static const Color accentBorder = Color(0xFF40916C);
  static const Color errorRed = Color(0xFFDC2626);
  static const Color textDark = Color(0xFF1F2937);
  static const Color textGray = Color(0xFF6B7280);

  // Data State
  List<Zamindar> _allZamindars = [];
  Zamindar? _selectedZamindar;
  List<Kisaan> _kisaansForZamindar = [];
  Kisaan? _selectedKisaan;
  List<ProductItem> _allProducts = [];
  List<CartItem> _cartItems = [];
  List<RecommendedProduct> _recommendations = [];

  // Payment State
  bool _isCreditPayment = true;
  double _globalDiscount = 0;
  double _seasonalIncrementTotal = 0;

  // Controllers
  final TextEditingController _zamindarSearchController =
      TextEditingController();
  final TextEditingController _productSearchController =
      TextEditingController();
  final TextEditingController _qtyController = TextEditingController(text: '1');
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _incrementController = TextEditingController(
    text: '0',
  );
  final TextEditingController _globalDiscountController = TextEditingController(
    text: '0',
  );

  // Loading States
  bool _isLoading = true;
  bool _isSaving = false;

  // Constants
  final String _currentSeason = 'Kharif 2026';

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _qtyController.addListener(_recalculateCart);
    _priceController.addListener(_recalculateCart);
    _incrementController.addListener(_recalculateCart);
  }

  @override
  void dispose() {
    _zamindarSearchController.dispose();
    _productSearchController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    _incrementController.dispose();
    _globalDiscountController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      final zamindars = await DatabaseHelper.instance.getAllZamindarsEnriched();
      final products = await DatabaseHelper.instance.getAllProducts();
      setState(() {
        _allZamindars = zamindars;
        _allProducts = products;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorSnackBar('Failed to load data: $e');
    }
  }

  Future<void> _loadKisaansForZamindar(int zamindarId) async {
    try {
      final kisaans = await DatabaseHelper.instance.getKisaansForZamindar(
        zamindarId,
      );
      setState(() {
        _kisaansForZamindar = kisaans;
        _selectedKisaan = null;
      });
    } catch (e) {
      _showErrorSnackBar('Failed to load kisaans: $e');
    }
  }

  void _onZamindarSelected(Zamindar zamindar) async {
    setState(() {
      _selectedZamindar = zamindar;
      _kisaansForZamindar = [];
      _selectedKisaan = null;
      _recommendations = [];
    });
    if (zamindar.id != null) {
      await _loadKisaansForZamindar(zamindar.id!);
    }
    _zamindarSearchController.clear();
  }

  void _onKisaanSelected(Kisaan kisaan) {
    setState(() {
      _selectedKisaan = kisaan;
      _recommendations = _generateRecommendations(kisaan);
    });
  }

  List<RecommendedProduct> _generateRecommendations(Kisaan kisaan) {
    final recommendations = <RecommendedProduct>[];
    final acres = kisaan.landAcres;
    final crop = kisaan.currentCrop.toLowerCase();

    if (crop.contains('rice') ||
        crop.contains('wheat') ||
        crop.contains('sugarcane')) {
      final urea = _allProducts
          .where((p) => p.name.toLowerCase().contains('urea'))
          .firstOrNull;
      if (urea != null) {
        recommendations.add(
          RecommendedProduct(
            product: urea,
            suggestedQty: (acres * 2).ceil(),
            reason: 'Based on ${acres.toStringAsFixed(1)} acres',
          ),
        );
      }

      final dap = _allProducts
          .where((p) => p.name.toLowerCase().contains('dap'))
          .firstOrNull;
      if (dap != null) {
        recommendations.add(
          RecommendedProduct(
            product: dap,
            suggestedQty: (acres * 1).ceil(),
            reason: 'Based on ${acres.toStringAsFixed(1)} acres',
          ),
        );
      }
    }

    if (crop.contains('cotton') || crop.contains('vegetables')) {
      final pesticide = _allProducts
          .where(
            (p) => p.description?.toLowerCase().contains('pesticide') ?? false,
          )
          .firstOrNull;
      if (pesticide != null) {
        recommendations.add(
          RecommendedProduct(
            product: pesticide,
            suggestedQty: (acres * 0.5).ceil().clamp(1, 100),
            reason: 'For ${crop} crop',
          ),
        );
      }
    }

    return recommendations.take(3).toList();
  }

  void _addRecommendationToCart(RecommendedProduct rec) {
    _addProductToCart(rec.product, rec.suggestedQty);
  }

  void _addProductToCart(ProductItem product, int qty) {
    setState(() {
      final existingIndex = _cartItems.indexWhere(
        (item) => item.product.id == product.id,
      );
      if (existingIndex >= 0) {
        _cartItems[existingIndex] = _cartItems[existingIndex].copyWith(
          quantity: _cartItems[existingIndex].quantity + qty,
        );
      } else {
        _cartItems.add(
          CartItem(
            product: product,
            quantity: qty,
            unitPrice: product.retailPrice.toDouble(),
            seasonalIncrement: 0,
            discount: 0,
          ),
        );
      }
      _recalculateCart();
    });
  }

  void _addCurrentProductToCart() {
    if (_productSearchController.text.isEmpty) {
      _showErrorSnackBar('Please select a product');
      return;
    }

    final product = _allProducts
        .where((p) => p.name == _productSearchController.text)
        .firstOrNull;
    if (product == null) {
      _showErrorSnackBar('Product not found');
      return;
    }

    final qty = int.tryParse(_qtyController.text) ?? 1;
    final price =
        double.tryParse(_priceController.text) ??
        product.retailPrice.toDouble();
    final increment = double.tryParse(_incrementController.text) ?? 0;

    setState(() {
      final existingIndex = _cartItems.indexWhere(
        (item) => item.product.id == product.id,
      );
      if (existingIndex >= 0) {
        _cartItems[existingIndex] = _cartItems[existingIndex].copyWith(
          quantity: _cartItems[existingIndex].quantity + qty,
          unitPrice: price,
          seasonalIncrement: increment,
        );
      } else {
        _cartItems.add(
          CartItem(
            product: product,
            quantity: qty,
            unitPrice: price,
            seasonalIncrement: increment,
            discount: 0,
          ),
        );
      }
      _productSearchController.clear();
      _qtyController.text = '1';
      _priceController.clear();
      _incrementController.text = '0';
      _recalculateCart();
    });
  }

  void _removeCartItem(int index) {
    setState(() {
      _cartItems.removeAt(index);
      _recalculateCart();
    });
  }

  void _updateCartItemQuantity(int index, int delta) {
    setState(() {
      final newQty = (_cartItems[index].quantity + delta).clamp(1, 9999);
      _cartItems[index] = _cartItems[index].copyWith(quantity: newQty);
      _recalculateCart();
    });
  }

  void _updateCartItemDiscount(int index, double discount) {
    setState(() {
      _cartItems[index] = _cartItems[index].copyWith(discount: discount);
      _recalculateCart();
    });
  }

  void _recalculateCart() {
    double incrementTotal = 0;
    for (final item in _cartItems) {
      incrementTotal += item.seasonalIncrement * item.quantity;
    }
    setState(() {
      _seasonalIncrementTotal = incrementTotal;
    });
  }

  double get _subtotal {
    return _cartItems.fold(
      0,
      (sum, item) => sum + (item.unitPrice * item.quantity),
    );
  }

  double get _itemDiscounts {
    return _cartItems.fold(0, (sum, item) => sum + item.discount);
  }

  double get _totalPayable {
    double total = _subtotal - _itemDiscounts - _globalDiscount;
    if (_isCreditPayment) {
      total += _seasonalIncrementTotal;
    }
    return total.clamp(0, double.infinity);
  }

  bool get _isOverLimit {
    if (_selectedZamindar == null) return false;
    final currentBalance = _selectedZamindar!.udhaarBalance;
    final newBalance = currentBalance + _totalPayable;
    return newBalance > _selectedZamindar!.creditLimit;
  }

  Future<void> _saveAndPrintReceipt() async {
    if (_selectedZamindar == null) {
      _showErrorSnackBar('Please select a Zamindar');
      return;
    }

    if (_cartItems.isEmpty) {
      _showErrorSnackBar('Cart is empty');
      return;
    }

    if (_isCreditPayment && _isOverLimit) {
      final confirm = await _showConfirmDialog(
        'Credit Limit Exceeded',
        'This transaction will exceed the credit limit. Continue anyway?',
      );
      if (confirm != true) return;
    }

    setState(() => _isSaving = true);

    try {
      final saleItems = _cartItems
          .map(
            (item) => SaleLineItem(
              productId: item.product.id,
              productName: item.product.name,
              qty: item.quantity.toDouble(),
              unitPrice:
                  item.unitPrice +
                  (_isCreditPayment ? item.seasonalIncrement : 0),
              discount: item.discount,
            ),
          )
          .toList();

      await DatabaseHelper.instance.processSale(
        zamindarId: _selectedZamindar!.id!,
        kisaanId: _selectedKisaan?.id,
        items: saleItems,
        globalDiscount: _globalDiscount.round(),
        isCredit: _isCreditPayment,
        season: _currentSeason,
        dateTime: DateTime.now(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sale saved successfully! Total: Rs ${_totalPayable.toStringAsFixed(0)}',
            ),
            backgroundColor: checkoutButton,
            duration: const Duration(seconds: 2),
          ),
        );
        _resetForm();
      }
    } catch (e) {
      _showErrorSnackBar('Failed to save sale: $e');
    } finally {
      setState(() => _isSaving = false);
    }
  }

  Future<void> _generateWhatsAppPDF() async {
    _showErrorSnackBar('WhatsApp PDF feature coming soon');
  }

  void _discardSale() async {
    if (_cartItems.isEmpty) {
      _resetForm();
      return;
    }

    final confirm = await _showConfirmDialog(
      'Discard Sale',
      'Are you sure you want to discard this sale? All items will be removed.',
    );

    if (confirm == true) {
      _resetForm();
    }
  }

  void _resetForm() {
    setState(() {
      _selectedZamindar = null;
      _selectedKisaan = null;
      _kisaansForZamindar = [];
      _cartItems = [];
      _recommendations = [];
      _isCreditPayment = true;
      _globalDiscount = 0;
      _seasonalIncrementTotal = 0;
      _zamindarSearchController.clear();
      _productSearchController.clear();
      _qtyController.text = '1';
      _priceController.clear();
      _incrementController.text = '0';
      _globalDiscountController.text = '0';
    });
  }

  Future<bool?> _showConfirmDialog(String title, String message) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: errorRed),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: errorRed,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: primaryBackground,
      appBar: AppBar(
        title: const Text(
          'Product Sales',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: sidebarDark,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLeftColumn(),
                Expanded(child: _buildRightColumn()),
              ],
            ),
    );
  }

  Widget _buildLeftColumn() {
    return Container(
      width: 380,
      color: Colors.white,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildZamindarSelector(),
            const SizedBox(height: 24),
            if (_selectedZamindar != null) ...[
              _buildKisaanSelector(),
              const SizedBox(height: 24),
            ],
            if (_recommendations.isNotEmpty) _buildSmartRecommendations(),
          ],
        ),
      ),
    );
  }

  Widget _buildZamindarSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: sidebarDark,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Center(
                child: Text(
                  '1',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'Select Zamindar',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Autocomplete<Zamindar>(
          optionsBuilder: (textEditingValue) {
            if (textEditingValue.text.isEmpty) {
              return _allZamindars;
            }
            return _allZamindars.where(
              (z) =>
                  z.name.toLowerCase().contains(
                    textEditingValue.text.toLowerCase(),
                  ) ||
                  (z.locationGoth?.toLowerCase().contains(
                        textEditingValue.text.toLowerCase(),
                      ) ??
                      false),
            );
          },
          displayStringForOption: (z) => z.name,
          fieldViewBuilder: (context, controller, focusNode, onSubmit) {
            _zamindarSearchController.text = controller.text;
            return TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                hintText: 'Search Zamindar',
                prefixIcon: const Icon(Icons.search, color: textGray),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: accentBorder, width: 2),
                ),
              ),
            );
          },
          onSelected: _onZamindarSelected,
        ),
        if (_selectedZamindar != null) ...[
          const SizedBox(height: 12),
          _buildZamindarProfileTile(),
        ],
      ],
    );
  }

  Widget _buildZamindarProfileTile() {
    final zamindar = _selectedZamindar!;
    final isOverLimit = _isOverLimit;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isOverLimit ? const Color(0xFFFEF2F2) : lightGreenSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isOverLimit ? errorRed : accentBorder,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      zamindar.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textDark,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      zamindar.locationGoth ?? 'No location',
                      style: const TextStyle(fontSize: 13, color: textGray),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isOverLimit ? errorRed : checkoutButton,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isOverLimit ? 'Over limit' : 'Active',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.people, size: 16, color: textGray),
              const SizedBox(width: 6),
              Text(
                '${zamindar.activeKisaans} Kisaans',
                style: const TextStyle(fontSize: 13, color: textGray),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKisaanSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: sidebarDark,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Center(
                child: Text(
                  '2',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'Select Kisaan',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_kisaansForZamindar.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: Text(
                'No Kisaans found',
                style: TextStyle(color: textGray),
              ),
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.2,
            ),
            itemCount: _kisaansForZamindar.length,
            itemBuilder: (context, index) {
              final kisaan = _kisaansForZamindar[index];
              final isSelected = _selectedKisaan?.id == kisaan.id;

              return InkWell(
                onTap: () => _onKisaanSelected(kisaan),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isSelected ? lightGreenSurface : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected ? accentBorder : Colors.grey.shade300,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        kisaan.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isSelected ? activeGreen : textDark,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            kisaan.village,
                            style: const TextStyle(
                              fontSize: 11,
                              color: textGray,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: checkoutButton.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  kisaan.currentCrop,
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: sidebarDark,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${kisaan.landAcres} acres',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: textGray,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildSmartRecommendations() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.lightbulb, color: checkoutButton, size: 20),
            const SizedBox(width: 8),
            const Text(
              'Smart recommendations',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFFBBF24), width: 1),
          ),
          child: Column(
            children: _recommendations
                .map((rec) => _buildRecommendationItem(rec))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildRecommendationItem(RecommendedProduct rec) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rec.product.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: textDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${rec.suggestedQty} ${rec.product.uom}',
                  style: const TextStyle(fontSize: 11, color: textGray),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: checkoutButton,
              borderRadius: BorderRadius.circular(4),
            ),
            child: InkWell(
              onTap: () => _addRecommendationToCart(rec),
              child: const Row(
                children: [
                  Icon(Icons.add, size: 14, color: Colors.white),
                  SizedBox(width: 2),
                  Text(
                    'Add',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightColumn() {
    return Container(
      color: primaryBackground,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildProductEntrySection(),
                  const SizedBox(height: 24),
                  _buildCartSection(),
                ],
              ),
            ),
          ),
          _buildFinancialSummary(),
        ],
      ),
    );
  }

  Widget _buildProductEntrySection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: sidebarDark,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Center(
                  child: Text(
                    '3',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Add products to cart',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Autocomplete<ProductItem>(
                  optionsBuilder: (textEditingValue) {
                    if (textEditingValue.text.isEmpty) {
                      return _allProducts;
                    }
                    return _allProducts.where(
                      (p) =>
                          p.name.toLowerCase().contains(
                            textEditingValue.text.toLowerCase(),
                          ) ||
                          p.brand.toLowerCase().contains(
                            textEditingValue.text.toLowerCase(),
                          ),
                    );
                  },
                  displayStringForOption: (p) => p.name,
                  fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                    _productSearchController.text = controller.text;
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        hintText: 'Search or select product...',
                        prefixIcon: const Icon(
                          Icons.search,
                          color: textGray,
                          size: 20,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: accentBorder,
                            width: 2,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    );
                  },
                  onSelected: (product) {
                    _priceController.text = product.retailPrice.toString();
                  },
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _qtyController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Qty',
                    labelStyle: const TextStyle(fontSize: 12, color: textGray),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: accentBorder,
                        width: 2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _priceController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Price',
                    labelStyle: const TextStyle(fontSize: 12, color: textGray),
                    prefixText: 'Rs ',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: accentBorder,
                        width: 2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _incrementController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Increment',
                    labelStyle: const TextStyle(fontSize: 12, color: textGray),
                    prefixText: 'Rs ',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: accentBorder,
                        width: 2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _addCurrentProductToCart,
                icon: const Icon(Icons.add, size: 18),
                label: const Text(
                  'Add to cart',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: checkoutButton,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCartSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Cart',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: textDark,
                ),
              ),
              const Spacer(),
              Text(
                '${_cartItems.length} items',
                style: const TextStyle(fontSize: 13, color: textGray),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_cartItems.isEmpty)
            Container(
              padding: const EdgeInsets.all(32),
              child: const Center(
                child: Text(
                  'No items in cart',
                  style: TextStyle(color: textGray, fontSize: 14),
                ),
              ),
            )
          else
            Table(
              border: TableBorder.all(color: Colors.grey.shade200, width: 1),
              columnWidths: const {
                0: FlexColumnWidth(3),
                1: FixedColumnWidth(80),
                2: FixedColumnWidth(100),
                3: FixedColumnWidth(120),
                4: FixedColumnWidth(100),
                5: FixedColumnWidth(120),
                6: FixedColumnWidth(50),
              },
              children: [
                TableRow(
                  decoration: BoxDecoration(color: lightGreenSurface),
                  children: [
                    _buildTableHeader('Product'),
                    _buildTableHeader('Type'),
                    _buildTableHeader('Qty'),
                    _buildTableHeader('Unit price'),
                    _buildTableHeader('Discount'),
                    _buildTableHeader('Subtotal'),
                    _buildTableHeader(''),
                  ],
                ),
                ..._cartItems.asMap().entries.map((entry) {
                  final index = entry.key;
                  final item = entry.value;
                  return _buildCartRow(index, item);
                }),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildTableHeader(String text) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: sidebarDark,
        ),
      ),
    );
  }

  TableRow _buildCartRow(int index, CartItem item) {
    final subtotal = (item.unitPrice * item.quantity) - item.discount;
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            item.product.name,
            style: const TextStyle(fontSize: 13, color: textDark),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: _getProductTypeColor(item.product.name).withOpacity(0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _getProductType(item.product.name),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: _getProductTypeColor(item.product.name),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(
                onTap: () => _updateCartItemQuantity(index, -1),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.remove, size: 14, color: textDark),
                ),
              ),
              Expanded(
                child: Text(
                  '${item.quantity}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: textDark,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              InkWell(
                onTap: () => _updateCartItemQuantity(index, 1),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: checkoutButton,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.add, size: 14, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            'Rs ${item.unitPrice.toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 13, color: textDark),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: TextField(
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              prefixText: 'Rs ',
              hintText: '0',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (value) {
              final discount = double.tryParse(value) ?? 0;
              _updateCartItemDiscount(index, discount);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            'Rs ${subtotal.toStringAsFixed(0)}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textDark,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: IconButton(
            icon: const Icon(Icons.close, size: 16, color: errorRed),
            onPressed: () => _removeCartItem(index),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ),
      ],
    );
  }

  String _getProductType(String productName) {
    final name = productName.toLowerCase();
    if (name.contains('urea') || name.contains('dap')) return 'Fertilizer';
    if (name.contains('seed')) return 'Seed';
    if (name.contains('pesticide') || name.contains('karate'))
      return 'Pesticide';
    return 'Other';
  }

  Color _getProductTypeColor(String productName) {
    final name = productName.toLowerCase();
    if (name.contains('urea') || name.contains('dap')) return checkoutButton;
    if (name.contains('seed')) return const Color(0xFF2563EB);
    if (name.contains('pesticide') || name.contains('karate'))
      return const Color(0xFFDC2626);
    return textGray;
  }

  Widget _buildFinancialSummary() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: sidebarDark,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(children: [Expanded(child: _buildPaymentTypeToggle())]),
          const SizedBox(height: 16),
          _buildSummaryRow(
            'Subtotal',
            'Rs ${_subtotal.toStringAsFixed(0)}',
            false,
          ),
          _buildSummaryRow(
            'Item Discounts',
            'Rs ${_itemDiscounts.toStringAsFixed(0)}',
            false,
          ),
          Row(
            children: [
              const Text(
                'Overall Discount',
                style: TextStyle(fontSize: 14, color: Colors.white70),
              ),
              const Spacer(),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _globalDiscountController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    prefixText: 'Rs ',
                    prefixStyle: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Colors.white30),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(
                        color: Colors.white,
                        width: 2,
                      ),
                    ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _globalDiscount = double.tryParse(value) ?? 0;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_isCreditPayment)
            _buildSummaryRow(
              'Seasonal Increment',
              'Rs ${_seasonalIncrementTotal.toStringAsFixed(0)}',
              false,
            ),
          const Divider(color: Colors.white30, height: 24),
          _buildSummaryRow(
            'Total payable',
            'Rs ${_totalPayable.toStringAsFixed(0)}',
            true,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _discardSale,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text(
                    'Discard',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white30),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _generateWhatsAppPDF,
                  icon: const Icon(Icons.picture_as_pdf, size: 18),
                  label: const Text(
                    'WhatsApp PDF',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white30),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _saveAndPrintReceipt,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                      : const Icon(Icons.check_circle, size: 18),
                  label: Text(
                    _isSaving ? 'Saving...' : 'Save & Print receipt',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: checkoutButton,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentTypeToggle() {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () {
              setState(() {
                _isCreditPayment = true;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: _isCreditPayment ? checkoutButton : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isCreditPayment ? checkoutButton : Colors.white30,
                  width: 1.5,
                ),
              ),
              child: Text(
                'Credit (Udhaar)',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _isCreditPayment ? Colors.white : Colors.white70,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: () {
              setState(() {
                _isCreditPayment = false;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: !_isCreditPayment ? checkoutButton : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: !_isCreditPayment ? checkoutButton : Colors.white30,
                  width: 1.5,
                ),
              ),
              child: Text(
                'Cash',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: !_isCreditPayment ? Colors.white : Colors.white70,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryRow(String label, String value, bool isBold) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: isBold ? 16 : 14,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              color: isBold ? Colors.white : Colors.white70,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: isBold ? 18 : 14,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class CartItem {
  final ProductItem product;
  final int quantity;
  final double unitPrice;
  final double seasonalIncrement;
  final double discount;

  const CartItem({
    required this.product,
    required this.quantity,
    required this.unitPrice,
    required this.seasonalIncrement,
    required this.discount,
  });

  CartItem copyWith({
    ProductItem? product,
    int? quantity,
    double? unitPrice,
    double? seasonalIncrement,
    double? discount,
  }) {
    return CartItem(
      product: product ?? this.product,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      seasonalIncrement: seasonalIncrement ?? this.seasonalIncrement,
      discount: discount ?? this.discount,
    );
  }
}

class RecommendedProduct {
  final ProductItem product;
  final int suggestedQty;
  final String reason;

  const RecommendedProduct({
    required this.product,
    required this.suggestedQty,
    required this.reason,
  });
}

extension FirstOrNullExtension<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
