import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:flutter/material.dart';

class ZamindarKisaansTab extends StatefulWidget {
  final int zamindarId;
  final String zamindarName;
  final bool autoOpenAdd;

  const ZamindarKisaansTab({
    super.key,
    required this.zamindarId,
    required this.zamindarName,
    this.autoOpenAdd = false,
  });

  @override
  State<ZamindarKisaansTab> createState() => _ZamindarKisaansTabState();
}

class _ZamindarKisaansTabState extends State<ZamindarKisaansTab> {
  List<Kisaan> _kisaans = [];
  Map<int, double> _kisaanBalances = {};
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadKisaans();
    if (widget.autoOpenAdd) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openKisaanPanel();
      });
    }
  }

  Future<void> _loadKisaans() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final kisaans = await DatabaseHelper.instance.getKisaansForZamindar(
        widget.zamindarId,
      );

      final Map<int, double> balances = {};
      for (final kisaan in kisaans) {
        if (kisaan.id != null) {
          final balance = await DatabaseHelper.instance.getKisaanBalanceDue(
            kisaan.id!,
          );
          balances[kisaan.id!] = balance;
        }
      }

      if (!mounted) return;
      setState(() {
        _kisaans = kisaans;
        _kisaanBalances = balances;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Failed to load kisaans: $e';
      });
    }
  }

  void _openKisaanPanel({Kisaan? editTarget}) async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: editTarget == null ? "Add Kisaan" : "Edit Kisaan",
      barrierColor: AppColors.darkGreen.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 340,
            height: double.infinity,
            child: _AddKisaanPanel(
              zamindarId: widget.zamindarId,
              zamindarName: widget.zamindarName,
              editTarget: editTarget,
              onSaved: (kisaan) async {
                try {
                  final zamindar = await DatabaseHelper.instance.getZamindar(widget.zamindarId);
                  if (zamindar == null) {
                    throw Exception('Zamindar not found');
                  }

                  final totalAllocated = await DatabaseHelper.instance.getTotalAllocatedLandForZamindar(
                    widget.zamindarId,
                    excludeKisaanId: editTarget?.id,
                  );

                  final zamindarTotalLand = zamindar.landArea;
                  final newTotal = totalAllocated + kisaan.landAcres;

                  if (newTotal > zamindarTotalLand) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Cannot allocate land. Total assigned (${newTotal.toStringAsFixed(2)} Acres) exceeds Zamindar\'s limit (${zamindarTotalLand.toStringAsFixed(2)} Acres).',
                          ),
                          backgroundColor: Colors.red,
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    }
                    return;
                  }

                  if (editTarget == null) {
                    await DatabaseHelper.instance.insertKisaan(kisaan);
                  } else {
                    await DatabaseHelper.instance.updateKisaan(kisaan);
                  }

                  Navigator.pop(context);
                  await _loadKisaans();

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          editTarget == null
                              ? '✓ Kisaan "${kisaan.name}" created successfully!'
                              : '✓ Kisaan "${kisaan.name}" updated successfully!',
                        ),
                        backgroundColor: AppColors.darkGreen,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error saving kisaan: $e'),
                        backgroundColor: Colors.red,
                      ),
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

  void _viewKisaanLedger(Kisaan kisaan) async {
    if (kisaan.id == null) return;

    List<LedgerTransaction> transactions = [];
    try {
      final allTransactions = await DatabaseHelper.instance
          .getLedgerTransactionsForZamindar(widget.zamindarId);
      transactions = allTransactions
          .where((t) => t.kisaanId == kisaan.id)
          .toList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading ledger: $e')),
        );
      }
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        contentPadding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: SizedBox(
          width: 650,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header Block
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.darkGreen,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kisaan.name.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Kisaan Account Statement · Under ${widget.zamindarName}",
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFFA7C4A0),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: "Print Statement",
                          icon: const Icon(
                            Icons.print_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () {},
                        ),
                        IconButton(
                          tooltip: "Share via WhatsApp",
                          icon: const Icon(
                            Icons.share_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () {},
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Prominent KPI Cards Row
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F7F1),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "TOTAL OUTSTANDING",
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "Rs ${_fmt(_kisaanBalances[kisaan.id] ?? 0)}",
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFA32D2D),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F7F1),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "CROP AREA DETAILS",
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "${kisaan.landAcres.toStringAsFixed(0)} Acres · ${kisaan.currentCrop}",
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.darkGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Itemized Transactions Data Table
              Padding(
                padding: const EdgeInsets.only(left: 20, right: 20, bottom: 20),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border, width: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: transactions.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                'No transactions yet',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          )
                        : DataTable(
                            headingRowHeight: 34,
                            dataRowMinHeight: 36,
                            dataRowMaxHeight: 38,
                            headingRowColor: WidgetStateProperty.all(
                              const Color(0xFFEAF3DE),
                            ),
                            horizontalMargin: 12,
                            columns: const [
                              DataColumn(
                                label: Text(
                                  'Date',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.darkGreen,
                                  ),
                                ),
                              ),
                              DataColumn(
                                label: Text(
                                  'Description',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.darkGreen,
                                  ),
                                ),
                              ),
                              DataColumn(
                                label: Text(
                                  'Type',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.darkGreen,
                                  ),
                                ),
                              ),
                              DataColumn(
                                label: Text(
                                  'Amount',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.darkGreen,
                                  ),
                                ),
                              ),
                            ],
                            rows: transactions
                                .map(
                                  (t) => DataRow(
                                    cells: [
                                      DataCell(
                                        Text(
                                          "${t.dateTime.day}/${t.dateTime.month}/${t.dateTime.year}",
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          t.description,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      DataCell(
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: t.type ==
                                                    LedgerTransactionType.debit
                                                ? const Color(0xFFFCEBEB)
                                                : const Color(0xFFE6F1FB),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            t.type ==
                                                    LedgerTransactionType.debit
                                                ? 'Debit'
                                                : 'Credit',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w500,
                                              color: t.type ==
                                                      LedgerTransactionType
                                                          .debit
                                                  ? const Color(0xFF791F1F)
                                                  : const Color(0xFF0C447C),
                                            ),
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          "Rs ${_fmt(t.amount.toDouble())}",
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                ),
              ),

              // Action Bar
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFFFAFAFA),
                  border: Border(
                    top: BorderSide(color: AppColors.border, width: 0.5),
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.picture_as_pdf_outlined, size: 14),
                      label: const Text(
                        "Export PDF Receipt",
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.send, size: 14),
                      label: const Text(
                        "WhatsApp Statement",
                        style: TextStyle(fontSize: 11),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSettlementForm() async {
    await showDialog(
      context: context,
      builder: (context) => _BillSettlementDialog(
        zamindarId: widget.zamindarId,
        zamindarName: widget.zamindarName,
        kisaans: _kisaans,
        onSettlementApplied: (selectedKisaanId, amount) async {
          try {
            final transaction = LedgerTransaction(
              zamindarId: widget.zamindarId,
              kisaanId: selectedKisaanId,
              type: LedgerTransactionType.credit,
              category: 'PAYMENT',
              description: 'Payment received',
              amount: amount.round(),
              dateTime: DateTime.now(),
              season: '',
            );
            await DatabaseHelper.instance.insertLedgerTransaction(transaction);
            await _loadKisaans();
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error recording payment: $e')),
              );
            }
          }
        },
      ),
    );
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
              onPressed: _loadKisaans,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppColors.border, width: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                  child: Text(
                    "${_kisaans.length} Kisaans under ${widget.zamindarName}",
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.darkGreen,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _openSettlementForm,
                      icon: const Icon(
                        Icons.payment_outlined,
                        size: 14,
                        color: Color(0xFF27500A),
                      ),
                      label: const Text(
                        "Bill Settlement",
                        style: TextStyle(fontSize: 12, color: Color(0xFF27500A)),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF27500A)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _openKisaanPanel(),
                      icon: const Icon(Icons.person_add_outlined, size: 15),
                      label: const Text("Add Kisaan"),
                    ),
                  ],
                ),
              ),
              ...List.generate(
                _kisaans.length,
                (i) => _kisaanRow(_kisaans[i], isLast: i == _kisaans.length - 1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kisaanRow(Kisaan k, {required bool isLast}) {
    final initials = k.name
        .split(' ')
        .where((e) => e.isNotEmpty)
        .map((e) => e[0].toUpperCase())
        .take(2)
        .join();
    final balanceDue = _kisaanBalances[k.id] ?? 0;
    final isSettled = balanceDue == 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: const Color(0xFFEAF3DE),
            child: Text(
              initials,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF27500A),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  k.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.darkGreen,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "${k.village} · ${k.landAcres.toStringAsFixed(0)} Acres · ${k.currentCrop}",
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                "Rs ${_fmt(balanceDue)}",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isSettled
                      ? const Color(0xFF27500A)
                      : const Color(0xFFA32D2D),
                ),
              ),
              Text(
                isSettled ? "Settled" : "Balance due",
                style: const TextStyle(fontSize: 9, color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(width: 14),
          _smallBtn(Icons.receipt_long_outlined, "Sale", () {}),
          const SizedBox(width: 5),
          _smallBtn(
            Icons.menu_book_outlined,
            "Ledger",
            () => _viewKisaanLedger(k),
          ),
          const SizedBox(width: 5),
          _smallBtn(
            Icons.edit_outlined,
            "Edit",
            () => _openKisaanPanel(editTarget: k),
          ),
        ],
      ),
    );
  }

  Widget _smallBtn(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 12),
      label: Text(label, style: const TextStyle(fontSize: 10)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        side: const BorderSide(color: AppColors.sidebarBg, width: 0.5),
      ),
    );
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

class _AddKisaanPanel extends StatefulWidget {
  final int zamindarId;
  final String zamindarName;
  final Kisaan? editTarget;
  final void Function(Kisaan kisaan) onSaved;
  final VoidCallback onCancel;

  const _AddKisaanPanel({
    required this.zamindarId,
    required this.zamindarName,
    this.editTarget,
    required this.onSaved,
    required this.onCancel,
  });

  @override
  State<_AddKisaanPanel> createState() => _AddKisaanPanelState();
}

class _AddKisaanPanelState extends State<_AddKisaanPanel> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _villageController = TextEditingController();
  final _phoneController = TextEditingController();
  final _landController = TextEditingController();
  String _selectedCrop = "Rice";
  String _landUnit = "Acre";

  final List<String> _crops = [
    "Rice",
    "Wheat",
    "Cotton",
    "Sugarcane",
    "Maize",
    "Mustard",
    "Potato",
    "Onion",
  ];

  @override
  void initState() {
    super.initState();
    if (widget.editTarget != null) {
      _nameController.text = widget.editTarget!.name;
      _villageController.text = widget.editTarget!.village;
      _phoneController.text = widget.editTarget!.phone ?? '';
      _landController.text = widget.editTarget!.landAcres.toStringAsFixed(2);
      _selectedCrop = widget.editTarget!.currentCrop;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _villageController.dispose();
    _phoneController.dispose();
    _landController.dispose();
    super.dispose();
  }

  double _convertToAcres(double value, String unit) {
    if (unit == "Athaas") return value * 4;
    return value;
  }

  String _getConversionText() {
    final inputValue = double.tryParse(_landController.text);
    if (inputValue == null || inputValue == 0) return "";

    if (_landUnit == "Acre") {
      final athaas = inputValue / 4;
      return "= ${athaas.toStringAsFixed(2)} Athaas";
    } else {
      final acres = inputValue * 4;
      return "= ${acres.toStringAsFixed(2)} Acres";
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final landValue = double.tryParse(_landController.text) ?? 0.0;
    final landInAcres = _convertToAcres(landValue, _landUnit);

    final kisaan = Kisaan(
      id: widget.editTarget?.id,
      zamindarId: widget.zamindarId,
      name: _nameController.text.trim(),
      village: _villageController.text.trim(),
      phone: _phoneController.text.trim().isEmpty
          ? null
          : _phoneController.text.trim(),
      landAcres: landInAcres,
      currentCrop: _selectedCrop,
    );
    widget.onSaved(kisaan);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            Container(
              color: AppColors.darkGreen,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.editTarget == null
                          ? "Add Kisaan"
                          : "Update Kisaan Profile",
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
                    _buildFormField(
                      label: "Full name",
                      controller: _nameController,
                      required: true,
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Name is required';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _buildFormField(
                            label: "Village",
                            controller: _villageController,
                            required: true,
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Village is required';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildFormField(
                            label: "Phone",
                            controller: _phoneController,
                            required: true,
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Phone is required';
                              }
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.darkGreen,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              InkWell(
                                onTap: () => setState(() => _landUnit = "Acre"),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _landUnit == "Acre" ? Colors.white : Colors.transparent,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    "Acre",
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: _landUnit == "Acre" ? AppColors.darkGreen : Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              InkWell(
                                onTap: () => setState(() => _landUnit = "Athaas"),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _landUnit == "Athaas" ? Colors.white : Colors.transparent,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    "Athaas",
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: _landUnit == "Athaas" ? AppColors.darkGreen : Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: _buildFormField(
                            label: "Land ($_landUnit)",
                            controller: _landController,
                            required: true,
                            isNumber: true,
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Land area is required';
                              }
                              final number = double.tryParse(val.trim());
                              if (number == null || number <= 0) {
                                return 'Enter valid land area';
                              }
                              return null;
                            },
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
                                    "Current crop",
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: AppColors.textMuted,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const Text(
                                    " *",
                                    style: TextStyle(color: Colors.red, fontSize: 10),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              DropdownButtonFormField<String>(
                                value: _selectedCrop,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(7),
                                    borderSide: const BorderSide(
                                      color: AppColors.sidebarBg,
                                      width: 0.5,
                                    ),
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                ),
                                items: _crops
                                    .map(
                                      (c) => DropdownMenuItem(
                                        value: c,
                                        child: Text(
                                          c,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (val) =>
                                    setState(() => _selectedCrop = val!),
                                validator: (val) {
                                  if (val == null || val.isEmpty) {
                                    return 'Crop is required';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_getConversionText().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        _getConversionText(),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.darkGreen,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.border, width: 0.5),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: widget.onCancel,
                    child: const Text("Cancel"),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _save,
                    child: Text(
                      widget.editTarget == null ? "Save Kisaan" : "Update Kisaan",
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

  Widget _buildFormField({
    required String label,
    required TextEditingController controller,
    bool required = false,
    bool isNumber = false,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (required)
              const Text(
                " *",
                style: TextStyle(color: Colors.red, fontSize: 10),
              ),
          ],
        ),
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          keyboardType: isNumber ? TextInputType.number : TextInputType.text,
          style: const TextStyle(fontSize: 12),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(
                color: AppColors.sidebarBg,
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(
                color: AppColors.darkGreen,
                width: 1,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(
                color: Colors.red,
                width: 1,
              ),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(
                color: Colors.red,
                width: 1,
              ),
            ),
            errorStyle: const TextStyle(fontSize: 9),
          ),
          validator: validator,
        ),
      ],
    );
  }
}

// Professional & Polished Bill Settlement Window UI Layout Component
class _BillSettlementDialog extends StatefulWidget {
  final int zamindarId;
  final String zamindarName;
  final List<Kisaan> kisaans;
  final void Function(int selectedKisaanId, double amount) onSettlementApplied;

  const _BillSettlementDialog({
    required this.zamindarId,
    required this.zamindarName,
    required this.kisaans,
    required this.onSettlementApplied,
  });

  @override
  State<_BillSettlementDialog> createState() => _BillSettlementDialogState();
}

class _BillSettlementDialogState extends State<_BillSettlementDialog> {
  int? _selectedKisaanId;
  final _amountController = TextEditingController();
  bool _showReceiptActions = false;
  String _lastSettledKisaanName = "";

  @override
  void initState() {
    super.initState();
    if (widget.kisaans.isNotEmpty && widget.kisaans.first.id != null) {
      _selectedKisaanId = widget.kisaans.first.id;
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Panel Header Block
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.darkGreen,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.account_balance_wallet_outlined,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "Recovery & Bill Settlement",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: const Icon(
                        Icons.close,
                        color: Color(0xFFA7C4A0),
                        size: 18,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              if (!_showReceiptActions) ...[
                // Input Workflow View
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F7F1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.business_outlined,
                              size: 16,
                              color: AppColors.darkGreen,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "Payer Zamindar: ${widget.zamindarName}",
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.darkGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        "Select Kisaan Account Account",
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<int>(
                        value: _selectedKisaanId,
                        isExpanded: true,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: const BorderSide(
                              color: AppColors.sidebarBg,
                              width: 0.5,
                            ),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                        items: widget.kisaans
                            .where((k) => k.id != null)
                            .map(
                              (k) => DropdownMenuItem(
                                value: k.id,
                                child: Text(
                                  "${k.name} (Balance: Rs ${k.landAcres.toStringAsFixed(0)} acres)",
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (val) =>
                            setState(() => _selectedKisaanId = val),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        "Collected Amount Payment (Rs)",
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _amountController,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.darkGreen,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixText: "Rs ",
                          prefixStyle: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColors.darkGreen,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          hintText: "0",
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: const BorderSide(
                              color: AppColors.sidebarBg,
                              width: 0.5,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: const BorderSide(
                              color: AppColors.darkGreen,
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Regular Footer Panel Action
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFAFAFA),
                    border: Border(
                      top: BorderSide(color: AppColors.border, width: 0.5),
                    ),
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          "Cancel",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          final amt =
                              double.tryParse(_amountController.text) ?? 0;
                          if (_selectedKisaanId != null && amt > 0) {
                            final targetKisaan = widget.kisaans.firstWhere(
                              (k) => k.id == _selectedKisaanId,
                            );
                            widget.onSettlementApplied(_selectedKisaanId!, amt);
                            setState(() {
                              _lastSettledKisaanName = targetKisaan.name;
                              _showReceiptActions = true;
                            });
                          }
                        },
                        child: const Text(
                          "Post Voucher Entry",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Modern Success Voucher Receipts Actions Panel View Look
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const CircleAvatar(
                        radius: 20,
                        backgroundColor: Color(0xFFEAF3DE),
                        child: Icon(
                          Icons.check_circle_outline,
                          color: Color(0xFF27500A),
                          size: 24,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        "Ledger Updated Successfully",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.darkGreen,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Voucher allocated to $_lastSettledKisaanName",
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFAFAFA),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Amount Settled:",
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              "Rs ${_amountController.text}",
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF27500A),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {},
                              icon: const Icon(Icons.print, size: 14),
                              label: const Text(
                                "Print Receipt",
                                style: TextStyle(fontSize: 11),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {},
                              icon: const Icon(Icons.send, size: 14),
                              label: const Text(
                                "WhatsApp PDF",
                                style: TextStyle(fontSize: 11),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF25D366),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          "Done & Close Window",
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
