import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Structured logger for database migrations.
///
/// Every step is tagged so failures report the exact operation that broke.
class MigrationLog {
  MigrationLog(this.version, this.description);

  final int version;
  final String description;
  String? _step;

  String get stepLabel => _step ?? '(no step)';

  void step(String name) {
    _step = name;
    debugPrint('[migrate→v$version] STEP: $name');
  }

  void info(String message) {
    debugPrint('[migrate→v$version] $message');
  }

  void warn(String message) {
    debugPrint('[migrate→v$version] WARN: $message');
  }

  Never fail(Object error, [StackTrace? stackTrace]) {
    final msg =
        '[migrate→v$version] FAILED at step "$stepLabel" '
        '($description): $error';
    debugPrint(msg);
    if (stackTrace != null) debugPrint('$stackTrace');
    throw MigrationException(
      version: version,
      step: stepLabel,
      description: description,
      cause: error,
      stackTrace: stackTrace,
    );
  }
}

/// Thrown when a versioned migration fails; includes the failing step name.
class MigrationException implements Exception {
  MigrationException({
    required this.version,
    required this.step,
    required this.description,
    required this.cause,
    this.stackTrace,
  });

  final int version;
  final String step;
  final String description;
  final Object cause;
  final StackTrace? stackTrace;

  @override
  String toString() =>
      'MigrationException(v$version, step=$step, $description): $cause';
}

/// One incremental schema upgrade target (e.g. bring DB up to version 16).
class MigrationStep {
  const MigrationStep({
    required this.toVersion,
    required this.description,
    required this.run,
    this.managed = true,
    this.verifyIntegrity = true,
  });

  /// Schema version this step produces when complete.
  final int toVersion;

  final String description;

  /// Migration body. Prefer using [Database] so nested helpers keep working.
  final Future<void> Function(Database db, MigrationLog log) run;

  /// When `true` (default), the runner wraps the step in a SAVEPOINT and
  /// applies the FK guard (SOP). Prefer this for most migrations.
  ///
  /// Set `false` only when the migration owns its own transaction / FK
  /// lifecycle (e.g. large multi-table rebuilds like v26).
  final bool managed;

  /// Run `PRAGMA foreign_key_check` + quick integrity probe before commit.
  final bool verifyIntegrity;
}

/// Disables FK enforcement for structural surgery, then restores it.
///
/// SQLite ignores `PRAGMA foreign_keys` changes **while a transaction is
/// already open** (sqflite wraps `onUpgrade` in one). We therefore also set
/// `PRAGMA defer_foreign_keys = ON`, which *is* valid inside a transaction
/// and postpones FK validation until COMMIT — giving the same safety window
/// for DROP/RENAME/CREATE sequences.
///
/// Nested [enter]/[exit] pairs are reference-counted so an inner rebuild
/// helper cannot re-enable FKs while an outer migration still needs them off.
class ForeignKeyGuard {
  ForeignKeyGuard._(this._db);

  final Database _db;
  bool _active = false;

  static final Map<Database, int> _depthByDb = {};

  static Future<ForeignKeyGuard> enter(Database db) async {
    final guard = ForeignKeyGuard._(db);
    final depth = _depthByDb[db] ?? 0;
    if (depth == 0) {
      // Best-effort: effective only when no outer transaction is open.
      await db.execute('PRAGMA foreign_keys = OFF');
      // Always effective inside a transaction (onUpgrade case).
      await db.execute('PRAGMA defer_foreign_keys = ON');
    }
    _depthByDb[db] = depth + 1;
    guard._active = true;
    return guard;
  }

  Future<void> exit() async {
    if (!_active) return;
    _active = false;
    final depth = (_depthByDb[_db] ?? 1) - 1;
    if (depth > 0) {
      _depthByDb[_db] = depth;
      return;
    }
    _depthByDb.remove(_db);
    try {
      await _db.execute('PRAGMA defer_foreign_keys = OFF');
    } catch (e) {
      debugPrint('ForeignKeyGuard: defer_foreign_keys OFF failed: $e');
    }
    try {
      await _db.execute('PRAGMA foreign_keys = ON');
    } catch (e) {
      debugPrint('ForeignKeyGuard: foreign_keys ON failed: $e');
    }
  }
}

/// Runs incremental migrations sequentially with atomic rollback on failure.
class MigrationRunner {
  MigrationRunner(this.db);

  final Database db;

  /// Executes every [MigrationStep] whose [MigrationStep.toVersion] is greater
  /// than [oldVersion] and less than or equal to [newVersion], in ascending
  /// version order.
  Future<void> runSequential({
    required int oldVersion,
    required int newVersion,
    required List<MigrationStep> steps,
  }) async {
    final ordered = [...steps]..sort((a, b) => a.toVersion.compareTo(b.toVersion));

    debugPrint(
      'MigrationRunner: upgrading $oldVersion → $newVersion '
      '(${ordered.where((s) => s.toVersion > oldVersion && s.toVersion <= newVersion).length} steps)',
    );

    for (final step in ordered) {
      if (step.toVersion <= oldVersion) continue;
      if (step.toVersion > newVersion) break;

      final log = MigrationLog(step.toVersion, step.description);
      log.info('Starting: ${step.description}');

      try {
        if (step.managed) {
          await _runManaged(step, log);
        } else {
          await step.run(db, log);
          if (step.verifyIntegrity) {
            log.step('integrity_check');
            await verifyDatabaseIntegrity(db, log: log);
          }
        }
        log.info('Completed successfully');
      } on MigrationException {
        rethrow;
      } catch (e, st) {
        log.fail(e, st);
      }
    }
  }

  Future<void> _runManaged(MigrationStep step, MigrationLog log) async {
    // sqflite already wraps onUpgrade in a transaction. Nested
    // `db.transaction((txn) ...)` requires every helper to use [txn] or it
    // can self-deadlock. SAVEPOINTs give per-step atomicity while letting
    // existing helpers keep using [db].
    final savepoint = 'mig_v${step.toVersion}';
    final guard = await ForeignKeyGuard.enter(db);
    try {
      log.step('SAVEPOINT $savepoint');
      await db.execute('SAVEPOINT $savepoint');
      try {
        await step.run(db, log);

        if (step.verifyIntegrity) {
          log.step('integrity_check');
          await verifyDatabaseIntegrity(db, log: log);
        }

        log.step('RELEASE SAVEPOINT $savepoint');
        await db.execute('RELEASE SAVEPOINT $savepoint');
      } catch (e, st) {
        log.warn('Rolling back savepoint $savepoint');
        try {
          await db.execute('ROLLBACK TO SAVEPOINT $savepoint');
          await db.execute('RELEASE SAVEPOINT $savepoint');
        } catch (rollbackError) {
          debugPrint(
            'MigrationRunner: savepoint rollback failed: $rollbackError',
          );
        }
        if (e is MigrationException) rethrow;
        log.fail(e, st);
      }
    } finally {
      await guard.exit();
    }
  }
}

/// Known ledger / purchase sync trigger names used across AgriKhata.
const kLedgerSyncTriggerNames = <String>[
  'after_sale_insert',
  'after_sale_delete',
  'after_sale_update',
  'after_payment_insert',
  'after_payment_delete',
  'after_payment_update',
  'after_purchase_insert',
  'after_purchase_update',
  'after_purchase_delete',
  'after_wholesaler_payment_insert',
  'after_wholesaler_payment_delete',
];

/// Drops triggers by name (no-op if missing).
Future<void> dropTriggers(
  DatabaseExecutor db,
  Iterable<String> names, {
  MigrationLog? log,
}) async {
  for (final name in names) {
    log?.step('DROP TRIGGER IF EXISTS $name');
    await db.execute('DROP TRIGGER IF EXISTS $name');
  }
}

/// Drops indexes by name (no-op if missing).
Future<void> dropIndexes(
  DatabaseExecutor db,
  Iterable<String> names, {
  MigrationLog? log,
}) async {
  for (final name in names) {
    log?.step('DROP INDEX IF EXISTS $name');
    await db.execute('DROP INDEX IF EXISTS $name');
  }
}

/// Looks up all index names defined on [table] (excludes autoindexes).
Future<List<String>> indexesOnTable(DatabaseExecutor db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'index' "
    "AND tbl_name = ? AND name NOT LIKE 'sqlite_autoindex%' "
    "AND sql IS NOT NULL",
    [table],
  );
  return [
    for (final row in rows)
      if (row['name'] is String) row['name'] as String,
  ];
}

/// Looks up all trigger names defined on [table].
Future<List<String>> triggersOnTable(DatabaseExecutor db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?",
    [table],
  );
  return [
    for (final row in rows)
      if (row['name'] is String) row['name'] as String,
  ];
}

Future<bool> tableExists(DatabaseExecutor db, String table) async {
  final rows = await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') "
    'AND name = ? LIMIT 1',
    [table],
  );
  return rows.isNotEmpty;
}

Future<Set<String>> tableColumnNames(DatabaseExecutor db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {
    for (final row in info)
      if (row['name'] is String) row['name'] as String,
  };
}

/// Runs FK + quick integrity checks. Throws [MigrationException] on failure
/// when [log] is provided; otherwise throws a plain [StateError].
Future<void> verifyDatabaseIntegrity(
  DatabaseExecutor db, {
  MigrationLog? log,
  String? table,
}) async {
  final fkSql = table == null
      ? 'PRAGMA foreign_key_check'
      : 'PRAGMA foreign_key_check($table)';
  final fkViolations = await db.rawQuery(fkSql);
  if (fkViolations.isNotEmpty) {
    final detail = fkViolations.take(5).toList();
    final message =
        'foreign_key_check failed (${fkViolations.length} violation(s)): $detail';
    if (log != null) {
      log.fail(message);
    }
    throw StateError(message);
  }

  final integrity = await db.rawQuery('PRAGMA quick_check');
  final result = integrity.isEmpty ? null : integrity.first.values.first;
  if (result != null && result != 'ok') {
    final message = 'quick_check failed: $result';
    if (log != null) {
      log.fail(message);
    }
    throw StateError(message);
  }
}

/// Specification for the strict 6-step table swap (structural ALTER).
class TableSwapSpec {
  const TableSwapSpec({
    required this.tableName,
    required this.createNewTableSql,
    required this.copyColumns,
    this.selectExpressions,
    this.whereClause,
    this.dependentTriggers = const [],
    this.dependentIndexes = const [],
    this.discoverDependents = true,
    this.recreateIndexSql = const [],
    this.recreateTriggerSql = const [],
    this.verifyAfter = true,
    this.newTableSuffix = '_new',
  });

  /// Live table name (e.g. `payments`).
  final String tableName;

  /// Full `CREATE TABLE <table>_new (...)` statement. Must use
  /// `"$tableName$newTableSuffix"` as the new table identifier.
  final String createNewTableSql;

  /// Columns present in **both** old and new tables, listed explicitly for
  /// `INSERT INTO ... (cols) SELECT cols FROM ...` (never `SELECT *`).
  final List<String> copyColumns;

  /// Optional per-column SELECT expressions keyed by destination column.
  /// Columns omitted here are copied by name (`col`).
  final Map<String, String>? selectExpressions;

  /// Optional WHERE clause (without the `WHERE` keyword) applied to the copy.
  final String? whereClause;

  /// Triggers to drop before the swap (in addition to discovered ones).
  final List<String> dependentTriggers;

  /// Indexes to drop before the swap (in addition to discovered ones).
  final List<String> dependentIndexes;

  /// When true, also DROP any triggers/indexes found on [tableName] via
  /// `sqlite_master` before renaming.
  final bool discoverDependents;

  /// `CREATE INDEX ...` statements to run after rename (Step E).
  final List<String> recreateIndexSql;

  /// `CREATE TRIGGER ...` statements to run after rename (Step E).
  final List<String> recreateTriggerSql;

  /// Step F: run `PRAGMA foreign_key_check` / `quick_check` after rename.
  /// Disable when callers still need to purge orphans before a valid check.
  final bool verifyAfter;

  final String newTableSuffix;

  String get newTableName => '$tableName$newTableSuffix';
}

/// Executes the mandatory 6-step table swap pattern.
///
/// **A** Create temp new table → **B** Copy explicit columns → **C** Drop old →
/// **D** Rename → **E** Recreate indexes/triggers → **F** Verify integrity.
///
/// Callers should already be inside a [ForeignKeyGuard] / migration transaction.
Future<void> rebuildTableWithSwap(
  DatabaseExecutor db,
  TableSwapSpec spec, {
  MigrationLog? log,
}) async {
  void step(String name) {
    if (log != null) {
      log.step(name);
    } else {
      debugPrint('table-swap: $name');
    }
  }

  final table = spec.tableName;
  final newTable = spec.newTableName;

  if (!await tableExists(db, table)) {
    step('A.create_only (source missing)');
    // No live table — just materialize the new schema under the final name.
    final createFinal = spec.createNewTableSql.replaceFirst(newTable, table);
    await db.execute(createFinal);
    for (final sql in spec.recreateIndexSql) {
      await db.execute(sql);
    }
    for (final sql in spec.recreateTriggerSql) {
      await db.execute(sql);
    }
    return;
  }

  // --- Pre: dependents ---
  final triggers = <String>{...spec.dependentTriggers};
  final indexes = <String>{...spec.dependentIndexes};
  if (spec.discoverDependents) {
    triggers.addAll(await triggersOnTable(db, table));
    indexes.addAll(await indexesOnTable(db, table));
  }
  if (triggers.isNotEmpty) {
    step('pre.drop_triggers (${triggers.length})');
    await dropTriggers(db, triggers, log: log);
  }
  if (indexes.isNotEmpty) {
    step('pre.drop_indexes (${indexes.length})');
    await dropIndexes(db, indexes, log: log);
  }

  // --- Step A ---
  step('A.CREATE $newTable');
  await db.execute('DROP TABLE IF EXISTS $newTable');
  await db.execute(spec.createNewTableSql);

  // --- Step B ---
  final liveCols = await tableColumnNames(db, table);
  final derivedCols = spec.selectExpressions?.keys.toSet() ?? const <String>{};
  final effectiveCopyCols = [
    for (final c in spec.copyColumns)
      if (liveCols.contains(c) || derivedCols.contains(c)) c,
  ];
  if (effectiveCopyCols.length != spec.copyColumns.length) {
    final skipped = spec.copyColumns
        .where((c) => !liveCols.contains(c) && !derivedCols.contains(c))
        .toList();
    if (skipped.isNotEmpty) {
      log?.warn(
        'Skipping missing source columns during copy: $skipped',
      );
    }
  }

  if (effectiveCopyCols.isEmpty) {
    step('B.SKIP copy (no overlapping columns)');
  } else {
    final destCols = effectiveCopyCols.join(', ');
    final selectParts = effectiveCopyCols.map((col) {
      final expr = spec.selectExpressions?[col];
      if (expr != null) return expr;
      // Source column must exist if we didn't supply an expression.
      return col;
    }).join(', ');
    final where = spec.whereClause == null || spec.whereClause!.isEmpty
        ? ''
        : ' WHERE ${spec.whereClause}';
    step('B.INSERT INTO $newTable ($destCols) SELECT ... FROM $table');
    await db.execute(
      'INSERT INTO $newTable ($destCols) SELECT $selectParts FROM $table$where',
    );
  }

  // --- Step C ---
  step('C.DROP TABLE $table');
  await db.execute('DROP TABLE $table');

  // --- Step D ---
  step('D.ALTER TABLE $newTable RENAME TO $table');
  await db.execute('ALTER TABLE $newTable RENAME TO $table');

  // --- Step E ---
  for (var i = 0; i < spec.recreateIndexSql.length; i++) {
    step('E.recreate_index[$i]');
    await db.execute(spec.recreateIndexSql[i]);
  }
  for (var i = 0; i < spec.recreateTriggerSql.length; i++) {
    step('E.recreate_trigger[$i]');
    await db.execute(spec.recreateTriggerSql[i]);
  }

  // --- Step F ---
  if (spec.verifyAfter) {
    step('F.verify integrity ($table)');
    await verifyDatabaseIntegrity(db, log: log, table: table);
  } else {
    step('F.verify skipped (caller will verify later)');
  }
}

/// Convenience: ADD COLUMN if missing (idempotent). Logs and swallows
/// "duplicate column" errors so re-entrant upgrades are safe.
Future<void> addColumnIfMissing(
  DatabaseExecutor db, {
  required String table,
  required String column,
  required String columnDefSql,
  MigrationLog? log,
}) async {
  final cols = await tableColumnNames(db, table);
  if (cols.contains(column)) {
    log?.info('Column $table.$column already present — skip');
    return;
  }
  log?.step('ALTER TABLE $table ADD COLUMN $column');
  await db.execute('ALTER TABLE $table ADD COLUMN $columnDefSql');
}
