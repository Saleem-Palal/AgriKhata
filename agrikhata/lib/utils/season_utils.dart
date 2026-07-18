import '../models/ledger_models.dart';

class SeasonUtils {
  static Season getCurrentSeason([DateTime? referenceDate]) {
    final now = referenceDate ?? DateTime.now();
    final year = now.year;
    final month = now.month;

    if (month >= 4 && month <= 9) {
      return Season(
        name: 'Kharif',
        year: year,
        startDate: DateTime(year, 4, 1),
        endDate: DateTime(year, 9, 30, 23, 59, 59),
      );
    } else {
      if (month >= 10) {
        return Season(
          name: 'Rabi',
          year: year,
          startDate: DateTime(year, 10, 1),
          endDate: DateTime(year + 1, 3, 31, 23, 59, 59),
        );
      } else {
        return Season(
          name: 'Rabi',
          year: year - 1,
          startDate: DateTime(year - 1, 10, 1),
          endDate: DateTime(year, 3, 31, 23, 59, 59),
        );
      }
    }
  }

  static List<Season> getAvailableSeasons({int yearsBack = 3}) {
    final currentSeason = getCurrentSeason();
    final seasons = <Season>[];

    seasons.add(currentSeason);

    for (int i = 1; i <= yearsBack * 2; i++) {
      final previousSeason = _getPreviousSeason(seasons.last);
      seasons.add(previousSeason);
    }

    return seasons;
  }

  static Season _getPreviousSeason(Season current) {
    if (current.name == 'Kharif') {
      return Season(
        name: 'Rabi',
        year: current.year - 1,
        startDate: DateTime(current.year - 1, 10, 1),
        endDate: DateTime(current.year, 3, 31, 23, 59, 59),
      );
    } else {
      return Season(
        name: 'Kharif',
        year: current.year,
        startDate: DateTime(current.year, 4, 1),
        endDate: DateTime(current.year, 9, 30, 23, 59, 59),
      );
    }
  }

  static String getSeasonString(DateTime date) {
    final season = getCurrentSeason(date);
    return season.displayName;
  }

  /// Calendar days elapsed since the season's start date (0 on day 1).
  static int daysElapsedInSeason([DateTime? referenceDate]) {
    final now = referenceDate ?? DateTime.now();
    final season = getCurrentSeason(now);
    final start = DateTime(
      season.startDate.year,
      season.startDate.month,
      season.startDate.day,
    );
    final today = DateTime(now.year, now.month, now.day);
    final elapsed = today.difference(start).inDays;
    return elapsed < 0 ? 0 : elapsed;
  }

  /// Coarse stage label for the current day inside the active season.
  static String seasonStageLabel([DateTime? referenceDate]) {
    final days = daysElapsedInSeason(referenceDate);
    if (days <= 45) return 'Early season';
    if (days <= 110) return 'Mid-season';
    return 'Late season';
  }

  static Season? parseSeasonDisplayName(String displayName) {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return null;

    final parts = trimmed.split(' ');
    if (parts.length < 2) return null;

    final year = int.tryParse(parts.last);
    if (year == null) return null;

    final name = parts.sublist(0, parts.length - 1).join(' ');
    if (name == 'Kharif') {
      return Season(
        name: 'Kharif',
        year: year,
        startDate: DateTime(year, 4, 1),
        endDate: DateTime(year, 9, 30, 23, 59, 59),
      );
    }
    if (name == 'Rabi') {
      return Season(
        name: 'Rabi',
        year: year,
        startDate: DateTime(year, 10, 1),
        endDate: DateTime(year + 1, 3, 31, 23, 59, 59),
      );
    }
    return null;
  }

  static List<Season> seasonsFromDisplayNames(List<String> displayNames) {
    final seasons = <Season>[];
    for (final name in displayNames) {
      final season = parseSeasonDisplayName(name);
      if (season != null && !seasons.contains(season)) {
        seasons.add(season);
      }
    }
    return seasons;
  }
}
