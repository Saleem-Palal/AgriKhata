import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../controllers/sale_controller.dart';
import '../models/sale_models.dart';
import '../models/ledger_models.dart';
import '../models/product_model.dart';
import '../Widgets/sale_widgets.dart';
import '../Widgets/sales/print_success_dialog.dart';
import '../Widgets/sales/pos_confirm_dialog.dart';
import '../Database/database_helper.dart' as db;
import '../services/partner_service.dart';
import '../services/print_service.dart';
import '../services/session_context.dart';
import '../services/whatsapp_urdu_service.dart';
import '../services/season_service.dart';
import '../utils/season_utils.dart';
import '../utils/smart_recommendations.dart';
import '../utils/advance_checkout_overlay.dart';
import '../utils/shop_settings.dart';
import '../theme/theme.dart';

enum _PartnerPricePreset { cost, retail, seasonal }

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
  final SaleController _saleController = SaleController();
  final TextEditingController _zamindarSearchController =
      TextEditingController();
  final TextEditingController _kisaanSearchController = TextEditingController();
  final TextEditingController _productSearchController =
      TextEditingController();

  /// Autocomplete's internal field controller / focus — used to clear & unfocus.
  TextEditingController? _zamindarFieldController;
  FocusNode? _zamindarAutocompleteFocusNode;

  /// Owned by this screen so search text clear ≠ product selection clear.
  final FocusNode _productFocusNode = FocusNode(debugLabel: 'productSearch');
  final FocusNode _screenFocusNode = FocusNode(debugLabel: 'newSaleScreen');
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
  final TextEditingController _descriptionController =
      TextEditingController();

  // State
  Zamindar? _selectedZamindar;
  Kisaan? _selectedKisaan;
  Product? _selectedProduct;
  final List<CartItem> _cartItems = [];
  String? _selectedCartItemId;
  PaymentMethod _paymentMethod = PaymentMethod.credit;
  String? _selectedSalePaymentTerm;
  double _overallDiscount = 0;
  String _invoiceNumber =
      'INV-1000'; // Display only - actual number generated at save time
  bool _isWalkInCustomer = false;
  bool _isPartnerSelfUse = false;
  _PartnerPricePreset _partnerPricePreset = _PartnerPricePreset.cost;
  DateTime _selectedDateTime = DateTime.now();
  bool _isDateTimeLocked = false;
  bool _isEditMode = false;
  String? _editingInvoiceNumber;
  _CheckoutMode _checkoutMode = _CheckoutMode.productSale;
  _AdvanceKind _advanceKind = _AdvanceKind.cash;

  // Database data
  List<Zamindar> _zamindars = [];
  List<Zamindar> _frequentZamindars = [];
  List<Product> _products = [];
  bool _isLoading = true;
  bool _isSaving = false;
  /// Sync lock so Enter + button click cannot double-submit before setState.
  bool _checkoutLock = false;

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

  @override
  void didUpdateWidget(covariant NewSaleScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Leaving edit mode (parent cleared editInvoiceNumber) must flush cart so
    // prior invoice lines never bleed into the next fresh sale.
    if (oldWidget.editInvoiceNumber != null &&
        widget.editInvoiceNumber == null) {
      _flushEditSessionIntoFreshSale();
    } else if (widget.editInvoiceNumber != null &&
        widget.editInvoiceNumber != oldWidget.editInvoiceNumber) {
      _loadEditData(widget.editInvoiceNumber!);
    }
  }

  void _flushEditSessionIntoFreshSale() {
    SaleController.flushCartSession(cartItems: _cartItems);
    setState(() {
      _isEditMode = false;
      _editingInvoiceNumber = null;
      _selectedCartItemId = null;
      _isDateTimeLocked = false;
      _selectedDateTime = DateTime.now();
      _overallDiscount = 0;
      _overallDiscountController.text = '0';
      _paymentMethod = PaymentMethod.credit;
      _selectedSalePaymentTerm = null;
      _cashReceivedController.text = '0';
      _checkoutMode = _CheckoutMode.productSale;
      _advanceKind = _AdvanceKind.cash;
    });
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
          _zamindarFieldController?.clear();
          _smartRecommendations = [];
          _recommendationStageLabel = null;
        } else if (refreshedZamindar != null) {
          _selectedZamindar = refreshedZamindar;
          _selectedKisaan = refreshedKisaan;
          // Search field is hidden while selected — keep it empty.
          _zamindarSearchController.clear();
          _zamindarFieldController?.clear();
        }
      });
      await _refreshFrequentZamindars();
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
          // Search field is hidden while selected — keep it empty.
          _zamindarSearchController.clear();
          _zamindarFieldController?.clear();

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
        if (_isEditMode || _editingInvoiceNumber != null) {
          SaleController.flushCartSession(cartItems: _cartItems);
        }
        setState(() {
          _isEditMode = false;
          _editingInvoiceNumber = null;
          _selectedCartItemId = null;
        });
      }

      if (_selectedZamindar != null) {
        await _refreshPartnerSelfUseFlag(_selectedZamindar);
      }
      await _refreshFrequentZamindars();
      if (_selectedKisaan != null) {
        await _loadSmartRecommendations();
      }
    } catch (e) {
      debugPrint('Error loading data from database: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        AppToast.showError(context, 'Failed to load data: $e');
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

      final seasonLabel = invoiceData['season'] as String?;
      await db.DatabaseHelper.instance.assertSeasonEditable(seasonLabel);

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
        // Search field is hidden while selected — keep it empty.
        _zamindarSearchController.clear();
        _zamindarFieldController?.clear();

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
        final saleOriginCash =
            (invoiceData['saleOriginCashCollected'] as num?)?.toDouble() ??
            (invoiceData['paidAmount'] as num?)?.toDouble() ??
            0.0;
        _cashReceivedController.text = saleOriginCash > 0
            ? saleOriginCash.toStringAsFixed(0)
            : '0';

        // Optional transaction notes (sales.description).
        _descriptionController.text =
            (invoiceData['description'] as String?)?.trim() ?? '';

        // Set date time
        _selectedDateTime = DateTime.parse(invoiceData['dateTime'] as String);
        _isDateTimeLocked = true;

        // Load cart items — each line gets a unique id (never share a timestamp).
        // Persist base + seasonal separately (insertSale stores both columns).
        final items = invoiceData['items'] as List<Map<String, dynamic>>;
        _cartItems.clear();
        _selectedCartItemId = null;
        for (final item in items) {
          final productName = item['productName'] as String;
          final soldUnitPrice = moneyRound(
            (item['unitPrice'] as num).toDouble(),
          );
          final seasonalFromDb = moneyRound(
            (item['seasonalIncrement'] as num?)?.toDouble() ?? 0,
          );
          final discount = moneyRound(
            (item['discount'] as num?)?.toDouble() ?? 0,
          );
          final qty = ((item['qty'] as num).toDouble()).round();

          Product? catalog;
          for (final p in _products) {
            if (p.name == productName) {
              catalog = p;
              break;
            }
          }

          // Prefer explicit DB seasonal; otherwise, if After Harvest and the
          // sold price exceeds catalog base, treat the delta as seasonal so
          // re-save does not bake seasonal twice into unit price.
          double basePrice = soldUnitPrice;
          double seasonalInc = seasonalFromDb;
          if (seasonalFromDb > 0) {
            basePrice = moneyRound(soldUnitPrice - seasonalFromDb);
            if (basePrice < 0) basePrice = 0;
          } else if (_selectedSalePaymentTerm == 'After Harvest' &&
              catalog != null &&
              soldUnitPrice > catalog.basePrice) {
            basePrice = moneyRound(catalog.basePrice);
            seasonalInc = moneyRound(soldUnitPrice - catalog.basePrice);
          }

          final product = Product(
            id: catalog?.id ?? '',
            name: productName,
            type: catalog?.type ?? _productTypeFromInvoiceLabel(
              item['productType'] as String?,
            ),
            basePrice: basePrice,
            unit: catalog?.unit ?? 'unit',
            brand: catalog?.brand ?? '',
            costPrice: catalog?.costPrice ?? 0,
            availableStock: catalog?.availableStock ?? 0,
            seasonalIncrement: catalog?.seasonalIncrement ?? 0,
          );

          _cartItems.add(
            CartItem(
              id: _saleController.nextCartItemId(),
              product: product,
              quantity: qty,
              seasonalIncrement:
                  (_selectedSalePaymentTerm == 'After Harvest')
                  ? seasonalInc
                  : 0,
              discount: discount,
            ),
          );
        }
      });

      if (_selectedKisaan != null) {
        await _loadSmartRecommendations();
      }

      if (mounted) {
        AppToast.showSuccess(context, 'Invoice loaded for editing');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to load invoice: $e');
        // Embedded in Shell (not a pushed route) — never Navigator.pop here.
        await _resetFormForNewSale();
      }
    }
  }

  ProductType _productTypeFromInvoiceLabel(String? raw) {
    final label = (raw ?? '').toLowerCase();
    if (label.contains('fertilizer')) return ProductType.fertilizer;
    if (label.contains('pesticide') || label.contains('herbicide')) {
      return ProductType.pesticide;
    }
    if (label.contains('seed')) return ProductType.seed;
    return ProductType.other;
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
      brand: dbProduct.brand,
      costPrice: dbProduct.costPrice.toDouble(),
      availableStock: dbProduct.availableStock,
      seasonalIncrement: dbProduct.seasonalIncrement.toDouble(),
    );
  }

  bool get _showSeasonalIncrement =>
      _paymentMethod == PaymentMethod.credit &&
      _selectedSalePaymentTerm == 'After Harvest';

  void _clearSeasonalIncrements() {
    _seasonalIncrementController.clear();
    for (final item in _cartItems) {
      item.seasonalIncrement = 0;
    }
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
      final season = SeasonService.instance.activeSeasonName ??
          SeasonUtils.getSeasonString(DateTime.now());
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
      // Keep selection + visible name until "+ Add to cart" (or explicit X cancel).
      _selectedProduct = product;
      _productSearchController.text = product.name;
      _syncSelectedProductPriceFields();
    });
  }

  void _cancelProductSelection() {
    _productSearchController.clear();
    setState(() {
      _selectedProduct = null;
    });
  }

  double _resolveUnitPrice(Product product) {
    if (!_isPartnerSelfUse) return product.basePrice;
    switch (_partnerPricePreset) {
      case _PartnerPricePreset.cost:
        return product.costPrice > 0 ? product.costPrice : product.basePrice;
      case _PartnerPricePreset.retail:
        return product.basePrice;
      case _PartnerPricePreset.seasonal:
        return product.basePrice +
            (product.hasSeasonalIncrement ? product.seasonalIncrement : 0);
    }
  }

  Product? _catalogProductById(String id) {
    for (final product in _products) {
      if (product.id == id) return product;
    }
    return null;
  }

  /// Partner Seasonal tier already bakes increment into unit price.
  bool get _partnerSeasonalBakesIncrement =>
      _isPartnerSelfUse && _partnerPricePreset == _PartnerPricePreset.seasonal;

  void _syncSelectedProductPriceFields() {
    final product = _selectedProduct;
    if (product == null) return;

    _priceController.text = _resolveUnitPrice(product).toStringAsFixed(0);
    if (!_showSeasonalIncrement || _partnerSeasonalBakesIncrement) {
      _seasonalIncrementController.text = _partnerSeasonalBakesIncrement
          ? '0'
          : '';
      return;
    }
    _seasonalIncrementController.text = product.hasSeasonalIncrement
        ? product.seasonalIncrement.toStringAsFixed(0)
        : '';
  }

  /// Reprices every cart line from catalog rates for the active partner tier.
  void _repriceCartForPartnerPreset() {
    if (!_isPartnerSelfUse || _cartItems.isEmpty) return;

    for (var i = 0; i < _cartItems.length; i++) {
      final item = _cartItems[i];
      final source = _catalogProductById(item.product.id) ?? item.product;
      final unitPrice = moneyRound(_resolveUnitPrice(source));

      final double lineSeasonal;
      if (!_showSeasonalIncrement || _partnerSeasonalBakesIncrement) {
        lineSeasonal = 0;
      } else if (item.seasonalIncrement > 0 &&
          _partnerPricePreset != _PartnerPricePreset.seasonal) {
        // Keep a user-edited seasonal amount when switching Cost ↔ Retail.
        lineSeasonal = item.seasonalIncrement;
      } else {
        lineSeasonal = source.hasSeasonalIncrement
            ? source.seasonalIncrement
            : 0;
      }

      _cartItems[i] = CartItem(
        id: item.id,
        product: Product(
          id: source.id,
          name: source.name,
          type: source.type,
          basePrice: unitPrice,
          unit: source.unit,
          brand: source.brand,
          costPrice: source.costPrice,
          availableStock: source.availableStock,
          seasonalIncrement: source.seasonalIncrement,
        ),
        quantity: item.quantity,
        seasonalIncrement: moneyRound(lineSeasonal),
        discount: item.discount,
      );
    }
  }

  void _applyPartnerPricePreset(_PartnerPricePreset preset) {
    setState(() {
      _partnerPricePreset = preset;
      _syncSelectedProductPriceFields();
      _repriceCartForPartnerPreset();
    });
  }

  Future<void> _refreshPartnerSelfUseFlag(Zamindar? zamindar) async {
    if (zamindar == null || zamindar.id.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isPartnerSelfUse = false;
        _partnerPricePreset = _PartnerPricePreset.cost;
      });
      return;
    }
    final linked = await PartnerService.instance.isPartnerLinkedZamindar(
      int.tryParse(zamindar.id),
    );
    if (!mounted) return;
    setState(() {
      _isPartnerSelfUse = linked;
      if (linked) {
        _partnerPricePreset = _PartnerPricePreset.cost;
        _syncSelectedProductPriceFields();
        _repriceCartForPartnerPreset();
      }
    });
  }

  // Helper method to get actual product stock from database
  Future<db.ProductItem?> _getProductFromDatabase(String productId) async {
    final id = int.tryParse(productId);
    if (id == null) return null;
    return await db.DatabaseHelper.instance.getProduct(id);
  }

  // Helper method to check if product has sufficient stock.
  // CASH_ADVANCE / FUEL_DISBURSAL never go through this path (advance mode),
  // but we still guard if a zero-margin loan kind is ever passed.
  Future<bool> _checkProductStock(
    Product product,
    int requestedQty, {
    String? serviceKind,
  }) async {
    if (SaleController.bypassesStockValidation(
      serviceKind ?? ProductServiceKind.inventory,
    )) {
      return true;
    }

    final dbProduct = await _getProductFromDatabase(product.id);
    if (dbProduct == null) return false;

    final availableStock = dbProduct.availableStock;

    // Check if out of stock
    if (availableStock == 0) {
      AppToast.showError(context, '❌ ${product.name} is OUT OF STOCK!');
      return false;
    }

    // Check if requested quantity exceeds available stock
    if (requestedQty > availableStock) {
      AppToast.showWarning(
        context,
        '⚠️ ${product.name}: Only $availableStock ${product.unit} available! Requested: $requestedQty',
      );
      return false;
    }

    // Check if stock is low (below threshold)
    if (availableStock <= dbProduct.lowStockThreshold) {
      AppToast.showWarning(
        context,
        '⚠️ LOW STOCK ALERT: ${product.name} has only $availableStock ${product.unit} left!',
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
          AppToast.showError(
            context,
            '⚠️ CREDIT LIMIT EXCEEDED: ${zamindar.name} has Rs $formattedBalance outstanding!',
          );
        } else if (outstandingBalance > 0) {
          AppToast.showWarning(
            context,
            '⚠️ OUTSTANDING AMOUNT: ${zamindar.name} has Rs $formattedBalance pending!',
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
    final price = SaleController.parseMoney(_priceController.text);
    final seasonalInc =
        _showSeasonalIncrement && !_partnerSeasonalBakesIncrement
        ? SaleController.parseMoney(_seasonalIncrementController.text)
        : 0.0;

    // Check stock before adding to cart
    final hasStock = await _checkProductStock(_selectedProduct!, qty);
    if (!hasStock) return; // Don't add to cart if out of stock or insufficient

    setState(() {
      final lineId = _saleController.nextCartItemId();
      _cartItems.add(
        CartItem(
          id: lineId,
          product: Product(
            id: _selectedProduct!.id,
            name: _selectedProduct!.name,
            type: _selectedProduct!.type,
            basePrice: moneyRound(price),
            unit: _selectedProduct!.unit,
            brand: _selectedProduct!.brand,
            costPrice: _selectedProduct!.costPrice,
            availableStock: _selectedProduct!.availableStock,
            seasonalIncrement: _selectedProduct!.seasonalIncrement,
          ),
          quantity: qty,
          seasonalIncrement: moneyRound(seasonalInc),
          discount: 0,
        ),
      );
      _selectedCartItemId = lineId;

      // AFTER cart append: clear search + selection, reset qty for next entry.
      _selectedProduct = null;
      _productSearchController.clear();
      _qtyController.text = '1';
      _priceController.text = '0';
      _seasonalIncrementController.clear();
    });

    // Ready for the next product entry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _productFocusNode.requestFocus();
    });
  }

  Future<void> _addRecommendation(Recommendation rec) async {
    final qty = rec.quantity.round();
    if (qty <= 0) return;

    // Check stock before adding to cart
    final hasStock = await _checkProductStock(rec.product, qty);
    if (!hasStock) return; // Don't add to cart if out of stock or insufficient

    setState(() {
      final lineId = _saleController.nextCartItemId();
      _cartItems.add(
        CartItem(
          id: lineId,
          product: rec.product,
          quantity: qty,
          seasonalIncrement: 0,
          discount: 0,
        ),
      );
      _selectedCartItemId = lineId;
    });

    // Refresh remaining allowances after cart append.
    await _loadSmartRecommendations();
  }

  void _removeCartItem(String id) {
    setState(() {
      SaleController.removeCartItemById(_cartItems, id);
      if (_selectedCartItemId == id) {
        _selectedCartItemId = _cartItems.isNotEmpty
            ? _cartItems.last.id
            : null;
      }
    });
    if (_selectedKisaan != null) {
      _loadSmartRecommendations();
    }
  }

  void _removeSelectedOrLastCartItem() {
    if (_cartItems.isEmpty || _isSaving) return;
    // Delete only — never bind Backspace (it must edit text fields).
    if (_isTypingInTextField) return;
    final id = _selectedCartItemId ?? _cartItems.last.id;
    _removeCartItem(id);
  }

  void _updateCartItemQuantity(String id, int change) {
    setState(() {
      final index = _cartItems.indexWhere((i) => i.id == id);
      if (index < 0) return;
      final item = _cartItems[index];
      final newQty = item.quantity + change;
      if (newQty > 0) {
        item.quantity = newQty;
        _selectedCartItemId = id;
      } else {
        _cartItems.removeAt(index);
        if (_selectedCartItemId == id) {
          _selectedCartItemId = _cartItems.isNotEmpty
              ? _cartItems.last.id
              : null;
        }
      }
    });
    if (_selectedKisaan != null) {
      _loadSmartRecommendations();
    }
  }

  void _updateCartItemDiscount(String id, double discount) {
    setState(() {
      final index = _cartItems.indexWhere((i) => i.id == id);
      if (index < 0) return;
      _cartItems[index].discount = moneyRound(discount);
      _selectedCartItemId = id;
    });
  }

  void _updateCartItemSeasonalIncrement(String id, double increment) {
    setState(() {
      final index = _cartItems.indexWhere((i) => i.id == id);
      if (index < 0) return;
      _cartItems[index].seasonalIncrement = moneyRound(increment);
      _selectedCartItemId = id;
    });
  }

  void _clearZamindarSelection() {
    setState(() {
      _selectedZamindar = null;
      _selectedKisaan = null;
      _selectedSalePaymentTerm = null;
      _isPartnerSelfUse = false;
      _cashReceivedController.text = '0';
      _zamindarSearchController.clear();
      _zamindarFieldController?.clear();
      _kisaanSearchController.clear();
      _clearSmartRecommendations();
    });
    // Autocomplete is remounted when selection is cleared — focus after rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _zamindarAutocompleteFocusNode?.requestFocus();
    });
  }

  List<Kisaan> _filteredKisaans() {
    final kisaans = List<Kisaan>.from(
      _selectedZamindar?.kisaans ?? const <Kisaan>[],
    );
    final query = _kisaanSearchController.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? kisaans
        : kisaans.where((kisaan) {
            return kisaan.name.toLowerCase().contains(query) ||
                kisaan.village.toLowerCase().contains(query) ||
                kisaan.crop.toLowerCase().contains(query);
          }).toList();

    // Pin the selected Kisaan to the top of the list.
    final selectedId = _selectedKisaan?.id;
    if (selectedId != null) {
      filtered.sort((a, b) {
        if (a.id == selectedId) return -1;
        if (b.id == selectedId) return 1;
        return 0;
      });
    }
    return filtered;
  }

  Future<void> _refreshFrequentZamindars() async {
    try {
      final ids = await db.DatabaseHelper.instance.getTopFrequentZamindarIds();
      if (!mounted) return;
      final matched = <Zamindar>[];
      for (final id in ids) {
        final idStr = id.toString();
        for (final zamindar in _zamindars) {
          if (zamindar.id == idStr) {
            matched.add(zamindar);
            break;
          }
        }
      }
      if (!mounted) return;
      setState(() => _frequentZamindars = matched);
    } catch (e) {
      debugPrint('Error loading frequent zamindars: $e');
    }
  }

  void _applyZamindarSelection(Zamindar selection) {
    _zamindarFieldController?.clear();
    _zamindarSearchController.clear();
    _zamindarAutocompleteFocusNode?.unfocus();

    setState(() {
      _selectedZamindar = selection;
      _kisaanSearchController.clear();
      _selectedSalePaymentTerm = selection.paymentTerms.length == 1
          ? selection.paymentTerms.first
          : null;
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
    _checkZamindarCreditLimit(selection);
    _refreshPartnerSelfUseFlag(selection);
    if (_selectedKisaan != null) {
      _loadSmartRecommendations();
    }
  }

  /// Clears edit/preselect state in the parent Shell, fetches the next invoice
  /// number, and resets form fields so the screen is ready for a new sale.
  ///
  /// When [retainPartySelection] is true (post-checkout), Zamindar + Kisaan
  /// stay selected so the next cart can be started immediately for the same party.
  Future<void> _resetFormForNewSale({
    bool notifyParent = true,
    bool retainPartySelection = false,
  }) async {
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

      final retainedZamindar =
          retainPartySelection && !_isWalkInCustomer ? _selectedZamindar : null;
      final retainedKisaan =
          retainPartySelection && !_isWalkInCustomer ? _selectedKisaan : null;
      final retainedPaymentTerm =
          retainPartySelection && !_isWalkInCustomer
          ? _selectedSalePaymentTerm
          : null;
      final retainedPaymentMethod =
          retainPartySelection && !_isWalkInCustomer
          ? _paymentMethod
          : PaymentMethod.credit;
      final retainedPartnerSelfUse =
          retainPartySelection && !_isWalkInCustomer ? _isPartnerSelfUse : false;
      final retainedPartnerPreset =
          retainPartySelection && !_isWalkInCustomer
          ? _partnerPricePreset
          : _PartnerPricePreset.cost;

      setState(() {
        _isEditMode = false;
        _editingInvoiceNumber = null;
        _invoiceNumber = nextInvoice;

        SaleController.flushCartSession(cartItems: _cartItems);
        _selectedCartItemId = null;
        _selectedProduct = null;
        _clearSmartRecommendations();
        _overallDiscount = 0;
        _overallDiscountController.text = '0';
        _productSearchController.clear();
        _qtyController.text = '1';
        _priceController.text = '0';
        _seasonalIncrementController.clear();

        _isDateTimeLocked = false;
        _selectedDateTime = DateTime.now();

        _isWalkInCustomer = false;
        _walkInCustomerNameController.clear();

        _checkoutMode = _CheckoutMode.productSale;
        _advanceKind = _AdvanceKind.cash;
        _advanceAmountController.clear();
        _advanceLitersController.clear();
        _advanceRemarksController.clear();
        _descriptionController.clear();
        _cashReceivedController.text = '0';

        if (retainedZamindar != null) {
          _selectedZamindar = retainedZamindar;
          _selectedKisaan = retainedKisaan;
          _selectedSalePaymentTerm = retainedPaymentTerm;
          _paymentMethod = retainedPaymentMethod;
          _isPartnerSelfUse = retainedPartnerSelfUse;
          _partnerPricePreset = retainedPartnerPreset;
        } else {
          _selectedZamindar = null;
          _selectedKisaan = null;
          _selectedSalePaymentTerm = null;
          _paymentMethod = PaymentMethod.credit;
          _isPartnerSelfUse = false;
          _partnerPricePreset = _PartnerPricePreset.cost;
          _zamindarSearchController.clear();
          _zamindarFieldController?.clear();
          _kisaanSearchController.clear();
        }
      });

      if (retainedKisaan != null) {
        await _loadSmartRecommendations();
      }
    } catch (e) {
      debugPrint('Error resetting sale form: $e');
      if (mounted) {
        AppToast.showError(context, 'Failed to refresh form: $e');
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

  /// Handles the Discard button action (with confirm).
  Future<void> _handleDiscard() async {
    if (_isSaving || _isLoading) return;
    final confirmed = await PosConfirmDialog.ask(
      context: context,
      title: 'Discard this sale?',
      message:
          'Clear all fields and cart items? This cannot be undone.\n\n'
          'Press Enter for Yes, Esc for No.',
      yesLabel: 'Yes — Clear (Enter)',
      noLabel: 'No (Esc)',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    await _resetFormForNewSale();
  }

  /// Esc shortcut: never wipe the cart while typing in a field.
  Future<void> _handleEscapeShortcut() async {
    if (_isSaving || _isLoading) return;
    if (_isTypingInTextField) {
      // Blur the field instead of discarding the whole sale.
      FocusManager.instance.primaryFocus?.unfocus();
      _screenFocusNode.requestFocus();
      return;
    }
    await _handleDiscard();
  }

  LedgerEntry _buildInvoiceLedgerEntry({
    required String invoiceNumber,
    required String zamindarName,
    required String? kisaanName,
    required double totalPayable,
    required double paidAmount,
    required String seasonString,
    required bool isWalkIn,
    String? description,
  }) {
    final items = _cartItems.map((cartItem) {
      final seasonalInc = _showSeasonalIncrement
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

    final note = description?.trim();
    final summary = _getSummary();
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
      description: (note != null && note.isNotEmpty) ? note : null,
      transactionType: 'PRODUCT_SALE',
      grossSubtotal: summary.subtotal - summary.totalSeasonalIncrements,
      seasonalIncrementTotal:
          _showSeasonalIncrement ? summary.totalSeasonalIncrements : 0,
      itemDiscountsTotal: summary.itemDiscounts,
      overallDiscount: _overallDiscount,
      createdByUserId: SessionContext.userId,
      createdByUserName: SessionContext.footprintLabel,
      createdAt: DateTime.now(),
    );
  }

  Future<void> _shareInvoiceWhatsAppReceipt({
    required LedgerEntry entry,
    String? whatsappNumber,
  }) async {
    final phone = whatsappNumber?.trim() ?? '';
    if (WhatsAppUrduService.normalizePhone(phone) == null) {
      if (mounted) {
        AppToast.showWarning(
          context,
          'No WhatsApp number on file for this customer.',
        );
      }
      return;
    }

    final shopName = await ShopSettings.getShopName();
    final shopPhone = await ShopSettings.getShopPhone();
    final shopAddress = await ShopSettings.getShopAddress();
    final itemsSummary = entry.items.map((item) {
      final qty = item.quantity == item.quantity.roundToDouble()
          ? item.quantity.toStringAsFixed(0)
          : item.quantity.toStringAsFixed(2);
      return '${item.productName} × $qty ${item.unit} = Rs ${item.total.toStringAsFixed(0)}';
    }).toList();

    final launched = await WhatsAppUrduService.sendSaleReceipt(
      phone: phone,
      zamindarName: entry.stakeholderName,
      shopName: shopName,
      shopPhone: shopPhone,
      shopAddress: shopAddress,
      invoiceNo: entry.invoiceNumber,
      totalAmount: entry.total,
      itemsSummary: itemsSummary,
      servedBy: entry.createdByUserName,
    );

    if (!launched && mounted) {
      AppToast.showWarning(context, 'Could not open WhatsApp for this number.');
    }
  }

  Future<void> _saveAndPrint() => _completeSale();

  Future<void> _saveAndWhatsAppPdf() => _completeSale(shareWhatsAppPdf: true);

  Future<void> _showPostCheckoutPrintDialog({
    required LedgerEntry entry,
    required bool isCreditSale,
    required bool isEdited,
  }) async {
    final action = await PrintSuccessDialog.show(
      context: context,
      invoiceNumber: entry.invoiceNumber,
      stakeholderName: entry.stakeholderName,
      isCreditSale: isCreditSale,
    );

    if (!mounted || action == null || action == PostCheckoutPrintAction.skip) {
      return;
    }

    try {
      if (action == PostCheckoutPrintAction.thermal) {
        await PrintService.printThermalSaleReceipt(entry);
        if (mounted) {
          AppToast.showSuccess(context, 'Thermal receipt sent to printer');
        }
      } else if (action == PostCheckoutPrintAction.a4) {
        await PrintService.printA4Invoice(entry, isEdited: isEdited);
        if (mounted) {
          AppToast.showSuccess(context, 'A4 statement sent to printer');
        }
      }
    } catch (e) {
      debugPrint('Post-checkout print failed: $e');
      if (mounted) {
        AppToast.showError(context, 'Print failed: $e');
      }
    }
  }

  Future<void> _completeSale({bool shareWhatsAppPdf = false}) async {
    // Guard against rapid Enter / double-clicks submitting twice.
    if (_isSaving || _checkoutLock) return;
    _checkoutLock = true;

    try {
      if (_isAdvanceMode) {
        await _completeKisaanAdvance(shareWhatsAppPdf: shareWhatsAppPdf);
        return;
      }

      // Validation: Check if Walk-In Customer or Zamindar is selected
      if (!_isWalkInCustomer && _selectedZamindar == null) {
        AppToast.showError(
          context,
          'Please select a Zamindar or enable Walk-In Customer',
        );
        return;
      }

      // Validation: Check if Walk-In Customer name is provided
      if (_isWalkInCustomer &&
          _walkInCustomerNameController.text.trim().isEmpty) {
        AppToast.showError(
          context,
          'Please enter customer name for walk-in customer',
        );
        return;
      }

      // Validation: Check if cart has items
      if (_cartItems.isEmpty) {
        AppToast.showError(
          context,
          'Cart is empty. Please add products to the cart.',
        );
        return;
      }

      final summary = _getSummary();
      final double totalPayable = summary.totalPayable;
      double cashReceived = 0;
      if (_paymentMethod == PaymentMethod.credit) {
        cashReceived = SaleController.parseMoney(_cashReceivedController.text);
        if (cashReceived < 0) cashReceived = 0;
        if (cashReceived > totalPayable) {
          AppToast.showError(
            context,
            'Cash received cannot exceed total payable',
          );
          return;
        }
        if (!_isWalkInCustomer &&
            (_selectedZamindar?.paymentTerms.isNotEmpty ?? false) &&
            (_selectedSalePaymentTerm == null ||
                _selectedSalePaymentTerm!.isEmpty)) {
          AppToast.showError(
            context,
            'Please select a payment term for this credit sale',
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
        final String kisaanName = _selectedKisaan?.name ?? 'Self';

        // Financial Breakdown — paisa-safe rounding before DB write
        final double subtotal = moneyRound(summary.subtotal);
        final double itemDiscountsTotal = moneyRound(summary.itemDiscounts);
        final double seasonalIncrementTotal = _showSeasonalIncrement
            ? moneyRound(summary.totalSeasonalIncrements)
            : 0.0;
        final double overallDiscount = moneyRound(_overallDiscount);
        // Credit: cash received is immediate payment; remainder is udhaar.
        // Cash: full amount is paid (advance wallet may draw down inside insertSale).
        final double paidAmount = moneyRound(
          _paymentMethod == PaymentMethod.cash ? totalPayable : cashReceived,
        );
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
          final parsed = int.tryParse(cartItem.product.id);
          final productId = (parsed != null && parsed > 0) ? parsed : null;

          // Persist base + seasonal separately so edit reload round-trips.
          final double basePrice = moneyRound(cartItem.product.basePrice);
          final double seasonalInc = _showSeasonalIncrement
              ? moneyRound(cartItem.seasonalIncrement)
              : 0.0;

          return db.SaleLineItem(
            productId: productId,
            productName: cartItem.product.name,
            qty: cartItem.quantity.toDouble(),
            unitPrice: basePrice,
            seasonalIncrement: seasonalInc,
            discount: moneyRound(cartItem.discount),
          );
        }).toList();

        // Get product type from first cart item (or default to 'Fertilizer')
        final String productType = _cartItems.isNotEmpty
            ? _cartItems.first.product.type.toString().split('.').last
            : 'Fertilizer';

        // Get season string for the selected date
        final String seasonString =
            SeasonService.instance.activeSeasonName ??
            SeasonUtils.getSeasonString(_selectedDateTime);

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
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
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
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
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
        // STEP 4: WhatsApp PDF (optional), print actions, then reset
        // ========================================================

        if (!mounted) return;

        final wasEditMode = _isEditMode;
        final wasCreditSale = _paymentMethod == PaymentMethod.credit;
        final whatsappNumber = _isWalkInCustomer
            ? null
            : _selectedZamindar?.whatsappNumber;

        final entry = _buildInvoiceLedgerEntry(
          invoiceNumber: invoiceNumber,
          zamindarName: zamindarName,
          kisaanName: kisaanName,
          totalPayable: totalPayable,
          paidAmount: paidAmount,
          seasonString: seasonString,
          isWalkIn: _isWalkInCustomer,
          description: _descriptionController.text.trim(),
        );

        if (shareWhatsAppPdf) {
          try {
            await _shareInvoiceWhatsAppReceipt(
              entry: entry,
              whatsappNumber: whatsappNumber,
            );
          } catch (e) {
            debugPrint('WhatsApp receipt share failed: $e');
            if (mounted) {
              AppToast.showWarning(
                context,
                'Sale saved, but WhatsApp receipt failed: $e',
              );
            }
          }
        }

        if (!mounted) return;

        final actionText = wasEditMode ? 'updated' : 'saved';
        AppToast.showSuccess(
          context,
          shareWhatsAppPdf
              ? 'Sale $actionText & WhatsApp receipt opened. Total: Rs ${totalPayable.toStringAsFixed(0)}'
              : 'Sale $actionText successfully! Total: Rs ${totalPayable.toStringAsFixed(0)}',
        );

        // Unlock UI before reset/sync (_syncReferenceData skips while saving).
        setState(() => _isSaving = false);

        await _showPostCheckoutPrintDialog(
          entry: entry,
          isCreditSale: wasCreditSale,
          isEdited: wasEditMode,
        );

        if (!mounted) return;

        // Must clear Shell editInvoiceNumber — otherwise reload re-enters edit
        // mode and the old invoice number sticks on screen.
        await _resetFormForNewSale(retainPartySelection: true);

        // If parent key-recreated this screen, we're done (fresh init loads data).
        if (!mounted) return;

        // Refresh stock / reference lists without reloading edit state.
        try {
          await _syncReferenceData();
        } catch (e) {
          debugPrint('Error syncing reference data after save: $e');
        }
      } catch (e, stackTrace) {
        debugPrint('❌ CRITICAL ERROR saving sale: $e');
        debugPrint('Stack trace: $stackTrace');

        if (mounted) {
          AppToast.showError(context, 'Failed to save sale: $e');
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
    } finally {
      _checkoutLock = false;
    }
  }

  Future<void> _completeKisaanAdvance({bool shareWhatsAppPdf = false}) async {
    if (_isSaving) return;

    if (_isEditMode) {
      AppToast.showError(
        context,
        'Cannot record an advance while editing an invoice',
      );
      return;
    }

    if (_isWalkInCustomer || _selectedZamindar == null) {
      AppToast.showError(
        context,
        'Select a Zamindar (and Kisaan) before saving a Cash / Fuel Advance',
      );
      return;
    }

    final zamindarId = int.tryParse(_selectedZamindar!.id);
    if (zamindarId == null) {
      AppToast.showError(context, 'Invalid Zamindar selection');
      return;
    }

    final amount = moneyRound(_advanceAmountValue);
    if (amount <= 0) {
      AppToast.showError(
        context,
        'Enter a valid Total Value (Rs.) greater than zero',
      );
      return;
    }

    final liters = _advanceLitersValue;
    if (_isFuelAdvance && (liters == null || liters <= 0)) {
      AppToast.showError(
        context,
        'Enter Quantity (Liters) for this fuel advance',
      );
      return;
    }

    // Advances are zero-margin loans: no stock check, Rs 0 profit contribution.
    assert(
      SaleController.profitContribution(
            serviceKind: ProductServiceKind.fromSaleTransactionType(
              _advanceTransactionType,
            ),
            saleAmount: amount,
            catalogCost: 0,
          ) ==
          0,
    );

    setState(() => _isSaving = true);

    try {
      final invoiceNumber = await db.DatabaseHelper.instance
          .getNextInvoiceNumber();
      final zamindarName = _selectedZamindar!.name;
      final kisaanName = _selectedKisaan?.name ?? 'Self';
      final kisaanId = _selectedKisaan != null
          ? int.tryParse(_selectedKisaan!.id)
          : null;
      final seasonString = SeasonService.instance.activeSeasonName ??
          SeasonUtils.getSeasonString(_selectedDateTime);
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
          await _shareInvoiceWhatsAppReceipt(
            entry: entry,
            whatsappNumber: whatsappNumber,
          );
        } catch (e) {
          debugPrint('WhatsApp receipt share failed: $e');
          if (mounted) {
            AppToast.showWarning(
              context,
              'Advance saved, but WhatsApp receipt failed: $e',
            );
          }
        }
      }

      if (!mounted) return;

      AppToast.showSuccess(
        context,
        shareWhatsAppPdf
            ? '$_advanceDisplayLabel saved & WhatsApp receipt opened. '
                  'Total: Rs ${amount.toStringAsFixed(0)}'
            : '$_advanceDisplayLabel saved on khata. '
                  'Total: Rs ${amount.toStringAsFixed(0)}',
      );

      setState(() => _isSaving = false);
      await _resetFormForNewSale(retainPartySelection: true);
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
        AppToast.showError(context, 'Failed to save advance: $e');
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
    final label = db.SaleTransactionType.khaataReceiptLabel(
      _advanceTransactionType,
      liters: liters,
    );
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
      createdByUserId: SessionContext.userId,
      createdByUserName: SessionContext.footprintLabel,
      createdAt: DateTime.now(),
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
    _productFocusNode.dispose();
    _screenFocusNode.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    _seasonalIncrementController.dispose();
    _overallDiscountController.dispose();
    _walkInCustomerNameController.dispose();
    _cashReceivedController.dispose();
    _advanceAmountController.dispose();
    _advanceLitersController.dispose();
    _advanceRemarksController.dispose();
    _descriptionController.dispose();
    // Remove database listener to prevent memory leaks
    db.DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  bool get _isTypingInTextField {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _focusProductSearch() {
    _productFocusNode.requestFocus();
  }

  void _onShortcutCheckout() {
    if (_isSaving || _isLoading) return;
    // Avoid accidental checkout while typing qty/price/name fields.
    if (_isTypingInTextField) return;
    _saveAndPrint();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _onShortcutCheckout,
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            _onShortcutCheckout,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _handleEscapeShortcut();
        },
        const SingleActivator(LogicalKeyboardKey.f2): _focusProductSearch,
        // Delete removes cart lines. Backspace is intentionally NOT bound so
        // text fields can erase/edit characters normally.
        const SingleActivator(LogicalKeyboardKey.delete):
            _removeSelectedOrLastCartItem,
      },
      child: Focus(
        focusNode: _screenFocusNode,
        autofocus: true,
        child: Theme(
          data: Theme.of(context).copyWith(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            inputDecorationTheme: Theme.of(context).inputDecorationTheme
                .copyWith(
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
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final stackColumns = constraints.maxWidth < 900;
                            if (stackColumns) {
                              return SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _buildLeftColumn(fullWidth: true),
                                    _buildRightColumn(scrollable: false),
                                  ],
                                ),
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildLeftColumn(),
                                Expanded(child: _buildRightColumn()),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          ),
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
    final season = SeasonService.instance.activeSeasonName ??
        SeasonUtils.getSeasonString(_selectedDateTime);

    return AppTopHeader(
      title: 'New sale',
      subtitle: '$displayDate — $season Season',
      actions: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.inputBorder, width: 0.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _invoiceNumber,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.pageSubtitle,
          ),
        ),
        AppButton.secondary(
          label: 'Discard',
          icon: Icons.close,
          onPressed: _handleDiscard,
        ),
        AppButton.primary(
          label: _isSaving ? 'Saving...' : 'Save & Print',
          icon: Icons.check,
          loading: _isSaving,
          onPressed: _isSaving ? null : _saveAndPrint,
        ),
      ],
    );
  }

  Widget _buildLeftColumn({bool fullWidth = false}) {
    final content = Column(
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
          if (_isPartnerSelfUse && !_isAdvanceMode) ...[
            _buildPartnerSelfUsePricingCard(),
            const SizedBox(height: 10),
          ],
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
    );

    return Container(
      width: fullWidth ? null : 360,
      constraints: fullWidth
          ? const BoxConstraints(maxWidth: double.infinity)
          : const BoxConstraints(maxWidth: 360),
      padding: EdgeInsets.fromLTRB(14, 12, fullWidth ? 14 : 8, 12),
      child: fullWidth ? content : SingleChildScrollView(child: content),
    );
  }

  Widget _buildRightColumn({bool scrollable = true}) {
    final content = Column(
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
          _buildDescriptionNotesCard(),
          const SizedBox(height: 10),
          _buildSummaryCard(),
        ],
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 14, 12),
      child: scrollable ? SingleChildScrollView(child: content) : content,
    );
  }

  Widget _buildCheckoutModeToggle() {
    final advanceDisabled = _isEditMode || _isWalkInCustomer;
    final infoText = advanceDisabled
        ? (_isEditMode
              ? 'Advance mode is unavailable while editing an invoice.'
              : 'Disable Walk-In Customer to record a Kisaan advance.')
        : (_isAdvanceMode
              ? 'Recording a cash or fuel advance against this Kisaan\'s harvest account.'
              : 'Selling stock items to this Zamindar\'s account — added to the cart below.');

    return Container(
      decoration: BoxDecoration(
        color: SaleColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SaleColors.borderLight, width: 0.5),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F4F1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildModeOptionCard(
                    title: 'Product Sale',
                    subtitle: 'Fertilizer, pesticide & seed',
                    icon: Icons.shopping_cart_rounded,
                    selected: !_isAdvanceMode,
                    onTap: () {
                      if (_isAdvanceMode) _enterProductSaleMode();
                    },
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _buildModeOptionCard(
                    title: 'Cash / Fuel Advance',
                    subtitle: 'Advance against harvest',
                    icon: Icons.payments_rounded,
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
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFFE8EFE8),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_rounded, size: 15, color: SaleColors.midGreen),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    infoText,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      color: SaleColors.textMuted,
                      fontWeight: FontWeight.w500,
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

  Widget _buildModeOptionCard({
    required String title,
    required String subtitle,
    required IconData icon,
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            decoration: BoxDecoration(
              color: selected ? SaleColors.cardBg : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: SaleColors.darkGreen.withValues(alpha: 0.08),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: selected
                        ? SaleColors.darkGreen
                        : SaleColors.paleGreen,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: selected ? Colors.white : SaleColors.midGreen,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: selected
                              ? SaleColors.darkGreen
                              : SaleColors.textDark,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          height: 1.2,
                          fontWeight: FontWeight.w500,
                          color: SaleColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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

  Widget _buildPartnerSelfUsePricingCard() {
    Widget chip(_PartnerPricePreset preset, String label) {
      final selected = _partnerPricePreset == preset;
      return Expanded(
        child: Material(
          color: selected ? SaleColors.darkGreen : Colors.white,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: () => _applyPartnerPricePreset(preset),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected
                      ? SaleColors.darkGreen
                      : SaleColors.borderLight,
                  width: 0.5,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : SaleColors.textDark,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3DE),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF97C459), width: 0.5),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.handshake_outlined,
                size: 16,
                color: SaleColors.darkGreen,
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Partner Self-Use pricing',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: SaleColors.darkGreen,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Linked partner Zamindar — choose Cost, Retail, or Seasonal increment.',
            style: TextStyle(fontSize: 11, color: Color(0xFF2D6A4F)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              chip(_PartnerPricePreset.cost, 'Cost Price'),
              const SizedBox(width: 6),
              chip(_PartnerPricePreset.retail, 'Retail'),
              const SizedBox(width: 6),
              chip(_PartnerPricePreset.seasonal, 'Seasonal'),
            ],
          ),
        ],
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
                    _isPartnerSelfUse = false;
                    _zamindarSearchController.clear();
                    _zamindarFieldController?.clear();
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
                if (_selectedZamindar == null) ...[
                  _buildZamindarAutocomplete(),
                  if (_frequentZamindars.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildFrequentZamindarChips(),
                  ],
                ] else
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
            _zamindarFieldController = controller;
            _zamindarAutocompleteFocusNode = focusNode;
            return TextFormField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(fontSize: 13, color: SaleColors.textDark),
              decoration: InputDecoration(
                hintText: 'Type to search Zamindar...',
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
          onSelected: _applyZamindarSelection,
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

  Widget _buildFrequentZamindarChips() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Frequently used',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: SaleColors.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final zamindar in _frequentZamindars)
              Material(
                color: SaleColors.paleGreen,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  onTap: () => _applyZamindarSelection(zamindar),
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: const BoxDecoration(
                            color: SaleColors.midGreen,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              zamindar.initials,
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: SaleColors.lightGreen,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          zamindar.name,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: SaleColors.darkGreen,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildZamindarPillWithClear() {
    return Container(
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textDark,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${_selectedZamindar!.location} · ${_selectedZamindar!.kisaanCount} Kisaans',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                if (_selectedKisaan != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Selected Kisaan: ${_selectedKisaan!.name}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: SaleColors.darkGreen,
                    ),
                  ),
                ],
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
                        final selected = _selectedKisaan?.id == kisaan.id;
                        return KisaanCard(
                          kisaan: kisaan,
                          isSelected: selected,
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
    final showSeasonal = _showSeasonalIncrement;

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
                  width: 96,
                  child: CustomStepperTextField(
                    label: 'Qty',
                    controller: _qtyController,
                    stepValue: 1,
                    minValue: 1,
                    integerOnly: true,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 100,
                  child: CustomStepperTextField(
                    label: 'Price',
                    controller: _priceController,
                    stepValue: 20,
                    minValue: 0,
                  ),
                ),
                if (showSeasonal) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 110,
                    child: CustomStepperTextField(
                      label: 'Seasonal Inc',
                      controller: _seasonalIncrementController,
                      stepValue: 20,
                      minValue: 0,
                      hintText:
                          _selectedProduct != null &&
                              !_selectedProduct!.hasSeasonalIncrement
                          ? 'No data'
                          : null,
                    ),
                  ),
                ],
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
        RawAutocomplete<Product>(
          textEditingController: _productSearchController,
          focusNode: _productFocusNode,
          displayStringForOption: (Product option) => option.name,
          optionsBuilder: (TextEditingValue textEditingValue) {
            if (textEditingValue.text.isEmpty) {
              return const Iterable<Product>.empty();
            }
            final query = textEditingValue.text.toLowerCase();
            return _products.where((Product product) {
              return product.name.toLowerCase().contains(query) ||
                  product.brand.toLowerCase().contains(query);
            });
          },
          onSelected: _onProductSelected,
          fieldViewBuilder:
              (context, textEditingController, focusNode, onFieldSubmitted) {
                return ListenableBuilder(
                  listenable: textEditingController,
                  builder: (context, _) {
                    return TextField(
                      controller: textEditingController,
                      focusNode: focusNode,
                      onSubmitted: (_) => onFieldSubmitted(),
                      style: const TextStyle(
                        fontSize: 13,
                        color: SaleColors.textDark,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search or select product... (F2)',
                        hintStyle: const TextStyle(
                          fontSize: 13,
                          color: SaleColors.textLight,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        isDense: true,
                        // Keep clear button inside the field without growing row height.
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        suffixIcon: textEditingController.text.isNotEmpty
                            ? IconButton(
                                tooltip: 'Clear',
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                icon: const Icon(
                                  Icons.close,
                                  size: 16,
                                  color: SaleColors.textMuted,
                                ),
                                onPressed: _cancelProductSelection,
                              )
                            : null,
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
                            color: SaleColors.darkGreen,
                            width: 1,
                          ),
                        ),
                        filled: true,
                        fillColor: const Color(0xFFF7F8F7),
                      ),
                    );
                  },
                );
              },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 6,
                color: SaleColors.cardBg,
                shadowColor: SaleColors.darkGreen.withValues(alpha: 0.18),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(10),
                  bottomRight: Radius.circular(10),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 260,
                    minWidth: 280,
                  ),
                  child: ListView.separated(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    separatorBuilder: (_, _) => const Divider(
                      height: 0.5,
                      thickness: 0.5,
                      color: SaleColors.borderLight,
                    ),
                    itemBuilder: (context, index) {
                      final option = options.elementAt(index);
                      final brand = option.brand.trim().isEmpty
                          ? '—'
                          : option.brand.trim();
                      final cost = option.costPrice > 0
                          ? option.costPrice
                          : option.basePrice;
                      final costLabel =
                          'Cost Rs ${cost.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
                      final unitLabel = option.unit.trim().isEmpty
                          ? ''
                          : option.unit.trim();

                      return InkWell(
                        onTap: () => onSelected(option),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                option.name,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1A1A1A),
                                  height: 1.25,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '$brand · $costLabel · Stock',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF6B7280),
                                  height: 1.3,
                                ),
                              ),
                              Text(
                                '${option.availableStock}${unitLabel.isEmpty ? '' : ' $unitLabel'}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF6B7280),
                                  height: 1.3,
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

  Widget _buildDescriptionNotesCard() {
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
          const StepHeader(stepNumber: 4, title: 'Description / Notes'),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: TextField(
              controller: _descriptionController,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 13, color: SaleColors.textDark),
              decoration: InputDecoration(
                hintText: 'Add transaction description or notes (optional)...',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: SaleColors.textLight,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
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
                    color: SaleColors.darkGreen,
                    width: 1,
                  ),
                ),
                filled: true,
                fillColor: const Color(0xFFF7F8F7),
              ),
            ),
          ),
        ],
      ),
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
    final showSeasonalIncrement = _showSeasonalIncrement;

    final columns = <AppDataColumn>[
      const AppDataColumn(title: 'Product', flex: 22),
      const AppDataColumn(title: 'Type', flex: 12),
      const AppDataColumn(title: 'Qty', flex: 12),
      const AppDataColumn(title: 'Unit price', flex: 12),
      if (showSeasonalIncrement)
        const AppDataColumn(title: 'Seasonal Inc', flex: 12),
      const AppDataColumn(title: 'Discount', flex: 12),
      const AppDataColumn(title: 'Subtotal', flex: 12),
      const AppDataColumn(title: '', flex: 6),
    ];

    return AppDataTable(
      showCardChrome: false,
      minWidth: showSeasonalIncrement ? 820 : 720,
      columns: columns,
      rows: [
        for (final item in _cartItems)
          AppDataRow(
            onTap: () => setState(() => _selectedCartItemId = item.id),
            backgroundColor: _selectedCartItemId == item.id
                ? const Color(0xFFEAF3DE)
                : null,
            cells: [
              Text(
                item.product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.textDark,
                ),
              ),
              ProductTypeBadge(type: item.product.type),
              QuantityControl(
                quantity: item.quantity,
                onIncrement: () => _updateCartItemQuantity(item.id, 1),
                onDecrement: () => _updateCartItemQuantity(item.id, -1),
              ),
              Text(
                CurrencyFormatter.format(item.product.basePrice),
                style: const TextStyle(
                  fontSize: 12,
                  color: SaleColors.textDark,
                ),
              ),
              if (showSeasonalIncrement)
                InlineEditableField(
                  key: ValueKey('seasonal_${item.id}'),
                  value: item.seasonalIncrement,
                  onChanged: (val) =>
                      _updateCartItemSeasonalIncrement(item.id, val),
                  width: 80,
                ),
              InlineEditableField(
                key: ValueKey('discount_${item.id}'),
                value: item.discount,
                onChanged: (val) => _updateCartItemDiscount(item.id, val),
              ),
              Text(
                CurrencyFormatter.format(item.subtotal),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.textDark,
                ),
              ),
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
            ],
          ),
      ],
    );
  }

  Widget _buildSummaryCard() {
    final summary = _getSummary();
    final showSeasonalIncrement = !_isAdvanceMode && _showSeasonalIncrement;
    final totalPayable = _isAdvanceMode
        ? _advanceAmountValue
        : summary.totalPayable;

    void onPaymentMethodChanged(PaymentMethod method) {
      final result = SaleController.applyPaymentMethodSwitch(
        next: method,
        zamindarPaymentTerms: _selectedZamindar?.paymentTerms ?? const [],
      );
      setState(() {
        _paymentMethod = result.paymentMethod;
        _selectedSalePaymentTerm = result.paymentTerm;
        _cashReceivedController.text = result.cashReceivedText;
        // Cart lines stay intact — only seasonal increments / cash fields change.
        // Ledger posts are rewritten once at save via updateSaleInNewSchema /
        // insertSale (no duplicate cash-drawer entries on UI toggle).
        if (result.clearSeasonalIncrements) {
          _clearSeasonalIncrements();
        }
      });
      if (method == PaymentMethod.credit && _selectedZamindar != null) {
        _checkZamindarCreditLimit(_selectedZamindar!);
      }
    }

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
            Container(
              height: 0.5,
              margin: const EdgeInsets.symmetric(vertical: 7),
              color: Colors.white.withValues(alpha: 0.15),
            ),
            _buildLockedAdvancePaymentTerms(totalPayable),
          ] else ...[
            _buildSummaryRow('Subtotal', summary.subtotal),
            _buildSummaryRow('Item Discounts', summary.itemDiscounts),
            if (showSeasonalIncrement)
              _buildSummaryRow(
                'Seasonal Increment Total',
                summary.totalSeasonalIncrements,
              ),
            Container(
              height: 0.5,
              margin: const EdgeInsets.symmetric(vertical: 7),
              color: Colors.white.withValues(alpha: 0.15),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Total payable',
                        style: TextStyle(
                          fontSize: 12,
                          color: SaleColors.textLight,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        CurrencyFormatter.format(totalPayable),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: SaleColors.lightGreen,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                PaymentMethodToggle(
                  compact: true,
                  selectedMethod: _paymentMethod,
                  onChanged: !_isWalkInCustomer
                      ? onPaymentMethodChanged
                      : (_) {},
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildOverallDiscountRow(),
            if (_paymentMethod == PaymentMethod.credit &&
                !_isWalkInCustomer) ...[
              const SizedBox(height: 10),
              _buildCreditSplitSection(summary.totalPayable),
            ],
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _isSaving ? null : _saveAndPrint,
                    borderRadius: BorderRadius.circular(9),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _isSaving
                            ? SaleColors.accentGreen.withValues(alpha: 0.6)
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
                            const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.white,
                            ),
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
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: AppButton.whatsapp(
                  label: 'Share Receipt on WhatsApp',
                  loading: _isSaving,
                  onPressed: _isSaving ? null : _saveAndWhatsAppPdf,
                ),
              ),
            ],
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
                  setState(() {
                    _selectedSalePaymentTerm = term;
                    if (term != 'After Harvest') {
                      _clearSeasonalIncrements();
                    }
                  });
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
    return Row(
      children: [
        const Text(
          'Overall Discount',
          style: TextStyle(fontSize: 12, color: SaleColors.textLight),
        ),
        const SizedBox(width: 8),
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
                  color: Colors.white.withValues(alpha: 0.2),
                  width: 0.5,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: 0.2),
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
              fillColor: Colors.white.withValues(alpha: 0.1),
            ),
            onChanged: (val) {
              final parsed = SaleController.parseMoney(val);
              setState(() {
                _overallDiscount = parsed;
              });
            },
          ),
        ),
      ],
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
