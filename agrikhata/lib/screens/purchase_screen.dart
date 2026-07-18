import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/screens/products_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
enum _PaymentSegment { udhaar, cash, partial }

class _PurchaseLine {
  _PurchaseLine() {
    expiryDate = _defaultPurchaseExpiryDate();
    expiryController.text = _formatDate(expiryDate!);
  }

  ProductItem? product;
  final TextEditingController productController = TextEditingController();
  final TextEditingController qtyController = TextEditingController(text: '1');
  final TextEditingController rateController = TextEditingController();
  final TextEditingController expiryController = TextEditingController();
  DateTime? expiryDate;

  /// Bumped to remount the product Autocomplete after quick-add selection.
  int productFieldEpoch = 0;

  double get quantity => double.tryParse(qtyController.text.trim()) ?? 0;
  double get rate => double.tryParse(rateController.text.trim()) ?? 0;
  double get lineTotal => quantity * rate;

  void dispose() {
    productController.dispose();
    qtyController.dispose();
    rateController.dispose();
    expiryController.dispose();
  }
}

String _formatPkr(num amount) {
  return '₨ ${NumberFormat('#,##,##0').format(amount.round())}';
}

String _formatDate(DateTime d) => DateFormat('dd MMM yyyy').format(d);

DateTime _defaultPurchaseExpiryDate([DateTime? from]) {
  final base = from ?? DateTime.now();
  return DateTime(base.year, base.month + 6, base.day);
}

// ---------------------------------------------------------------------------

class PurchaseScreen extends StatefulWidget {
  const PurchaseScreen({super.key});

  @override
  State<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends State<PurchaseScreen> {
  static const _primary = Color(0xFF1B4332);
  static const _secondary = Color(0xFF2D6A4F);
  static const _bg = Color(0xFFF7F9F4);
  static const _accentRed = Color(0xFFA32D2D);
  static const _border = Color(0xFFE2EBE0);
  static const _inputBorder = Color(0xFFC6DEC9);
  /// Forest-green outline (Tailwind emerald-800 equivalent).
  static const _emerald800 = Color(0xFF065F46);

  final _transportController = TextEditingController(text: '0');
  final _amountPaidController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _invoicePreview = ValueNotifier<String>('PI-…');

  List<DbWholesaler> _wholesalers = [];
  List<ProductItem> _products = [];
  DbWholesaler? _selectedWholesaler;
  DateTime _invoiceDate = DateTime.now();
  _PaymentSegment _payment = _PaymentSegment.udhaar;
  final List<_PurchaseLine> _lines = [_PurchaseLine()];

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _transportController.addListener(() => setState(() {}));
    _amountPaidController.addListener(() => setState(() {}));
    _loadData();
    DatabaseHelper.instance.addListener(_onDbChanged);
  }

  void _onDbChanged() => _loadData(silent: true);

  Future<void> _loadData({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final db = DatabaseHelper.instance;
      final wholesalers = await db.getAllWholesalers();
      final products = await db.getAllProducts();
      final next = await db.getNextPurchaseInvoiceNumber();
      if (!mounted) return;
      setState(() {
        _wholesalers = wholesalers;
        _products = products;
        _invoicePreview.value = next;
        _loading = false;
        if (_selectedWholesaler != null) {
          final still = wholesalers
              .where((w) => w.id == _selectedWholesaler!.id)
              .toList();
          _selectedWholesaler = still.isEmpty ? null : still.first;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load purchase data: $e';
      });
    }
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDbChanged);
    _transportController.dispose();
    _amountPaidController.dispose();
    _descriptionController.dispose();
    _invoicePreview.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  // ---- Totals ----

  double get _subtotal => _lines.fold(0.0, (sum, line) => sum + line.lineTotal);

  double get _transport =>
      double.tryParse(_transportController.text.trim()) ?? 0;

  double get _grandTotal => _subtotal + _transport;

  double get _amountPaid {
    switch (_payment) {
      case _PaymentSegment.cash:
        return _grandTotal;
      case _PaymentSegment.udhaar:
        return 0;
      case _PaymentSegment.partial:
        return double.tryParse(_amountPaidController.text.trim()) ?? 0;
    }
  }

  double get _outstanding {
    switch (_payment) {
      case _PaymentSegment.cash:
        return 0;
      case _PaymentSegment.udhaar:
        return _grandTotal;
      case _PaymentSegment.partial:
        final remaining = _grandTotal - _amountPaid;
        return remaining < 0 ? 0 : remaining;
    }
  }

  String get _paymentTypeLabel {
    switch (_payment) {
      case _PaymentSegment.udhaar:
        return PurchasePaymentType.udhaar;
      case _PaymentSegment.cash:
        return PurchasePaymentType.cash;
      case _PaymentSegment.partial:
        return PurchasePaymentType.partial;
    }
  }

  // ---- Line helpers ----

  void _addLine() => setState(() => _lines.add(_PurchaseLine()));

  void _removeLine(int index) {
    if (_lines.length <= 1) return;
    setState(() {
      _lines[index].dispose();
      _lines.removeAt(index);
    });
  }

  Future<void> _pickInvoiceDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _invoiceDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: _primary,
              onPrimary: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) setState(() => _invoiceDate = picked);
  }

  Future<void> _pickExpiry(int index) async {
    final line = _lines[index];
    final initial =
        line.expiryDate ?? _defaultPurchaseExpiryDate();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime(2100),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: _primary,
              onPrimary: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() {
      line.expiryDate = picked;
      line.expiryController.text = _formatDate(picked);
    });
  }

  void _applyProductToLine(_PurchaseLine line, ProductItem product) {
    line.product = product;
    line.productController.text = product.name;
    line.rateController.text =
        product.costPrice > 0 ? product.costPrice.toString() : '';
    line.expiryDate = product.expiryDate;
    line.expiryController.text = _formatDate(line.expiryDate!);
    line.productFieldEpoch++;
  }

  /// Prefer first empty line; otherwise append a new row for the new product.
  void _selectCreatedProduct(ProductItem product) {
    final emptyIndex = _lines.indexWhere((l) => l.product == null);
    if (emptyIndex >= 0) {
      _applyProductToLine(_lines[emptyIndex], product);
      return;
    }
    final line = _PurchaseLine();
    _applyProductToLine(line, product);
    _lines.add(line);
  }

  Future<void> _showQuickAddProductDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    final created = await showDialog<ProductItem>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var saving = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 48,
                vertical: 28,
              ),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox(
                width: 400,
                height: MediaQuery.sizeOf(context).height * 0.9,
                child: AddProductPanel(
                  onCancel: saving
                      ? () {}
                      : () => Navigator.of(dialogContext).pop(),
                  onSaved: (draft) async {
                    if (saving) return;
                    setDialogState(() => saving = true);
                    try {
                      final id =
                          await DatabaseHelper.instance.insertProduct(draft);
                      final product =
                          await DatabaseHelper.instance.getProduct(id);
                      if (!dialogContext.mounted) return;
                      if (product == null) {
                        setDialogState(() => saving = false);
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Product was saved but could not be loaded.',
                            ),
                          ),
                        );
                        return;
                      }
                      Navigator.of(dialogContext).pop(product);
                    } catch (e) {
                      if (!dialogContext.mounted) return;
                      setDialogState(() => saving = false);
                      messenger.showSnackBar(
                        SnackBar(content: Text('Failed to save product: $e')),
                      );
                    }
                  },
                ),
              ),
            );
          },
        );
      },
    );

    if (created == null || !mounted) return;

    // Refresh catalog + auto-select into an empty/new row only.
    setState(() {
      final exists = _products.any((p) => p.id == created.id);
      if (!exists) {
        _products = [..._products, created]
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
      } else {
        _products = _products
            .map((p) => p.id == created.id ? created : p)
            .toList();
      }
      _selectCreatedProduct(created);
    });
  }

  // ---- Save ----

  Future<void> _savePurchase() async {
    setState(() => _error = null);

    if (_wholesalers.isEmpty) {
      setState(() {
        _error = 'No Wholesalers Found. Please add a wholesaler first.';
      });
      return;
    }
    if (_selectedWholesaler == null || _selectedWholesaler!.id == null) {
      setState(() => _error = 'Please select a wholesaler.');
      return;
    }

    final validLines = _lines
        .where((l) => l.product != null && l.quantity > 0)
        .toList();
    if (validLines.isEmpty) {
      setState(
        () => _error = 'Add at least one product with a valid quantity.',
      );
      return;
    }
    for (final line in validLines) {
      if (line.rate <= 0) {
        setState(() => _error = 'Purchase rate must be greater than zero.');
        return;
      }
    }

    if (_payment == _PaymentSegment.partial) {
      if (_amountPaid <= 0) {
        setState(() => _error = 'Enter Amount Paid for partial payment.');
        return;
      }
      if (_amountPaid > _grandTotal) {
        setState(() {
          _error =
              'Amount Paid cannot exceed Grand Total (${_formatPkr(_grandTotal)}).';
        });
        return;
      }
    }

    if (_grandTotal <= 0) {
      setState(() => _error = 'Grand total must be greater than zero.');
      return;
    }

    setState(() => _saving = true);
    try {
      final items = validLines
          .map(
            (l) => PurchaseLineItem(
              productId: l.product!.id,
              productName: l.product!.name,
              quantity: l.quantity.round(),
              purchaseRate: l.rate,
              expiryDate: l.expiryDate ?? _defaultPurchaseExpiryDate(),
            ),
          )
          .toList();

      final invoiceNo = await DatabaseHelper.instance.insertPurchaseInvoice(
        wholesalerId: _selectedWholesaler!.id!,
        wholesalerName: _selectedWholesaler!.name,
        dateTime: _invoiceDate,
        items: items,
        transportCharges: _transport,
        paymentType: _paymentTypeLabel,
        amountPaid: _amountPaid,
        description: _descriptionController.text.trim(),
      );

      if (!mounted) return;
      _resetForm();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Purchase $invoiceNo saved successfully.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: _secondary,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to save purchase: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetForm() {
    for (final line in _lines) {
      line.dispose();
    }
    setState(() {
      _selectedWholesaler = null;
      _invoiceDate = DateTime.now();
      _payment = _PaymentSegment.udhaar;
      _transportController.text = '0';
      _amountPaidController.clear();
      _descriptionController.clear();
      _lines
        ..clear()
        ..add(_PurchaseLine());
      _error = null;
    });
    _loadData(silent: true);
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AgriHeader(
            breadcrumbs: const ['Inventory', 'Purchase Invoice'],
            actions: [
              ElevatedButton.icon(
                onPressed: _saving ? null : _savePurchase,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined, size: 16),
                label: Text(_saving ? 'Saving…' : 'Save Purchase'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _primary.withValues(alpha: 0.6),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          if (_error != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFCEBEB),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFF7C1C1), width: 0.5),
              ),
              child: Text(
                _error!,
                style: const TextStyle(fontSize: 12.5, color: _accentRed),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 300, child: _buildLeftPanel()),
                        const SizedBox(width: 16),
                        Expanded(child: _buildMiddlePanel()),
                        const SizedBox(width: 16),
                        SizedBox(width: 280, child: _buildRightPanel()),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // LEFT — Invoice metadata
  // ===========================================================================

  Widget _buildLeftPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border, width: 0.5),
      ),
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF3DE),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFF97C459),
                    width: 0.5,
                  ),
                ),
                child: const Text(
                  'Purchase Invoice',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<String>(
              valueListenable: _invoicePreview,
              builder: (_, value, child) => _metaRow('Invoice No.', value),
            ),
            const SizedBox(height: 14),
            _fieldLabel('Wholesaler *'),
            if (_wholesalers.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFCEBEB),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFF7C1C1),
                    width: 0.5,
                  ),
                ),
                child: const Text(
                  'No Wholesalers Found. Please add a wholesaler first.',
                  style: TextStyle(fontSize: 12, color: _accentRed),
                ),
              )
            else
              _buildWholesalerAutocomplete(),
            if (_selectedWholesaler != null) ...[
              const SizedBox(height: 8),
              Text(
                '${_selectedWholesaler!.city} · ${_selectedWholesaler!.phone}',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                ),
              ),
            ],
            const SizedBox(height: 14),
            _fieldLabel('Invoice Date'),
            InkWell(
              onTap: _pickInvoiceDate,
              borderRadius: BorderRadius.circular(8),
              child: InputDecorator(
                decoration: _inputDecoration(
                  suffix: const Icon(Icons.calendar_today_outlined, size: 14),
                ),
                child: Text(
                  _formatDate(_invoiceDate),
                  style: const TextStyle(fontSize: 12.5, color: _primary),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _fieldLabel('Description'),
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              minLines: 2,
              style: const TextStyle(fontSize: 12.5, color: _primary),
              decoration: _inputDecoration(
                hint: 'Invoice summary (optional)',
              ),
            ),
            const SizedBox(height: 16),
            _fieldLabel('Payment Type'),
            const SizedBox(height: 6),
            _buildPaymentSegment(),
            if (_payment == _PaymentSegment.partial) ...[
              const SizedBox(height: 14),
              _fieldLabel('Amount Paid (Rs) *'),
              TextField(
                controller: _amountPaidController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                style: const TextStyle(fontSize: 12.5, color: _primary),
                decoration: _inputDecoration(hint: 'e.g. 50000'),
              ),
              if (_amountPaid > _grandTotal && _grandTotal > 0)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Amount paid exceeds grand total.',
                    style: TextStyle(fontSize: 11, color: _accentRed),
                  ),
                ),
            ],
            const SizedBox(height: 14),
            _fieldLabel('Transport Charges'),
            TextField(
              controller: _transportController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              style: const TextStyle(fontSize: 12.5, color: _primary),
              decoration: _inputDecoration(hint: '0'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaRow(String label, String value) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: _primary,
          ),
        ),
      ],
    );
  }

  Widget _buildPaymentSegment() {
    Widget chip(String label, _PaymentSegment value) {
      final active = _payment == value;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _payment = value),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? _primary : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active ? _primary : _inputBorder,
                width: 0.5,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: active ? Colors.white : _primary,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('Udhaar', _PaymentSegment.udhaar),
        const SizedBox(width: 6),
        chip('Cash', _PaymentSegment.cash),
        const SizedBox(width: 6),
        chip('Partial', _PaymentSegment.partial),
      ],
    );
  }

  Widget _buildWholesalerAutocomplete() {
    return Autocomplete<DbWholesaler>(
      optionsBuilder: (TextEditingValue tev) {
        final q = tev.text.trim().toLowerCase();
        if (q.isEmpty) return _wholesalers;
        return _wholesalers.where((w) {
          return w.name.toLowerCase().contains(q) ||
              w.city.toLowerCase().contains(q);
        });
      },
      displayStringForOption: (w) => w.name,
      onSelected: (w) => setState(() => _selectedWholesaler = w),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        if (_selectedWholesaler != null &&
            controller.text != _selectedWholesaler!.name) {
          controller.text = _selectedWholesaler!.name;
        }
        return TextFormField(
          controller: controller,
          focusNode: focusNode,
          style: const TextStyle(fontSize: 12.5, color: _primary),
          decoration: _inputDecoration(hint: 'Type to search wholesaler…'),
          onChanged: (_) {
            if (_selectedWholesaler != null) {
              setState(() => _selectedWholesaler = null);
            }
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 268),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final w = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    title: Text(
                      w.name,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      '${w.city} · ${w.phone}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                    onTap: () => onSelected(w),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // MIDDLE — Line items
  // ===========================================================================

  Widget _buildMiddlePanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _border, width: 0.5)),
            ),
            child: Row(
              children: [
                const Text(
                  'Line Items',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _primary,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _showQuickAddProductDialog,
                  icon: const Icon(Icons.add, size: 16, color: _emerald800),
                  label: const Text('Add Product'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _emerald800,
                    side: const BorderSide(color: _emerald800, width: 1),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: _addLine,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Row'),
                  style: TextButton.styleFrom(
                    foregroundColor: _secondary,
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _lineHeader(),
          Expanded(
            child: ListView.builder(
              itemCount: _lines.length,
              itemBuilder: (context, index) => _buildLineRow(index),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineHeader() {
    return Container(
      color: _bg,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: const Row(
        children: [
          Expanded(flex: 28, child: Text('PRODUCT', style: _headerStyle)),
          Expanded(flex: 12, child: Text('QTY', style: _headerStyle)),
          Expanded(flex: 14, child: Text('RATE', style: _headerStyle)),
          Expanded(flex: 16, child: Text('EXPIRY', style: _headerStyle)),
          Expanded(flex: 14, child: Text('LINE TOTAL', style: _headerStyle)),
          SizedBox(width: 36),
        ],
      ),
    );
  }

  static const _headerStyle = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.3,
    color: AppColors.textMuted,
  );

  Widget _buildLineRow(int index) {
    final line = _lines[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _border, width: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 28, child: _buildProductAutocomplete(line, index)),
            const SizedBox(width: 8),
            Expanded(
              flex: 12,
              child: TextField(
                controller: line.qtyController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 12.5, color: _primary),
                decoration: _lineInputDecoration(hint: 'Qty'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 14,
              child: TextField(
                controller: line.rateController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 12.5, color: _primary),
                decoration: _lineInputDecoration(hint: 'Rate'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 16,
              child: InkWell(
                onTap: () => _pickExpiry(index),
                child: IgnorePointer(
                  child: TextField(
                    controller: line.expiryController,
                    style: const TextStyle(fontSize: 12.5, color: _primary),
                    decoration: _lineInputDecoration(
                      hint: 'Pick date',
                      suffix: const Icon(Icons.event, size: 14),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 14,
              child: Text(
                _formatPkr(line.lineTotal),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _primary,
                ),
              ),
            ),
            SizedBox(
              width: 36,
              child: IconButton(
                onPressed:
                    _lines.length <= 1 ? null : () => _removeLine(index),
                icon: const Icon(Icons.delete_outline, size: 18),
                color: _accentRed,
                tooltip: 'Remove row',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProductAutocomplete(_PurchaseLine line, int index) {
    return Autocomplete<ProductItem>(
      key: ValueKey('purchase-product-$index-${line.productFieldEpoch}'),
      optionsBuilder: (TextEditingValue tev) {
        final q = tev.text.trim().toLowerCase();
        if (q.isEmpty) return const Iterable<ProductItem>.empty();
        return _products.where((p) {
          return p.name.toLowerCase().contains(q) ||
              p.brand.toLowerCase().contains(q);
        });
      },
      displayStringForOption: (p) => p.name,
      onSelected: (p) {
        setState(() {
          line.product = p;
          line.productController.text = p.name;
          line.rateController.text =
              p.costPrice > 0 ? p.costPrice.toString() : '';
          line.expiryDate = _defaultPurchaseExpiryDate();
          line.expiryController.text = _formatDate(line.expiryDate!);
        });
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        // Keep external controller in sync for display after selection.
        if (line.product != null && controller.text.isEmpty) {
          controller.text = line.product!.name;
        }
        return TextFormField(
          controller: controller,
          focusNode: focusNode,
          style: const TextStyle(fontSize: 12.5, color: _primary),
          decoration: _lineInputDecoration(hint: 'Search product…'),
          onChanged: (v) {
            line.productController.text = v;
            if (line.product != null && v != line.product!.name) {
              setState(() => line.product = null);
            }
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, optionIndex) {
                  final p = options.elementAt(optionIndex);
                  return ListTile(
                    dense: true,
                    title: Text(
                      p.name,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      '${p.brand} · Cost ${_formatPkr(p.costPrice)} · Stock ${p.availableStock} ${p.uom}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                    onTap: () => onSelected(p),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // RIGHT — Summary
  // ===========================================================================

  Widget _buildRightPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border, width: 0.5),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Summary',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _primary,
            ),
          ),
          const SizedBox(height: 16),
          _summaryRow('Subtotal', _formatPkr(_subtotal)),
          const SizedBox(height: 10),
          _summaryRow('Transport Charges', _formatPkr(_transport)),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: _border),
          ),
          _summaryRow('Grand Total', _formatPkr(_grandTotal), emphasize: true),
          if (_payment != _PaymentSegment.cash) ...[
            const SizedBox(height: 10),
            _summaryRow('Amount Paid', _formatPkr(_amountPaid)),
            const SizedBox(height: 10),
            _summaryRow(
              'Outstanding',
              _formatPkr(_outstanding),
              valueColor: _outstanding > 0 ? _accentRed : _secondary,
            ),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PAYMENT: ${_paymentTypeLabel.toUpperCase()}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                    color: AppColors.sidebarText,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _formatPkr(_grandTotal),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                if (_outstanding > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Udhaar ${_formatPkr(_outstanding)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.sidebarText,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _saving ? null : _savePurchase,
            style: ElevatedButton.styleFrom(
              backgroundColor: _secondary,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: Text(_saving ? 'Saving…' : 'Confirm Purchase'),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value, {
    bool emphasize = false,
    Color? valueColor,
  }) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: emphasize ? 13 : 12,
            fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
            color: emphasize ? _primary : AppColors.textMuted,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: emphasize ? 14 : 12.5,
            fontWeight: FontWeight.w600,
            color: valueColor ?? _primary,
          ),
        ),
      ],
    );
  }

  // ---- Shared field chrome ----

  Widget _fieldLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: AppColors.textMuted,
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({String? hint, Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12.5, color: AppColors.textHint),
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      suffixIcon: suffix,
      suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 0),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _inputBorder, width: 0.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _inputBorder, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.accentGreen, width: 1),
      ),
    );
  }

  /// Roomier padding for line-item fields so rows breathe without crowding.
  InputDecoration _lineInputDecoration({String? hint, Widget? suffix}) {
    return _inputDecoration(hint: hint, suffix: suffix).copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
    );
  }
}
