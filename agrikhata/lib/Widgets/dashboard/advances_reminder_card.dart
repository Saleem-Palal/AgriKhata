import 'package:agrikhata/Database/database_helper.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Amber reminder card: pending kisaan cash advances & fuel slips.
class AdvancesReminderCard extends StatelessWidget {
  final PendingAdvancesReminder reminder;
  final void Function(PendingAdvanceRow row)? onViewKhaataLedger;
  final bool isLoading;

  const AdvancesReminderCard({
    super.key,
    required this.reminder,
    this.onViewKhaataLedger,
    this.isLoading = false,
  });

  static final NumberFormat _currency = NumberFormat('#,##,##0');
  static final DateFormat _dateFmt = DateFormat('dd MMM yyyy');

  String _rs(double amount) => '₨ ${_currency.format(amount.round())}';

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF0C48A), width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: const BoxDecoration(
              color: Color(0xFFFFF1DE),
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              border: Border(
                bottom: BorderSide(color: Color(0xFFF0C48A), width: 0.5),
              ),
            ),
            child: const Row(
              children: [
                Text('⚠️', style: TextStyle(fontSize: 15)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pending Kisaan Advances & Fuel Slips',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8A4B12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: isLoading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFC27803),
                        ),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildMetricsRow(),
                      const SizedBox(height: 12),
                      if (!reminder.hasPending)
                        const Text(
                          'No pending cash advances or fuel slips.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFA87A45),
                          ),
                        )
                      else ...[
                        const Text(
                          'Recent pending',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF8A4B12),
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (var i = 0;
                            i < reminder.recentPending.length;
                            i++) ...[
                          if (i > 0)
                            const Divider(
                              height: 1,
                              color: Color(0xFFF0D5B0),
                            ),
                          _buildRow(reminder.recentPending[i]),
                        ],
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsRow() {
    return Row(
      children: [
        Expanded(
          child: _MetricTile(
            label: 'Cash Advances',
            value: _rs(reminder.totalActiveCashAdvances),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MetricTile(
            label: 'Fuel Slips',
            value: _rs(reminder.totalActiveFuelSlips),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MetricTile(
            label: 'Zamindars',
            value: '${reminder.zamindarCountWithPending}',
            subtitle: reminder.zamindarCountWithPending == 1
                ? '1 Zamindar'
                : '${reminder.zamindarCountWithPending} Zamindars',
          ),
        ),
      ],
    );
  }

  Widget _buildRow(PendingAdvanceRow row) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.zamindarName,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5C3A14),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _dateFmt.format(row.dateIssued),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFA87A45),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: row.isFuel
                  ? const Color(0xFFE8F1FF)
                  : const Color(0xFFFFF3D6),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: row.isFuel
                    ? const Color(0xFFB7C9E8)
                    : const Color(0xFFE8C98A),
                width: 0.5,
              ),
            ),
            child: Text(
              row.typeLabel,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: row.isFuel
                    ? const Color(0xFF2F5F9E)
                    : const Color(0xFF8A4B12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 88,
            child: Text(
              _rs(row.amount),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF5C3A14),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'View Khaata Ledger',
            child: OutlinedButton(
              onPressed: row.zamindarId == null
                  ? null
                  : () => onViewKhaataLedger?.call(row),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF8A4B12),
                side: const BorderSide(color: Color(0xFFE0A95A), width: 0.7),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text(
                '📄 View Khaata',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;

  const _MetricTile({
    required this.label,
    required this.value,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF0D5B0), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: Color(0xFFA87A45),
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle ?? value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF8A4B12),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
