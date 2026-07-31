import 'package:flutter/foundation.dart';

import '../Database/database_helper.dart';
import '../models/season.dart';
import '../models/user_model.dart';
import 'payment_service.dart';
import 'session_context.dart';

/// Global active-season context. UI listens via [activeSeasonNotifier].
class SeasonService {
  SeasonService._();
  static final SeasonService instance = SeasonService._();

  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Instant UI reactions when the shop rolls over or switches seasons.
  final ValueNotifier<Season?> activeSeasonNotifier = ValueNotifier<Season?>(
    null,
  );

  bool _initialized = false;

  Season? get activeSeason => activeSeasonNotifier.value;

  int? get activeSeasonId => activeSeason?.id;

  String? get activeSeasonName => activeSeason?.name;

  bool get isOwnerSession => SessionContext.currentUser?.isOwner == true;

  Future<void> initialize() async {
    if (_initialized && activeSeason != null) return;
    await ensureActiveSeason();
    _initialized = true;
  }

  Future<void> refreshActiveSeason() async {
    final season = await _db.getActiveSeason();
    activeSeasonNotifier.value = season;
  }

  Future<List<Season>> getAllSeasons() => _db.getAllSeasons();

  Future<Season?> getPreviousSeason() async {
    final all = await _db.getAllSeasons();
    final inactive = all.where((s) => !s.isActive).toList();
    if (inactive.isEmpty) return null;
    inactive.sort((a, b) => b.startDate.compareTo(a.startDate));
    return inactive.first;
  }

  /// Ensures an active season exists (seeds from calendar on first launch).
  Future<Season> ensureActiveSeason() async {
    final current = await _db.getActiveSeason();
    if (current != null) {
      activeSeasonNotifier.value = current;
      return current;
    }
    final seeded = await _db.ensureSeededActiveSeason();
    activeSeasonNotifier.value = seeded;
    return seeded;
  }

  /// True when the transaction belongs to a closed (inactive) season.
  Future<bool> isPastSeason({
    int? seasonId,
    String? seasonLabel,
  }) async {
    if (seasonId != null) {
      final season = await _db.getSeasonById(seasonId);
      if (season != null) return !season.isActive;
    }
    final label = (seasonLabel ?? '').trim();
    if (label.isEmpty) return false;

    final byName = await _db.getSeasonByName(label);
    if (byName != null) return !byName.isActive;

    // Legacy archived-season lock (settlement flow).
    return _db.isSeasonArchived(label);
  }

  /// Edit / delete gate for past seasons.
  ///
  /// - Active season → allowed
  /// - Past season + Owner session → allowed (optionally after Master PIN)
  /// - Past season + non-owner → blocked unless [masterAdminAuthorized]
  Future<SeasonEditability> evaluateEditability({
    int? seasonId,
    String? seasonLabel,
  }) async {
    final past = await isPastSeason(
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!past) {
      return const SeasonEditability(
        isEditable: true,
        requiresMasterAdmin: false,
      );
    }

    if (isOwnerSession) {
      return SeasonEditability(
        isEditable: true,
        requiresMasterAdmin: true,
        reason:
            'This entry belongs to a past season. '
            'Master Owner PIN is required to edit or delete it.',
      );
    }

    return const SeasonEditability(
      isEditable: false,
      requiresMasterAdmin: false,
      reason:
          '🔒 Past-season entries are read-only. '
          'Only the Owner / Master Admin can modify them.',
    );
  }

  Future<void> assertEditable({
    int? seasonId,
    String? seasonLabel,
    bool masterAdminAuthorized = false,
  }) async {
    final result = await evaluateEditability(
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!result.isEditable) {
      throw StateError(
        result.reason ?? 'This past-season entry cannot be modified.',
      );
    }
    if (result.requiresMasterAdmin && !masterAdminAuthorized && !isOwnerSession) {
      throw StateError(
        result.reason ??
            'Master Owner PIN is required to modify past-season entries.',
      );
    }
    // Owner session may proceed without PIN at the service layer; UI should
    // still prompt for Master PIN when [requiresMasterAdmin] is true.
    if (result.requiresMasterAdmin &&
        !masterAdminAuthorized &&
        isOwnerSession) {
      // Soft allow for Owner — callers that want hard PIN use verifyMasterPin.
      return;
    }
  }

  /// Verifies Master Owner PIN (same gate as payment Master Admin).
  Future<UserModel> verifyMasterOwnerPin(String pinCode) =>
      PaymentService.instance.verifyMasterAdminPasscode(pinCode);

  /// Ends the active season and opens the next one. Historical rows stay intact.
  Future<Season> proceedToNextSeason({
    required String seasonType,
    required int startYear,
    String? notes,
  }) async {
    if (!SeasonType.isValid(seasonType)) {
      throw ArgumentError('seasonType must be Kharif or Rabi');
    }
    if (!isOwnerSession) {
      throw StateError(
        'Only the Owner / Master Admin can roll over to a new season.',
      );
    }

    final next = await _db.rollOverToNextSeason(
      seasonType: seasonType,
      startYear: startYear,
      notes: notes,
    );
    activeSeasonNotifier.value = next;
    return next;
  }

  /// Suggested next season type + year based on the current active season.
  ({String seasonType, int startYear, String name}) suggestNextSeason() {
    final current = activeSeason;
    if (current == null) {
      final now = DateTime.now();
      final type = now.month >= 4 && now.month <= 9
          ? SeasonType.kharif
          : SeasonType.rabi;
      final year = type == SeasonType.rabi && now.month < 4
          ? now.year - 1
          : (type == SeasonType.rabi ? now.year : now.year);
      return (
        seasonType: type,
        startYear: year,
        name: Season.buildName(type, year),
      );
    }

    final nextType = Season.nextType(current.seasonType);
    final startYear = Season.nextStartYear(
      current.seasonType,
      current.startDate.year,
    );
    return (
      seasonType: nextType,
      startYear: startYear,
      name: Season.buildName(nextType, startYear),
    );
  }

  /// Label for Zamindar filter: current / previous name / All-Time.
  Future<List<String>> zamindarFilterLabels() async {
    await ensureActiveSeason();
    final labels = <String>[SeasonFilterOption.current];
    final previous = await getPreviousSeason();
    if (previous != null) {
      labels.add(previous.name);
    }
    labels.add(SeasonFilterOption.allTime);
    return labels;
  }

  /// Resolves a Zamindar dropdown selection to a season name filter.
  /// Returns `null` for All-Time (no filter).
  Future<String?> resolveZamindarFilter(String selected) async {
    if (selected == SeasonFilterOption.allTime) return null;
    if (selected == SeasonFilterOption.current) {
      final active = await ensureActiveSeason();
      return active.name;
    }
    return selected;
  }

  void dispose() {
    activeSeasonNotifier.dispose();
  }
}

class SeasonEditability {
  final bool isEditable;
  final bool requiresMasterAdmin;
  final String? reason;

  const SeasonEditability({
    required this.isEditable,
    required this.requiresMasterAdmin,
    this.reason,
  });
}
