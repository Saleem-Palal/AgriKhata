import 'package:agrikhata/services/season_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Gates edit/delete of past-season rows. Returns `true` when allowed.
///
/// Non-owners are blocked. Owners must enter the Master Owner PIN.
Future<bool> ensurePastSeasonWriteAccess(
  BuildContext context, {
  int? seasonId,
  String? seasonLabel,
}) async {
  final result = await SeasonService.instance.evaluateEditability(
    seasonId: seasonId,
    seasonLabel: seasonLabel,
  );
  if (result.isEditable && !result.requiresMasterAdmin) {
    return true;
  }
  if (!result.isEditable) {
    if (context.mounted) {
      AppToast.showError(
        context,
        result.reason ?? 'Past-season entries are read-only.',
      );
    }
    return false;
  }

  final pinController = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: const Text('Past Season — Owner Authorization'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  result.reason ??
                      'Master Owner PIN is required to modify past-season entries.',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pinController,
                  obscureText: true,
                  autofocus: true,
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
                  try {
                    await SeasonService.instance
                        .verifyMasterOwnerPin(pinController.text);
                    if (ctx.mounted) Navigator.of(ctx).pop(true);
                  } catch (e) {
                    setLocal(() {
                      error = e.toString().replaceFirst('Bad state: ', '');
                    });
                  }
                },
                child: const Text('Authorize'),
              ),
            ],
          );
        },
      );
    },
  );
  pinController.dispose();
  return ok == true;
}
