import 'package:agrikhata/models/ledger_models.dart';
import 'package:agrikhata/services/partner_accounting_service.dart';
import 'package:agrikhata/services/settlement_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:agrikhata/utils/season_utils.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Dynamic Seasonal Settlement / Profit Reinvestment modal.
class SeasonalSettlementDialog extends StatefulWidget {
  const SeasonalSettlementDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const SeasonalSettlementDialog(),
    );
  }

  @override
  State<SeasonalSettlementDialog> createState() =>
      _SeasonalSettlementDialogState();
}

class _SeasonalSettlementDialogState extends State<SeasonalSettlementDialog> {
  static final NumberFormat _currency = NumberFormat('#,##,##0');

  final List<Season> _seasons = SeasonUtils.getAvailableSeasons(yearsBack: 2);
  late Season _selected;
  SeasonalProfitSummary? _summary;
  bool _loading = true;
  bool _saving = false;
  bool _lockArchive = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = SeasonUtils.getCurrentSeason();
    // Ensure current season is in the dropdown list.
    if (!_seasons.contains(_selected)) {
      _seasons.insert(0, _selected);
    }
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await SettlementService.instance.aggregateSeasonProfit(
        season: _selected,
      );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
        if (summary.isArchived) _lockArchive = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _summary = null;
      });
    }
  }

  String _rs(num n, {bool signed = false, bool forcePlus = false}) {
    final abs = _currency.format(n.abs().round());
    if (!signed && !forcePlus) return 'Rs $abs';
    if (n < 0) return '- Rs $abs';
    return '+ Rs $abs';
  }

  Future<void> _confirm() async {
    final summary = _summary;
    if (summary == null || !summary.canSettle) return;
    setState(() => _saving = true);
    try {
      await PartnerAccountingService.instance.runSeasonalSettlement(
        netProfit: summary.netDistributableProfit,
        seasonLabel: summary.seasonLabel,
        lockAndArchiveSeason: _lockArchive,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, '$e');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Seasonal Settlement / Profit Reinvestment',
      subtitle: 'Auto-calculated from cash margins, recovered khaata & overheads',
      maxWidth: 560,
      onClose: _saving ? null : () => Navigator.of(context).pop(false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Season',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B8F71),
            ),
          ),
          const SizedBox(height: 5),
          DropdownButtonFormField<Season>(
            initialValue: _selected,
            decoration: _fieldDeco('Select season'),
            items: _seasons
                .map(
                  (s) => DropdownMenuItem(
                    value: s,
                    child: Text(s.displayName),
                  ),
                )
                .toList(),
            onChanged: _saving
                ? null
                : (v) {
                    if (v == null) return;
                    setState(() => _selected = v);
                    _reload();
                  },
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_error != null)
            _errorBanner(_error!)
          else if (_summary != null) ...[
            _profitCard(_summary!),
            if (_summary!.totalUnrecoveredCreditMargin > 0.5) ...[
              const SizedBox(height: 10),
              _unrecoveredBanner(_summary!),
            ],
            const SizedBox(height: 14),
            _partnerSplitTable(_summary!),
            const SizedBox(height: 12),
            _lockSwitch(),
            if (_summary!.alreadySettled) ...[
              const SizedBox(height: 10),
              _statusBanner(
                'This season has already been settled. Credits were applied '
                'to Unsettled Profit.',
                AppColors.tagBlueBg,
                AppColors.tagBlueText,
              ),
            ] else if (_summary!.netDistributableProfit <= 0) ...[
              const SizedBox(height: 10),
              _statusBanner(
                'Net distributable profit is zero or negative for this season. '
                'Nothing to credit yet.',
                AppColors.tagAmberBg,
                AppColors.tagAmberText,
              ),
            ],
          ],
        ],
      ),
      actions: [
        AppButton.secondary(
          label: 'Cancel',
          icon: Icons.close,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        AppButton.primary(
          label: 'Confirm & Credit Partner Accounts',
          icon: Icons.check,
          loading: _saving,
          onPressed: (_summary?.canSettle == true && !_saving) ? _confirm : null,
        ),
      ],
    );
  }

  Widget _profitCard(SeasonalProfitSummary s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3DE),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF97C459), width: 0.8),
      ),
      child: Column(
        children: [
          _moneyRow(
            'Cash Sales Margin',
            _rs(s.totalCashSalesMargin, forcePlus: true),
            const Color(0xFF2D6A4F),
          ),
          const SizedBox(height: 6),
          _moneyRow(
            'Recovered Credit Margin',
            _rs(s.totalRecoveredCreditMargin, forcePlus: true),
            const Color(0xFF2D6A4F),
            hint: 'Realized Khaata',
          ),
          const SizedBox(height: 6),
          _moneyRow(
            'Seasonal Overhead Expenses',
            _rs(-s.totalSeasonOverheads, signed: true),
            const Color(0xFFA32D2D),
            hint: 'Split 50-50',
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1, color: Color(0xFFB7CFB9)),
          ),
          _moneyRow(
            'NET DISTRIBUTABLE PROFIT',
            _rs(s.netDistributableProfit),
            AppColors.primary,
            bold: true,
          ),
        ],
      ),
    );
  }

  Widget _moneyRow(
    String label,
    String value,
    Color valueColor, {
    String? hint,
    bool bold = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: bold ? 12.5 : 12,
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                  color: AppColors.textPrimary,
                  letterSpacing: bold ? 0.2 : 0,
                ),
              ),
              if (hint != null)
                Text(
                  hint,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: bold ? 14 : 12.5,
            fontWeight: FontWeight.w800,
            color: valueColor,
          ),
        ),
      ],
    );
  }

  Widget _unrecoveredBanner(SeasonalProfitSummary s) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.tagAmberBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8C98B), width: 0.8),
      ),
      child: Text(
        'ℹ️ Unrecovered Udhaar Margin: ${_rs(s.totalUnrecoveredCreditMargin)} '
        '(Tied in pending credit sales. This profit will be distributed in '
        'future seasons upon collection).',
        style: const TextStyle(
          fontSize: 11.5,
          height: 1.4,
          color: AppColors.tagAmberText,
        ),
      ),
    );
  }

  Widget _partnerSplitTable(SeasonalProfitSummary s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Partner Equity Split → Unsettled Profit',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF6B8F71),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              for (var i = 0; i < s.partnerShares.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, color: AppColors.border),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${s.partnerShares[i].partner.name} '
                          '(${s.partnerShares[i].equitySharePct.toStringAsFixed(0)}%)',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        _rs(
                          s.partnerShares[i].profitCredit,
                          forcePlus: s.netDistributableProfit > 0,
                        ),
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF2D6A4F),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (s.partnerShares.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'No active partners',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Credited to Unsettled Profit on confirm',
          style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
        ),
      ],
    );
  }

  Widget _lockSwitch() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          Switch.adaptive(
            value: _lockArchive,
            activeThumbColor: AppColors.primary,
            onChanged: (_saving || (_summary?.isArchived ?? false))
                ? null
                : (v) => setState(() => _lockArchive = v),
          ),
          const SizedBox(width: 4),
          const Expanded(
            child: Text(
              'Lock & Archive Season Ledger on Settlement',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String message) => _statusBanner(
        message,
        AppColors.dangerBg,
        AppColors.dangerText,
      );

  Widget _statusBanner(String message, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 12, height: 1.35, color: fg),
      ),
    );
  }

  InputDecoration _fieldDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 12.5),
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: AppColors.inputBorder, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: AppColors.inputBorder, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary, width: 1),
        ),
      );
}
