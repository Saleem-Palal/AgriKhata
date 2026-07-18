import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/sale_models.dart';
import '../models/ledger_models.dart';
import '../Widgets/sale_widgets.dart';
import '../Database/database_helper.dart' as db;
import '../utils/season_utils.dart';
import '../utils/smart_recommendations.dart';
import '../utils/advance_checkout_overlay.dart';
import '../utils/pdf_generator.dart';
import '../utils/pdf_share.dart';

class NewSaleScreen extends StatefulWidget {
  final int? preSelectedZamindarId;
  final int? preSelectedKisaanId;
  final String? editInvoiceNumber;
  final VoidCallback?
  onCancelEdit; // Callback to notify parent when edit is cancelled

  const NewSaleScreen({
    super.key,
    this.preSelectedZamindarId,
    this.preSelectedKisaanId,
    this.editInvoiceNumber,
    this.onCancelEdit,
  });

  @override
  State<NewSaleScreen> createState() => _NewSaleScreenState();
}

enum _CheckoutMode { productSale, cashFuelAdvance }

enum _AdvanceKind { cash, diesel, petrol }

class _NewSaleScreenState extends State<NewSaleScreen> {
  // Controllers
  final TextEditingController _zamindarSearchController =
      TextEditingController();
  final TextEditingController _kisaanSearchController = TextEditingController();
  final TextEditingController _productSearchController =
      TextEditingController();
  final TextEditingController _qtyController = TextEditingController(text: '1');
  final TextEditingController _priceController = TextEditingController(
    text: '0',
  );
  final TextEditingController _seasonalIncrementController =
      TextEditingController(text: '0');
  final TextEditingController _overallDiscountController =
      TextEditingController(text: '0');
  final TextEditingController _walkInCustomerNameController =
      TextEditingController();
  final TextEditingController _cashReceivedController = TextEditingController(
    text: '0',
  );
  final TextEditingController _advanceAmountController =
      TextEditingController();
  final TextEditingController _advanceLitersController =
      TextEditingController();
  final TextEditingController _advanceRemarksController =
      TextEditingController();

  // State
  Zamindar? _selectedZamindar;
  Kisaan? _selectedKisaan;
  Product? _selectedProduct;
  final List<CartItem> _cartItems = [];
  PaymentMethod _paymentMethod = PaymentMethod.credit;
  String? _selectedSalePaymentTerm;
  double _overallDiscount = 0;
  String _invoiceNumber =
      'INV-1000'; // Display only - actual number generated at save time
  bool _isWalkInCustomer = false;
  DateTime _selectedDateTime = DateTime.now();
  bool _isDateTimeLocked = false;
  bool _isEditMode = false;
  String? _editingInvoiceNumber;
  _CheckoutMode _checkoutMode = _CheckoutMode.productSale;
  _AdvanceKind _advanceKind = _AdvanceKind.cash;

  // Database data
  List<Zamindar> _zamindars = [];
  List<Product> _products = [];
  bool _isLoading = true;
  bool _isSaving = false;

  // Smart recommendations (async, season-stage + stock aware)
  List<Recommendation> _smartRecommendations = [];
  bool _isLoadingRecommendations = false;
  String? _recommendationStageLabel;
  int _recommendationsRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadDataFromDatabase();

    // Keep zamindar/product pickers in sync across the app without clearing cart state.
    db.DatabaseHelper.instance.addListener(_onDatabaseChanged);
  }

  void _onDatabaseChanged() => _syncReferenceData();

  Future<void> _syncReferenceData() async {
    if (!mounted || _isSaving) return;

    try {
      final dbZamindars = await db.DatabaseHelper.instance
          .getAllZamindarsEnriched();
      final dbProducts = await db.DatabaseHelper.instance.getAllProducts();

      final zamindars = <Zamindar>[];
      for (final dbZamindar in dbZamindars) {
        final kisaans = <Kisaan>[];
        if (dbZamindar.id != null) {
          final dbKisaans = await db.DatabaseHelper.instance
              .getKisaansForZamindar(dbZamindar.id!);
          kisaans.addAll(dbKisaans.map(_convertKisaan));
        }
        zamindars.add(_convertZamindar(dbZamindar, kisaans));
      }

      final products = dbProducts.map(_convertProduct).toList();
      final selectedZamindarId = _selectedZamindar?.id;
      final selectedKisaanId = _selectedKisaan?.id;

      Zamindar? refreshedZamindar;
      if (selectedZamindarId != null) {
        for (final zamindar in zamindars) {
          if (zamindar.id == selectedZamindarId) {
            refreshedZamindar = zamindar;
            break;
          }
        }
      }

      Kisaan? refreshedKisaan;
      if (refreshedZamindar != null && selectedKisaanId != null) {
        for (final kisaan in refreshedZamindar.kisaans) {
          if (kisaan.id == selectedKisaanId) {
            refreshedKisaan = kisaan;
            break;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _zamindars = zamindars;
        _products = products;

        if (selectedZamindarId != null && refreshedZamindar == null) {
          _selectedZamindar = null;
          _selectedKisaan = null;
          _zamindarSearchController.clear();
          _smartRecommendations = [];
          _recommendationStageLabel = null;
        } else if (refreshedZamindar != null) {
          _selectedZamindar = refreshedZamindar;
          _selectedKisaan = refreshedKisaan;
          _zamindarSearchController.text = refreshedZamindar.name;
        }
      });
      if (_selectedKisaan != null) {
        await _loadSmartRecommendations();
      }
    } catch (e) {
      debugPrint('Error syncing sale screen reference data: $e');
    }
  }

  Future<void> _loadDataFromDatabase() async {
    setState(() => _isLoading = true);

    try {
      // Fetch zamindars and products from database
      final dbZamindars = await db.DatabaseHelper.instance
          .getAllZamindarsEnriched();
      final dbProducts = await db.DatabaseHelper.instance.getAllProducts();

      // Convert database models to sale models
      final zamindars = <Zamindar>[];
      Zamindar? preSelectedZamindar;

      for (final dbZamindar in dbZamindars) {
        final kisaans = <Kisaan>[];
        if (dbZamindar.id != null) {
          final dbKisaans = await db.DatabaseHelper.instance
              .getKisaansForZamindar(dbZamindar.id!);
          kisaans.addAll(dbKisaans.map((dbKisaan) => _convertKisaan(dbKisaan)));
        }
        final zamindar = _convertZamindar(dbZamindar, kisaans);
        zamindars.add(zamindar);

        // Check if this is the pre-selected zamindar
        if (widget.preSelectedZamindarId != null &&
            dbZamindar.id == widget.preSelectedZamindarId) {
          preSelectedZamindar = zamindar;
        }
      }

      final products = dbProducts.map(_convertProduct).toList();

      // 🔒 STRICT CONDITIONAL GATE: Invoice number assignment
      // CRITICAL: Must check edit mode BEFORE fetching/setting invoice number
      String invoiceNumberToDisplay;
      if (widget.editInvoiceNumber != null) {
        // ✏️ EDIT MODE: Use the invoice number being edited
        invoiceNumberToDisplay = widget.editInvoiceNumber!;
      } else {
        // ✨ NEW SALE MODE: Fetch next available invoice number from database
        invoiceNumberToDisplay = await db.DatabaseHelper.instance
            .getNextInvoiceNumber();
      }

      setState(() {
        _zamindars = zamindars;
        _products = products;
        _invoiceNumber = invoiceNumberToDisplay;
        _isLoading = false;

        // Pre-select zamindar if provided
        if (preSelectedZamindar != null) {
          _selectedZamindar = preSelectedZamindar;
          _zamindarSearchController.text = preSelectedZamindar.name;

          // Auto-select Kisaan (either pre-selected or 'Self')
          if (preSelectedZamindar.kisaans.isNotEmpty) {
            final kisaans = preSelectedZamindar.kisaans;
            if (widget.preSelectedKisaanId != null) {
              // Try to find the pre-selected Kisaan
              final kisaan = kisaans
                  .where((k) => k.id == widget.preSelectedKisaanId.toString())
                  .firstOrNull;
              _selectedKisaan =
                  kisaan ??
                  kisaans.firstWhere(
                    (k) => k.name == 'Self',
                    orElse: () => kisaans[0],
                  );
            } else {
              // Default to 'Self' Kisaan
              _selectedKisaan = kisaans.firstWhere(
                (k) => k.name == 'Self',
                orElse: () => kisaans[0],
              );
            }
          }
        }
      });

      // Handle edit mode vs. new sale mode state lifecycle
      if (widget.editInvoiceNumber != null) {
        // If we have an edit invoice, we need to load it
        // Force reload if cart is empty (can happen after discard or navigation back)
        // OR if this is a different invoice than what we currently have cached
        if (_cartItems.isEmpty ||
            _editingInvoiceNumber != widget.editInvoiceNumber) {
          await _loadEditData(widget.editInvoiceNumber!);
        }
      } else {
        // Explicitly reset edit state for a fresh new sale
        // This prevents lingering edit state from poisoning new sales
        setState(() {
          _isEditMode = false;
          _editingInvoiceNumber = null;
        });
      }

      if (_selectedKisaan != null) {
        await _loadSmartRecommendations();
      }
    } catch (e) {
      debugPrint('Error loading data from database: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load data: $e'),
            backgroundColor: Colors.red,
            duration: Duration(minutes: 1),
          ),
        );
      }
    }
  }

  Future<void> _loadEditData(String invoiceNumber) async {
    try {
      final invoiceData = await db.DatabaseHelper.instance
          .getInvoiceDataByInvoiceNumber(invoiceNumber);

      if (invoiceData == null) {
        throw Exception('Invoice not found');
      }

      setState(() {
        _isEditMode = true;
        _editingInvoiceNumber = invoiceNumber;
        _invoiceNumber = invoiceNumber; // Explicitly set display invoice number

        // Set zamindar by name
        final zamindarName = invoiceData['zamindarName'] as String;
        _selectedZamindar = _zamindars.firstWhere(
          (z) => z.name == zamindarName,
          orElse: () => _zamindars.first,
        );
        _zamindarSearchController.text = _selectedZamindar?.name ?? '';

        // Set kisaan by name if exists
        final kisaanName = invoiceData['kisaanName'] as String?;
        if (kisaanName != null && _selectedZamindar != null) {
          _selectedKisaan = _selectedZamindar!.kisaans.firstWhere(
            (k) => k.name == kisaanName,
            orElse: () => _selectedZamindar!.kisaans.firstWhere(
              (k) => k.name == 'Self',
              orElse: () => _selectedZamindar!.kisaans.first,
            ),
          );
        }

        // Set payment method
        _paymentMethod = (invoiceData['isCredit'] as bool)
            ? PaymentMethod.credit
            : PaymentMethod.cash;

        _selectedSalePaymentTerm = invoiceData['paymentTerm'] as String?;
        final collected =
            (invoiceData['totalCollected'] as num?)?.toDouble() ?? 0.0;
        _cashReceivedController.text = collected > 0
            ? collected.toStringAsFixed(0)
            : '0';

        // Set date time
        _selectedDateTime = DateTime.parse(invoiceData['dateTime'] as String);
        _isDateTimeLocked = true;

        // Load cart items
        final items = invoiceData['items'] as List<Map<String, dynamic>>;
        _cartItems.clear();
        for (final item in items) {
          final productName = item['productName'] as String;
          final product = _products.firstWhere(
            (p) => p.name == productName,
            orElse: () => _products.first,
          );

          _cartItems.add(
            CartItem(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              product: product,
              quantity: ((item['qty'] as num).toDouble()).round(),
              seasonalIncrement: _paymentMethod == PaymentMethod.credit
                  ? (item['seasonalIncrement'] as num?)?.toDouble() ?? 0
                  : 0,
              discount: (item['discount'] as num?)?.toDouble() ?? 0,
            ),
          );
        }
      });

      if (_selectedKisaan != null) {
        await _loadSmartRecommendations();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invoice loaded for editing'),
            backgroundColor: SaleColors.darkGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load invoice: $e'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Zamindar _convertZamindar(db.Zamindar dbZamindar, List<Kisaan> kisaans) {
    return Zamindar(
      id: dbZamindar.id?.toString() ?? '0',
      name: dbZamindar.name,
      location: dbZamindar.locationGoth ?? dbZamindar.village ?? 'Unknown',
      kisaanCount: dbZamindar.activeKisaans,
      isOverLimit: dbZamindar.isOverLimit,
      paymentTerms: List<String>.from(dbZamindar.paymentTerms),
      whatsappNumber: dbZamindar.whatsappNumber,
      kisaans: kisaans,
    );
  }

  Kisaan _convertKisaan(db.Kisaan dbKisaan) {
    return Kisaan(
      id: dbKisaan.id?.toString() ?? '0',
      name: dbKisaan.name,
      village: dbKisaan.village,
      crop: dbKisaan.currentCrop,
      acres: dbKisaan.landAcres,
      zamindarId: dbKisaan.zamindarId.toString(),
    );
  }

  Product _convertProduct(db.ProductItem dbProduct) {
    ProductType type;
    final productType = dbProduct.productType.toLowerCase();
    if (productType.contains('fertilizer')) {
      type = ProductType.fertilizer;
    } else if (productType.contains('pesticide') ||
        productType.contains('herbicide')) {
      type = ProductType.pesticide;
    } else if (productType.contains('seed')) {
      type = ProductType.seed;
    } else {
      type = ProductType.other;
    }

    return Product(
      id: dbProduct.id?.toString() ?? '0',
      name: dbProduct.name,
      type: type,
      basePrice: dbProduct.retailPrice.toDouble(),
      unit: dbProduct.uom,
    );
  }

  ProductWithStock _toStockAwareProduct(db.ProductItem dbProduct) {
    final base = _convertProduct(dbProduct);
    return ProductWithStock(
      id: base.id,
      name: base.name,
      type: base.type,
      basePrice: base.basePrice,
      unit: base.unit,
      availableStock: dbProduct.availableStock,
    );
  }

  Map<String, int> _cartQuantitiesByProductId() {
    final map = <String, int>{};
    for (final item in _cartItems) {
      map[item.product.id] = (map[item.product.id] ?? 0) + item.quantity;
    }
    return map;
  }

  void _clearSmartRecommendations() {
    _recommendationsRequestId++;
    _smartRecommendations = [];
    _isLoadingRecommendations = false;
    _recommendationStageLabel = null;
  }

  /// Season-stage, purchase-deduped, in-stock Smart Recommendations.
  Future<void> _loadSmartRecommendations() async {
    final kisaan = _selectedKisaan;
    final zamindar = _selectedZamindar;
    if (kisaan == null || zamindar == null) {
      if (!mounted) return;
      setState(_clearSmartRecommendations);
      return;
    }

    final requestId = ++_recommendationsRequestId;
    setState(() {
      _isLoadingRecommendations = true;
      _recommendationStageLabel = SeasonUtils.seasonStageLabel();
    });

    try {
      final season = SeasonUtils.getSeasonString(DateTime.now());
      final results = await Future.wait([
        db.DatabaseHelper.instance.getProductsInStock(),
        db.DatabaseHelper.instance.getKisaanSeasonPurchaseLineItems(
          zamindarName: zamindar.name,
          kisaanName: kisaan.name,
          season: season,
        ),
      ]);

      if (!mounted || requestId != _recommendationsRequestId) return;

      final inStockDb = results[0] as List<db.ProductItem>;
      final purchased = results[1] as List<Map<String, dynamic>>;
      final inStockProducts = inStockDb.map(_toStockAwareProduct).toList();

      final built = SmartRecommendationEngine.build(
        kisaan: kisaan,
        inStockProducts: inStockProducts,
        purchasedLineItems: purchased,
        cartQuantitiesByProductId: _cartQuantitiesByProductId(),
      );

      if (!mounted || requestId != _recommendationsRequestId) return;
      setState(() {
        _smartRecommendations = built.map((r) => r.toRecommendation()).toList();
        _isLoadingRecommendations = false;
        _recommendationStageLabel = SeasonUtils.seasonStageLabel();
      });
    } catch (e) {
      debugPrint('Error loading smart recommendations: $e');
      if (!mounted || requestId != _recommendationsRequestId) return;
      setState(() {
        _smartRecommendations = [];
        _isLoadingRecommendations = false;
      });
    }
  }

  Future<void> _selectTransactionDate() async {
    final now = DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDateTime,
      firstDate: DateTime(2020),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: SaleColors.darkGreen,
              onPrimary: Colors.white,
              onSurface: SaleColors.textDark,
            ),
          ),
          child: child!,
        );
      },
    );

    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_selectedDateTime),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: SaleColors.darkGreen,
              onPrimary: Colors.white,
              onSurface: SaleColors.textDark,
            ),
          ),
          child: child!,
        );
      },
    );

    if (pickedTime == null || !mounted) return;

    setState(() {
      _selectedDateTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
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

  // Helper method to get actual product stock from database
  Future<db.ProductItem?> _getProductFromDatabase(String productId) async {
    final id = int.tryParse(productId);
    if (id == null) return null;
    return await db.DatabaseHelper.instance.getProduct(id);
  }

  // Helper method to check if product has sufficient stock
  Future<bool> _checkProductStock(Product product, int requestedQty) async {
    final dbProduct = await _getProductFromDatabase(product.id);
    if (dbProduct == null) return false;

    final availableStock = dbProduct.availableStock;

    // Check if out of stock
    if (availableStock == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ ${product.name} is OUT OF STOCK!'),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return false;
    }

    // Check if requested quantity exceeds available stock
    if (requestedQty > availableStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '⚠️ ${product.name}: Only $availableStock ${product.unit} available! Requested: $requestedQty',
          ),
          backgroundColor: Colors.orange,
          duration: Duration(minutes: 1),
        ),
      );
      return false;
    }

    // Check if stock is low (below threshold)
    if (availableStock <= dbProduct.lowStockThreshold) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '⚠️ LOW STOCK ALERT: ${product.name} has only $availableStock ${product.unit} left!',
          ),
          backgroundColor: Colors.orange.shade700,
          duration: Duration(minutes: 1),
        ),
      );
      // Allow adding even if low stock, just show warning
    }

    return true;
  }

  // Helper method to check zamindar credit limit
  Future<void> _checkZamindarCreditLimit(Zamindar zamindar) async {
    final zamindarId = int.tryParse(zamindar.id);
    if (zamindarId == null) return;

    try {
      final balances = await db.DatabaseHelper.instance.getZamindarBalancesSafe(
        zamindarId,
      );

      if (balances == null) return;

      final outstandingBalance = balances['outstandingBalance'] as int;
      final isOverLimit = balances['isOverLimit'] as bool;

      // Show warning if there's outstanding balance or credit limit exceeded
      if (outstandingBalance > 0 || isOverLimit) {
        if (!mounted) return;

        final formattedBalance = outstandingBalance.toStringAsFixed(0);

        if (isOverLimit) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '⚠️ CREDIT LIMIT EXCEEDED: ${zamindar.name} has Rs $formattedBalance outstanding!',
              ),
              backgroundColor: Colors.red.shade700,
              duration: Duration(minutes: 1),
            ),
          );
        } else if (outstandingBalance > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '⚠️ OUTSTANDING AMOUNT: ${zamindar.name} has Rs $formattedBalance pending!',
              ),
              backgroundColor: Colors.orange.shade700,
              duration: Duration(minutes: 1),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error checking zamindar credit limit: $e');
    }
  }

  Future<void> _addProductToCart() async {
    if (_selectedProduct == null) return;

    final qty = int.tryParse(_qtyController.text) ?? 1;
    final price =
        double.tryParse(_priceController.text.replaceAll(',', '')) ?? 0;
    final seasonalInc =
        double.tryParse(
          _seasonalIncrementController.text.replaceAll(',', ''),
        ) ??
        0;

    // Check stock before adding to cart
    final hasStock = await _checkProductStock(_selectedProduct!, qty);
    if (!hasStock) return; // Don't add to cart if out of stock or insufficient

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

  Future<void> _addRecommendation(Recommendation rec) async {
    final qty = rec.quantity.round();
    if (qty <= 0) return;

    // Check stock before adding to cart
    final hasStock = await _checkProductStock(rec.product, qty);
    if (!hasStock) return; // Don't add to cart if out of stock or insufficient

    setState(() {
      _cartItems.add(
        CartItem(
          id: 'c${DateTime.now().millisecondsSinceEpoch}',
          product: rec.product,
          quantity: qty,
          seasonalIncrement: 0,
          discount: 0,
        ),
      );
    });

    // Refresh remaining allowances after cart append.
    await _loadSmartRecommendations();
  }

  void _removeCartItem(String id) {
    setState(() {
      _cartItems.removeWhere((item) => item.id == id);
    });
    if (_selectedKisaan != null) {
      _loadSmartRecommendations();
    }
  }

  void _updateCartItemQuantity(String id, int change) {
    setState(() {
      final item = _cartItems.firstWhere((i) => i.id == id);
      final newQty = item.quantity + change;
      if (newQty > 0) {
        item.quantity = newQty;
      }
    });
    if (_selectedKisaan != null) {
      _loadSmartRecommendations();
    }
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
      _selectedSalePaymentTerm = null;
      _cashReceivedController.text = '0';
      _zamindarSearchController.clear();
      _kisaanSearchController.clear();
      _clearSmartRecommendations();
    });
  }

  List<Kisaan> _filteredKisaans() {
    final kisaans = _selectedZamindar?.kisaans ?? const <Kisaan>[];
    final query = _kisaanSearchController.text.trim().toLowerCase();
    if (query.isEmpty) return kisaans;

    return kisaans.where((kisaan) {
      return kisaan.name.toLowerCase().contains(query) ||
          kisaan.village.toLowerCase().contains(query) ||
          kisaan.crop.toLowerCase().contains(query);
    }).toList();
  }

  /// Clears edit/preselect state in the parent Shell, fetches the next invoice
  /// number, and resets every form field so the screen is ready for a new sale.
  Future<void> _resetFormForNewSale({bool notifyParent = true}) async {
    try {
      if (notifyParent) {
        // Clears Shell's editInvoiceNumber / preselects. Key change may dispose
        // this State and create a fresh NewSaleScreen — check mounted after.
        widget.onCancelEdit?.call();
      }

      final nextInvoice = await db.DatabaseHelper.instance
          .getNextInvoiceNumber();

      debugPrint('🔄 RESET FORM: next invoice = $nextInvoice');

      if (!mounted) return;

      setState(() {
        _isEditMode = false;
        _editingInvoiceNumber = null;
        _invoiceNumber = nextInvoice;

        _cartItems.clear();
        _selectedZamindar = null;
        _selectedKisaan = null;
        _selectedProduct = null;
        _clearSmartRecommendations();
        _overallDiscount = 0;
        _overallDiscountController.text = '0';
        _zamindarSearchController.clear();
        _kisaanSearchController.clear();
        _productSearchController.clear();
        _qtyController.text = '1';
        _priceController.text = '0';
        _seasonalIncrementController.text = '0';

        _isDateTimeLocked = false;
        _selectedDateTime = DateTime.now();

        _isWalkInCustomer = false;
        _walkInCustomerNameController.clear();

        _paymentMethod = PaymentMethod.credit;
        _selectedSalePaymentTerm = null;
        _cashReceivedController.text = '0';
        _checkoutMode = _CheckoutMode.productSale;
        _advanceKind = _AdvanceKind.cash;
        _advanceAmountController.clear();
        _advanceLitersController.clear();
        _advanceRemarksController.clear();
      });
    } catch (e) {
      debugPrint('Error resetting sale form: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to refresh form: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  bool get _isAdvanceMode => _checkoutMode == _CheckoutMode.cashFuelAdvance;

  bool get _isFuelAdvance =>
      _advanceKind == _AdvanceKind.diesel ||
      _advanceKind == _AdvanceKind.petrol;

  String get _advanceTransactionType {
    switch (_advanceKind) {
      case _AdvanceKind.cash:
        return db.SaleTransactionType.cashAdvance;
      case _AdvanceKind.diesel:
        return db.SaleTransactionType.dieselAdvance;
      case _AdvanceKind.petrol:
        return db.SaleTransactionType.petrolAdvance;
    }
  }

  String get _advanceDisplayLabel {
    switch (_advanceKind) {
      case _AdvanceKind.cash:
        return 'Cash Advance';
      case _AdvanceKind.diesel:
        return 'Diesel Advance';
      case _AdvanceKind.petrol:
        return 'Petrol Advance';
    }
  }

  double get _advanceAmountValue {
    return double.tryParse(
          _advanceAmountController.text.replaceAll(RegExp(r'[^0-9.]'), ''),
        ) ??
        0;
  }

  double? get _advanceLitersValue {
    final parsed = double.tryParse(
      _advanceLitersController.text.replaceAll(RegExp(r'[^0-9.]'), ''),
    );
    return parsed;
  }

  void _enterAdvanceMode() {
    setState(() {
      _checkoutMode = _CheckoutMode.cashFuelAdvance;
      _isWalkInCustomer = false;
      _walkInCustomerNameController.clear();
      _paymentMethod = PaymentMethod.credit;
      _selectedSalePaymentTerm = 'After Harvest';
      _cashReceivedController.text = '0';
      _overallDiscount = 0;
      _overallDiscountController.text = '0';
      _cartItems.clear();
      _selectedProduct = null;
      _productSearchController.clear();
      _clearSmartRecommendations();
    });
  }

  void _enterProductSaleMode() {
    setState(() {
      _checkoutMode = _CheckoutMode.productSale;
      if (_selectedZamindar != null &&
          _selectedZamindar!.paymentTerms.length == 1) {
        _selectedSalePaymentTerm = _selectedZamindar!.paymentTerms.first;
      } else if (_selectedSalePaymentTerm == 'After Harvest' &&
          !(_selectedZamindar?.paymentTerms.contains('After Harvest') ??
              false)) {
        _selectedSalePaymentTerm = null;
      }
    });
  }

  /// Handles the Discard button action.
  Future<void> _handleDiscard() async {
    await _resetFormForNewSale();
  }

  /// Strips formatting and normalizes Pakistani mobile numbers for wa.me.
  static String? _normalizeWhatsAppNumber(String? raw) {
    if (raw == null) return null;
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    if (digits.startsWith('00')) {
      digits = digits.substring(2);
    }
    if (digits.startsWith('0') && digits.length == 11) {
      digits = '92${digits.substring(1)}';
    } else if (digits.length == 10 && digits.startsWith('3')) {
      digits = '92$digits';
    }
    if (digits.length < 10) return null;
    return digits;
  }

  LedgerEntry _buildInvoiceLedgerEntry({
    required String invoiceNumber,
    required String zamindarName,
    required String? kisaanName,
    required double totalPayable,
    required double paidAmount,
    required String seasonString,
    required bool isWalkIn,
  }) {
    final items = _cartItems.map((cartItem) {
      final seasonalInc = _paymentMethod == PaymentMethod.credit
          ? cartItem.seasonalIncrement
          : 0.0;
      return LineItem(
        productName: cartItem.product.name,
        quantity: cartItem.quantity.toDouble(),
        unit: cartItem.product.unit,
        unitPrice: cartItem.product.basePrice,
        seasonalIncrement: seasonalInc,
        discount: cartItem.discount,
      );
    }).toList();

    final PaymentStatus status;
    if (paidAmount <= 0) {
      status = PaymentStatus.unpaid;
    } else if (paidAmount + 0.001 >= totalPayable) {
      status = PaymentStatus.paid;
    } else {
      status = PaymentStatus.partial;
    }

    return LedgerEntry(
      id: 0,
      invoiceNumber: invoiceNumber,
      date: _selectedDateTime,
      stakeholderName: zamindarName,
      kisaanName: kisaanName,
      items: items,
      total: totalPayable,
      paid: paidAmount,
      status: status,
      season: seasonString,
      isWalkInCustomer: isWalkIn,
    );
  }

  Future<void> _shareInvoiceWhatsAppPdf({
    required LedgerEntry entry,
    required bool isEdited,
    String? whatsappNumber,
  }) async {
    final file = await PdfGenerator.saveInvoiceToFile(
      entry,
      isEdited: isEdited,
    );

    final message =
        'Invoice ${entry.invoiceNumber} — ${entry.stakeholderName}\n'
        'Total: Rs ${entry.total.toStringAsFixed(0)}\n'
        'Paid: Rs ${entry.paid.toStringAsFixed(0)}\n'
        'Outstanding: Rs ${entry.outstanding.toStringAsFixed(0)}\n'
        'AgriKhata';

    await PdfShare.sharePdfFile(
      file: file,
      fileName: 'invoice_${entry.invoiceNumber}.pdf',
      text: message,
      subject: 'AgriKhata Invoice ${entry.invoiceNumber}',
    );

    final phone = _normalizeWhatsAppNumber(whatsappNumber);
    if (phone != null) {
      final uri = Uri.parse(
        'https://wa.me/$phone?text=${Uri.encodeComponent(message)}',
      );
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'PDF ready. Could not open WhatsApp for $phone — '
              'pick WhatsApp in the share sheet.',
            ),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'PDF ready to share. No WhatsApp number on file for this customer.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _saveAndPrint() => _completeSale();

  Future<void> _saveAndWhatsAppPdf() => _completeSale(shareWhatsAppPdf: true);

  Future<void> _completeSale({bool shareWhatsAppPdf = false}) async {
    if (_isAdvanceMode) {
      await _completeKisaanAdvance(shareWhatsAppPdf: shareWhatsAppPdf);
      return;
    }

    // Validation: Check if Walk-In Customer or Zamindar is selected
    if (!_isWalkInCustomer && _selectedZamindar == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a Zamindar or enable Walk-In Customer'),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return;
    }

    // Validation: Check if Walk-In Customer name is provided
    if (_isWalkInCustomer &&
        _walkInCustomerNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter customer name for walk-in customer'),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return;
    }

    // Validation: Check if cart has items
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cart is empty. Please add products to the cart.'),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return;
    }

    final summary = _getSummary();
    final double totalPayable = summary.totalPayable;
    double cashReceived = 0;
    if (_paymentMethod == PaymentMethod.credit) {
      cashReceived =
          double.tryParse(
            _cashReceivedController.text.replaceAll(RegExp(r'[^0-9.]'), ''),
          ) ??
          0;
      if (cashReceived < 0) cashReceived = 0;
      if (cashReceived > totalPayable) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cash received cannot exceed total payable'),
            backgroundColor: Colors.red,
            duration: Duration(minutes: 1),
          ),
        );
        return;
      }
      if (!_isWalkInCustomer &&
          (_selectedZamindar?.paymentTerms.isNotEmpty ?? false) &&
          (_selectedSalePaymentTerm == null ||
              _selectedSalePaymentTerm!.isEmpty)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select a payment term for this credit sale'),
            backgroundColor: Colors.red,
            duration: Duration(minutes: 1),
          ),
        );
        return;
      }
    }

    // Start saving
    setState(() => _isSaving = true);

    try {
      // ========================================================
      // STEP 1: Extract and Format Metadata Fields from UI State
      // ========================================================

      // Invoice Number - Get from database to ensure uniqueness
      final String invoiceNumber = _isEditMode
          ? _editingInvoiceNumber!
          : await db.DatabaseHelper.instance.getNextInvoiceNumber();

      // Zamindar Name
      final String zamindarName = _isWalkInCustomer
          ? _walkInCustomerNameController.text.trim()
          : _selectedZamindar!.name;

      // Kisaan Name
      final String? kisaanName = _selectedKisaan?.name ?? 'Self';

      // Financial Breakdown
      final double subtotal = summary.subtotal;
      final double itemDiscountsTotal = summary.itemDiscounts;
      final double seasonalIncrementTotal =
          _paymentMethod == PaymentMethod.credit
          ? summary.totalSeasonalIncrements
          : 0.0;
      final double overallDiscount = _overallDiscount;
      // Credit: cash received is immediate payment; remainder is udhaar.
      // Cash: full amount is paid (advance wallet may draw down inside insertSale).
      final double paidAmount = _paymentMethod == PaymentMethod.cash
          ? totalPayable
          : cashReceived;
      final String paymentMethod = _paymentMethod == PaymentMethod.cash
          ? 'Cash'
          : 'Credit';
      final String? paymentTerm = _paymentMethod == PaymentMethod.credit
          ? _selectedSalePaymentTerm
          : null;

      debugPrint(
        'SALE DEBUG: Invoice=$invoiceNumber, Zamindar=$zamindarName, Kisaan=$kisaanName',
      );
      debugPrint(
        'SALE DEBUG: Subtotal=$subtotal, ItemDisc=$itemDiscountsTotal, SeasonalInc=$seasonalIncrementTotal',
      );
      debugPrint(
        'SALE DEBUG: OverallDisc=$overallDiscount, TotalPayable=$totalPayable, Paid=$paidAmount, Term=$paymentTerm',
      );

      // ========================================================
      // STEP 2: Convert Cart Items to New Schema Format
      // ========================================================

      final saleItems = _cartItems.map((cartItem) {
        final productId = int.tryParse(cartItem.product.id);

        // Calculate effective unit price (base + seasonal increment for credit sales)
        final double basePrice = cartItem.product.basePrice;
        final double seasonalInc = _paymentMethod == PaymentMethod.credit
            ? cartItem.seasonalIncrement
            : 0.0;
        final double effectiveUnitPrice = basePrice + seasonalInc;

        return db.SaleLineItem(
          productId: productId,
          productName: cartItem.product.name,
          qty: cartItem.quantity.toDouble(),
          unitPrice: effectiveUnitPrice,
          discount: cartItem.discount,
        );
      }).toList();

      // Get product type from first cart item (or default to 'Fertilizer')
      final String productType = _cartItems.isNotEmpty
          ? _cartItems.first.product.type.toString().split('.').last
          : 'Fertilizer';

      // Get season string for the selected date
      final String seasonString = SeasonUtils.getSeasonString(
        _selectedDateTime,
      );

      debugPrint(
        'SALE DEBUG: Converted ${saleItems.length} cart items to SaleLineItem format',
      );
      debugPrint('SALE DEBUG: Season=$seasonString');

      // ========================================================
      // STEP 3: Save to New Three-Table Schema
      // ========================================================

      if (_isEditMode && _editingInvoiceNumber != null) {
        // UPDATE EXISTING SALE
        debugPrint(
          'SALE DEBUG: Updating existing sale with invoice=$invoiceNumber',
        );

        await db.DatabaseHelper.instance.updateSaleInNewSchema(
          invoiceNumber: invoiceNumber,
          dateTime: _selectedDateTime,
          zamindarName: zamindarName,
          kisaanName: kisaanName,
          items: saleItems,
          overallDiscount: overallDiscount,
          paidAmount: paidAmount,
          paymentMethod: paymentMethod,
          productType: productType,
          season: seasonString,
          paymentTerm: paymentTerm,
        );

        debugPrint('SALE DEBUG: Successfully updated sale in new schema');
      } else {
        // INSERT NEW SALE
        debugPrint(
          'SALE DEBUG: Inserting new sale with invoice=$invoiceNumber',
        );

        final checkoutResult = await db.DatabaseHelper.instance.insertSale(
          invoiceNumber: invoiceNumber,
          dateTime: _selectedDateTime,
          zamindarName: zamindarName,
          kisaanName: kisaanName,
          items: saleItems,
          overallDiscount: overallDiscount,
          paidAmount: paidAmount,
          paymentMethod: paymentMethod,
          productType: productType,
          season: seasonString,
          paymentTerm: paymentTerm,
        );

        debugPrint('SALE DEBUG: Successfully inserted sale into new schema');

        if (checkoutResult['hadAdvanceDeduction'] == true) {
          AdvanceCheckoutOverlay.instance.show(
            zamindarName: checkoutResult['zamindarName'] as String,
            kisaanName: checkoutResult['kisaanName'] as String?,
            totalAdvanceBefore: (checkoutResult['totalAdvanceBefore'] as num)
                .toDouble(),
            deductedAmount: (checkoutResult['deductedAmount'] as num)
                .toDouble(),
            remainingAdvance: (checkoutResult['remainingAdvance'] as num)
                .toDouble(),
            remainingPhysicalCash:
                (checkoutResult['remainingPhysicalCash'] as num).toDouble(),
          );
        }
      }

      // ========================================================
      // STEP 4: WhatsApp PDF (optional), then Success & Reset UI
      // ========================================================

      if (!mounted) return;

      final wasEditMode = _isEditMode;
      final whatsappNumber = _isWalkInCustomer
          ? null
          : _selectedZamindar?.whatsappNumber;

      if (shareWhatsAppPdf) {
        try {
          final entry = _buildInvoiceLedgerEntry(
            invoiceNumber: invoiceNumber,
            zamindarName: zamindarName,
            kisaanName: kisaanName,
            totalPayable: totalPayable,
            paidAmount: paidAmount,
            seasonString: seasonString,
            isWalkIn: _isWalkInCustomer,
          );
          await _shareInvoiceWhatsAppPdf(
            entry: entry,
            isEdited: wasEditMode,
            whatsappNumber: whatsappNumber,
          );
        } catch (e) {
          debugPrint('WhatsApp PDF share failed: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Sale saved, but PDF/WhatsApp share failed: $e'),
                backgroundColor: Colors.orange.shade800,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      }

      if (!mounted) return;

      final actionText = wasEditMode ? 'updated' : 'saved';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shareWhatsAppPdf
                ? 'Sale $actionText & invoice PDF ready. Total: Rs ${totalPayable.toStringAsFixed(0)}'
                : 'Sale $actionText successfully! Total: Rs ${totalPayable.toStringAsFixed(0)}',
          ),
          backgroundColor: SaleColors.darkGreen,
          duration: Duration(seconds: 3),
        ),
      );

      // Unlock UI before reset/sync (_syncReferenceData skips while saving).
      setState(() => _isSaving = false);

      // Must clear Shell editInvoiceNumber — otherwise reload re-enters edit
      // mode and the old invoice number sticks on screen.
      await _resetFormForNewSale();

      // If parent key-recreated this screen, we're done (fresh init loads data).
      if (!mounted) return;

      // Refresh stock / reference lists without reloading edit state.
      try {
        await _syncReferenceData();
      } catch (e) {
        debugPrint('Error syncing reference data after save: $e');
      }

      // TODO: Add thermal printer / receipt generation logic here
    } catch (e, stackTrace) {
      debugPrint('❌ CRITICAL ERROR saving sale: $e');
      debugPrint('Stack trace: $stackTrace');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save sale: $e'),
            backgroundColor: Colors.red,
            duration: Duration(minutes: 1),
          ),
        );
      }
    } finally {
      // CRITICAL: Always stop the loading indicator in the finally block
      // This prevents the infinite progress indicator deadlock
      if (mounted && _isSaving) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _completeKisaanAdvance({bool shareWhatsAppPdf = false}) async {
    if (_isEditMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot record an advance while editing an invoice'),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return;
    }

    if (_isWalkInCustomer || _selectedZamindar == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Select a Zamindar (and Kisaan) before saving a Cash / Fuel Advance',
          ),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return;
    }

    final zamindarId = int.tryParse(_selectedZamindar!.id);
    if (zamindarId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid Zamindar selection'),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return;
    }

    final amount = _advanceAmountValue;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid Total Value (Rs.) greater than zero'),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return;
    }

    final liters = _advanceLitersValue;
    if (_isFuelAdvance && (liters == null || liters <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter Quantity (Liters) for this fuel advance'),
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final invoiceNumber = await db.DatabaseHelper.instance
          .getNextInvoiceNumber();
      final zamindarName = _selectedZamindar!.name;
      final kisaanName = _selectedKisaan?.name ?? 'Self';
      final kisaanId = _selectedKisaan != null
          ? int.tryParse(_selectedKisaan!.id)
          : null;
      final seasonString = SeasonUtils.getSeasonString(_selectedDateTime);
      final transactionType = _advanceTransactionType;
      final remarks = _advanceRemarksController.text.trim();

      debugPrint(
        'ADVANCE DEBUG: Invoice=$invoiceNumber type=$transactionType '
        'amount=$amount liters=$liters zamindarId=$zamindarId kisaanId=$kisaanId',
      );

      await db.DatabaseHelper.instance.insertKisaanAdvance(
        invoiceNumber: invoiceNumber,
        dateTime: _selectedDateTime,
        zamindarId: zamindarId,
        zamindarName: zamindarName,
        kisaanId: kisaanId,
        kisaanName: kisaanName,
        transactionType: transactionType,
        amount: amount,
        fuelQuantityLiters: _isFuelAdvance ? liters : null,
        remarks: remarks.isEmpty ? null : remarks,
        season: seasonString,
      );

      if (!mounted) return;

      final whatsappNumber = _selectedZamindar?.whatsappNumber;
      if (shareWhatsAppPdf) {
        try {
          final entry = _buildAdvanceLedgerEntry(
            invoiceNumber: invoiceNumber,
            zamindarName: zamindarName,
            kisaanName: kisaanName,
            totalPayable: amount,
            seasonString: seasonString,
            liters: _isFuelAdvance ? liters : null,
            remarks: remarks,
          );
          await _shareInvoiceWhatsAppPdf(
            entry: entry,
            isEdited: false,
            whatsappNumber: whatsappNumber,
          );
        } catch (e) {
          debugPrint('WhatsApp PDF share failed: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Advance saved, but PDF/WhatsApp share failed: $e',
                ),
                backgroundColor: Colors.orange.shade800,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shareWhatsAppPdf
                ? '$_advanceDisplayLabel saved & invoice PDF ready. '
                      'Total: Rs ${amount.toStringAsFixed(0)}'
                : '$_advanceDisplayLabel saved on khata. '
                      'Total: Rs ${amount.toStringAsFixed(0)}',
          ),
          backgroundColor: SaleColors.darkGreen,
          duration: const Duration(seconds: 3),
        ),
      );

      setState(() => _isSaving = false);
      await _resetFormForNewSale();
      if (!mounted) return;

      try {
        await _syncReferenceData();
      } catch (e) {
        debugPrint('Error syncing reference data after advance save: $e');
      }
    } catch (e, stackTrace) {
      debugPrint('❌ CRITICAL ERROR saving advance: $e');
      debugPrint('Stack trace: $stackTrace');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save advance: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(minutes: 1),
          ),
        );
      }
    } finally {
      if (mounted && _isSaving) {
        setState(() => _isSaving = false);
      }
    }
  }

  LedgerEntry _buildAdvanceLedgerEntry({
    required String invoiceNumber,
    required String zamindarName,
    required String? kisaanName,
    required double totalPayable,
    required String seasonString,
    double? liters,
    required String remarks,
  }) {
    final label = liters != null
        ? '$_advanceDisplayLabel (${liters.toStringAsFixed(liters == liters.roundToDouble() ? 0 : 2)} L)'
        : _advanceDisplayLabel;
    final description = remarks.isNotEmpty ? '$label — $remarks' : label;

    return LedgerEntry(
      id: 0,
      invoiceNumber: invoiceNumber,
      date: _selectedDateTime,
      stakeholderName: zamindarName,
      kisaanName: kisaanName ?? 'Self',
      items: [
        LineItem(
          productName: description,
          quantity: 1,
          unit: liters != null ? 'L' : 'advance',
          unitPrice: totalPayable,
          seasonalIncrement: 0,
          discount: 0,
        ),
      ],
      total: totalPayable,
      paid: 0,
      status: PaymentStatus.unpaid,
      season: seasonString,
      isWalkInCustomer: false,
      description: description,
      purchaseTerms: 'After Harvest',
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
    _kisaanSearchController.dispose();
    _productSearchController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    _seasonalIncrementController.dispose();
    _overallDiscountController.dispose();
    _walkInCustomerNameController.dispose();
    _cashReceivedController.dispose();
    _advanceAmountController.dispose();
    _advanceLitersController.dispose();
    _advanceRemarksController.dispose();
    // Remove database listener to prevent memory leaks
    db.DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
        ),
      ),
      child: Scaffold(
        backgroundColor: SaleColors.canvasBg,
        body: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                    SaleColors.darkGreen,
                  ),
                ),
              )
            : Column(
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
      ),
    );
  }

  Widget _buildTransactionDateCard() {
    final dateFormat = DateFormat('EEE, d MMM yyyy');
    final timeFormat = DateFormat('h:mm a');
    final isToday =
        DateFormat('yyyy-MM-dd').format(_selectedDateTime) ==
        DateFormat('yyyy-MM-dd').format(DateTime.now());
    final displayDate = isToday
        ? 'Today · ${timeFormat.format(_selectedDateTime)}'
        : '${dateFormat.format(_selectedDateTime)} · ${timeFormat.format(_selectedDateTime)}';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _selectTransactionDate,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: SaleColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _isDateTimeLocked
                  ? SaleColors.darkGreen
                  : (isToday ? SaleColors.borderLight : SaleColors.accentGreen),
              width: _isDateTimeLocked ? 1.5 : (isToday ? 0.5 : 1),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _isDateTimeLocked
                        ? SaleColors.darkGreen.withOpacity(0.15)
                        : (isToday
                              ? SaleColors.paleGreen
                              : SaleColors.lightGreenBg),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Icon(
                      _isDateTimeLocked
                          ? Icons.lock_clock
                          : Icons.calendar_today,
                      size: 15,
                      color: _isDateTimeLocked
                          ? SaleColors.darkGreen
                          : (isToday
                                ? SaleColors.midGreen
                                : SaleColors.darkGreen),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Transaction Date',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: SaleColors.textMuted,
                            ),
                          ),
                          if (_isDateTimeLocked) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: SaleColors.darkGreen.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'LOCKED',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: SaleColors.darkGreen,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 1),
                      Text(
                        displayDate,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _isDateTimeLocked
                              ? SaleColors.darkGreen
                              : (isToday
                                    ? SaleColors.textDark
                                    : SaleColors.darkGreen),
                        ),
                      ),
                    ],
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _isDateTimeLocked = !_isDateTimeLocked;
                      });
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: _isDateTimeLocked
                            ? SaleColors.darkGreen
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _isDateTimeLocked
                              ? SaleColors.darkGreen
                              : SaleColors.borderMid,
                          width: 0.5,
                        ),
                      ),
                      child: Icon(
                        _isDateTimeLocked ? Icons.lock : Icons.lock_open,
                        size: 14,
                        color: _isDateTimeLocked
                            ? Colors.white
                            : SaleColors.textLight,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.edit_calendar,
                  size: 18,
                  color: _isDateTimeLocked
                      ? SaleColors.darkGreen
                      : (isToday ? SaleColors.textLight : SaleColors.darkGreen),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final dateFormat = DateFormat('EEEE, d MMMM yyyy');
    final timeFormat = DateFormat('h:mm a');
    final isToday =
        DateFormat('yyyy-MM-dd').format(_selectedDateTime) ==
        DateFormat('yyyy-MM-dd').format(DateTime.now());
    final displayDate = isToday
        ? 'Today · ${timeFormat.format(_selectedDateTime)}'
        : dateFormat.format(_selectedDateTime);
    final season = SeasonUtils.getSeasonString(_selectedDateTime);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
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
                  '$displayDate — $season Season',
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
              _invoiceNumber,
              style: const TextStyle(fontSize: 12, color: SaleColors.textLight),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _handleDiscard,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: SaleColors.cardBg,
                  border: Border.all(color: SaleColors.borderMid, width: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'Discard',
                  style: TextStyle(fontSize: 13, color: SaleColors.textDark),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isSaving ? null : _saveAndPrint,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _isSaving
                      ? SaleColors.darkGreen.withOpacity(0.6)
                      : SaleColors.darkGreen,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isSaving)
                      const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    else
                      const Icon(Icons.check, size: 13, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      _isSaving ? 'Saving...' : 'Save & Print',
                      style: const TextStyle(
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
      width: 360,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: SingleChildScrollView(
        child: Column(
          children: [
            _buildTransactionDateCard(),
            const SizedBox(height: 10),
            if (!_isAdvanceMode) ...[
              _buildWalkInToggleCard(),
              const SizedBox(height: 10),
            ],
            if (!_isWalkInCustomer) ...[
              _buildSelectZamindarCard(),
              const SizedBox(height: 10),
              if (_selectedZamindar != null) ...[
                _buildSelectKisaanCard(),
                if (!_isAdvanceMode) ...[
                  const SizedBox(height: 10),
                  _buildSmartRecommendationsCard(),
                ],
              ],
            ] else ...[
              _buildWalkInCustomerNameCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRightColumn() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 14, 12),
      child: SingleChildScrollView(
        child: Column(
          children: [
            _buildCheckoutModeToggle(),
            const SizedBox(height: 10),
            if (_isAdvanceMode) ...[
              _buildCashFuelAdvanceCard(),
              const SizedBox(height: 10),
              _buildSummaryCard(),
            ] else ...[
              _buildAddProductCard(),
              const SizedBox(height: 10),
              _buildCartCard(),
              const SizedBox(height: 10),
              _buildSummaryCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCheckoutModeToggle() {
    final advanceDisabled = _isEditMode || _isWalkInCustomer;

    return Container(
      decoration: BoxDecoration(
        color: SaleColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SaleColors.borderLight, width: 0.5),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildModeChip(
                  label: '🛒 Product Sale',
                  selected: !_isAdvanceMode,
                  onTap: () {
                    if (_isAdvanceMode) _enterProductSaleMode();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildModeChip(
                  label: '💸 Cash / Fuel Advance',
                  selected: _isAdvanceMode,
                  enabled: !advanceDisabled,
                  onTap: () {
                    if (!_isAdvanceMode && !advanceDisabled) {
                      _enterAdvanceMode();
                    }
                  },
                ),
              ),
            ],
          ),
          if (advanceDisabled) ...[
            const SizedBox(height: 6),
            Text(
              _isEditMode
                  ? 'Advance mode is unavailable while editing an invoice.'
                  : 'Disable Walk-In Customer to record a Kisaan advance.',
              style: const TextStyle(fontSize: 11, color: SaleColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? SaleColors.lightGreenBg : SaleColors.canvasBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? SaleColors.accentGreen : SaleColors.borderMid,
                width: selected ? 1 : 0.5,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: SaleColors.textDark,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCashFuelAdvanceCard() {
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
          const StepHeader(stepNumber: 3, title: 'Cash / Fuel Advance'),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Advance Type',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                InputDecorator(
                  decoration: _advanceInputDecoration(),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<_AdvanceKind>(
                      value: _advanceKind,
                      isExpanded: true,
                      isDense: true,
                      items: const [
                        DropdownMenuItem(
                          value: _AdvanceKind.cash,
                          child: Text('💵 Cash Advance'),
                        ),
                        DropdownMenuItem(
                          value: _AdvanceKind.diesel,
                          child: Text('⛽ Diesel Advance'),
                        ),
                        DropdownMenuItem(
                          value: _AdvanceKind.petrol,
                          child: Text('🏍️ Petrol Advance'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _advanceKind = value;
                          if (value == _AdvanceKind.cash) {
                            _advanceLitersController.clear();
                          }
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Total Value (Rs.)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                TextFormField(
                  controller: _advanceAmountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: SaleColors.textDark,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: _advanceInputDecoration(
                    hintText: '0',
                    prefixText: 'Rs ',
                    prominentFocus: true,
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _isFuelAdvance
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Quantity (Liters)',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: SaleColors.textMuted,
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextFormField(
                                controller: _advanceLitersController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: SaleColors.textDark,
                                ),
                                onChanged: (_) => setState(() {}),
                                decoration: _advanceInputDecoration(
                                  hintText: 'e.g. 20',
                                  suffixText: 'L',
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Remarks / Purpose',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                TextFormField(
                  controller: _advanceRemarksController,
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 13,
                    color: SaleColors.textDark,
                  ),
                  decoration: _advanceInputDecoration(
                    hintText:
                        'e.g. For tractor harvesting, Emergency household cash',
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF3DE),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: SaleColors.borderMid, width: 0.5),
                  ),
                  child: const Text(
                    'Debt settles on the Zamindar khata after harvest. '
                    'Cash advances reduce Cash in Hand; fuel does not.',
                    style: TextStyle(
                      fontSize: 11,
                      color: SaleColors.midGreen,
                      height: 1.35,
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

  InputDecoration _advanceInputDecoration({
    String? hintText,
    String? prefixText,
    String? suffixText,
    bool prominentFocus = false,
  }) {
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: SaleColors.cardBg,
      hintText: hintText,
      hintStyle: const TextStyle(fontSize: 13, color: SaleColors.textLight),
      prefixText: prefixText,
      prefixStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: SaleColors.textDark,
      ),
      suffixText: suffixText,
      suffixStyle: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: SaleColors.textMuted,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
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
        borderSide: BorderSide(
          color: SaleColors.accentGreen,
          width: prominentFocus ? 2 : 1.5,
        ),
      ),
    );
  }

  Widget _buildWalkInToggleCard() {
    return Container(
      decoration: BoxDecoration(
        color: _isWalkInCustomer ? const Color(0xFFFFF9E6) : SaleColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _isWalkInCustomer
              ? const Color(0xFFFFD54F)
              : SaleColors.borderLight,
          width: _isWalkInCustomer ? 1 : 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              _isWalkInCustomer ? Icons.storefront : Icons.person_outline,
              size: 19,
              color: _isWalkInCustomer
                  ? const Color(0xFFF57C00)
                  : SaleColors.darkGreen,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Walk-In / Cash Customer',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _isWalkInCustomer
                          ? const Color(0xFFF57C00)
                          : SaleColors.textDark,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _isWalkInCustomer
                        ? 'Cash only, no credit'
                        : 'Enable for walk-in customers',
                    style: TextStyle(
                      fontSize: 11,
                      color: _isWalkInCustomer
                          ? const Color(0xFFE65100)
                          : SaleColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _isWalkInCustomer,
              onChanged: (value) {
                setState(() {
                  _isWalkInCustomer = value;
                  if (value) {
                    // Force cash payment for walk-in
                    _paymentMethod = PaymentMethod.cash;
                    _checkoutMode = _CheckoutMode.productSale;
                    // Clear zamindar selection
                    _selectedZamindar = null;
                    _selectedKisaan = null;
                    _zamindarSearchController.clear();
                    _kisaanSearchController.clear();
                    _clearSmartRecommendations();
                    _advanceAmountController.clear();
                    _advanceLitersController.clear();
                    _advanceRemarksController.clear();
                  } else {
                    // Clear walk-in customer name
                    _walkInCustomerNameController.clear();
                  }
                });
              },
              activeThumbColor: const Color(0xFFF57C00),
              activeTrackColor: const Color(0xFFFFD54F),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWalkInCustomerNameCard() {
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
          const StepHeader(stepNumber: 1, title: 'Customer Name'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  children: [
                    Text(
                      'Customer Name',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: SaleColors.textMuted,
                      ),
                    ),
                    SizedBox(width: 2),
                    Text(
                      '*',
                      style: TextStyle(fontSize: 11, color: Color(0xFFE24B4A)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                TextFormField(
                  controller: _walkInCustomerNameController,
                  style: const TextStyle(
                    fontSize: 13,
                    color: SaleColors.textDark,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter customer name (e.g., Ahmed Ali)...',
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: SaleColors.textLight,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(
                        color: SaleColors.borderMid,
                        width: 0.5,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(
                        color: SaleColors.borderMid,
                        width: 0.5,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(
                        color: SaleColors.accentGreen,
                        width: 1,
                      ),
                    ),
                    filled: true,
                    fillColor: SaleColors.cardBg,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: const [
                      Icon(
                        Icons.info_outline,
                        size: 13,
                        color: Color(0xFF1565C0),
                      ),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Walk-in customers are cash-only. No credit option available.',
                          style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
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
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildZamindarAutocomplete(),
                if (_selectedZamindar != null) _buildZamindarPillWithClear(),
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
              style: TextStyle(fontSize: 11, color: Color(0xFFE24B4A)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Autocomplete<Zamindar>(
          optionsBuilder: (TextEditingValue textEditingValue) {
            if (textEditingValue.text.isEmpty) {
              return const Iterable<Zamindar>.empty();
            }
            return _zamindars.where((Zamindar zamindar) {
              return zamindar.name.toLowerCase().contains(
                textEditingValue.text.toLowerCase(),
              );
            });
          },
          displayStringForOption: (Zamindar option) => option.name,
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            _zamindarSearchController.text = controller.text;
            return TextFormField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(fontSize: 13, color: SaleColors.textDark),
              decoration: InputDecoration(
                hintText: 'Type to search Zamindar (e.g. Asif, Zafar)...',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: SaleColors.textLight,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(
                    color: SaleColors.borderMid,
                    width: 0.5,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(
                    color: SaleColors.borderMid,
                    width: 0.5,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(
                    color: SaleColors.accentGreen,
                    width: 1,
                  ),
                ),
                filled: true,
                fillColor: SaleColors.cardBg,
              ),
            );
          },
          onSelected: (Zamindar selection) {
            setState(() {
              _selectedZamindar = selection;
              _kisaanSearchController.clear();
              _selectedSalePaymentTerm = selection.paymentTerms.length == 1
                  ? selection.paymentTerms.first
                  : null;
              // Auto-select 'Self' Kisaan
              if (selection.kisaans.isNotEmpty) {
                _selectedKisaan = selection.kisaans.firstWhere(
                  (k) => k.name == 'Self',
                  orElse: () => selection.kisaans.first,
                );
              } else {
                _selectedKisaan = null;
                _clearSmartRecommendations();
              }
            });
            // Check credit limit after selection
            _checkZamindarCreditLimit(selection);
            if (_selectedKisaan != null) {
              _loadSmartRecommendations();
            }
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(9),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 160,
                    maxWidth: 318,
                  ),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final option = options.elementAt(index);
                      return InkWell(
                        onTap: () => onSelected(option),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: SaleColors.borderLight,
                                width: 0.5,
                              ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: SaleColors.lightGreenBg,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
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
                child: Icon(Icons.clear, size: 18, color: SaleColors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectKisaanCard() {
    final filteredKisaans = _filteredKisaans();
    final hasAnyKisaans = _selectedZamindar!.kisaans.isNotEmpty;

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
            padding: const EdgeInsets.all(12),
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
                TextFormField(
                  controller: _kisaanSearchController,
                  style: const TextStyle(
                    fontSize: 13,
                    color: SaleColors.textDark,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search by name, village, or crop...',
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: SaleColors.textLight,
                    ),
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 18,
                      color: SaleColors.textMuted,
                    ),
                    suffixIcon: _kisaanSearchController.text.isNotEmpty
                        ? IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(
                              Icons.close,
                              size: 16,
                              color: SaleColors.textMuted,
                            ),
                            onPressed: () {
                              setState(() {
                                _kisaanSearchController.clear();
                              });
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(
                        color: SaleColors.borderMid,
                        width: 0.5,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(
                        color: SaleColors.borderMid,
                        width: 0.5,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(
                        color: SaleColors.accentGreen,
                        width: 1,
                      ),
                    ),
                    filled: true,
                    fillColor: SaleColors.cardBg,
                  ),
                ),
                const SizedBox(height: 8),
                if (!hasAnyKisaans)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No kisaans found',
                      style: TextStyle(
                        fontSize: 12,
                        color: SaleColors.textMuted,
                      ),
                    ),
                  )
                else if (filteredKisaans.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No kisaans match your search',
                      style: TextStyle(
                        fontSize: 12,
                        color: SaleColors.textMuted,
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const AlwaysScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 1.85,
                          ),
                      itemCount: filteredKisaans.length,
                      itemBuilder: (context, index) {
                        final kisaan = filteredKisaans[index];
                        return KisaanCard(
                          kisaan: kisaan,
                          isSelected: _selectedKisaan?.id == kisaan.id,
                          onTap: () {
                            setState(() {
                              _selectedKisaan = kisaan;
                            });
                            _loadSmartRecommendations();
                          },
                        );
                      },
                    ),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            padding: const EdgeInsets.all(12),
            child: SmartRecommendationsBox(
              selectedKisaan: _selectedKisaan,
              recommendations: _smartRecommendations,
              onAddRecommendation: _addRecommendation,
              isLoading: _isLoadingRecommendations,
              stageLabel: _recommendationStageLabel,
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
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(flex: 4, child: _buildProductAutocomplete()),
                const SizedBox(width: 8),
                SizedBox(
                  width: 64,
                  child: _buildCompactField(
                    'Qty',
                    _qtyController,
                    TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 84,
                  child: _buildCompactField(
                    'Price',
                    _priceController,
                    TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 88,
                  child: _buildCompactField(
                    'Seasonal Inc',
                    _seasonalIncrementController,
                    TextInputType.number,
                  ),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
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
        const SizedBox(height: 4),
        Autocomplete<Product>(
          optionsBuilder: (TextEditingValue textEditingValue) {
            if (textEditingValue.text.isEmpty) {
              return const Iterable<Product>.empty();
            }
            return _products.where((Product product) {
              return product.name.toLowerCase().contains(
                textEditingValue.text.toLowerCase(),
              );
            });
          },
          displayStringForOption: (Product option) => option.name,
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            _productSearchController.text = controller.text;
            return TextFormField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(fontSize: 13, color: SaleColors.textDark),
              decoration: InputDecoration(
                hintText: 'Search or select product...',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: SaleColors.textLight,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(
                    color: SaleColors.borderMid,
                    width: 0.5,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(
                    color: SaleColors.borderMid,
                    width: 0.5,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(
                    color: SaleColors.accentGreen,
                    width: 1,
                  ),
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: SaleColors.borderLight,
                                width: 0.5,
                              ),
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

  Widget _buildCompactField(
    String label,
    TextEditingController controller,
    TextInputType keyboardType,
  ) {
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
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          style: const TextStyle(fontSize: 13, color: SaleColors.textDark),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 8,
            ),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.borderMid,
                width: 0.5,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.borderMid,
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.accentGreen,
                width: 1,
              ),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              padding: EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              child: Center(
                child: Text(
                  'No items in cart',
                  style: TextStyle(fontSize: 13, color: SaleColors.textMuted),
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
        horizontalMargin: 10,
        columnSpacing: 14,
        headingRowHeight: 32,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 40,
        headingRowColor: WidgetStateProperty.all(SaleColors.canvasBg),
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
          const DataColumn(label: SizedBox.shrink()),
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
              DataCell(ProductTypeBadge(type: item.product.type)),
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
                    onChanged: (val) =>
                        _updateCartItemSeasonalIncrement(item.id, val),
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
                        border: Border.all(
                          color: SaleColors.borderLight,
                          width: 0.5,
                        ),
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
    final showSeasonalIncrement =
        !_isAdvanceMode && _paymentMethod == PaymentMethod.credit;
    final totalPayable = _isAdvanceMode
        ? _advanceAmountValue
        : summary.totalPayable;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: SaleColors.darkGreen,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isAdvanceMode) ...[
            _buildSummaryRow(_advanceDisplayLabel, totalPayable),
            if (_isFuelAdvance && (_advanceLitersValue ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Quantity',
                      style: TextStyle(
                        fontSize: 12,
                        color: SaleColors.textLight,
                      ),
                    ),
                    Text(
                      '${_advanceLitersValue!.toStringAsFixed((_advanceLitersValue! == _advanceLitersValue!.roundToDouble()) ? 0 : 2)} L',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
          ] else ...[
            _buildSummaryRow('Subtotal', summary.subtotal),
            _buildSummaryRow('Item Discounts', summary.itemDiscounts),
            if (showSeasonalIncrement)
              _buildSummaryRow(
                'Seasonal Increment Total',
                summary.totalSeasonalIncrements,
              ),
            _buildOverallDiscountRow(),
          ],
          Container(
            height: 0.5,
            margin: const EdgeInsets.symmetric(vertical: 7),
            color: Colors.white.withOpacity(0.15),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total payable',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
              Text(
                CurrencyFormatter.format(totalPayable),
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.lightGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_isAdvanceMode)
            _buildLockedAdvancePaymentTerms(totalPayable)
          else ...[
            PaymentMethodToggle(
              selectedMethod: _paymentMethod,
              onChanged: !_isWalkInCustomer
                  ? (method) {
                      setState(() {
                        _paymentMethod = method;
                        if (method == PaymentMethod.cash) {
                          _selectedSalePaymentTerm = null;
                          _cashReceivedController.text = '0';
                        } else if (_selectedZamindar != null &&
                            _selectedZamindar!.paymentTerms.length == 1) {
                          _selectedSalePaymentTerm =
                              _selectedZamindar!.paymentTerms.first;
                        }
                      });
                    }
                  : (method) {},
            ),
            if (_paymentMethod == PaymentMethod.credit &&
                !_isWalkInCustomer) ...[
              const SizedBox(height: 10),
              _buildCreditSplitSection(summary.totalPayable),
            ],
          ],
          const SizedBox(height: 10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isSaving ? null : _saveAndPrint,
              borderRadius: BorderRadius.circular(9),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _isSaving
                      ? SaleColors.accentGreen.withOpacity(0.6)
                      : SaleColors.accentGreen,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isSaving)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    else
                      const Icon(Icons.check, size: 14, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      _isSaving ? 'Saving...' : 'Save & Print receipt',
                      style: const TextStyle(
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
          const SizedBox(height: 5),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isSaving ? null : _saveAndWhatsAppPdf,
              borderRadius: BorderRadius.circular(9),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isSaving)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            SaleColors.textLight,
                          ),
                        ),
                      )
                    else
                      const Icon(
                        Icons.picture_as_pdf_outlined,
                        size: 14,
                        color: SaleColors.textLight,
                      ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _isSaving
                            ? 'Saving & sharing...'
                            : _isWalkInCustomer
                            ? 'WhatsApp PDF to ${_walkInCustomerNameController.text.isNotEmpty ? _walkInCustomerNameController.text : "Customer"}'
                            : 'WhatsApp PDF to ${_selectedZamindar?.name ?? "Zamindar"}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: SaleColors.textLight,
                        ),
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

  Widget _buildSummaryRow(String label, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: SaleColors.textLight),
          ),
          Text(
            CurrencyFormatter.format(value),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLockedAdvancePaymentTerms(double totalPayable) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: SaleColors.lightGreen.withOpacity(0.55),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: SaleColors.lightGreen,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.lock_outline,
                  size: 13,
                  color: SaleColors.darkGreen,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Credit (Udhaar)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Locked for Cash / Fuel Advances',
                      style: TextStyle(
                        fontSize: 11,
                        color: SaleColors.textLight,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Credit (Udhaar)',
              style: TextStyle(fontSize: 11, color: SaleColors.textLight),
            ),
            Text(
              CurrencyFormatter.format(totalPayable),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: SaleColors.lightGreen,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Payment term',
          style: TextStyle(fontSize: 11, color: SaleColors.textLight),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: ChoiceChip(
            label: const Text('After Harvest'),
            selected: true,
            onSelected: (_) {},
            labelStyle: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: SaleColors.darkGreen,
            ),
            selectedColor: SaleColors.lightGreen,
            backgroundColor: Colors.white.withOpacity(0.08),
            side: const BorderSide(color: SaleColors.lightGreen, width: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 2),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }

  Widget _buildCreditSplitSection(double totalPayable) {
    final cashReceived =
        double.tryParse(
          _cashReceivedController.text.replaceAll(RegExp(r'[^0-9.]'), ''),
        ) ??
        0;
    final creditAmount = (totalPayable - cashReceived).clamp(0.0, totalPayable);
    final terms = _selectedZamindar?.paymentTerms ?? const <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Cash received',
          style: TextStyle(fontSize: 12, color: SaleColors.textLight),
        ),
        const SizedBox(height: 5),
        Theme(
          data: Theme.of(context).copyWith(
            textSelectionTheme: TextSelectionThemeData(
              cursorColor: SaleColors.darkGreen,
              selectionColor: SaleColors.accentGreen.withOpacity(0.35),
              selectionHandleColor: SaleColors.darkGreen,
            ),
          ),
          child: TextFormField(
            controller: _cashReceivedController,
            keyboardType: TextInputType.number,
            cursorColor: SaleColors.darkGreen,
            style: const TextStyle(
              color: Color(0xFF1B4332),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              prefixText: 'Rs ',
              prefixStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1B4332),
              ),
              hintText: '0',
              hintStyle: const TextStyle(
                fontSize: 13,
                color: Color(0xFF95B89A),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: Colors.white.withOpacity(0.25),
                  width: 0.5,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: SaleColors.lightGreen,
                  width: 1,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Credit (Udhaar)',
              style: TextStyle(fontSize: 11, color: SaleColors.textLight),
            ),
            Text(
              CurrencyFormatter.format(creditAmount),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: SaleColors.lightGreen,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Payment term',
          style: TextStyle(fontSize: 11, color: SaleColors.textLight),
        ),
        const SizedBox(height: 4),
        if (terms.isEmpty)
          Text(
            'No payment terms on this Zamindar profile',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(0.55),
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: terms.map((term) {
              final selected = _selectedSalePaymentTerm == term;
              return ChoiceChip(
                label: Text(term),
                selected: selected,
                onSelected: (_) {
                  setState(() => _selectedSalePaymentTerm = term);
                },
                labelStyle: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: selected ? SaleColors.darkGreen : SaleColors.textLight,
                ),
                selectedColor: SaleColors.lightGreen,
                backgroundColor: Colors.white.withOpacity(0.08),
                side: BorderSide(
                  color: selected
                      ? SaleColors.lightGreen
                      : Colors.white.withOpacity(0.25),
                  width: 0.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildOverallDiscountRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Overall Discount',
            style: TextStyle(fontSize: 12, color: SaleColors.textLight),
          ),
          SizedBox(
            width: 76,
            child: TextField(
              controller: _overallDiscountController,
              textAlign: TextAlign.right,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 12, color: Colors.white),
              cursorColor: SaleColors.lightGreen,
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 2,
                ),
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

extension FirstOrNullExtension<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
