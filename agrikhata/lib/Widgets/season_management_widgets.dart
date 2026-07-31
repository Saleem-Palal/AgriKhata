import 'package:agrikhata/models/season.dart';
import 'package:agrikhata/services/season_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Compact badge for headers: `🟢 Active: Kharif 2026`.
class ActiveSeasonBadge extends StatelessWidget {
  const ActiveSeasonBadge({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Season?>(
      valueListenable: SeasonService.instance.activeSeasonNotifier,
      builder: (context, season, _) {
        final label = season == null
            ? 'No active season'
            : '🟢 Active: ${season.name}';
        final child = Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFFEDF7EE),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFC6DEC9)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1B4332),
            ),
          ),
        );
        if (onTap == null) return child;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(onTap: onTap, child: child),
        );
      },
    );
  }
}

/// Settings card: active season + Proceed to Next Season.
class SeasonManagementCard extends StatelessWidget {
  const SeasonManagementCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Season?>(
      valueListenable: SeasonService.instance.activeSeasonNotifier,
      builder: (context, season, _) {
        final isOwner = SeasonService.instance.isOwnerSession;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE4EDE6)),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F5EE),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.eco_outlined,
                      color: Color(0xFF1B4332),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Current Season',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1B4332),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          season == null
                              ? 'Not configured'
                              : '🟢 Active: ${season.name}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF5C8468),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                isOwner
                    ? 'End the current season and open a clean Kharif / Rabi '
                        'ledger. Historical invoices stay in the database.'
                    : 'Only the Owner / Master Admin can roll over seasons.',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: Color(0xFF8CA491),
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: isOwner
                      ? () => showProceedToNextSeasonDialog(context)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1B4332),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  icon: const Text('🚀', style: TextStyle(fontSize: 14)),
                  label: const Text('Proceed to Next Season'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<bool> showProceedToNextSeasonDialog(BuildContext context) async {
  final service = SeasonService.instance;
  if (!service.isOwnerSession) {
    AppToast.showError(
      context,
      'Only the Owner / Master Admin can start a new season.',
    );
    return false;
  }

  await service.ensureActiveSeason();
  final suggestion = service.suggestNextSeason();
  final current = service.activeSeason;

  var selectedType = suggestion.seasonType;
  final yearController = TextEditingController(
    text: suggestion.startYear.toString(),
  );
  final pinController = TextEditingController();
  String? error;

  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          int year = int.tryParse(yearController.text.trim()) ??
              suggestion.startYear;
          final previewName = Season.buildName(selectedType, year);

          return AlertDialog(
            title: const Text('Proceed to Next Season'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (current != null) ...[
                    Text(
                      'Ending: ${current.name}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B4332),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'The current season will be marked inactive and locked '
                      'for standard users. All historical records are preserved.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF5C8468)),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Text(
                    'Next season type',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: SeasonType.kharif,
                        label: Text('Kharif'),
                      ),
                      ButtonSegment(
                        value: SeasonType.rabi,
                        label: Text('Rabi'),
                      ),
                    ],
                    selected: {selectedType},
                    onSelectionChanged: (set) {
                      setLocal(() => selectedType = set.first);
                    },
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: yearController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Start year',
                      hintText: 'e.g. 2026',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF7EE),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFC6DEC9)),
                    ),
                    child: Text(
                      'New active season: $previewName',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B4332),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: pinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Master Owner PIN',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: const TextStyle(
                        color: Color(0xFFD64545),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B4332),
                ),
                onPressed: () async {
                  final y = int.tryParse(yearController.text.trim());
                  if (y == null || y < 2000 || y > 2100) {
                    setLocal(() => error = 'Enter a valid start year');
                    return;
                  }
                  try {
                    await service.verifyMasterOwnerPin(pinController.text);
                    await service.proceedToNextSeason(
                      seasonType: selectedType,
                      startYear: y,
                    );
                    if (ctx.mounted) Navigator.of(ctx).pop(true);
                  } catch (e) {
                    setLocal(() => error = e.toString().replaceFirst(
                          'Bad state: ',
                          '',
                        ));
                  }
                },
                child: const Text('Confirm Rollover'),
              ),
            ],
          );
        },
      );
    },
  );

  yearController.dispose();
  pinController.dispose();

  if (confirmed == true && context.mounted) {
    AppToast.showSuccess(
      context,
      'Season rolled over to ${service.activeSeason?.name ?? 'new season'}',
    );
  }
  return confirmed == true;
}
