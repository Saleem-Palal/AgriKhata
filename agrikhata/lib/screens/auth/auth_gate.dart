import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/screens/auth/login_screen.dart';
import 'package:agrikhata/screens/auth/onboarding_screen.dart';
import 'package:agrikhata/services/auth_service.dart';
import 'package:agrikhata/shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Routes first launch → Owner onboarding, else PIN login → Shell.
///
/// In debug builds with bypass enabled, auto-signs in a mock Owner so
/// hot restarts land directly in the app.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _loading = true;
  bool _needsOnboarding = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    AuthService.instance.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    await AuthService.instance.initialize();
    final hasOwner = await AuthService.instance.hasOwner();
    if (!mounted) return;
    setState(() {
      _needsOnboarding = !hasOwner;
      _loading = false;
    });
  }

  Future<void> _refreshAfterOnboarding() async {
    setState(() => _needsOnboarding = false);
  }

  Future<void> _toggleDebugBypass() async {
    final next = !AuthService.instance.debugBypassEnabled;
    await AuthService.instance.setDebugBypassEnabled(next);
    if (!mounted) return;
    if (!next) {
      // Re-evaluate onboarding when leaving bypass mode.
      final hasOwner = await AuthService.instance.hasOwner();
      if (mounted) setState(() => _needsOnboarding = !hasOwner);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child;

    if (_loading) {
      child = const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.darkGreen),
        ),
      );
    } else if (AuthService.instance.isDebugBypassActive &&
        AuthService.instance.isSignedIn) {
      child = const Shell();
    } else if (_needsOnboarding && !AuthService.instance.isSignedIn) {
      child = OnboardingScreen(onCompleted: _refreshAfterOnboarding);
    } else if (!AuthService.instance.isSignedIn) {
      child = LoginScreen(
        onLoggedIn: () {
          if (mounted) setState(() {});
        },
      );
    } else {
      child = const Shell();
    }

    if (!kDebugMode) return child;

    return Stack(
      children: [
        child,
        Positioned(
          right: 16,
          bottom: 16,
          child: _DebugBypassChip(
            enabled: AuthService.instance.debugBypassEnabled,
            onTap: _toggleDebugBypass,
          ),
        ),
      ],
    );
  }
}

class _DebugBypassChip extends StatelessWidget {
  const _DebugBypassChip({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: enabled
                ? const Color(0xFF1B4332)
                : const Color(0xFFF0F4EE),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: enabled
                  ? const Color(0xFF2D6A4F)
                  : const Color(0xFFDCE6D9),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled ? Icons.bolt_rounded : Icons.lock_outline_rounded,
                size: 14,
                color: enabled ? const Color(0xFF95D5B2) : const Color(0xFF5C8468),
              ),
              const SizedBox(width: 6),
              Text(
                enabled ? 'DEBUG: Auto-Login ON' : 'DEBUG: Auto-Login OFF',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: enabled ? Colors.white : const Color(0xFF5C8468),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
