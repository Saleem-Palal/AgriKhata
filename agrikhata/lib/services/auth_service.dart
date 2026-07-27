import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Database/database_helper.dart';
import '../models/user_model.dart';
import '../utils/shop_settings.dart';
import 'debug_auth_config.dart';
import 'session_context.dart';

/// Google identity payload used during Owner onboarding.
class OwnerGoogleProfile {
  final String name;
  final String email;

  const OwnerGoogleProfile({required this.name, required this.email});
}

/// Owns Google Owner bootstrap, PIN login, and the active session.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _sessionUserIdKey = 'agrikhata_session_user_id';
  static const _debugOwnerId = 'debug_owner_atta';

  UserModel? _currentUser;
  bool _initialized = false;
  bool _googleReady = false;

  /// Runtime toggle for the debug auto-login bypass (debug builds only).
  /// Seeded from [bypassLoginInDebug] in `debug_auth_config.dart`.
  bool _debugBypassEnabled = bypassLoginInDebug;

  UserModel? get currentUser => _currentUser;
  bool get isSignedIn => _currentUser != null;
  bool get isInitialized => _initialized;
  String? get role => _currentUser?.role;

  /// True when debug auto-login should skip onboarding / PIN screens.
  bool get isDebugBypassActive => kDebugMode && _debugBypassEnabled;

  bool get debugBypassEnabled => _debugBypassEnabled;

  /// Restores a persisted session if the user still exists and is active.
  /// In debug + bypass mode, ensures a mock Owner session instead.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      if (isDebugBypassActive) {
        await ensureDebugOwnerSession();
      } else {
        final prefs = await SharedPreferences.getInstance();
        final userId = prefs.getString(_sessionUserIdKey);
        if (userId != null && userId.isNotEmpty) {
          final user = await DatabaseHelper.instance.getUserById(userId);
          if (user != null && user.isActive) {
            await _setSession(user, persist: false);
          } else {
            await prefs.remove(_sessionUserIdKey);
          }
        }
      }
    } catch (e, st) {
      debugPrint('AuthService.initialize failed: $e\n$st');
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  Future<bool> hasAnyUsers() => DatabaseHelper.instance.hasAnyUsers();

  Future<bool> hasOwner() => DatabaseHelper.instance.hasOwner();

  Future<List<UserModel>> getActiveUsers() async {
    final users = await DatabaseHelper.instance.getUsers();
    return users.where((u) => u.isActive).toList();
  }

  /// Enable / disable debug auto-login at runtime (floating DEBUG chip).
  Future<void> setDebugBypassEnabled(bool enabled) async {
    if (!kDebugMode) return;
    _debugBypassEnabled = enabled;
    if (enabled) {
      await ensureDebugOwnerSession();
    } else {
      // Drop the in-memory / debug session so AuthGate shows real auth UI.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionUserIdKey);
      _currentUser = null;
      SessionContext.clear();
    }
    notifyListeners();
  }

  /// Seeds a mock Owner session for seamless hot-restarts in debug builds.
  /// Prefers a real Owner from SQLite when present; otherwise uses an
  /// in-memory mock (not persisted) so onboarding can still be tested.
  Future<void> ensureDebugOwnerSession() async {
    if (!kDebugMode || !_debugBypassEnabled) return;

    final existing = await DatabaseHelper.instance.getOwnerUser();
    if (existing != null) {
      await _setSession(existing, persist: false);
      return;
    }

    final mock = UserModel(
      id: _debugOwnerId,
      name: 'Atta Muhammad',
      phone: '',
      email: 'atta.muhammad@gmail.com',
      role: UserRole.owner,
      pinCode: '0000',
      isActive: true,
      createdAt: DateTime.now(),
    );
    await _setSession(mock, persist: false);
  }

  Future<void> _ensureGoogleInitialized() async {
    if (_googleReady) return;
    try {
      await GoogleSignIn.instance.initialize();
      _googleReady = true;
    } catch (e) {
      debugPrint('GoogleSignIn.initialize failed: $e');
      rethrow;
    }
  }

  /// Attempts native Google Sign-In. On unsupported desktop platforms this
  /// throws [UnsupportedError] so the UI can fall back to account capture.
  Future<OwnerGoogleProfile> signInWithGoogle() async {
    try {
      await _ensureGoogleInitialized();
      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        throw UnsupportedError(
          'Google Sign-In authenticate is not available on this platform',
        );
      }
      final account = await GoogleSignIn.instance.authenticate();
      final email = account.email.trim();
      if (email.isEmpty) {
        throw StateError('Google account did not return an email');
      }
      final name = account.displayName?.trim().isNotEmpty == true
          ? account.displayName!.trim()
          : email.split('@').first;
      return OwnerGoogleProfile(name: name, email: email);
    } on UnsupportedError {
      rethrow;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw StateError('Google sign-in was cancelled');
      }
      throw UnsupportedError(
        'Google Sign-In is not available on this platform (${e.code})',
      );
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('cancelled') || msg.contains('canceled')) {
        rethrow;
      }
      if (msg.contains('Unsupported') ||
          msg.contains('not available') ||
          msg.contains('MissingPluginException')) {
        throw UnsupportedError(
          'Google Sign-In is not available on this platform',
        );
      }
      rethrow;
    }
  }

  /// Creates the primary OWNER row after Google identity + master PIN.
  Future<UserModel> completeOwnerOnboarding({
    required OwnerGoogleProfile identity,
    required String pinCode,
    String phone = '',
    String storeName = '',
  }) async {
    final pin = pinCode.trim();
    if (pin.length != 4 || int.tryParse(pin) == null) {
      throw ArgumentError('Owner PIN must be exactly 4 digits');
    }

    final existing = await DatabaseHelper.instance.hasOwner();
    if (existing) {
      throw StateError('Owner already exists — onboarding is locked');
    }

    final owner = UserModel(
      id: _newId(),
      name: identity.name.trim(),
      phone: phone.trim(),
      email: identity.email.trim().toLowerCase(),
      role: UserRole.owner,
      pinCode: pin,
      isActive: true,
      createdAt: DateTime.now(),
    );

    await DatabaseHelper.instance.insertUser(owner);

    final trimmedStore = storeName.trim();
    if (trimmedStore.isNotEmpty) {
      await ShopSettings.setShopName(trimmedStore);
    }
    if (phone.trim().isNotEmpty) {
      await ShopSettings.setShopPhone(phone.trim());
    }

    await _setSession(owner, persist: true);
    return owner;
  }

  /// Fast counter login using a 4-digit PIN (any matching active user).
  Future<UserModel> loginWithPin(String pinCode) async {
    final pin = pinCode.trim();
    if (pin.length != 4) {
      throw ArgumentError('Enter a 4-digit PIN');
    }
    final user = await DatabaseHelper.instance.findUserByPin(pin);
    if (user == null) {
      throw StateError('Invalid PIN');
    }
    if (!user.isActive) {
      throw StateError('This account is inactive');
    }
    await _setSession(user, persist: true);
    return user;
  }

  /// PIN login for a specific staff card selection.
  Future<UserModel> loginWithUserPin(UserModel user, String pinCode) async {
    final pin = pinCode.trim();
    if (pin.length != 4) {
      throw ArgumentError('Enter a 4-digit PIN');
    }
    if (user.pinCode != pin) {
      throw StateError('Invalid PIN');
    }
    if (!user.isActive) {
      throw StateError('This account is inactive');
    }
    // Re-fetch to ensure the account still exists / is active.
    final fresh = await DatabaseHelper.instance.getUserById(user.id);
    if (fresh == null || !fresh.isActive) {
      throw StateError('This account is inactive');
    }
    if (fresh.pinCode != pin) {
      throw StateError('Invalid PIN');
    }
    await _setSession(fresh, persist: true);
    return fresh;
  }

  Future<void> logout() async {
    try {
      if (_googleReady) {
        await GoogleSignIn.instance.signOut();
      }
    } catch (_) {
      // Ignore — desktop stubs may not support signOut.
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionUserIdKey);
    _currentUser = null;
    SessionContext.clear();
    notifyListeners();
  }

  Future<void> refreshCurrentUser() async {
    final id = _currentUser?.id;
    if (id == null) return;
    if (id == _debugOwnerId) return;
    final user = await DatabaseHelper.instance.getUserById(id);
    if (user == null || !user.isActive) {
      await logout();
      return;
    }
    await _setSession(user, persist: true);
  }

  Future<void> _setSession(UserModel user, {required bool persist}) async {
    _currentUser = user;
    SessionContext.setUser(user);
    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionUserIdKey, user.id);
    }
    notifyListeners();
  }

  static String _newId() {
    final rand = Random.secure().nextInt(0x7fffffff);
    return 'u_${DateTime.now().microsecondsSinceEpoch}_$rand';
  }
}
