import 'package:flutter/material.dart';
import '../models/sale_models.dart';
import '../widgets/sale_widgets.dart';

class NewSaleScreen extends StatefulWidget {
  const NewSaleScreen({Key? key}) : super(key: key);

  @override
  State<NewSaleScreen> createState() => _NewSaleScreenState();
}

class _NewSaleScreenState extends State<NewSaleScreen> {
  // Controllers
  final TextEditingController _zamindarSearchController = TextEditingController();
  final TextEditingController _productSearchController = TextEditingController();
  final TextEditingController _qtyController = TextEditingController(text: '1');
  final TextEditingController _priceController = TextEditingController(text: '0');
  final TextEditingController _seasonalIncrementController = TextEditingController(text: '0');
  final TextEditingController _overallDiscountController = TextEditingController(text: '0');

  // State
  Zamindar? _selectedZamindar;
  Kisaan? _selectedKisaan;
  Product? _selectedProduct;
  final List<CartItem> _cartItems = [];
  PaymentMethod _paymentMethod = PaymentMethod.credit;
  double _overallDiscount = 0;
  int _invoiceNumber = 312;

  // Mock data
  late final List<Zamindar> _zamindars;
  late final List<Product> _products;

  @override
  void initState() {
    super.initState();
    _initializeMockData();
  }

  void _initializeMockData() {
    _zamindars = [
      Zamindar(
        id: '1',
        name: 'Zafar Magsi',
        location: 'Jhal Magsi',
        kisaanCount: 4,
        isOverLimit: true,
        kisaans: [
          Kisaan(
            id: 'k1',
            name: 'Ramzan Ali',
            village: 'Shahan Palal',
            crop: 'Rice',
            acres: 10,
            zamindarId: '1',
          ),
          Kisaan(
            id: 'k2',
            name: 'Muhammad Saeed',
            village: 'Chak 44',
            crop: 'Wheat',
            acres: 6,
            zamindarId: '1',
          ),
          Kisaan(
            id: 'k3',
            name: 'Bashir Ahmed',
            village: 'Mouza Kalan',
            crop: 'Cotton',
            acres: 8,
            zamindarId: '1',
          ),
          Kisaan(
            id: 'k4',
            name: 'Ghulam Rasool',
            village: 'Chak 12',
            crop: 'Sugarcane',
            acres: 5,
            zamindarId: '1',
          ),
        ],
      ),
      Zamindar(
        id: '2',
        name: 'Abdul Rehman Buledi',
        location: 'Dera Bugti',
        kisaanCount: 3,
        kisaans: [
          Kisaan(
            id: 'k5',
            name: 'Ahmed Ali',
            village: 'Dera Bugti',
            crop: 'Wheat',
            acres: 12,
            zamindarId: '2',
          ),
        ],
      ),
      Zamindar(
        id: '3',
        name: 'Mir Miran Khosa',
        location: 'Barkhan',
        kisaanCount: 5,
        kisaans: [],
      ),
      Zamindar(
        id: '4',
        name: 'Asif Ali Umrani',
        location: 'Nasirabad',
        kisaanCount: 2,
        kisaans: [],
      ),
    ];

    _products = [
      Product(
        id: 'p1',
        name: 'Urea Fertilizer',
        type: ProductType.fertilizer,
        basePrice: 3600,
        unit: 'bag',
      ),
      Product(
        id: 'p2',
        name: 'DAP Fertilizer',
        type: ProductType.fertilizer,
        basePrice: 9200,
        unit: 'bag',
      ),
      Product(
        id: 'p3',
        name: 'Karate Insecticide',
        type: ProductType.pesticide,
        basePrice: 1200,
        unit: 'ml',
      ),
      Product(
        id: 'p4',
        name: 'Syngenta Rice Seed',
        type: ProductType.seed,
        basePrice: 420,
        unit: 'kg',
      ),
      Product(
        id: 'p5',
        name: 'Topik Herbicide',
        type: ProductType.pesticide,
        basePrice: 850,
        unit: 'ml',
      ),
      Product(
        id: 'p6',
        name: 'NPK Fertilizer',
        type: ProductType.fertilizer,
        basePrice: 5200,
        unit: 'bag',
      ),
    ];
  }

  List<Recommendation> _getRecommendations() {
    if (_selectedKisaan == null) return [];

    // Generate recommendations based on crop type
    switch (_selectedKisaan!.crop.toLowerCase()) {
      case 'rice':
        return [
          Recommendation(
            product: _products[0], // Urea Fertilizer
            quantity: 20,
            displayQuantity: '20 bags',
          ),
          Recommendation(
            product: _products[1], // DAP Fertilizer
            quantity: 10,
            displayQuantity: '10 bags',
          ),
          Recommendation(
            product: _products[2], // Karate Insecticide
            quantity: 2000,
            displayQuantity: '2,000 ml',
          ),
          Recommendation(
            product: _products[3], // Syngenta Rice Seed
            quantity: 25,
            displayQuantity: '25 kg',
          ),
        ];
      case 'wheat':
        return [
          Recommendation(
            product: _products[0], // Urea Fertilizer
            quantity: 15,
            displayQuantity: '15 bags',
          ),
          Recommendation(
            product: _products[1], // DAP Fertilizer
            quantity: 8,
            displayQuantity: '8 bags',
          ),
          Recommendation(
            product: _products[4], // Topik Herbicide
            quantity: 1500,
            displayQuantity: '1,500 ml',
          ),
        ];
      case 'cotton':
        return [
          Recommendation(
            product: _products[0], // Urea Fertilizer
            quantity: 18,
            displayQuantity: '18 bags',
          ),
          Recommendation(
            product: _products[5], // NPK Fertilizer
            quantity: 12,
            displayQuantity: '12 bags',
          ),
          Recommendation(
            product: _products[2], // Karate Insecticide
            quantity: 3000,
            displayQuantity: '3,000 ml',
          ),
        ];
      case 'sugarcane':
        return [
          Recommendation(
            product: _products[1], // DAP Fertilizer
            quantity: 20,
            displayQuantity: '20 bags',
          ),
          Recommendation(
            product: _products[5], // NPK Fertilizer
            quantity: 15,
            displayQuantity: '15 bags',
          ),
        ];
      default:
        return [];
    }
  }

  void _onProductSelected(Product? product) {
    if (product == null) return;

    setState(() {
      _selectedProduct = product;
      _productSearchController.text = product.name;
      _priceController.text = product.basePrice.toStringAsFixed(0);
      // Set seasonal increment to 0 by default
      _seasonalIncrementController.text = '0';
    });
  }

  void _addProductToCart() {
    if (_selectedProduct == null) return;

    final qty = int.tryParse(_qtyController.text) ?? 1;
    final price = double.tryParse(_priceController.text.replaceAll(',', '')) ?? 0;
    final seasonalInc = double.tryParse(_seasonalIncrementController.text.replaceAll(',', '')) ?? 0;

    setState(() {
      _cartItems.add(
        CartItem(
          id: 'c${DateTime.now().millisecondsSinceEpoch}',
          product: Product(
            id: _selectedProduct!.id,
            name: _selectedProduct!.name,
            type: _selectedProduct!.type,
            basePrice: price,
            unit: _selectedProduct!.unit,
          ),
          quantity: qty,
          seasonalIncrement: seasonalInc,
          discount: 0,
        ),
      );
    });

    // Reset form
    _productSearchController.clear();
    _qtyController.text = '1';
    _priceController.text = '0';
    _seasonalIncrementController.text = '0';
    _selectedProduct = null;
  }

  void _addRecommendation(Recommendation rec) {
    setState(() {
      _cartItems.add(
        CartItem(
          id: 'c${DateTime.now().millisecondsSinceEpoch}',
          product: rec.product,
          quantity: rec.quantity.toInt(),
          seasonalIncrement: 0,
          discount: 0,
        ),
      );
    });
  }

  void _removeCartItem(String id) {
    setState(() {
      _cartItems.removeWhere((item) => item.id == id);
    });
  }

  void _updateCartItemQuantity(String id, int change) {
    setState(() {
      final item = _cartItems.firstWhere((i) => i.id == id);
      final newQty = item.quantity + change;
      if (newQty > 0) {
        item.quantity = newQty;
      }
    });
  }

  void _updateCartItemDiscount(String id, double discount) {
    setState(() {
      final item = _cartItems.firstWhere((i) => i.id == id);
      item.discount = discount;
    });
  }

  void _updateCartItemSeasonalIncrement(String id, double increment) {
    setState(() {
      final item = _cartItems.firstWhere((i) => i.id == id);
      item.seasonalIncrement = increment;
    });
  }

  void _clearZamindarSelection() {
    setState(() {
      _selectedZamindar = null;
      _selectedKisaan = null;
      _zamindarSearchController.clear();
    });
  }

  void _saveAndPrint() {
    setState(() {
      _invoiceNumber++;
      _cartItems.clear();
      _selectedZamindar = null;
      _selectedKisaan = null;
      _selectedProduct = null;
      _overallDiscount = 0;
      _overallDiscountController.text = '0';
      _zamindarSearchController.clear();
      _productSearchController.clear();
      _qtyController.text = '1';
      _priceController.text = '0';
      _seasonalIncrementController.text = '0';
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sale saved and invoice printed!'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  SaleSummary _getSummary() {
    return SaleSummary(
      items: _cartItems,
      overallDiscount: _overallDiscount,
      paymentMethod: _paymentMethod,
    );
  }

  @override
  void dispose() {
    _zamindarSearchController.dispose();
    _productSearchController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    _seasonalIncrementController.dispose();
    _overallDiscountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SaleColors.canvasBg,
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLeftColumn(),
                Expanded(child: _buildRightColumn()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        color: SaleColors.cardBg,
        border: Border(
          bottom: BorderSide(color: SaleColors.borderLight, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'New sale',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textDark,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Tuesday, 7 April 2026 — Rabi Season',
                  style: const TextStyle(
                    fontSize: 12,
                    color: SaleColors.textLight,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: SaleColors.canvasBg,
              border: Border.all(color: SaleColors.borderMid, width: 0.5),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Sale # AK-2026-${_invoiceNumber.toString().padLeft(4, '0')}',
              style: const TextStyle(
                fontSize: 12,
                color: SaleColors.textLight,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                setState(() {
                  _cartItems.clear();
                  _selectedZamindar = null;
                  _selectedKisaan = null;
                  _selectedProduct = null;
                  _overallDiscount = 0;
                  _overallDiscountController.text = '0';
                  _zamindarSearchController.clear();
                  _productSearchController.clear();
                  _qtyController.text = '1';
                  _priceController.text = '0';
                  _seasonalIncrementController.text = '0';
                });
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: SaleColors.cardBg,
                  border: Border.all(color: SaleColors.borderMid, width: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'Discard',
                  style: TextStyle(
                    fontSize: 13,
                    color: SaleColors.textDark,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _saveAndPrint,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: SaleColors.darkGreen,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.check, size: 13, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      'Save & Print',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftColumn() {
    return Container(
      width: 380,
      padding: const EdgeInsets.fromLTRB(22, 18, 9, 18),
      child: SingleChildScrollView(
        child: Column(
          children: [
            _buildSelectZamindarCard(),
            const SizedBox(height: 14),
            if (_selectedZamindar != null) ...[
              _buildSelectKisaanCard(),
              const SizedBox(height: 14),
              _buildSmartRecommendationsCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRightColumn() {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 18, 22, 18),
      child: SingleChildScrollView(
        child: Column(
          children: [
            _buildAddProductCard(),
            const SizedBox(height: 14),
            _buildCartCard(),
            const SizedBox(height: 14),
            _buildSummaryCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectZamindarCard() {
    return Container(
      decoration: BoxDecoration(
        color: SaleColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SaleColors.borderLight, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const StepHeader(stepNumber: 1, title: 'Select Zamindar'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildZamindarAutocomplete(),
                if (_selectedZamindar != null)
                  _buildZamindarPillWithClear(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildZamindarAutocomplete() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text(
              'Search Zamindar',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: SaleColors.textMuted,
              ),
            ),
            const SizedBox(width: 2),
            const Text(
              '*',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xFFE24B4A),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Autocomplete<Zamindar>(
          optionsBuilder: (TextEditingValue textEditingValue) {
            if (textEditingValue.text.isEmpty) {
              return const Iterable<Zamindar>.empty();
            }
            return _zamindars.where((Zamindar zamindar) {
              return zamindar.name
                  .toLowerCase()
                  .contains(textEditingValue.text.toLowerCase());
            });
          },
          displayStringForOption: (Zamindar option) => option.name,
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            _zamindarSearchController.text = controller.text;
            return TextFormField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(
                fontSize: 13,
                color: SaleColors.textDark,
              ),
              decoration: InputDecoration(
                hintText: 'Type to search Zamindar (e.g. Asif, Zafar)...',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: SaleColors.textLight,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: SaleColors.borderMid, width: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: SaleColors.borderMid, width: 0.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: SaleColors.accentGreen, width: 1),
                ),
                filled: true,
                fillColor: SaleColors.cardBg,
              ),
            );
          },
          onSelected: (Zamindar selection) {
            setState(() {
              _selectedZamindar = selection;
              _selectedKisaan = null;
            });
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(9),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200, maxWidth: 348),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final option = options.elementAt(index);
                      return InkWell(
                        onTap: () => onSelected(option),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: SaleColors.borderLight, width: 0.5),
                            ),
                          ),
                          child: Text(
                            option.name,
                            style: const TextStyle(
                              fontSize: 13,
                              color: SaleColors.textDark,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildZamindarPillWithClear() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: SaleColors.lightGreenBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: SaleColors.midGreen,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                _selectedZamindar!.initials,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.lightGreen,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _selectedZamindar!.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textDark,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${_selectedZamindar!.location} · ${_selectedZamindar!.kisaanCount} Kisaans',
                  style: const TextStyle(
                    fontSize: 11,
                    color: SaleColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (_selectedZamindar!.isOverLimit)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: SaleColors.limitBg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Over limit',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.limitText,
                ),
              ),
            ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _clearZamindarSelection,
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.clear,
                  size: 18,
                  color: SaleColors.textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectKisaanCard() {
    return Container(
      decoration: BoxDecoration(
        color: SaleColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SaleColors.borderLight, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const StepHeader(stepNumber: 2, title: 'Select Kisaan'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Kisaans under ${_selectedZamindar!.name}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textMuted,
                  ),
                ),
                const SizedBox(height: 8),
                if (_selectedZamindar!.kisaans.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No kisaans found',
                      style: TextStyle(
                        fontSize: 12,
                        color: SaleColors.textMuted,
                      ),
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.5,
                    ),
                    itemCount: _selectedZamindar!.kisaans.length,
                    itemBuilder: (context, index) {
                      final kisaan = _selectedZamindar!.kisaans[index];
                      return KisaanCard(
                        kisaan: kisaan,
                        isSelected: _selectedKisaan?.id == kisaan.id,
                        onTap: () {
                          setState(() {
                            _selectedKisaan = kisaan;
                          });
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmartRecommendationsCard() {
    return Container(
      decoration: BoxDecoration(
        color: SaleColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SaleColors.borderLight, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: SaleColors.borderLight, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: SaleColors.paleGreen,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.stars,
                      size: 12,
                      color: SaleColors.midGreen,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Smart recommendations',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textDark,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SmartRecommendationsBox(
              selectedKisaan: _selectedKisaan,
              recommendations: _getRecommendations(),
              onAddRecommendation: _addRecommendation,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddProductCard() {
    return Container(
      decoration: BoxDecoration(
        color: SaleColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SaleColors.borderLight, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const StepHeader(stepNumber: 3, title: 'Add products to cart'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  flex: 3,
                  child: _buildProductAutocomplete(),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: _buildCompactField('Qty', _qtyController, TextInputType.number),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 100,
                  child: _buildCompactField('Price', _priceController, TextInputType.number),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 100,
                  child: _buildCompactField('Seasonal Inc', _seasonalIncrementController, TextInputType.number),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 0),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _addProductToCart,
                      borderRadius: BorderRadius.circular(9),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: SaleColors.darkGreen,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Text(
                          '+ Add to cart',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductAutocomplete() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Product',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: SaleColors.textMuted,
          ),
        ),
        const SizedBox(height: 5),
        Autocomplete<Product>(
          optionsBuilder: (TextEditingValue textEditingValue) {
            if (textEditingValue.text.isEmpty) {
              return const Iterable<Product>.empty();
            }
            return _products.where((Product product) {
              return product.name
                  .toLowerCase()
                  .contains(textEditingValue.text.toLowerCase());
            });
          },
          displayStringForOption: (Product option) => option.name,
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            _productSearchController.text = controller.text;
            return TextFormField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(
                fontSize: 13,
                color: SaleColors.textDark,
              ),
              decoration: InputDecoration(
                hintText: 'Search or select product...',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: SaleColors.textLight,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: SaleColors.borderMid, width: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: SaleColors.borderMid, width: 0.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: SaleColors.accentGreen, width: 1),
                ),
                filled: true,
                fillColor: SaleColors.cardBg,
              ),
            );
          },
          onSelected: _onProductSelected,
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(9),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final option = options.elementAt(index);
                      return InkWell(
                        onTap: () => onSelected(option),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: SaleColors.borderLight, width: 0.5),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  option.name,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: SaleColors.textDark,
                                  ),
                                ),
                              ),
                              Text(
                                CurrencyFormatter.format(option.basePrice),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: SaleColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildCompactField(String label, TextEditingController controller, TextInputType keyboardType) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: SaleColors.textMuted,
          ),
        ),
        const SizedBox(height: 5),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          style: const TextStyle(
            fontSize: 13,
            color: SaleColors.textDark,
          ),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: SaleColors.borderMid, width: 0.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: SaleColors.borderMid, width: 0.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: SaleColors.accentGreen, width: 1),
            ),
            filled: true,
            fillColor: SaleColors.cardBg,
          ),
        ),
      ],
    );
  }

  Widget _buildCartCard() {
    return Container(
      decoration: BoxDecoration(
        color: SaleColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SaleColors.borderLight, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: SaleColors.borderLight, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                const Text(
                  'Cart',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textDark,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_cartItems.length} items',
                  style: const TextStyle(
                    fontSize: 12,
                    color: SaleColors.textLight,
                  ),
                ),
              ],
            ),
          ),
          if (_cartItems.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No items in cart',
                  style: TextStyle(
                    fontSize: 13,
                    color: SaleColors.textMuted,
                  ),
                ),
              ),
            )
          else
            _buildCartTable(),
        ],
      ),
    );
  }

  Widget _buildCartTable() {
    final showSeasonalIncrement = _paymentMethod == PaymentMethod.credit;
    
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        horizontalMargin: 12,
        columnSpacing: 16,
        headingRowHeight: 36,
        dataRowHeight: 48,
        headingRowColor: MaterialStateProperty.all(SaleColors.canvasBg),
        dividerThickness: 0.5,
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: SaleColors.borderLight, width: 0.5),
          ),
        ),
        columns: [
          const DataColumn(
            label: Text(
              'Product',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: SaleColors.textMuted,
              ),
            ),
          ),
          const DataColumn(
            label: Text(
              'Type',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: SaleColors.textMuted,
              ),
            ),
          ),
          const DataColumn(
            label: Text(
              'Qty',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: SaleColors.textMuted,
              ),
            ),
          ),
          const DataColumn(
            label: Text(
              'Unit price',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: SaleColors.textMuted,
              ),
            ),
          ),
          if (showSeasonalIncrement)
            const DataColumn(
              label: Text(
                'Seasonal Inc',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.textMuted,
                ),
              ),
            ),
          const DataColumn(
            label: Text(
              'Discount',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: SaleColors.textMuted,
              ),
            ),
          ),
          const DataColumn(
            label: Text(
              'Subtotal',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: SaleColors.textMuted,
              ),
            ),
          ),
          const DataColumn(
            label: SizedBox.shrink(),
          ),
        ],
        rows: _cartItems.map((item) {
          return DataRow(
            cells: [
              DataCell(
                SizedBox(
                  width: 160,
                  child: Text(
                    item.product.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: SaleColors.textDark,
                    ),
                  ),
                ),
              ),
              DataCell(
                ProductTypeBadge(type: item.product.type),
              ),
              DataCell(
                QuantityControl(
                  quantity: item.quantity,
                  onIncrement: () => _updateCartItemQuantity(item.id, 1),
                  onDecrement: () => _updateCartItemQuantity(item.id, -1),
                ),
              ),
              DataCell(
                Text(
                  CurrencyFormatter.format(item.product.basePrice),
                  style: const TextStyle(
                    fontSize: 12,
                    color: SaleColors.textDark,
                  ),
                ),
              ),
              if (showSeasonalIncrement)
                DataCell(
                  InlineEditableField(
                    value: item.seasonalIncrement,
                    onChanged: (val) => _updateCartItemSeasonalIncrement(item.id, val),
                    width: 80,
                  ),
                ),
              DataCell(
                InlineEditableField(
                  value: item.discount,
                  onChanged: (val) => _updateCartItemDiscount(item.id, val),
                ),
              ),
              DataCell(
                Text(
                  CurrencyFormatter.format(item.subtotal),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textDark,
                  ),
                ),
              ),
              DataCell(
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _removeCartItem(item.id),
                    borderRadius: BorderRadius.circular(5),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        border: Border.all(color: SaleColors.borderLight, width: 0.5),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: SaleColors.deleteBtnColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSummaryCard() {
    final summary = _getSummary();
    final showSeasonalIncrement = _paymentMethod == PaymentMethod.credit;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: SaleColors.darkGreen,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSummaryRow('Subtotal', summary.subtotal),
          _buildSummaryRow('Item Discounts', summary.itemDiscounts),
          if (showSeasonalIncrement)
            _buildSummaryRow('Seasonal Increment Total', summary.totalSeasonalIncrements),
          _buildOverallDiscountRow(),
          Container(
            height: 0.5,
            margin: const EdgeInsets.symmetric(vertical: 8),
            color: Colors.white.withOpacity(0.15),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total payable',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
              Text(
                CurrencyFormatter.format(summary.totalPayable),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.lightGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          PaymentMethodToggle(
            selectedMethod: _paymentMethod,
            onChanged: (method) {
              setState(() {
                _paymentMethod = method;
              });
            },
          ),
          const SizedBox(height: 10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _saveAndPrint,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: SaleColors.accentGreen,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.check, size: 14, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      'Save & Print receipt',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {},
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'WhatsApp PDF to ${_selectedZamindar?.name ?? "Zamindar"}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SaleColors.textLight,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: SaleColors.textLight,
            ),
          ),
          Text(
            CurrencyFormatter.format(value),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverallDiscountRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Overall Discount',
            style: TextStyle(
              fontSize: 13,
              color: SaleColors.textLight,
            ),
          ),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _overallDiscountController,
              textAlign: TextAlign.right,
              keyboardType: TextInputType.number,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
              ),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(
                    color: Colors.white.withOpacity(0.2),
                    width: 0.5,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(
                    color: Colors.white.withOpacity(0.2),
                    width: 0.5,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: const BorderSide(
                    color: SaleColors.lightGreen,
                    width: 1,
                  ),
                ),
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
              ),
              onChanged: (val) {
                final parsed = double.tryParse(val.replaceAll(',', ''));
                if (parsed != null) {
                  setState(() {
                    _overallDiscount = parsed;
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
