import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/audit/audit_report_dialog.dart';
import 'package:agrikhata/screens/auth/auth_gate.dart';
import 'package:agrikhata/services/auth_service.dart';
import 'package:agrikhata/services/backup_service.dart';
import 'package:agrikhata/services/google_oauth_config.dart';
import 'package:agrikhata/utils/advance_checkout_overlay.dart';
import 'package:agrikhata/utils/app_version.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:agrikhata/Widgets/season_management_widgets.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:agrikhata/theme/theme.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onDataReset;
  final ValueChanged<String>? onShopNameChanged;

  const SettingsScreen({
    super.key,
    this.onDataReset,
    this.onShopNameChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _rowDivider = Color(0xFFEEF3EC);
  static const _iconBg = Color(0xFFF0F5EE);
  static const _rowSub = Color(0xFF8CA491);
  static const _sectionLabel = Color(0xFF5C8468);
  static const _chevron = Color(0xFFC6D5C9);
  static const _switchOff = Color(0xFFDCE5DA);
  static const _dangerCardBg = Color(0xFFFFF5F5);
  static const _dangerCardBorder = Color(0xFFF5C6C6);
  static const _dangerIconBg = Color(0xFFFCDCDC);
  static const _dangerTitle = Color(0xFFD64545);
  static const _dangerSub = Color(0xFFB56A6A);
  static const _footer = Color(0xFF95AC9C);
  static const _forestButton = Color(0xFF1B4332);

  String _shopName = '';
  String _shopAddress = '';
  String _shopPhone = '';
  bool _darkTheme = false;
  bool _showThumbprintBlockThermal = true;
  bool _loaded = false;
  String _versionLabel = '';
  double _cashOpeningBalance = 0;
  bool _backupBusy = false;
  bool _accountBusy = false;
  bool _fetchBusy = false;
  bool _autoBackupOnExit = false;
  bool _keepLocalCopy = true;
  String? _driveEmail;
  String _lastBackupLabel = 'Last Cloud Backup: Never';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final backup = BackupService.instance;
    final results = await Future.wait([
      ShopSettings.getShopName(),
      ShopSettings.getShopAddress(),
      ShopSettings.getShopPhone(),
      ShopSettings.getDarkTheme(),
      ShopSettings.getShowThumbprintBlockOnThermal(),
      AppVersion.displayLabel(),
      backup.loadPreferences(),
      ShopSettings.getCashOpeningBalance(),
    ]);
    if (!mounted) return;
    setState(() {
      _shopName = results[0] as String;
      _shopAddress = results[1] as String;
      _shopPhone = results[2] as String;
      _darkTheme = results[3] as bool;
      _showThumbprintBlockThermal = results[4] as bool;
      _versionLabel = results[5] as String;
      _driveEmail = backup.connectedEmail;
      _lastBackupLabel = backup.lastBackupStatusLabel;
      _autoBackupOnExit = backup.autoBackupOnExit;
      _keepLocalCopy = backup.keepLocalCopy;
      _cashOpeningBalance = results[7] as double;
      _loaded = true;
    });
  }

  void _syncBackupUi() {
    final backup = BackupService.instance;
    setState(() {
      _driveEmail = backup.connectedEmail;
      _lastBackupLabel = backup.lastBackupStatusLabel;
      _autoBackupOnExit = backup.autoBackupOnExit;
      _keepLocalCopy = backup.keepLocalCopy;
    });
  }

  Future<void> _editTextField({
    required String title,
    required String initialValue,
    required String hint,
    required Future<void> Function(String) onSave,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: maxLines > 1
                ? TextInputType.multiline
                : keyboardType,
            maxLines: maxLines,
            textInputAction:
                maxLines > 1 ? TextInputAction.newline : TextInputAction.done,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: AppColors.textHint),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.inputBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.inputBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: AppColors.darkGreen,
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            onSubmitted: maxLines > 1
                ? null
                : (value) => Navigator.of(ctx).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.darkGreen,
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (saved == null || !mounted) return;

    try {
      await onSave(saved);
      if (!mounted) return;
      AppToast.showSuccess(context, '$title saved');
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Failed to save: $e');
    }
  }

  Future<void> _editShopName() async {
    await _editTextField(
      title: 'Shop Name',
      initialValue:
          _shopName == ShopSettings.defaultShopName ? '' : _shopName,
      hint: 'e.g. AM Pesticides and Fertilizer',
      onSave: (value) async {
        await ShopSettings.setShopName(value);
        final resolved = await ShopSettings.getShopName();
        widget.onShopNameChanged?.call(resolved);
        if (mounted) setState(() => _shopName = resolved);
      },
    );
  }

  Future<void> _editAddress() async {
    await _editTextField(
      title: 'Business Address',
      initialValue: _shopAddress,
      hint: 'Street, city, province',
      maxLines: 3,
      onSave: (value) async {
        await ShopSettings.setShopAddress(value);
        if (mounted) setState(() => _shopAddress = value);
      },
    );
  }

  Future<void> _editPhone() async {
    await _editTextField(
      title: 'Contact Number',
      initialValue: _shopPhone,
      hint: 'e.g. +92 300 1234567',
      keyboardType: TextInputType.phone,
      onSave: (value) async {
        await ShopSettings.setShopPhone(value);
        if (mounted) setState(() => _shopPhone = value);
      },
    );
  }

  Future<void> _editCashOpeningBalance() async {
    await _editTextField(
      title: 'Cash Opening Balance',
      initialValue: _cashOpeningBalance > 0
          ? _cashOpeningBalance.toStringAsFixed(0)
          : '',
      hint: 'Counter float in Rs (e.g. 50000)',
      keyboardType: TextInputType.number,
      onSave: (value) async {
        final parsed =
            double.tryParse(value.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
        await ShopSettings.setCashOpeningBalance(parsed);
        if (mounted) setState(() => _cashOpeningBalance = parsed);
      },
    );
  }

  Future<void> _runSystemAudit() async {
    await showAuditReportDialog(context);
  }

  Future<void> _toggleDarkTheme(bool value) async {
    setState(() => _darkTheme = value);
    await ShopSettings.setDarkTheme(value);
    if (!mounted) return;
    AppToast.showSuccess(context, value
              ? 'Dark theme will apply in a future update'
              : 'Dark theme disabled',);
  }

  Future<void> _toggleThumbprintBlock(bool value) async {
    setState(() => _showThumbprintBlockThermal = value);
    await ShopSettings.setShowThumbprintBlockOnThermal(value);
    if (!mounted) return;
    AppToast.showSuccess(
      context,
      value
          ? 'Thumbprint block enabled on thermal receipts'
          : 'Thumbprint block hidden on thermal receipts',
    );
  }

  Future<bool> _ensureOAuthConfigured() async {
    await GoogleOAuthConfig.load();
    if (GoogleOAuthConfig.isConfigured) return true;
    return _showOAuthSetupDialog();
  }

  Future<bool> _showOAuthSetupDialog() async {
    final idController = TextEditingController(
      text: GoogleOAuthConfig.desktopClientId,
    );
    final secretController = TextEditingController(
      text: GoogleOAuthConfig.desktopClientSecret,
    );

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Configure Google Drive OAuth'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Windows desktop backup needs a Google Cloud Desktop OAuth client. Enable the Google Drive API, create a Desktop app client, then paste the credentials below.',
                  style: TextStyle(fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: idController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'OAuth Client ID',
                    hintText: 'xxxx.apps.googleusercontent.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: secretController,
                  decoration: const InputDecoration(
                    labelText: 'OAuth Client Secret (optional)',
                    hintText: 'GOCSPX-…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Authorized redirect URI (if prompted):\n'
                  'http://localhost:8765/ (fallback ports 8766–8769 are tried automatically)',
                  style: TextStyle(fontSize: 12, color: _rowSub, height: 1.4),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: _forestButton,
                foregroundColor: Colors.white,
              ),
              child: const Text('Save & Continue'),
            ),
          ],
        );
      },
    );

    final id = idController.text;
    final secret = secretController.text;
    idController.dispose();
    secretController.dispose();

    if (saved != true || !mounted) return false;
    try {
      await GoogleOAuthConfig.saveRuntimeCredentials(
        clientId: id,
        clientSecret: secret,
      );
      if (!mounted) return false;
      AppToast.showSuccess(context, 'Google OAuth credentials saved');
      return true;
    } catch (e) {
      if (!mounted) return false;
      AppToast.showError(context, '$e');
      return false;
    }
  }

  Future<void> _connectOrSwitchGoogle({required bool switchAccount}) async {
    if (_accountBusy) return;
    setState(() => _accountBusy = true);
    try {
      final ready = await _ensureOAuthConfigured();
      if (!ready) {
        if (!mounted) return;
        AppToast.showError(
          context,
          'Add a Google Desktop OAuth Client ID to connect Drive backup',
        );
        return;
      }

      if (switchAccount || BackupService.instance.isConnected) {
        await BackupService.instance.switchGoogleAccount();
      } else {
        final ok = await BackupService.instance.connectGoogleAccount();
        if (!ok) {
          if (!mounted) return;
          AppToast.showError(context, 'Google sign-in was cancelled');
          return;
        }
      }
      if (!mounted) return;
      _syncBackupUi();
      AppToast.showSuccess(
        context,
        'Connected: ${BackupService.instance.connectedEmail ?? 'Google Account'}',
      );
    } on GoogleOAuthNotConfiguredException {
      if (!mounted) return;
      final ready = await _showOAuthSetupDialog();
      if (ready && mounted) {
        setState(() => _accountBusy = false);
        await _connectOrSwitchGoogle(switchAccount: switchAccount);
        return;
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Google account error: $e');
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _disconnectGoogle() async {
    if (_accountBusy) return;
    setState(() => _accountBusy = true);
    try {
      await BackupService.instance.disconnectGoogleAccount();
      if (!mounted) return;
      _syncBackupUi();
      AppToast.showSuccess(context, 'Google Drive account disconnected');
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Disconnect failed: $e');
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _backupDatabaseNow() async {
    if (_backupBusy) return;
    setState(() => _backupBusy = true);
    try {
      final ready = await _ensureOAuthConfigured();
      if (!ready) {
        if (!mounted) return;
        AppToast.showError(context, 'Configure Google OAuth before backup');
        return;
      }
      if (!BackupService.instance.isConnected) {
        final ok = await BackupService.instance.connectGoogleAccount();
        if (!ok) {
          if (!mounted) return;
          AppToast.showError(context, 'Connect a Google account first');
          return;
        }
        _syncBackupUi();
      }
      final ok = await BackupService.instance.createCloudBackup();
      if (!mounted) return;
      _syncBackupUi();
      if (ok) {
        AppToast.showSuccess(context, 'Database backed up to Google Drive');
      } else {
        AppToast.showError(context, 'Backup did not complete');
      }
    } on GoogleOAuthNotConfiguredException {
      if (!mounted) return;
      await _showOAuthSetupDialog();
    } catch (e) {
      if (!mounted) return;
      _syncBackupUi();
      AppToast.showError(context, 'Backup failed: $e');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _fetchAndViewCloudBackups() async {
    if (_fetchBusy) return;
    setState(() => _fetchBusy = true);
    try {
      final ready = await _ensureOAuthConfigured();
      if (!ready) {
        if (!mounted) return;
        AppToast.showError(context, 'Configure Google OAuth before restore');
        return;
      }
      if (!BackupService.instance.isConnected) {
        final ok = await BackupService.instance.connectGoogleAccount();
        if (!ok) {
          if (!mounted) return;
          AppToast.showError(context, 'Connect a Google account first');
          return;
        }
        _syncBackupUi();
      }
      final backups = await BackupService.instance.fetchCloudBackups();
      if (!mounted) return;
      await _showCloudBackupsModal(backups);
    } on GoogleOAuthNotConfiguredException {
      if (!mounted) return;
      await _showOAuthSetupDialog();
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Could not fetch backups: $e');
    } finally {
      if (mounted) setState(() => _fetchBusy = false);
    }
  }

  Future<void> _showCloudBackupsModal(List<DriveBackupFile> backups) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Cloud Backups'),
          content: SizedBox(
            width: 520,
            child: backups.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No AgriKhata backups found in Google Drive.',
                      style: TextStyle(color: _rowSub),
                    ),
                  )
                : SizedBox(
                    height: 360,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: backups.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final file = backups[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            backgroundColor: _iconBg,
                            child: Icon(
                              Icons.cloud_download_outlined,
                              color: AppColors.accentGreen,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            file.formattedWhen,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13.5,
                            ),
                          ),
                          subtitle: Text(
                            '${file.name}  •  ${file.formattedSize}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: _rowSub,
                            ),
                          ),
                          trailing: TextButton(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              _confirmAndRestore(file);
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: _forestButton,
                            ),
                            child: const Text('Restore'),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmAndRestore(DriveBackupFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Restore Database from Cloud'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '⚠️ Restoring a backup will overwrite all existing local sales, inventory, and ledger data on this device. Create a local backup first?',
                style: TextStyle(height: 1.45),
              ),
              SizedBox(height: 12),
              Text(
                'If “Keep local backup copy on desktop” is enabled, a safety ZIP is saved under Documents/AgriKhata_Backups before restore.',
                style: TextStyle(fontSize: 12.5, color: _rowSub, height: 1.4),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: _forestButton,
                foregroundColor: Colors.white,
              ),
              child: const Text('Confirm & Restore'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _backupBusy = true);
    try {
      final ok = await BackupService.instance.restoreFromCloudBackup(file.id);
      if (!mounted) return;
      if (!ok) {
        AppToast.showError(context, 'Restore failed');
        return;
      }
      AppToast.showSuccess(context, 'Database restored — reloading app…');
      await _reloadAppAfterRestore();
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Restore failed: $e');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _reloadAppAfterRestore() async {
    widget.onDataReset?.call();
    try {
      await AuthService.instance.logout();
    } catch (_) {}
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthGate()),
      (_) => false,
    );
  }

  Future<void> _toggleAutoBackupOnExit(bool value) async {
    setState(() => _autoBackupOnExit = value);
    await BackupService.instance.setAutoBackupOnExit(value);
    if (!mounted) return;
    AppToast.showSuccess(
      context,
      value
          ? 'Auto-backup on app exit enabled'
          : 'Auto-backup on app exit disabled',
    );
  }

  Future<void> _toggleKeepLocalCopy(bool value) async {
    setState(() => _keepLocalCopy = value);
    await BackupService.instance.setKeepLocalCopy(value);
    if (!mounted) return;
    AppToast.showSuccess(
      context,
      value
          ? 'Local desktop backup copies enabled'
          : 'Local desktop backup copies disabled',
    );
  }

  Future<void> _contactSupport() async {
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@agrikhata.app',
      queryParameters: {
        'subject': 'AgriKhata Support',
        'body': 'Describe your issue or question about double-ledger rules:\n\n',
      },
    );
    final launched = await launchUrl(uri);
    if (!launched && mounted) {
      AppToast.showError(context, 'Could not open email app');
    }
  }

  Future<void> _showResetDialog(BuildContext context) async {
    final controller = TextEditingController();
    var canConfirm = false;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Reset Application Data'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This will permanently delete all sales, payments, purchases, ledger history, stock movements, and expenses for a new season. Zamindar, kisaan, product, and wholesaler profiles will be kept.\n\nType RESET to confirm:',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'RESET',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: AppColors.inputBorder,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: AppColors.darkGreen,
                          width: 1.5,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onChanged: (value) {
                      setDialogState(() {
                        canConfirm = value.trim() == 'RESET';
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed:
                      canConfirm ? () => Navigator.of(ctx).pop(true) : null,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF791F1F),
                  ),
                  child: const Text('Reset All Data'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    if (confirmed != true || !context.mounted) return;

    try {
      await DatabaseHelper.instance.truncateFullDatabase();
      widget.onDataReset?.call();

      if (context.mounted) {
        AppToast.showSuccess(context, 'Application data has been reset');
      }
    } catch (e) {
      if (context.mounted) {
        AppToast.showError(context, 'Failed to reset data: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          const AgriHeader(
            breadcrumbs: ['System', 'Settings'],
            actions: [
              ActiveSeasonBadge(),
            ],
          ),
          Expanded(
            child: !_loaded
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.darkGreen,
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 40,
                      vertical: 32,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: _buildPageHeader(),
                        ),
                        const SizedBox(height: 22),
                        _buildSectionLabel('Shop Identity'),
                        const SizedBox(height: 8),
                        _buildCard(
                          children: [
                            _SettingsRow(
                              icon: Icons.storefront_outlined,
                              title: 'Shop Name',
                              subtitle: ShopSettings.displayOrNotConfigured(
                                _shopName,
                              ),
                              onTap: _editShopName,
                            ),
                            _SettingsRow(
                              icon: Icons.location_on_outlined,
                              title: 'Business Address',
                              subtitle: ShopSettings.displayOrNotConfigured(
                                _shopAddress,
                              ),
                              onTap: _editAddress,
                            ),
                            _SettingsRow(
                              icon: Icons.phone_outlined,
                              title: 'Contact Number',
                              subtitle: ShopSettings.displayOrNotConfigured(
                                _shopPhone,
                              ),
                              onTap: _editPhone,
                              showDivider: false,
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _buildSectionLabel('Season Management'),
                        const SizedBox(height: 8),
                        const SeasonManagementCard(),
                        const SizedBox(height: 24),
                        _buildSectionLabel('Cloud Backup & Data Security'),
                        const SizedBox(height: 8),
                        _buildCloudBackupSection(),
                        const SizedBox(height: 24),
                        _buildSectionLabel('Preferences & Data Safety'),
                        const SizedBox(height: 8),
                        _buildCard(
                          children: [
                            _SettingsRow(
                              icon: Icons.account_balance_wallet_outlined,
                              title: 'Cash Opening Balance',
                              subtitle: _cashOpeningBalance > 0
                                  ? 'Rs ${NumberFormat('#,##,##0').format(_cashOpeningBalance.round())}'
                                  : 'Used by Cash in Hand KPI (not set)',
                              onTap: _editCashOpeningBalance,
                            ),
                            _SettingsRow(
                              icon: Icons.manage_search_rounded,
                              title: 'Run Audit & Reconcile All Ledgers',
                              subtitle:
                                  'Scan orphan rows, stock drift, KPI vs SQL sums, then fix',
                              onTap: _runSystemAudit,
                            ),
                            _SettingsRow(
                              icon: Icons.dark_mode_outlined,
                              title: 'Dark Theme',
                              subtitle:
                                  'Reduce eye strain in low-light environments',
                              trailing: Switch(
                                value: _darkTheme,
                                onChanged: _toggleDarkTheme,
                                activeThumbColor: Colors.white,
                                activeTrackColor: AppColors.accentGreen,
                                inactiveThumbColor: Colors.white,
                                inactiveTrackColor: _switchOff,
                                trackOutlineColor:
                                    const WidgetStatePropertyAll(
                                  Colors.transparent,
                                ),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            _SettingsRow(
                              icon: Icons.fingerprint_outlined,
                              title:
                                  'Show Thumbprint Block on Thermal Receipts',
                              subtitle:
                                  'Print Zamindar thumb/sign and shop stamp boxes on 80mm receipts',
                              trailing: Switch(
                                value: _showThumbprintBlockThermal,
                                onChanged: _toggleThumbprintBlock,
                                activeThumbColor: Colors.white,
                                activeTrackColor: AppColors.accentGreen,
                                inactiveThumbColor: Colors.white,
                                inactiveTrackColor: _switchOff,
                                trackOutlineColor:
                                    const WidgetStatePropertyAll(
                                  Colors.transparent,
                                ),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            _SettingsRow(
                              icon: Icons.help_outline_rounded,
                              title: 'Contact Support',
                              subtitle:
                                  'Get help with double-ledger rules or report an issue',
                              onTap: _contactSupport,
                              showDivider: false,
                            ),
                          ],
                        ),
                        const SizedBox(height: 38),
                        _buildDangerCard(),
                        const SizedBox(height: 36),
                        Text(
                          'AgriKhata ${_versionLabel.isEmpty ? 'v1.0.18' : _versionLabel}  •  Built with ❤️',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            color: _footer,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageHeader() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Settings',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        SizedBox(height: 3),
        Text(
          'Manage your shop identity, preferences, and data',
          style: TextStyle(
            fontSize: 12.5,
            color: _sectionLabel,
          ),
        ),
      ],
    );
  }

  Widget _buildSectionLabel(String label) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: _sectionLabel,
        letterSpacing: 0.6,
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _buildCloudBackupSection() {
    final email = (_driveEmail == null || _driveEmail!.trim().isEmpty)
        ? 'No Account Connected'
        : _driveEmail!.trim();
    final connected = email != 'No Account Connected';

    return _buildCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.cloud_outlined,
                    size: 20,
                    color: AppColors.accentGreen,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Google Drive Backup Account',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F9F4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    Icon(
                      connected
                          ? Icons.account_circle_rounded
                          : Icons.person_off_outlined,
                      size: 22,
                      color: connected ? AppColors.accentGreen : _rowSub,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        email,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color:
                              connected ? AppColors.textPrimary : _rowSub,
                        ),
                      ),
                    ),
                    if (_accountBusy)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.darkGreen,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (!connected)
                      _ForestActionButton(
                        icon: Icons.link_rounded,
                        label: 'Connect Google Account',
                        onPressed: _accountBusy
                            ? null
                            : () => _connectOrSwitchGoogle(
                                  switchAccount: false,
                                ),
                      )
                    else ...[
                      _ForestActionButton(
                        icon: Icons.swap_horiz_rounded,
                        label: 'Switch Google Account',
                        onPressed: _accountBusy
                            ? null
                            : () => _connectOrSwitchGoogle(
                                  switchAccount: true,
                                ),
                      ),
                      _OutlineActionButton(
                        icon: Icons.logout_rounded,
                        label: 'Disconnect',
                        onPressed: _accountBusy ? null : _disconnectGoogle,
                      ),
                    ],
                    _OutlineActionButton(
                      icon: Icons.key_outlined,
                      label: 'OAuth Setup',
                      onPressed: _accountBusy ? null : () async {
                        await _showOAuthSetupDialog();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const _CustomDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _lastBackupLabel,
                textAlign: TextAlign.left,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: _sectionLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: _ForestActionButton(
                  icon: Icons.cloud_upload_outlined,
                  label: 'Backup Database Now',
                  loading: _backupBusy,
                  onPressed: _backupBusy ? null : _backupDatabaseNow,
                ),
              ),
            ],
          ),
        ),
        const _CustomDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Restore Database from Cloud',
                textAlign: TextAlign.left,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Download a previous AgriKhata backup ZIP from Google Drive and replace the local database.',
                textAlign: TextAlign.left,
                style: TextStyle(
                  fontSize: 11.5,
                  color: _rowSub,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: _ForestActionButton(
                  icon: Icons.cloud_download_outlined,
                  label: 'Fetch & View Cloud Backups',
                  loading: _fetchBusy,
                  onPressed: _fetchBusy ? null : _fetchAndViewCloudBackups,
                ),
              ),
            ],
          ),
        ),
        const _CustomDivider(),
        _SettingsRow(
          icon: Icons.exit_to_app_outlined,
          title: 'Auto-backup to Google Drive on App Exit',
          subtitle: 'Upload a fresh cloud backup when AgriKhata is closed',
          trailing: Switch(
            value: _autoBackupOnExit,
            onChanged: _toggleAutoBackupOnExit,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.accentGreen,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: _switchOff,
            trackOutlineColor:
                const WidgetStatePropertyAll(Colors.transparent),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        _SettingsRow(
          icon: Icons.folder_copy_outlined,
          title: 'Keep local backup copy on desktop',
          subtitle: 'Also save ZIP copies under Documents/AgriKhata_Backups',
          trailing: Switch(
            value: _keepLocalCopy,
            onChanged: _toggleKeepLocalCopy,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.accentGreen,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: _switchOff,
            trackOutlineColor:
                const WidgetStatePropertyAll(Colors.transparent),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          showDivider: false,
        ),
      ],
    );
  }

  Widget _buildDangerCard() {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: _dangerCardBg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () => _showResetDialog(context),
          borderRadius: BorderRadius.circular(14),
          hoverColor: const Color(0xFFFEEAEA),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _dangerCardBorder),
            ),
            child: const Row(
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _dangerIconBg,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 17,
                      color: _dangerTitle,
                    ),
                  ),
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reset Application',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: _dangerTitle,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Wipes all local transactions, customers, and data forever.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: _dangerSub,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ForestActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  const _ForestActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(icon, size: 16),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: _SettingsScreenState._forestButton,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFF9BB0A3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        textStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}

class _OutlineActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _OutlineActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: _SettingsScreenState._forestButton,
        side: const BorderSide(color: Color(0xFFC6DEC9)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        textStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}

class _CustomDivider extends StatelessWidget {
  const _CustomDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 1,
      indent: 20,
      endIndent: 20,
      color: _SettingsScreenState._rowDivider,
    );
  }
}

class _SettingsRow extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.showDivider = true,
  });

  @override
  State<_SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<_SettingsRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              color: _hovered && widget.onTap != null
                  ? const Color(0xFFFAFBF8)
                  : Colors.white,
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _SettingsScreenState._iconBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      widget.icon,
                      size: 22,
                      color: AppColors.accentGreen,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: _SettingsScreenState._rowSub,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.trailing != null)
                    widget.trailing!
                  else
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: _SettingsScreenState._chevron,
                    ),
                ],
              ),
            ),
            if (widget.showDivider) const _CustomDivider(),
          ],
        ),
      ),
    );
  }
}

