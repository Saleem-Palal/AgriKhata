import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:flutter/material.dart';

/// Premium desktop update prompt for AgriKhata shopkeepers.
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    super.key,
    required this.latestVersion,
    required this.currentVersion,
    required this.changelog,
    required this.downloadUrl,
    this.onUpdateNow,
  });

  final String latestVersion;
  final String currentVersion;
  final List<String> changelog;
  final String downloadUrl;
  final Future<void> Function(String downloadUrl)? onUpdateNow;

  /// Shows a non-dismissible update dialog. Prefer this over raw [showDialog].
  static Future<void> show(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required List<String> changelog,
    required String downloadUrl,
    Future<void> Function(String downloadUrl)? onUpdateNow,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (dialogContext) => UpdateDialog(
        latestVersion: latestVersion,
        currentVersion: currentVersion,
        changelog: changelog,
        downloadUrl: downloadUrl,
        onUpdateNow: onUpdateNow,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notes = changelog.isEmpty
        ? const ['A newer version of AgriKhata is ready to install.']
        : changelog;

    return Dialog(
      backgroundColor: Colors.white,
      elevation: 8,
      shadowColor: AppColors.darkGreen.withValues(alpha: 0.18),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 400, maxWidth: 450),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeaderIcon(),
              const SizedBox(height: 18),
              const Text(
                'New Update Available!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.darkGreen,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 14),
              _buildVersionBadge(),
              const SizedBox(height: 18),
              _buildChangelogBox(notes),
              const SizedBox(height: 22),
              _buildActions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderIcon() {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: AppColors.tagGreenBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: const Icon(
        Icons.rocket_launch_rounded,
        color: AppColors.darkGreen,
        size: 30,
      ),
    );
  }

  Widget _buildVersionBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _VersionChip(label: 'v$currentVersion', muted: true),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 16,
              color: AppColors.mediumGreen,
            ),
          ),
          _VersionChip(label: 'v$latestVersion', muted: false),
        ],
      ),
    );
  }

  Widget _buildChangelogBox(List<String> notes) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Scrollbar(
        thumbVisibility: notes.length > 4,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < notes.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 7),
                      child: Icon(
                        Icons.circle,
                        size: 6,
                        color: AppColors.mediumGreen,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _stripBullet(notes[i]),
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13.5,
                          height: 1.45,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textMuted,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: AppColors.border),
              ),
            ),
            child: const Text(
              'Remind Me Later',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              final callback = onUpdateNow;
              if (callback != null) {
                await callback(downloadUrl);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.darkGreen,
              foregroundColor: Colors.white,
              elevation: 0,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.download_rounded, size: 18),
                SizedBox(width: 8),
                Text(
                  'Update Now',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _stripBullet(String line) {
    final trimmed = line.trim();
    if (trimmed.startsWith('•') ||
        trimmed.startsWith('-') ||
        trimmed.startsWith('*')) {
      return trimmed.substring(1).trim();
    }
    return trimmed;
  }
}

class _VersionChip extends StatelessWidget {
  const _VersionChip({required this.label, required this.muted});

  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: muted ? Colors.white : AppColors.tagGreenBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: muted ? AppColors.border : AppColors.recBorder,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: muted ? AppColors.textMuted : AppColors.darkGreen,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}
