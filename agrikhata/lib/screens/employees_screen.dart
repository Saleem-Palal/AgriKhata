import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/app_auto_suggest_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:agrikhata/theme/theme.dart';

enum EmployeesView { directory, profile }

/// Employee directory + monthly payroll / attendance ledger.
class EmployeesScreen extends StatefulWidget {
  const EmployeesScreen({super.key, this.onViewChanged});

  /// Notifies parent hub so breadcrumbs can update.
  final void Function(EmployeesView view, DbEmployee? employee)? onViewChanged;

  @override
  State<EmployeesScreen> createState() => EmployeesScreenState();
}

class EmployeesScreenState extends State<EmployeesScreen> {
  static final _currency = NumberFormat('#,##,##0');
  static final _displayDate = DateFormat('dd-MMM-yyyy');
  static final _monthLabel = DateFormat('MMMM yyyy');

  EmployeesView _view = EmployeesView.directory;
  List<DbEmployee> _employees = [];
  DbEmployee? _active;
  EmployeeMonthPayroll? _payroll;
  bool _loading = true;
  bool _profileLoading = false;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  EmployeesView get view => _view;
  DbEmployee? get activeEmployee => _active;

  void backToDirectory() {
    setState(() {
      _view = EmployeesView.directory;
      _active = null;
      _payroll = null;
    });
    widget.onViewChanged?.call(_view, null);
  }

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    DatabaseHelper.instance.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDbChanged);
    super.dispose();
  }

  void _onDbChanged() {
    if (_view == EmployeesView.directory) {
      _loadEmployees(silent: true);
    } else if (_active?.id != null) {
      _openProfile(_active!, silent: true);
    }
  }

  Future<void> _loadEmployees({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final rows = await DatabaseHelper.instance.getEmployees(
        activeOnly: false,
      );
      if (!mounted) return;
      setState(() {
        _employees = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Failed to load employees: $e', error: true);
    }
  }

  Future<void> _openProfile(DbEmployee employee, {bool silent = false}) async {
    if (!silent) {
      setState(() {
        _view = EmployeesView.profile;
        _active = employee;
        _profileLoading = true;
      });
      widget.onViewChanged?.call(_view, employee);
    }
    try {
      final payroll = await DatabaseHelper.instance.getEmployeeMonthPayroll(
        employeeId: employee.id!,
        year: _month.year,
        month: _month.month,
      );
      if (!mounted) return;
      setState(() {
        _active = payroll.employee;
        _payroll = payroll;
        _profileLoading = false;
        _view = EmployeesView.profile;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _profileLoading = false);
      _snack('Failed to load payroll: $e', error: true);
    }
  }

  Future<void> _shiftMonth(int delta) async {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _profileLoading = true;
    });
    if (_active != null) await _openProfile(_active!, silent: true);
  }

  void _snack(String msg, {bool error = false}) {
    AppToast.showError(context, msg);
  }

  String _pkr(num amount) => '₨ ${_currency.format(amount.round())}';

  @override
  Widget build(BuildContext context) {
    if (_view == EmployeesView.profile) {
      return _buildProfile();
    }
    return _buildDirectory();
  }

  // ---------------------------------------------------------------------------
  // Directory
  // ---------------------------------------------------------------------------

  Widget _buildDirectory() {
    final active = _employees.where((e) => e.isActive).toList();
    final inactive = _employees.where((e) => !e.isActive).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.cardSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  const Text(
                    'Employees',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  AppButton.primary(
                    label: 'Add Employee',
                    icon: Icons.person_add_alt_1,
                    onPressed: _showAddEmployeeDialog,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
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
                  : _employees.isEmpty
                  ? const Center(
                      child: Text(
                        'No employees yet. Add your first shop employee.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textHint,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: AppDataTable(
                        showCardChrome: false,
                        trailingWidth: 24,
                        minWidth: 720,
                        columns: const [
                          AppDataColumn(title: 'Employee', flex: 28),
                          AppDataColumn(title: 'Role', flex: 16),
                          AppDataColumn(title: 'Pay Type', flex: 12),
                          AppDataColumn(title: 'Salary', flex: 14),
                          AppDataColumn(title: 'Phone', flex: 16),
                          AppDataColumn(title: 'Status', flex: 12),
                        ],
                        rows: [
                          for (final emp in [...active, ...inactive])
                            AppDataRow(
                              onTap: () => _openProfile(emp),
                              trailing: const SizedBox(
                                width: 24,
                                child: Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: AppColors.textHint,
                                ),
                              ),
                              cells: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 14,
                                      backgroundColor: emp.isActive
                                          ? AppColors.tagGreenBg
                                          : const Color(0xFFF0F4EE),
                                      child: Text(
                                        _initials(emp.name),
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: emp.isActive
                                              ? AppColors.tagGreenText
                                              : AppColors.textHint,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        emp.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: emp.isActive
                                              ? AppColors.textPrimary
                                              : AppColors.textMuted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                emp.role.isEmpty ? '—' : emp.role,
                                emp.isDaily ? 'Daily' : 'Monthly',
                                _pkr(emp.baseSalary),
                                emp.phone.isEmpty ? '—' : emp.phone,
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: emp.isActive
                                        ? AppColors.tagGreenBg
                                        : const Color(0xFFF0F4EE),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    emp.isActive ? 'Active' : 'Inactive',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: emp.isActive
                                          ? AppColors.tagGreenText
                                          : AppColors.textHint,
                                    ),
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
      ),
    );
  }

  Widget _employeeRow(DbEmployee emp) {
    return InkWell(
      onTap: () => _openProfile(emp),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: emp.isActive
                  ? AppColors.tagGreenBg
                  : const Color(0xFFF0F4EE),
              child: Text(
                _initials(emp.name),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: emp.isActive
                      ? AppColors.tagGreenText
                      : AppColors.textHint,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    emp.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: emp.isActive
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (emp.role.isNotEmpty) emp.role,
                      emp.isDaily ? 'Daily' : 'Monthly',
                      _pkr(emp.baseSalary),
                      if (emp.phone.isNotEmpty) emp.phone,
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: AppColors.textHint,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Profile / payroll
  // ---------------------------------------------------------------------------

  Widget _buildProfile() {
    final emp = _active;
    final pay = _payroll;
    if (emp == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _profileHeader(emp),
          const SizedBox(height: 12),
          Expanded(
            child: _profileLoading || pay == null
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
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 4, child: _summaryColumn(pay)),
                      const SizedBox(width: 12),
                      Expanded(flex: 6, child: _transactionColumn(pay)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _profileHeader(DbEmployee emp) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.tagGreenBg,
            child: Text(
              _initials(emp.name),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.tagGreenText,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  emp.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (emp.role.isNotEmpty) emp.role,
                    emp.isDaily ? 'Daily wage' : 'Monthly salary',
                    _pkr(emp.baseSalary),
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Previous month',
            onPressed: () => _shiftMonth(-1),
            icon: const Icon(Icons.chevron_left),
            color: AppColors.darkGreen,
          ),
          Text(
            _monthLabel.format(_month),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          IconButton(
            tooltip: 'Next month',
            onPressed: () => _shiftMonth(1),
            icon: const Icon(Icons.chevron_right),
            color: AppColors.darkGreen,
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => _showKharchiDialog(emp),
            icon: const Icon(Icons.payments_outlined, size: 16),
            label: const Text('Add Kharchi'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.darkGreen,
              side: const BorderSide(color: AppColors.inputBorder),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(width: 8),
          if (emp.isActive)
            TextButton(
              onPressed: () => _confirmDeactivate(emp),
              child: const Text(
                'Deactivate',
                style: TextStyle(color: AppColors.dangerText, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _summaryColumn(EmployeeMonthPayroll pay) {
    return Column(
      children: [
        Expanded(
          child: _card(
            title: 'Attendance Summary',
            child: Column(
              children: [
                _statRow(
                  'Present',
                  '${pay.presentDays}',
                  AppColors.tagGreenText,
                ),
                _statRow('Absent', '${pay.absentDays}', AppColors.tagRedText),
                _statRow(
                  'Half-days',
                  '${pay.halfDays}',
                  AppColors.tagAmberText,
                ),
                _statRow('Unmarked', '${pay.unmarkedDays}', AppColors.textHint),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _card(
            title: 'Financial Summary',
            child: Column(
              children: [
                _statRow(
                  'Base Salary',
                  _pkr(pay.baseSalary),
                  AppColors.textPrimary,
                ),
                _statRow(
                  'Earned Amount',
                  _pkr(pay.earnedAmount),
                  AppColors.mediumGreen,
                ),
                _statRow(
                  'Kharchi / Advance',
                  _pkr(pay.kharchiTotal),
                  AppColors.tagAmberText,
                ),
                _statRow(
                  pay.isSettled ? 'Settled Payout' : 'Net Remaining Payable',
                  pay.isSettled
                      ? _pkr(pay.settlementTotal)
                      : _pkr(pay.netRemaining),
                  pay.isSettled ? AppColors.tagBlueText : AppColors.darkGreen,
                  bold: true,
                ),
                if (pay.isSettled)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Month closed',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.tagBlueText,
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: pay.isSettled ? null : () => _confirmSettle(pay),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.darkGreen,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFC6DEC9),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                    child: Text(
                      pay.isSettled
                          ? 'Already Settled'
                          : 'Settle Monthly Salary',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
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

  Widget _transactionColumn(EmployeeMonthPayroll pay) {
    final rows = <_LedgerLine>[];

    for (final e in pay.payrollExpenses) {
      final isKharchi = e.payrollType == ExpensePayrollType.kharchi;
      rows.add(
        _LedgerLine(
          date: e.expenseDate,
          label: isKharchi ? 'Kharchi / Advance' : 'Salary Settlement',
          detail: e.remarks,
          amount: e.amount,
          kind: isKharchi ? _LedgerKind.kharchi : _LedgerKind.settlement,
        ),
      );
    }
    for (final a in pay.attendance) {
      final parsed =
          DateTime.tryParse(a.date) ?? DateTime(_month.year, _month.month);
      rows.add(
        _LedgerLine(
          date: parsed,
          label: _attendanceLabel(a.status),
          detail: 'Attendance',
          amount: null,
          kind: _LedgerKind.attendance,
          status: a.status,
        ),
      );
    }
    rows.sort((a, b) => b.date.compareTo(a.date));

    return _card(
      title: 'Transaction & Attendance History',
      child: rows.isEmpty
          ? const Center(
              child: Text(
                'No attendance or kharchi recorded this month.',
                style: TextStyle(fontSize: 12, color: AppColors.textHint),
              ),
            )
          : ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: Color(0xFFEEF3EC)),
              itemBuilder: (context, i) {
                final row = rows[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 88,
                        child: Text(
                          _displayDate.format(row.date),
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                      _kindBadge(row),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.label,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            if (row.detail.isNotEmpty)
                              Text(
                                row.detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textHint,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (row.amount != null)
                        Text(
                          _pkr(row.amount!),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _card({required String title, required Widget child}) {
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: Padding(padding: const EdgeInsets.all(14), child: child),
          ),
        ],
      ),
    );
  }

  Widget _statRow(
    String label,
    String value,
    Color valueColor, {
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kindBadge(_LedgerLine row) {
    Color bg;
    Color fg;
    String text;
    switch (row.kind) {
      case _LedgerKind.kharchi:
        bg = AppColors.tagAmberBg;
        fg = AppColors.tagAmberText;
        text = 'ADV';
        break;
      case _LedgerKind.settlement:
        bg = AppColors.tagBlueBg;
        fg = AppColors.tagBlueText;
        text = 'PAY';
        break;
      case _LedgerKind.attendance:
        if (row.status == AttendanceStatus.present) {
          bg = AppColors.tagGreenBg;
          fg = AppColors.tagGreenText;
          text = 'P';
        } else if (row.status == AttendanceStatus.absent) {
          bg = AppColors.tagRedBg;
          fg = AppColors.tagRedText;
          text = 'A';
        } else {
          bg = AppColors.tagAmberBg;
          fg = AppColors.tagAmberText;
          text = '½';
        }
        break;
    }
    return Container(
      width: 36,
      padding: const EdgeInsets.symmetric(vertical: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dialogs / actions
  // ---------------------------------------------------------------------------

  Future<void> _showAddEmployeeDialog() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final roleCtrl = TextEditingController();
    final salaryCtrl = TextEditingController();
    var salaryType = EmployeeSalaryType.monthly;
    String? error;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text(
                'Add Employee',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppAutoSuggestField(
                      controller: nameCtrl,
                      labelText: 'Name',
                      isRequired: true,
                      fetchSuggestions: (text) => DatabaseHelper.instance
                          .fetchNameSuggestions(EmployeeTable.name, text),
                    ),
                    const SizedBox(height: 10),
                    _field('Phone', phoneCtrl),
                    const SizedBox(height: 10),
                    _field('Role', roleCtrl, hint: 'e.g. Salesman, Guard'),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Salary type',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('Monthly'),
                          selected: salaryType == EmployeeSalaryType.monthly,
                          onSelected: (_) => setLocal(
                            () => salaryType = EmployeeSalaryType.monthly,
                          ),
                          selectedColor: AppColors.tagGreenBg,
                          labelStyle: TextStyle(
                            color: salaryType == EmployeeSalaryType.monthly
                                ? AppColors.tagGreenText
                                : AppColors.textMuted,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Daily'),
                          selected: salaryType == EmployeeSalaryType.daily,
                          onSelected: (_) => setLocal(
                            () => salaryType = EmployeeSalaryType.daily,
                          ),
                          selectedColor: AppColors.tagGreenBg,
                          labelStyle: TextStyle(
                            color: salaryType == EmployeeSalaryType.daily
                                ? AppColors.tagGreenText
                                : AppColors.textMuted,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _field(
                      salaryType == EmployeeSalaryType.daily
                          ? 'Daily wage (₨) *'
                          : 'Monthly base salary (₨) *',
                      salaryCtrl,
                      keyboard: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        error!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.dangerText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (nameCtrl.text.trim().isEmpty) {
                      setLocal(() => error = 'Name is required');
                      return;
                    }
                    final salary = double.tryParse(salaryCtrl.text.trim());
                    if (salary == null || salary < 0) {
                      setLocal(() => error = 'Enter a valid salary amount');
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.darkGreen,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;
    try {
      await DatabaseHelper.instance.insertEmployee(
        name: nameCtrl.text.trim(),
        phone: phoneCtrl.text.trim(),
        role: roleCtrl.text.trim(),
        salaryType: salaryType,
        baseSalary: double.parse(salaryCtrl.text.trim()),
      );
      _snack('Employee added');
      await _loadEmployees(silent: true);
    } catch (e) {
      _snack('Could not add employee: $e', error: true);
    }
  }

  Future<void> _showKharchiDialog(DbEmployee emp) async {
    final amountCtrl = TextEditingController();
    final remarksCtrl = TextEditingController();
    String? error;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: Text(
                'Kharchi / Advance — ${emp.name}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _field(
                      'Amount (₨) *',
                      amountCtrl,
                      keyboard: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _field('Remarks', remarksCtrl),
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        error!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.dangerText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final amount = double.tryParse(amountCtrl.text.trim());
                    if (amount == null || amount <= 0) {
                      setLocal(() => error = 'Enter a valid amount');
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.darkGreen,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Record'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;
    try {
      await DatabaseHelper.instance.recordEmployeeKharchi(
        employeeId: emp.id!,
        amount: double.parse(amountCtrl.text.trim()),
        remarks: remarksCtrl.text.trim(),
      );
      _snack('Kharchi recorded');
      await _openProfile(emp, silent: true);
    } catch (e) {
      _snack('Could not record kharchi: $e', error: true);
    }
  }

  Future<void> _confirmSettle(EmployeeMonthPayroll pay) async {
    final net = pay.netRemaining;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Settle Monthly Salary',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          net > 0
              ? 'Pay ${_pkr(net)} to ${pay.employee.name} for ${_monthLabel.format(_month)}?\n\nThis will log an Employee Salaries expense and close the month.'
              : 'Advances already cover (or exceed) earned pay for ${_monthLabel.format(_month)}.\n\nClose this month with no additional payout?',
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.darkGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Settle'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await DatabaseHelper.instance.settleEmployeeMonthlySalary(
        employeeId: pay.employee.id!,
        year: pay.year,
        month: pay.month,
      );
      _snack('Month settled');
      await _openProfile(pay.employee, silent: true);
    } catch (e) {
      _snack('Settlement failed: $e', error: true);
    }
  }

  Future<void> _confirmDeactivate(DbEmployee emp) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deactivate employee?'),
        content: Text(
          '${emp.name} will be hidden from the daily attendance register. History is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Deactivate',
              style: TextStyle(color: AppColors.dangerText),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await DatabaseHelper.instance.setEmployeeActive(emp.id!, false);
    _snack('Employee deactivated');
    backToDirectory();
    await _loadEmployees(silent: true);
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    TextInputType? keyboard,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          inputFormatters: inputFormatters,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.inputBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.inputBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(
                color: AppColors.darkGreen,
                width: 1.2,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _attendanceLabel(String status) {
    switch (status) {
      case AttendanceStatus.present:
        return 'Present';
      case AttendanceStatus.absent:
        return 'Absent';
      case AttendanceStatus.halfDay:
        return 'Half-Day';
      default:
        return status;
    }
  }

  static String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final w = parts.first;
      return w.substring(0, w.length >= 2 ? 2 : 1).toUpperCase();
    }
    return ('${parts.first[0]}${parts.last[0]}').toUpperCase();
  }
}

enum _LedgerKind { kharchi, settlement, attendance }

class _LedgerLine {
  _LedgerLine({
    required this.date,
    required this.label,
    required this.detail,
    required this.amount,
    required this.kind,
    this.status,
  });

  final DateTime date;
  final String label;
  final String detail;
  final double? amount;
  final _LedgerKind kind;
  final String? status;
}
