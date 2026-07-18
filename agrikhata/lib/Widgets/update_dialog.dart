import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:flutter/material.dart';

/// Premium desktop update prompt for AgriKhata shopkeepers.
class UpdateDialog extends StatefulWidget {
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
  final Future<void> Function(
    String downloadUrl, {
    void Function(String status)? onStatus,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  })? onUpdateNow;

  /// Shows a non-dismissible update dialog. Prefer this over raw [showDialog].
  static Future<void> show(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required List<String> changelog,
    required String downloadUrl,
    Future<void> Function(
      String downloadUrl, {
      void Function(String status)? onStatus,
      void Function(int receivedBytes, int totalBytes)? onProgress,
    })? onUpdateNow,
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
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _busy = false;
  String _status = '';
  String? _error;
  double? _progress; // null => indeterminate

  static String _formatDownloadLabel(int receivedBytes, int totalBytes) {
    final downloadedMB = receivedBytes / (1024 * 1024);
    if (totalBytes > 0) {
      final totalMB = totalBytes / (1024 * 1024);
      final percentage = ((receivedBytes / totalBytes) * 100).round();
      return 'Downloading: ${downloadedMB.toStringAsFixed(1)} MB / '
          '${totalMB.toStringAsFixed(1)} MB ($percentage%)';
    }
    return 'Downloading: ${downloadedMB.toStringAsFixed(1)} MB';
  }

  Future<void> _handleUpdateNow() async {
    final callback = widget.onUpdateNow;
    if (callback == null || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
      _status = 'Preparing update...';
      _progress = null;
    });

    try {
      await callback(
        widget.downloadUrl,
        onStatus: (status) {
          if (!mounted) return;
          setState(() {
            _status = status;
            // Non-download phases use an indeterminate bar.
            if (!status.startsWith('Downloading:')) {
              _progress = null;
            }
          });
        },
        onProgress: (receivedBytes, totalBytes) {
          if (!mounted) return;
          setState(() {
            _status = _formatDownloadLabel(receivedBytes, totalBytes);
            _progress =
                totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
          });
        },
      );
      // Detached install + exit(0) normally kills this process first.
      // If we are still here, close the dialog.
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
        _progress = null;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.changelog.isEmpty
        ? const ['A newer version of AgriKhata is ready to install.']
        : widget.changelog;

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
              if (_busy) ...[
                const SizedBox(height: 18),
                LinearProgressIndicator(
                  value: _progress,
                  color: AppColors.darkGreen,
                  backgroundColor: AppColors.tagGreenBg,
                  minHeight: 4,
                ),
                const SizedBox(height: 10),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                    height: 1.35,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.dangerBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.dangerBorder),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.dangerText,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 22),
              _buildActions(),
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
      child: Icon(
        _busy ? Icons.downloading_rounded : Icons.rocket_launch_rounded,
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
          _VersionChip(label: 'v${widget.currentVersion}', muted: true),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 16,
              color: AppColors.mediumGreen,
            ),
          ),
          _VersionChip(label: 'v${widget.latestVersion}', muted: false),
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

  Widget _buildActions() {
    return Row(
      children: [
        Expanded(
          child: TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
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
            onPressed: _busy ? null : _handleUpdateNow,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.darkGreen,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppColors.mediumGreen,
              elevation: 0,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                else
                  const Icon(Icons.system_update_alt_rounded, size: 18),
                const SizedBox(width: 8),
                Text(
                  _busy ? 'Updating...' : 'Update Now',
                  style: const TextStyle(
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
