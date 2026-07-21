import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/utils/app_version.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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

  String _shopName = '';
  String _shopAddress = '';
  String _shopPhone = '';
  bool _darkTheme = false;
  bool _loaded = false;
  String _versionLabel = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final results = await Future.wait([
      ShopSettings.getShopName(),
      ShopSettings.getShopAddress(),
      ShopSettings.getShopPhone(),
      ShopSettings.getDarkTheme(),
      AppVersion.displayLabel(),
    ]);
    if (!mounted) return;
    setState(() {
      _shopName = results[0] as String;
      _shopAddress = results[1] as String;
      _shopPhone = results[2] as String;
      _darkTheme = results[3] as bool;
      _versionLabel = results[4] as String;
      _loaded = true;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$title saved'),
          backgroundColor: const Color(0xFF28A745),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save: $e'),
          backgroundColor: const Color(0xFFDC3545),
        ),
      );
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

  Future<void> _toggleDarkTheme(bool value) async {
    setState(() => _darkTheme = value);
    await ShopSettings.setDarkTheme(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'Dark theme will apply in a future update'
              : 'Dark theme disabled',
        ),
        backgroundColor: AppColors.darkGreen,
      ),
    );
  }

  Future<void> _exportBackup() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Google Drive backup coming soon'),
        backgroundColor: AppColors.darkGreen,
      ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open email app'),
          backgroundColor: Color(0xFFDC3545),
        ),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Application data has been reset'),
            backgroundColor: Color(0xFF28A745),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to reset data: $e'),
            backgroundColor: const Color(0xFFDC3545),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
            child: const Row(
              children: [
                Text(
                  'System',
                  style: TextStyle(fontSize: 12, color: AppColors.textHint),
                ),
                Text(
                  '  ›  ',
                  style: TextStyle(fontSize: 12, color: AppColors.textHint),
                ),
                Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
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
                        _buildSectionLabel('Preferences & Data Safety'),
                        const SizedBox(height: 8),
                        _buildCard(
                          children: [
                            _SettingsRow(
                              icon: Icons.cloud_upload_outlined,
                              title: 'Google Drive Cloud Backup',
                              subtitle:
                                  'Save your local database securely to the cloud',
                              trailing: _ExportButton(onPressed: _exportBackup),
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
                          'AgriKhata ${_versionLabel.isEmpty ? 'v1.0.8' : _versionLabel}  •  Built with ❤️',
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
        child: Column(children: children),
      ),
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

class _ExportButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _ExportButton({required this.onPressed});

  @override
  State<_ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends State<_ExportButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFF163828) : AppColors.darkGreen,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_rounded, size: 12, color: Colors.white),
              SizedBox(width: 6),
              Text(
                'Export Now',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
