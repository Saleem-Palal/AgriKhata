import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/product_history_dialog.dart';
import 'package:agrikhata/utils/pdf_generator.dart';
import 'package:flutter/material.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedCategory = "All";
  ProductItem? _selectedProduct;
  bool _showAddForm = false;

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
    220, // Actions (Edit, Restock, History, Delete)
  ];

  final List<String> _categories = [
    "All",
    "Fertilizer",
    "Pesticide",
    "Herbicide",
    "Seed",
    "Equipment",
  ];

  List<ProductItem> get _filteredProducts {
    return _products.where((p) {
      final query = _searchController.text.toLowerCase();
      final matchesSearch =
          query.isEmpty ||
          p.name.toLowerCase().contains(query) ||
          p.brand.toLowerCase().contains(query);

      final matchesCategory = _selectedCategory == "All" || p.productType == _selectedCategory;

      return matchesSearch && matchesCategory;
    }).toList();
  }

  double get _totalInventoryVolume {
    return _products.fold(0.0, (sum, p) => sum + p.availableStock);
  }

  double get _totalInventoryValue {
    return _products.fold(
      0.0,
      (sum, p) => sum + (p.retailPrice * p.availableStock),
    );
  }

  int get _alertsCount {
    return _products.where((p) => p.isLowStock || p.isExpired).length;
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadProducts();
    
    // Listen for database changes and auto-refresh
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
  }

  void _onDatabaseChanged() => _loadProducts(showLoading: false);

  Future<void> _loadProducts({bool showLoading = true}) async {
    if (showLoading) setState(() => _isLoading = true);
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
    // Remove database listener to prevent memory leaks
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _openAddProductPanel() {
    setState(() {
      _showAddForm = true;
      _selectedProduct = null;
    });
  }

  void _openEditProductPanel(ProductItem product) {
    setState(() {
      _showAddForm = true;
      _selectedProduct = product;
    });
  }

  Future<void> _saveProduct(ProductItem product) async {
    try {
      if (product.id == null) {
        await DatabaseHelper.instance.insertProduct(product);
      } else {
        final previous = _selectedProduct;
        await DatabaseHelper.instance.updateProduct(product);
        if (previous != null &&
            previous.id != null &&
            previous.availableStock != product.availableStock) {
          await DatabaseHelper.instance.recordStockAdjustment(
            productId: previous.id!,
            previousStock: previous.availableStock,
            newStock: product.availableStock,
          );
        }
      }
      await _loadProducts();
      setState(() {
        _showAddForm = false;
        _selectedProduct = null;
      });
    } catch (e) {
      debugPrint('Error saving product: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(
            content: Text('Error saving product: $e'),
            duration: const Duration(minutes: 1),
          ),
        );
      }
    }
  }

  void _closePanel() {
    setState(() {
      _showAddForm = false;
      _selectedProduct = null;
    });
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
            const SnackBar(
              content: Text('Product deleted successfully'),
              duration: Duration(minutes: 1),
            ),
          );
        }
      } catch (e) {
        debugPrint('Error deleting product: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(
            SnackBar(
              content: Text('Error deleting product: $e'),
              duration: const Duration(minutes: 1),
            ),
          );
        }
      }
    }
  }

  Future<void> _restockProduct(ProductItem product) async {
    final qtyController = TextEditingController();
    final costController = TextEditingController(
      text: product.costPrice.toString(),
    );
    
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
              controller: qtyController,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Add Quantity',
                hintText: 'Enter quantity to add',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFFC6DEC9),
                    width: 1.0,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFFC6DEC9),
                    width: 1.0,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: AppColors.accentGreen,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: costController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'New Cost Price (per unit)',
                hintText: 'Enter cost price',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFFC6DEC9),
                    width: 1.0,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFFC6DEC9),
                    width: 1.0,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: AppColors.accentGreen,
                    width: 1.5,
                  ),
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
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2D6A4F),
              foregroundColor: Colors.white,
            ),
            child: const Text('Restock'),
          ),
        ],
      ),
    );

    if (confirmed == true && product.id != null) {
      final addQty = int.tryParse(qtyController.text) ?? 0;
      final newCostPrice = int.tryParse(costController.text) ?? 0;
      
      if (addQty > 0 && newCostPrice > 0) {
        try {
          await DatabaseHelper.instance.restockProduct(
            product: product,
            addQuantity: addQty,
            newCostPrice: newCostPrice,
          );
          await _loadProducts();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Added $addQty ${product.uom} to stock · Cost price updated to Rs $newCostPrice',
                ),
                duration: const Duration(minutes: 1),
              ),
            );
          }
        } catch (e) {
          debugPrint('Error restocking product: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error restocking product: $e'),
                duration: const Duration(minutes: 1),
              ),
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please enter valid quantity and cost price'),
              duration: Duration(minutes: 1),
            ),
          );
        }
      }
    }
    qtyController.dispose();
    costController.dispose();
  }

  void _openProductHistory(ProductItem product) {
    if (product.id == null) return;
    showDialog(
      context: context,
      builder: (_) => ProductHistoryDialog(productId: product.id!),
    );
  }

  Future<void> _generateStockedProductsPdf() async {
    try {
      final stocked = await DatabaseHelper.instance.getProductsInStock();
      if (stocked.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No stocked products to export'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      final rows = stocked
          .map(
            (p) => <String, dynamic>{
              'name': p.name,
              'brand': p.brand,
              'product_type': p.productType,
              'packaging_size': p.packagingSize,
              'retail_price': p.retailPrice,
              'available_stock': p.availableStock,
              'uom': p.uom,
              'expiry_date': p.expiryDate,
              'low_stock_threshold': p.lowStockThreshold,
              'status': p.statusLabel,
            },
          )
          .toList();

      final file = await PdfGenerator.saveStockedProductsToDocuments(
        products: rows,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PDF saved to ${file.path}'),
          backgroundColor: AppColors.darkGreen,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to generate PDF: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
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
            OutlinedButton.icon(
              onPressed: _generateStockedProductsPdf,
              icon: const Icon(
                Icons.picture_as_pdf_outlined,
                size: 16,
                color: Color(0xFF27500A),
              ),
              label: const Text(
                "Generate PDF",
                style: TextStyle(color: Color(0xFF27500A)),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF27500A)),
              ),
            ),
            const SizedBox(width: 8),
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
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final showSidePanel =
                        _selectedProduct != null || _showAddForm;
                    final stackVertically =
                        showSidePanel && constraints.maxWidth < 900;

                    final mainScroll = SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildKPICards(),
                          const SizedBox(height: 20),
                          _buildTabFilters(),
                          const SizedBox(height: 14),
                          _buildTable(filtered),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                            ),
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
                    );

                    Widget? sidePanel;
                    if (showSidePanel) {
                      sidePanel = ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: stackVertically ? double.infinity : 360,
                        ),
                        child: Container(
                          width: stackVertically ? double.infinity : 360,
                          height: stackVertically ? null : double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: stackVertically
                                ? Border(
                                    top: BorderSide(
                                      color: AppColors.border,
                                      width: 1.0,
                                    ),
                                  )
                                : Border(
                                    left: BorderSide(
                                      color: AppColors.border,
                                      width: 1.0,
                                    ),
                                  ),
                          ),
                          child: _showAddForm
                              ? AddProductPanel(
                                  product: _selectedProduct,
                                  onSaved: _saveProduct,
                                  onCancel: _closePanel,
                                )
                              : _ProductDetailPanel(
                                  product: _selectedProduct!,
                                  onClose: () =>
                                      setState(() => _selectedProduct = null),
                                  onEdit: () =>
                                      _openEditProductPanel(_selectedProduct!),
                                ),
                        ),
                      );
                    }

                    if (stackVertically) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: mainScroll),
                          if (sidePanel != null)
                            Flexible(
                              flex: 2,
                              child: sidePanel,
                            ),
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: mainScroll),
                        if (sidePanel != null) sidePanel,
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildKPICards() {
    return Row(
      children: [
        Expanded(
          child: _buildKPICard(
            value: _totalInventoryVolume.toStringAsFixed(0),
            label: "Total inventory volume",
            valueColor: AppColors.darkGreen,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildKPICard(
            value: "Rs ${_fmt(_totalInventoryValue)}",
            label: "Total value in Rs",
            valueColor: AppColors.accentGreen,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildKPICard(
            value: _alertsCount.toString(),
            label: "Alerts count",
            valueColor: const Color(0xFFA32D2D),
          ),
        ),
      ],
    );
  }

  Widget _buildKPICard({
    required String value,
    required String label,
    required Color valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
          BoxShadow(
            color: valueColor.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w800,
                color: valueColor,
                height: 1.0,
                letterSpacing: -1.0,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabFilters() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ..._categories.map((category) {
          final isSelected = _selectedCategory == category;
          return InkWell(
            onTap: () => setState(() => _selectedCategory = category),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 9,
              ),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.darkGreen : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                category,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isSelected ? Colors.white : AppColors.textMuted,
                ),
              ),
            ),
          );
        }),
      ],
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
    final isSelected = _selectedProduct?.id == p.id;
    return InkWell(
      onTap: () => setState(() {
        _selectedProduct = p;
        _showAddForm = false;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFEAF3DE) : Colors.transparent,
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _cell(
              1,
              Text(
                p.brand,
                style: const TextStyle(fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _cell(
              2,
              Text(p.packagingSize, style: const TextStyle(fontSize: 12)),
            ),
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
                  p.availableStock.truncateToDouble() == p.availableStock
                      ? 0
                      : 1,
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
                    icon: Icons.history_rounded,
                    label: 'History',
                    color: AppColors.tagBlueText,
                    onTap: () => _openProductHistory(p),
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

class _ProductDetailPanel extends StatelessWidget {
  final ProductItem product;
  final VoidCallback onClose;
  final VoidCallback onEdit;

  const _ProductDetailPanel({
    required this.product,
    required this.onClose,
    required this.onEdit,
  });

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

  String _formatDate(DateTime date) {
    return "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";
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
                    product.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: onClose,
                  child: const Icon(
                    Icons.close,
                    size: 18,
                    color: Color(0xFFA7C4A0),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xFFF7F9F4),
              border: Border(
                bottom: BorderSide(color: Color(0xFFC6DEC9), width: 1.0),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit, size: 14),
                    label: const Text("Edit"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
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
                  const Text(
                    "Product info",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.darkGreen,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildInfoRow("SKU", product.id?.toString() ?? "N/A"),
                  _buildInfoRow(
                    "Price",
                    "Rs ${_fmt(product.retailPrice.toDouble())}",
                  ),
                  _buildInfoRow("Product Type", product.productType),
                  _buildInfoRow("Brand", product.brand),
                  _buildInfoRow("Available Stock", product.availableStock.toString()),
                  _buildInfoRow("Status", product.statusLabel),
                  const SizedBox(height: 24),
                  const Text(
                    "Sales statistics",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.darkGreen,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SalesTrendChart(product: product),
                  const SizedBox(height: 24),
                  const Text(
                    "Additional details",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.darkGreen,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildInfoRow(
                    "Cost Price",
                    "Rs ${_fmt(product.costPrice.toDouble())}",
                  ),
                  _buildInfoRow("Pack Size", product.packagingSize),
                  _buildInfoRow("Unit of Measure", product.uom),
                  _buildInfoRow("Expiry Date", _formatDate(product.expiryDate)),
                  _buildInfoRow(
                    "Low Stock Threshold",
                    product.lowStockThreshold.toString(),
                  ),
                  if (product.description != null &&
                      product.description!.isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        const Text(
                          "Description",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          product.description!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.darkGreen,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.textMuted,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.darkGreen,
            ),
          ),
        ],
      ),
    );
  }
}

class _SalesTrendChart extends StatelessWidget {
  final ProductItem product;

  const _SalesTrendChart({required this.product});

  @override
  Widget build(BuildContext context) {
    final dataPoints = _generateTrendData();
    
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Stock trend",
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
              Text(
                "Current: ${product.availableStock}",
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: AppColors.accentGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _TrendChartPainter(dataPoints: dataPoints),
            ),
          ),
        ],
      ),
    );
  }

  List<double> _generateTrendData() {
    final currentStock = product.availableStock.toDouble();
    final random = currentStock.hashCode;
    
    final points = <double>[];
    var value = currentStock * 0.6;
    
    for (int i = 0; i < 12; i++) {
      final variation = ((random + i * 137) % 20 - 10) / 100;
      value = value * (1 + variation);
      value = value.clamp(0, currentStock * 1.5);
      points.add(value);
    }
    
    points.add(currentStock);
    return points;
  }
}

class _TrendChartPainter extends CustomPainter {
  final List<double> dataPoints;

  _TrendChartPainter({required this.dataPoints});

  @override
  void paint(Canvas canvas, Size size) {
    if (dataPoints.isEmpty) return;

    final maxValue = dataPoints.reduce((a, b) => a > b ? a : b);
    final minValue = dataPoints.reduce((a, b) => a < b ? a : b);
    final range = maxValue - minValue;

    if (range == 0) return;

    final paint = Paint()
      ..color = AppColors.accentGreen
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = AppColors.accentGreen.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    final path = Path();
    final fillPath = Path();
    final stepX = size.width / (dataPoints.length - 1);

    for (int i = 0; i < dataPoints.length; i++) {
      final x = i * stepX;
      final normalizedValue = (dataPoints[i] - minValue) / range;
      final y = size.height - (normalizedValue * size.height * 0.9);

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    final dotPaint = Paint()
      ..color = AppColors.accentGreen
      ..style = PaintingStyle.fill;

    final lastX = (dataPoints.length - 1) * stepX;
    final lastNormalizedValue = (dataPoints.last - minValue) / range;
    final lastY = size.height - (lastNormalizedValue * size.height * 0.9);
    
    canvas.drawCircle(Offset(lastX, lastY), 4, dotPaint);
    
    final whiteDotPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(lastX, lastY), 2, whiteDotPaint);
  }

  @override
  bool shouldRepaint(_TrendChartPainter oldDelegate) {
    return oldDelegate.dataPoints != dataPoints;
  }
}

/// Full product create/edit form (shared with Purchase Invoice quick-add).
class AddProductPanel extends StatefulWidget {
  final void Function(ProductItem product) onSaved;
  final VoidCallback onCancel;
  final ProductItem? product;

  const AddProductPanel({
    super.key,
    required this.onSaved,
    required this.onCancel,
    this.product,
  });

  @override
  State<AddProductPanel> createState() => _AddProductPanelState();
}

class _AddProductPanelState extends State<AddProductPanel> {
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
  late String _selectedProductType;
  late DateTime? _expiryDate;

  bool get _isEditing => widget.product != null;

  final List<String> _uoms = ["Bags", "Bottles", "Packets", "kg", "L"];
  final List<String> _productTypes = [
    "Fertilizer",
    "Pesticide",
    "Herbicide",
    "Seed",
    "Equipment",
  ];

  @override
  void initState() {
    super.initState();

    final product = widget.product;

    _nameController = TextEditingController(text: product?.name ?? '');
    _brandController = TextEditingController(text: product?.brand ?? 'Engro');
    _packSizeController = TextEditingController(
      text: product?.packagingSize ?? '',
    );
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
    _descriptionController = TextEditingController(
      text: product?.description ?? '',
    );

    _selectedUom = product?.uom ?? 'Bags';
    _selectedProductType = product?.productType ?? 'Fertilizer';
    _expiryDate =
        product?.expiryDate ?? DateTime.now().add(const Duration(days: 365));

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
        productType: _selectedProductType,
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
                      _dropdownField(
                        "Product type",
                        _selectedProductType,
                        _productTypes,
                        (val) => setState(() => _selectedProductType = val!),
                        required: true,
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
