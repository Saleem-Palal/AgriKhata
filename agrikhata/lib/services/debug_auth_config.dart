/// Dev-only auth bypass flag.
///
/// When `true` (and running in Flutter debug mode), [AuthService] auto-signs
/// in a mock Owner so hot restarts skip onboarding / PIN login.
///
/// Flip to `false`, or tap the floating DEBUG chip, to exercise the real
/// login flow. Ignored in release / profile builds.
const bool bypassLoginInDebug = true;
