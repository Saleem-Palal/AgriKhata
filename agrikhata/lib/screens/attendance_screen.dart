import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:agrikhata/theme/theme.dart';

/// Daily attendance register — toggle P / A / ½ per active employee.
/// Unmarked days leave no row in [employee_attendance].
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  static final _dayHeader = DateFormat('EEEE, d MMMM yyyy');
  static final _dateKey = DateFormat('yyyy-MM-dd');

  DateTime _selectedDate = DateTime.now();
  List<DbEmployee> _employees = [];
  Map<int, String> _statusByEmployee = {};
  bool _loading = true;
  final Set<int> _savingIds = {};

  String get _dateIso {
    final d = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    return _dateKey.format(d);
  }

  @override
  void initState() {
    super.initState();
    _load();
    DatabaseHelper.instance.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDbChanged);
    super.dispose();
  }

  void _onDbChanged() => _load(silent: true);

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final employees = await DatabaseHelper.instance.getEmployees(activeOnly: true);
      final statuses =
          await DatabaseHelper.instance.getAttendanceForDate(_dateIso);
      if (!mounted) return;
      setState(() {
        _employees = employees;
        _statusByEmployee = statuses;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppToast.showError(context, 'Failed to load attendance: $e');
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: AppColors.darkGreen,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() => _selectedDate = picked);
    await _load();
  }

  Future<void> _shiftDay(int delta) async {
    setState(() {
      _selectedDate = _selectedDate.add(Duration(days: delta));
    });
    await _load();
  }

  /// Toggle semantics: tap selected status again → Unmarked (delete row).
  Future<void> _toggleStatus(int employeeId, String status) async {
    if (_savingIds.contains(employeeId)) return;
    final current = _statusByEmployee[employeeId];
    final next = current == status ? null : status;

    setState(() {
      _savingIds.add(employeeId);
      if (next == null) {
        _statusByEmployee.remove(employeeId);
      } else {
        _statusByEmployee[employeeId] = next;
      }
    });

    try {
      await DatabaseHelper.instance.setAttendanceStatus(
        employeeId: employeeId,
        date: _dateIso,
        status: next,
      );
    } catch (e) {
      if (!mounted) return;
      await _load(silent: true);
      if (!mounted) return;
      AppToast.showError(context, 'Could not update attendance: $e');
    } finally {
      if (mounted) {
        setState(() => _savingIds.remove(employeeId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
            _buildToolbar(),
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
                      ? _buildEmpty()
                      : _buildList(),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          const Text(
            'Daily Attendance Register',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Previous day',
            onPressed: () => _shiftDay(-1),
            icon: const Icon(Icons.chevron_left, size: 20),
            color: AppColors.darkGreen,
            visualDensity: VisualDensity.compact,
          ),
          TextButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_today_outlined, size: 14),
            label: Text(_dayHeader.format(_selectedDate)),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.darkGreen,
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next day',
            onPressed: () => _shiftDay(1),
            icon: const Icon(Icons.chevron_right, size: 20),
            color: AppColors.darkGreen,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No active employees yet.\nAdd employees from the Employees screen.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.textHint, height: 1.45),
        ),
      ),
    );
  }

  Widget _buildList() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _employees.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: Color(0xFFEEF3EC)),
      itemBuilder: (context, index) {
        final emp = _employees[index];
        final id = emp.id!;
        final status = _statusByEmployee[id];
        final busy = _savingIds.contains(id);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.tagGreenBg,
                child: Text(
                  _initials(emp.name),
                  style: const TextStyle(
                    fontSize: 11,
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
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (emp.role.isNotEmpty) emp.role,
                        emp.isDaily ? 'Daily wage' : 'Monthly salary',
                      ].join(' · '),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.mediumGreen,
                  ),
                )
              else
                _AttendanceToggle(
                  status: status,
                  onPresent: () => _toggleStatus(id, AttendanceStatus.present),
                  onAbsent: () => _toggleStatus(id, AttendanceStatus.absent),
                  onHalf: () => _toggleStatus(id, AttendanceStatus.halfDay),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFooter() {
    final marked = _statusByEmployee.length;
    final present = _statusByEmployee.values
        .where((s) => s == AttendanceStatus.present)
        .length;
    final absent = _statusByEmployee.values
        .where((s) => s == AttendanceStatus.absent)
        .length;
    final half = _statusByEmployee.values
        .where((s) => s == AttendanceStatus.halfDay)
        .length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Text(
            '${_employees.length} employees · $marked marked',
            style: const TextStyle(fontSize: 11, color: AppColors.textHint),
          ),
          const Spacer(),
          Text(
            'P $present  ·  A $absent  ·  ½ $half',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
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

class _AttendanceToggle extends StatelessWidget {
  const _AttendanceToggle({
    required this.status,
    required this.onPresent,
    required this.onAbsent,
    required this.onHalf,
  });

  final String? status;
  final VoidCallback onPresent;
  final VoidCallback onAbsent;
  final VoidCallback onHalf;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _chip(
          label: 'P',
          tooltip: 'Present',
          selected: status == AttendanceStatus.present,
          selectedBg: AppColors.tagGreenBg,
          selectedFg: AppColors.tagGreenText,
          onTap: onPresent,
        ),
        const SizedBox(width: 6),
        _chip(
          label: 'A',
          tooltip: 'Absent',
          selected: status == AttendanceStatus.absent,
          selectedBg: AppColors.tagRedBg,
          selectedFg: AppColors.tagRedText,
          onTap: onAbsent,
        ),
        const SizedBox(width: 6),
        _chip(
          label: '½',
          tooltip: 'Half-Day',
          selected: status == AttendanceStatus.halfDay,
          selectedBg: AppColors.tagAmberBg,
          selectedFg: AppColors.tagAmberText,
          onTap: onHalf,
        ),
      ],
    );
  }

  Widget _chip({
    required String label,
    required String tooltip,
    required bool selected,
    required Color selectedBg,
    required Color selectedFg,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: selected ? '$tooltip (tap to unmark)' : tooltip,
      child: Material(
        color: selected ? selectedBg : const Color(0xFFF0F4EE),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 36,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? selectedFg.withValues(alpha: 0.35) : AppColors.border,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? selectedFg : AppColors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
