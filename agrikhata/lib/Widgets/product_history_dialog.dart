import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Desktop stock movement ledger for a single product.
class ProductHistoryDialog extends StatefulWidget {
  const ProductHistoryDialog({
    super.key,
    required this.productId,
  });

  final int productId;

  static Future<void> show(BuildContext context, {required int productId}) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => ProductHistoryDialog(productId: productId),
    );
  }

  @override
  State<ProductHistoryDialog> createState() => _ProductHistoryDialogState();
}

class _ProductHistoryDialogState extends State<ProductHistoryDialog> {
  bool _isLoading = true;
  String? _error;
  ProductItem? _product;
  List<ProductHistoryEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final product =
          await DatabaseHelper.instance.getProduct(widget.productId);
      final history =
          await DatabaseHelper.instance.getProductHistory(widget.productId);
      if (!mounted) return;
      setState(() {
        _product = product;
        _entries = history;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load stock history: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final productName = _product?.name ?? 'Product';

    return Dialog(
      backgroundColor: Colors.white,
      elevation: 8,
      shadowColor: AppColors.darkGreen.withValues(alpha: 0.16),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 720,
          maxWidth: 860,
          maxHeight: 640,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(productName),
            const Divider(height: 1, color: AppColors.border),
            Expanded(child: _buildBody()),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(String productName) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 14, 16),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F9F4),
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.tagBlueBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.history_rounded,
              size: 20,
              color: AppColors.tagBlueText,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$productName — Stock Movement Ledger',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.darkGreen,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _product == null
                      ? 'Loading product details…'
                      : '${_product!.brand} · ${_product!.packagingSize} · ${_product!.uom}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (_product != null) _stockBadge(_product!),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _stockBadge(ProductItem product) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.tagGreenBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFC6DEC9)),
      ),
      child: Text(
        'Available: ${product.availableStock} ${product.uom}',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.tagGreenText,
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.dangerText),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return _buildEmptyState();
    }
    return Column(
      children: [
        _buildTableHeader(),
        Expanded(
          child: ListView.builder(
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              return _buildTableRow(
                _entries[index],
                isLast: index == _entries.length - 1,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F4F8),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.inventory_2_outlined,
                size: 30,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'No stock movements recorded for this product yet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Sales, restocks, and stock adjustments will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTableHeader() {
    const style = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      color: AppColors.textMuted,
      letterSpacing: 0.3,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
      color: const Color(0xFFF7F9F4),
      child: const Row(
        children: [
          Expanded(flex: 22, child: Text('DATE & TIME', style: style)),
          Expanded(flex: 16, child: Text('TYPE', style: style)),
          Expanded(flex: 16, child: Text('QUANTITY', style: style)),
          Expanded(flex: 28, child: Text('SOURCE / DESTINATION', style: style)),
          Expanded(flex: 18, child: Text('REFERENCE', style: style)),
        ],
      ),
    );
  }

  Widget _buildTableRow(ProductHistoryEntry entry, {required bool isLast}) {
    final dateLabel =
        DateFormat('dd MMM yyyy · hh:mm a').format(entry.dateTime);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 22,
            child: Text(
              dateLabel,
              style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
            ),
          ),
          Expanded(flex: 16, child: _typeBadge(entry)),
          Expanded(
            flex: 16,
            child: Text(
              entry.quantityLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: entry.isStockIn
                    ? AppColors.tagGreenText
                    : AppColors.tagAmberText,
              ),
            ),
          ),
          Expanded(
            flex: 28,
            child: Text(
              entry.partyLabel,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
            ),
          ),
          Expanded(
            flex: 18,
            child: Text(
              entry.referenceId ?? entry.referenceType,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeBadge(ProductHistoryEntry entry) {
    final isIn = entry.isStockIn;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isIn ? AppColors.tagGreenBg : AppColors.tagAmberBg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          entry.typeLabel,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: isIn ? AppColors.tagGreenText : AppColors.tagAmberText,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Text(
            _entries.isEmpty
                ? 'No movements'
                : '${_entries.length} movement${_entries.length == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
