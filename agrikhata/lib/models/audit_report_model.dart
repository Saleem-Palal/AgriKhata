/// Structured result of a full-system ledger / KPI / stock audit.
enum AuditCheckStatus {
  ok,
  warning,
  fixed,
  failed,
}

class AuditCheckResult {
  final String id;
  final String title;
  final AuditCheckStatus status;
  final String message;
  final int discrepancyCount;

  const AuditCheckResult({
    required this.id,
    required this.title,
    required this.status,
    required this.message,
    this.discrepancyCount = 0,
  });

  bool get isHealthy =>
      status == AuditCheckStatus.ok || status == AuditCheckStatus.fixed;
}

class AuditReportModel {
  final DateTime ranAt;
  final bool reconciled;
  final List<AuditCheckResult> checks;
  final Map<String, double> kpiSnapshots;

  const AuditReportModel({
    required this.ranAt,
    required this.reconciled,
    required this.checks,
    this.kpiSnapshots = const {},
  });

  int get okCount =>
      checks.where((c) => c.status == AuditCheckStatus.ok).length;
  int get fixedCount =>
      checks.where((c) => c.status == AuditCheckStatus.fixed).length;
  int get warningCount =>
      checks.where((c) => c.status == AuditCheckStatus.warning).length;
  int get failedCount =>
      checks.where((c) => c.status == AuditCheckStatus.failed).length;

  bool get allHealthy => checks.every((c) => c.isHealthy);

  String get summaryLine {
    if (allHealthy && fixedCount == 0) {
      return 'All ledgers and KPI engines reconciled cleanly.';
    }
    if (fixedCount > 0 && failedCount == 0) {
      return 'Audit complete — $fixedCount issue(s) auto-fixed.';
    }
    return 'Audit finished with $warningCount warning(s), '
        '$failedCount failure(s), $fixedCount fix(es).';
  }
}
