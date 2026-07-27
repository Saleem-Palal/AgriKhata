import '../models/user_model.dart';

/// Process-wide pointer to the signed-in shop user.
///
/// Kept separate from [AuthService] so the database layer can stamp
/// `created_by_*` columns without importing UI/auth packages.
class SessionContext {
  SessionContext._();

  static UserModel? currentUser;

  static String? get userId => currentUser?.id;
  static String? get userName => currentUser?.name;
  static String? get role => currentUser?.role;

  /// Snapshot label for inserts: `Name (Role)`. Null when signed out.
  static String? get footprintLabel => currentUser?.footprintLabel;

  static void setUser(UserModel? user) => currentUser = user;

  static void clear() => currentUser = null;
}
