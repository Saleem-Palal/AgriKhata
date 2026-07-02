import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:flutter/material.dart';

class ZamindarLedgerTab extends StatefulWidget {
  final int zamindarId;

  const ZamindarLedgerTab({super.key, required this.zamindarId});

  @override
  State<ZamindarLedgerTab> createState() => _ZamindarLedgerTabState();
}

class _ZamindarLedgerTabState extends State<ZamindarLedgerTab> {
  String _selectedSeason = "All seasons";
  List<LedgerTransaction> _allTransactions = [];
  bool _isLoading = true;
  String? _loadError;

  List<String> _seasons = ["All seasons"];

  @override
  void initState() {
    super.initState();
    _loadLedgerData();
  }

  Future<void> _loadLedgerData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final transactions = await DatabaseHelper.instance
          .getLedgerTransactionsForZamindar(widget.zamindarId);

      final uniqueSeasons = transactions
          .map((t) => t.season)
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

      if (!mounted) return;
      setState(() {
        _allTransactions = transactions;
        _seasons = ["All seasons", ...uniqueSeasons];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Failed to load ledger: $e';
      });
    }
  }

  List<LedgerTransaction> get _filteredTransactions {
    if (_selectedSeason == "All seasons") {
      return _allTransactions;
    }
    return _allTransactions.where((t) => t.season == _selectedSeason).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              style: const TextStyle(color: AppColors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _loadLedgerData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final filtered = _filteredTransactions;
    final totalDebit = filtered
        .where((e) => e.type == LedgerTransactionType.debit)
        .fold(0, (sum, e) => sum + e.amount);
    final totalCredit = filtered
        .where((e) => e.type == LedgerTransactionType.credit)
        .fold(0, (sum, e) => sum + e.amount);

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _summaryCard(
                    "Total sales (debit)",
                    "Rs ${_fmt(totalDebit.toDouble())}",
                    const Color(0xFFA32D2D),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _summaryCard(
                    "Total payments received",
                    "Rs ${_fmt(totalCredit.toDouble())}",
                    const Color(0xFF0C447C),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _summaryCard(
                    "Net balance",
                    "Rs ${_fmt((totalDebit - totalCredit).toDouble())}",
                    const Color(0xFF27500A),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildFilterBar(),
            const SizedBox(height: 14),
            Expanded(child: _buildLedgerList()),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Row(
      children: [
        _dropdown(
          _seasons,
          _selectedSeason,
          (val) => setState(() => _selectedSeason = val!),
        ),
        const Spacer(),
        Text(
          "${_filteredTransactions.length} transactions",
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        const SizedBox(width: 14),
        _exportBtn(Icons.print_outlined, "Print"),
        const SizedBox(width: 8),
        _exportBtn(Icons.chat_outlined, "WhatsApp PDF"),
        const SizedBox(width: 8),
        _exportBtn(Icons.table_chart_outlined, "Excel"),
      ],
    );
  }

  Widget _dropdown(
    List<String> options,
    String value,
    ValueChanged<String?> onChanged,
  ) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
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

  Widget _exportBtn(IconData icon, String label) {
    return OutlinedButton.icon(
      onPressed: () {},
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: AppColors.sidebarBg, width: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }

  Widget _buildLedgerList() {
    final filtered = _filteredTransactions;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: filtered.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No ledger entries yet',
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: filtered.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: AppColors.border),
              itemBuilder: (context, i) {
                final txn = filtered[i];
                final isDebit = txn.type == LedgerTransactionType.debit;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(right: 10),
                        decoration: BoxDecoration(
                          color: isDebit
                              ? const Color(0xFFC0DD97)
                              : const Color(0xFF85B7EB),
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              txn.description,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.darkGreen,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Text(
                                  _formatDate(txn.dateTime),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                                if (txn.category.isNotEmpty) ...[
                                  const Text(
                                    ' · ',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                  Text(
                                    txn.category,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      Text(
                        "${isDebit ? '+' : '−'}Rs ${_fmt(txn.amount.toDouble())}",
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isDebit
                              ? const Color(0xFFA32D2D)
                              : const Color(0xFF0C447C),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
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
