import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// First-launch Owner bootstrap — 2-column split matching the approved HTML.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _storeController = TextEditingController();
  final _phoneController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();

  OwnerGoogleProfile? _identity;
  bool _googleUnavailable = false;
  bool _formUnlocked = false;
  bool _busy = false;
  bool _obscurePin = true;
  bool _obscureConfirm = true;
  String? _error;

  bool get _showDetails => _formUnlocked || _identity != null || _googleUnavailable;

  @override
  void dispose() {
    _nameController.dispose();
    _storeController.dispose();
    _phoneController.dispose();
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final identity = await AuthService.instance.signInWithGoogle();
      if (!mounted) return;
      setState(() {
        _identity = identity;
        _googleUnavailable = false;
        _formUnlocked = true;
        _nameController.text = identity.name;
      });
    } on UnsupportedError {
      if (!mounted) return;
      setState(() {
        _googleUnavailable = true;
        _formUnlocked = true;
        _error =
            'Native Google Sign-In is unavailable on this desktop build. '
            'Complete the form below to continue.';
      });
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (msg.contains('cancelled')) {
        setState(() => _error = null);
      } else {
        setState(() {
          _googleUnavailable = true;
          _formUnlocked = true;
          _error =
              'Could not complete Google Sign-In. '
              'Complete the form below to continue.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _unlockFormManually() {
    setState(() {
      _googleUnavailable = true;
      _formUnlocked = true;
      _error = null;
    });
  }

  Future<void> _completeOnboarding() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final name = _nameController.text.trim();
    final pin = _pinController.text.trim();

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final email = _identity?.email.trim().toLowerCase() ??
          '${name.toLowerCase().replaceAll(RegExp(r'\s+'), '.')}@local.owner';
      final identity = OwnerGoogleProfile(
        name: name.isNotEmpty ? name : (_identity?.name ?? 'Owner'),
        email: email,
      );
      await AuthService.instance.completeOwnerOnboarding(
        identity: identity,
        pinCode: pin,
        phone: _phoneController.text.trim(),
        storeName: _storeController.text.trim(),
      );
      if (!mounted) return;
      widget.onCompleted();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4EE),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Expanded(flex: 42, child: _IntroPanel()),
                      Expanded(flex: 58, child: _buildFormPanel()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFormPanel() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(40, 38, 40, 38),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Set up your owner profile',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1B4332),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "This only takes a minute — you'll be ready to launch right after.",
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF8CA491),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            _GoogleSignInButton(
              busy: _busy,
              signedInEmail: _identity?.email,
              onPressed: _busy ? null : _handleGoogleSignIn,
            ),
            if (_identity == null && !_googleUnavailable) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _unlockFormManually,
                child: const Text(
                  'Enter details manually',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.darkGreen,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            const _DividerLabel(label: 'then complete your profile'),
            const SizedBox(height: 16),
            AnimatedOpacity(
              opacity: _showDetails ? 1 : 0.4,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showDetails,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _FieldLabel('Owner Name'),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      enabled: _showDetails && !_busy,
                      decoration: _decoration(hint: 'e.g. Atta Muhammad'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Enter owner name' : null,
                    ),
                    const SizedBox(height: 12),
                    _FieldLabel('Store / Business Name'),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _storeController,
                      textCapitalization: TextCapitalization.words,
                      enabled: _showDetails && !_busy,
                      decoration: _decoration(
                        hint: 'e.g. AM Pesticides & Fertilizers',
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Enter store name'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    _FieldLabel('Phone Number'),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      enabled: _showDetails && !_busy,
                      decoration: _decoration(hint: '03XX-XXXXXXX'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _FieldLabel('Set 4-Digit PIN'),
                              const SizedBox(height: 6),
                              TextFormField(
                                controller: _pinController,
                                obscureText: _obscurePin,
                                maxLength: 4,
                                enabled: _showDetails && !_busy,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(
                                  fontSize: 15,
                                  letterSpacing: 4,
                                  color: Color(0xFF1B4332),
                                ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(4),
                                ],
                                decoration: _decoration(hint: '••••').copyWith(
                                  counterText: '',
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscurePin
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      size: 18,
                                      color: const Color(0xFF95B89A),
                                    ),
                                    onPressed: () =>
                                        setState(() => _obscurePin = !_obscurePin),
                                  ),
                                ),
                                validator: (v) => (v == null || v.length != 4)
                                    ? '4 digits required'
                                    : null,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _FieldLabel('Confirm PIN'),
                              const SizedBox(height: 6),
                              TextFormField(
                                controller: _confirmPinController,
                                obscureText: _obscureConfirm,
                                maxLength: 4,
                                enabled: _showDetails && !_busy,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(
                                  fontSize: 15,
                                  letterSpacing: 4,
                                  color: Color(0xFF1B4332),
                                ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(4),
                                ],
                                decoration: _decoration(hint: '••••').copyWith(
                                  counterText: '',
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureConfirm
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      size: 18,
                                      color: const Color(0xFF95B89A),
                                    ),
                                    onPressed: () => setState(
                                      () => _obscureConfirm = !_obscureConfirm,
                                    ),
                                  ),
                                ),
                                validator: (v) {
                                  if (v != _pinController.text) {
                                    return 'PINs do not match';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 46,
                      child: FilledButton(
                        onPressed: (_showDetails && !_busy)
                            ? _completeOnboarding
                            : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1B4332),
                          disabledBackgroundColor: const Color(0xFFB4C4B8),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(11),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (_busy)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            else
                              const Icon(Icons.login_rounded, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              _busy
                                  ? 'Launching…'
                                  : 'Complete Setup & Launch App',
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFFC24545),
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static InputDecoration _decoration({String? hint}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF95B89A), fontSize: 13),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: Color(0xFFC6DEC9), width: 0.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: Color(0xFFC6DEC9), width: 0.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: Color(0xFFC6DEC9), width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: Color(0xFF40916C)),
      ),
    );
  }
}

class _IntroPanel extends StatelessWidget {
  const _IntroPanel();

  static const _features = [
    ('🌾', 'Zamindar Credit & Khata Ledgers'),
    ('📦', 'Inventory & Weighted Average Batch Pricing'),
    ('🤝', 'Partner Capital & Equity Share Calculations'),
    ('⚡', 'High-Speed Counter Checkout with PIN Access'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-0.2, -1),
          end: Alignment(0.4, 1),
          colors: [Color(0xFF1B4332), Color(0xFF173B2B)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -70,
            right: -70,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF40916C).withValues(alpha: 0.3),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 38, 32, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.eco_rounded,
                          color: Color(0xFF95D5B2),
                          size: 22,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'AgriKhata ERP',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'Smart Shop Management for Pesticide & Fertilizer Stores',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 26),
                    for (final feature in _features) ...[
                      _FeatureItem(emoji: feature.$1, text: feature.$2),
                      const SizedBox(height: 15),
                    ],
                  ],
                ),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Divider(color: Color(0x26FFFFFF), height: 1),
                    SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 14,
                          color: Color(0xFF95D5B2),
                        ),
                        SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            'Secure Local Database with Cloud Sync Capability',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFF95D5B2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  const _FeatureItem({required this.emoji, required this.text});

  final String emoji;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Text(emoji, style: const TextStyle(fontSize: 14)),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFD8E6DC),
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GoogleSignInButton extends StatelessWidget {
  const _GoogleSignInButton({
    required this.busy,
    required this.signedInEmail,
    required this.onPressed,
  });

  final bool busy;
  final String? signedInEmail;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final signedIn = signedInEmail != null;

    return Material(
      color: signedIn ? const Color(0xFFF0F7EB) : Colors.white,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: signedIn ? null : onPressed,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: signedIn ? const Color(0xFF97C459) : const Color(0xFFDADCE0),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (signedIn)
                const Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: Color(0xFF2D6A4F),
                )
              else
                const _GoogleGIcon(),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  signedIn
                      ? 'Signed in as $signedInEmail'
                      : 'Sign in with Google',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: signedIn
                        ? const Color(0xFF2D6A4F)
                        : const Color(0xFF3C4043),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoogleGIcon extends StatelessWidget {
  const _GoogleGIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CustomPaint(painter: _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Simple multicolor "G" mark approximation.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    paint.color = const Color(0xFF4285F4);
    canvas.drawArc(rect, -0.4, 1.8, false, paint);
    paint.color = const Color(0xFF34A853);
    canvas.drawArc(rect, 1.4, 1.2, false, paint);
    paint.color = const Color(0xFFFBBC05);
    canvas.drawArc(rect, 2.6, 0.9, false, paint);
    paint.color = const Color(0xFFEA4335);
    canvas.drawArc(rect, 3.5, 1.0, false, paint);
    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.5),
      Offset(size.width - 1, size.height * 0.5),
      Paint()
        ..color = const Color(0xFF4285F4)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DividerLabel extends StatelessWidget {
  const _DividerLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider(color: Color(0xFFE2EBE0), height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF95B89A)),
          ),
        ),
        const Expanded(child: Divider(color: Color(0xFFE2EBE0), height: 1)),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: Color(0xFF4B5A50),
      ),
    );
  }
}
