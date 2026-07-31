/// Persisted shop season (Kharif / Rabi) — source of truth for filtering
/// and past-season lock rules. Distinct from the calendar [Season] helper
/// in `ledger_models.dart`.
class Season {
  final int id;
  final String name;
  final String seasonType;
  final DateTime startDate;
  final DateTime? endDate;
  final bool isActive;

  const Season({
    required this.id,
    required this.name,
    required this.seasonType,
    required this.startDate,
    this.endDate,
    required this.isActive,
  });

  bool get isKharif => seasonType == SeasonType.kharif;
  bool get isRabi => seasonType == SeasonType.rabi;
  bool get isClosed => !isActive;

  /// Badge label e.g. `Active: Kharif 2026`.
  String get activeBadgeLabel =>
      isActive ? 'Active: $name' : name;

  Season copyWith({
    int? id,
    String? name,
    String? seasonType,
    DateTime? startDate,
    DateTime? endDate,
    bool clearEndDate = false,
    bool? isActive,
  }) {
    return Season(
      id: id ?? this.id,
      name: name ?? this.name,
      seasonType: seasonType ?? this.seasonType,
      startDate: startDate ?? this.startDate,
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'season_type': seasonType,
        'start_date': _dateOnly(startDate),
        'end_date': endDate == null ? null : _dateOnly(endDate!),
        'is_active': isActive ? 1 : 0,
      };

  factory Season.fromMap(Map<String, Object?> map) {
    final startRaw = map['start_date'] as String? ?? '';
    final endRaw = map['end_date'] as String?;
    return Season(
      id: (map['id'] as num?)?.toInt() ?? 0,
      name: map['name'] as String? ?? '',
      seasonType: map['season_type'] as String? ?? SeasonType.kharif,
      startDate: DateTime.tryParse(startRaw) ?? DateTime.now(),
      endDate: endRaw == null || endRaw.isEmpty
          ? null
          : DateTime.tryParse(endRaw),
      isActive: (map['is_active'] as num?)?.toInt() == 1,
    );
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Builds a display name: `Kharif 2026` or `Rabi 2026-27`.
  static String buildName(String seasonType, int startYear) {
    if (seasonType == SeasonType.rabi) {
      final endShort = ((startYear + 1) % 100).toString().padLeft(2, '0');
      return 'Rabi $startYear-$endShort';
    }
    return 'Kharif $startYear';
  }

  /// Calendar window for a season type starting in [startYear].
  static ({DateTime start, DateTime end}) dateWindow(
    String seasonType,
    int startYear,
  ) {
    if (seasonType == SeasonType.rabi) {
      return (
        start: DateTime(startYear, 10, 1),
        end: DateTime(startYear + 1, 3, 31, 23, 59, 59),
      );
    }
    return (
      start: DateTime(startYear, 4, 1),
      end: DateTime(startYear, 9, 30, 23, 59, 59),
    );
  }

  /// Opposite season type after the current one.
  static String nextType(String currentType) =>
      currentType == SeasonType.kharif ? SeasonType.rabi : SeasonType.kharif;

  /// Start year for the season that follows [currentType]/[currentStartYear].
  static int nextStartYear(String currentType, int currentStartYear) {
    // Kharif Y → Rabi Y; Rabi Y → Kharif Y+1
    if (currentType == SeasonType.kharif) return currentStartYear;
    return currentStartYear + 1;
  }

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Season && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class SeasonType {
  static const String kharif = 'Kharif';
  static const String rabi = 'Rabi';

  static const List<String> values = [kharif, rabi];

  static bool isValid(String value) => values.contains(value);
}

/// Sentinel filter keys for Zamindar ledger season dropdown.
class SeasonFilterOption {
  static const String current = 'Current Season';
  static const String allTime = 'All-Time';
}
