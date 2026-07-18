import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const String _kCustomCategory = 'Other / Add Custom Title';

const List<String> _kCategoryOptions = [
  'Shop Rent',
  'Employee Salaries',
  'Chai/Pani',
  'Chhotu Kharchi',
  'Mazdoori',
  'Electricity / Utilities',
  'Generator / Fuel',
  'License & Permits',
  _kCustomCategory,
];

const Map<String, String> _kCategoryEmoji = {
  'Shop Rent': '🏠',
  'Employee Salaries': '💼',
  'Chai/Pani': '☕',
  'Baraf': '🧊',
  'Chhotu Kharchi': '💸',
  'Mazdoori': '💪',
  'Electricity / Utilities': '🔌',
  'Generator / Fuel': '⛽',
  'License & Permits': '📜',
  _kCustomCategory: '📝',
};

enum _ExpenseFilter { today, thisMonth, allTime }

extension on _ExpenseFilter {
  String get label {
    switch (this) {
      case _ExpenseFilter.today:
        return 'Today';
      case _ExpenseFilter.thisMonth:
        return 'This Month';
      case _ExpenseFilter.allTime:
        return 'All Time';
    }
  }

  String get queryValue {
    switch (this) {
      case _ExpenseFilter.today:
        return 'Today';
      case _ExpenseFilter.thisMonth:
        return 'This Month';
      case _ExpenseFilter.allTime:
        return 'All Time';
    }
  }
}

// ---------------------------------------------------------------------------
// Formatters
// ---------------------------------------------------------------------------

final NumberFormat _currency = NumberFormat('#,##,##0');
final DateFormat _displayDate = DateFormat('dd-MMM-yyyy');
final DateFormat _headerDate = DateFormat('EEEE, d MMMM yyyy');

String _formatPkr(num amount) => '₨ ${_currency.format(amount.round())}';

String _categoryLabel(String category) {
  final emoji = _kCategoryEmoji[category];
  if (emoji == null || emoji.isEmpty) return category;
  return '$emoji $category';
}

/// Formats digit input with Indian/Pakistani grouping while typing.
class _IndianNumberInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text.replaceAll(RegExp(r'[^0-9.]'), '');
    if (raw.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    final parts = raw.split('.');
    final intPart = parts.first;
    final frac = parts.length > 1 ? parts.sublist(1).join() : null;

    final formattedInt = _formatIntegerGroup(intPart);
    final formatted = frac == null
        ? formattedInt
        : '$formattedInt.${frac.length > 2 ? frac.substring(0, 2) : frac}';

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  static String _formatIntegerGroup(String digits) {
    if (digits.isEmpty) return '';
    final cleaned = digits.replaceFirst(RegExp(r'^0+(?=.)'), '');
    if (cleaned.length <= 3) return cleaned;
    final last3 = cleaned.substring(cleaned.length - 3);
    var rest = cleaned.substring(0, cleaned.length - 3);
    final buffer = StringBuffer();
    for (var i = 0; i < rest.length; i++) {
      if (i > 0 && (rest.length - i) % 2 == 0) buffer.write(',');
      buffer.write(rest[i]);
    }
    return '${buffer.toString()},$last3';
  }
}

double? _parseFormattedAmount(String text) {
  final cleaned = text.replaceAll(',', '').trim();
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class ExpenseScreen extends StatefulWidget {
  const ExpenseScreen({super.key});

  @override
  State<ExpenseScreen> createState() => _ExpenseScreenState();
}

class _ExpenseScreenState extends State<ExpenseScreen> {
  final _amountController = TextEditingController();
  final _remarksController = TextEditingController();
  final _customCategoryController = TextEditingController();

  _ExpenseFilter _filter = _ExpenseFilter.today;
  String _selectedCategory = 'Chai/Pani';
  List<DbExpense> _expenses = [];
  double _todayTotal = 0;
  bool _loading = true;
  bool _saving = false;
  String? _formError;

  bool get _isCustomCategory => _selectedCategory == _kCustomCategory;

  @override
  void initState() {
    super.initState();
    _loadExpenses();
    DatabaseHelper.instance.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDbChanged);
    _amountController.dispose();
    _remarksController.dispose();
    _customCategoryController.dispose();
    super.dispose();
  }

  void _onDbChanged() => _loadExpenses(silent: true);

  Future<void> _loadExpenses({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final db = DatabaseHelper.instance;
      final rows = await db.getExpensesFilter(filterType: _filter.queryValue);
      final todayRows = await db.getExpensesFilter(filterType: 'Today');
      final todayTotal = todayRows.fold<double>(0, (sum, e) => sum + e.amount);
      if (!mounted) return;
      setState(() {
        _expenses = rows;
        _todayTotal = todayTotal;
        _loading = false;
        _formError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _formError = 'Failed to load expenses: $e';
      });
    }
  }

  Future<void> _setFilter(_ExpenseFilter filter) async {
    if (_filter == filter) return;
    setState(() => _filter = filter);
    await _loadExpenses();
  }

  Future<void> _saveExpense() async {
    final amount = _parseFormattedAmount(_amountController.text);
    final category = _isCustomCategory
        ? _customCategoryController.text.trim()
        : _selectedCategory.trim();

    if (category.isEmpty) {
      setState(() {
        _formError = _isCustomCategory
            ? 'Enter a custom expense title'
            : 'Select an expense category';
      });
      return;
    }
    if (amount == null || amount <= 0) {
      setState(() => _formError = 'Enter a valid amount greater than zero');
      return;
    }

    setState(() {
      _saving = true;
      _formError = null;
    });

    try {
      await DatabaseHelper.instance.insertExpense(
        category,
        amount,
        _remarksController.text.trim(),
      );
      if (!mounted) return;
      _resetForm();
      await _loadExpenses(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Expense saved'),
          backgroundColor: AppColors.mediumGreen,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _formError = 'Could not save expense: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetForm() {
    _amountController.clear();
    _remarksController.clear();
    _customCategoryController.clear();
    setState(() {
      _selectedCategory = 'Chai/Pani';
      _formError = null;
    });
  }

  double get _filteredTotal =>
      _expenses.fold<double>(0, (sum, e) => sum + e.amount);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();

    return ColoredBox(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AgriHeader(
            breadcrumbs: const ['Finance', 'Expenses'],
            actions: [
              Text(
                _headerDate.format(now),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textHint,
                ),
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 7,
                    child: _buildLedgerCard(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: _buildFormPanel(now),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Left: Expense History Ledger
  // -------------------------------------------------------------------------

  Widget _buildLedgerCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                const Text(
                  '💸 Expense History Ledger',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                _buildFilterToggle(),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.mediumGreen,
                      ),
                    ),
                  )
                : _expenses.isEmpty
                    ? _buildEmptyLedger()
                    : _buildExpenseTable(),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Text(
                  'Showing ${_expenses.length} of ${_expenses.length} entries',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textHint,
                  ),
                ),
                const Spacer(),
                Text(
                  'Total: ${_formatPkr(_filteredTotal)}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterToggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.inputBorder, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _ExpenseFilter.values.map((filter) {
          final active = _filter == filter;
          return Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _setFilter(filter),
                borderRadius: BorderRadius.circular(7),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? AppColors.darkGreen
                        : const Color(0xFFF7F9F4),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    filter.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: active ? Colors.white : AppColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEmptyLedger() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 36,
              color: AppColors.textHint.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 10),
            Text(
              'No expenses for ${_filter.label.toLowerCase()}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Record a new expense using the panel on the right.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: AppColors.textHint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpenseTable() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: AppColors.border, width: 0.5),
            ),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 96,
                child: Text(
                  'DATE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  'CATEGORY',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  'AMOUNT (₨)',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: Text(
                  'REMARKS / DETAILS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _expenses.length,
            itemBuilder: (context, index) {
              final expense = _expenses[index];
              final odd = index.isEven;
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: odd ? const Color(0xFFFAFBF8) : Colors.white,
                  border: Border(
                    bottom: BorderSide(
                      color: index == _expenses.length - 1
                          ? Colors.transparent
                          : const Color(0xFFEEF3EC),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        _displayDate.format(expense.expenseDate),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        _categoryLabel(expense.category),
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(
                      width: 110,
                      child: Text(
                        _formatPkr(expense.amount),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 5,
                      child: Text(
                        expense.remarks.isEmpty ? '—' : expense.remarks,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF4B5A50),
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Right: Record New Expense
  // -------------------------------------------------------------------------

  Widget _buildFormPanel(DateTime now) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '➕ Record New Expense',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            _fieldLabel('🗓️ Date'),
            _readOnlyValue(_displayDate.format(now)),
            const SizedBox(height: 12),
            _fieldLabel('Category'),
            _buildCategoryDropdown(),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _isCustomCategory
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _fieldLabel('Enter Custom Expense Title'),
                          _textField(
                            controller: _customCategoryController,
                            hint: 'e.g., Baraf, Paper Roll, etc.',
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 12),
            _fieldLabel('Amount'),
            _buildAmountField(),
            const SizedBox(height: 12),
            _fieldLabel('Remarks / Details'),
            _textField(
              controller: _remarksController,
              hint: 'Short note, e.g. Tea for driver waiting on delivery',
              maxLines: 3,
            ),
            if (_formError != null) ...[
              const SizedBox(height: 10),
              Text(
                _formError!,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.dangerText,
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _saveExpense,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF047857),
                  disabledBackgroundColor: const Color(0xFF047857)
                      .withValues(alpha: 0.55),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Save Expense',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.recBg,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.recBorder, width: 0.5),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Today's Total Expenses",
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.mediumGreen,
                      ),
                    ),
                  ),
                  Text(
                    _formatPkr(_todayTotal),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: Color(0xFF4B5A50),
        ),
      ),
    );
  }

  Widget _buildCategoryDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.inputBorder, width: 0.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedCategory,
          isExpanded: true,
          icon: const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: AppColors.textMuted,
            size: 20,
          ),
          style: const TextStyle(
            fontSize: 12.5,
            color: AppColors.textPrimary,
          ),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(8),
          items: _kCategoryOptions.map((option) {
            return DropdownMenuItem<String>(
              value: option,
              child: Text(
                _categoryLabel(option),
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _selectedCategory = value;
              _formError = null;
              if (value != _kCustomCategory) {
                _customCategoryController.clear();
              }
            });
          },
        ),
      ),
    );
  }

  Widget _buildAmountField() {
    return TextField(
      controller: _amountController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        _IndianNumberInputFormatter(),
      ],
      style: const TextStyle(
        fontSize: 12.5,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: 'e.g. 500',
        hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 12.5),
        prefixIcon: const Padding(
          padding: EdgeInsets.only(left: 10, right: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: Text(
              'Rs. ',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(
            color: AppColors.inputBorder,
            width: 0.5,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.accentGreen, width: 1),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(
            color: AppColors.inputBorder,
            width: 0.5,
          ),
        ),
      ),
    );
  }

  Widget _readOnlyValue(String value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.inputBorder, width: 0.5),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 12.5,
          color: AppColors.textPrimary.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    String? hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(
        fontSize: 12.5,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 12.5),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(
            color: AppColors.inputBorder,
            width: 0.5,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.accentGreen, width: 1),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(
            color: AppColors.inputBorder,
            width: 0.5,
          ),
        ),
      ),
    );
  }
}
