import 'dart:math';

import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/models/audit_log_model.dart';
import 'package:agrikhata/models/user_model.dart';
import 'package:agrikhata/services/user_account_store.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// System → User Accounts (SQLite-backed RBAC staff management).
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  static const _mutedAccent = Color(0xFF5C8468);
  static const _deleteColor = Color(0xFFC24545);
  static const _ownerBadgeBg = Color(0xFFFAEEDA);
  static const _ownerBadgeText = Color(0xFF633806);
  static const _partnerBadgeBg = Color(0xFFE6F1FB);
  static const _partnerBadgeText = Color(0xFF0C447C);
  static const _managerBadgeBg = Color(0xFFEAF3DE);
  static const _managerBadgeText = Color(0xFF2D6A4F);
  static const _cashierBadgeBg = Color(0xFFF3E8FF);
  static const _cashierBadgeText = Color(0xFF5B21B6);

  final _dateFmt = DateFormat('MMM d, yyyy • h:mm a');

  List<UserModel> _users = const [];
  Map<String, AuditLogModel?> _lastActions = const {};
  Map<String, String> _partnerNames = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await DatabaseHelper.instance.getUsers();
      final partners = await DatabaseHelper.instance.getPartners();
      final lastActions = await DatabaseHelper.instance
          .getLatestAuditLogsByUserIds(users.map((u) => u.id).toList());
      final partnerNames = <String, String>{
        for (final p in partners) p.id: p.name,
      };
      if (!mounted) return;
      setState(() {
        _users = users;
        _lastActions = lastActions;
        _partnerNames = partnerNames;
        _loading = false;
      });
      UserAccountStore.instance.setUsers(
        users.map(AppUserAccount.fromUser).toList(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _showAddStaffDialog() async {
    final created = await showDialog<UserModel>(
      context: context,
      builder: (ctx) => _StaffAccountDialog(
        partners: _partnerNames.entries
            .map((e) => MapEntry(e.key, e.value))
            .toList(),
      ),
    );
    if (created == null) return;
    try {
      await DatabaseHelper.instance.insertUser(created);
      if (!mounted) return;
      AppToast.showSuccess(context, 'Staff account created');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _showEditDialog(UserModel user) async {
    if (user.isOwner) {
      final pin = await _promptPin(title: 'Edit Owner PIN — ${user.name}');
      if (pin == null) return;
      try {
        await DatabaseHelper.instance.updateUser(user.copyWith(pinCode: pin));
        if (!mounted) return;
        AppToast.showSuccess(context, 'PIN updated');
        await _reload();
      } catch (e) {
        if (!mounted) return;
        AppToast.showError(
          context,
          e.toString().replaceFirst('Bad state: ', ''),
        );
      }
      return;
    }

    final updated = await showDialog<UserModel>(
      context: context,
      builder: (ctx) => _StaffAccountDialog(
        existing: user,
        partners: _partnerNames.entries
            .map((e) => MapEntry(e.key, e.value))
            .toList(),
      ),
    );
    if (updated == null) return;
    try {
      await DatabaseHelper.instance.updateUser(updated);
      if (!mounted) return;
      AppToast.showSuccess(context, 'Account updated');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<String?> _promptPin({required String title}) async {
    final pinController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: pinController,
            obscureText: true,
            maxLength: 4,
            keyboardType: TextInputType.number,
            autofocus: true,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: const InputDecoration(
              labelText: '4-Digit PIN',
              counterText: '',
            ),
            validator: (v) =>
                (v == null || v.length != 4) ? 'Enter a 4-digit PIN' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (!(formKey.currentState?.validate() ?? false)) return;
              Navigator.pop(ctx, pinController.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    pinController.dispose();
    return result;
  }

  Future<void> _toggleActive(UserModel user) async {
    if (user.isOwner) return;
    try {
      await DatabaseHelper.instance.setUserActive(user.id, !user.isActive);
      if (!mounted) return;
      AppToast.showSuccess(
        context,
        user.isActive ? 'Account deactivated' : 'Account activated',
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _showActivityLog(UserModel user) async {
    final logs = await DatabaseHelper.instance.getAuditLogsForUser(user.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Activity — ${user.name}'),
        content: SizedBox(
          width: 520,
          height: 360,
          child: logs.isEmpty
              ? const Center(child: Text('No activity recorded yet'))
              : ListView.separated(
                  itemCount: logs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final log = logs[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        log.description,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '${AuditActionType.label(log.actionType)} • ${_dateFmt.format(log.timestamp)}',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          AgriHeader(
            breadcrumbs: const ['System', 'User Accounts'],
            actions: const [],
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.darkGreen,
                    ),
                  )
                : _error != null
                ? Center(child: Text(_error!))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final horizontalPad = constraints.maxWidth >= 900
                          ? 40.0
                          : 24.0;
                      return SingleChildScrollView(
                        padding: EdgeInsets.symmetric(
                          horizontal: horizontalPad,
                          vertical: 28,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildPageHeader(
                              compact: constraints.maxWidth < 820,
                            ),
                            const SizedBox(height: 22),
                            _buildTable(),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageHeader({required bool compact}) {
    final titleBlock = const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'User Accounts',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: AppColors.darkGreen,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Manage staff roles, PIN login, partner links, and activity footprints',
          style: TextStyle(fontSize: 13, color: _mutedAccent),
        ),
      ],
    );

    final addButton = AppButton.primary(
      label: 'Add Staff Account',
      icon: Icons.person_add_alt_1_rounded,
      onPressed: _showAddStaffDialog,
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleBlock,
          const SizedBox(height: 14),
          Align(alignment: Alignment.centerLeft, child: addButton),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: titleBlock),
        const SizedBox(width: 16),
        addButton,
      ],
    );
  }

  Widget _buildTable() {
    if (_users.isEmpty) {
      return AppDataTable(
        columns: _columns,
        rows: const [],
        empty: const Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text(
              'No user accounts yet. Complete Owner onboarding first.',
              style: TextStyle(color: _mutedAccent),
            ),
          ),
        ),
      );
    }

    return AppDataTable(
      minWidth: 980,
      columns: _columns,
      rows: [
        for (final user in _users)
          AppDataRow(
            cells: [
              _nameCell(user),
              AppTableCellText(user.phone.isEmpty ? '—' : user.phone),
              _roleBadge(user.role),
              AppTableCellText(
                user.partnerId == null
                    ? '—'
                    : (_partnerNames[user.partnerId!] ?? '—'),
              ),
              AppTableCellText(_lastActionLabel(user.id), maxLines: 2),
              _statusChip(user.isActive),
              _actionsCell(user),
            ],
          ),
      ],
    );
  }

  static const _columns = [
    AppDataColumn(title: 'Name', flex: 3),
    AppDataColumn(title: 'Phone', flex: 2),
    AppDataColumn(title: 'Role', flex: 2),
    AppDataColumn(title: 'Linked Partner', flex: 2),
    AppDataColumn(title: 'Last Action', flex: 3),
    AppDataColumn(title: 'Status', flex: 2),
    AppDataColumn(title: 'Actions', flex: 3),
  ];

  Widget _nameCell(UserModel user) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFD8F3DC),
            border: Border.all(color: const Color(0xFFB7E4C7)),
          ),
          child: Text(
            user.initials,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: AppColors.darkGreen,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                user.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.darkGreen,
                  fontSize: 13,
                ),
              ),
              if (user.email != null && user.email!.isNotEmpty)
                Text(
                  user.email!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _mutedAccent),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _lastActionLabel(String userId) {
    final log = _lastActions[userId];
    if (log == null) return '—';
    return '${AuditActionType.label(log.actionType)}\n${_dateFmt.format(log.timestamp)}';
  }

  Widget _roleBadge(String role) {
    late final Color bg;
    late final Color fg;
    switch (role) {
      case UserRole.owner:
        bg = _ownerBadgeBg;
        fg = _ownerBadgeText;
      case UserRole.partner:
        bg = _partnerBadgeBg;
        fg = _partnerBadgeText;
      case UserRole.cashier:
        bg = _cashierBadgeBg;
        fg = _cashierBadgeText;
      default:
        bg = _managerBadgeBg;
        fg = _managerBadgeText;
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          UserRole.label(role),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ),
    );
  }

  Widget _statusChip(bool active) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFD8F3DC) : const Color(0xFFF0F4EE),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          active ? 'Active' : 'Inactive',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: active ? const Color(0xFF2D6A4F) : _mutedAccent,
          ),
        ),
      ),
    );
  }

  Widget _actionsCell(UserModel user) {
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: [
        TextButton(
          onPressed: () => _showEditDialog(user),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF2D6A4F),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            user.isOwner ? 'Edit PIN' : 'Edit',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ),
        if (!user.isOwner)
          TextButton(
            onPressed: () => _toggleActive(user),
            style: TextButton.styleFrom(
              foregroundColor: user.isActive
                  ? _deleteColor
                  : AppColors.darkGreen,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              user.isActive ? 'Deactivate' : 'Activate',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        TextButton(
          onPressed: () => _showActivityLog(user),
          style: TextButton.styleFrom(
            foregroundColor: _mutedAccent,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text(
            'Activity',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _StaffAccountDialog extends StatefulWidget {
  const _StaffAccountDialog({this.existing, required this.partners});

  final UserModel? existing;
  final List<MapEntry<String, String>> partners;

  @override
  State<_StaffAccountDialog> createState() => _StaffAccountDialogState();
}

class _StaffAccountDialogState extends State<_StaffAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _pinController;
  late String _role;
  String? _partnerId;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _phoneController = TextEditingController(text: existing?.phone ?? '');
    _pinController = TextEditingController(text: existing?.pinCode ?? '');
    _role = existing?.role ?? UserRole.manager;
    if (_role == UserRole.owner) _role = UserRole.manager;
    _partnerId = existing?.partnerId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_role == UserRole.partner &&
        (_partnerId == null || _partnerId!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a partner profile to link')),
      );
      return;
    }

    final existing = widget.existing;
    final user = UserModel(
      id:
          existing?.id ??
          'u_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(9999)}',
      name: _nameController.text.trim(),
      phone: _phoneController.text.trim(),
      email: existing?.email,
      role: _role,
      pinCode: _pinController.text.trim(),
      partnerId: _role == UserRole.partner ? _partnerId : null,
      isActive: existing?.isActive ?? true,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
    Navigator.of(context).pop(user);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _isEdit ? 'Edit Staff Account' : 'Add Staff Account',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Assign a role and 4-digit PIN for counter login',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF5C8468)),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Full Name',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4B5A50),
                  ),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Ahmed Khan',
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Enter a full name'
                      : null,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Phone',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4B5A50),
                  ),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(hintText: '03XXXXXXXXX'),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Role',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF4B5A50),
                            ),
                          ),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            initialValue: _role,
                            items: [
                              for (final role in UserRole.staffRoles)
                                DropdownMenuItem(
                                  value: role,
                                  child: Text(UserRole.label(role)),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                _role = value;
                                if (_role != UserRole.partner) {
                                  _partnerId = null;
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '4-Digit PIN',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF4B5A50),
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _pinController,
                            obscureText: true,
                            maxLength: 4,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(4),
                            ],
                            decoration: const InputDecoration(
                              hintText: '••••',
                              counterText: '',
                            ),
                            validator: (v) => (v == null || v.length != 4)
                                ? 'Enter a 4-digit PIN'
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_role == UserRole.partner) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Link Partner Profile',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4B5A50),
                    ),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _partnerId,
                    hint: const Text('Select partner'),
                    items: [
                      for (final entry in widget.partners)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) => setState(() => _partnerId = value),
                    validator: (v) {
                      if (_role == UserRole.partner &&
                          (v == null || v.isEmpty)) {
                        return 'Link a partner profile';
                      }
                      return null;
                    },
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.darkGreen,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(_isEdit ? 'Save Changes' : 'Create Account'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Backward-compatible alias used by older imports.
typedef UserAccountsScreen = UsersScreen;
