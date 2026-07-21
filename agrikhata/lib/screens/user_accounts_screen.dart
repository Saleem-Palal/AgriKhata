import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class _AppUser {
  final String id;
  final String name;
  final String role;
  final String pin;
  final String subtitle;
  final bool isOwner;
  final bool isPinVisible;

  const _AppUser({
    required this.id,
    required this.name,
    required this.role,
    required this.pin,
    required this.subtitle,
    this.isOwner = false,
    this.isPinVisible = false,
  });

  String get initials {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final word = parts.first;
      return word.substring(0, word.length >= 2 ? 2 : 1).toUpperCase();
    }
    return ('${parts.first[0]}${parts.last[0]}').toUpperCase();
  }

  _AppUser copyWith({
    String? id,
    String? name,
    String? role,
    String? pin,
    String? subtitle,
    bool? isOwner,
    bool? isPinVisible,
  }) {
    return _AppUser(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      pin: pin ?? this.pin,
      subtitle: subtitle ?? this.subtitle,
      isOwner: isOwner ?? this.isOwner,
      isPinVisible: isPinVisible ?? this.isPinVisible,
    );
  }
}

class UserAccountsScreen extends StatefulWidget {
  const UserAccountsScreen({super.key});

  @override
  State<UserAccountsScreen> createState() => _UserAccountsScreenState();
}

class _UserAccountsScreenState extends State<UserAccountsScreen> {
  static const _mutedAccent = Color(0xFF5C8468);
  static const _rowDivider = Color(0xFFEEF3EC);
  static const _subtitle = Color(0xFF8CA491);
  static const _avatarBg = Color(0xFFD8F3DC);
  static const _avatarBorder = Color(0xFFB7E4C7);
  static const _ownerBadgeBg = Color(0xFFFAEEDA);
  static const _ownerBadgeText = Color(0xFF633806);
  static const _partnerBadgeBg = Color(0xFFE6F1FB);
  static const _partnerBadgeText = Color(0xFF0C447C);
  static const _managerBadgeBg = Color(0xFFEAF3DE);
  static const _managerBadgeText = Color(0xFF2D6A4F);
  static const _systemTagBg = Color(0xFFF0F4EE);
  static const _systemTagText = Color(0xFF95B89A);
  static const _editPinColor = Color(0xFF2D6A4F);
  static const _deleteColor = Color(0xFFC24545);
  static const _fieldLabel = Color(0xFF4B5A50);
  static const _eyeIdle = Color(0xFF95B89A);

  late List<_AppUser> _users;

  @override
  void initState() {
    super.initState();
    _users = [
      const _AppUser(
        id: '1',
        name: 'Atta Muhammad',
        role: 'Owner',
        pin: '9911',
        subtitle: 'Primary Account • Full Access',
        isOwner: true,
      ),
      const _AppUser(
        id: '2',
        name: 'Zubair Ahmed',
        role: 'Manager',
        pin: '1234',
        subtitle: 'Added: Jul 12, 2026 • Sales & Ledger Only',
      ),
      const _AppUser(
        id: '3',
        name: 'Farhan Khan',
        role: 'Partner',
        pin: '8822',
        subtitle: 'Added: May 04, 2026 • Full Access',
      ),
    ];
  }

  void _togglePinVisibility(String id) {
    setState(() {
      _users = _users
          .map(
            (u) => u.id == id ? u.copyWith(isPinVisible: !u.isPinVisible) : u,
          )
          .toList();
    });
  }

  Future<void> _showAddUserDialog() async {
    final nameController = TextEditingController();
    final pinController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var selectedRole = 'Manager';

    final created = await showDialog<_AppUser>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Add New User Account',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Create a manager or partner account with a 4-digit PIN',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: _mutedAccent,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _fieldLabelText('Full Name'),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: nameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: _inputDecoration(
                            hint: 'e.g. Ahmed Khan',
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Enter a full name';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _fieldLabelText('Role'),
                                  const SizedBox(height: 6),
                                  DropdownButtonFormField<String>(
                                    initialValue: selectedRole,
                                    decoration: _inputDecoration(),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'Manager',
                                        child: Text('Manager'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'Partner',
                                        child: Text('Partner'),
                                      ),
                                    ],
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setDialogState(
                                        () => selectedRole = value,
                                      );
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
                                  _fieldLabelText('4-Digit Access PIN'),
                                  const SizedBox(height: 6),
                                  TextFormField(
                                    controller: pinController,
                                    obscureText: true,
                                    maxLength: 4,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                      LengthLimitingTextInputFormatter(4),
                                    ],
                                    decoration: _inputDecoration(
                                      hint: '••••',
                                    ).copyWith(counterText: ''),
                                    validator: (value) {
                                      if (value == null || value.length != 4) {
                                        return 'Enter a 4-digit PIN';
                                      }
                                      return null;
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        const Divider(height: 1, color: _rowDivider),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textPrimary,
                                side: const BorderSide(
                                  color: AppColors.inputBorder,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(9),
                                ),
                              ),
                              child: const Text(
                                'Cancel',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 10),
                            ElevatedButton(
                              onPressed: () {
                                if (!(formKey.currentState?.validate() ??
                                    false)) {
                                  return;
                                }
                                final name = nameController.text.trim();
                                final accessLabel = selectedRole == 'Partner'
                                    ? 'Full Access'
                                    : 'Sales & Ledger Only';
                                final added = DateFormat(
                                  'MMM dd, yyyy',
                                ).format(DateTime.now());
                                Navigator.of(ctx).pop(
                                  _AppUser(
                                    id: DateTime.now()
                                        .millisecondsSinceEpoch
                                        .toString(),
                                    name: name,
                                    role: selectedRole,
                                    pin: pinController.text,
                                    subtitle:
                                        'Added: $added • $accessLabel',
                                  ),
                                );
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.darkGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shadowColor: AppColors.darkGreen.withValues(
                                  alpha: 0.2,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(9),
                                ),
                              ),
                              child: const Text(
                                'Create User Account',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    nameController.dispose();
    pinController.dispose();

    if (created == null || !mounted) return;
    setState(() => _users = [..._users, created]);
  }

  Future<void> _showEditPinDialog(_AppUser user) async {
    if (user.isOwner) return;

    final pinController = TextEditingController(text: user.pin);
    final formKey = GlobalKey<FormState>();

    final newPin = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Edit PIN — ${user.name}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Update the 4-digit access PIN for this account',
                      style: TextStyle(fontSize: 12.5, color: _mutedAccent),
                    ),
                    const SizedBox(height: 18),
                    _fieldLabelText('New Access PIN'),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: pinController,
                      obscureText: true,
                      autofocus: true,
                      maxLength: 4,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      decoration: _inputDecoration(
                        hint: '••••',
                      ).copyWith(counterText: ''),
                      validator: (value) {
                        if (value == null || value.length != 4) {
                          return 'Enter a 4-digit PIN';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 18),
                    const Divider(height: 1, color: _rowDivider),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () {
                            if (!(formKey.currentState?.validate() ?? false)) {
                              return;
                            }
                            Navigator.of(ctx).pop(pinController.text);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.darkGreen,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9),
                            ),
                          ),
                          child: const Text(
                            'Save PIN',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    pinController.dispose();
    if (newPin == null || !mounted) return;

    setState(() {
      _users = _users
          .map(
            (u) => u.id == user.id
                ? u.copyWith(pin: newPin, isPinVisible: false)
                : u,
          )
          .toList();
    });
  }

  Future<void> _confirmDelete(_AppUser user) async {
    if (user.isOwner) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: const Text('Delete User'),
          content: Text(
            'Remove ${user.name} (${user.role}) from store accounts? '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: _deleteColor),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;
    setState(() => _users = _users.where((u) => u.id != user.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
            child: const Row(
              children: [
                Text(
                  'System',
                  style: TextStyle(fontSize: 12, color: AppColors.textHint),
                ),
                Text(
                  '  ›  ',
                  style: TextStyle(fontSize: 12, color: AppColors.textHint),
                ),
                Text(
                  'User Accounts',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 820;
                final horizontalPad = constraints.maxWidth >= 900 ? 40.0 : 24.0;

                return SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPad,
                    vertical: 32,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPageHeader(compact: !wide),
                      const SizedBox(height: 26),
                      _buildUsersCard(wide: wide),
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
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: AppColors.darkGreen,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Manage store managers, partners, and access PIN codes',
          style: TextStyle(fontSize: 13, color: _mutedAccent),
        ),
      ],
    );

    final addButton = ElevatedButton.icon(
      onPressed: _showAddUserDialog,
      icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
      label: const Text(
        'Add New User',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.darkGreen,
        foregroundColor: Colors.white,
        elevation: 0,
        shadowColor: AppColors.darkGreen.withValues(alpha: 0.2),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: const StadiumBorder(),
      ),
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleBlock,
          const SizedBox(height: 16),
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

  Widget _buildUsersCard({required bool wide}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: AppColors.darkGreen.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < _users.length; i++) ...[
            _UserRow(
              user: _users[i],
              wide: wide,
              onTogglePin: () => _togglePinVisibility(_users[i].id),
              onEditPin: () => _showEditPinDialog(_users[i]),
              onDelete: () => _confirmDelete(_users[i]),
            ),
            if (i < _users.length - 1)
              const Divider(height: 1, color: _rowDivider),
          ],
        ],
      ),
    );
  }

  static Widget _fieldLabelText(String label) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: _fieldLabel,
      ),
    );
  }

  static InputDecoration _inputDecoration({String? hint}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: AppColors.inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: AppColors.inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: AppColors.accentGreen, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: _deleteColor),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: _deleteColor, width: 1.5),
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  final _AppUser user;
  final bool wide;
  final VoidCallback onTogglePin;
  final VoidCallback onEditPin;
  final VoidCallback onDelete;

  const _UserRow({
    required this.user,
    required this.wide,
    required this.onTogglePin,
    required this.onEditPin,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final identity = Row(
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _UserAccountsScreenState._avatarBg,
            border: Border.all(
              color: _UserAccountsScreenState._avatarBorder,
            ),
          ),
          child: Text(
            user.initials,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.darkGreen,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppColors.darkGreen,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                user.subtitle,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: _UserAccountsScreenState._subtitle,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final meta = Column(
      crossAxisAlignment:
          wide ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _RoleBadge(role: user.role),
        const SizedBox(height: 6),
        _PinDisplay(
          pin: user.pin,
          isVisible: user.isPinVisible,
          onToggle: onTogglePin,
        ),
      ],
    );

    final actions = user.isOwner
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: _UserAccountsScreenState._systemTagBg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'System Owner',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: _UserAccountsScreenState._systemTagText,
              ),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: onEditPin,
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: const Text(
                  'Edit PIN',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: _UserAccountsScreenState._editPinColor,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              TextButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 14),
                label: const Text(
                  'Delete',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: _UserAccountsScreenState._deleteColor,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          );

    if (!wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            identity,
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: meta),
                actions,
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Row(
        children: [
          Expanded(child: identity),
          const SizedBox(width: 16),
          meta,
          const SizedBox(width: 20),
          actions,
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final String role;

  const _RoleBadge({required this.role});

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;

    switch (role.toLowerCase()) {
      case 'owner':
        bg = _UserAccountsScreenState._ownerBadgeBg;
        fg = _UserAccountsScreenState._ownerBadgeText;
      case 'partner':
        bg = _UserAccountsScreenState._partnerBadgeBg;
        fg = _UserAccountsScreenState._partnerBadgeText;
      default:
        bg = _UserAccountsScreenState._managerBadgeBg;
        fg = _UserAccountsScreenState._managerBadgeText;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Role: $role',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

class _PinDisplay extends StatelessWidget {
  final String pin;
  final bool isVisible;
  final VoidCallback onToggle;

  const _PinDisplay({
    required this.pin,
    required this.isVisible,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'PIN: ',
          style: TextStyle(
            fontSize: 11.5,
            color: _UserAccountsScreenState._mutedAccent,
          ),
        ),
        const Icon(
          Icons.lock_rounded,
          size: 11,
          color: _UserAccountsScreenState._mutedAccent,
        ),
        const SizedBox(width: 4),
        Text(
          isVisible ? pin : '****',
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: _UserAccountsScreenState._mutedAccent,
          ),
        ),
        const SizedBox(width: 2),
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              isVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 14,
              color: _UserAccountsScreenState._eyeIdle,
            ),
          ),
        ),
      ],
    );
  }
}
