import 'package:agrikhata/models/user_model.dart';
import 'package:agrikhata/services/auth_service.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Daily counter PIN login — staff selector + compact 3×4 keypad.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLoggedIn});

  final VoidCallback onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final FocusNode _keyboardFocus = FocusNode();

  List<UserModel> _users = [];
  UserModel? _selected;
  String _pin = '';
  String? _error;
  bool _busy = false;
  bool _loading = true;
  String _shopName = ShopSettings.defaultShopName;

  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -4), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -4, end: 4), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 4, end: -4), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -4, end: 0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut));

    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final users = await AuthService.instance.getActiveUsers();
    final shop = await ShopSettings.getShopName();
    if (!mounted) return;
    setState(() {
      _users = users;
      _selected = users.isNotEmpty ? users.first : null;
      _shopName = shop;
      _loading = false;
    });
  }

  void _selectUser(UserModel user) {
    setState(() {
      _selected = user;
      _pin = '';
      _error = null;
    });
  }

  void _pressDigit(String digit) {
    if (_busy || _selected == null || _pin.length >= 4) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == 4) {
      _submit();
    }
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  void _clearPin() {
    if (_busy) return;
    setState(() {
      _pin = '';
      _error = null;
    });
  }

  Future<void> _submit() async {
    final user = _selected;
    if (user == null || _pin.length != 4 || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await AuthService.instance.loginWithUserPin(user, _pin);
      if (!mounted) return;
      widget.onLoggedIn();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Invalid PIN';
        _pin = '';
      });
      _shakeController.forward(from: 0);
      _keyboardFocus.requestFocus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.delete) {
      _clearPin();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (_pin.length == 4) _submit();
      return KeyEventResult.handled;
    }

    final digit = _digitFromKey(key);
    if (digit != null) {
      _pressDigit(digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String? _digitFromKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      return '0';
    }
    if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
      return '1';
    }
    if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
      return '2';
    }
    if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
      return '3';
    }
    if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
      return '4';
    }
    if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
      return '5';
    }
    if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
      return '6';
    }
    if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
      return '7';
    }
    if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
      return '8';
    }
    if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) {
      return '9';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: const Color(0xFFF0F4EE),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1B4332).withValues(alpha: 0.08),
                      blurRadius: 60,
                      offset: const Offset(0, 20),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(38, 34, 38, 34),
                  child: _loading
                      ? const SizedBox(
                          height: 280,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF1B4332),
                            ),
                          ),
                        )
                      : _buildContent(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final selected = _selected;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.eco_rounded, color: Color(0xFF40916C), size: 22),
            SizedBox(width: 8),
            Text(
              'AgriKhata',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1B4332),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          _shopName,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1B4332),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Select your account or enter PIN to access the terminal.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: Color(0xFF8CA491)),
        ),
        const SizedBox(height: 24),
        if (_users.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No staff accounts found. Complete onboarding first.',
              style: TextStyle(color: Color(0xFF8CA491), fontSize: 13),
            ),
          )
        else
          _StaffSelector(
            users: _users,
            selectedId: selected?.id,
            onSelect: _selectUser,
          ),
        const SizedBox(height: 28),
        if (selected != null) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StaffAvatar(
                initials: selected.initials,
                selected: true,
                size: 46,
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selected.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1B4332),
                    ),
                  ),
                  const SizedBox(height: 4),
                  _RoleBadge(role: selected.role),
                ],
              ),
            ],
          ),
          const SizedBox(height: 22),
          AnimatedBuilder(
            animation: _shakeAnimation,
            builder: (context, child) {
              return Transform.translate(
                offset: Offset(_shakeAnimation.value, 0),
                child: child,
              );
            },
            child: _PinDots(filled: _pin.length, error: _error != null),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(
                color: Color(0xFFC24545),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 24),
          _PinKeypad(
            enabled: !_busy,
            onDigit: _pressDigit,
            onClear: _clearPin,
            onBackspace: _backspace,
          ),
          const SizedBox(height: 18),
          const Text(
            'You can also type your PIN using the keyboard.',
            style: TextStyle(fontSize: 10.5, color: Color(0xFF95B89A)),
          ),
          const SizedBox(height: 14),
          Text(
            'Forgot PIN? Ask Owner',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF40916C).withValues(alpha: 0.9),
            ),
          ),
        ],
      ],
    );
  }
}

class _StaffSelector extends StatelessWidget {
  const _StaffSelector({
    required this.users,
    required this.selectedId,
    required this.onSelect,
  });

  final List<UserModel> users;
  final String? selectedId;
  final ValueChanged<UserModel> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = users.length >= 4
            ? 4
            : (users.length <= 1 ? 1 : users.length);
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            for (final user in users)
              SizedBox(
                width: columns == 1
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 12 * (columns - 1)) / columns,
                child: _StaffCard(
                  user: user,
                  selected: user.id == selectedId,
                  onTap: () => onSelect(user),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StaffCard extends StatefulWidget {
  const _StaffCard({
    required this.user,
    required this.selected,
    required this.onTap,
  });

  final UserModel user;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_StaffCard> createState() => _StaffCardState();
}

class _StaffCardState extends State<_StaffCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Transform.translate(
        offset: Offset(0, _hovered && !selected ? -1 : 0),
        child: Material(
          color: selected
              ? const Color(0xFFEAF3DE)
              : (_hovered ? const Color(0xFFF7FBF3) : Colors.white),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected
                      ? const Color(0xFF1B4332)
                      : (_hovered
                          ? const Color(0xFF97C459)
                          : const Color(0xFFE2EBE0)),
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color:
                              const Color(0xFF1B4332).withValues(alpha: 0.12),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Column(
                children: [
                  _StaffAvatar(
                    initials: widget.user.initials,
                    selected: selected,
                    size: 46,
                  ),
                  const SizedBox(height: 9),
                  Text(
                    widget.user.name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1B4332),
                    ),
                  ),
                  const SizedBox(height: 5),
                  _RoleBadge(role: widget.user.role),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StaffAvatar extends StatelessWidget {
  const _StaffAvatar({
    required this.initials,
    required this.selected,
    this.size = 46,
  });

  final String initials;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? const Color(0xFF1B4332) : const Color(0xFFD8F3DC),
        border: Border.all(
          color: selected ? const Color(0xFF1B4332) : const Color(0xFFB7E4C7),
          width: 1.5,
        ),
      ),
      child: Text(
        initials,
        style: TextStyle(
          fontSize: 14.5,
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : const Color(0xFF1B4332),
        ),
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final isOwner = role.toUpperCase() == UserRole.owner;
    final label = role.toUpperCase() == UserRole.owner
        ? 'Owner / Partner'
        : UserRole.label(role);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isOwner ? const Color(0xFFFAEEDA) : const Color(0xFFF0F4EE),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: isOwner ? const Color(0xFF633806) : const Color(0xFF5C8468),
        ),
      ),
    );
  }
}

class _PinDots extends StatelessWidget {
  const _PinDots({required this.filled, required this.error});

  final int filled;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (i) {
        final isFilled = i < filled;
        return Container(
          margin: EdgeInsets.only(left: i == 0 ? 0 : 16),
          width: 15,
          height: 15,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled ? const Color(0xFF1B4332) : Colors.transparent,
            border: Border.all(
              color: error && !isFilled
                  ? const Color(0xFFC24545)
                  : (isFilled
                      ? const Color(0xFF1B4332)
                      : const Color(0xFFC6DEC9)),
              width: 1.5,
            ),
          ),
        );
      }),
    );
  }
}

class _PinKeypad extends StatelessWidget {
  const _PinKeypad({
    required this.enabled,
    required this.onDigit,
    required this.onClear,
    required this.onBackspace,
  });

  final bool enabled;
  final ValueChanged<String> onDigit;
  final VoidCallback onClear;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    const keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['C', '0', '⌫'],
    ];

    return SizedBox(
      width: 252,
      child: Column(
        children: [
          for (final row in keys) ...[
            Row(
              children: [
                for (var i = 0; i < row.length; i++) ...[
                  if (i > 0) const SizedBox(width: 9),
                  Expanded(
                    child: _KeyButton(
                      label: row[i],
                      functional: row[i] == 'C' || row[i] == '⌫',
                      enabled: enabled,
                      onTap: () {
                        final key = row[i];
                        if (key == 'C') {
                          onClear();
                        } else if (key == '⌫') {
                          onBackspace();
                        } else {
                          onDigit(key);
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
            if (row != keys.last) const SizedBox(height: 9),
          ],
        ],
      ),
    );
  }
}

class _KeyButton extends StatefulWidget {
  const _KeyButton({
    required this.label,
    required this.functional,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool functional;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final functional = widget.functional;
    Color bg;
    if (functional) {
      bg = _hovered ? const Color(0xFFE5EEE2) : const Color(0xFFF0F4EE);
    } else {
      bg = _pressed
          ? const Color(0xFFEAF3DE)
          : (_hovered ? const Color(0xFFF7F9F4) : Colors.white);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: widget.enabled
            ? (_) {
                setState(() => _pressed = false);
                widget.onTap();
              }
            : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1,
          duration: const Duration(milliseconds: 80),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _hovered && !functional
                    ? const Color(0xFFC6DEC9)
                    : const Color(0xFFE2EBE0),
              ),
            ),
            child: widget.label == '⌫'
                ? Icon(
                    Icons.backspace_outlined,
                    size: 18,
                    color: functional
                        ? const Color(0xFF6B8F71)
                        : const Color(0xFF1B4332),
                  )
                : Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: functional ? 12 : 23,
                      fontWeight: functional ? FontWeight.w700 : FontWeight.w600,
                      color: functional
                          ? const Color(0xFF6B8F71)
                          : const Color(0xFF1B4332),
                      letterSpacing: functional ? 0.3 : 0,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
