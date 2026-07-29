import 'package:agrikhata/models/audit_report_model.dart';
import 'package:agrikhata/services/audit_report_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Modal that runs the full system audit and optionally reconciles ledgers.
Future<void> showAuditReportDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _AuditReportDialog(),
  );
}

class _AuditReportDialog extends StatefulWidget {
  const _AuditReportDialog();

  @override
  State<_AuditReportDialog> createState() => _AuditReportDialogState();
}

class _AuditReportDialogState extends State<_AuditReportDialog> {
  bool _running = false;
  bool _reconcile = true;
  AuditReportModel? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run({bool? reconcile}) async {
    setState(() {
      _running = true;
      _error = null;
      if (reconcile != null) _reconcile = reconcile;
    });
    try {
      final report = await AuditReportService.instance.runFullSystemAudit(
        reconcile: _reconcile,
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _running = false;
      });
    }
  }

  Color _statusColor(AuditCheckStatus status) {
    switch (status) {
      case AuditCheckStatus.ok:
        return const Color(0xFF1B7A4E);
      case AuditCheckStatus.fixed:
        return const Color(0xFF1D6FA5);
      case AuditCheckStatus.warning:
        return const Color(0xFFB86E00);
      case AuditCheckStatus.failed:
        return const Color(0xFFA32D2D);
    }
  }

  IconData _statusIcon(AuditCheckStatus status) {
    switch (status) {
      case AuditCheckStatus.ok:
        return Icons.check_circle_outline;
      case AuditCheckStatus.fixed:
        return Icons.build_circle_outlined;
      case AuditCheckStatus.warning:
        return Icons.warning_amber_rounded;
      case AuditCheckStatus.failed:
        return Icons.error_outline;
    }
  }

  String _statusLabel(AuditCheckStatus status) {
    switch (status) {
      case AuditCheckStatus.ok:
        return 'OK';
      case AuditCheckStatus.fixed:
        return 'FIXED';
      case AuditCheckStatus.warning:
        return 'WARN';
      case AuditCheckStatus.failed:
        return 'FAIL';
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final currency = NumberFormat('#,##,##0');

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: Row(
        children: [
          const Icon(Icons.fact_check_outlined, color: AppColors.mediumGreen),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'System Audit & Ledger Reconcile',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: _running ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: _running
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Scanning ledgers, stock, and KPI engines…'),
                  ],
                ),
              )
            : _error != null
                ? Text('Audit failed: $_error',
                    style: const TextStyle(color: Color(0xFFA32D2D)))
                : report == null
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: report.allHealthy
                                    ? const Color(0xFFEDF7F1)
                                    : const Color(0xFFFFF6E8),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: report.allHealthy
                                      ? const Color(0xFFB7E4C7)
                                      : const Color(0xFFF0D5A0),
                                ),
                              ),
                              child: Text(
                                report.summaryLine,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            ...report.checks.map((check) {
                              final color = _statusColor(check.status);
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: const Color(0xFFE4EBE6),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(_statusIcon(check.status),
                                          color: color, size: 22),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    check.title,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 13.5,
                                                    ),
                                                  ),
                                                ),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 2,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: color
                                                        .withValues(alpha: 0.12),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      20,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    _statusLabel(check.status),
                                                    style: TextStyle(
                                                      color: color,
                                                      fontSize: 10.5,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              check.message,
                                              style: const TextStyle(
                                                fontSize: 12.5,
                                                color: Color(0xFF5C6B62),
                                                height: 1.35,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),
                            if (report.kpiSnapshots.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              const Text(
                                'KPI Snapshots',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final e in report.kpiSnapshots.entries)
                                    Chip(
                                      label: Text(
                                        '${e.key}: ₨ ${currency.format(e.value.round())}',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor:
                                          const Color(0xFFF3F7F4),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
      ),
      actions: [
        if (!_running) ...[
          TextButton(
            onPressed: () => _run(reconcile: false),
            child: const Text('Scan Only'),
          ),
          FilledButton.icon(
            onPressed: () => _run(reconcile: true),
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('Reconcile All Ledgers'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.mediumGreen,
            ),
          ),
        ],
      ],
    );
  }
}
