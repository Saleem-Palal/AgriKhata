import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:flutter/material.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedBrand = "All brands";
  String _selectedStatus = "All status";

  List<ProductItem> _products = [];
  bool _isLoading = true;

  final List<double> _colWidths = [
    170, // Product Name
    90, // Brand
    90, // Pack Size
    100, // Cost Price
    100, // Retail Price
    110, // Available Stock
    80, // UOM
    110, // Expiry Date
    100, // Status
    180, // Actions (Edit, Delete, Restock)
  ];

  final List<String> _statusOptions = [
    "All status",
    "In Stock",
    "Low Stock",
    "Expired",
  ];

  List<String> get _brandOptions {
    final brands = _products.map((p) => p.brand).toSet().toList()..sort();
    return ["All brands", ...brands];
  }

  List<ProductItem> get _filteredProducts {
    return _products.where((p) {
      final query = _searchController.text.toLowerCase();
      final matchesSearch =
          query.isEmpty ||
          p.name.toLowerCase().contains(query) ||
          p.brand.toLowerCase().contains(query);

      final matchesBrand =
          _selectedBrand == "All brands" || p.brand == _selectedBrand;

      final matchesStatus =
          _selectedStatus == "All status" || p.statusLabel == _selectedStatus;

      return matchesSearch && matchesBrand && matchesStatus;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    setState(() => _isLoading = true);
    try {
      final products = await DatabaseHelper.instance.getAllProducts();
      setState(() {
        _products = products;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading products: $e');
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openAddProductPanel() async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Add New Product",
      barrierColor: AppColors.darkGreen.withValues(alpha: 0.3),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 360,
            height: double.infinity,
            child: _AddProductPanel(
              onSaved: (product) async {
                try {
                  await DatabaseHelper.instance.insertProduct(product);
                  await _loadProducts();
                  if (mounted) Navigator.pop(context);
                } catch (e) {
                  debugPrint('Error saving product: $e');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error saving product: $e')),
                    );
                  }
                }
              },
              onCancel: () => Navigator.pop(context),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        final offset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOut));
        return SlideTransition(position: offset, child: child);
      },
    );
  }

  Future<void> _openEditProductPanel(ProductItem product) async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Edit Product",
      barrierColor: AppColors.darkGreen.withValues(alpha: 0.3),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 360,
            height: double.infinity,
            child: _AddProductPanel(
              product: product,
              onSaved: (updatedProduct) async {
                try {
                  await DatabaseHelper.instance.updateProduct(updatedProduct);
                  await _loadProducts();
                  if (mounted) Navigator.pop(context);
                } catch (e) {
                  debugPrint('Error updating product: $e');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error updating product: $e')),
                    );
                  }
                }
              },
              onCancel: () => Navigator.pop(context),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        final offset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOut));
        return SlideTransition(position: offset, child: child);
      },
    );
  }

  Future<void> _deleteProduct(ProductItem product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Product'),
        content: Text('Are you sure you want to delete "${product.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && product.id != null) {
      try {
        await DatabaseHelper.instance.deleteProduct(product.id!);
        await _loadProducts();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Product deleted successfully')),
          );
        }
      } catch (e) {
        debugPrint('Error deleting product: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting product: $e')),
          );
        }
      }
    }
  }

  Future<void> _restockProduct(ProductItem product) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Restock ${product.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current Stock: ${product.availableStock} ${product.uom}',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Add Quantity',
                hintText: 'Enter quantity to add',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restock'),
          ),
        ],
      ),
    );

    if (confirmed == true && product.id != null) {
      final addQty = int.tryParse(controller.text) ?? 0;
      if (addQty > 0) {
        try {
          final updatedProduct = ProductItem(
            id: product.id,
            name: product.name,
            brand: product.brand,
            packagingSize: product.packagingSize,
            costPrice: product.costPrice,
            retailPrice: product.retailPrice,
            seasonalIncrement: product.seasonalIncrement,
            availableStock: product.availableStock + addQty,
            uom: product.uom,
            expiryDate: product.expiryDate,
            lowStockThreshold: product.lowStockThreshold,
            description: product.description,
          );
          await DatabaseHelper.instance.updateProduct(updatedProduct);
          await _loadProducts();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Added $addQty ${product.uom} to stock'),
              ),
            );
          }
        } catch (e) {
          debugPrint('Error restocking product: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error restocking product: $e')),
            );
          }
        }
      }
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredProducts;
    final lowStockCount = _products.where((p) => p.isLowStock).length;
    final expiredCount = _products.where((p) => p.isExpired).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AgriHeader(
          breadcrumbs: const ["Inventory", "Products"],
          actions: [
            ElevatedButton.icon(
              onPressed: _openAddProductPanel,
              icon: const Icon(Icons.add, size: 16),
              label: const Text("Add New Product"),
            ),
          ],
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSearchRow(),
                      const SizedBox(height: 14),
                      _buildTable(filtered),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          "Showing ${filtered.length} of ${_products.length} products  ·  $lowStockCount low stock  ·  $expiredCount expired",
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSearchRow() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppColors.sidebarBg, width: 0.5),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, size: 16, color: AppColors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: "Search products by name or brand...",
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: AppColors.sidebarText,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        _buildFilterDropdown(_brandOptions, _selectedBrand, (val) {
          setState(() => _selectedBrand = val!);
        }),
        const SizedBox(width: 10),
        _buildFilterDropdown(_statusOptions, _selectedStatus, (val) {
          setState(() => _selectedStatus = val!);
        }),
      ],
    );
  }

  Widget _buildFilterDropdown(
    List<String> options,
    String value,
    ValueChanged<String?> onChanged,
  ) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.sidebarBg, width: 0.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 16,
            color: AppColors.textMuted,
          ),
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          items: options
              .map((opt) => DropdownMenuItem(value: opt, child: Text(opt)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildTable(List<ProductItem> products) {
    // Row containers use horizontal padding of 14px on each side (28px total).
    // The SizedBox below must include that, or the Row content overflows by
    // exactly that amount (which is what was happening before this fix).
    final totalWidth = _colWidths.fold(0.0, (sum, w) => sum + w) + 28;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: Column(
            children: [
              _buildHeaderRow(),
              for (int i = 0; i < products.length; i++)
                _buildDataRow(products[i], isLast: i == products.length - 1),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(int index, Widget child) {
    return SizedBox(
      width: _colWidths[index],
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
  }

  Widget _buildHeaderRow() {
    final titles = [
      "PRODUCT NAME",
      "BRAND",
      "PACK SIZE",
      "COST PRICE",
      "RETAIL PRICE",
      "AVAILABLE STOCK",
      "UOM",
      "EXPIRY DATE",
      "STATUS",
      "",
    ];
    final style = const TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      color: AppColors.textMuted,
      letterSpacing: 0.3,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F9F4),
        border: Border(
          bottom: BorderSide(color: Color(0xFFC6DEC9), width: 1.0),
        ),
      ),
      child: Row(
        children: List.generate(
          titles.length,
          (i) => _cell(i, Text(titles[i], style: style)),
        ),
      ),
    );
  }

  Widget _buildDataRow(ProductItem p, {required bool isLast}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0xFFC6DEC9), width: 1.0),
              ),
      ),
      child: Row(
        children: [
          _cell(
            0,
            Text(
              p.name,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
            ),
          ),
          _cell(1, Text(p.brand, style: const TextStyle(fontSize: 12))),
          _cell(2, Text(p.packagingSize, style: const TextStyle(fontSize: 12))),
          _cell(
            3,
            Text(
              "Rs ${_fmt(p.costPrice.toDouble())}",
              style: const TextStyle(fontSize: 12),
            ),
          ),
          _cell(
            4,
            Text(
              "Rs ${_fmt(p.retailPrice.toDouble())}",
              style: const TextStyle(fontSize: 12),
            ),
          ),
          _cell(
            5,
            Text(
              p.availableStock.toStringAsFixed(
                p.availableStock.truncateToDouble() == p.availableStock ? 0 : 1,
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          _cell(6, Text(p.uom, style: const TextStyle(fontSize: 12))),
          _cell(
            7,
            Text(
              _formatDate(p.expiryDate),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          _cell(8, _buildStatusBadge(p)),
          _cell(
            9,
            Row(
              children: [
                _actionButton(
                  icon: Icons.edit,
                  label: 'Edit',
                  color: AppColors.accentGreen,
                  onTap: () => _openEditProductPanel(p),
                ),
                const SizedBox(width: 4),
                _actionButton(
                  icon: Icons.add_box,
                  label: 'Restock',
                  color: const Color(0xFF2D6A4F),
                  onTap: () => _restockProduct(p),
                ),
                const SizedBox(width: 4),
                _actionButton(
                  icon: Icons.delete,
                  label: 'Delete',
                  color: const Color(0xFFA32D2D),
                  onTap: () => _deleteProduct(p),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(ProductItem p) {
    Color bg;
    Color fg;
    if (p.isExpired) {
      bg = const Color(0xFFFCEBEB);
      fg = const Color(0xFF791F1F);
    } else if (p.isLowStock) {
      bg = const Color(0xFFFAEEDA);
      fg = const Color(0xFF633806);
    } else {
      bg = const Color(0xFFD8F3DC);
      fg = const Color(0xFF2D6A4F);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        p.statusLabel,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
            borderRadius: BorderRadius.circular(6),
            color: color.withValues(alpha: 0.05),
          ),
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ];
    return "${months[date.month - 1]} ${date.year}";
  }

  String _fmt(double value) {
    final formatted = value.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final buffer = StringBuffer();
    for (int i = 0; i < chars.length; i++) {
      buffer.write(chars[i]);
      final pos = i + 1;
      if (pos == 3 || (pos > 3 && (pos - 3) % 2 == 0)) {
        if (i != chars.length - 1) buffer.write(',');
      }
    }
    return buffer.toString().split('').reversed.join('');
  }
}

class _AddProductPanel extends StatefulWidget {
  final void Function(ProductItem product) onSaved;
  final VoidCallback onCancel;
  final ProductItem? product;

  const _AddProductPanel({
    required this.onSaved,
    required this.onCancel,
    this.product,
  });

  @override
  State<_AddProductPanel> createState() => _AddProductPanelState();
}

class _AddProductPanelState extends State<_AddProductPanel> {
  late final TextEditingController _nameController;
  late final TextEditingController _brandController;
  late final TextEditingController _packSizeController;
  late final TextEditingController _purchaseController;
  late final TextEditingController _sellingController;
  late final TextEditingController _seasonalIncrementController;
  late final TextEditingController _qtyController;
  late final TextEditingController _thresholdController;
  late final TextEditingController _descriptionController;

  late String _selectedUom;
  late DateTime? _expiryDate;

  bool get _isEditing => widget.product != null;

  final List<String> _uoms = ["Bags", "Bottles", "Packets", "kg", "L"];

  @override
  void initState() {
    super.initState();
    
    final product = widget.product;
    
    _nameController = TextEditingController(text: product?.name ?? '');
    _brandController = TextEditingController(text: product?.brand ?? 'Engro');
    _packSizeController = TextEditingController(text: product?.packagingSize ?? '');
    _purchaseController = TextEditingController(
      text: product != null ? _fmt(product.costPrice.toDouble()) : '3,200',
    );
    _sellingController = TextEditingController(
      text: product != null ? _fmt(product.retailPrice.toDouble()) : '3,600',
    );
    _seasonalIncrementController = TextEditingController(
      text: product != null ? product.seasonalIncrement.toString() : '500',
    );
    _qtyController = TextEditingController(
      text: product != null ? product.availableStock.toString() : '10',
    );
    _thresholdController = TextEditingController(
      text: product != null ? product.lowStockThreshold.toString() : '5',
    );
    _descriptionController = TextEditingController(text: product?.description ?? '');
    
    _selectedUom = product?.uom ?? 'Bags';
    _expiryDate = product?.expiryDate ?? DateTime.now().add(const Duration(days: 365));
    
    for (final c in [
      _nameController,
      _brandController,
      _packSizeController,
      _purchaseController,
      _sellingController,
      _seasonalIncrementController,
      _qtyController,
      _thresholdController,
    ]) {
      c.addListener(() => setState(() {}));
    }
  }

  String _fmt(double value) {
    final formatted = value.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final buffer = StringBuffer();
    for (int i = 0; i < chars.length; i++) {
      buffer.write(chars[i]);
      final pos = i + 1;
      if (pos == 3 || (pos > 3 && (pos - 3) % 2 == 0)) {
        if (i != chars.length - 1) buffer.write(',');
      }
    }
    return buffer.toString().split('').reversed.join('');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _brandController.dispose();
    _packSizeController.dispose();
    _purchaseController.dispose();
    _sellingController.dispose();
    _seasonalIncrementController.dispose();
    _qtyController.dispose();
    _thresholdController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  double get _purchasePrice =>
      double.tryParse(_purchaseController.text.replaceAll(',', '')) ?? 0;
  double get _sellingPrice =>
      double.tryParse(_sellingController.text.replaceAll(',', '')) ?? 0;

  String get _marginNote {
    if (_purchasePrice <= 0) return "Enter prices to see margin";
    final margin = _sellingPrice - _purchasePrice;
    final percent = (margin / _purchasePrice) * 100;
    return "Margin: Rs ${margin.toStringAsFixed(0)} · ${percent.toStringAsFixed(1)}% profit";
  }

  bool get _canSave =>
      _nameController.text.isNotEmpty &&
      _packSizeController.text.isNotEmpty &&
      _purchasePrice > 0 &&
      _sellingPrice > 0 &&
      _expiryDate != null &&
      _qtyController.text.isNotEmpty;

  Future<void> _pickExpiryDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 365)),
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _expiryDate = picked);
    }
  }

  void _handleSave() {
    if (!_canSave) return;

    final seasonalIncrementValue =
        double.tryParse(
          _seasonalIncrementController.text.replaceAll(',', ''),
        ) ??
        0;

    widget.onSaved(
      ProductItem(
        id: widget.product?.id,
        name: _nameController.text.trim(),
        brand: _brandController.text.trim(),
        packagingSize: _packSizeController.text.trim(),
        costPrice: _purchasePrice.round(),
        retailPrice: _sellingPrice.round(),
        seasonalIncrement: seasonalIncrementValue.round(),
        availableStock: (double.tryParse(_qtyController.text) ?? 0).round(),
        uom: _selectedUom,
        expiryDate: _expiryDate!,
        lowStockThreshold: (double.tryParse(_thresholdController.text) ?? 0)
            .round(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: Column(
        children: [
          Container(
            color: AppColors.darkGreen,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _isEditing ? "Edit Product" : "Add New Product",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                InkWell(
                  onTap: widget.onCancel,
                  child: const Icon(
                    Icons.close,
                    size: 18,
                    color: Color(0xFFA7C4A0),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _card(
                    title: "Product identity",
                    dotColor: const Color(0xFF40916C),
                    children: [
                      _field("Product name", _nameController, required: true),
                      const SizedBox(height: 12),
                      _field(
                        "Manufacturer / Brand",
                        _brandController,
                        required: true,
                        hint: "e.g. Engro, FFC",
                      ),
                      const SizedBox(height: 12),
                      _field(
                        "Packaging size",
                        _packSizeController,
                        required: true,
                        hint: "e.g. 50kg, 1L",
                      ),
                      const SizedBox(height: 12),
                      _dropdownField(
                        "Unit of measure",
                        _selectedUom,
                        _uoms,
                        (val) => setState(() => _selectedUom = val!),
                        required: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _card(
                    title: "Pricing",
                    dotColor: const Color(0xFFEF9F27),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _prefixField(
                              "Purchase price",
                              _purchaseController,
                              required: true,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _prefixField(
                              "Selling price",
                              _sellingController,
                              required: true,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _field(
                        "Seasonal Increment Default (Rs)",
                        _seasonalIncrementController,
                        required: false,
                        isNumber: true,
                        hint: "500",
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF3DE),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _marginNote,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF3B6D11),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _card(
                    title: "Additional details",
                    dotColor: const Color(0xFFA32D2D),
                    children: [
                      _dateField("Expiry date", _expiryDate, _pickExpiryDate),
                      const SizedBox(height: 12),
                      _field(
                        "Available qty",
                        _qtyController,
                        isNumber: true,
                        hint: "0",
                      ),
                      const SizedBox(height: 12),
                      _field(
                        "Low Stock Alert Limit (Threshold)",
                        _thresholdController,
                        isNumber: true,
                        hint: "e.g. 10",
                      ),
                      const SizedBox(height: 12),
                      _textareaField("Description", _descriptionController),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                top: BorderSide(color: const Color(0xFFC6DEC9), width: 1.0),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: widget.onCancel,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    side: BorderSide(
                      color: const Color(0xFFC6DEC9),
                      width: 1.0,
                    ),
                  ),
                  child: const Text("Cancel", style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _canSave ? _handleSave : null,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    backgroundColor: _canSave
                        ? AppColors.accentGreen
                        : AppColors.sidebarBg,
                    foregroundColor: _canSave
                        ? Colors.white
                        : AppColors.textMuted,
                    disabledBackgroundColor: AppColors.sidebarBg,
                    disabledForegroundColor: AppColors.textMuted,
                  ),
                  child: const Text(
                    "Save Product",
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required String title,
    required Color dotColor,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFC6DEC9), width: 1.0),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F9F4),
              border: Border(
                bottom: BorderSide(color: const Color(0xFFC6DEC9), width: 1.0),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.darkGreen,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text, {bool required = false}) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: AppColors.textMuted,
          ),
        ),
        if (required)
          const Text(" *", style: TextStyle(color: Colors.red, fontSize: 10)),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool required = false,
    bool isNumber = false,
    String hint = "",
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: required),
        const SizedBox(height: 6),
        SizedBox(
          height: 40,
          child: TextField(
            controller: controller,
            keyboardType: isNumber ? TextInputType.number : TextInputType.text,
            style: const TextStyle(fontSize: 12, color: AppColors.darkGreen),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: const TextStyle(
                fontSize: 12,
                color: AppColors.sidebarText,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(
                  color: Color(0xFFC6DEC9),
                  width: 1.0,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(
                  color: AppColors.accentGreen,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _prefixField(
    String label,
    TextEditingController controller, {
    bool required = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: required),
        const SizedBox(height: 6),
        SizedBox(
          height: 40,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFC6DEC9), width: 1.0),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: const BoxDecoration(
                    color: Color(0xFFF7F9F4),
                    border: Border(
                      right: BorderSide(color: Color(0xFFC6DEC9), width: 1.0),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    "Rs",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.darkGreen,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      hintText: "0",
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: AppColors.sidebarText,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dropdownField(
    String label,
    String value,
    List<String> options,
    ValueChanged<String?> onChanged, {
    bool required = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: required),
        const SizedBox(height: 6),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFC6DEC9), width: 1.0),
            borderRadius: BorderRadius.circular(7),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              icon: const Icon(
                Icons.keyboard_arrow_down,
                size: 16,
                color: AppColors.textMuted,
              ),
              style: const TextStyle(fontSize: 12, color: AppColors.darkGreen),
              items: options
                  .map((opt) => DropdownMenuItem(value: opt, child: Text(opt)))
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _dateField(String label, DateTime? value, VoidCallback onTap) {
    final display = value == null
        ? "Select date"
        : "${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: true),
        const SizedBox(height: 6),
        InkWell(
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFC6DEC9), width: 1.0),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    display,
                    style: TextStyle(
                      fontSize: 12,
                      color: value == null
                          ? AppColors.sidebarText
                          : AppColors.darkGreen,
                    ),
                  ),
                ),
                const Icon(
                  Icons.calendar_today_outlined,
                  size: 14,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _textareaField(String label, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _label(label),
            const Text(
              " optional",
              style: TextStyle(fontSize: 9, color: Color(0xFFB0C9B5)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: 3,
          style: const TextStyle(fontSize: 12, color: AppColors.darkGreen),
          decoration: InputDecoration(
            isDense: true,
            hintText: "Usage notes, dosage instructions, etc.",
            hintStyle: const TextStyle(
              fontSize: 12,
              color: AppColors.sidebarText,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(
                color: Color(0xFFC6DEC9),
                width: 1.0,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(
                color: AppColors.accentGreen,
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
