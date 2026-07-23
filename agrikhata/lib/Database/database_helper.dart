import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../utils/season_utils.dart';
import 'migration_framework.dart';

/// Singleton database helper for the AgriKhata local relational database.
///
/// This file contains:
/// - a strongly typed schema definition via model classes and column constants
/// - table creation scripts
/// - CRUD helpers for all four tables
/// - business helpers for zamindar balances and product inventory status
/// - ChangeNotifier mixin for reactive UI updates
/// - versioned, atomic SQLite migrations (see [migration_framework.dart])
class DatabaseHelper with ChangeNotifier {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  /// Current on-disk schema version. Bump only when adding a new `_migrateToV*`.
  static const int schemaVersion = 28;

  static final NumberFormat _indianCurrencyFormat = NumberFormat('#,##,##0');

  static Database? _database;
  static Future<Database>? _databaseFuture;
  static bool _factoryInitialized = false;

  Future<Database> get database async {
    await _ensureDatabaseFactory();
    if (_database != null) return _database!;
    _databaseFuture ??= _initDatabase().then((db) async {
      _database = db;
      await _repairAdvancePaymentSeasons(db);
      return db;
    });
    try {
      return await _databaseFuture!;
    } catch (e) {
      _databaseFuture = null;
      rethrow;
    }
  }

  /// Closes the SQLite connection and clears caches so WAL/journal locks release.
  Future<void> close() async {
    try {
      final pending = _databaseFuture;
      if (pending != null) {
        final db = await pending;
        await db.close();
      } else {
        final db = _database;
        if (db != null) {
          await db.close();
        }
      }
    } catch (e, st) {
      debugPrint('DatabaseHelper.close failed: $e\n$st');
    } finally {
      _database = null;
      _databaseFuture = null;
    }
  }

  Future<Database> _initDatabase() async {
    // Use Application Support (writable under MSIX); getDatabasesPath() can
    // resolve inside the read-only package and cause SQLITE_CANTOPEN (14).
    final supportDir = await getApplicationSupportDirectory();
    await supportDir.create(recursive: true);
    final path = p.join(supportDir.path, 'agrikhata.db');

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute(_createZamindarsTable());
          await db.execute(_createKisaansTable());
          await db.execute(_createProductsTable());
          // sales/payments first — ledger_transactions FKs reference them.
          await db.execute(_createSalesTable());
          await db.execute(_createSaleItemsTable());
          await db.execute(_createPaymentsTable());
          await db.execute(_createLedgerTransactionsTable());
          await db.execute(_createPaymentSequencesTable());
          await db.execute(_createStockMovementsTable());
          await db.execute(_createWholesalersTable());
          await db.execute(_createPurchaseInvoicesTable());
          await db.execute(_createPurchaseItemsTable());
          await db.execute(_createWholesalerLedgerTable());
          await db.execute(_createWholesalerPaymentsTable());
          await db.execute(_createExpensesTable());
          await db.execute(_createEmployeesTable());
          await db.execute(_createEmployeeAttendanceTable());
          await _createIndexes(db);
          await _createLedgerSyncTriggers(db);
        },
        onOpen: (db) async {
          // Reinforce FK enforcement on every connection (Desktop FFI).
          await db.execute('PRAGMA foreign_keys = ON');
          await _ensureWholesalerLedgerSchema(db);
          await _ensureWholesalerPaymentsSchema(db);
          await _ensureExpensesSchema(db);
          await _ensureEmployeeSchema(db);
          await _ensureSalesAdvanceSchema(db);
          await _createLedgerSyncTriggers(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await _runSchemaMigrations(db, oldVersion, newVersion);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Schema migrations (incremental, atomic, data-preserving)
  // ---------------------------------------------------------------------------

  /// Sequential upgrade path. Each `_migrateToV*` is isolated; failures roll
  /// back via SAVEPOINT (managed steps) or the migration's own transaction.
  Future<void> _runSchemaMigrations(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    await MigrationRunner(db).runSequential(
      oldVersion: oldVersion,
      newVersion: newVersion,
      steps: [
        MigrationStep(
          toVersion: 3,
          description: 'zamindars village + is_draft columns',
          run: _migrateToV3,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 4,
          description: 'rebuild kisaans schema (preserve overlapping columns)',
          run: _migrateToV4,
        ),
        MigrationStep(
          toVersion: 5,
          description: 'products.seasonal_increment',
          run: _migrateToV5,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 6,
          description: 'rebuild products schema (preserve overlapping columns)',
          run: _migrateToV6,
        ),
        MigrationStep(
          toVersion: 7,
          description: 'products.product_type',
          run: _migrateToV7,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 8,
          description: 'zamindars.advance_balance',
          run: _migrateToV8,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 9,
          description: 'create sales / sale_items / payments',
          run: _migrateToV9,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 10,
          description: 'rebuild sales domain with season column',
          run: _migrateToV10,
        ),
        MigrationStep(
          toVersion: 11,
          description: 'ledger audit trail linkage columns',
          run: _migrateToV11,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 12,
          description: 'backfill ledger_transactions from sales',
          run: _migrateToV12,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 13,
          description: 'nullable payment invoice + advance backfill',
          run: _migrateToV13,
        ),
        MigrationStep(
          toVersion: 14,
          description: 'payment sequences + ghost payment cleanup',
          run: _migrateToV14,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 15,
          description: 'renumber legacy payment receipt IDs',
          run: _migrateToV15,
          // Owns FK pragma around payment id renames.
          managed: false,
        ),
        MigrationStep(
          toVersion: 16,
          description: 'sales.payment_term',
          run: _migrateToV16,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 17,
          description: 'stock_movements ledger',
          run: _migrateToV17,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 18,
          description: 'wholesalers + purchase invoices',
          run: _migrateToV18,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 19,
          description: 'wholesaler_ledger table',
          run: _migrateToV19,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 20,
          description: 'backfill wholesaler_ledger from purchases',
          run: _migrateToV20,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 21,
          description: 'wholesaler_payments table',
          run: _migrateToV21,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 22,
          description: 'purchase + wholesaler ledger description columns',
          run: _migrateToV22,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 23,
          description: 'expenses table',
          run: _migrateToV23,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 24,
          description: 'cascade invoice FKs + current_balance sync',
          run: _migrateToV24,
          // Table swaps inside manage their own FK pragma toggles.
          managed: false,
        ),
        MigrationStep(
          toVersion: 25,
          description: 'cash/fuel advance columns on sales',
          run: _migrateToV25,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 26,
          description: 'FK integrity, INTEGER money, ledger triggers',
          run: _migrateToV26,
          // Large multi-table rebuild; owns transaction + FK lifecycle.
          managed: false,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 27,
          description: 'full sales/purchase domain sync triggers',
          run: _migrateToV27,
        ),
        MigrationStep(
          toVersion: 28,
          description: 'employees + attendance + expense payroll link',
          run: _migrateToV28,
          verifyIntegrity: false,
        ),
      ],
    );
  }

  Future<void> _migrateToV3(Database db, MigrationLog log) async {
    await addColumnIfMissing(
      db,
      table: ZamindarTable.name,
      column: ZamindarTable.village,
      columnDefSql: '${ZamindarTable.village} TEXT',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: ZamindarTable.name,
      column: ZamindarTable.isDraft,
      columnDefSql: '${ZamindarTable.isDraft} INTEGER DEFAULT 0',
      log: log,
    );
  }

  Future<void> _migrateToV4(Database db, MigrationLog log) async {
    log.step('rebuild kisaans via 6-step swap');
    final oldCols = await tableExists(db, KisaanTable.name)
        ? await tableColumnNames(db, KisaanTable.name)
        : <String>{};
    const targetCols = [
      KisaanTable.id,
      KisaanTable.zamindarId,
      KisaanTable.nameColumn,
      KisaanTable.village,
      KisaanTable.phone,
      KisaanTable.landAcres,
      KisaanTable.currentCrop,
    ];
    final copyCols = [
      for (final c in targetCols)
        if (oldCols.contains(c)) c,
    ];

    final createNew = _createKisaansTable().replaceFirst(
      'CREATE TABLE IF NOT EXISTS ${KisaanTable.name}',
      'CREATE TABLE ${KisaanTable.name}_new',
    );

    await rebuildTableWithSwap(
      db,
      TableSwapSpec(
        tableName: KisaanTable.name,
        createNewTableSql: createNew,
        copyColumns: copyCols,
        recreateIndexSql: const [
          'CREATE INDEX IF NOT EXISTS idx_kisaans_zamindar_id '
              'ON kisaans(zamindar_id)',
        ],
      ),
      log: log,
    );
  }

  Future<void> _migrateToV5(Database db, MigrationLog log) async {
    await addColumnIfMissing(
      db,
      table: ProductTable.name,
      column: ProductTable.seasonalIncrement,
      columnDefSql: '${ProductTable.seasonalIncrement} INTEGER DEFAULT 0',
      log: log,
    );
  }

  Future<void> _migrateToV6(Database db, MigrationLog log) async {
    log.step('rebuild products via 6-step swap');
    final oldCols = await tableExists(db, ProductTable.name)
        ? await tableColumnNames(db, ProductTable.name)
        : <String>{};
    const targetCols = [
      ProductTable.id,
      ProductTable.nameColumn,
      ProductTable.brand,
      ProductTable.productType,
      ProductTable.packagingSize,
      ProductTable.costPrice,
      ProductTable.retailPrice,
      ProductTable.seasonalIncrement,
      ProductTable.availableStock,
      ProductTable.uom,
      ProductTable.expiryDate,
      ProductTable.lowStockThreshold,
      ProductTable.description,
    ];
    final copyCols = [
      for (final c in targetCols)
        if (oldCols.contains(c)) c,
    ];

    final createNew = _createProductsTable().replaceFirst(
      'CREATE TABLE IF NOT EXISTS ${ProductTable.name}',
      'CREATE TABLE ${ProductTable.name}_new',
    );

    await rebuildTableWithSwap(
      db,
      TableSwapSpec(
        tableName: ProductTable.name,
        createNewTableSql: createNew,
        copyColumns: copyCols,
      ),
      log: log,
    );
  }

  Future<void> _migrateToV7(Database db, MigrationLog log) async {
    await addColumnIfMissing(
      db,
      table: ProductTable.name,
      column: ProductTable.productType,
      columnDefSql: "${ProductTable.productType} TEXT DEFAULT 'Fertilizer'",
      log: log,
    );
  }

  Future<void> _migrateToV8(Database db, MigrationLog log) async {
    await addColumnIfMissing(
      db,
      table: ZamindarTable.name,
      column: ZamindarTable.advanceBalance,
      columnDefSql: '${ZamindarTable.advanceBalance} INTEGER DEFAULT 0',
      log: log,
    );
  }

  Future<void> _migrateToV9(Database db, MigrationLog log) async {
    log.step('CREATE sales / sale_items / payments');
    await db.execute(_createSalesTable());
    await db.execute(_createSaleItemsTable());
    await db.execute(_createPaymentsTable());
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sale_items_invoice
      ON sale_items(invoice_number)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_payments_invoice
      ON payments(invoice_number)
    ''');
  }

  Future<void> _migrateToV10(Database db, MigrationLog log) async {
    // Historical fix for incomplete v9 sales tables. Recreate the v10-era
    // shape (name-based parties + season). Do NOT jump to the modern id-based
    // schema here — later migrations (v13/v24/v26) expect transitional columns.
    await dropTriggers(db, kLedgerSyncTriggerNames, log: log);

    for (final table in [
      PaymentsTable.name,
      SaleItemsTable.name,
      SalesTable.name,
    ]) {
      if (await tableExists(db, table)) {
        await dropTriggers(db, await triggersOnTable(db, table), log: log);
        await dropIndexes(db, await indexesOnTable(db, table), log: log);
      }
    }

    log.step('DROP incomplete v9 sales domain tables');
    await db.execute('DROP TABLE IF EXISTS ${PaymentsTable.name}');
    await db.execute('DROP TABLE IF EXISTS ${SaleItemsTable.name}');
    await db.execute('DROP TABLE IF EXISTS ${SalesTable.name}');

    log.step('CREATE v10 sales domain (season + name columns)');
    await db.execute('''
      CREATE TABLE ${SalesTable.name} (
        ${SalesTable.invoiceNumber} TEXT PRIMARY KEY,
        ${SalesTable.dateTime} TEXT NOT NULL,
        ${SalesTable.zamindarName} TEXT NOT NULL,
        ${SalesTable.kisaanName} TEXT,
        ${SalesTable.subtotal} REAL NOT NULL,
        ${SalesTable.itemDiscountsTotal} REAL NOT NULL DEFAULT 0,
        ${SalesTable.seasonalIncrementTotal} REAL NOT NULL DEFAULT 0,
        ${SalesTable.overallDiscount} REAL NOT NULL DEFAULT 0,
        ${SalesTable.totalPayable} REAL NOT NULL,
        ${SalesTable.paidAmount} REAL NOT NULL DEFAULT 0,
        ${SalesTable.paymentMethod} TEXT NOT NULL,
        ${SalesTable.season} TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE ${SaleItemsTable.name} (
        ${SaleItemsTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
        ${SaleItemsTable.invoiceNumber} TEXT NOT NULL,
        ${SaleItemsTable.productName} TEXT NOT NULL,
        ${SaleItemsTable.productType} TEXT NOT NULL,
        ${SaleItemsTable.quantity} REAL NOT NULL,
        ${SaleItemsTable.unitPrice} REAL NOT NULL,
        ${SaleItemsTable.seasonalIncrement} REAL NOT NULL DEFAULT 0,
        ${SaleItemsTable.itemDiscount} REAL NOT NULL DEFAULT 0,
        ${SaleItemsTable.subtotal} REAL NOT NULL,
        FOREIGN KEY (${SaleItemsTable.invoiceNumber})
          REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE ${PaymentsTable.name} (
        ${PaymentsTable.paymentId} TEXT PRIMARY KEY,
        ${PaymentsTable.invoiceNumber} TEXT NOT NULL,
        ${PaymentsTable.dateTime} TEXT NOT NULL,
        ${PaymentsTable.zamindarName} TEXT NOT NULL,
        ${PaymentsTable.kisaanName} TEXT,
        ${PaymentsTable.amountPaid} REAL NOT NULL,
        ${PaymentsTable.paymentMethod} TEXT NOT NULL,
        ${PaymentsTable.season} TEXT NOT NULL,
        FOREIGN KEY (${PaymentsTable.invoiceNumber})
          REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sale_items_invoice
      ON sale_items(invoice_number)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_payments_invoice
      ON payments(invoice_number)
    ''');
  }

  Future<void> _migrateToV11(Database db, MigrationLog log) async {
    await addColumnIfMissing(
      db,
      table: LedgerTransactionTable.name,
      column: LedgerTransactionTable.invoiceNumber,
      columnDefSql: '${LedgerTransactionTable.invoiceNumber} TEXT',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: LedgerTransactionTable.name,
      column: LedgerTransactionTable.paymentId,
      columnDefSql: '${LedgerTransactionTable.paymentId} TEXT',
      log: log,
    );
  }

  Future<void> _migrateToV12(Database db, MigrationLog log) async {
    log.step('backfill ledger from sales');
    await _backfillLedgerFromSales(db);
  }

  Future<void> _migrateToV13(Database db, MigrationLog log) async {
    log.step('nullable payment invoice');
    await _migratePaymentsTableNullableInvoice(db, log: log);
    log.step('backfill advance payments');
    await _backfillAdvancePayments(db);
  }

  Future<void> _migrateToV14(Database db, MigrationLog log) async {
    log.step('create payment_sequences');
    await db.execute(_createPaymentSequencesTable());
    log.step('seed payment sequences');
    await _seedPaymentSequences(db);
    log.step('cleanup ghost advance payments');
    await _cleanupGhostAdvancePayments(db);
    log.step('normalize wallet deduction category');
    await db.update(
      LedgerTransactionTable.name,
      {LedgerTransactionTable.category: 'WALLET_DEDUCTION'},
      where:
          '${LedgerTransactionTable.category} = ? AND ${LedgerTransactionTable.description} = ?',
      whereArgs: ['ADVANCE_PAYMENT', 'Advance wallet deduction'],
    );
  }

  Future<void> _migrateToV15(Database db, MigrationLog log) async {
    log.step('ensure payment_sequences');
    await db.execute(_createPaymentSequencesTable());
    log.step('renumber legacy payment ids');
    await _renumberLegacyPaymentIds(db);
    log.step('integrity_check');
    await verifyDatabaseIntegrity(db, log: log);
  }

  Future<void> _migrateToV16(Database db, MigrationLog log) async {
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.paymentTerm,
      columnDefSql: '${SalesTable.paymentTerm} TEXT',
      log: log,
    );
  }

  Future<void> _migrateToV17(Database db, MigrationLog log) async {
    log.step('create stock_movements');
    await db.execute(_createStockMovementsTable());
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_stock_movements_product
      ON ${StockMovementTable.name}(${StockMovementTable.productId})
    ''');
    log.step('backfill stock movements from sales');
    await _backfillStockMovementsFromSales(db);
  }

  Future<void> _migrateToV18(Database db, MigrationLog log) async {
    log.step('create wholesalers + purchases');
    await db.execute(_createWholesalersTable());
    await db.execute(_createPurchaseInvoicesTable());
    await db.execute(_createPurchaseItemsTable());
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_purchase_items_invoice
      ON ${PurchaseItemsTable.name}(${PurchaseItemsTable.invoiceNumber})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_wholesalers_name
      ON ${WholesalerTable.name}(${WholesalerTable.nameColumn})
    ''');
  }

  Future<void> _migrateToV19(Database db, MigrationLog log) async {
    log.step('create wholesaler_ledger');
    await db.execute(_createWholesalerLedgerTable());
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_wholesaler_ledger_wholesaler
      ON ${WholesalerLedgerTable.name}(${WholesalerLedgerTable.wholesalerId})
    ''');
  }

  Future<void> _migrateToV20(Database db, MigrationLog log) async {
    log.step('ensure + backfill wholesaler_ledger');
    await _ensureWholesalerLedgerSchema(db);
  }

  Future<void> _migrateToV21(Database db, MigrationLog log) async {
    log.step('ensure wholesaler_payments');
    await _ensureWholesalerPaymentsSchema(db);
  }

  Future<void> _migrateToV22(Database db, MigrationLog log) async {
    await addColumnIfMissing(
      db,
      table: PurchaseInvoicesTable.name,
      column: PurchaseInvoicesTable.description,
      columnDefSql: '${PurchaseInvoicesTable.description} TEXT',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: WholesalerLedgerTable.name,
      column: WholesalerLedgerTable.description,
      columnDefSql: '${WholesalerLedgerTable.description} TEXT',
      log: log,
    );
  }

  Future<void> _migrateToV23(Database db, MigrationLog log) async {
    log.step('ensure expenses schema');
    await _ensureExpensesSchema(db);
  }

  Future<void> _migrateToV24(Database db, MigrationLog log) async {
    log.step('invoice integrity cascade + balance sync');
    await _migrateInvoiceIntegrityV24(db, log: log);
    log.step('integrity_check');
    await verifyDatabaseIntegrity(db, log: log);
  }

  Future<void> _migrateToV25(Database db, MigrationLog log) async {
    log.step('ensure sales advance columns');
    await _ensureSalesAdvanceSchema(db);
  }

  Future<void> _migrateToV26(Database db, MigrationLog log) async {
    log.step('schema integrity refactor');
    await _migrateSchemaIntegrityV26(db, log: log);
    log.step('integrity_check');
    await verifyDatabaseIntegrity(db, log: log);
  }

  Future<void> _migrateToV27(Database db, MigrationLog log) async {
    log.step('recreate ledger sync triggers');
    await _createLedgerSyncTriggers(db);
  }

  Future<void> _migrateToV28(Database db, MigrationLog log) async {
    log.step('ensure employee + attendance schema');
    await _ensureEmployeeSchema(db);
  }

  /// v24: cascade ledger/payments on invoice delete, add cached current_balance,
  /// purge orphaned ledger rows, and recalculate every zamindar balance.
  Future<void> _migrateInvoiceIntegrityV24(
    Database db, {
    MigrationLog? log,
  }) async {
    await addColumnIfMissing(
      db,
      table: ZamindarTable.name,
      column: ZamindarTable.currentBalance,
      columnDefSql:
          '${ZamindarTable.currentBalance} INTEGER NOT NULL DEFAULT 0',
      log: log,
    );

    await _rebuildLedgerTransactionsWithInvoiceCascade(db, log: log);
    await _rebuildPaymentsWithInvoiceCascade(db, log: log);

    // Orphan SALE/payment ledger rows left behind by the old ON DELETE SET NULL.
    log?.step('purge orphan ledger/payment rows');
    await db.rawDelete('''
      DELETE FROM ${LedgerTransactionTable.name}
      WHERE ${LedgerTransactionTable.invoiceNumber} IS NOT NULL
        AND TRIM(${LedgerTransactionTable.invoiceNumber}) != ''
        AND ${LedgerTransactionTable.invoiceNumber} NOT IN (
          SELECT ${SalesTable.invoiceNumber} FROM ${SalesTable.name}
        )
    ''');
    await db.rawDelete('''
      DELETE FROM ${LedgerTransactionTable.name}
      WHERE (${LedgerTransactionTable.invoiceNumber} IS NULL
             OR TRIM(${LedgerTransactionTable.invoiceNumber}) = '')
        AND UPPER(${LedgerTransactionTable.category}) IN (
          'SALE', 'CASH_PAYMENT', 'WALLET_DEDUCTION', 'PAYMENT'
        )
    ''');
    await db.rawDelete('''
      DELETE FROM ${PaymentsTable.name}
      WHERE ${PaymentsTable.invoiceNumber} IS NOT NULL
        AND TRIM(${PaymentsTable.invoiceNumber}) != ''
        AND ${PaymentsTable.invoiceNumber} NOT IN (
          SELECT ${SalesTable.invoiceNumber} FROM ${SalesTable.name}
        )
    ''');

    log?.step('backfill ledger + recalculate balances');
    await _backfillLedgerFromSales(db);
    await _recalculateAllZamindarBalances(db);
  }

  /// v26 Schema Integrity Refactor:
  /// TEMP-stage live transactional data → rebuild INTEGER/FK tables →
  /// name→id mapping with ROUND money → fresh ledger triggers → balance sweep.
  ///
  /// FK pragma is toggled via [ForeignKeyGuard] (also enables
  /// `defer_foreign_keys` because sqflite's onUpgrade transaction makes
  /// `PRAGMA foreign_keys` changes a no-op).
  Future<void> _migrateSchemaIntegrityV26(
    Database db, {
    MigrationLog? log,
  }) async {
    const stageSales = '_mig26_sales';
    const stageSaleItems = '_mig26_sale_items';
    const stagePayments = '_mig26_payments';
    const stageLedger = '_mig26_ledger';
    const stagePurchases = '_mig26_purchase_invoices';
    const stagePurchaseItems = '_mig26_purchase_items';
    const stageWhLedger = '_mig26_wholesaler_ledger';
    const stageWhPayments = '_mig26_wholesaler_payments';

    String roundInt(String expr) =>
        'CAST(ROUND(COALESCE($expr, 0)) AS INTEGER)';

    String colOrDefault(Set<String> cols, String tableAlias, String column,
        String sqlDefault) {
      if (!cols.contains(column)) return sqlDefault;
      return '$tableAlias.$column';
    }

    String moneyOrZero(Set<String> cols, String tableAlias, String column) {
      if (!cols.contains(column)) return '0';
      return roundInt('$tableAlias.$column');
    }

    log?.step('drop domain triggers');
    await dropTriggers(db, kLedgerSyncTriggerNames, log: log);

    final guard = await ForeignKeyGuard.enter(db);
    try {
      await db.transaction((txn) async {
        // ---------------------------------------------------------------
        // 1) TEMPORARILY BACK UP LIVE TRANSACTION DATA
        // ---------------------------------------------------------------
        Future<void> stageTable(String stage, String source) async {
          await txn.execute('DROP TABLE IF EXISTS $stage');
          if (await _tableExists(txn, source)) {
            await txn.execute(
              'CREATE TEMP TABLE $stage AS SELECT * FROM $source',
            );
            final countRow =
                await txn.rawQuery('SELECT COUNT(*) AS c FROM $stage');
            final count = (countRow.first['c'] as num?)?.toInt() ?? 0;
            log?.info('staged $source → $stage ($count rows)');
          } else {
            // Empty shell so later INSERTs are no-ops instead of hard failures.
            await txn.execute('CREATE TEMP TABLE $stage (id INTEGER)');
            log?.info('$source missing — empty stage $stage');
          }
        }

        await stageTable(stageSales, SalesTable.name);
        await stageTable(stageSaleItems, SaleItemsTable.name);
        await stageTable(stagePayments, PaymentsTable.name);
        await stageTable(stageLedger, LedgerTransactionTable.name);
        await stageTable(stagePurchases, PurchaseInvoicesTable.name);
        await stageTable(stagePurchaseItems, PurchaseItemsTable.name);
        await stageTable(stageWhLedger, WholesalerLedgerTable.name);
        await stageTable(stageWhPayments, WholesalerPaymentsTable.name);

        final salesCols = await _tableColumnNames(txn, stageSales);
        final paymentCols = await _tableColumnNames(txn, stagePayments);
        final saleItemCols = await _tableColumnNames(txn, stageSaleItems);
        final purchaseCols = await _tableColumnNames(txn, stagePurchases);
        final purchaseItemCols =
            await _tableColumnNames(txn, stagePurchaseItems);
        final whLedgerCols = await _tableColumnNames(txn, stageWhLedger);
        final whPaymentCols = await _tableColumnNames(txn, stageWhPayments);

        // ---------------------------------------------------------------
        // 2) DROP OLD TABLES + REBUILD VERSION 26 LAYOUT
        // ---------------------------------------------------------------
        // Child → parent order (FK pragma is OFF, but keep dependencies sane).
        log?.step('drop + recreate transactional tables');
        await txn.execute('DROP TABLE IF EXISTS ${SaleItemsTable.name}');
        await txn.execute('DROP TABLE IF EXISTS ${LedgerTransactionTable.name}');
        await txn.execute('DROP TABLE IF EXISTS ${PaymentsTable.name}');
        await txn.execute('DROP TABLE IF EXISTS ${SalesTable.name}');
        await txn.execute('DROP TABLE IF EXISTS ${PurchaseItemsTable.name}');
        await txn.execute('DROP TABLE IF EXISTS ${PurchaseInvoicesTable.name}');
        await txn.execute('DROP TABLE IF EXISTS ${WholesalerLedgerTable.name}');
        await txn.execute('DROP TABLE IF EXISTS ${WholesalerPaymentsTable.name}');

        await txn.execute(_createSalesTable());
        await txn.execute(_createSaleItemsTable());
        await txn.execute(_createPaymentsTable());
        await txn.execute(_createLedgerTransactionsTable());
        await txn.execute(_createPurchaseInvoicesTable());
        await txn.execute(_createPurchaseItemsTable());
        await txn.execute(_createWholesalerLedgerTable());
        await txn.execute(_createWholesalerPaymentsTable());

        // ---------------------------------------------------------------
        // 3) SAFE DATA MAPPING & ROUNDING CONVERSION
        // ---------------------------------------------------------------
        log?.step('map staged data into new schema');

        // --- sales: name strings → zamindar_id / kisaan_id, REAL → INTEGER ---
        if (salesCols.contains(SalesTable.invoiceNumber)) {
          final resolvedZamindarId = () {
            final hasId = salesCols.contains(SalesTable.zamindarId);
            final hasName = salesCols.contains(SalesTable.zamindarName);
            if (hasId && hasName) {
              return '''
                COALESCE(
                  s.${SalesTable.zamindarId},
                  (SELECT z.${ZamindarTable.id} FROM ${ZamindarTable.name} z
                   WHERE z.${ZamindarTable.nameColumn} = TRIM(s.${SalesTable.zamindarName})
                   LIMIT 1)
                )''';
            }
            if (hasId) return 's.${SalesTable.zamindarId}';
            if (hasName) {
              return '''
                (SELECT z.${ZamindarTable.id} FROM ${ZamindarTable.name} z
                 WHERE z.${ZamindarTable.nameColumn} = TRIM(s.${SalesTable.zamindarName})
                 LIMIT 1)''';
            }
            return 'NULL';
          }();

          final resolvedKisaanId = () {
            final hasId = salesCols.contains(SalesTable.kisaanId);
            final hasName = salesCols.contains(SalesTable.kisaanName);
            final zamindarForKisaan = resolvedZamindarId;
            if (hasId && hasName) {
              return '''
                COALESCE(
                  s.${SalesTable.kisaanId},
                  (SELECT k.${KisaanTable.id} FROM ${KisaanTable.name} k
                   WHERE k.${KisaanTable.nameColumn} = TRIM(s.${SalesTable.kisaanName})
                     AND k.${KisaanTable.zamindarId} = $zamindarForKisaan
                   LIMIT 1)
                )''';
            }
            if (hasId) return 's.${SalesTable.kisaanId}';
            if (hasName) {
              return '''
                (SELECT k.${KisaanTable.id} FROM ${KisaanTable.name} k
                 WHERE k.${KisaanTable.nameColumn} = TRIM(s.${SalesTable.kisaanName})
                   AND k.${KisaanTable.zamindarId} = $zamindarForKisaan
                 LIMIT 1)''';
            }
            return 'NULL';
          }();

          await txn.execute('''
            INSERT INTO ${SalesTable.name} (
              ${SalesTable.invoiceNumber}, ${SalesTable.dateTime},
              ${SalesTable.subtotal}, ${SalesTable.itemDiscountsTotal},
              ${SalesTable.seasonalIncrementTotal}, ${SalesTable.overallDiscount},
              ${SalesTable.totalPayable}, ${SalesTable.paidAmount},
              ${SalesTable.paymentMethod}, ${SalesTable.season},
              ${SalesTable.paymentTerm}, ${SalesTable.transactionType},
              ${SalesTable.creditAmount}, ${SalesTable.fuelQuantity},
              ${SalesTable.remarks}, ${SalesTable.zamindarId}, ${SalesTable.kisaanId}
            )
            SELECT
              s.${SalesTable.invoiceNumber},
              s.${SalesTable.dateTime},
              ${moneyOrZero(salesCols, 's', SalesTable.subtotal)},
              ${moneyOrZero(salesCols, 's', SalesTable.itemDiscountsTotal)},
              ${moneyOrZero(salesCols, 's', SalesTable.seasonalIncrementTotal)},
              ${moneyOrZero(salesCols, 's', SalesTable.overallDiscount)},
              ${moneyOrZero(salesCols, 's', SalesTable.totalPayable)},
              ${moneyOrZero(salesCols, 's', SalesTable.paidAmount)},
              ${colOrDefault(salesCols, 's', SalesTable.paymentMethod, "'Cash'")},
              ${colOrDefault(salesCols, 's', SalesTable.season, "'Unknown'")},
              ${colOrDefault(salesCols, 's', SalesTable.paymentTerm, 'NULL')},
              COALESCE(
                ${colOrDefault(salesCols, 's', SalesTable.transactionType, 'NULL')},
                '${SaleTransactionType.productSale}'
              ),
              ${moneyOrZero(salesCols, 's', SalesTable.creditAmount)},
              ${colOrDefault(salesCols, 's', SalesTable.fuelQuantity, 'NULL')},
              ${colOrDefault(salesCols, 's', SalesTable.remarks, 'NULL')},
              $resolvedZamindarId,
              $resolvedKisaanId
            FROM $stageSales s
            WHERE s.${SalesTable.invoiceNumber} IS NOT NULL
              AND TRIM(s.${SalesTable.invoiceNumber}) != ''
          ''');
        }

        // --- sale_items ---
        if (saleItemCols.contains(SaleItemsTable.invoiceNumber)) {
          await txn.execute('''
            INSERT INTO ${SaleItemsTable.name} (
              ${SaleItemsTable.id}, ${SaleItemsTable.invoiceNumber},
              ${SaleItemsTable.productName}, ${SaleItemsTable.productType},
              ${SaleItemsTable.quantity}, ${SaleItemsTable.unitPrice},
              ${SaleItemsTable.seasonalIncrement}, ${SaleItemsTable.itemDiscount},
              ${SaleItemsTable.subtotal}
            )
            SELECT
              ${colOrDefault(saleItemCols, 'si', SaleItemsTable.id, 'NULL')},
              si.${SaleItemsTable.invoiceNumber},
              ${colOrDefault(saleItemCols, 'si', SaleItemsTable.productName, "''")},
              ${colOrDefault(saleItemCols, 'si', SaleItemsTable.productType, "'Fertilizer'")},
              CAST(ROUND(COALESCE(
                ${colOrDefault(saleItemCols, 'si', SaleItemsTable.quantity, '0')}, 0
              )) AS INTEGER),
              ${moneyOrZero(saleItemCols, 'si', SaleItemsTable.unitPrice)},
              ${moneyOrZero(saleItemCols, 'si', SaleItemsTable.seasonalIncrement)},
              ${moneyOrZero(saleItemCols, 'si', SaleItemsTable.itemDiscount)},
              ${moneyOrZero(saleItemCols, 'si', SaleItemsTable.subtotal)}
            FROM $stageSaleItems si
            WHERE si.${SaleItemsTable.invoiceNumber} IN (
              SELECT ${SalesTable.invoiceNumber} FROM ${SalesTable.name}
            )
          ''');
        }

        // --- payments: name strings → ids, amount_paid REAL → INTEGER ---
        if (paymentCols.contains(PaymentsTable.paymentId)) {
          final payZamindarId = () {
            final hasId = paymentCols.contains(PaymentsTable.zamindarId);
            final hasName = paymentCols.contains(PaymentsTable.zamindarName);
            final fromName = hasName
                ? '''
                  (SELECT z.${ZamindarTable.id} FROM ${ZamindarTable.name} z
                   WHERE z.${ZamindarTable.nameColumn} = TRIM(p.${PaymentsTable.zamindarName})
                   LIMIT 1)'''
                : 'NULL';
            final fromSale = '''
              (SELECT s.${SalesTable.zamindarId} FROM ${SalesTable.name} s
               WHERE s.${SalesTable.invoiceNumber} = p.${PaymentsTable.invoiceNumber}
               LIMIT 1)''';
            if (hasId) {
              return 'COALESCE(p.${PaymentsTable.zamindarId}, $fromName, $fromSale)';
            }
            return 'COALESCE($fromName, $fromSale)';
          }();

          final payKisaanId = () {
            final hasId = paymentCols.contains(PaymentsTable.kisaanId);
            final hasName = paymentCols.contains(PaymentsTable.kisaanName);
            final fromName = hasName
                ? '''
                  (SELECT k.${KisaanTable.id} FROM ${KisaanTable.name} k
                   WHERE k.${KisaanTable.nameColumn} = TRIM(p.${PaymentsTable.kisaanName})
                     AND k.${KisaanTable.zamindarId} = $payZamindarId
                   LIMIT 1)'''
                : 'NULL';
            final fromSale = '''
              (SELECT s.${SalesTable.kisaanId} FROM ${SalesTable.name} s
               WHERE s.${SalesTable.invoiceNumber} = p.${PaymentsTable.invoiceNumber}
               LIMIT 1)''';
            if (hasId) {
              return 'COALESCE(p.${PaymentsTable.kisaanId}, $fromName, $fromSale)';
            }
            return 'COALESCE($fromName, $fromSale)';
          }();

          await txn.execute('''
            INSERT INTO ${PaymentsTable.name} (
              ${PaymentsTable.paymentId}, ${PaymentsTable.invoiceNumber},
              ${PaymentsTable.dateTime}, ${PaymentsTable.zamindarId},
              ${PaymentsTable.kisaanId}, ${PaymentsTable.amountPaid},
              ${PaymentsTable.paymentMethod}, ${PaymentsTable.season}
            )
            SELECT
              p.${PaymentsTable.paymentId},
              p.${PaymentsTable.invoiceNumber},
              p.${PaymentsTable.dateTime},
              $payZamindarId,
              $payKisaanId,
              ${moneyOrZero(paymentCols, 'p', PaymentsTable.amountPaid)},
              ${colOrDefault(paymentCols, 'p', PaymentsTable.paymentMethod, "'Cash'")},
              ${colOrDefault(paymentCols, 'p', PaymentsTable.season, "'Unknown'")}
            FROM $stagePayments p
            WHERE p.${PaymentsTable.paymentId} IS NOT NULL
              AND TRIM(p.${PaymentsTable.paymentId}) != ''
              AND (
                p.${PaymentsTable.invoiceNumber} IS NULL
                OR TRIM(p.${PaymentsTable.invoiceNumber}) = ''
                OR p.${PaymentsTable.invoiceNumber} IN (
                  SELECT ${SalesTable.invoiceNumber} FROM ${SalesTable.name}
                )
              )
          ''');
        }

        // Ledger is staged for safety but rebuilt empty here; the post-txn
        // trigger sweep regenerates the stream under v26 rules.
        // (stageLedger retained until end of transaction for crash forensics.)

        // --- purchase_invoices ---
        if (purchaseCols.contains(PurchaseInvoicesTable.invoiceNumber)) {
          await txn.execute('''
            INSERT INTO ${PurchaseInvoicesTable.name} (
              ${PurchaseInvoicesTable.invoiceNumber},
              ${PurchaseInvoicesTable.wholesalerId},
              ${PurchaseInvoicesTable.dateTime},
              ${PurchaseInvoicesTable.subtotal},
              ${PurchaseInvoicesTable.transportCharges},
              ${PurchaseInvoicesTable.grandTotal},
              ${PurchaseInvoicesTable.paymentType},
              ${PurchaseInvoicesTable.amountPaid},
              ${PurchaseInvoicesTable.outstanding},
              ${PurchaseInvoicesTable.description}
            )
            SELECT
              pi.${PurchaseInvoicesTable.invoiceNumber},
              pi.${PurchaseInvoicesTable.wholesalerId},
              pi.${PurchaseInvoicesTable.dateTime},
              ${moneyOrZero(purchaseCols, 'pi', PurchaseInvoicesTable.subtotal)},
              ${moneyOrZero(purchaseCols, 'pi', PurchaseInvoicesTable.transportCharges)},
              ${moneyOrZero(purchaseCols, 'pi', PurchaseInvoicesTable.grandTotal)},
              ${colOrDefault(purchaseCols, 'pi', PurchaseInvoicesTable.paymentType, "'Cash'")},
              ${moneyOrZero(purchaseCols, 'pi', PurchaseInvoicesTable.amountPaid)},
              ${moneyOrZero(purchaseCols, 'pi', PurchaseInvoicesTable.outstanding)},
              ${colOrDefault(purchaseCols, 'pi', PurchaseInvoicesTable.description, 'NULL')}
            FROM $stagePurchases pi
            WHERE pi.${PurchaseInvoicesTable.invoiceNumber} IS NOT NULL
              AND TRIM(pi.${PurchaseInvoicesTable.invoiceNumber}) != ''
          ''');
        }

        // --- purchase_items ---
        if (purchaseItemCols.contains(PurchaseItemsTable.invoiceNumber)) {
          await txn.execute('''
            INSERT INTO ${PurchaseItemsTable.name} (
              ${PurchaseItemsTable.id}, ${PurchaseItemsTable.invoiceNumber},
              ${PurchaseItemsTable.productId}, ${PurchaseItemsTable.productName},
              ${PurchaseItemsTable.quantity}, ${PurchaseItemsTable.purchaseRate},
              ${PurchaseItemsTable.expiryDate}, ${PurchaseItemsTable.lineTotal}
            )
            SELECT
              ${colOrDefault(purchaseItemCols, 'pii', PurchaseItemsTable.id, 'NULL')},
              pii.${PurchaseItemsTable.invoiceNumber},
              ${colOrDefault(purchaseItemCols, 'pii', PurchaseItemsTable.productId, 'NULL')},
              ${colOrDefault(purchaseItemCols, 'pii', PurchaseItemsTable.productName, "''")},
              CAST(ROUND(COALESCE(
                ${colOrDefault(purchaseItemCols, 'pii', PurchaseItemsTable.quantity, '0')}, 0
              )) AS INTEGER),
              ${moneyOrZero(purchaseItemCols, 'pii', PurchaseItemsTable.purchaseRate)},
              ${colOrDefault(purchaseItemCols, 'pii', PurchaseItemsTable.expiryDate, 'NULL')},
              ${moneyOrZero(purchaseItemCols, 'pii', PurchaseItemsTable.lineTotal)}
            FROM $stagePurchaseItems pii
            WHERE pii.${PurchaseItemsTable.invoiceNumber} IN (
              SELECT ${PurchaseInvoicesTable.invoiceNumber}
              FROM ${PurchaseInvoicesTable.name}
            )
          ''');
        }

        // --- wholesaler_ledger (drop denormalized running_balance) ---
        if (whLedgerCols.contains(WholesalerLedgerTable.wholesalerId)) {
          await txn.execute('''
            INSERT INTO ${WholesalerLedgerTable.name} (
              ${WholesalerLedgerTable.id},
              ${WholesalerLedgerTable.wholesalerId},
              ${WholesalerLedgerTable.transactionType},
              ${WholesalerLedgerTable.referenceId},
              ${WholesalerLedgerTable.date},
              ${WholesalerLedgerTable.debit},
              ${WholesalerLedgerTable.credit},
              ${WholesalerLedgerTable.description}
            )
            SELECT
              ${colOrDefault(whLedgerCols, 'wl', WholesalerLedgerTable.id, 'NULL')},
              wl.${WholesalerLedgerTable.wholesalerId},
              ${colOrDefault(whLedgerCols, 'wl', WholesalerLedgerTable.transactionType, "'Purchase'")},
              ${colOrDefault(whLedgerCols, 'wl', WholesalerLedgerTable.referenceId, 'NULL')},
              ${colOrDefault(whLedgerCols, 'wl', WholesalerLedgerTable.date, "datetime('now')")},
              ${moneyOrZero(whLedgerCols, 'wl', WholesalerLedgerTable.debit)},
              ${moneyOrZero(whLedgerCols, 'wl', WholesalerLedgerTable.credit)},
              ${colOrDefault(whLedgerCols, 'wl', WholesalerLedgerTable.description, 'NULL')}
            FROM $stageWhLedger wl
          ''');
        }

        // --- wholesaler_payments ---
        if (whPaymentCols.contains(WholesalerPaymentsTable.wholesalerId)) {
          await txn.execute('''
            INSERT INTO ${WholesalerPaymentsTable.name} (
              ${WholesalerPaymentsTable.id},
              ${WholesalerPaymentsTable.wholesalerId},
              ${WholesalerPaymentsTable.amount},
              ${WholesalerPaymentsTable.paymentMethod},
              ${WholesalerPaymentsTable.paymentSource},
              ${WholesalerPaymentsTable.referenceNo},
              ${WholesalerPaymentsTable.date},
              ${WholesalerPaymentsTable.notes}
            )
            SELECT
              ${colOrDefault(whPaymentCols, 'wp', WholesalerPaymentsTable.id, 'NULL')},
              wp.${WholesalerPaymentsTable.wholesalerId},
              ${moneyOrZero(whPaymentCols, 'wp', WholesalerPaymentsTable.amount)},
              ${colOrDefault(whPaymentCols, 'wp', WholesalerPaymentsTable.paymentMethod, "'Cash'")},
              ${colOrDefault(whPaymentCols, 'wp', WholesalerPaymentsTable.paymentSource, "'${WholesalerPaymentSource.manualKhataPayment}'")},
              ${colOrDefault(whPaymentCols, 'wp', WholesalerPaymentsTable.referenceNo, 'NULL')},
              ${colOrDefault(whPaymentCols, 'wp', WholesalerPaymentsTable.date, "datetime('now')")},
              ${colOrDefault(whPaymentCols, 'wp', WholesalerPaymentsTable.notes, 'NULL')}
            FROM $stageWhPayments wp
          ''');
        }

        // Drop staging tables (TEMP; also auto-cleared on connection close).
        for (final stage in [
          stageSales,
          stageSaleItems,
          stagePayments,
          stageLedger,
          stagePurchases,
          stagePurchaseItems,
          stageWhLedger,
          stageWhPayments,
        ]) {
          await txn.execute('DROP TABLE IF EXISTS $stage');
        }
      });

      await _createIndexes(db);

      // ---------------------------------------------------------------
      // 4) RE-INJECT NATIVE TRIGGERS & RECALCULATE LEDGER / BALANCES
      // ---------------------------------------------------------------
      log?.step('recreate triggers + rebuild ledger stream');
      await _createLedgerSyncTriggers(db);
      await _rebuildLedgerStreamAfterV26(db);
      await _recalculateAllZamindarBalances(db);
    } finally {
      await guard.exit();
    }
  }

  /// Touch-updates every sale/payment so v26 triggers rewrite the ledger
  /// stream (DEBIT from sales, CREDIT from payments) under the new rules.
  Future<void> _rebuildLedgerStreamAfterV26(Database db) async {
    await db.delete(LedgerTransactionTable.name);

    final sales = await db.query(SalesTable.name);
    for (final sale in sales) {
      if (sale[SalesTable.zamindarId] == null) continue;
      final invoice = sale[SalesTable.invoiceNumber] as String?;
      if (invoice == null || invoice.isEmpty) continue;

      // Fires after_sale_update → SALE debit + invoice-linked payment credits.
      await db.update(
        SalesTable.name,
        {SalesTable.dateTime: sale[SalesTable.dateTime]},
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoice],
      );
    }

    // Advance collections (NULL invoice) are not covered by sale updates.
    final payments = await db.query(PaymentsTable.name);
    for (final payment in payments) {
      final paymentId = payment[PaymentsTable.paymentId] as String?;
      if (paymentId == null || paymentId.isEmpty) continue;

      final existing = await db.query(
        LedgerTransactionTable.name,
        columns: [LedgerTransactionTable.id],
        where: '${LedgerTransactionTable.paymentId} = ?',
        whereArgs: [paymentId],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;

      // Fires after_payment_update when zamindar can be resolved.
      await db.update(
        PaymentsTable.name,
        {PaymentsTable.dateTime: payment[PaymentsTable.dateTime]},
        where: '${PaymentsTable.paymentId} = ?',
        whereArgs: [paymentId],
      );
    }

    debugPrint(
      'v26 ledger rebuild complete '
      '(${sales.length} sales, ${payments.length} payments swept)',
    );
  }

  Future<bool> _tableExists(DatabaseExecutor db, String table) =>
      tableExists(db, table);

  Future<Set<String>> _tableColumnNames(
    DatabaseExecutor db,
    String table,
  ) =>
      tableColumnNames(db, table);

  /// Single source of truth for how much has been collected on sale alias `s`.
  /// Prefer SUM(payments) when payment rows exist; otherwise sales.paid_amount.
  static String get _sqlSaleCollectedExpr => '''
CASE
  WHEN EXISTS (
    SELECT 1 FROM ${PaymentsTable.name} p
    WHERE p.${PaymentsTable.invoiceNumber} = s.${SalesTable.invoiceNumber}
  )
  THEN COALESCE((
    SELECT SUM(p2.${PaymentsTable.amountPaid})
    FROM ${PaymentsTable.name} p2
    WHERE p2.${PaymentsTable.invoiceNumber} = s.${SalesTable.invoiceNumber}
  ), 0)
  ELSE COALESCE(s.${SalesTable.paidAmount}, 0)
END
''';

  /// Outstanding = total_payable − collected (floored at 0) for sale alias `s`.
  static String get _sqlSaleRemainingExpr => '''
CASE
  WHEN (s.${SalesTable.totalPayable} - ($_sqlSaleCollectedExpr)) > 0
  THEN (s.${SalesTable.totalPayable} - ($_sqlSaleCollectedExpr))
  ELSE 0
END
''';

  Future<void> _rebuildLedgerTransactionsWithInvoiceCascade(
    Database db, {
    MigrationLog? log,
  }) async {
    final guard = await ForeignKeyGuard.enter(db);
    try {
      await rebuildTableWithSwap(
        db,
        TableSwapSpec(
          tableName: LedgerTransactionTable.name,
          createNewTableSql: '''
            CREATE TABLE ledger_transactions_new (
              ${LedgerTransactionTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
              ${LedgerTransactionTable.zamindarId} INTEGER NOT NULL,
              ${LedgerTransactionTable.kisaanId} INTEGER,
              ${LedgerTransactionTable.invoiceNumber} TEXT,
              ${LedgerTransactionTable.paymentId} TEXT,
              ${LedgerTransactionTable.type} TEXT NOT NULL,
              ${LedgerTransactionTable.category} TEXT NOT NULL,
              ${LedgerTransactionTable.description} TEXT NOT NULL,
              ${LedgerTransactionTable.amount} INTEGER NOT NULL,
              ${LedgerTransactionTable.dateTime} TEXT NOT NULL,
              ${LedgerTransactionTable.season} TEXT NOT NULL,
              FOREIGN KEY (${LedgerTransactionTable.zamindarId})
                REFERENCES ${ZamindarTable.name}(${ZamindarTable.id})
                ON DELETE CASCADE,
              FOREIGN KEY (${LedgerTransactionTable.kisaanId})
                REFERENCES ${KisaanTable.name}(${KisaanTable.id})
                ON DELETE SET NULL,
              FOREIGN KEY (${LedgerTransactionTable.invoiceNumber})
                REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
                ON UPDATE CASCADE ON DELETE CASCADE,
              FOREIGN KEY (${LedgerTransactionTable.paymentId})
                REFERENCES ${PaymentsTable.name}(${PaymentsTable.paymentId})
                ON DELETE SET NULL
            )
          ''',
          copyColumns: const [
            LedgerTransactionTable.id,
            LedgerTransactionTable.zamindarId,
            LedgerTransactionTable.kisaanId,
            LedgerTransactionTable.invoiceNumber,
            LedgerTransactionTable.paymentId,
            LedgerTransactionTable.type,
            LedgerTransactionTable.category,
            LedgerTransactionTable.description,
            LedgerTransactionTable.amount,
            LedgerTransactionTable.dateTime,
            LedgerTransactionTable.season,
          ],
          dependentTriggers: kLedgerSyncTriggerNames,
          verifyAfter: false,
          recreateIndexSql: const [
            'CREATE INDEX IF NOT EXISTS idx_ledger_zamindar_id '
                'ON ledger_transactions(zamindar_id)',
            'CREATE INDEX IF NOT EXISTS idx_ledger_kisaan_id '
                'ON ledger_transactions(kisaan_id)',
            'CREATE INDEX IF NOT EXISTS idx_ledger_invoice_number '
                'ON ledger_transactions(invoice_number)',
          ],
        ),
        log: log,
      );
    } finally {
      await guard.exit();
    }
  }

  Future<void> _rebuildPaymentsWithInvoiceCascade(
    Database db, {
    MigrationLog? log,
  }) async {
    final liveCols = await tableColumnNames(db, PaymentsTable.name);
    final hasName = liveCols.contains(PaymentsTable.zamindarName);
    final hasId = liveCols.contains(PaymentsTable.zamindarId);
    final salesCols = await tableExists(db, SalesTable.name)
        ? await tableColumnNames(db, SalesTable.name)
        : <String>{};

    log?.info(
      'payments rebuild: hasName=$hasName hasId=$hasId cols=$liveCols',
    );

    final guard = await ForeignKeyGuard.enter(db);
    try {
      // Prefer id-based CASCADE rebuild whenever names are absent. Forcing a
      // name-based destination (zamindar_name NOT NULL) is what crashed when
      // live payments only had ids / bare columns.
      if (!hasName) {
        final zamindarIdExpr = _sqlResolvePaymentZamindarId(
          hasPaymentId: hasId,
          salesCols: salesCols,
        );
        final kisaanIdExpr = _sqlResolvePaymentKisaanId(
          hasPaymentKisaanId: liveCols.contains(PaymentsTable.kisaanId),
          salesCols: salesCols,
        );

        await rebuildTableWithSwap(
          db,
          TableSwapSpec(
            tableName: PaymentsTable.name,
            createNewTableSql: '''
              CREATE TABLE payments_new (
                ${PaymentsTable.paymentId} TEXT PRIMARY KEY,
                ${PaymentsTable.invoiceNumber} TEXT,
                ${PaymentsTable.dateTime} TEXT NOT NULL,
                ${PaymentsTable.zamindarId} INTEGER,
                ${PaymentsTable.kisaanId} INTEGER,
                ${PaymentsTable.amountPaid} REAL NOT NULL,
                ${PaymentsTable.paymentMethod} TEXT NOT NULL,
                ${PaymentsTable.season} TEXT NOT NULL,
                FOREIGN KEY (${PaymentsTable.invoiceNumber})
                  REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
                  ON UPDATE CASCADE ON DELETE CASCADE,
                FOREIGN KEY (${PaymentsTable.zamindarId})
                  REFERENCES ${ZamindarTable.name}(${ZamindarTable.id})
                  ON DELETE RESTRICT,
                FOREIGN KEY (${PaymentsTable.kisaanId})
                  REFERENCES ${KisaanTable.name}(${KisaanTable.id})
                  ON DELETE SET NULL
              )
            ''',
            copyColumns: const [
              PaymentsTable.paymentId,
              PaymentsTable.invoiceNumber,
              PaymentsTable.dateTime,
              PaymentsTable.zamindarId,
              PaymentsTable.kisaanId,
              PaymentsTable.amountPaid,
              PaymentsTable.paymentMethod,
              PaymentsTable.season,
            ],
            selectExpressions: {
              PaymentsTable.zamindarId: zamindarIdExpr,
              PaymentsTable.kisaanId: kisaanIdExpr,
            },
            dependentTriggers: const [
              'after_payment_insert',
              'after_payment_delete',
              'after_payment_update',
            ],
            verifyAfter: false,
            recreateIndexSql: const [
              'CREATE INDEX IF NOT EXISTS idx_payments_invoice '
                  'ON payments(invoice_number)',
              'CREATE INDEX IF NOT EXISTS idx_payments_zamindar_id '
                  'ON payments(zamindar_id)',
            ],
          ),
          log: log,
        );
        return;
      }

      // Classic pre-v26 shape: keep denormalized names, add CASCADE.
      final nameExpr = _sqlResolvePaymentZamindarName(
        hasPaymentName: true,
        hasPaymentId: hasId,
        salesCols: salesCols,
      );
      final kisaanNameExpr = liveCols.contains(PaymentsTable.kisaanName)
          ? "NULLIF(TRIM(${PaymentsTable.kisaanName}), '')"
          : 'NULL';

      await rebuildTableWithSwap(
        db,
        TableSwapSpec(
          tableName: PaymentsTable.name,
          createNewTableSql: '''
            CREATE TABLE payments_new (
              ${PaymentsTable.paymentId} TEXT PRIMARY KEY,
              ${PaymentsTable.invoiceNumber} TEXT,
              ${PaymentsTable.dateTime} TEXT NOT NULL,
              ${PaymentsTable.zamindarName} TEXT NOT NULL,
              ${PaymentsTable.kisaanName} TEXT,
              ${PaymentsTable.amountPaid} REAL NOT NULL,
              ${PaymentsTable.paymentMethod} TEXT NOT NULL,
              ${PaymentsTable.season} TEXT NOT NULL,
              FOREIGN KEY (${PaymentsTable.invoiceNumber})
                REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
                ON UPDATE CASCADE ON DELETE CASCADE
            )
          ''',
          copyColumns: const [
            PaymentsTable.paymentId,
            PaymentsTable.invoiceNumber,
            PaymentsTable.dateTime,
            PaymentsTable.zamindarName,
            PaymentsTable.kisaanName,
            PaymentsTable.amountPaid,
            PaymentsTable.paymentMethod,
            PaymentsTable.season,
          ],
          selectExpressions: {
            PaymentsTable.zamindarName: nameExpr,
            PaymentsTable.kisaanName: kisaanNameExpr,
          },
          dependentTriggers: const [
            'after_payment_insert',
            'after_payment_delete',
            'after_payment_update',
          ],
          verifyAfter: false,
          recreateIndexSql: const [
            'CREATE INDEX IF NOT EXISTS idx_payments_invoice '
                'ON payments(invoice_number)',
          ],
        ),
        log: log,
      );
    } finally {
      await guard.exit();
    }
  }

  /// SQL expression resolving a payment's zamindar_id from the row and/or sales.
  String _sqlResolvePaymentZamindarId({
    required bool hasPaymentId,
    required Set<String> salesCols,
  }) {
    final parts = <String>[];
    if (hasPaymentId) parts.add(PaymentsTable.zamindarId);
    if (salesCols.contains(SalesTable.zamindarId)) {
      parts.add('''
        (SELECT s.${SalesTable.zamindarId} FROM ${SalesTable.name} s
         WHERE s.${SalesTable.invoiceNumber} = ${PaymentsTable.invoiceNumber}
         LIMIT 1)''');
    }
    if (salesCols.contains(SalesTable.zamindarName)) {
      parts.add('''
        (SELECT z.${ZamindarTable.id} FROM ${ZamindarTable.name} z
         INNER JOIN ${SalesTable.name} s
           ON z.${ZamindarTable.nameColumn} = TRIM(s.${SalesTable.zamindarName})
         WHERE s.${SalesTable.invoiceNumber} = ${PaymentsTable.invoiceNumber}
         LIMIT 1)''');
    }
    if (parts.isEmpty) return 'NULL';
    if (parts.length == 1) return parts.first;
    return 'COALESCE(${parts.join(', ')})';
  }

  String _sqlResolvePaymentKisaanId({
    required bool hasPaymentKisaanId,
    required Set<String> salesCols,
  }) {
    final parts = <String>[];
    if (hasPaymentKisaanId) parts.add(PaymentsTable.kisaanId);
    if (salesCols.contains(SalesTable.kisaanId)) {
      parts.add('''
        (SELECT s.${SalesTable.kisaanId} FROM ${SalesTable.name} s
         WHERE s.${SalesTable.invoiceNumber} = ${PaymentsTable.invoiceNumber}
         LIMIT 1)''');
    }
    if (parts.isEmpty) return 'NULL';
    if (parts.length == 1) return parts.first;
    return 'COALESCE(${parts.join(', ')})';
  }

  /// Always yields a non-null display name for legacy name-based payments tables.
  String _sqlResolvePaymentZamindarName({
    required bool hasPaymentName,
    required bool hasPaymentId,
    required Set<String> salesCols,
  }) {
    final parts = <String>[];
    if (hasPaymentName) {
      parts.add("NULLIF(TRIM(${PaymentsTable.zamindarName}), '')");
    }
    if (salesCols.contains(SalesTable.zamindarName)) {
      parts.add('''
        (SELECT NULLIF(TRIM(s.${SalesTable.zamindarName}), '')
         FROM ${SalesTable.name} s
         WHERE s.${SalesTable.invoiceNumber} = ${PaymentsTable.invoiceNumber}
         LIMIT 1)''');
    }
    if (hasPaymentId) {
      parts.add('''
        (SELECT z.${ZamindarTable.nameColumn} FROM ${ZamindarTable.name} z
         WHERE z.${ZamindarTable.id} = ${PaymentsTable.zamindarId}
         LIMIT 1)''');
    }
    if (salesCols.contains(SalesTable.zamindarId)) {
      parts.add('''
        (SELECT z.${ZamindarTable.nameColumn} FROM ${ZamindarTable.name} z
         INNER JOIN ${SalesTable.name} s
           ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
         WHERE s.${SalesTable.invoiceNumber} = ${PaymentsTable.invoiceNumber}
         LIMIT 1)''');
    }
    parts.add("'Unknown'");
    return 'COALESCE(${parts.join(', ')})';
  }

  /// Creates expenses table + date index if missing.
  Future<void> _ensureExpensesSchema(Database db) async {
    await db.execute(_createExpensesTable());
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_expenses_expense_date
      ON ${ExpenseTable.name}(${ExpenseTable.expenseDate})
    ''');
  }

  /// Creates employees / attendance tables and payroll link columns on expenses.
  Future<void> _ensureEmployeeSchema(Database db) async {
    await db.execute(_createEmployeesTable());
    await db.execute(_createEmployeeAttendanceTable());
    await addColumnIfMissing(
      db,
      table: ExpenseTable.name,
      column: ExpenseTable.employeeId,
      columnDefSql: '${ExpenseTable.employeeId} INTEGER',
    );
    await addColumnIfMissing(
      db,
      table: ExpenseTable.name,
      column: ExpenseTable.payrollType,
      columnDefSql: '${ExpenseTable.payrollType} TEXT',
    );
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_employee_attendance_date
      ON ${EmployeeAttendanceTable.name}(${EmployeeAttendanceTable.date})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_expenses_employee_id
      ON ${ExpenseTable.name}(${ExpenseTable.employeeId})
    ''');
  }

  /// Adds Cash/Fuel Advance columns on [SalesTable] (idempotent).
  /// Called from onOpen and v25 — must stay quiet when columns already exist.
  Future<void> _ensureSalesAdvanceSchema(Database db) async {
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.transactionType,
      columnDefSql:
          "${SalesTable.transactionType} TEXT NOT NULL DEFAULT '${SaleTransactionType.productSale}'",
    );
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.creditAmount,
      columnDefSql: '${SalesTable.creditAmount} INTEGER NOT NULL DEFAULT 0',
    );
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.fuelQuantity,
      columnDefSql: '${SalesTable.fuelQuantity} REAL',
    );
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.remarks,
      columnDefSql: '${SalesTable.remarks} TEXT',
    );
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.zamindarId,
      columnDefSql: '${SalesTable.zamindarId} INTEGER',
    );
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.kisaanId,
      columnDefSql: '${SalesTable.kisaanId} INTEGER',
    );

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sales_transaction_type
      ON ${SalesTable.name}(${SalesTable.transactionType})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sales_zamindar_id
      ON ${SalesTable.name}(${SalesTable.zamindarId})
    ''');
  }

  /// Creates wholesaler_ledger if missing and backfills rows from purchase_invoices.
  Future<void> _ensureWholesalerLedgerSchema(Database db) async {
    await db.execute(_createWholesalerLedgerTable());
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_wholesaler_ledger_wholesaler
      ON ${WholesalerLedgerTable.name}(${WholesalerLedgerTable.wholesalerId})
    ''');
    await _backfillWholesalerLedgerFromPurchases(db);
  }

  Future<void> _ensureWholesalerPaymentsSchema(Database db) async {
    await db.execute(_createWholesalerPaymentsTable());
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_wholesaler_payments_wholesaler
      ON ${WholesalerPaymentsTable.name}(${WholesalerPaymentsTable.wholesalerId})
    ''');
    await _backfillWholesalerPaymentsFromPurchases(db);
  }

  Future<void> _backfillWholesalerPaymentsFromPurchases(Database db) async {
    final missing = await db.rawQuery(
      '''
      SELECT pi.*
      FROM ${PurchaseInvoicesTable.name} pi
      WHERE pi.${PurchaseInvoicesTable.amountPaid} > 0
        AND NOT EXISTS (
          SELECT 1 FROM ${WholesalerPaymentsTable.name} wp
          WHERE wp.${WholesalerPaymentsTable.referenceNo} = pi.${PurchaseInvoicesTable.invoiceNumber}
            AND wp.${WholesalerPaymentsTable.paymentSource} = ?
        )
      ORDER BY pi.${PurchaseInvoicesTable.dateTime} ASC
    ''',
      [WholesalerPaymentSource.cashPurchaseOutlay],
    );

    if (missing.isEmpty) return;
    debugPrint('Backfilling ${missing.length} cash purchase outlay payment(s)');

    for (final row in missing) {
      final paid =
          (row[PurchaseInvoicesTable.amountPaid] as num?)?.toDouble() ?? 0;
      if (paid <= 0) continue;
      await db.insert(WholesalerPaymentsTable.name, {
        WholesalerPaymentsTable.wholesalerId:
            row[PurchaseInvoicesTable.wholesalerId],
        WholesalerPaymentsTable.amount: paid,
        WholesalerPaymentsTable.paymentMethod: 'Cash',
        WholesalerPaymentsTable.paymentSource:
            WholesalerPaymentSource.cashPurchaseOutlay,
        WholesalerPaymentsTable.referenceNo:
            row[PurchaseInvoicesTable.invoiceNumber],
        WholesalerPaymentsTable.date:
            row[PurchaseInvoicesTable.dateTime] as String? ??
            DateTime.now().toIso8601String(),
        WholesalerPaymentsTable.notes:
            'Auto-backfill from ${row[PurchaseInvoicesTable.paymentType]} purchase',
      });
    }
  }

  Future<void> _backfillWholesalerLedgerFromPurchases(Database db) async {
    final missing = await db.rawQuery(
      '''
      SELECT pi.*
      FROM ${PurchaseInvoicesTable.name} pi
      WHERE NOT EXISTS (
        SELECT 1 FROM ${WholesalerLedgerTable.name} wl
        WHERE wl.${WholesalerLedgerTable.referenceId} = pi.${PurchaseInvoicesTable.invoiceNumber}
          AND wl.${WholesalerLedgerTable.transactionType} = ?
      )
      ORDER BY pi.${PurchaseInvoicesTable.dateTime} ASC,
               pi.${PurchaseInvoicesTable.invoiceNumber} ASC
    ''',
      [WholesalerLedgerTxnType.purchase],
    );

    if (missing.isEmpty) return;

    debugPrint(
      'Backfilling ${missing.length} purchase(s) into wholesaler_ledger',
    );

    for (final row in missing) {
      final wholesalerId = row[PurchaseInvoicesTable.wholesalerId] as int;
      final invoiceNumber = row[PurchaseInvoicesTable.invoiceNumber] as String;
      final dateRaw =
          row[PurchaseInvoicesTable.dateTime] as String? ??
          DateTime.now().toIso8601String();
      final grandTotal =
          (row[PurchaseInvoicesTable.grandTotal] as num?)?.toDouble() ?? 0;
      final paid =
          (row[PurchaseInvoicesTable.amountPaid] as num?)?.toDouble() ?? 0;
      final outstanding =
          (row[PurchaseInvoicesTable.outstanding] as num?)?.toDouble() ??
          (grandTotal - paid);

      await db.insert(WholesalerLedgerTable.name, {
        WholesalerLedgerTable.wholesalerId: wholesalerId,
        WholesalerLedgerTable.transactionType: WholesalerLedgerTxnType.purchase,
        WholesalerLedgerTable.referenceId: invoiceNumber,
        WholesalerLedgerTable.date: dateRaw,
        WholesalerLedgerTable.debit:
            (grandTotal > 0 ? grandTotal : outstanding).round(),
        WholesalerLedgerTable.credit: 0,
      });

      if (paid > 0) {
        await db.insert(WholesalerLedgerTable.name, {
          WholesalerLedgerTable.wholesalerId: wholesalerId,
          WholesalerLedgerTable.transactionType:
              WholesalerLedgerTxnType.payment,
          WholesalerLedgerTable.referenceId: '$invoiceNumber-PAID',
          WholesalerLedgerTable.date: dateRaw,
          WholesalerLedgerTable.debit: 0,
          WholesalerLedgerTable.credit: paid.round(),
        });
      }
    }
  }

  Future<void> _ensureDatabaseFactory() async {
    if (_factoryInitialized) return;
    if (kIsWeb) {
      _factoryInitialized = true;
      return;
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      } catch (e) {
        debugPrint('sqflite ffi initialization failed: $e');
        rethrow;
      }
    }

    _factoryInitialized = true;
  }

  static String _formatDateTime(DateTime dateTime) =>
      dateTime.toIso8601String();

  /// Advances were previously hardcoded to "Rabi 2026". Recompute season from
  /// each row's date_time so filters (e.g. Kharif 2026) show them correctly.
  Future<void> _repairAdvancePaymentSeasons(Database db) async {
    try {
      final rows = await db.query(
        LedgerTransactionTable.name,
        where: 'UPPER(${LedgerTransactionTable.category}) IN (?, ?)',
        whereArgs: const ['ADVANCE_PAYMENT', 'ADVANCE'],
      );

      for (final row in rows) {
        final id = row[LedgerTransactionTable.id] as int?;
        final dateRaw = row[LedgerTransactionTable.dateTime] as String?;
        if (id == null || dateRaw == null || dateRaw.isEmpty) continue;

        final correctSeason = SeasonUtils.getSeasonString(
          _parseDateTime(dateRaw),
        );
        final current = (row[LedgerTransactionTable.season] as String? ?? '')
            .trim();
        if (current == correctSeason) continue;

        await db.update(
          LedgerTransactionTable.name,
          {LedgerTransactionTable.season: correctSeason},
          where: '${LedgerTransactionTable.id} = ?',
          whereArgs: [id],
        );

        final paymentId = row[LedgerTransactionTable.paymentId] as String?;
        if (paymentId != null && paymentId.isNotEmpty) {
          await db.update(
            PaymentsTable.name,
            {PaymentsTable.season: correctSeason},
            where: '${PaymentsTable.paymentId} = ?',
            whereArgs: [paymentId],
          );
        }
      }
    } catch (e) {
      debugPrint('Advance season repair skipped: $e');
    }
  }

  Future<void> _backfillLedgerFromSales(Database db) async {
    // Touch-update missing SALE ledger rows so after_sale_update fires.
    final salesMaps = await db.query(SalesTable.name);
    for (final sale in salesMaps) {
      final invoiceNumber = sale[SalesTable.invoiceNumber] as String;
      final existing = await db.query(
        LedgerTransactionTable.name,
        where:
            '${LedgerTransactionTable.invoiceNumber} = ? AND '
            'UPPER(${LedgerTransactionTable.category}) IN '
            "('SALE', 'CASH_ADVANCE', 'DIESEL_ADVANCE', 'PETROL_ADVANCE')",
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      if (sale[SalesTable.zamindarId] == null) continue;

      await db.update(
        SalesTable.name,
        {
          SalesTable.dateTime: sale[SalesTable.dateTime],
        },
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
    }
  }

  double _sumPaymentsCollected(
    double initialPaid,
    List<Map<String, dynamic>> paymentsMaps,
  ) {
    if (paymentsMaps.isEmpty) {
      return initialPaid;
    }
    return paymentsMaps.fold<double>(
      0.0,
      (sum, payment) =>
          sum +
          ((payment[PaymentsTable.amountPaid] as num?)?.toDouble() ?? 0.0),
    );
  }

  String _createPaymentSequencesTable() => '''
    CREATE TABLE IF NOT EXISTS payment_sequences (
      sequence_key TEXT PRIMARY KEY,
      last_value INTEGER NOT NULL DEFAULT 1000
    )
  ''';

  Future<void> _seedPaymentSequences(Database db) async {
    for (final isAdvance in [false, true]) {
      final whereClause = isAdvance
          ? "${PaymentsTable.paymentId} LIKE 'PAY-ADV-%'"
          : "${PaymentsTable.paymentId} LIKE 'PAY-%' AND ${PaymentsTable.paymentId} NOT LIKE 'PAY-ADV-%'";

      final rows = await db.rawQuery('''
        SELECT ${PaymentsTable.paymentId}
        FROM ${PaymentsTable.name}
        WHERE $whereClause
      ''');

      var maxSeq = 1000;
      for (final row in rows) {
        final id = row[PaymentsTable.paymentId] as String;
        final seq = _extractPaymentSequence(id, isAdvance: isAdvance);
        if (seq > maxSeq) maxSeq = seq;
      }

      final key = isAdvance ? 'advance' : 'standard';
      await db.insert('payment_sequences', {
        'sequence_key': key,
        'last_value': maxSeq,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> _cleanupGhostAdvancePayments(Database db) async {
    await db.rawDelete('''
      DELETE FROM ${PaymentsTable.name}
      WHERE ${PaymentsTable.invoiceNumber} IS NULL
        AND ${PaymentsTable.paymentMethod} = 'Cash'
        AND ${PaymentsTable.paymentId} IN (
          SELECT ${LedgerTransactionTable.paymentId}
          FROM ${LedgerTransactionTable.name}
          WHERE ${LedgerTransactionTable.category} = 'ADVANCE_PAYMENT'
            AND ${LedgerTransactionTable.description} = 'Advance wallet deduction'
            AND ${LedgerTransactionTable.paymentId} IS NOT NULL
            AND TRIM(${LedgerTransactionTable.paymentId}) != ''
        )
    ''');

    final walletLedgers = await db.query(
      LedgerTransactionTable.name,
      where:
          '${LedgerTransactionTable.category} = ? AND ${LedgerTransactionTable.description} = ?',
      whereArgs: ['ADVANCE_PAYMENT', 'Advance wallet deduction'],
    );

    for (final ledger in walletLedgers) {
      final zamindarId = ledger[LedgerTransactionTable.zamindarId] as int?;
      final amount = (ledger[LedgerTransactionTable.amount] as num).toDouble();
      final dateTime = ledger[LedgerTransactionTable.dateTime] as String;
      if (zamindarId == null) continue;

      final zamindarRows = await db.query(
        ZamindarTable.name,
        columns: [ZamindarTable.nameColumn],
        where: '${ZamindarTable.id} = ?',
        whereArgs: [zamindarId],
        limit: 1,
      );
      if (zamindarRows.isEmpty) continue;
      final zamindarName =
          zamindarRows.first[ZamindarTable.nameColumn] as String;

      await db.delete(
        PaymentsTable.name,
        where:
            '${PaymentsTable.invoiceNumber} IS NULL AND ${PaymentsTable.zamindarName} = ? AND ${PaymentsTable.amountPaid} = ? AND ${PaymentsTable.dateTime} = ? AND ${PaymentsTable.paymentMethod} = ?',
        whereArgs: [zamindarName, amount, dateTime, 'Cash'],
      );
    }
  }

  static String _formatDateOnly(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _createZamindarsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${ZamindarTable.name} (
      ${ZamindarTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${ZamindarTable.nameColumn} TEXT NOT NULL,
      ${ZamindarTable.fathersName} TEXT,
      ${ZamindarTable.whatsappNumber} TEXT NOT NULL,
      ${ZamindarTable.locationGoth} TEXT,
      ${ZamindarTable.village} TEXT,
      ${ZamindarTable.description} TEXT,
      ${ZamindarTable.creditLimit} INTEGER NOT NULL,
      ${ZamindarTable.landArea} REAL NOT NULL,
      ${ZamindarTable.landUnit} TEXT NOT NULL,
      ${ZamindarTable.paymentTerms} TEXT NOT NULL,
      ${ZamindarTable.activeSeasons} TEXT,
      ${ZamindarTable.activeCrops} TEXT,
      ${ZamindarTable.isDraft} INTEGER DEFAULT 0,
      ${ZamindarTable.advanceBalance} INTEGER DEFAULT 0,
      ${ZamindarTable.currentBalance} INTEGER NOT NULL DEFAULT 0
    )
  ''';

  Future<void> _createIndexes(Database db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_kisaans_zamindar_id
      ON kisaans(zamindar_id)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_ledger_zamindar_id
      ON ledger_transactions(zamindar_id)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_ledger_kisaan_id
      ON ledger_transactions(kisaan_id)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_ledger_invoice_number
      ON ledger_transactions(invoice_number)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_purchase_items_invoice
      ON ${PurchaseItemsTable.name}(${PurchaseItemsTable.invoiceNumber})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_wholesalers_name
      ON ${WholesalerTable.name}(${WholesalerTable.nameColumn})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_wholesaler_ledger_wholesaler
      ON ${WholesalerLedgerTable.name}(${WholesalerLedgerTable.wholesalerId})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_wholesaler_payments_wholesaler
      ON ${WholesalerPaymentsTable.name}(${WholesalerPaymentsTable.wholesalerId})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_expenses_expense_date
      ON ${ExpenseTable.name}(${ExpenseTable.expenseDate})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_products_search
      ON ${ProductTable.name}(${ProductTable.nameColumn}, ${ProductTable.brand})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_zamindars_search
      ON ${ZamindarTable.name}(${ZamindarTable.nameColumn})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sales_zamindar_id
      ON ${SalesTable.name}(${SalesTable.zamindarId})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_payments_zamindar_id
      ON ${PaymentsTable.name}(${PaymentsTable.zamindarId})
    ''');
  }

  /// Native SQLite triggers keep sales/payments/purchases ledgers in sync.
  /// Sale polarity: SALE = DEBIT, payment = CREDIT (app convention).
  Future<void> _createLedgerSyncTriggers(Database db) async {
    await dropTriggers(db, kLedgerSyncTriggerNames);

    // Shared CASE expressions for payment → ledger mapping.
    const paymentCategoryCase = '''
      CASE
        WHEN NEW.${PaymentsTable.invoiceNumber} IS NULL
          THEN 'ADVANCE_PAYMENT'
        WHEN NEW.${PaymentsTable.paymentMethod} = 'Advance Wallet Deduction'
          THEN 'WALLET_DEDUCTION'
        WHEN NEW.${PaymentsTable.paymentMethod} = 'Cash' THEN 'CASH_PAYMENT'
        ELSE 'PAYMENT'
      END
    ''';
    const paymentDescriptionCase = '''
      CASE
        WHEN NEW.${PaymentsTable.invoiceNumber} IS NULL
          THEN 'Advance payment received'
        WHEN NEW.${PaymentsTable.paymentMethod} = 'Advance Wallet Deduction'
          THEN 'Advance wallet deduction'
        ELSE 'Payment received via ' || NEW.${PaymentsTable.paymentMethod}
      END
    ''';
    const saleCategoryCase = '''
      CASE
        WHEN NEW.${SalesTable.transactionType} IN (
          '${SaleTransactionType.cashAdvance}',
          '${SaleTransactionType.dieselAdvance}',
          '${SaleTransactionType.petrolAdvance}'
        ) THEN NEW.${SalesTable.transactionType}
        ELSE 'SALE'
      END
    ''';
    const saleDescriptionCase = '''
      CASE
        WHEN NEW.${SalesTable.transactionType} = '${SaleTransactionType.cashAdvance}'
          THEN 'Cash Advance: ' || COALESCE(NEW.${SalesTable.remarks}, '')
        WHEN NEW.${SalesTable.transactionType} = '${SaleTransactionType.dieselAdvance}'
          THEN 'Diesel Advance (' || NEW.${SalesTable.fuelQuantity} || 'L)'
        WHEN NEW.${SalesTable.transactionType} = '${SaleTransactionType.petrolAdvance}'
          THEN 'Petrol Advance (' || NEW.${SalesTable.fuelQuantity} || 'L)'
        ELSE 'Product Sale Invoice'
      END
    ''';

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_sale_insert
      AFTER INSERT ON ${SalesTable.name}
      WHEN NEW.${SalesTable.zamindarId} IS NOT NULL
      BEGIN
        INSERT INTO ${LedgerTransactionTable.name} (
          ${LedgerTransactionTable.zamindarId},
          ${LedgerTransactionTable.kisaanId},
          ${LedgerTransactionTable.invoiceNumber},
          ${LedgerTransactionTable.paymentId},
          ${LedgerTransactionTable.type},
          ${LedgerTransactionTable.category},
          ${LedgerTransactionTable.description},
          ${LedgerTransactionTable.amount},
          ${LedgerTransactionTable.dateTime},
          ${LedgerTransactionTable.season}
        ) VALUES (
          NEW.${SalesTable.zamindarId},
          NEW.${SalesTable.kisaanId},
          NEW.${SalesTable.invoiceNumber},
          NULL,
          '${LedgerTransactionType.debit}',
          $saleCategoryCase,
          $saleDescriptionCase,
          NEW.${SalesTable.totalPayable},
          NEW.${SalesTable.dateTime},
          NEW.${SalesTable.season}
        );
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_sale_delete
      AFTER DELETE ON ${SalesTable.name}
      BEGIN
        DELETE FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.invoiceNumber}
          = OLD.${SalesTable.invoiceNumber};
      END;
    ''');

    // Wipe ALL invoice ledger rows (DEBIT + CREDIT), reinsert SALE debit,
    // then rebuild CREDIT rows from any payments that still reference the invoice
    // (preserves settlements kept during edit).
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_sale_update
      AFTER UPDATE ON ${SalesTable.name}
      WHEN NEW.${SalesTable.zamindarId} IS NOT NULL
      BEGIN
        DELETE FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.invoiceNumber}
          = OLD.${SalesTable.invoiceNumber};

        INSERT INTO ${LedgerTransactionTable.name} (
          ${LedgerTransactionTable.zamindarId},
          ${LedgerTransactionTable.kisaanId},
          ${LedgerTransactionTable.invoiceNumber},
          ${LedgerTransactionTable.paymentId},
          ${LedgerTransactionTable.type},
          ${LedgerTransactionTable.category},
          ${LedgerTransactionTable.description},
          ${LedgerTransactionTable.amount},
          ${LedgerTransactionTable.dateTime},
          ${LedgerTransactionTable.season}
        ) VALUES (
          NEW.${SalesTable.zamindarId},
          NEW.${SalesTable.kisaanId},
          NEW.${SalesTable.invoiceNumber},
          NULL,
          '${LedgerTransactionType.debit}',
          $saleCategoryCase,
          $saleDescriptionCase,
          NEW.${SalesTable.totalPayable},
          NEW.${SalesTable.dateTime},
          NEW.${SalesTable.season}
        );

        INSERT INTO ${LedgerTransactionTable.name} (
          ${LedgerTransactionTable.zamindarId},
          ${LedgerTransactionTable.kisaanId},
          ${LedgerTransactionTable.invoiceNumber},
          ${LedgerTransactionTable.paymentId},
          ${LedgerTransactionTable.type},
          ${LedgerTransactionTable.category},
          ${LedgerTransactionTable.description},
          ${LedgerTransactionTable.amount},
          ${LedgerTransactionTable.dateTime},
          ${LedgerTransactionTable.season}
        )
        SELECT
          COALESCE(
            p.${PaymentsTable.zamindarId},
            NEW.${SalesTable.zamindarId}
          ),
          COALESCE(
            p.${PaymentsTable.kisaanId},
            NEW.${SalesTable.kisaanId}
          ),
          p.${PaymentsTable.invoiceNumber},
          p.${PaymentsTable.paymentId},
          '${LedgerTransactionType.credit}',
          CASE
            WHEN p.${PaymentsTable.paymentMethod} = 'Advance Wallet Deduction'
              THEN 'WALLET_DEDUCTION'
            WHEN p.${PaymentsTable.paymentMethod} = 'Cash' THEN 'CASH_PAYMENT'
            ELSE 'PAYMENT'
          END,
          CASE
            WHEN p.${PaymentsTable.paymentMethod} = 'Advance Wallet Deduction'
              THEN 'Advance wallet deduction'
            ELSE 'Payment received via ' || p.${PaymentsTable.paymentMethod}
          END,
          p.${PaymentsTable.amountPaid},
          p.${PaymentsTable.dateTime},
          p.${PaymentsTable.season}
        FROM ${PaymentsTable.name} p
        WHERE p.${PaymentsTable.invoiceNumber} = NEW.${SalesTable.invoiceNumber};
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_payment_insert
      AFTER INSERT ON ${PaymentsTable.name}
      WHEN COALESCE(
        NEW.${PaymentsTable.zamindarId},
        (SELECT ${SalesTable.zamindarId} FROM ${SalesTable.name}
         WHERE ${SalesTable.invoiceNumber} = NEW.${PaymentsTable.invoiceNumber})
      ) IS NOT NULL
      BEGIN
        INSERT INTO ${LedgerTransactionTable.name} (
          ${LedgerTransactionTable.zamindarId},
          ${LedgerTransactionTable.kisaanId},
          ${LedgerTransactionTable.invoiceNumber},
          ${LedgerTransactionTable.paymentId},
          ${LedgerTransactionTable.type},
          ${LedgerTransactionTable.category},
          ${LedgerTransactionTable.description},
          ${LedgerTransactionTable.amount},
          ${LedgerTransactionTable.dateTime},
          ${LedgerTransactionTable.season}
        ) VALUES (
          COALESCE(
            NEW.${PaymentsTable.zamindarId},
            (SELECT ${SalesTable.zamindarId} FROM ${SalesTable.name}
             WHERE ${SalesTable.invoiceNumber}
               = NEW.${PaymentsTable.invoiceNumber})
          ),
          COALESCE(
            NEW.${PaymentsTable.kisaanId},
            (SELECT ${SalesTable.kisaanId} FROM ${SalesTable.name}
             WHERE ${SalesTable.invoiceNumber}
               = NEW.${PaymentsTable.invoiceNumber})
          ),
          NEW.${PaymentsTable.invoiceNumber},
          NEW.${PaymentsTable.paymentId},
          '${LedgerTransactionType.credit}',
          $paymentCategoryCase,
          $paymentDescriptionCase,
          NEW.${PaymentsTable.amountPaid},
          NEW.${PaymentsTable.dateTime},
          NEW.${PaymentsTable.season}
        );
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_payment_delete
      AFTER DELETE ON ${PaymentsTable.name}
      BEGIN
        DELETE FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.paymentId}
          = OLD.${PaymentsTable.paymentId};
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_payment_update
      AFTER UPDATE ON ${PaymentsTable.name}
      WHEN COALESCE(
        NEW.${PaymentsTable.zamindarId},
        (SELECT ${SalesTable.zamindarId} FROM ${SalesTable.name}
         WHERE ${SalesTable.invoiceNumber} = NEW.${PaymentsTable.invoiceNumber})
      ) IS NOT NULL
      BEGIN
        DELETE FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.paymentId}
          = OLD.${PaymentsTable.paymentId};

        INSERT INTO ${LedgerTransactionTable.name} (
          ${LedgerTransactionTable.zamindarId},
          ${LedgerTransactionTable.kisaanId},
          ${LedgerTransactionTable.invoiceNumber},
          ${LedgerTransactionTable.paymentId},
          ${LedgerTransactionTable.type},
          ${LedgerTransactionTable.category},
          ${LedgerTransactionTable.description},
          ${LedgerTransactionTable.amount},
          ${LedgerTransactionTable.dateTime},
          ${LedgerTransactionTable.season}
        ) VALUES (
          COALESCE(
            NEW.${PaymentsTable.zamindarId},
            (SELECT ${SalesTable.zamindarId} FROM ${SalesTable.name}
             WHERE ${SalesTable.invoiceNumber}
               = NEW.${PaymentsTable.invoiceNumber})
          ),
          COALESCE(
            NEW.${PaymentsTable.kisaanId},
            (SELECT ${SalesTable.kisaanId} FROM ${SalesTable.name}
             WHERE ${SalesTable.invoiceNumber}
               = NEW.${PaymentsTable.invoiceNumber})
          ),
          NEW.${PaymentsTable.invoiceNumber},
          NEW.${PaymentsTable.paymentId},
          '${LedgerTransactionType.credit}',
          $paymentCategoryCase,
          $paymentDescriptionCase,
          NEW.${PaymentsTable.amountPaid},
          NEW.${PaymentsTable.dateTime},
          NEW.${PaymentsTable.season}
        );
      END;
    ''');

    // --- Purchase → wholesaler_ledger + vendor balance ---
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_purchase_insert
      AFTER INSERT ON ${PurchaseInvoicesTable.name}
      BEGIN
        UPDATE ${WholesalerTable.name}
        SET ${WholesalerTable.balance} =
          ${WholesalerTable.balance} + NEW.${PurchaseInvoicesTable.outstanding}
        WHERE ${WholesalerTable.id} = NEW.${PurchaseInvoicesTable.wholesalerId};

        INSERT INTO ${WholesalerLedgerTable.name} (
          ${WholesalerLedgerTable.wholesalerId},
          ${WholesalerLedgerTable.transactionType},
          ${WholesalerLedgerTable.referenceId},
          ${WholesalerLedgerTable.date},
          ${WholesalerLedgerTable.debit},
          ${WholesalerLedgerTable.credit},
          ${WholesalerLedgerTable.description}
        ) VALUES (
          NEW.${PurchaseInvoicesTable.wholesalerId},
          '${WholesalerLedgerTxnType.purchase}',
          NEW.${PurchaseInvoicesTable.invoiceNumber},
          NEW.${PurchaseInvoicesTable.dateTime},
          NEW.${PurchaseInvoicesTable.grandTotal},
          0,
          COALESCE(
            NULLIF(TRIM(NEW.${PurchaseInvoicesTable.description}), ''),
            'Purchase ' || NEW.${PurchaseInvoicesTable.invoiceNumber}
          )
        );

        INSERT INTO ${WholesalerLedgerTable.name} (
          ${WholesalerLedgerTable.wholesalerId},
          ${WholesalerLedgerTable.transactionType},
          ${WholesalerLedgerTable.referenceId},
          ${WholesalerLedgerTable.date},
          ${WholesalerLedgerTable.debit},
          ${WholesalerLedgerTable.credit},
          ${WholesalerLedgerTable.description}
        )
        SELECT
          NEW.${PurchaseInvoicesTable.wholesalerId},
          '${WholesalerLedgerTxnType.payment}',
          NEW.${PurchaseInvoicesTable.invoiceNumber} || '-PAID',
          NEW.${PurchaseInvoicesTable.dateTime},
          0,
          NEW.${PurchaseInvoicesTable.amountPaid},
          'Purchase payment outlay'
        WHERE NEW.${PurchaseInvoicesTable.amountPaid} > 0;
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_purchase_update
      AFTER UPDATE ON ${PurchaseInvoicesTable.name}
      BEGIN
        UPDATE ${WholesalerTable.name}
        SET ${WholesalerTable.balance} = CASE
          WHEN ${WholesalerTable.balance}
                 - OLD.${PurchaseInvoicesTable.outstanding} < 0
            THEN 0
          ELSE ${WholesalerTable.balance}
                 - OLD.${PurchaseInvoicesTable.outstanding}
        END
        WHERE ${WholesalerTable.id} = OLD.${PurchaseInvoicesTable.wholesalerId};

        UPDATE ${WholesalerTable.name}
        SET ${WholesalerTable.balance} =
          ${WholesalerTable.balance} + NEW.${PurchaseInvoicesTable.outstanding}
        WHERE ${WholesalerTable.id} = NEW.${PurchaseInvoicesTable.wholesalerId};

        DELETE FROM ${WholesalerLedgerTable.name}
        WHERE ${WholesalerLedgerTable.wholesalerId}
              = OLD.${PurchaseInvoicesTable.wholesalerId}
          AND (
            ${WholesalerLedgerTable.referenceId}
              = OLD.${PurchaseInvoicesTable.invoiceNumber}
            OR ${WholesalerLedgerTable.referenceId}
              = OLD.${PurchaseInvoicesTable.invoiceNumber} || '-PAID'
          );

        INSERT INTO ${WholesalerLedgerTable.name} (
          ${WholesalerLedgerTable.wholesalerId},
          ${WholesalerLedgerTable.transactionType},
          ${WholesalerLedgerTable.referenceId},
          ${WholesalerLedgerTable.date},
          ${WholesalerLedgerTable.debit},
          ${WholesalerLedgerTable.credit},
          ${WholesalerLedgerTable.description}
        ) VALUES (
          NEW.${PurchaseInvoicesTable.wholesalerId},
          '${WholesalerLedgerTxnType.purchase}',
          NEW.${PurchaseInvoicesTable.invoiceNumber},
          NEW.${PurchaseInvoicesTable.dateTime},
          NEW.${PurchaseInvoicesTable.grandTotal},
          0,
          COALESCE(
            NULLIF(TRIM(NEW.${PurchaseInvoicesTable.description}), ''),
            'Purchase ' || NEW.${PurchaseInvoicesTable.invoiceNumber}
          )
        );

        INSERT INTO ${WholesalerLedgerTable.name} (
          ${WholesalerLedgerTable.wholesalerId},
          ${WholesalerLedgerTable.transactionType},
          ${WholesalerLedgerTable.referenceId},
          ${WholesalerLedgerTable.date},
          ${WholesalerLedgerTable.debit},
          ${WholesalerLedgerTable.credit},
          ${WholesalerLedgerTable.description}
        )
        SELECT
          NEW.${PurchaseInvoicesTable.wholesalerId},
          '${WholesalerLedgerTxnType.payment}',
          NEW.${PurchaseInvoicesTable.invoiceNumber} || '-PAID',
          NEW.${PurchaseInvoicesTable.dateTime},
          0,
          NEW.${PurchaseInvoicesTable.amountPaid},
          'Purchase payment outlay'
        WHERE NEW.${PurchaseInvoicesTable.amountPaid} > 0;
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_purchase_delete
      AFTER DELETE ON ${PurchaseInvoicesTable.name}
      BEGIN
        UPDATE ${WholesalerTable.name}
        SET ${WholesalerTable.balance} = CASE
          WHEN ${WholesalerTable.balance}
                 - OLD.${PurchaseInvoicesTable.outstanding} < 0
            THEN 0
          ELSE ${WholesalerTable.balance}
                 - OLD.${PurchaseInvoicesTable.outstanding}
        END
        WHERE ${WholesalerTable.id} = OLD.${PurchaseInvoicesTable.wholesalerId};

        DELETE FROM ${WholesalerLedgerTable.name}
        WHERE ${WholesalerLedgerTable.wholesalerId}
              = OLD.${PurchaseInvoicesTable.wholesalerId}
          AND (
            ${WholesalerLedgerTable.referenceId}
              = OLD.${PurchaseInvoicesTable.invoiceNumber}
            OR ${WholesalerLedgerTable.referenceId}
              = OLD.${PurchaseInvoicesTable.invoiceNumber} || '-PAID'
          );
      END;
    ''');

    // Manual khata payments (not cash purchase outlays — those come from purchase triggers).
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_wholesaler_payment_insert
      AFTER INSERT ON ${WholesalerPaymentsTable.name}
      WHEN NEW.${WholesalerPaymentsTable.paymentSource}
        = '${WholesalerPaymentSource.manualKhataPayment}'
      BEGIN
        INSERT INTO ${WholesalerLedgerTable.name} (
          ${WholesalerLedgerTable.wholesalerId},
          ${WholesalerLedgerTable.transactionType},
          ${WholesalerLedgerTable.referenceId},
          ${WholesalerLedgerTable.date},
          ${WholesalerLedgerTable.debit},
          ${WholesalerLedgerTable.credit},
          ${WholesalerLedgerTable.description}
        ) VALUES (
          NEW.${WholesalerPaymentsTable.wholesalerId},
          '${WholesalerLedgerTxnType.payment}',
          NEW.${WholesalerPaymentsTable.referenceNo},
          NEW.${WholesalerPaymentsTable.date},
          0,
          NEW.${WholesalerPaymentsTable.amount},
          COALESCE(NEW.${WholesalerPaymentsTable.notes}, '')
        );
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS after_wholesaler_payment_delete
      AFTER DELETE ON ${WholesalerPaymentsTable.name}
      WHEN OLD.${WholesalerPaymentsTable.paymentSource}
        = '${WholesalerPaymentSource.manualKhataPayment}'
      BEGIN
        DELETE FROM ${WholesalerLedgerTable.name}
        WHERE ${WholesalerLedgerTable.wholesalerId}
              = OLD.${WholesalerPaymentsTable.wholesalerId}
          AND ${WholesalerLedgerTable.referenceId}
              = OLD.${WholesalerPaymentsTable.referenceNo};
      END;
    ''');
  }

  String _createKisaansTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${KisaanTable.name} (
      ${KisaanTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${KisaanTable.zamindarId} INTEGER NOT NULL,
      ${KisaanTable.nameColumn} TEXT NOT NULL,
      ${KisaanTable.village} TEXT NOT NULL,
      ${KisaanTable.phone} TEXT,
      ${KisaanTable.landAcres} REAL NOT NULL,
      ${KisaanTable.currentCrop} TEXT NOT NULL,
      FOREIGN KEY (${KisaanTable.zamindarId}) REFERENCES ${ZamindarTable.name}(${ZamindarTable.id})
        ON DELETE CASCADE
    )
  ''';

  String _createProductsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${ProductTable.name} (
      ${ProductTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${ProductTable.nameColumn} TEXT NOT NULL,
      ${ProductTable.brand} TEXT NOT NULL,
      ${ProductTable.productType} TEXT DEFAULT 'Fertilizer',
      ${ProductTable.packagingSize} TEXT NOT NULL,
      ${ProductTable.costPrice} INTEGER NOT NULL,
      ${ProductTable.retailPrice} INTEGER NOT NULL,
      ${ProductTable.seasonalIncrement} INTEGER DEFAULT 0,
      ${ProductTable.availableStock} INTEGER NOT NULL DEFAULT 0,
      ${ProductTable.uom} TEXT NOT NULL,
      ${ProductTable.expiryDate} TEXT NOT NULL,
      ${ProductTable.lowStockThreshold} INTEGER NOT NULL DEFAULT 10,
      ${ProductTable.description} TEXT
    )
  ''';
  String _createLedgerTransactionsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${LedgerTransactionTable.name} (
      ${LedgerTransactionTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${LedgerTransactionTable.zamindarId} INTEGER NOT NULL,
      ${LedgerTransactionTable.kisaanId} INTEGER,
      ${LedgerTransactionTable.invoiceNumber} TEXT,
      ${LedgerTransactionTable.paymentId} TEXT,
      ${LedgerTransactionTable.type} TEXT NOT NULL,
      ${LedgerTransactionTable.category} TEXT NOT NULL,
      ${LedgerTransactionTable.description} TEXT NOT NULL,
      ${LedgerTransactionTable.amount} INTEGER NOT NULL,
      ${LedgerTransactionTable.dateTime} TEXT NOT NULL,
      ${LedgerTransactionTable.season} TEXT NOT NULL,
      FOREIGN KEY (${LedgerTransactionTable.zamindarId}) REFERENCES ${ZamindarTable.name}(${ZamindarTable.id})
        ON DELETE CASCADE,
      FOREIGN KEY (${LedgerTransactionTable.kisaanId}) REFERENCES ${KisaanTable.name}(${KisaanTable.id})
        ON DELETE SET NULL,
      FOREIGN KEY (${LedgerTransactionTable.invoiceNumber}) REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
        ON UPDATE CASCADE ON DELETE CASCADE,
      FOREIGN KEY (${LedgerTransactionTable.paymentId}) REFERENCES ${PaymentsTable.name}(${PaymentsTable.paymentId})
        ON DELETE CASCADE
    )
  ''';

  String _createSalesTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${SalesTable.name} (
      ${SalesTable.invoiceNumber} TEXT PRIMARY KEY,
      ${SalesTable.dateTime} TEXT NOT NULL,
      ${SalesTable.subtotal} INTEGER NOT NULL,
      ${SalesTable.itemDiscountsTotal} INTEGER NOT NULL DEFAULT 0,
      ${SalesTable.seasonalIncrementTotal} INTEGER NOT NULL DEFAULT 0,
      ${SalesTable.overallDiscount} INTEGER NOT NULL DEFAULT 0,
      ${SalesTable.totalPayable} INTEGER NOT NULL,
      ${SalesTable.paidAmount} INTEGER NOT NULL DEFAULT 0,
      ${SalesTable.paymentMethod} TEXT NOT NULL,
      ${SalesTable.season} TEXT NOT NULL,
      ${SalesTable.paymentTerm} TEXT,
      ${SalesTable.transactionType} TEXT NOT NULL
        DEFAULT '${SaleTransactionType.productSale}',
      ${SalesTable.creditAmount} INTEGER NOT NULL DEFAULT 0,
      ${SalesTable.fuelQuantity} REAL,
      ${SalesTable.remarks} TEXT,
      ${SalesTable.zamindarId} INTEGER,
      ${SalesTable.kisaanId} INTEGER,
      FOREIGN KEY (${SalesTable.zamindarId}) REFERENCES ${ZamindarTable.name}(${ZamindarTable.id})
        ON DELETE RESTRICT,
      FOREIGN KEY (${SalesTable.kisaanId}) REFERENCES ${KisaanTable.name}(${KisaanTable.id})
        ON DELETE SET NULL
    )
  ''';

  String _createSaleItemsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${SaleItemsTable.name} (
      ${SaleItemsTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${SaleItemsTable.invoiceNumber} TEXT NOT NULL,
      ${SaleItemsTable.productName} TEXT NOT NULL,
      ${SaleItemsTable.productType} TEXT NOT NULL,
      ${SaleItemsTable.quantity} INTEGER NOT NULL,
      ${SaleItemsTable.unitPrice} INTEGER NOT NULL,
      ${SaleItemsTable.seasonalIncrement} INTEGER NOT NULL DEFAULT 0,
      ${SaleItemsTable.itemDiscount} INTEGER NOT NULL DEFAULT 0,
      ${SaleItemsTable.subtotal} INTEGER NOT NULL,
      FOREIGN KEY (${SaleItemsTable.invoiceNumber}) REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
        ON DELETE CASCADE
    )
  ''';

  String _createPaymentsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${PaymentsTable.name} (
      ${PaymentsTable.paymentId} TEXT PRIMARY KEY,
      ${PaymentsTable.invoiceNumber} TEXT,
      ${PaymentsTable.dateTime} TEXT NOT NULL,
      ${PaymentsTable.zamindarId} INTEGER,
      ${PaymentsTable.kisaanId} INTEGER,
      ${PaymentsTable.amountPaid} INTEGER NOT NULL,
      ${PaymentsTable.paymentMethod} TEXT NOT NULL,
      ${PaymentsTable.season} TEXT NOT NULL,
      FOREIGN KEY (${PaymentsTable.invoiceNumber}) REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
        ON UPDATE CASCADE ON DELETE CASCADE,
      FOREIGN KEY (${PaymentsTable.zamindarId}) REFERENCES ${ZamindarTable.name}(${ZamindarTable.id})
        ON DELETE RESTRICT,
      FOREIGN KEY (${PaymentsTable.kisaanId}) REFERENCES ${KisaanTable.name}(${KisaanTable.id})
        ON DELETE SET NULL
    )
  ''';

  String _createStockMovementsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${StockMovementTable.name} (
      ${StockMovementTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${StockMovementTable.productId} INTEGER NOT NULL,
      ${StockMovementTable.movementType} TEXT NOT NULL,
      ${StockMovementTable.quantity} INTEGER NOT NULL,
      ${StockMovementTable.partyLabel} TEXT NOT NULL,
      ${StockMovementTable.referenceType} TEXT NOT NULL,
      ${StockMovementTable.referenceId} TEXT,
      ${StockMovementTable.dateTime} TEXT NOT NULL,
      ${StockMovementTable.notes} TEXT,
      FOREIGN KEY (${StockMovementTable.productId}) REFERENCES ${ProductTable.name}(${ProductTable.id})
        ON DELETE CASCADE
    )
  ''';

  String _createWholesalersTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${WholesalerTable.name} (
      ${WholesalerTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${WholesalerTable.nameColumn} TEXT NOT NULL,
      ${WholesalerTable.city} TEXT NOT NULL,
      ${WholesalerTable.phone} TEXT NOT NULL,
      ${WholesalerTable.balance} REAL NOT NULL DEFAULT 0
    )
  ''';

  String _createPurchaseInvoicesTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${PurchaseInvoicesTable.name} (
      ${PurchaseInvoicesTable.invoiceNumber} TEXT PRIMARY KEY,
      ${PurchaseInvoicesTable.wholesalerId} INTEGER NOT NULL,
      ${PurchaseInvoicesTable.dateTime} TEXT NOT NULL,
      ${PurchaseInvoicesTable.subtotal} INTEGER NOT NULL,
      ${PurchaseInvoicesTable.transportCharges} INTEGER NOT NULL DEFAULT 0,
      ${PurchaseInvoicesTable.grandTotal} INTEGER NOT NULL,
      ${PurchaseInvoicesTable.paymentType} TEXT NOT NULL,
      ${PurchaseInvoicesTable.amountPaid} INTEGER NOT NULL DEFAULT 0,
      ${PurchaseInvoicesTable.outstanding} INTEGER NOT NULL DEFAULT 0,
      ${PurchaseInvoicesTable.description} TEXT,
      FOREIGN KEY (${PurchaseInvoicesTable.wholesalerId})
        REFERENCES ${WholesalerTable.name}(${WholesalerTable.id})
    )
  ''';

  String _createPurchaseItemsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${PurchaseItemsTable.name} (
      ${PurchaseItemsTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${PurchaseItemsTable.invoiceNumber} TEXT NOT NULL,
      ${PurchaseItemsTable.productId} INTEGER,
      ${PurchaseItemsTable.productName} TEXT NOT NULL,
      ${PurchaseItemsTable.quantity} INTEGER NOT NULL,
      ${PurchaseItemsTable.purchaseRate} INTEGER NOT NULL,
      ${PurchaseItemsTable.expiryDate} TEXT,
      ${PurchaseItemsTable.lineTotal} INTEGER NOT NULL,
      FOREIGN KEY (${PurchaseItemsTable.invoiceNumber})
        REFERENCES ${PurchaseInvoicesTable.name}(${PurchaseInvoicesTable.invoiceNumber})
        ON DELETE CASCADE
    )
  ''';

  String _createWholesalerLedgerTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${WholesalerLedgerTable.name} (
      ${WholesalerLedgerTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${WholesalerLedgerTable.wholesalerId} INTEGER NOT NULL,
      ${WholesalerLedgerTable.transactionType} TEXT NOT NULL,
      ${WholesalerLedgerTable.referenceId} TEXT,
      ${WholesalerLedgerTable.date} TEXT NOT NULL,
      ${WholesalerLedgerTable.debit} INTEGER NOT NULL DEFAULT 0,
      ${WholesalerLedgerTable.credit} INTEGER NOT NULL DEFAULT 0,
      ${WholesalerLedgerTable.description} TEXT,
      FOREIGN KEY (${WholesalerLedgerTable.wholesalerId})
        REFERENCES ${WholesalerTable.name}(${WholesalerTable.id})
        ON DELETE CASCADE
    )
  ''';

  String _createWholesalerPaymentsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${WholesalerPaymentsTable.name} (
      ${WholesalerPaymentsTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${WholesalerPaymentsTable.wholesalerId} INTEGER NOT NULL,
      ${WholesalerPaymentsTable.amount} INTEGER NOT NULL,
      ${WholesalerPaymentsTable.paymentMethod} TEXT NOT NULL,
      ${WholesalerPaymentsTable.paymentSource} TEXT NOT NULL,
      ${WholesalerPaymentsTable.referenceNo} TEXT,
      ${WholesalerPaymentsTable.date} TEXT NOT NULL,
      ${WholesalerPaymentsTable.notes} TEXT,
      FOREIGN KEY (${WholesalerPaymentsTable.wholesalerId})
        REFERENCES ${WholesalerTable.name}(${WholesalerTable.id})
        ON DELETE CASCADE
    )
  ''';

  String _createExpensesTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${ExpenseTable.name} (
      ${ExpenseTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${ExpenseTable.category} TEXT NOT NULL,
      ${ExpenseTable.amount} REAL NOT NULL,
      ${ExpenseTable.remarks} TEXT,
      ${ExpenseTable.expenseDate} TEXT NOT NULL,
      ${ExpenseTable.employeeId} INTEGER,
      ${ExpenseTable.payrollType} TEXT
    )
  ''';

  String _createEmployeesTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${EmployeeTable.name} (
      ${EmployeeTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${EmployeeTable.nameColumn} TEXT NOT NULL,
      ${EmployeeTable.phone} TEXT,
      ${EmployeeTable.role} TEXT,
      ${EmployeeTable.salaryType} TEXT NOT NULL,
      ${EmployeeTable.baseSalary} REAL NOT NULL,
      ${EmployeeTable.createdAt} TEXT NOT NULL,
      ${EmployeeTable.isActive} INTEGER NOT NULL DEFAULT 1
    )
  ''';

  String _createEmployeeAttendanceTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${EmployeeAttendanceTable.name} (
      ${EmployeeAttendanceTable.attendanceId} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${EmployeeAttendanceTable.employeeId} INTEGER NOT NULL,
      ${EmployeeAttendanceTable.date} TEXT NOT NULL,
      ${EmployeeAttendanceTable.status} TEXT NOT NULL,
      UNIQUE(${EmployeeAttendanceTable.employeeId}, ${EmployeeAttendanceTable.date}),
      FOREIGN KEY (${EmployeeAttendanceTable.employeeId})
        REFERENCES ${EmployeeTable.name}(${EmployeeTable.id})
        ON DELETE CASCADE
    )
  ''';

  Future<void> _backfillStockMovementsFromSales(Database db) async {
    final existing = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${StockMovementTable.name}',
    );
    final count = (existing.first['c'] as num?)?.toInt() ?? 0;
    if (count > 0) return;

    final rows = await db.rawQuery('''
      SELECT
        p.${ProductTable.id} AS product_id,
        si.${SaleItemsTable.quantity} AS qty,
        z.${ZamindarTable.nameColumn} AS zamindar_name,
        s.${SalesTable.invoiceNumber} AS invoice_number,
        s.${SalesTable.dateTime} AS date_time,
        CASE
          WHEN z.${ZamindarTable.id} IS NULL THEN 'Walk-in Customer'
          ELSE z.${ZamindarTable.nameColumn}
        END AS party_label
      FROM ${SaleItemsTable.name} si
      INNER JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = si.${SaleItemsTable.invoiceNumber}
      INNER JOIN ${ProductTable.name} p
        ON p.${ProductTable.nameColumn} = si.${SaleItemsTable.productName}
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
      ORDER BY s.${SalesTable.dateTime} ASC
    ''');

    final batch = db.batch();
    for (final row in rows) {
      batch.insert(StockMovementTable.name, {
        StockMovementTable.productId: row['product_id'],
        StockMovementTable.movementType: StockMovementType.stockOut,
        StockMovementTable.quantity: (row['qty'] as num).toInt(),
        StockMovementTable.partyLabel: row['party_label'] as String,
        StockMovementTable.referenceType: StockMovementRef.sale,
        StockMovementTable.referenceId: row['invoice_number'] as String,
        StockMovementTable.dateTime: row['date_time'] as String,
        StockMovementTable.notes: null,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<void> _migratePaymentsTableNullableInvoice(
    Database db, {
    MigrationLog? log,
  }) async {
    final tableInfo = await db.rawQuery(
      'PRAGMA table_info(${PaymentsTable.name})',
    );
    final invoiceColumn = tableInfo.cast<Map<String, Object?>>().where(
      (col) => col['name'] == PaymentsTable.invoiceNumber,
    );
    if (invoiceColumn.isNotEmpty && invoiceColumn.first['notnull'] == 0) {
      log?.info('payments.invoice_number already nullable — skip');
      return;
    }

    final liveCols = {
      for (final row in tableInfo)
        if (row['name'] is String) row['name'] as String,
    };
    final hasName = liveCols.contains(PaymentsTable.zamindarName);
    final hasId = liveCols.contains(PaymentsTable.zamindarId);
    final salesCols = await tableExists(db, SalesTable.name)
        ? await tableColumnNames(db, SalesTable.name)
        : <String>{};

    final guard = await ForeignKeyGuard.enter(db);
    try {
      if (!hasName) {
        await rebuildTableWithSwap(
          db,
          TableSwapSpec(
            tableName: PaymentsTable.name,
            createNewTableSql: '''
              CREATE TABLE payments_new (
                ${PaymentsTable.paymentId} TEXT PRIMARY KEY,
                ${PaymentsTable.invoiceNumber} TEXT,
                ${PaymentsTable.dateTime} TEXT NOT NULL,
                ${PaymentsTable.zamindarId} INTEGER,
                ${PaymentsTable.kisaanId} INTEGER,
                ${PaymentsTable.amountPaid} REAL NOT NULL,
                ${PaymentsTable.paymentMethod} TEXT NOT NULL,
                ${PaymentsTable.season} TEXT NOT NULL
              )
            ''',
            copyColumns: const [
              PaymentsTable.paymentId,
              PaymentsTable.invoiceNumber,
              PaymentsTable.dateTime,
              PaymentsTable.zamindarId,
              PaymentsTable.kisaanId,
              PaymentsTable.amountPaid,
              PaymentsTable.paymentMethod,
              PaymentsTable.season,
            ],
            selectExpressions: {
              PaymentsTable.zamindarId: _sqlResolvePaymentZamindarId(
                hasPaymentId: hasId,
                salesCols: salesCols,
              ),
              PaymentsTable.kisaanId: _sqlResolvePaymentKisaanId(
                hasPaymentKisaanId: liveCols.contains(PaymentsTable.kisaanId),
                salesCols: salesCols,
              ),
            },
            dependentTriggers: const [
              'after_payment_insert',
              'after_payment_delete',
              'after_payment_update',
            ],
            recreateIndexSql: const [
              'CREATE INDEX IF NOT EXISTS idx_payments_invoice '
                  'ON payments(invoice_number)',
            ],
          ),
          log: log,
        );
        return;
      }

      await rebuildTableWithSwap(
        db,
        TableSwapSpec(
          tableName: PaymentsTable.name,
          createNewTableSql: '''
            CREATE TABLE payments_new (
              ${PaymentsTable.paymentId} TEXT PRIMARY KEY,
              ${PaymentsTable.invoiceNumber} TEXT,
              ${PaymentsTable.dateTime} TEXT NOT NULL,
              ${PaymentsTable.zamindarName} TEXT NOT NULL,
              ${PaymentsTable.kisaanName} TEXT,
              ${PaymentsTable.amountPaid} REAL NOT NULL,
              ${PaymentsTable.paymentMethod} TEXT NOT NULL,
              ${PaymentsTable.season} TEXT NOT NULL
            )
          ''',
          copyColumns: const [
            PaymentsTable.paymentId,
            PaymentsTable.invoiceNumber,
            PaymentsTable.dateTime,
            PaymentsTable.zamindarName,
            PaymentsTable.kisaanName,
            PaymentsTable.amountPaid,
            PaymentsTable.paymentMethod,
            PaymentsTable.season,
          ],
          selectExpressions: {
            PaymentsTable.zamindarName: _sqlResolvePaymentZamindarName(
              hasPaymentName: true,
              hasPaymentId: hasId,
              salesCols: salesCols,
            ),
          },
          dependentTriggers: const [
            'after_payment_insert',
            'after_payment_delete',
            'after_payment_update',
          ],
          recreateIndexSql: const [
            'CREATE INDEX IF NOT EXISTS idx_payments_invoice '
                'ON payments(invoice_number)',
          ],
        ),
        log: log,
      );
    } finally {
      await guard.exit();
    }
  }

  Future<void> _backfillAdvancePayments(Database db) async {
    final advanceRows = await db.query(
      LedgerTransactionTable.name,
      where:
          '${LedgerTransactionTable.category} = ? AND ${LedgerTransactionTable.description} = ? AND (${LedgerTransactionTable.paymentId} IS NULL OR ${LedgerTransactionTable.paymentId} = \'\')',
      whereArgs: ['ADVANCE_PAYMENT', 'Advance payment received'],
      orderBy: '${LedgerTransactionTable.dateTime} ASC',
    );

    final paymentCols = await tableColumnNames(db, PaymentsTable.name);
    final usesNames = paymentCols.contains(PaymentsTable.zamindarName);
    final usesIds = paymentCols.contains(PaymentsTable.zamindarId);

    for (final row in advanceRows) {
      final zamindarId = row[LedgerTransactionTable.zamindarId] as int?;
      if (zamindarId == null) continue;

      final zamindarRows = await db.query(
        ZamindarTable.name,
        columns: [ZamindarTable.nameColumn],
        where: '${ZamindarTable.id} = ?',
        whereArgs: [zamindarId],
        limit: 1,
      );
      if (zamindarRows.isEmpty) continue;

      final paymentId = await generateNextPaymentId(db, isAdvance: true);
      final dateTime = row[LedgerTransactionTable.dateTime] as String;
      final amount = (row[LedgerTransactionTable.amount] as num).round();
      final season = row[LedgerTransactionTable.season] as String;
      final zamindarName =
          zamindarRows.first[ZamindarTable.nameColumn] as String;

      final values = <String, Object?>{
        PaymentsTable.paymentId: paymentId,
        PaymentsTable.invoiceNumber: null,
        PaymentsTable.dateTime: dateTime,
        PaymentsTable.amountPaid: amount,
        PaymentsTable.paymentMethod: 'Cash',
        PaymentsTable.season: season,
      };
      if (usesIds) {
        values[PaymentsTable.zamindarId] = zamindarId;
        values[PaymentsTable.kisaanId] = null;
      }
      if (usesNames) {
        values[PaymentsTable.zamindarName] = zamindarName;
        values[PaymentsTable.kisaanName] = null;
      }
      // Extremely defensive: if schema has neither party column, skip insert.
      if (!usesIds && !usesNames) continue;

      await db.insert(PaymentsTable.name, values);

      await db.update(
        LedgerTransactionTable.name,
        {LedgerTransactionTable.paymentId: paymentId},
        where: '${LedgerTransactionTable.id} = ?',
        whereArgs: [row[LedgerTransactionTable.id]],
      );
    }
  }

  int _extractPaymentSequence(String paymentId, {required bool isAdvance}) {
    if (!_isCleanPaymentId(paymentId, isAdvance: isAdvance)) return 0;
    final prefix = isAdvance ? 'PAY-ADV-' : 'PAY-';
    return int.parse(paymentId.substring(prefix.length));
  }

  bool _isCleanPaymentId(String paymentId, {required bool isAdvance}) {
    final prefix = isAdvance ? 'PAY-ADV-' : 'PAY-';
    if (!paymentId.startsWith(prefix)) return false;
    final suffix = paymentId.substring(prefix.length);
    if (!RegExp(r'^\d+$').hasMatch(suffix)) return false;
    final seq = int.tryParse(suffix);
    if (seq == null) return false;
    return seq >= 1001 && seq <= 99999;
  }

  Future<void> _renamePaymentId(Database db, String oldId, String newId) async {
    if (oldId == newId) return;
    await db.update(
      LedgerTransactionTable.name,
      {LedgerTransactionTable.paymentId: newId},
      where: '${LedgerTransactionTable.paymentId} = ?',
      whereArgs: [oldId],
    );
    await db.update(
      PaymentsTable.name,
      {PaymentsTable.paymentId: newId},
      where: '${PaymentsTable.paymentId} = ?',
      whereArgs: [oldId],
    );
  }

  Future<void> _renumberLegacyPaymentIds(Database db) async {
    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await _renumberPaymentGroup(db, isAdvance: false);
      await _renumberPaymentGroup(db, isAdvance: true);
      await _seedPaymentSequences(db);
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }
  }

  Future<void> _renumberPaymentGroup(
    Database db, {
    required bool isAdvance,
  }) async {
    final prefix = isAdvance ? 'PAY-ADV-' : 'PAY-';
    final rows = await db.query(
      PaymentsTable.name,
      orderBy: '${PaymentsTable.dateTime} ASC, ${PaymentsTable.paymentId} ASC',
    );

    final groupRows = rows.where((row) {
      final id = row[PaymentsTable.paymentId] as String;
      final invoice = row[PaymentsTable.invoiceNumber] as String?;
      if (isAdvance) {
        return id.startsWith('PAY-ADV-') || invoice == null;
      }
      return !id.startsWith('PAY-ADV-') && invoice != null;
    }).toList();

    var maxCleanSeq = 1000;
    final legacyRows = <Map<String, dynamic>>[];

    for (final row in groupRows) {
      final id = row[PaymentsTable.paymentId] as String;
      if (_isCleanPaymentId(id, isAdvance: isAdvance)) {
        final seq = _extractPaymentSequence(id, isAdvance: isAdvance);
        if (seq > maxCleanSeq) maxCleanSeq = seq;
      } else {
        legacyRows.add(row);
      }
    }

    if (legacyRows.isEmpty) return;

    final tempMap = <String, String>{};
    for (var i = 0; i < legacyRows.length; i++) {
      final oldId = legacyRows[i][PaymentsTable.paymentId] as String;
      final tempId =
          '${isAdvance ? 'TMP-ADV' : 'TMP-PAY'}-$i-${oldId.hashCode.abs()}';
      tempMap[oldId] = tempId;
      await _renamePaymentId(db, oldId, tempId);
    }

    var seq = maxCleanSeq;
    for (final row in legacyRows) {
      final oldId = row[PaymentsTable.paymentId] as String;
      final tempId = tempMap[oldId]!;
      seq++;
      await _renamePaymentId(db, tempId, '$prefix$seq');
    }
  }

  /// Generates the next sequential receipt ID (starting at PAY-1001 / PAY-ADV-1001).
  Future<String> generateNextPaymentId(
    DatabaseExecutor executor, {
    required bool isAdvance,
  }) async {
    final key = isAdvance ? 'advance' : 'standard';
    final prefix = isAdvance ? 'PAY-ADV-' : 'PAY-';

    await executor.insert('payment_sequences', {
      'sequence_key': key,
      'last_value': 1000,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    await executor.rawUpdate(
      'UPDATE payment_sequences SET last_value = last_value + 1 WHERE sequence_key = ?',
      [key],
    );

    final rows = await executor.query(
      'payment_sequences',
      columns: ['last_value'],
      where: 'sequence_key = ?',
      whereArgs: [key],
      limit: 1,
    );

    final seq = rows.isEmpty ? 1001 : rows.first['last_value'] as int;
    return '$prefix$seq';
  }

  /// Returns distinct season labels that have ledger transaction data.
  Future<List<String>> getDistinctLedgerSeasons() async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT DISTINCT ${LedgerTransactionTable.season} AS season
      FROM ${LedgerTransactionTable.name}
      WHERE ${LedgerTransactionTable.season} IS NOT NULL
        AND TRIM(${LedgerTransactionTable.season}) != ''
      ORDER BY ${LedgerTransactionTable.season} DESC
    ''');

    return results
        .map((row) => row['season'] as String)
        .where((season) => season.trim().isNotEmpty)
        .toList();
  }

  // -----------------------------
  // Zamindar CRUD
  // -----------------------------

  Future<int> insertZamindar(Zamindar zamindar) async {
    final db = await database;
    final zamindarId = await db.insert(ZamindarTable.name, zamindar.toMap());

    // Auto-create 'Self' Kisaan for this Zamindar
    await db.insert(KisaanTable.name, {
      KisaanTable.zamindarId: zamindarId,
      KisaanTable.nameColumn: 'Self',
      KisaanTable.village: zamindar.village ?? zamindar.locationGoth ?? 'N/A',
      KisaanTable.phone: null,
      KisaanTable.landAcres: 0.0,
      KisaanTable.currentCrop: 'Direct Purchase',
    });

    notifyListeners();
    return zamindarId;
  }

  Future<Zamindar?> getZamindar(int id) async {
    final db = await database;
    final maps = await db.query(
      ZamindarTable.name,
      where: '${ZamindarTable.id} = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Zamindar.fromMap(maps.first);
  }

  Future<List<Zamindar>> getAllZamindars({bool descending = false}) async {
    final db = await database;
    final maps = await db.query(
      ZamindarTable.name,
      orderBy: '${ZamindarTable.id} ${descending ? 'DESC' : 'ASC'}',
    );
    return maps.map(Zamindar.fromMap).toList();
  }

  Future<int> updateZamindar(Zamindar zamindar) async {
    final db = await database;
    final result = await db.update(
      ZamindarTable.name,
      zamindar.toMap(),
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindar.id],
    );
    notifyListeners();
    return result;
  }

  Future<int> deleteZamindar(int id) async {
    final db = await database;
    final zamindar = await getZamindar(id);
    if (zamindar == null) return 0;

    final result = await db.transaction((txn) async {
      // Delete dependent sales/payments first (zamindar FKs are RESTRICT).
      await txn.delete(
        SalesTable.name,
        where: '${SalesTable.zamindarId} = ?',
        whereArgs: [id],
      );
      await txn.delete(
        PaymentsTable.name,
        where: '${PaymentsTable.zamindarId} = ?',
        whereArgs: [id],
      );
      await txn.delete(
        LedgerTransactionTable.name,
        where: '${LedgerTransactionTable.zamindarId} = ?',
        whereArgs: [id],
      );
      await txn.delete(
        KisaanTable.name,
        where: '${KisaanTable.zamindarId} = ?',
        whereArgs: [id],
      );
      return txn.delete(
        ZamindarTable.name,
        where: '${ZamindarTable.id} = ?',
        whereArgs: [id],
      );
    });

    notifyListeners();
    return result;
  }

  // -----------------------------
  // Kisaan CRUD
  // -----------------------------

  Future<int> insertKisaan(Kisaan kisaan) async {
    final db = await database;
    final result = await db.insert(KisaanTable.name, kisaan.toMap());
    notifyListeners();
    return result;
  }

  Future<Kisaan?> getKisaan(int id) async {
    final db = await database;
    final maps = await db.query(
      KisaanTable.name,
      where: '${KisaanTable.id} = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Kisaan.fromMap(maps.first);
  }

  Future<List<Kisaan>> getKisaansForZamindar(int zamindarId) async {
    final db = await database;
    final maps = await db.query(
      KisaanTable.name,
      where: '${KisaanTable.zamindarId} = ?',
      whereArgs: [zamindarId],
      orderBy: 'name ASC',
    );
    return maps.map(Kisaan.fromMap).toList();
  }

  /// Returns true if another Kisaan under this Zamindar already uses [name].
  /// Comparison ignores case and extra whitespace, so "Saleem Khan" and
  /// "saleem khan" are treated as the same. Pass [excludeKisaanId] when
  /// editing so the current record is ignored.
  Future<bool> kisaanNameExistsForZamindar({
    required int zamindarId,
    required String name,
    int? excludeKisaanId,
  }) async {
    final normalized = _normalizeKisaanName(name);
    if (normalized.isEmpty) return false;

    final existing = await getKisaansForZamindar(zamindarId);
    return existing.any((k) {
      if (excludeKisaanId != null && k.id == excludeKisaanId) return false;
      return _normalizeKisaanName(k.name) == normalized;
    });
  }

  static String _normalizeKisaanName(String name) {
    return name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<List<Kisaan>> getAllKisaans() async {
    final db = await database;
    final maps = await db.query(
      KisaanTable.name,
      orderBy: '${KisaanTable.id} ASC',
    );
    return maps.map(Kisaan.fromMap).toList();
  }

  Future<int> updateKisaan(Kisaan kisaan) async {
    final db = await database;
    final result = await db.update(
      KisaanTable.name,
      kisaan.toMap(),
      where: '${KisaanTable.id} = ?',
      whereArgs: [kisaan.id],
    );
    notifyListeners();
    return result;
  }

  Future<int> deleteKisaan(int id) async {
    final db = await database;
    final kisaan = await getKisaan(id);
    if (kisaan == null) return 0;

    final zamindar = await getZamindar(kisaan.zamindarId);
    if (zamindar == null) return 0;

    final result = await db.transaction((txn) async {
      await _purgeKisaanLinkedDataInTxn(
        txn,
        kisaanId: id,
        kisaanName: kisaan.name,
        zamindarName: zamindar.name,
      );
      return txn.delete(
        KisaanTable.name,
        where: '${KisaanTable.id} = ?',
        whereArgs: [id],
      );
    });

    notifyListeners();
    return result;
  }

  /// Removes all sales, payments, and ledger rows for a kisaan but keeps the record.
  Future<void> clearKisaanTransactionData(int id) async {
    final db = await database;
    final kisaan = await getKisaan(id);
    if (kisaan == null) return;

    final zamindar = await getZamindar(kisaan.zamindarId);
    if (zamindar == null) return;

    await db.transaction((txn) async {
      await _purgeKisaanLinkedDataInTxn(
        txn,
        kisaanId: id,
        kisaanName: kisaan.name,
        zamindarName: zamindar.name,
      );
    });

    notifyListeners();
  }

  Future<void> _purgeKisaanLinkedDataInTxn(
    Transaction txn, {
    required int kisaanId,
    required String kisaanName,
    required String zamindarName,
  }) async {
    final invoiceRows = await txn.query(
      SalesTable.name,
      columns: [SalesTable.invoiceNumber],
      where: '${SalesTable.kisaanId} = ?',
      whereArgs: [kisaanId],
    );
    for (final row in invoiceRows) {
      final invoiceNumber = row[SalesTable.invoiceNumber] as String;
      await txn.delete(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
    }

    await txn.delete(
      SalesTable.name,
      where: '${SalesTable.kisaanId} = ?',
      whereArgs: [kisaanId],
    );
    await txn.delete(
      PaymentsTable.name,
      where: '${PaymentsTable.kisaanId} = ?',
      whereArgs: [kisaanId],
    );
    await txn.delete(
      LedgerTransactionTable.name,
      where: '${LedgerTransactionTable.kisaanId} = ?',
      whereArgs: [kisaanId],
    );
  }

  // -----------------------------
  // Product CRUD
  // -----------------------------

  Future<int> insertProduct(ProductItem product) async {
    final db = await database;
    final result = await db.insert(ProductTable.name, product.toMap());
    if (product.availableStock > 0) {
      await _insertStockMovement(
        db,
        productId: result,
        movementType: StockMovementType.stockIn,
        quantity: product.availableStock,
        partyLabel: 'Stock Initialized',
        referenceType: StockMovementRef.create,
        dateTime: DateTime.now(),
      );
    }
    notifyListeners();
    return result;
  }

  Future<ProductItem?> getProduct(int id) async {
    final db = await database;
    final maps = await db.query(
      ProductTable.name,
      where: '${ProductTable.id} = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return ProductItem.fromMap(maps.first);
  }

  Future<List<ProductItem>> getAllProducts() async {
    final db = await database;
    final maps = await db.query(
      ProductTable.name,
      orderBy: '${ProductTable.nameColumn} ASC',
    );
    return maps.map(ProductItem.fromMap).toList();
  }

  /// Products currently sellable from shop inventory (`available_stock > 0`).
  Future<List<ProductItem>> getProductsInStock() async {
    final db = await database;
    final maps = await db.query(
      ProductTable.name,
      where: '${ProductTable.availableStock} > 0',
      orderBy: '${ProductTable.nameColumn} ASC',
    );
    return maps.map(ProductItem.fromMap).toList();
  }

  /// Aggregated line-item quantities this Kisaan already bought in [season].
  ///
  /// Each row: `{productName, productType, quantity}`.
  Future<List<Map<String, dynamic>>> getKisaanSeasonPurchaseLineItems({
    required String zamindarName,
    required String kisaanName,
    required String season,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT
        si.${SaleItemsTable.productName} AS product_name,
        si.${SaleItemsTable.productType} AS product_type,
        SUM(si.${SaleItemsTable.quantity}) AS total_qty
      FROM ${SaleItemsTable.name} si
      INNER JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = si.${SaleItemsTable.invoiceNumber}
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
      LEFT JOIN ${KisaanTable.name} k
        ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
      WHERE z.${ZamindarTable.nameColumn} = ?
        AND k.${KisaanTable.nameColumn} = ?
        AND s.${SalesTable.season} = ?
      GROUP BY si.${SaleItemsTable.productName}, si.${SaleItemsTable.productType}
      ''',
      [zamindarName, kisaanName, season],
    );

    return rows
        .map((row) {
          final name = (row['product_name'] as String?)?.trim() ?? '';
          if (name.isEmpty) return null;
          return <String, dynamic>{
            'productName': name,
            'productType': (row['product_type'] as String?)?.trim() ?? '',
            'quantity': (row['total_qty'] as num?)?.toDouble() ?? 0.0,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// Product line-items issued to all Kisaans under [zamindarId].
  ///
  /// One row per sale_items line (invoice, date, kisaan, product, qty, uom).
  /// Excludes cash/fuel advance placeholder lines.
  Future<List<ZamindarProductLedgerEntry>> getZamindarProductWiseLedgerEntries(
    int zamindarId,
  ) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT
        s.${SalesTable.invoiceNumber} AS invoice_number,
        s.${SalesTable.dateTime} AS date_time,
        COALESCE(
          NULLIF(TRIM(k.${KisaanTable.nameColumn}), ''),
          'Self'
        ) AS kisaan_name,
        si.${SaleItemsTable.productName} AS product_name,
        si.${SaleItemsTable.quantity} AS quantity,
        COALESCE(NULLIF(TRIM(p.${ProductTable.uom}), ''), 'Bags') AS uom
      FROM ${SaleItemsTable.name} si
      INNER JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = si.${SaleItemsTable.invoiceNumber}
      LEFT JOIN ${KisaanTable.name} k
        ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
      LEFT JOIN ${ProductTable.name} p
        ON p.${ProductTable.nameColumn} = si.${SaleItemsTable.productName}
      WHERE s.${SalesTable.zamindarId} = ?
        AND (
          s.${SalesTable.transactionType} IS NULL
          OR s.${SalesTable.transactionType} = ?
        )
        AND LOWER(TRIM(si.${SaleItemsTable.productType})) != 'advance'
        AND TRIM(si.${SaleItemsTable.productName}) != ''
      ORDER BY s.${SalesTable.dateTime} DESC, si.${SaleItemsTable.id} ASC
      ''',
      [zamindarId, SaleTransactionType.productSale],
    );

    return rows
        .map((row) {
          final productName =
              (row['product_name'] as String?)?.trim() ?? '';
          if (productName.isEmpty) return null;
          final kisaanRaw = (row['kisaan_name'] as String?)?.trim() ?? '';
          final uomRaw = (row['uom'] as String?)?.trim() ?? '';
          return ZamindarProductLedgerEntry(
            invoiceNumber:
                (row['invoice_number'] as String?)?.trim() ?? '',
            dateTime: _parseDateTime(row['date_time'] as String? ?? ''),
            kisaanName: kisaanRaw.isNotEmpty ? kisaanRaw : 'Self',
            productName: productName,
            quantity: (row['quantity'] as num?)?.round() ?? 0,
            uom: uomRaw.isNotEmpty ? uomRaw : 'Bags',
          );
        })
        .whereType<ZamindarProductLedgerEntry>()
        .toList();
  }

  Future<int> updateProduct(ProductItem product) async {
    final db = await database;
    final result = await db.update(
      ProductTable.name,
      product.toMap(),
      where: '${ProductTable.id} = ?',
      whereArgs: [product.id],
    );
    notifyListeners();
    return result;
  }

  /// Restocks a product and records a STOCK IN ledger entry.
  Future<void> restockProduct({
    required ProductItem product,
    required int addQuantity,
    required int newCostPrice,
  }) async {
    if (product.id == null) {
      throw ArgumentError('product.id is required to restock');
    }
    if (addQuantity <= 0) {
      throw ArgumentError('addQuantity must be positive');
    }

    final db = await database;
    await db.transaction((txn) async {
      final updated = ProductItem(
        id: product.id,
        name: product.name,
        brand: product.brand,
        productType: product.productType,
        packagingSize: product.packagingSize,
        costPrice: newCostPrice,
        retailPrice: product.retailPrice,
        seasonalIncrement: product.seasonalIncrement,
        availableStock: product.availableStock + addQuantity,
        uom: product.uom,
        expiryDate: product.expiryDate,
        lowStockThreshold: product.lowStockThreshold,
        description: product.description,
      );
      await txn.update(
        ProductTable.name,
        updated.toMap(),
        where: '${ProductTable.id} = ?',
        whereArgs: [product.id],
      );
      await _insertStockMovement(
        txn,
        productId: product.id!,
        movementType: StockMovementType.stockIn,
        quantity: addQuantity,
        partyLabel: 'Stock Added',
        referenceType: StockMovementRef.restock,
        dateTime: DateTime.now(),
        notes: 'Cost price set to Rs $newCostPrice',
      );
    });
    notifyListeners();
  }

  /// Records a manual stock adjustment when available qty is edited.
  Future<void> recordStockAdjustment({
    required int productId,
    required int previousStock,
    required int newStock,
  }) async {
    final delta = newStock - previousStock;
    if (delta == 0) return;

    final db = await database;
    await _insertStockMovement(
      db,
      productId: productId,
      movementType: delta > 0
          ? StockMovementType.stockIn
          : StockMovementType.stockOut,
      quantity: delta.abs(),
      partyLabel: 'Stock Adjusted',
      referenceType: StockMovementRef.adjust,
      dateTime: DateTime.now(),
    );
    notifyListeners();
  }

  Future<int> deleteProduct(int id) async {
    final db = await database;
    final result = await db.delete(
      ProductTable.name,
      where: '${ProductTable.id} = ?',
      whereArgs: [id],
    );
    notifyListeners();
    return result;
  }

  /// Aggregated stock inflows + outflows for a product, newest first.
  Future<List<ProductHistoryEntry>> getProductHistory(int productId) async {
    final db = await database;
    final product = await getProduct(productId);
    final uom = product?.uom ?? 'units';

    final rows = await db.query(
      StockMovementTable.name,
      where: '${StockMovementTable.productId} = ?',
      whereArgs: [productId],
      orderBy:
          '${StockMovementTable.dateTime} DESC, ${StockMovementTable.id} DESC',
    );

    return rows.map((row) {
      final type = row[StockMovementTable.movementType] as String;
      final qty = (row[StockMovementTable.quantity] as num).toInt();
      return ProductHistoryEntry(
        id: row[StockMovementTable.id] as int?,
        productId: productId,
        dateTime:
            DateTime.tryParse(
              row[StockMovementTable.dateTime] as String? ?? '',
            ) ??
            DateTime.now(),
        movementType: type,
        quantity: qty,
        uom: uom,
        partyLabel: row[StockMovementTable.partyLabel] as String? ?? '—',
        referenceType: row[StockMovementTable.referenceType] as String? ?? '',
        referenceId: row[StockMovementTable.referenceId] as String?,
        notes: row[StockMovementTable.notes] as String?,
      );
    }).toList();
  }

  Future<void> _insertStockMovement(
    DatabaseExecutor txn, {
    required int productId,
    required String movementType,
    required int quantity,
    required String partyLabel,
    required String referenceType,
    required DateTime dateTime,
    String? referenceId,
    String? notes,
  }) async {
    if (quantity <= 0) return;
    await txn.insert(StockMovementTable.name, {
      StockMovementTable.productId: productId,
      StockMovementTable.movementType: movementType,
      StockMovementTable.quantity: quantity,
      StockMovementTable.partyLabel: partyLabel,
      StockMovementTable.referenceType: referenceType,
      StockMovementTable.referenceId: referenceId,
      StockMovementTable.dateTime: _formatDateTime(dateTime),
      StockMovementTable.notes: notes,
    });
  }

  Future<String> _resolveSalePartyLabel(
    DatabaseExecutor txn,
    String zamindarName,
  ) async {
    final rows = await txn.query(
      ZamindarTable.name,
      columns: [ZamindarTable.id],
      where: '${ZamindarTable.nameColumn} = ?',
      whereArgs: [zamindarName],
      limit: 1,
    );
    if (rows.isEmpty) return 'Walk-in Customer';
    return zamindarName;
  }

  // -----------------------------
  // Ledger Transaction CRUD
  // -----------------------------

  Future<int> insertLedgerTransaction(LedgerTransaction transaction) async {
    final db = await database;
    final result = await db.insert(
      LedgerTransactionTable.name,
      transaction.toMap(),
    );
    notifyListeners();
    return result;
  }

  Future<LedgerTransaction?> getLedgerTransaction(int id) async {
    final db = await database;
    final maps = await db.query(
      LedgerTransactionTable.name,
      where: '${LedgerTransactionTable.id} = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return LedgerTransaction.fromMap(maps.first);
  }

  /// Unified ledger feed for a zamindar, including joined kisaan name.
  Future<List<Map<String, dynamic>>> getLedgerTransactions(
    int zamindarId, {
    int? limit,
  }) async {
    final db = await database;
    final limitClause = limit != null ? ' LIMIT $limit' : '';
    return db.rawQuery(
      '''
      SELECT lt.*, k.${KisaanTable.nameColumn} AS kisaan_name
      FROM ${LedgerTransactionTable.name} lt
      LEFT JOIN ${KisaanTable.name} k
        ON lt.${LedgerTransactionTable.kisaanId} = k.${KisaanTable.id}
      WHERE lt.${LedgerTransactionTable.zamindarId} = ?
      ORDER BY lt.${LedgerTransactionTable.dateTime} DESC$limitClause
    ''',
      [zamindarId],
    );
  }

  /// Seasons that actually appear on this zamindar's ledger rows.
  Future<List<String>> getDistinctSeasonsForZamindar(int zamindarId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT DISTINCT ${LedgerTransactionTable.season} AS season
      FROM ${LedgerTransactionTable.name}
      WHERE ${LedgerTransactionTable.zamindarId} = ?
        AND ${LedgerTransactionTable.season} IS NOT NULL
        AND TRIM(${LedgerTransactionTable.season}) != ''
      ORDER BY season ASC
      ''',
      [zamindarId],
    );
    return rows
        .map((row) => (row['season'] as String?)?.trim() ?? '')
        .where((season) => season.isNotEmpty)
        .toList();
  }

  /// Compact "Product xQty" summary for an invoice's sale line items.
  Future<String> getSaleItemsSummaryForInvoice(String invoiceNumber) async {
    if (invoiceNumber.trim().isEmpty) return '';
    final db = await database;
    final items = await db.query(
      SaleItemsTable.name,
      columns: [SaleItemsTable.productName, SaleItemsTable.quantity],
      where: '${SaleItemsTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
    );
    if (items.isEmpty) return '';
    return items
        .map((item) {
          final name = item[SaleItemsTable.productName] as String? ?? 'Item';
          final qty = item[SaleItemsTable.quantity];
          return '$name x$qty';
        })
        .join(', ');
  }

  /// Batch item summaries keyed by invoice number.
  Future<Map<String, String>> getSaleItemsSummariesForInvoices(
    Iterable<String> invoiceNumbers,
  ) async {
    final unique = invoiceNumbers
        .map((n) => n.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();
    if (unique.isEmpty) return {};

    final db = await database;
    final placeholders = List.filled(unique.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT ${SaleItemsTable.invoiceNumber},
             ${SaleItemsTable.productName},
             ${SaleItemsTable.quantity}
      FROM ${SaleItemsTable.name}
      WHERE ${SaleItemsTable.invoiceNumber} IN ($placeholders)
      ORDER BY ${SaleItemsTable.id} ASC
      ''', unique);

    final Map<String, List<String>> grouped = {};
    for (final row in rows) {
      final invoice = row[SaleItemsTable.invoiceNumber] as String? ?? '';
      if (invoice.isEmpty) continue;
      final name = row[SaleItemsTable.productName] as String? ?? 'Item';
      final qty = row[SaleItemsTable.quantity];
      grouped.putIfAbsent(invoice, () => []).add('$name x$qty');
    }

    return {
      for (final entry in grouped.entries) entry.key: entry.value.join(', '),
    };
  }

  /// Batch total payable + collected amounts keyed by invoice number.
  Future<Map<String, Map<String, double>>> getInvoiceCollectionSummaries(
    Iterable<String> invoiceNumbers,
  ) async {
    final unique = invoiceNumbers
        .map((n) => n.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();
    if (unique.isEmpty) return {};

    final db = await database;
    final placeholders = List.filled(unique.length, '?').join(',');
    final rows = await db.rawQuery(
      '''
      SELECT
        s.${SalesTable.invoiceNumber} AS invoice_number,
        s.${SalesTable.totalPayable} AS total,
        ($_sqlSaleCollectedExpr) AS paid
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.invoiceNumber} IN ($placeholders)
      ''',
      unique,
    );

    return {
      for (final row in rows)
        (row['invoice_number'] as String): {
          'total': (row['total'] as num?)?.toDouble() ?? 0.0,
          'paid': (row['paid'] as num?)?.toDouble() ?? 0.0,
        },
    };
  }

  Future<List<LedgerTransaction>> getLedgerTransactionsForZamindar(
    int zamindarId,
  ) async {
    final rows = await getLedgerTransactions(zamindarId);
    return rows.map(LedgerTransaction.fromMap).toList();
  }

  /// Sum of customer cash received (cash sales + udhar repayments),
  /// excluding upfront advance wallet deposits.
  /// Uses the same sales/payments aggregation as dashboard & balances.
  Future<int> getTotalPaymentsReceived(int zamindarId) async {
    final db = await database;
    final zamindarRows = await db.query(
      ZamindarTable.name,
      columns: [ZamindarTable.nameColumn],
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
      limit: 1,
    );
    if (zamindarRows.isEmpty) return 0;
    final zamindarName =
        zamindarRows.first[ZamindarTable.nameColumn] as String? ?? '';
    final totals = await _aggregateSalesBalancesForZamindarName(
      db,
      zamindarName,
    );
    return totals['totalPayments']!;
  }

  Future<List<LedgerTransaction>> getAllLedgerTransactions() async {
    final db = await database;
    final maps = await db.query(
      LedgerTransactionTable.name,
      orderBy: '${LedgerTransactionTable.dateTime} DESC',
    );

    debugPrint(
      'DATABASE DEBUG: getAllLedgerTransactions() fetched ${maps.length} raw rows',
    );
    if (maps.isNotEmpty) {
      debugPrint('DATABASE DEBUG: First transaction: ${maps.first}');
    }

    return maps.map(LedgerTransaction.fromMap).toList();
  }

  Future<int> updateLedgerTransaction(LedgerTransaction transaction) async {
    final db = await database;
    final result = await db.update(
      LedgerTransactionTable.name,
      transaction.toMap(),
      where: '${LedgerTransactionTable.id} = ?',
      whereArgs: [transaction.id],
    );
    notifyListeners();
    return result;
  }

  Future<int> deleteLedgerTransaction(int id) async {
    final db = await database;
    final result = await db.delete(
      LedgerTransactionTable.name,
      where: '${LedgerTransactionTable.id} = ?',
      whereArgs: [id],
    );
    notifyListeners();
    return result;
  }

  // -----------------------------
  // Business helper methods
  // -----------------------------

  /// Kisaan land is stored as Acre-equivalent (1 Athaas = 1/4 Acre).
  static double landAcresToUnit(double landAcres, String unit) {
    if (unit == 'Athaas') return landAcres / 4.0;
    return landAcres;
  }

  /// Converts a value entered in [unit] to Acre-equivalent for storage.
  static double landUnitToAcres(double value, String unit) {
    if (unit == 'Athaas') return value * 4.0;
    return value;
  }

  /// Calculates total land allocated to all Kisaans under a Zamindar.
  /// Returns the sum in Acre-equivalent (internal storage unit).
  /// Excludes a specific kisaan ID if provided (useful for edit validation).
  Future<double> getTotalAllocatedLandForZamindar(
    int zamindarId, {
    int? excludeKisaanId,
  }) async {
    final db = await database;
    final whereClause = excludeKisaanId == null
        ? '${KisaanTable.zamindarId} = ?'
        : '${KisaanTable.zamindarId} = ? AND ${KisaanTable.id} != ?';
    final whereArgs = excludeKisaanId == null
        ? [zamindarId]
        : [zamindarId, excludeKisaanId];

    final result = await db.rawQuery('''
        SELECT COALESCE(SUM(${KisaanTable.landAcres}), 0) AS total_land
        FROM ${KisaanTable.name}
        WHERE $whereClause
      ''', whereArgs);

    final totalLand = result.first['total_land'];
    if (totalLand is num) return totalLand.toDouble();
    return 0.0;
  }

  /// Land allocation totals expressed in the Zamindar's preferred [land_unit].
  Future<ZamindarLandAllocationSummary> getZamindarLandAllocationSummary(
    int zamindarId, {
    int? excludeKisaanId,
  }) async {
    final zamindar = await getZamindar(zamindarId);
    if (zamindar == null) {
      return const ZamindarLandAllocationSummary(
        totalLand: 0,
        allocatedLand: 0,
        remainingLand: 0,
        landUnit: 'Acre',
      );
    }

    final activeUnit = zamindar.landUnit;
    final allocatedInAcres = await getTotalAllocatedLandForZamindar(
      zamindarId,
      excludeKisaanId: excludeKisaanId,
    );
    final allocatedLand = landAcresToUnit(allocatedInAcres, activeUnit);
    final totalLand = zamindar.landArea;
    final remainingLand = totalLand - allocatedLand;

    return ZamindarLandAllocationSummary(
      totalLand: totalLand,
      allocatedLand: allocatedLand,
      remainingLand: remainingLand < 0 ? 0 : remainingLand,
      landUnit: activeUnit,
    );
  }

  /// Calculates total debits, total credits, outstanding balance,
  /// and whether the balance exceeds the zamindar's credit limit.
  /// Returns null when the zamindar does not exist.
  ///
  /// Uses the same live `sales` + `payments` aggregation as the dashboard
  /// and [recalculateZamindarBalance] — never a stale cached figure alone.
  Future<Map<String, Object>?> getZamindarBalancesSafe(int zamindarId) async {
    final db = await database;

    final zamindarRows = await db.query(
      ZamindarTable.name,
      columns: [ZamindarTable.creditLimit, ZamindarTable.nameColumn],
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
      limit: 1,
    );

    if (zamindarRows.isEmpty) return null;

    final creditLimit =
        (zamindarRows.first[ZamindarTable.creditLimit] as int?) ?? 0;
    final zamindarName =
        zamindarRows.first[ZamindarTable.nameColumn] as String? ?? '';

    final totals = await _aggregateSalesBalancesForZamindarName(
      db,
      zamindarName,
    );
    final totalSales = totals['totalSales']!;
    final totalPayments = totals['totalPayments']!;
    final outstandingBalance = totals['outstandingBalance']!;

    return {
      'totalSales': totalSales,
      'totalPayments': totalPayments,
      'totalDebits': totalSales,
      'outstandingBalance': outstandingBalance,
      'isOverLimit': outstandingBalance > creditLimit,
    };
  }

  /// Live SUM aggregation over sales/payments for one zamindar name.
  Future<Map<String, int>> _aggregateSalesBalancesForZamindarName(
    DatabaseExecutor db,
    String zamindarName,
  ) async {
    final id = await _resolveZamindarIdByName(db, zamindarName);
    if (id == null) {
      return {
        'totalSales': 0,
        'totalPayments': 0,
        'outstandingBalance': 0,
      };
    }
    return _aggregateSalesBalancesForZamindarId(db, id);
  }

  /// Recomputes `zamindars.current_balance` from invoices − collections.
  ///
  /// Formula: SUM(total_payable) − SUM(payments collected) across all sales
  /// for the zamindar (outstanding floored at 0). This is the single verified
  /// truth used after every invoice edit/delete.
  Future<int> recalculateZamindarBalance(int zamindarId) async {
    final db = await database;
    return _recalculateZamindarBalanceOn(db, zamindarId);
  }

  Future<int> _recalculateZamindarBalanceOn(
    DatabaseExecutor db,
    int zamindarId,
  ) async {
    final totals = await _aggregateSalesBalancesForZamindarId(db, zamindarId);
    final outstanding = totals['outstandingBalance']!;

    await db.update(
      ZamindarTable.name,
      {ZamindarTable.currentBalance: outstanding},
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
    );
    return outstanding;
  }

  Future<Map<String, int>> _aggregateSalesBalancesForZamindarId(
    DatabaseExecutor db,
    int zamindarId,
  ) async {
    final rows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(s.${SalesTable.totalPayable}), 0) AS total_sales,
        COALESCE(SUM($_sqlSaleCollectedExpr), 0) AS total_payments,
        COALESCE(SUM($_sqlSaleRemainingExpr), 0) AS outstanding
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.zamindarId} = ?
      ''',
      [zamindarId],
    );

    final totalSales = (rows.first['total_sales'] as num?)?.round() ?? 0;
    final totalPayments = (rows.first['total_payments'] as num?)?.round() ?? 0;
    final outstanding = (rows.first['outstanding'] as num?)?.round() ?? 0;
    return {
      'totalSales': totalSales,
      'totalPayments': totalPayments,
      'outstandingBalance': outstanding < 0 ? 0 : outstanding,
    };
  }

  Future<void> _recalculateAllZamindarBalances(DatabaseExecutor db) async {
    final rows = await db.query(
      ZamindarTable.name,
      columns: [ZamindarTable.id],
    );
    for (final row in rows) {
      final id = row[ZamindarTable.id] as int?;
      if (id != null) {
        await _recalculateZamindarBalanceOn(db, id);
      }
    }
  }

  Future<int?> _resolveZamindarIdByName(
    DatabaseExecutor db,
    String zamindarName,
  ) async {
    final rows = await db.query(
      ZamindarTable.name,
      columns: [ZamindarTable.id],
      where: '${ZamindarTable.nameColumn} = ?',
      whereArgs: [zamindarName],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first[ZamindarTable.id] as int?;
  }

  Future<Map<String, Object>> getZamindarBalances(int zamindarId) async {
    final balances = await getZamindarBalancesSafe(zamindarId);
    if (balances == null) {
      throw ArgumentError('Zamindar with id $zamindarId was not found.');
    }
    return balances;
  }

  /// Centralized formatted outstanding balance for all Zamindar UI screens.
  Future<String> getOutstandingBalanceString(int zamindarId) async {
    final balances = await getZamindarBalancesSafe(zamindarId);
    if (balances == null) return "Rs. 0";
    final int outstanding = balances['outstandingBalance'] as int? ?? 0;
    return "Rs. ${_indianCurrencyFormat.format(outstanding)}";
  }

  Future<int> countKisaansForZamindar(int zamindarId) async {
    final db = await database;
    final result = await db.rawQuery(
      '''
        SELECT COUNT(*) AS count
        FROM ${KisaanTable.name}
        WHERE ${KisaanTable.zamindarId} = ?
      ''',
      [zamindarId],
    );
    return _readIntValue(result.first['count']);
  }

  Future<double> getKisaanBalanceDue(int kisaanId) async {
    final kisaan = await getKisaan(kisaanId);
    if (kisaan == null) return 0.0;
    return getKisaanSalesOutstandingDebt(
      zamindarId: kisaan.zamindarId,
      kisaanName: kisaan.name,
    );
  }

  /// Latest sale (purchase) date per Kisaan under [zamindarId].
  /// Missing kisaans / no sales → absent from the map.
  Future<Map<int, DateTime>> getLastPurchaseDatesForZamindar(
    int zamindarId,
  ) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT
        ${SalesTable.kisaanId} AS kisaan_id,
        MAX(${SalesTable.dateTime}) AS last_purchase
      FROM ${SalesTable.name}
      WHERE ${SalesTable.zamindarId} = ?
        AND ${SalesTable.kisaanId} IS NOT NULL
      GROUP BY ${SalesTable.kisaanId}
      ''',
      [zamindarId],
    );

    final Map<int, DateTime> result = {};
    for (final row in rows) {
      final idRaw = row['kisaan_id'];
      final id = idRaw is int
          ? idRaw
          : (idRaw is num ? idRaw.toInt() : int.tryParse('$idRaw'));
      final raw = row['last_purchase']?.toString();
      if (id == null || raw == null || raw.isEmpty) continue;
      try {
        result[id] = DateTime.parse(raw);
      } catch (_) {}
    }
    return result;
  }

  Future<Zamindar> enrichZamindar(Zamindar zamindar) async {
    if (zamindar.id == null) return zamindar;

    final balances = await getZamindarBalancesSafe(zamindar.id!);
    final activeKisaans = await countKisaansForZamindar(zamindar.id!);

    return zamindar.copyWith(
      udhaarBalance: (balances?['outstandingBalance'] as int? ?? 0).toDouble(),
      activeKisaans: activeKisaans,
      isOverLimit: balances?['isOverLimit'] as bool? ?? false,
    );
  }

  Future<List<Zamindar>> getAllZamindarsEnriched({
    bool descending = false,
  }) async {
    final zamindars = await getAllZamindars(descending: descending);
    final enriched = <Zamindar>[];
    for (final zamindar in zamindars) {
      enriched.add(await enrichZamindar(zamindar));
    }
    return enriched;
  }

  /// Persists a sale: ledger entries and stock decrements in one transaction.
  Future<void> processSale({
    required int zamindarId,
    int? kisaanId,
    required List<SaleLineItem> items,
    required int globalDiscount,
    required bool isCredit,
    required String season,
    required DateTime dateTime,
  }) async {
    if (items.isEmpty) return;

    final db = await database;
    await db.transaction((txn) async {
      final gross = items.fold<int>(
        0,
        (sum, item) => sum + (item.qty * item.unitPrice).round(),
      );
      final itemDiscounts = items.fold<int>(
        0,
        (sum, item) => sum + item.discount.round(),
      );
      final netAmount = (gross - itemDiscounts - globalDiscount).clamp(
        0,
        1 << 31,
      );

      final description = items
          .map((i) => '${i.productName} x${i.qty}')
          .join(' · ');

      await txn.insert(LedgerTransactionTable.name, {
        LedgerTransactionTable.zamindarId: zamindarId,
        LedgerTransactionTable.kisaanId: kisaanId,
        LedgerTransactionTable.type: LedgerTransactionType.debit,
        LedgerTransactionTable.category: 'SALE',
        LedgerTransactionTable.description: description,
        LedgerTransactionTable.amount: netAmount,
        LedgerTransactionTable.dateTime: _formatDateTime(dateTime),
        LedgerTransactionTable.season: season,
      });

      debugPrint(
        'DATABASE DEBUG: Inserted SALE transaction - season="$season", amount=$netAmount, dateTime=${_formatDateTime(dateTime)}',
      );

      if (!isCredit) {
        await txn.insert(LedgerTransactionTable.name, {
          LedgerTransactionTable.zamindarId: zamindarId,
          LedgerTransactionTable.kisaanId: kisaanId,
          LedgerTransactionTable.type: LedgerTransactionType.credit,
          LedgerTransactionTable.category: 'CASH_PAYMENT',
          LedgerTransactionTable.description: 'Cash payment for sale',
          LedgerTransactionTable.amount: netAmount,
          LedgerTransactionTable.dateTime: _formatDateTime(dateTime),
          LedgerTransactionTable.season: season,
        });
      }

      for (final item in items) {
        if (item.productId == null) continue;
        final rows = await txn.query(
          ProductTable.name,
          columns: [ProductTable.availableStock],
          where: '${ProductTable.id} = ?',
          whereArgs: [item.productId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final currentStock = _readIntValue(
          rows.first[ProductTable.availableStock],
        );
        final nextStock = (currentStock - item.qty.ceil()).clamp(0, 1 << 31);
        await txn.update(
          ProductTable.name,
          {ProductTable.availableStock: nextStock},
          where: '${ProductTable.id} = ?',
          whereArgs: [item.productId],
        );
      }
    });

    // Notify listeners that database has changed
    notifyListeners();
  }

  /// Gets the next invoice number by querying the latest invoice from the sales table
  /// Returns a String in format 'INV-XXXX' (e.g., 'INV-1000', 'INV-1001', etc.)
  /// This method is thread-safe and always returns a unique invoice number
  Future<String> getNextInvoiceNumber() async {
    final db = await database;

    // Fetch the latest invoice by sorting descending
    final maps = await db.query(
      SalesTable.name,
      columns: [SalesTable.invoiceNumber],
      orderBy: 'ROWID DESC',
      limit: 1,
    );

    if (maps.isEmpty) {
      return 'INV-1000'; // Default baseline for a completely clean DB
    }

    final latestInvoice = maps.first[SalesTable.invoiceNumber] as String;

    // Extract digits using a regular expression (e.g., "INV-1024" -> "1024")
    final numMatch = RegExp(r'\d+').stringMatch(latestInvoice);
    if (numMatch != null) {
      final nextNum = int.parse(numMatch) + 1;
      return 'INV-$nextNum';
    }

    // Fallback if parsing fails
    return 'INV-1000';
  }

  // ---------------------------------------------------------------------------
  // Wholesalers
  // ---------------------------------------------------------------------------

  Future<List<DbWholesaler>> getAllWholesalers() async {
    final db = await database;
    final maps = await db.query(
      WholesalerTable.name,
      orderBy: '${WholesalerTable.nameColumn} COLLATE NOCASE ASC',
    );
    return maps.map(DbWholesaler.fromMap).toList();
  }

  Future<DbWholesaler?> getWholesaler(int id) async {
    final db = await database;
    final maps = await db.query(
      WholesalerTable.name,
      where: '${WholesalerTable.id} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return DbWholesaler.fromMap(maps.first);
  }

  Future<int> insertWholesaler(DbWholesaler wholesaler) async {
    final db = await database;
    late final int id;
    await db.transaction((txn) async {
      id = await txn.insert(WholesalerTable.name, wholesaler.toMap());
      if (wholesaler.balance > 0) {
        // Opening balance is not a purchase_invoice — write ledger directly.
        await _insertWholesalerLedgerEntry(
          txn,
          wholesalerId: id,
          transactionType: WholesalerLedgerTxnType.purchase,
          referenceId: 'OPENING',
          date: DateTime.now(),
          debit: wholesaler.balance,
          credit: 0,
          description: 'Opening balance',
        );
      }
    });
    notifyListeners();
    return id;
  }

  Future<int> updateWholesaler(DbWholesaler wholesaler) async {
    if (wholesaler.id == null) {
      throw ArgumentError('Wholesaler id is required for update');
    }
    final db = await database;
    final result = await db.update(
      WholesalerTable.name,
      wholesaler.toMap(),
      where: '${WholesalerTable.id} = ?',
      whereArgs: [wholesaler.id],
    );
    notifyListeners();
    return result;
  }

  /// Inserts a shop operating expense with the current timestamp.
  Future<int> insertExpense(
    String category,
    double amount,
    String remarks,
  ) async {
    final trimmedCategory = category.trim();
    if (trimmedCategory.isEmpty) {
      throw ArgumentError('Expense category is required');
    }
    if (amount <= 0) {
      throw ArgumentError('Expense amount must be greater than zero');
    }

    final db = await database;
    await _ensureExpensesSchema(db);
    final id = await db.insert(ExpenseTable.name, {
      ExpenseTable.category: trimmedCategory,
      ExpenseTable.amount: amount,
      ExpenseTable.remarks: remarks.trim(),
      ExpenseTable.expenseDate: _formatDateTime(DateTime.now()),
    });
    notifyListeners();
    return id;
  }

  /// Fetches expenses for [filterType]: `Today`, `This Month`, or `All`/`All Time`.
  Future<List<DbExpense>> getExpensesFilter({
    String filterType = 'All',
  }) async {
    final db = await database;
    await _ensureExpensesSchema(db);

    final now = DateTime.now();
    final normalized = filterType.trim().toLowerCase();
    String? where;
    List<Object?>? whereArgs;

    if (normalized == 'today') {
      final start = DateTime(now.year, now.month, now.day);
      final end = start.add(const Duration(days: 1));
      where =
          '${ExpenseTable.expenseDate} >= ? AND ${ExpenseTable.expenseDate} < ?';
      whereArgs = [_formatDateTime(start), _formatDateTime(end)];
    } else if (normalized == 'this month') {
      final start = DateTime(now.year, now.month, 1);
      final end = now.month == 12
          ? DateTime(now.year + 1, 1, 1)
          : DateTime(now.year, now.month + 1, 1);
      where =
          '${ExpenseTable.expenseDate} >= ? AND ${ExpenseTable.expenseDate} < ?';
      whereArgs = [_formatDateTime(start), _formatDateTime(end)];
    }

    final maps = await db.query(
      ExpenseTable.name,
      where: where,
      whereArgs: whereArgs,
      orderBy:
          '${ExpenseTable.expenseDate} DESC, ${ExpenseTable.id} DESC',
    );
    return maps.map(DbExpense.fromMap).toList();
  }

  // ---------------------------------------------------------------------------
  // Employees & attendance
  // ---------------------------------------------------------------------------

  Future<int> insertEmployee({
    required String name,
    String phone = '',
    String role = '',
    required String salaryType,
    required double baseSalary,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Employee name is required');
    }
    final normalizedType = salaryType.trim().toLowerCase();
    if (normalizedType != EmployeeSalaryType.monthly &&
        normalizedType != EmployeeSalaryType.daily) {
      throw ArgumentError("salary_type must be 'monthly' or 'daily'");
    }
    if (baseSalary < 0) {
      throw ArgumentError('Base salary cannot be negative');
    }

    final db = await database;
    await _ensureEmployeeSchema(db);
    final id = await db.insert(EmployeeTable.name, {
      EmployeeTable.nameColumn: trimmed,
      EmployeeTable.phone: phone.trim(),
      EmployeeTable.role: role.trim(),
      EmployeeTable.salaryType: normalizedType,
      EmployeeTable.baseSalary: baseSalary,
      EmployeeTable.createdAt: _formatDateTime(DateTime.now()),
      EmployeeTable.isActive: 1,
    });
    notifyListeners();
    return id;
  }

  Future<int> updateEmployee(DbEmployee employee) async {
    if (employee.id == null) {
      throw ArgumentError('Employee id is required for update');
    }
    final db = await database;
    await _ensureEmployeeSchema(db);
    final result = await db.update(
      EmployeeTable.name,
      employee.toMap(),
      where: '${EmployeeTable.id} = ?',
      whereArgs: [employee.id],
    );
    notifyListeners();
    return result;
  }

  Future<int> setEmployeeActive(int employeeId, bool isActive) async {
    final db = await database;
    await _ensureEmployeeSchema(db);
    final result = await db.update(
      EmployeeTable.name,
      {EmployeeTable.isActive: isActive ? 1 : 0},
      where: '${EmployeeTable.id} = ?',
      whereArgs: [employeeId],
    );
    notifyListeners();
    return result;
  }

  Future<List<DbEmployee>> getEmployees({bool activeOnly = true}) async {
    final db = await database;
    await _ensureEmployeeSchema(db);
    final maps = await db.query(
      EmployeeTable.name,
      where: activeOnly ? '${EmployeeTable.isActive} = 1' : null,
      orderBy: '${EmployeeTable.nameColumn} COLLATE NOCASE ASC',
    );
    return maps.map(DbEmployee.fromMap).toList();
  }

  Future<DbEmployee?> getEmployeeById(int id) async {
    final db = await database;
    await _ensureEmployeeSchema(db);
    final maps = await db.query(
      EmployeeTable.name,
      where: '${EmployeeTable.id} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return DbEmployee.fromMap(maps.first);
  }

  /// Upserts attendance for [date] (`YYYY-MM-DD`). Pass null [status] to clear
  /// (Unmarked — deletes any existing row).
  Future<void> setAttendanceStatus({
    required int employeeId,
    required String date,
    String? status,
  }) async {
    final normalizedDate = date.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(normalizedDate)) {
      throw ArgumentError('date must be YYYY-MM-DD');
    }

    final db = await database;
    await _ensureEmployeeSchema(db);

    await db.transaction((txn) async {
      if (status == null || status.trim().isEmpty) {
        await txn.delete(
          EmployeeAttendanceTable.name,
          where:
              '${EmployeeAttendanceTable.employeeId} = ? AND ${EmployeeAttendanceTable.date} = ?',
          whereArgs: [employeeId, normalizedDate],
        );
        return;
      }

      final normalizedStatus = status.trim().toUpperCase();
      if (normalizedStatus != AttendanceStatus.present &&
          normalizedStatus != AttendanceStatus.absent &&
          normalizedStatus != AttendanceStatus.halfDay) {
        throw ArgumentError(
          "status must be PRESENT, ABSENT, HALF_DAY, or unmarked",
        );
      }

      final existing = await txn.query(
        EmployeeAttendanceTable.name,
        columns: [EmployeeAttendanceTable.attendanceId],
        where:
            '${EmployeeAttendanceTable.employeeId} = ? AND ${EmployeeAttendanceTable.date} = ?',
        whereArgs: [employeeId, normalizedDate],
        limit: 1,
      );

      if (existing.isEmpty) {
        await txn.insert(EmployeeAttendanceTable.name, {
          EmployeeAttendanceTable.employeeId: employeeId,
          EmployeeAttendanceTable.date: normalizedDate,
          EmployeeAttendanceTable.status: normalizedStatus,
        });
      } else {
        await txn.update(
          EmployeeAttendanceTable.name,
          {EmployeeAttendanceTable.status: normalizedStatus},
          where: '${EmployeeAttendanceTable.attendanceId} = ?',
          whereArgs: [existing.first[EmployeeAttendanceTable.attendanceId]],
        );
      }
    });
    notifyListeners();
  }

  Future<Map<int, String>> getAttendanceForDate(String date) async {
    final db = await database;
    await _ensureEmployeeSchema(db);
    final rows = await db.query(
      EmployeeAttendanceTable.name,
      where: '${EmployeeAttendanceTable.date} = ?',
      whereArgs: [date.trim()],
    );
    final map = <int, String>{};
    for (final row in rows) {
      final id = row[EmployeeAttendanceTable.employeeId] as int?;
      final status = row[EmployeeAttendanceTable.status] as String?;
      if (id != null && status != null) map[id] = status;
    }
    return map;
  }

  Future<List<DbAttendance>> getEmployeeAttendanceForMonth({
    required int employeeId,
    required int year,
    required int month,
  }) async {
    final db = await database;
    await _ensureEmployeeSchema(db);
    final start = _formatDateOnly(DateTime(year, month, 1));
    final endExclusive = _formatDateOnly(
      month == 12 ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1),
    );
    final rows = await db.query(
      EmployeeAttendanceTable.name,
      where:
          '${EmployeeAttendanceTable.employeeId} = ? AND ${EmployeeAttendanceTable.date} >= ? AND ${EmployeeAttendanceTable.date} < ?',
      whereArgs: [employeeId, start, endExclusive],
      orderBy: '${EmployeeAttendanceTable.date} ASC',
    );
    return rows.map(DbAttendance.fromMap).toList();
  }

  /// Records Kharchi/Advance as an expense linked to [employeeId].
  Future<int> recordEmployeeKharchi({
    required int employeeId,
    required double amount,
    String remarks = '',
    DateTime? date,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('Kharchi amount must be greater than zero');
    }
    final employee = await getEmployeeById(employeeId);
    if (employee == null) {
      throw ArgumentError('Employee not found');
    }

    final db = await database;
    await _ensureEmployeeSchema(db);
    final note = remarks.trim().isEmpty
        ? 'Kharchi/Advance — ${employee.name}'
        : 'Kharchi/Advance — ${employee.name}: ${remarks.trim()}';
    final id = await db.insert(ExpenseTable.name, {
      ExpenseTable.category: 'Employee Salaries',
      ExpenseTable.amount: amount,
      ExpenseTable.remarks: note,
      ExpenseTable.expenseDate: _formatDateTime(date ?? DateTime.now()),
      ExpenseTable.employeeId: employeeId,
      ExpenseTable.payrollType: ExpensePayrollType.kharchi,
    });
    notifyListeners();
    return id;
  }

  /// Settles the month: logs net payable as expense and closes the balance.
  Future<int> settleEmployeeMonthlySalary({
    required int employeeId,
    required int year,
    required int month,
  }) async {
    final payroll = await getEmployeeMonthPayroll(
      employeeId: employeeId,
      year: year,
      month: month,
    );
    if (payroll.isSettled) {
      throw StateError('This month is already settled');
    }

    final net = payroll.netRemaining;
    final employee = payroll.employee;
    final monthLabel = DateFormat('MMM yyyy').format(DateTime(year, month));
    final db = await database;
    await _ensureEmployeeSchema(db);

    late final int expenseId;
    await db.transaction((txn) async {
      // Amount can be 0 when advances already covered earnings.
      expenseId = await txn.insert(ExpenseTable.name, {
        ExpenseTable.category: 'Employee Salaries',
        ExpenseTable.amount: net > 0 ? net : 0,
        ExpenseTable.remarks:
            'Salary settlement $monthLabel — ${employee.name}'
            '${net <= 0 ? ' (no payout; advances covered earnings)' : ''}',
        ExpenseTable.expenseDate: _formatDateTime(DateTime.now()),
        ExpenseTable.employeeId: employeeId,
        ExpenseTable.payrollType: ExpensePayrollType.settlement,
      });
    });
    notifyListeners();
    return expenseId;
  }

  Future<List<DbExpense>> getEmployeePayrollExpenses({
    required int employeeId,
    required int year,
    required int month,
  }) async {
    final db = await database;
    await _ensureEmployeeSchema(db);
    final start = DateTime(year, month, 1);
    final end = month == 12
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    final maps = await db.query(
      ExpenseTable.name,
      where:
          '${ExpenseTable.employeeId} = ? AND ${ExpenseTable.expenseDate} >= ? AND ${ExpenseTable.expenseDate} < ?',
      whereArgs: [
        employeeId,
        _formatDateTime(start),
        _formatDateTime(end),
      ],
      orderBy:
          '${ExpenseTable.expenseDate} DESC, ${ExpenseTable.id} DESC',
    );
    return maps.map(DbExpense.fromMap).toList();
  }

  Future<EmployeeMonthPayroll> getEmployeeMonthPayroll({
    required int employeeId,
    required int year,
    required int month,
  }) async {
    final employee = await getEmployeeById(employeeId);
    if (employee == null) {
      throw ArgumentError('Employee not found');
    }

    final attendance = await getEmployeeAttendanceForMonth(
      employeeId: employeeId,
      year: year,
      month: month,
    );
    final expenses = await getEmployeePayrollExpenses(
      employeeId: employeeId,
      year: year,
      month: month,
    );

    var present = 0;
    var absent = 0;
    var half = 0;
    for (final row in attendance) {
      switch (row.status) {
        case AttendanceStatus.present:
          present++;
          break;
        case AttendanceStatus.absent:
          absent++;
          break;
        case AttendanceStatus.halfDay:
          half++;
          break;
      }
    }

    final daysInMonth = DateTime(year, month + 1, 0).day;
    final unmarked = daysInMonth - present - absent - half;
    final paidUnits = present + (half * 0.5);
    final dailyRate = employee.isDaily
        ? employee.baseSalary
        : (daysInMonth > 0 ? employee.baseSalary / daysInMonth : 0.0);
    final earned = paidUnits * dailyRate;

    var kharchi = 0.0;
    var settlements = 0.0;
    var isSettled = false;
    for (final e in expenses) {
      if (e.payrollType == ExpensePayrollType.kharchi) {
        kharchi += e.amount;
      } else if (e.payrollType == ExpensePayrollType.settlement) {
        settlements += e.amount;
        isSettled = true;
      }
    }

    // Before settlement: net = earned - kharchi.
    // After settlement: remaining payable is effectively closed.
    final net = isSettled ? 0.0 : (earned - kharchi);

    return EmployeeMonthPayroll(
      employee: employee,
      year: year,
      month: month,
      presentDays: present,
      absentDays: absent,
      halfDays: half,
      unmarkedDays: unmarked < 0 ? 0 : unmarked,
      baseSalary: employee.baseSalary,
      earnedAmount: earned,
      kharchiTotal: kharchi,
      settlementTotal: settlements,
      netRemaining: net,
      isSettled: isSettled,
      attendance: attendance,
      payrollExpenses: expenses,
    );
  }

  /// Khata statement rows for a wholesaler, newest first.
  Future<List<Map<String, dynamic>>> fetchWholesalerLedger(
    int wholesalerId,
  ) async {
    final db = await database;
    await _ensureWholesalerLedgerSchema(db);
    final rows = await db.rawQuery(
      '''
      SELECT
        wl.*,
        SUM(wl.${WholesalerLedgerTable.debit} - wl.${WholesalerLedgerTable.credit})
          OVER (
            PARTITION BY wl.${WholesalerLedgerTable.wholesalerId}
            ORDER BY wl.${WholesalerLedgerTable.date} ASC,
                     wl.${WholesalerLedgerTable.id} ASC
          ) AS ${WholesalerLedgerTable.runningBalance}
      FROM ${WholesalerLedgerTable.name} wl
      WHERE wl.${WholesalerLedgerTable.wholesalerId} = ?
      ORDER BY wl.${WholesalerLedgerTable.date} DESC,
               wl.${WholesalerLedgerTable.id} DESC
      ''',
      [wholesalerId],
    );
    debugPrint('fetchWholesalerLedger($wholesalerId) -> ${rows.length} row(s)');
    return rows;
  }

  Future<void> _insertWholesalerLedgerEntry(
    DatabaseExecutor txn, {
    required int wholesalerId,
    required String transactionType,
    required String? referenceId,
    required DateTime date,
    required double debit,
    required double credit,
    String? description,
  }) async {
    await txn.insert(WholesalerLedgerTable.name, {
      WholesalerLedgerTable.wholesalerId: wholesalerId,
      WholesalerLedgerTable.transactionType: transactionType,
      WholesalerLedgerTable.referenceId: referenceId,
      WholesalerLedgerTable.date: _formatDateTime(date),
      WholesalerLedgerTable.debit: debit.round(),
      WholesalerLedgerTable.credit: credit.round(),
      if (description != null && description.trim().isNotEmpty)
        WholesalerLedgerTable.description: description.trim(),
    });
  }

  Future<void> _insertWholesalerPaymentRow(
    DatabaseExecutor txn, {
    required int wholesalerId,
    required double amount,
    required String paymentMethod,
    required String paymentSource,
    required String? referenceNo,
    required DateTime date,
    String notes = '',
  }) async {
    await txn.insert(WholesalerPaymentsTable.name, {
      WholesalerPaymentsTable.wholesalerId: wholesalerId,
      WholesalerPaymentsTable.amount: amount.round(),
      WholesalerPaymentsTable.paymentMethod: paymentMethod,
      WholesalerPaymentsTable.paymentSource: paymentSource,
      WholesalerPaymentsTable.referenceNo: referenceNo,
      WholesalerPaymentsTable.date: _formatDateTime(date),
      WholesalerPaymentsTable.notes: notes.isEmpty ? null : notes,
    });
  }

  /// Bulk purchase invoices for a wholesaler, newest first.
  Future<List<Map<String, dynamic>>> fetchWholesalerPurchases(
    int wholesalerId,
  ) async {
    final db = await database;
    return db.rawQuery(
      'SELECT * FROM ${PurchaseInvoicesTable.name} '
      'WHERE ${PurchaseInvoicesTable.wholesalerId} = ? '
      'ORDER BY ${PurchaseInvoicesTable.dateTime} DESC, '
      '${PurchaseInvoicesTable.invoiceNumber} DESC',
      [wholesalerId],
    );
  }

  /// Line items for a single purchase invoice.
  Future<List<Map<String, dynamic>>> fetchPurchaseItems(
    String invoiceNumber,
  ) async {
    final db = await database;
    return db.query(
      PurchaseItemsTable.name,
      where: '${PurchaseItemsTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
      orderBy: '${PurchaseItemsTable.id} ASC',
    );
  }

  /// All purchase line items for a wholesaler, grouped by invoice number.
  Future<Map<String, List<Map<String, dynamic>>>>
  fetchWholesalerPurchaseItemsGrouped(int wholesalerId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT pi_items.*
      FROM ${PurchaseItemsTable.name} pi_items
      INNER JOIN ${PurchaseInvoicesTable.name} pi
        ON pi.${PurchaseInvoicesTable.invoiceNumber}
         = pi_items.${PurchaseItemsTable.invoiceNumber}
      WHERE pi.${PurchaseInvoicesTable.wholesalerId} = ?
      ORDER BY pi_items.${PurchaseItemsTable.id} ASC
      ''',
      [wholesalerId],
    );

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final invoice = row[PurchaseItemsTable.invoiceNumber] as String? ?? '';
      grouped.putIfAbsent(invoice, () => []).add(row);
    }
    return grouped;
  }

  /// Payment logs for a wholesaler, newest first.
  ///
  /// Includes [WholesalerPaymentsTable.itemsSummary]: invoice line items for
  /// cash purchase outlays, or a fixed label for manual khata payments.
  Future<List<Map<String, dynamic>>> fetchWholesalerPayments(
    int wholesalerId,
  ) async {
    final db = await database;
    await _ensureWholesalerPaymentsSchema(db);
    return db.rawQuery(
      '''
      SELECT
        wp.*,
        CASE
          WHEN wp.${WholesalerPaymentsTable.paymentSource} = ?
            THEN 'N/A (Account Clearance)'
          WHEN wp.${WholesalerPaymentsTable.paymentSource} = ?
            THEN (
              SELECT GROUP_CONCAT(
                item.${PurchaseItemsTable.productName}
                  || ' x'
                  || CAST(item.${PurchaseItemsTable.quantity} AS INTEGER),
                ', '
              )
              FROM ${PurchaseItemsTable.name} item
              WHERE item.${PurchaseItemsTable.invoiceNumber}
                  = wp.${WholesalerPaymentsTable.referenceNo}
            )
          ELSE NULL
        END AS ${WholesalerPaymentsTable.itemsSummary}
      FROM ${WholesalerPaymentsTable.name} wp
      WHERE wp.${WholesalerPaymentsTable.wholesalerId} = ?
      ORDER BY wp.${WholesalerPaymentsTable.date} DESC,
               wp.${WholesalerPaymentsTable.id} DESC
      ''',
      [
        WholesalerPaymentSource.manualKhataPayment,
        WholesalerPaymentSource.cashPurchaseOutlay,
        wholesalerId,
      ],
    );
  }

  /// Global purchase ledger matrix with product summary aggregation.
  ///
  /// Optional [search] matches wholesaler name or invoice number.
  /// Optional [seasonStart]/[seasonEnd] bound `date_time` (ISO) inclusively.
  Future<List<Map<String, dynamic>>> fetchPurchaseLedgerMatrix({
    String? search,
    DateTime? seasonStart,
    DateTime? seasonEnd,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];

    final q = search?.trim() ?? '';
    if (q.isNotEmpty) {
      where.add(
        '(w.${WholesalerTable.nameColumn} LIKE ? '
        'OR pi.${PurchaseInvoicesTable.invoiceNumber} LIKE ?)',
      );
      args.add('%$q%');
      args.add('%$q%');
    }

    if (seasonStart != null && seasonEnd != null) {
      where.add(
        'pi.${PurchaseInvoicesTable.dateTime} >= ? '
        'AND pi.${PurchaseInvoicesTable.dateTime} <= ?',
      );
      args.add(_formatDateTime(seasonStart));
      args.add(_formatDateTime(seasonEnd));
    }

    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    return db.rawQuery('''
      SELECT
        pi.*,
        w.${WholesalerTable.nameColumn} AS wholesaler_name,
        (
          SELECT GROUP_CONCAT(
            item.${PurchaseItemsTable.productName}
              || ' x'
              || CAST(item.${PurchaseItemsTable.quantity} AS INTEGER),
            ', '
          )
          FROM ${PurchaseItemsTable.name} item
          WHERE item.${PurchaseItemsTable.invoiceNumber}
              = pi.${PurchaseInvoicesTable.invoiceNumber}
        ) AS product_summary
      FROM ${PurchaseInvoicesTable.name} pi
      LEFT JOIN ${WholesalerTable.name} w
        ON w.${WholesalerTable.id} = pi.${PurchaseInvoicesTable.wholesalerId}
      $whereSql
      ORDER BY pi.${PurchaseInvoicesTable.dateTime} DESC,
               pi.${PurchaseInvoicesTable.invoiceNumber} DESC
      ''', args);
  }

  /// KPI aggregates for the Purchase Ledger dashboard.
  Future<Map<String, double>> fetchPurchaseLedgerKpis({
    DateTime? seasonStart,
    DateTime? seasonEnd,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];

    if (seasonStart != null && seasonEnd != null) {
      where.add(
        '${PurchaseInvoicesTable.dateTime} >= ? '
        'AND ${PurchaseInvoicesTable.dateTime} <= ?',
      );
      args.add(_formatDateTime(seasonStart));
      args.add(_formatDateTime(seasonEnd));
    }

    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(${PurchaseInvoicesTable.grandTotal}), 0) AS total_purchases,
        COALESCE(SUM(${PurchaseInvoicesTable.amountPaid}), 0) AS paid_cash,
        COALESCE(SUM(${PurchaseInvoicesTable.outstanding}), 0) AS outstanding_debt
      FROM ${PurchaseInvoicesTable.name}
      $whereSql
      ''', args);

    final row = rows.first;
    return {
      'totalPurchases': (row['total_purchases'] as num?)?.toDouble() ?? 0,
      'paidCash': (row['paid_cash'] as num?)?.toDouble() ?? 0,
      'outstandingDebt': (row['outstanding_debt'] as num?)?.toDouble() ?? 0,
    };
  }

  /// Distinct purchase invoice dates (for season picker enrichment).
  Future<List<DateTime>> getPurchaseInvoiceDates() async {
    final db = await database;
    final rows = await db.query(
      PurchaseInvoicesTable.name,
      columns: [PurchaseInvoicesTable.dateTime],
    );
    return rows
        .map((r) {
          final raw = r[PurchaseInvoicesTable.dateTime] as String?;
          if (raw == null || raw.isEmpty) return null;
          return DateTime.tryParse(raw);
        })
        .whereType<DateTime>()
        .toList();
  }

  /// Records a vendor payment: reduces balance and appends a Payment ledger row.
  Future<void> recordWholesalerPayment({
    required int wholesalerId,
    required double amount,
    required String method,
    String remarks = '',
    DateTime? dateTime,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('Payment amount must be greater than zero');
    }
    final when = dateTime ?? DateTime.now();
    final suffix = method == 'Bank Transfer' ? 'BT' : 'CA';
    final receiptNo = 'RCPT-$suffix-${900 + Random().nextInt(99)}';

    final db = await database;
    await _ensureWholesalerPaymentsSchema(db);
    await db.transaction((txn) async {
      final rows = await txn.query(
        WholesalerTable.name,
        columns: [WholesalerTable.balance],
        where: '${WholesalerTable.id} = ?',
        whereArgs: [wholesalerId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Wholesaler $wholesalerId not found');
      }
      final current =
          (rows.first[WholesalerTable.balance] as num?)?.toDouble() ?? 0;
      final newBalance = (current - amount).clamp(0.0, double.infinity);

      await txn.rawUpdate(
        'UPDATE ${WholesalerTable.name} '
        'SET ${WholesalerTable.balance} = ? '
        'WHERE ${WholesalerTable.id} = ?',
        [newBalance, wholesalerId],
      );

      // wholesaler_ledger CREDIT is written by after_wholesaler_payment_insert.
      await _insertWholesalerPaymentRow(
        txn,
        wholesalerId: wholesalerId,
        amount: amount,
        paymentMethod: method,
        paymentSource: WholesalerPaymentSource.manualKhataPayment,
        referenceNo: receiptNo,
        date: when,
        notes: remarks,
      );
    });

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Purchase invoices
  // ---------------------------------------------------------------------------

  Future<String> getNextPurchaseInvoiceNumber() async {
    final db = await database;
    final maps = await db.query(
      PurchaseInvoicesTable.name,
      columns: [PurchaseInvoicesTable.invoiceNumber],
      orderBy: 'ROWID DESC',
      limit: 1,
    );

    if (maps.isEmpty) return 'PI-1000';

    final latest = maps.first[PurchaseInvoicesTable.invoiceNumber] as String;
    final numMatch = RegExp(r'\d+').stringMatch(latest);
    if (numMatch != null) {
      return 'PI-${int.parse(numMatch) + 1}';
    }
    return 'PI-1000';
  }

  /// Atomically saves a purchase invoice inside one DB transaction:
  /// purchase_invoices → purchase_items → products/stock_movements →
  /// wholesaler_payments. Vendor balance + wholesaler_ledger are owned by
  /// `after_purchase_insert`.
  Future<String> insertPurchaseInvoice({
    required int wholesalerId,
    required String wholesalerName,
    required DateTime dateTime,
    required List<PurchaseLineItem> items,
    required double transportCharges,
    required String paymentType,
    required double amountPaid,
    String description = '',
  }) async {
    if (items.isEmpty) {
      throw ArgumentError('Purchase must include at least one line item');
    }

    final invoiceNumber = await getNextPurchaseInvoiceNumber();
    final subtotal = items.fold<double>(0, (sum, i) => sum + i.lineTotal);
    final grandTotal = subtotal + transportCharges;

    double paid = amountPaid;
    double outstanding;

    switch (paymentType) {
      case PurchasePaymentType.cash:
        paid = grandTotal;
        outstanding = 0;
      case PurchasePaymentType.udhaar:
        paid = 0;
        outstanding = grandTotal;
      case PurchasePaymentType.partial:
        if (paid < 0) paid = 0;
        if (paid > grandTotal) paid = grandTotal;
        outstanding = grandTotal - paid;
      default:
        throw ArgumentError('Unknown payment type: $paymentType');
    }

    final trimmedDescription = description.trim();

    final db = await database;
    await _ensureWholesalerPaymentsSchema(db);
    await db.transaction((txn) async {
      // 1) Header — trigger syncs wholesaler_ledger + vendor balance.
      await txn.insert(PurchaseInvoicesTable.name, {
        PurchaseInvoicesTable.invoiceNumber: invoiceNumber,
        PurchaseInvoicesTable.wholesalerId: wholesalerId,
        PurchaseInvoicesTable.dateTime: _formatDateTime(dateTime),
        PurchaseInvoicesTable.subtotal: subtotal.round(),
        PurchaseInvoicesTable.transportCharges: transportCharges.round(),
        PurchaseInvoicesTable.grandTotal: grandTotal.round(),
        PurchaseInvoicesTable.paymentType: paymentType,
        PurchaseInvoicesTable.amountPaid: paid.round(),
        PurchaseInvoicesTable.outstanding: outstanding.round(),
        if (trimmedDescription.isNotEmpty)
          PurchaseInvoicesTable.description: trimmedDescription,
      });

      // 2) Line items + 3) inventory + 4) stock audit log.
      for (final item in items) {
        await txn.insert(PurchaseItemsTable.name, {
          PurchaseItemsTable.invoiceNumber: invoiceNumber,
          PurchaseItemsTable.productId: item.productId,
          PurchaseItemsTable.productName: item.productName,
          PurchaseItemsTable.quantity: item.quantity,
          PurchaseItemsTable.purchaseRate: item.purchaseRate.round(),
          PurchaseItemsTable.expiryDate: item.expiryDate != null
              ? _formatDateOnly(item.expiryDate!)
              : null,
          PurchaseItemsTable.lineTotal: item.lineTotal.round(),
        });

        if (item.productId == null || item.quantity <= 0) continue;

        final updates = <String, Object?>{
          ProductTable.costPrice: item.purchaseRate.round(),
        };
        if (item.expiryDate != null) {
          updates[ProductTable.expiryDate] = _formatDateOnly(item.expiryDate!);
        }

        await txn.rawUpdate(
          'UPDATE ${ProductTable.name} '
          'SET ${ProductTable.availableStock} = ${ProductTable.availableStock} + ? '
          'WHERE ${ProductTable.id} = ?',
          [item.quantity, item.productId],
        );
        await txn.update(
          ProductTable.name,
          updates,
          where: '${ProductTable.id} = ?',
          whereArgs: [item.productId],
        );

        await _insertStockMovement(
          txn,
          productId: item.productId!,
          movementType: StockMovementType.stockIn,
          quantity: item.quantity,
          partyLabel: wholesalerName,
          referenceType: StockMovementRef.purchase,
          referenceId: invoiceNumber,
          dateTime: dateTime,
          notes: 'Purchase $invoiceNumber',
        );
      }

      // 5) Cash/partial outlay voucher (ledger CREDIT already from purchase trigger).
      if (paid > 0) {
        await _insertWholesalerPaymentRow(
          txn,
          wholesalerId: wholesalerId,
          amount: paid,
          paymentMethod: 'Cash',
          paymentSource: WholesalerPaymentSource.cashPurchaseOutlay,
          referenceNo: invoiceNumber,
          date: dateTime,
          notes: '$paymentType purchase outlay',
        );
      }
    });

    notifyListeners();
    return invoiceNumber;
  }

  /// Atomically deletes a purchase invoice and reverses inventory.
  /// Cascade clears purchase_items; `after_purchase_delete` clears vendor ledger
  /// and outstanding balance; cash outlay payment rows are removed explicitly.
  Future<void> deletePurchaseInvoiceEntirely(String invoiceNumber) async {
    final db = await database;
    await db.transaction((txn) async {
      final headers = await txn.query(
        PurchaseInvoicesTable.name,
        where: '${PurchaseInvoicesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (headers.isEmpty) return;

      final header = headers.first;
      final wholesalerId = header[PurchaseInvoicesTable.wholesalerId] as int;
      final wholesalerRows = await txn.query(
        WholesalerTable.name,
        columns: [WholesalerTable.nameColumn],
        where: '${WholesalerTable.id} = ?',
        whereArgs: [wholesalerId],
        limit: 1,
      );
      final wholesalerName = wholesalerRows.isEmpty
          ? 'Wholesaler'
          : wholesalerRows.first[WholesalerTable.nameColumn] as String? ??
                'Wholesaler';

      final items = await txn.query(
        PurchaseItemsTable.name,
        where: '${PurchaseItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      for (final item in items) {
        final productId = item[PurchaseItemsTable.productId] as int?;
        final qty = (item[PurchaseItemsTable.quantity] as num?)?.toInt() ?? 0;
        if (productId == null || qty <= 0) continue;

        final rows = await txn.query(
          ProductTable.name,
          columns: [ProductTable.availableStock],
          where: '${ProductTable.id} = ?',
          whereArgs: [productId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final current = _readIntValue(rows.first[ProductTable.availableStock]);
        await txn.update(
          ProductTable.name,
          {
            ProductTable.availableStock: (current - qty).clamp(0, 1 << 31),
          },
          where: '${ProductTable.id} = ?',
          whereArgs: [productId],
        );

        await _insertStockMovement(
          txn,
          productId: productId,
          movementType: StockMovementType.stockOut,
          quantity: qty,
          partyLabel: wholesalerName,
          referenceType: StockMovementRef.purchase,
          referenceId: invoiceNumber,
          dateTime: DateTime.now(),
          notes: 'Purchase $invoiceNumber reversed',
        );
      }

      await txn.delete(
        StockMovementTable.name,
        where:
            '${StockMovementTable.referenceType} = ? AND '
            '${StockMovementTable.referenceId} = ? AND '
            '${StockMovementTable.movementType} = ?',
        whereArgs: [
          StockMovementRef.purchase,
          invoiceNumber,
          StockMovementType.stockIn,
        ],
      );

      await txn.delete(
        WholesalerPaymentsTable.name,
        where:
            '${WholesalerPaymentsTable.referenceNo} = ? AND '
            '${WholesalerPaymentsTable.paymentSource} = ?',
        whereArgs: [
          invoiceNumber,
          WholesalerPaymentSource.cashPurchaseOutlay,
        ],
      );

      // Triggers purge wholesaler_ledger + reverse outstanding on header delete.
      await txn.delete(
        PurchaseInvoicesTable.name,
        where: '${PurchaseInvoicesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
    });

    notifyListeners();
  }

  /// Atomically rewrites a purchase invoice (header, lines, stock, outlay).
  /// `after_purchase_update` rebuilds wholesaler_ledger + vendor balance.
  Future<void> updatePurchaseInvoice({
    required String invoiceNumber,
    required int wholesalerId,
    required String wholesalerName,
    required DateTime dateTime,
    required List<PurchaseLineItem> items,
    required double transportCharges,
    required String paymentType,
    required double amountPaid,
    String description = '',
  }) async {
    if (items.isEmpty) {
      throw ArgumentError('Purchase must include at least one line item');
    }

    final subtotal = items.fold<double>(0, (sum, i) => sum + i.lineTotal);
    final grandTotal = subtotal + transportCharges;

    double paid = amountPaid;
    double outstanding;
    switch (paymentType) {
      case PurchasePaymentType.cash:
        paid = grandTotal;
        outstanding = 0;
      case PurchasePaymentType.udhaar:
        paid = 0;
        outstanding = grandTotal;
      case PurchasePaymentType.partial:
        if (paid < 0) paid = 0;
        if (paid > grandTotal) paid = grandTotal;
        outstanding = grandTotal - paid;
      default:
        throw ArgumentError('Unknown payment type: $paymentType');
    }

    final trimmedDescription = description.trim();
    final db = await database;
    await _ensureWholesalerPaymentsSchema(db);

    await db.transaction((txn) async {
      final existing = await txn.query(
        PurchaseInvoicesTable.name,
        where: '${PurchaseInvoicesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (existing.isEmpty) {
        throw StateError('Purchase invoice $invoiceNumber was not found.');
      }

      // Reverse prior STOCK_IN quantities.
      final oldItems = await txn.query(
        PurchaseItemsTable.name,
        where: '${PurchaseItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      for (final item in oldItems) {
        final productId = item[PurchaseItemsTable.productId] as int?;
        final qty = (item[PurchaseItemsTable.quantity] as num?)?.toInt() ?? 0;
        if (productId == null || qty <= 0) continue;
        final rows = await txn.query(
          ProductTable.name,
          columns: [ProductTable.availableStock],
          where: '${ProductTable.id} = ?',
          whereArgs: [productId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final current = _readIntValue(rows.first[ProductTable.availableStock]);
        await txn.update(
          ProductTable.name,
          {
            ProductTable.availableStock: (current - qty).clamp(0, 1 << 31),
          },
          where: '${ProductTable.id} = ?',
          whereArgs: [productId],
        );
      }

      await txn.delete(
        StockMovementTable.name,
        where:
            '${StockMovementTable.referenceType} = ? AND '
            '${StockMovementTable.referenceId} = ?',
        whereArgs: [StockMovementRef.purchase, invoiceNumber],
      );
      await txn.delete(
        PurchaseItemsTable.name,
        where: '${PurchaseItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      await txn.delete(
        WholesalerPaymentsTable.name,
        where:
            '${WholesalerPaymentsTable.referenceNo} = ? AND '
            '${WholesalerPaymentsTable.paymentSource} = ?',
        whereArgs: [
          invoiceNumber,
          WholesalerPaymentSource.cashPurchaseOutlay,
        ],
      );

      await txn.update(
        PurchaseInvoicesTable.name,
        {
          PurchaseInvoicesTable.wholesalerId: wholesalerId,
          PurchaseInvoicesTable.dateTime: _formatDateTime(dateTime),
          PurchaseInvoicesTable.subtotal: subtotal.round(),
          PurchaseInvoicesTable.transportCharges: transportCharges.round(),
          PurchaseInvoicesTable.grandTotal: grandTotal.round(),
          PurchaseInvoicesTable.paymentType: paymentType,
          PurchaseInvoicesTable.amountPaid: paid.round(),
          PurchaseInvoicesTable.outstanding: outstanding.round(),
          PurchaseInvoicesTable.description: trimmedDescription.isEmpty
              ? null
              : trimmedDescription,
        },
        where: '${PurchaseInvoicesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      for (final item in items) {
        await txn.insert(PurchaseItemsTable.name, {
          PurchaseItemsTable.invoiceNumber: invoiceNumber,
          PurchaseItemsTable.productId: item.productId,
          PurchaseItemsTable.productName: item.productName,
          PurchaseItemsTable.quantity: item.quantity,
          PurchaseItemsTable.purchaseRate: item.purchaseRate.round(),
          PurchaseItemsTable.expiryDate: item.expiryDate != null
              ? _formatDateOnly(item.expiryDate!)
              : null,
          PurchaseItemsTable.lineTotal: item.lineTotal.round(),
        });

        if (item.productId == null || item.quantity <= 0) continue;

        final updates = <String, Object?>{
          ProductTable.costPrice: item.purchaseRate.round(),
        };
        if (item.expiryDate != null) {
          updates[ProductTable.expiryDate] = _formatDateOnly(item.expiryDate!);
        }

        await txn.rawUpdate(
          'UPDATE ${ProductTable.name} '
          'SET ${ProductTable.availableStock} = ${ProductTable.availableStock} + ? '
          'WHERE ${ProductTable.id} = ?',
          [item.quantity, item.productId],
        );
        await txn.update(
          ProductTable.name,
          updates,
          where: '${ProductTable.id} = ?',
          whereArgs: [item.productId],
        );

        await _insertStockMovement(
          txn,
          productId: item.productId!,
          movementType: StockMovementType.stockIn,
          quantity: item.quantity,
          partyLabel: wholesalerName,
          referenceType: StockMovementRef.purchase,
          referenceId: invoiceNumber,
          dateTime: dateTime,
          notes: 'Purchase $invoiceNumber',
        );
      }

      if (paid > 0) {
        await _insertWholesalerPaymentRow(
          txn,
          wholesalerId: wholesalerId,
          amount: paid,
          paymentMethod: 'Cash',
          paymentSource: WholesalerPaymentSource.cashPurchaseOutlay,
          referenceNo: invoiceNumber,
          date: dateTime,
          notes: '$paymentType purchase outlay',
        );
      }
    });

    notifyListeners();
  }

  /// Fetches complete invoice data for editing via invoice_number
  /// Returns a map with all necessary information to reconstruct the sale
  Future<Map<String, dynamic>?> getInvoiceDataByInvoiceNumber(
    String invoiceNumber,
  ) async {
    final db = await database;

    // Fetch the main sale record with joined party names.
    final salesMaps = await db.rawQuery(
      '''
      SELECT
        s.*,
        z.${ZamindarTable.nameColumn} AS ${SalesTable.zamindarName},
        k.${KisaanTable.nameColumn} AS ${SalesTable.kisaanName}
      FROM ${SalesTable.name} s
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
      LEFT JOIN ${KisaanTable.name} k
        ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
      WHERE s.${SalesTable.invoiceNumber} = ?
      LIMIT 1
      ''',
      [invoiceNumber],
    );

    if (salesMaps.isEmpty) return null;

    final sale = salesMaps.first;

    // Fetch associated line items
    final itemsMaps = await db.query(
      SaleItemsTable.name,
      where: '${SaleItemsTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
    );

    // Fetch associated payments
    final paymentsMaps = await db.query(
      PaymentsTable.name,
      where: '${PaymentsTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
    );

    final zamindarName = sale[SalesTable.zamindarName] as String;
    final kisaanName = sale[SalesTable.kisaanName] as String?;
    final totalPayable = (sale[SalesTable.totalPayable] as num).toDouble();
    final initialPaid = (sale[SalesTable.paidAmount] as num).toDouble();
    final paymentMethod = sale[SalesTable.paymentMethod] as String;
    final dateTimeStr = sale[SalesTable.dateTime] as String;
    final season = sale[SalesTable.season] as String;

    // Calculate total collected
    final totalCollected = _sumPaymentsCollected(initialPaid, paymentsMaps);

    // Convert line items to a format suitable for the edit form
    final items = itemsMaps.map((item) {
      return {
        'productName': item[SaleItemsTable.productName] as String,
        'productType': item[SaleItemsTable.productType] as String,
        'qty': (item[SaleItemsTable.quantity] as num).toDouble(),
        'unitPrice': (item[SaleItemsTable.unitPrice] as num).toDouble(),
        'seasonalIncrement':
            (item[SaleItemsTable.seasonalIncrement] as num?)?.toDouble() ?? 0,
        'discount':
            (item[SaleItemsTable.itemDiscount] as num?)?.toDouble() ?? 0,
      };
    }).toList();

    return {
      'invoiceNumber': invoiceNumber,
      'zamindarName': zamindarName,
      'kisaanName': kisaanName,
      'items': items,
      'totalPayable': totalPayable,
      'totalCollected': totalCollected,
      'paidAmount': initialPaid,
      'paymentTerm': sale[SalesTable.paymentTerm] as String?,
      'isCredit': paymentMethod.toLowerCase() == 'credit',
      'season': season,
      'dateTime': dateTimeStr,
      'payments': paymentsMaps,
    };
  }

  /// Returns product inventory rows with a runtime-calculated status.
  Future<List<ProductInventoryStatus>> getProductInventoryStatus() async {
    final db = await database;
    final rows = await db.query(ProductTable.name);

    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);

    return rows.map((row) {
      final expiryDate = _parseDateOnly(row[ProductTable.expiryDate] as String);
      final availableStock = _readIntValue(row[ProductTable.availableStock]);
      final lowStockThreshold = _readIntValue(
        row[ProductTable.lowStockThreshold],
      );

      String status;
      if (expiryDate.isBefore(todayStart)) {
        status = 'Expired';
      } else if (availableStock <= lowStockThreshold) {
        status = 'Low Stock';
      } else {
        status = 'In Stock';
      }

      return ProductInventoryStatus(
        id: _readIntValue(row[ProductTable.id]),
        name: row[ProductTable.nameColumn] as String,
        brand: row[ProductTable.brand] as String,
        packagingSize: row[ProductTable.packagingSize] as String,
        availableStock: availableStock,
        lowStockThreshold: lowStockThreshold,
        expiryDate: expiryDate,
        status: status,
      );
    }).toList();
  }

  /// Returns a summary of inventory counts for the products table.
  Future<ProductInventorySummary> getProductInventorySummary() async {
    final statuses = await getProductInventoryStatus();

    return ProductInventorySummary(
      totalItems: statuses.length,
      lowStockCount: statuses
          .where((item) => item.status == 'Low Stock')
          .length,
      expiredCount: statuses.where((item) => item.status == 'Expired').length,
    );
  }

  // ---------------------------------------------------------------------------
  // Dashboard aggregations
  // ---------------------------------------------------------------------------

  /// Live shop-counter KPIs for [DashboardScreen].
  ///
  /// - Receivables: outstanding invoice balances owed by customers (You Will Get)
  /// - Payables: wholesaler balances where balance > 0 (You Will Give)
  /// - Cash in hand: today's cash sales + cash ledger receipts − supplier cash
  ///   out − cash advances given to kisaans (physical cash left the drawer)
  /// - Active accounts: non-draft zamindars + wholesalers
  Future<DashboardMetrics> getDashboardMetrics() async {
    final db = await database;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));
    final todayStartIso = _formatDateTime(todayStart);
    final todayEndIso = _formatDateTime(todayEnd);
    final expiryHorizon = todayStart.add(const Duration(days: 60));
    final expiryHorizonIso = _formatDateOnly(expiryHorizon);
    final todayStartDateIso = _formatDateOnly(todayStart);

    final totalReceivables = await _sumTotalReceivables(db);
    final totalPayables = await _sumTotalPayables(db);

    final cashSalesRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${SalesTable.paidAmount}), 0) AS total
      FROM ${SalesTable.name}
      WHERE ${SalesTable.paymentMethod} = 'Cash'
        AND ${SalesTable.dateTime} >= ?
        AND ${SalesTable.dateTime} < ?
      ''',
      [todayStartIso, todayEndIso],
    );
    final todayCashSales =
        (cashSalesRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final ledgerPaymentRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${PaymentsTable.amountPaid}), 0) AS total
      FROM ${PaymentsTable.name}
      WHERE ${PaymentsTable.paymentMethod} = 'Cash'
        AND ${PaymentsTable.dateTime} >= ?
        AND ${PaymentsTable.dateTime} < ?
      ''',
      [todayStartIso, todayEndIso],
    );
    final todayLedgerPayments =
        (ledgerPaymentRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final supplierPaymentRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${WholesalerPaymentsTable.amount}), 0) AS total
      FROM ${WholesalerPaymentsTable.name}
      WHERE ${WholesalerPaymentsTable.paymentMethod} = 'Cash'
        AND ${WholesalerPaymentsTable.date} >= ?
        AND ${WholesalerPaymentsTable.date} < ?
      ''',
      [todayStartIso, todayEndIso],
    );
    final todaySupplierCashPayments =
        (supplierPaymentRows.first['total'] as num?)?.toDouble() ?? 0.0;

    // Physical cash advances leave the register; fuel advances do not.
    final cashAdvanceRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${SalesTable.totalPayable}), 0) AS total
      FROM ${SalesTable.name}
      WHERE ${SalesTable.transactionType} = ?
        AND ${SalesTable.dateTime} >= ?
        AND ${SalesTable.dateTime} < ?
      ''',
      [SaleTransactionType.cashAdvance, todayStartIso, todayEndIso],
    );
    final todayCashAdvances =
        (cashAdvanceRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final cashInHand = todayCashSales +
        todayLedgerPayments -
        todaySupplierCashPayments -
        todayCashAdvances;

    final todayVolumeRows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE
          WHEN ${SalesTable.paymentMethod} = 'Cash'
          THEN ${SalesTable.totalPayable} ELSE 0 END), 0) AS cash_volume,
        COALESCE(SUM(CASE
          WHEN ${SalesTable.paymentMethod} = 'Credit'
          THEN ${SalesTable.totalPayable} ELSE 0 END), 0) AS credit_volume
      FROM ${SalesTable.name}
      WHERE ${SalesTable.dateTime} >= ?
        AND ${SalesTable.dateTime} < ?
      ''',
      [todayStartIso, todayEndIso],
    );
    final todayCashSalesVolume =
        (todayVolumeRows.first['cash_volume'] as num?)?.toDouble() ?? 0.0;
    final todayCreditSalesVolume =
        (todayVolumeRows.first['credit_volume'] as num?)?.toDouble() ?? 0.0;

    final zamindarCountRows = await db.rawQuery('''
      SELECT COUNT(*) AS count
      FROM ${ZamindarTable.name}
      WHERE ${ZamindarTable.isDraft} IS NULL OR ${ZamindarTable.isDraft} = 0
    ''');
    final wholesalerCountRows = await db.rawQuery('''
      SELECT COUNT(*) AS count
      FROM ${WholesalerTable.name}
    ''');
    final activeZamindars = _readIntValue(zamindarCountRows.first['count']);
    final activeWholesalers = _readIntValue(wholesalerCountRows.first['count']);
    final activeAccounts = activeZamindars + activeWholesalers;

    final lowStockAlerts = await getLowStockAlerts();
    final expiryAlerts = await getExpiringBatchAlerts(
      withinDays: 60,
      todayStartDateIso: todayStartDateIso,
      expiryHorizonIso: expiryHorizonIso,
    );
    final topRecoveries = await getTopPendingRecoveries(limit: 5);

    return DashboardMetrics(
      totalReceivables: totalReceivables,
      totalPayables: totalPayables,
      cashInHand: cashInHand,
      todayCashSales: todayCashSales,
      todayLedgerPayments: todayLedgerPayments,
      todaySupplierCashPayments: todaySupplierCashPayments,
      todayCashSalesVolume: todayCashSalesVolume,
      todayCreditSalesVolume: todayCreditSalesVolume,
      activeAccounts: activeAccounts,
      activeZamindars: activeZamindars,
      activeWholesalers: activeWholesalers,
      lowStockAlerts: lowStockAlerts,
      expiryAlerts: expiryAlerts,
      topRecoveries: topRecoveries,
    );
  }

  /// Top Zamindars by outstanding balance, optionally filtered by payment term.
  ///
  /// [paymentTerm] accepts UI labels (`Weekly`, `Monthly`, `90 Days`,
  /// `After Harvest`) or stored values (`After a Week`, etc.).
  Future<List<DashboardRecoveryRow>> getTopPendingRecoveries({
    String? paymentTerm,
    int limit = 5,
  }) async {
    final mappedTerm = _mapDashboardRecoveryFilter(paymentTerm);
    final directory = await getOutstandingCreditDirectory(
      paymentTerm: mappedTerm,
    );
    final capped = directory.take(limit < 1 ? 5 : limit);
    return capped
        .map(
          (row) => DashboardRecoveryRow(
            zamindarId: row['zamindarId'] as int?,
            name: row['name'] as String? ?? '',
            outstandingBalance:
                (row['outstandingBalance'] as num?)?.toDouble() ?? 0.0,
            whatsappNumber: row['whatsappNumber'] as String?,
            paymentTerm: row['paymentTerm'] as String? ?? '',
          ),
        )
        .where((row) => row.name.isNotEmpty && row.outstandingBalance > 0.005)
        .toList();
  }

  /// Maps dashboard chip labels onto stored / directory payment-term filters.
  static String? _mapDashboardRecoveryFilter(String? filter) {
    final raw = filter?.trim() ?? '';
    if (raw.isEmpty) return null;
    switch (raw.toLowerCase()) {
      case 'weekly':
      case 'after a week':
        return 'After a Week';
      case 'monthly':
      case 'after a month':
        return 'After a Month';
      case '90 days':
      case '90-day cycle':
      case '90 days cycle':
        return '90 days';
      case 'after harvest':
      case 'harvest settlement':
        return 'After Harvest';
      default:
        return raw;
    }
  }

  /// Outstanding customer balances (sales remaining after collections).
  /// Identical collected/remaining logic as zamindar ledger & recalculate.
  Future<double> _sumTotalReceivables(Database db) async {
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(remaining), 0) AS total
      FROM (
        SELECT ($_sqlSaleRemainingExpr) AS remaining
        FROM ${SalesTable.name} s
      ) AS invoice_balances
      WHERE remaining > 0.005
    ''');
    return (rows.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  /// Unpaid wholesaler debt balances (You Will Give).
  Future<double> _sumTotalPayables(Database db) async {
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(${WholesalerTable.balance}), 0) AS total
      FROM ${WholesalerTable.name}
      WHERE ${WholesalerTable.balance} > 0
    ''');
    return (rows.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  /// Products at or below their reorder / low-stock threshold.
  Future<List<DashboardLowStockAlert>> getLowStockAlerts() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        ${ProductTable.id},
        ${ProductTable.nameColumn},
        ${ProductTable.brand},
        ${ProductTable.packagingSize},
        ${ProductTable.availableStock},
        ${ProductTable.lowStockThreshold},
        ${ProductTable.uom}
      FROM ${ProductTable.name}
      WHERE ${ProductTable.availableStock} <= ${ProductTable.lowStockThreshold}
      ORDER BY ${ProductTable.availableStock} ASC,
               ${ProductTable.nameColumn} COLLATE NOCASE ASC
    ''');

    return rows
        .map(
          (row) => DashboardLowStockAlert(
            productId: _readIntValue(row[ProductTable.id]),
            productName: row[ProductTable.nameColumn] as String? ?? '',
            brand: row[ProductTable.brand] as String? ?? '',
            packagingSize: row[ProductTable.packagingSize] as String? ?? '',
            availableStock: _readIntValue(row[ProductTable.availableStock]),
            lowStockThreshold: _readIntValue(
              row[ProductTable.lowStockThreshold],
            ),
            uom: row[ProductTable.uom] as String? ?? 'bags',
          ),
        )
        .toList();
  }

  /// Purchase batch / product rows whose expiry falls within [withinDays].
  Future<List<DashboardExpiryAlert>> getExpiringBatchAlerts({
    int withinDays = 60,
    String? todayStartDateIso,
    String? expiryHorizonIso,
  }) async {
    final db = await database;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final horizon = todayStart.add(Duration(days: withinDays));
    final startIso = todayStartDateIso ?? _formatDateOnly(todayStart);
    final endIso = expiryHorizonIso ?? _formatDateOnly(horizon);

    final batchRows = await db.rawQuery(
      '''
      SELECT
        pi.${PurchaseItemsTable.id} AS batch_id,
        pi.${PurchaseItemsTable.productId} AS product_id,
        pi.${PurchaseItemsTable.productName} AS product_name,
        pi.${PurchaseItemsTable.quantity} AS quantity,
        pi.${PurchaseItemsTable.expiryDate} AS expiry_date,
        pi.${PurchaseItemsTable.invoiceNumber} AS invoice_number,
        p.${ProductTable.brand} AS brand,
        p.${ProductTable.uom} AS uom
      FROM ${PurchaseItemsTable.name} pi
      LEFT JOIN ${ProductTable.name} p
        ON p.${ProductTable.id} = pi.${PurchaseItemsTable.productId}
      WHERE pi.${PurchaseItemsTable.expiryDate} IS NOT NULL
        AND TRIM(pi.${PurchaseItemsTable.expiryDate}) != ''
        AND pi.${PurchaseItemsTable.expiryDate} >= ?
        AND pi.${PurchaseItemsTable.expiryDate} <= ?
      ORDER BY pi.${PurchaseItemsTable.expiryDate} ASC,
               pi.${PurchaseItemsTable.productName} COLLATE NOCASE ASC
      ''',
      [startIso, endIso],
    );

    final alerts = <DashboardExpiryAlert>[];
    final seenProductKeys = <String>{};

    for (final row in batchRows) {
      final expiryRaw = row['expiry_date'] as String? ?? '';
      final productName = row['product_name'] as String? ?? '';
      final key = '$productName|$expiryRaw';
      seenProductKeys.add(key);
      alerts.add(
        DashboardExpiryAlert(
          productId: row['product_id'] == null
              ? null
              : _readIntValue(row['product_id']),
          productName: productName,
          brand: row['brand'] as String? ?? '',
          quantity: _readIntValue(row['quantity']),
          uom: row['uom'] as String? ?? 'bags',
          expiryDate: _parseDateOnly(expiryRaw),
          invoiceNumber: row['invoice_number'] as String?,
          source: 'batch',
        ),
      );
    }

    // Fallback: catalogue products with no matching purchase-batch alert.
    final productRows = await db.rawQuery(
      '''
      SELECT
        ${ProductTable.id},
        ${ProductTable.nameColumn},
        ${ProductTable.brand},
        ${ProductTable.availableStock},
        ${ProductTable.uom},
        ${ProductTable.expiryDate}
      FROM ${ProductTable.name}
      WHERE ${ProductTable.expiryDate} >= ?
        AND ${ProductTable.expiryDate} <= ?
      ORDER BY ${ProductTable.expiryDate} ASC,
               ${ProductTable.nameColumn} COLLATE NOCASE ASC
      ''',
      [startIso, endIso],
    );

    for (final row in productRows) {
      final expiryRaw = row[ProductTable.expiryDate] as String? ?? '';
      final productName = row[ProductTable.nameColumn] as String? ?? '';
      final key = '$productName|$expiryRaw';
      if (seenProductKeys.contains(key)) continue;
      alerts.add(
        DashboardExpiryAlert(
          productId: _readIntValue(row[ProductTable.id]),
          productName: productName,
          brand: row[ProductTable.brand] as String? ?? '',
          quantity: _readIntValue(row[ProductTable.availableStock]),
          uom: row[ProductTable.uom] as String? ?? 'bags',
          expiryDate: _parseDateOnly(expiryRaw),
          invoiceNumber: null,
          source: 'product',
        ),
      );
    }

    alerts.sort((a, b) => a.expiryDate.compareTo(b.expiryDate));
    return alerts;
  }

  static int _readIntValue(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static DateTime _parseDateOnly(String value) {
    final parts = value.split('-');
    if (parts.length != 3) {
      return DateTime.now();
    }

    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) {
      return DateTime.now();
    }

    return DateTime(year, month, day);
  }

  static DateTime _parseDateTime(String value) {
    return DateTime.tryParse(value) ?? DateTime.now();
  }

  /// Restores advance wallet amounts previously drawn down on [invoiceNumber].
  Future<void> _reverseInvoiceWalletDrawdowns(
    DatabaseExecutor txn,
    String invoiceNumber,
  ) async {
    final walletPayments = await txn.query(
      PaymentsTable.name,
      where:
          '${PaymentsTable.invoiceNumber} = ? AND '
          '${PaymentsTable.paymentMethod} = ?',
      whereArgs: [invoiceNumber, 'Advance Wallet Deduction'],
    );

    for (final payment in walletPayments) {
      final zamindarId = payment[PaymentsTable.zamindarId] as int?;
      final amount =
          (payment[PaymentsTable.amountPaid] as num?)?.round() ?? 0;
      if (zamindarId == null || amount <= 0) continue;

      final rows = await txn.query(
        ZamindarTable.name,
        columns: [ZamindarTable.advanceBalance],
        where: '${ZamindarTable.id} = ?',
        whereArgs: [zamindarId],
        limit: 1,
      );
      if (rows.isEmpty) continue;

      final current = _readIntValue(rows.first[ZamindarTable.advanceBalance]);
      await txn.update(
        ZamindarTable.name,
        {ZamindarTable.advanceBalance: current + amount},
        where: '${ZamindarTable.id} = ?',
        whereArgs: [zamindarId],
      );
    }
  }

  /// Removes sale-originated payment vouchers for an invoice, keeping later
  /// settlement rows (`category = PAYMENT` from [insertPayment]).
  ///
  /// Ledger rebuild is owned by `after_sale_update` / payment triggers —
  /// this method only touches the `payments` table.
  Future<void> _clearSaleOriginatedFinancials(
    DatabaseExecutor txn,
    String invoiceNumber,
  ) async {
    final settlementRows = await txn.query(
      LedgerTransactionTable.name,
      columns: [LedgerTransactionTable.paymentId],
      where:
          '${LedgerTransactionTable.invoiceNumber} = ? AND '
          'UPPER(${LedgerTransactionTable.category}) = ?',
      whereArgs: [invoiceNumber, 'PAYMENT'],
    );
    final settlementPaymentIds = settlementRows
        .map((r) => r[LedgerTransactionTable.paymentId] as String?)
        .whereType<String>()
        .where((id) => id.trim().isNotEmpty)
        .toSet();

    if (settlementPaymentIds.isEmpty) {
      await txn.delete(
        PaymentsTable.name,
        where: '${PaymentsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
    } else {
      final placeholders = List.filled(
        settlementPaymentIds.length,
        '?',
      ).join(',');
      await txn.delete(
        PaymentsTable.name,
        where:
            '${PaymentsTable.invoiceNumber} = ? AND '
            '${PaymentsTable.paymentId} NOT IN ($placeholders)',
        whereArgs: [invoiceNumber, ...settlementPaymentIds],
      );
    }
  }

  /// Removes a single invoice and all linked sales, payments, and ledger rows.
  /// Stock is restored and the zamindar balance is recalculated from sales.
  Future<void> deleteInvoiceEntirely(String invoiceNumber) async {
    final db = await database;
    int? affectedZamindarId;

    await db.transaction((txn) async {
      final saleRows = await txn.query(
        SalesTable.name,
        columns: [SalesTable.zamindarId],
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (saleRows.isEmpty) return;

      affectedZamindarId =
          saleRows.first[SalesTable.zamindarId] as int?;

      final oldItems = await txn.query(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      for (final oldItem in oldItems) {
        final productName = oldItem[SaleItemsTable.productName] as String;
        final oldQuantity =
            (oldItem[SaleItemsTable.quantity] as num?)?.toInt() ?? 0;
        final products = await txn.query(
          ProductTable.name,
          where: '${ProductTable.nameColumn} = ?',
          whereArgs: [productName],
          limit: 1,
        );
        if (products.isEmpty) continue;
        final productId = products.first[ProductTable.id] as int;
        final currentStock = _readIntValue(
          products.first[ProductTable.availableStock],
        );
        await txn.update(
          ProductTable.name,
          {
            ProductTable.availableStock: (currentStock + oldQuantity).clamp(
              0,
              1 << 31,
            ),
          },
          where: '${ProductTable.id} = ?',
          whereArgs: [productId],
        );
      }

      await _reverseInvoiceWalletDrawdowns(txn, invoiceNumber);

      await txn.delete(
        StockMovementTable.name,
        where:
            '${StockMovementTable.referenceType} = ? AND '
            '${StockMovementTable.referenceId} = ?',
        whereArgs: [StockMovementRef.sale, invoiceNumber],
      );

      // ON DELETE CASCADE purges sale_items, payments, and ledger_transactions.
      await txn.delete(
        SalesTable.name,
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      if (affectedZamindarId != null) {
        await _recalculateZamindarBalanceOn(txn, affectedZamindarId!);
      }
    });

    notifyListeners();
  }

  /// Partial factory reset for a new season.
  ///
  /// Completely wipes transactional history, operational logs, and financial
  /// records, then resets auto-increment counters. Master profiles are kept:
  /// zamindars, kisaans, products, wholesalers, and employees.
  Future<void> truncateFullDatabase() async {
    final db = await database;

    // Child / dependent tables first, then parents — safe even if FK pragma
    // is ignored by the platform during the transaction.
    const transactionalTables = <String>[
      SaleItemsTable.name,
      PaymentsTable.name,
      LedgerTransactionTable.name,
      SalesTable.name,
      PurchaseItemsTable.name,
      WholesalerLedgerTable.name,
      WholesalerPaymentsTable.name,
      PurchaseInvoicesTable.name,
      StockMovementTable.name,
      ExpenseTable.name,
      EmployeeAttendanceTable.name,
    ];

    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.transaction((txn) async {
        for (final table in transactionalTables) {
          await txn.delete(table);
        }

        // Reset AUTOINCREMENT trackers so new IDs start at 1 again.
        final placeholders =
            List.filled(transactionalTables.length, '?').join(', ');
        await txn.rawDelete(
          'DELETE FROM sqlite_sequence WHERE name IN ($placeholders)',
          transactionalTables,
        );

        // Reset payment receipt sequences to the default seed value.
        await txn.rawUpdate(
          'UPDATE payment_sequences SET last_value = 1000',
        );
        for (final key in ['standard', 'advance']) {
          await txn.insert(
            'payment_sequences',
            {'sequence_key': key, 'last_value': 1000},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        // Cached balances on preserved masters must not retain wiped history.
        await txn.rawUpdate(
          'UPDATE ${ZamindarTable.name} SET '
          '${ZamindarTable.currentBalance} = 0, '
          '${ZamindarTable.advanceBalance} = 0',
        );
        await txn.rawUpdate(
          'UPDATE ${WholesalerTable.name} SET ${WholesalerTable.balance} = 0',
        );
      });
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }

    notifyListeners();
  }

  // -----------------------------
  // New Three-Table Schema CRUD Operations
  // -----------------------------

  /// Inserts a new sale into the sales table with its line items.
  /// For Cash sales against a registered Zamindar, automatically draws down
  /// the advance wallet and returns financial breakdown for the UI overlay.
  Future<Map<String, dynamic>> insertSale({
    required String invoiceNumber,
    required DateTime dateTime,
    required String zamindarName,
    String? kisaanName,
    required List<SaleLineItem> items,
    required double overallDiscount,
    required double paidAmount,
    required String paymentMethod,
    required String productType,
    required String season,
    String? paymentTerm,
  }) async {
    final isCashSale = paymentMethod == 'Cash';
    final isCreditSale = paymentMethod == 'Credit';
    double totalAdvanceBefore = 0;
    double drawdown = 0;
    double remainingAdvance = 0;
    double remainingPhysicalCash = 0;
    double effectivePaidAmount = paidAmount;

    final db = await database;
    await db.transaction((txn) async {
      // Calculate totals
      final subtotal = items.fold<double>(
        0.0,
        (sum, item) => sum + (item.qty * item.unitPrice),
      );
      final itemDiscountsTotal = items.fold<double>(
        0.0,
        (sum, item) => sum + item.discount,
      );
      final seasonalIncrementTotal = items.fold<double>(0.0, (sum, item) {
        if (paymentMethod == 'Credit') {
          return sum + 0;
        }
        return sum;
      });
      final totalPayable =
          subtotal +
          seasonalIncrementTotal -
          itemDiscountsTotal -
          overallDiscount;

      remainingPhysicalCash = totalPayable;

      int? advanceZamindarId;
      if (isCashSale) {
        final zamindarRows = await txn.query(
          ZamindarTable.name,
          columns: [ZamindarTable.id, ZamindarTable.advanceBalance],
          where: '${ZamindarTable.nameColumn} = ?',
          whereArgs: [zamindarName],
          limit: 1,
        );

        if (zamindarRows.isNotEmpty) {
          advanceZamindarId = zamindarRows.first[ZamindarTable.id] as int;
          final originalAdvanceBalance = _readIntValue(
            zamindarRows.first[ZamindarTable.advanceBalance],
          );
          totalAdvanceBefore = originalAdvanceBalance.toDouble();
          drawdown = totalPayable >= originalAdvanceBalance
              ? originalAdvanceBalance.toDouble()
              : totalPayable;
          remainingAdvance = totalAdvanceBefore - drawdown;
          remainingPhysicalCash = totalPayable - drawdown;
          effectivePaidAmount = remainingPhysicalCash;
        }
      }

      // Credit sales: cash received reduces udhaar; remainder stays outstanding.
      if (isCreditSale) {
        if (effectivePaidAmount < 0) effectivePaidAmount = 0;
        if (effectivePaidAmount > totalPayable) {
          effectivePaidAmount = totalPayable;
        }
        remainingPhysicalCash = effectivePaidAmount;
      }

      final usesAdvanceWallet =
          isCashSale && drawdown > 0 && advanceZamindarId != null;
      // When credit has an upfront cash payment row, keep sales.paid_amount at 0
      // so _sumPaymentsCollected does not double-count.
      final hasCreditCashPayment = isCreditSale && effectivePaidAmount > 0;
      final salePaidAmount = (usesAdvanceWallet || hasCreditCashPayment)
          ? 0.0
          : effectivePaidAmount;
      final creditAmount = isCreditSale
          ? (totalPayable - effectivePaidAmount).clamp(0.0, totalPayable)
          : 0.0;

      int? resolvedZamindarId = advanceZamindarId;
      resolvedZamindarId ??=
          await _resolveZamindarIdByName(txn, zamindarName);
      int? resolvedKisaanId;
      if (resolvedZamindarId != null &&
          kisaanName != null &&
          kisaanName.isNotEmpty &&
          kisaanName != 'Self') {
        final kisaanRows = await txn.query(
          KisaanTable.name,
          columns: [KisaanTable.id],
          where:
              '${KisaanTable.zamindarId} = ? AND ${KisaanTable.nameColumn} = ?',
          whereArgs: [resolvedZamindarId, kisaanName],
          limit: 1,
        );
        if (kisaanRows.isNotEmpty) {
          resolvedKisaanId = kisaanRows.first[KisaanTable.id] as int?;
        }
      }

      if (resolvedZamindarId == null) {
        throw StateError(
          'Cannot insert sale: zamindar "$zamindarName" was not resolved to an id.',
        );
      }

      // Step 1: Insert sale (after_sale_insert trigger writes ledger DEBIT).
      await txn.insert(SalesTable.name, {
        SalesTable.invoiceNumber: invoiceNumber,
        SalesTable.dateTime: _formatDateTime(dateTime),
        SalesTable.subtotal: subtotal.round(),
        SalesTable.itemDiscountsTotal: itemDiscountsTotal.round(),
        SalesTable.seasonalIncrementTotal: seasonalIncrementTotal.round(),
        SalesTable.overallDiscount: overallDiscount.round(),
        SalesTable.totalPayable: totalPayable.round(),
        SalesTable.paidAmount: salePaidAmount.round(),
        SalesTable.paymentMethod: paymentMethod,
        SalesTable.season: season,
        SalesTable.paymentTerm: isCreditSale ? paymentTerm : null,
        SalesTable.transactionType: SaleTransactionType.productSale,
        SalesTable.creditAmount: creditAmount.round(),
        SalesTable.fuelQuantity: null,
        SalesTable.remarks: null,
        SalesTable.zamindarId: resolvedZamindarId,
        SalesTable.kisaanId: resolvedKisaanId,
      });

      // Insert line items into sale_items table
      for (final item in items) {
        final itemSubtotal = (item.qty * item.unitPrice) - item.discount;
        await txn.insert(SaleItemsTable.name, {
          SaleItemsTable.invoiceNumber: invoiceNumber,
          SaleItemsTable.productName: item.productName,
          SaleItemsTable.productType: productType,
          SaleItemsTable.quantity: item.qty.round(),
          SaleItemsTable.unitPrice: item.unitPrice.round(),
          SaleItemsTable.seasonalIncrement: 0,
          SaleItemsTable.itemDiscount: item.discount.round(),
          SaleItemsTable.subtotal: itemSubtotal.round(),
        });
      }

      // Decrement product stock + record STOCK OUT movements
      final partyLabel = await _resolveSalePartyLabel(txn, zamindarName);
      for (final item in items) {
        if (item.productId == null) continue;
        final rows = await txn.query(
          ProductTable.name,
          columns: [ProductTable.availableStock],
          where: '${ProductTable.id} = ?',
          whereArgs: [item.productId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final currentStock = _readIntValue(
          rows.first[ProductTable.availableStock],
        );
        final qtyOut = item.qty.ceil();
        final nextStock = (currentStock - qtyOut).clamp(0, 1 << 31);
        await txn.update(
          ProductTable.name,
          {ProductTable.availableStock: nextStock},
          where: '${ProductTable.id} = ?',
          whereArgs: [item.productId],
        );
        await _insertStockMovement(
          txn,
          productId: item.productId!,
          movementType: StockMovementType.stockOut,
          quantity: qtyOut,
          partyLabel: partyLabel,
          referenceType: StockMovementRef.sale,
          referenceId: invoiceNumber,
          dateTime: dateTime,
          notes: 'Invoice $invoiceNumber',
        );
      }

      // Step 2: Advance wallet + payment rows (must exist before ledger FKs).
      String? walletPaymentId;
      String? cashPaymentId;

      if (usesAdvanceWallet) {
        await txn.update(
          ZamindarTable.name,
          {ZamindarTable.advanceBalance: remainingAdvance.round()},
          where: '${ZamindarTable.id} = ?',
          whereArgs: [advanceZamindarId],
        );

        walletPaymentId = await generateNextPaymentId(txn, isAdvance: false);
        await txn.insert(PaymentsTable.name, {
          PaymentsTable.paymentId: walletPaymentId,
          PaymentsTable.invoiceNumber: invoiceNumber,
          PaymentsTable.dateTime: _formatDateTime(dateTime),
          PaymentsTable.zamindarId: resolvedZamindarId,
          PaymentsTable.kisaanId: resolvedKisaanId,
          PaymentsTable.amountPaid: drawdown.round(),
          PaymentsTable.paymentMethod: 'Advance Wallet Deduction',
          PaymentsTable.season: season,
        });

        if (remainingPhysicalCash > 0) {
          cashPaymentId = await generateNextPaymentId(txn, isAdvance: false);
          await txn.insert(PaymentsTable.name, {
            PaymentsTable.paymentId: cashPaymentId,
            PaymentsTable.invoiceNumber: invoiceNumber,
            PaymentsTable.dateTime: _formatDateTime(dateTime),
            PaymentsTable.zamindarId: resolvedZamindarId,
            PaymentsTable.kisaanId: resolvedKisaanId,
            PaymentsTable.amountPaid: remainingPhysicalCash.round(),
            PaymentsTable.paymentMethod: 'Cash',
            PaymentsTable.season: season,
          });
        }
      } else if (hasCreditCashPayment) {
        cashPaymentId = await generateNextPaymentId(txn, isAdvance: false);
        await txn.insert(PaymentsTable.name, {
          PaymentsTable.paymentId: cashPaymentId,
          PaymentsTable.invoiceNumber: invoiceNumber,
          PaymentsTable.dateTime: _formatDateTime(dateTime),
          PaymentsTable.zamindarId: resolvedZamindarId,
          PaymentsTable.kisaanId: resolvedKisaanId,
          PaymentsTable.amountPaid: effectivePaidAmount.round(),
          PaymentsTable.paymentMethod: 'Cash',
          PaymentsTable.season: season,
        });
      }
      // Ledger CREDIT rows for payments are created by after_payment_insert.

      await _recalculateZamindarBalanceOn(txn, resolvedZamindarId);
    });

    notifyListeners();

    return {
      'success': true,
      'zamindarName': zamindarName,
      'kisaanName': kisaanName,
      'totalAdvanceBefore': totalAdvanceBefore,
      'deductedAmount': drawdown,
      'remainingAdvance': remainingAdvance,
      'remainingPhysicalCash': remainingPhysicalCash,
      'hadAdvanceDeduction': isCashSale && drawdown > 0,
    };
  }

  /// Records a Cash / Diesel / Petrol advance to a Kisaan on the Zamindar khata.
  ///
  /// Always credit (udhaar) with payment term **After Harvest**. Increments
  /// outstanding via [recalculateZamindarBalance]. Cash advances reduce the
  /// dashboard cash-in-hand aggregation; fuel advances do not.
  Future<Map<String, dynamic>> insertKisaanAdvance({
    required String invoiceNumber,
    required DateTime dateTime,
    required int zamindarId,
    required String zamindarName,
    int? kisaanId,
    String? kisaanName,
    required String transactionType,
    required double amount,
    double? fuelQuantityLiters,
    String? remarks,
    required String season,
  }) async {
    if (!SaleTransactionType.isAdvance(transactionType)) {
      throw ArgumentError(
        'transactionType must be a kisaan advance kind, got: $transactionType',
      );
    }
    if (amount <= 0) {
      throw ArgumentError('Advance amount must be greater than zero.');
    }
    if (SaleTransactionType.isFuelAdvance(transactionType) &&
        (fuelQuantityLiters == null || fuelQuantityLiters <= 0)) {
      throw ArgumentError(
        'Fuel advances require a positive quantity in liters.',
      );
    }

    final displayName = SaleTransactionType.displayLabel(transactionType);
    final liters = SaleTransactionType.isFuelAdvance(transactionType)
        ? fuelQuantityLiters
        : null;
    final trimmedRemarks = remarks?.trim();
    final itemLabel = liters != null
        ? '$displayName (${_formatLiters(liters)} L)'
        : displayName;

    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(SalesTable.name, {
        SalesTable.invoiceNumber: invoiceNumber,
        SalesTable.dateTime: _formatDateTime(dateTime),
        SalesTable.subtotal: amount.round(),
        SalesTable.itemDiscountsTotal: 0,
        SalesTable.seasonalIncrementTotal: 0,
        SalesTable.overallDiscount: 0,
        SalesTable.totalPayable: amount.round(),
        SalesTable.paidAmount: 0,
        SalesTable.paymentMethod: 'Credit',
        SalesTable.season: season,
        SalesTable.paymentTerm: 'After Harvest',
        SalesTable.transactionType: transactionType,
        SalesTable.creditAmount: amount.round(),
        SalesTable.fuelQuantity: liters,
        SalesTable.remarks:
            (trimmedRemarks != null && trimmedRemarks.isNotEmpty)
            ? trimmedRemarks
            : null,
        SalesTable.zamindarId: zamindarId,
        SalesTable.kisaanId: kisaanId,
      });
      // after_sale_insert trigger writes advance DEBIT ledger row.

      // Liters live on sales.fuel_quantity; line qty stays 1 so reports
      // that multiply qty × unit price stay accurate.
      await txn.insert(SaleItemsTable.name, {
        SaleItemsTable.invoiceNumber: invoiceNumber,
        SaleItemsTable.productName: itemLabel,
        SaleItemsTable.productType: 'Advance',
        SaleItemsTable.quantity: 1,
        SaleItemsTable.unitPrice: amount.round(),
        SaleItemsTable.seasonalIncrement: 0,
        SaleItemsTable.itemDiscount: 0,
        SaleItemsTable.subtotal: amount.round(),
      });

      await _recalculateZamindarBalanceOn(txn, zamindarId);
    });

    notifyListeners();

    return {
      'success': true,
      'invoiceNumber': invoiceNumber,
      'zamindarId': zamindarId,
      'kisaanId': kisaanId,
      'transactionType': transactionType,
      'totalPayable': amount,
      'creditAmount': amount,
      'fuelQuantity': liters,
      'affectsCashDrawer': transactionType == SaleTransactionType.cashAdvance,
    };
  }

  String _formatLiters(double liters) {
    if (liters == liters.roundToDouble()) {
      return liters.toStringAsFixed(0);
    }
    return liters
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  /// Gets all sales with their associated items and payments
  Future<List<Map<String, dynamic>>> getAllSalesWithDetails({
    String? season,
  }) async {
    final db = await database;

    final seasonClause =
        season != null ? 'WHERE s.${SalesTable.season} = ?' : '';
    final salesMaps = await db.rawQuery(
      '''
      SELECT
        s.*,
        z.${ZamindarTable.nameColumn} AS ${SalesTable.zamindarName},
        k.${KisaanTable.nameColumn} AS ${SalesTable.kisaanName}
      FROM ${SalesTable.name} s
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
      LEFT JOIN ${KisaanTable.name} k
        ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
      $seasonClause
      ORDER BY s.${SalesTable.dateTime} DESC
      ''',
      season != null ? [season] : [],
    );

    final salesWithDetails = <Map<String, dynamic>>[];

    for (final saleMap in salesMaps) {
      final invoiceNumber = saleMap[SalesTable.invoiceNumber] as String;

      // Get line items for this invoice
      final itemsMaps = await db.query(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      // Get payments for this invoice
      final paymentsMaps = await db.query(
        PaymentsTable.name,
        where: '${PaymentsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      // Calculate total collected (initial paid + subsequent payments)
      final initialPaid =
          (saleMap[SalesTable.paidAmount] as num?)?.toDouble() ?? 0.0;
      final totalCollected = _sumPaymentsCollected(initialPaid, paymentsMaps);

      salesWithDetails.add({
        'sale': saleMap,
        'items': itemsMaps,
        'payments': paymentsMaps,
        'totalCollected': totalCollected,
      });
    }

    return salesWithDetails;
  }

  /// Season performance KPIs for the Reports screen.
  ///
  /// Returns:
  /// - `totalPurchases` — hardcoded `0` until the Purchase module exists
  /// - `totalRevenue`, `cashSales`, `creditSales`
  /// - `netProfit` — Σ quantity × (retail_price − cost_price) on sold items
  /// - `totalMarketDebt`, `highRiskDues`, `todaysRecovery`, `dailyTarget`
  /// - `collectionEfficiency` — recovered credit / credit sales × 100
  /// - `season` — season display name used for the aggregation
  Future<Map<String, dynamic>> getSeasonalMetrics({String? season}) async {
    final db = await database;
    final seasonName = season ?? SeasonUtils.getCurrentSeason().displayName;

    final revenueRows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(${SalesTable.totalPayable}), 0) AS total_revenue,
        COALESCE(SUM(CASE
          WHEN ${SalesTable.paymentMethod} = 'Cash'
          THEN ${SalesTable.totalPayable} ELSE 0 END), 0) AS cash_sales,
        COALESCE(SUM(CASE
          WHEN ${SalesTable.paymentMethod} = 'Credit'
          THEN ${SalesTable.totalPayable} ELSE 0 END), 0) AS credit_sales
      FROM ${SalesTable.name}
      WHERE ${SalesTable.season} = ?
      ''',
      [seasonName],
    );

    final totalRevenue =
        (revenueRows.first['total_revenue'] as num?)?.toDouble() ?? 0.0;
    final cashSales =
        (revenueRows.first['cash_sales'] as num?)?.toDouble() ?? 0.0;
    final creditSales =
        (revenueRows.first['credit_sales'] as num?)?.toDouble() ?? 0.0;

    // Net profit from sold inventory: qty × (retail − cost).
    final profitRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(
        si.${SaleItemsTable.quantity} * (
          COALESCE(p.${ProductTable.retailPrice}, si.${SaleItemsTable.unitPrice})
          - COALESCE(p.${ProductTable.costPrice}, 0)
        )
      ), 0) AS net_profit
      FROM ${SaleItemsTable.name} si
      INNER JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = si.${SaleItemsTable.invoiceNumber}
      LEFT JOIN ${ProductTable.name} p
        ON p.${ProductTable.nameColumn} = si.${SaleItemsTable.productName}
      WHERE s.${SalesTable.season} = ?
      ''',
      [seasonName],
    );
    final netProfit =
        (profitRows.first['net_profit'] as num?)?.toDouble() ?? 0.0;

    // Outstanding figures use the same sales/payments formula as Dashboard.
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final outstandingRows = await db.rawQuery('''
      SELECT
        s.${SalesTable.season} AS season,
        s.${SalesTable.paymentMethod} AS payment_method,
        s.${SalesTable.dateTime} AS date_time,
        ($_sqlSaleRemainingExpr) AS remaining
      FROM ${SalesTable.name} s
    ''');

    var totalMarketDebt = 0.0;
    var highRiskDues = 0.0;
    var creditOutstandingSeason = 0.0;

    for (final row in outstandingRows) {
      final remaining = (row['remaining'] as num?)?.toDouble() ?? 0.0;
      if (remaining <= 0.005) continue;

      totalMarketDebt += remaining;

      final saleSeason = row['season'] as String? ?? '';
      final paymentMethod = row['payment_method'] as String? ?? '';
      if (saleSeason == seasonName && paymentMethod == 'Credit') {
        creditOutstandingSeason += remaining;
      }

      final saleDate = _parseDateTime(row['date_time'] as String? ?? '');
      if (now.difference(saleDate).inDays > 180) {
        highRiskDues += remaining;
      }
    }

    // Today's recovery: cash-like collections dated today.
    final paymentRows = await db.query(PaymentsTable.name);
    var todaysRecovery = 0.0;
    for (final payment in paymentRows) {
      final amount =
          (payment[PaymentsTable.amountPaid] as num?)?.toDouble() ?? 0.0;
      if (amount <= 0) continue;
      final paidAt = _parseDateTime(
        payment[PaymentsTable.dateTime] as String? ?? '',
      );
      if (!paidAt.isBefore(todayStart) &&
          paidAt.isBefore(todayStart.add(const Duration(days: 1)))) {
        todaysRecovery += amount;
      }
    }

    const dailyTarget = 100000.0;
    final recoveredCredit = (creditSales - creditOutstandingSeason).clamp(
      0.0,
      double.infinity,
    );
    final collectionEfficiency = creditSales > 0
        ? (recoveredCredit / creditSales) * 100.0
        : 0.0;

    return {
      'season': seasonName,
      'totalPurchases': 0.0,
      'totalRevenue': totalRevenue,
      'cashSales': cashSales,
      'creditSales': creditSales,
      'netProfit': netProfit,
      'totalMarketDebt': totalMarketDebt,
      'highRiskDues': highRiskDues,
      'todaysRecovery': todaysRecovery,
      'dailyTarget': dailyTarget,
      'collectionEfficiency': collectionEfficiency,
    };
  }

  /// Credit aging buckets and capital trapped by product category.
  /// Outstanding per invoice uses the same formula as Dashboard receivables.
  Future<Map<String, dynamic>> getAnalyticalInsights() async {
    final db = await database;
    final now = DateTime.now();

    var currentAmt = 0.0;
    var overdueAmt = 0.0;
    var criticalAmt = 0.0;
    final capitalByCategory = <String, double>{
      'Fertilizers': 0.0,
      'Seeds': 0.0,
      'Pesticides': 0.0,
    };

    final invoiceRows = await db.rawQuery('''
      SELECT
        s.${SalesTable.invoiceNumber} AS invoice_number,
        s.${SalesTable.dateTime} AS date_time,
        ($_sqlSaleRemainingExpr) AS remaining
      FROM ${SalesTable.name} s
    ''');

    final allItems = await db.query(SaleItemsTable.name);
    final itemsByInvoice = <String, List<Map<String, dynamic>>>{};
    for (final item in allItems) {
      final invoice = item[SaleItemsTable.invoiceNumber] as String? ?? '';
      if (invoice.isEmpty) continue;
      itemsByInvoice.putIfAbsent(invoice, () => []).add(item);
    }

    for (final row in invoiceRows) {
      final remaining = (row['remaining'] as num?)?.toDouble() ?? 0.0;
      if (remaining <= 0.005) continue;

      final invoiceNumber = row['invoice_number'] as String? ?? '';
      final saleDate = _parseDateTime(row['date_time'] as String? ?? '');
      final ageDays = now.difference(saleDate).inDays;
      if (ageDays < 90) {
        currentAmt += remaining;
      } else if (ageDays <= 180) {
        overdueAmt += remaining;
      } else {
        criticalAmt += remaining;
      }

      final items = itemsByInvoice[invoiceNumber] ?? const [];

      // Allocate outstanding proportionally across line items by subtotal.
      final invoiceSubtotal = items.fold<double>(
        0.0,
        (sum, item) =>
            sum + ((item[SaleItemsTable.subtotal] as num?)?.toDouble() ?? 0.0),
      );

      if (invoiceSubtotal <= 0 || items.isEmpty) {
        capitalByCategory['Fertilizers'] =
            (capitalByCategory['Fertilizers'] ?? 0) + remaining;
        continue;
      }

      for (final item in items) {
        final lineSubtotal =
            (item[SaleItemsTable.subtotal] as num?)?.toDouble() ?? 0.0;
        final share = remaining * (lineSubtotal / invoiceSubtotal);
        final category = _normalizeProductCategory(
          item[SaleItemsTable.productType] as String? ?? 'Fertilizer',
        );
        capitalByCategory[category] =
            (capitalByCategory[category] ?? 0.0) + share;
      }
    }

    final totalAging = currentAmt + overdueAmt + criticalAmt;
    double pct(double amount) =>
        totalAging > 0 ? (amount / totalAging) * 100.0 : 0.0;

    final maxCapital = capitalByCategory.values.fold<double>(
      0.0,
      (m, v) => v > m ? v : m,
    );

    final capitalTrapped =
        capitalByCategory.entries.map((e) {
          return {
            'category': e.key,
            'amount': e.value,
            'ratio': maxCapital > 0 ? e.value / maxCapital : 0.0,
          };
        }).toList()..sort(
          (a, b) => ((b['amount'] as num).toDouble()).compareTo(
            (a['amount'] as num).toDouble(),
          ),
        );

    return {
      'creditAging': {
        'currentAmount': currentAmt,
        'overdueAmount': overdueAmt,
        'criticalAmount': criticalAmt,
        'currentPercent': pct(currentAmt),
        'overduePercent': pct(overdueAmt),
        'criticalPercent': pct(criticalAmt),
        'total': totalAging,
      },
      'capitalTrapped': capitalTrapped,
    };
  }

  /// Zamindars with outstanding credit, optionally filtered by search,
  /// village, and payment agreement.
  Future<List<Map<String, dynamic>>> getOutstandingCreditDirectory({
    String? search,
    String? village,
    String? paymentTerm,
  }) async {
    final db = await database;

    final whereParts = <String>[];
    final whereArgs = <Object?>[];

    // Soft-exclude drafts when the column is present.
    whereParts.add(
      '(${ZamindarTable.isDraft} IS NULL OR ${ZamindarTable.isDraft} = 0)',
    );

    final searchQuery = search?.trim() ?? '';
    if (searchQuery.isNotEmpty) {
      whereParts.add(
        '(LOWER(${ZamindarTable.nameColumn}) LIKE ? OR '
        'LOWER(COALESCE(${ZamindarTable.village}, \'\')) LIKE ?)',
      );
      final like = '%${searchQuery.toLowerCase()}%';
      whereArgs.addAll([like, like]);
    }

    final villageFilter = village?.trim() ?? '';
    if (villageFilter.isNotEmpty &&
        villageFilter.toLowerCase() != 'all villages') {
      whereParts.add('LOWER(COALESCE(${ZamindarTable.village}, \'\')) = ?');
      whereArgs.add(villageFilter.toLowerCase());
    }

    final zamindarRows = await db.query(
      ZamindarTable.name,
      where: whereParts.isEmpty ? null : whereParts.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: '${ZamindarTable.nameColumn} ASC',
    );

    final now = DateTime.now();

    // Aggregate outstanding + last activity per zamindar name using the
    // shared sales/payments remaining formula (same as Dashboard).
    final outstandingByName = <String, double>{};
    final lastActiveByName = <String, DateTime>{};
    final dominantTermByName = <String, String?>{};
    final dominantTermWeight = <String, double>{};
    final oldestUnpaidAgeByName = <String, int>{};

    final saleRows = await db.rawQuery('''
      SELECT
        s.${SalesTable.invoiceNumber} AS invoice_number,
        z.${ZamindarTable.nameColumn} AS zamindar_name,
        s.${SalesTable.dateTime} AS date_time,
        s.${SalesTable.paymentTerm} AS payment_term,
        ($_sqlSaleRemainingExpr) AS remaining
      FROM ${SalesTable.name} s
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
    ''');

    final paymentRows = await db.rawQuery('''
      SELECT
        p.${PaymentsTable.invoiceNumber} AS invoice_number,
        p.${PaymentsTable.dateTime} AS date_time,
        COALESCE(
          z.${ZamindarTable.nameColumn},
          zs.${ZamindarTable.nameColumn}
        ) AS zamindar_name
      FROM ${PaymentsTable.name} p
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = p.${PaymentsTable.zamindarId}
      LEFT JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = p.${PaymentsTable.invoiceNumber}
      LEFT JOIN ${ZamindarTable.name} zs
        ON zs.${ZamindarTable.id} = s.${SalesTable.zamindarId}
    ''');
    final paymentDatesByInvoice = <String, List<DateTime>>{};
    for (final payment in paymentRows) {
      final invoice = payment['invoice_number'] as String?;
      final paidAt = _parseDateTime(
        payment['date_time'] as String? ?? '',
      );
      if (invoice != null && invoice.isNotEmpty) {
        paymentDatesByInvoice.putIfAbsent(invoice, () => []).add(paidAt);
      }
      // Advance / unscoped payments still count toward last activity by name.
      final payee = (payment['zamindar_name'] as String? ?? '').trim();
      if (payee.isNotEmpty) {
        final prev = lastActiveByName[payee];
        if (prev == null || paidAt.isAfter(prev)) {
          lastActiveByName[payee] = paidAt;
        }
      }
    }

    for (final sale in saleRows) {
      final name = (sale['zamindar_name'] as String? ?? '').trim();
      if (name.isEmpty) continue;

      final invoiceNumber = sale['invoice_number'] as String? ?? '';
      final remaining = (sale['remaining'] as num?)?.toDouble() ?? 0.0;

      final saleDate = _parseDateTime(sale['date_time'] as String? ?? '');
      final prevActive = lastActiveByName[name];
      if (prevActive == null || saleDate.isAfter(prevActive)) {
        lastActiveByName[name] = saleDate;
      }

      for (final paidAt in paymentDatesByInvoice[invoiceNumber] ?? const []) {
        final prev = lastActiveByName[name];
        if (prev == null || paidAt.isAfter(prev)) {
          lastActiveByName[name] = paidAt;
        }
      }

      if (remaining <= 0.005) continue;

      outstandingByName[name] = (outstandingByName[name] ?? 0.0) + remaining;

      final ageDays = now.difference(saleDate).inDays;
      final prevAge = oldestUnpaidAgeByName[name] ?? 0;
      if (ageDays > prevAge) {
        oldestUnpaidAgeByName[name] = ageDays;
      }

      final term = sale['payment_term'] as String?;
      if (term != null && term.trim().isNotEmpty) {
        final weight = dominantTermWeight[name] ?? 0.0;
        if (remaining >= weight) {
          dominantTermWeight[name] = remaining;
          dominantTermByName[name] = term.trim();
        }
      }
    }

    final termFilter = paymentTerm?.trim() ?? '';
    final ignoreTermFilter =
        termFilter.isEmpty || termFilter.toLowerCase() == 'all terms';

    final results = <Map<String, dynamic>>[];

    for (final row in zamindarRows) {
      final zamindar = Zamindar.fromMap(row);
      final name = zamindar.name.trim();
      final balance = outstandingByName[name] ?? 0.0;
      if (balance <= 0.005) continue;

      final oldestAge = oldestUnpaidAgeByName[name] ?? 0;
      final isOverduePastSeason = oldestAge > 180;

      var rawTerm = dominantTermByName[name];
      if (rawTerm == null || rawTerm.isEmpty) {
        rawTerm = zamindar.paymentTerms.isNotEmpty
            ? zamindar.paymentTerms.first
            : null;
      }

      final displayTerm = _toDisplayPaymentTerm(
        rawTerm,
        isOverduePastSeason: isOverduePastSeason,
      );

      if (!ignoreTermFilter) {
        final matches = _paymentTermMatchesFilter(
          filter: termFilter,
          rawTerm: rawTerm,
          displayTerm: displayTerm,
          isOverduePastSeason: isOverduePastSeason,
        );
        if (!matches) continue;
      }

      // Village search also covers walk-in names when SQL missed them —
      // already SQL-filtered for registered zamindars.
      results.add({
        'zamindarId': zamindar.id,
        'name': name,
        'village': zamindar.village?.trim().isNotEmpty == true
            ? zamindar.village!.trim()
            : (zamindar.locationGoth?.trim().isNotEmpty == true
                  ? zamindar.locationGoth!.trim()
                  : '—'),
        'outstandingBalance': balance,
        'paymentTerm': displayTerm,
        'paymentTermRaw': rawTerm,
        'lastActiveAt': lastActiveByName[name],
        'lastActiveLabel': _formatRelativeActivity(lastActiveByName[name]),
        'whatsappNumber': zamindar.whatsappNumber,
        'isCritical': isOverduePastSeason || balance >= 400000,
        'oldestUnpaidDays': oldestAge,
      });
    }

    // Include outstanding sales for names not in the zamindar table
    // (walk-in / deleted), still respecting search/village/term filters.
    for (final entry in outstandingByName.entries) {
      final name = entry.key;
      if (results.any((r) => r['name'] == name)) continue;

      final searchLower = searchQuery.toLowerCase();
      if (searchLower.isNotEmpty && !name.toLowerCase().contains(searchLower)) {
        continue;
      }
      if (villageFilter.isNotEmpty &&
          villageFilter.toLowerCase() != 'all villages') {
        continue;
      }

      final oldestAge = oldestUnpaidAgeByName[name] ?? 0;
      final isOverduePastSeason = oldestAge > 180;
      final rawTerm = dominantTermByName[name];
      final displayTerm = _toDisplayPaymentTerm(
        rawTerm,
        isOverduePastSeason: isOverduePastSeason,
      );

      if (!ignoreTermFilter) {
        final matches = _paymentTermMatchesFilter(
          filter: termFilter,
          rawTerm: rawTerm,
          displayTerm: displayTerm,
          isOverduePastSeason: isOverduePastSeason,
        );
        if (!matches) continue;
      }

      results.add({
        'zamindarId': null,
        'name': name,
        'village': '—',
        'outstandingBalance': entry.value,
        'paymentTerm': displayTerm,
        'paymentTermRaw': rawTerm,
        'lastActiveAt': lastActiveByName[name],
        'lastActiveLabel': _formatRelativeActivity(lastActiveByName[name]),
        'whatsappNumber': null,
        'isCritical': isOverduePastSeason || entry.value >= 400000,
        'oldestUnpaidDays': oldestAge,
      });
    }

    results.sort(
      (a, b) => ((b['outstandingBalance'] as num).toDouble()).compareTo(
        (a['outstandingBalance'] as num).toDouble(),
      ),
    );
    return results;
  }

  /// Distinct non-empty villages for Reports filter dropdowns.
  Future<List<String>> getDistinctVillages() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT DISTINCT TRIM(${ZamindarTable.village}) AS village
      FROM ${ZamindarTable.name}
      WHERE ${ZamindarTable.village} IS NOT NULL
        AND TRIM(${ZamindarTable.village}) != ''
      ORDER BY village COLLATE NOCASE ASC
      ''');
    return rows
        .map((r) => (r['village'] as String?)?.trim() ?? '')
        .where((v) => v.isNotEmpty)
        .toList();
  }

  /// Generic name auto-suggest for form fields (Zamindar / Kisaan / Wholesaler / Employee).
  ///
  /// Returns up to 5 distinct matching names using `WHERE name LIKE '%query%'`.
  /// [tableName] must be a known entity table — arbitrary SQL identifiers are rejected.
  Future<List<String>> fetchNameSuggestions(
    String tableName,
    String query,
  ) async {
    const allowedTables = <String>{
      ZamindarTable.name,
      KisaanTable.name,
      WholesalerTable.name,
      EmployeeTable.name,
    };
    if (!allowedTables.contains(tableName)) {
      throw ArgumentError.value(
        tableName,
        'tableName',
        'Unsupported table for name suggestions',
      );
    }

    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT DISTINCT TRIM(name) AS name
      FROM $tableName
      WHERE name IS NOT NULL
        AND TRIM(name) != ''
        AND name LIKE ?
      ORDER BY name COLLATE NOCASE ASC
      LIMIT 5
      ''',
      ['%$trimmed%'],
    );

    return rows
        .map((r) => (r['name'] as String?)?.trim() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
  }

  static String _normalizeProductCategory(String raw) {
    final lower = raw.trim().toLowerCase();
    if (lower.contains('fert')) return 'Fertilizers';
    if (lower.contains('seed')) return 'Seeds';
    if (lower.contains('pest') || lower.contains('herb')) {
      return 'Pesticides';
    }
    if (lower.isEmpty) return 'Fertilizers';
    return raw.trim();
  }

  /// Maps stored payment-term values to Reports UI labels.
  static String _toDisplayPaymentTerm(
    String? raw, {
    required bool isOverduePastSeason,
  }) {
    if (isOverduePastSeason) return 'Overdue / Past Season';
    final value = raw?.trim() ?? '';
    switch (value) {
      case 'After Harvest':
      case 'Harvest Settlement':
        return 'Harvest Settlement';
      case '90 days':
      case '90-Day Cycle':
        return '90-Day Cycle';
      case 'After a Week':
        return 'After a Week';
      case 'After a Month':
        return 'After a Month';
      case 'Overdue / Past Season':
        return 'Overdue / Past Season';
      default:
        return value.isNotEmpty ? value : '90-Day Cycle';
    }
  }

  static bool _paymentTermMatchesFilter({
    required String filter,
    required String? rawTerm,
    required String displayTerm,
    required bool isOverduePastSeason,
  }) {
    final f = filter.trim().toLowerCase();
    if (f == 'overdue / past season' || f == 'overdue') {
      return isOverduePastSeason ||
          displayTerm.toLowerCase() == 'overdue / past season';
    }

    final normalizedFilter = _toDisplayPaymentTerm(
      filter,
      isOverduePastSeason: false,
    ).toLowerCase();
    final normalizedRaw = _toDisplayPaymentTerm(
      rawTerm,
      isOverduePastSeason: false,
    ).toLowerCase();

    return displayTerm.toLowerCase() == normalizedFilter ||
        normalizedRaw == normalizedFilter ||
        (rawTerm?.trim().toLowerCase() == f);
  }

  static String _formatRelativeActivity(DateTime? dateTime) {
    if (dateTime == null) return '—';
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return 'Just Now';
    if (diff.inHours < 1) return '${diff.inMinutes} min Ago';
    if (diff.inHours < 24) {
      return diff.inHours == 1 ? '1 Hour Ago' : '${diff.inHours} Hours Ago';
    }
    if (diff.inDays == 1) return '1 Day Ago';
    if (diff.inDays < 7) return '${diff.inDays} Days Ago';
    if (diff.inDays < 30) {
      final weeks = (diff.inDays / 7).floor();
      return weeks <= 1 ? '1 Week Ago' : '$weeks Weeks Ago';
    }
    if (diff.inDays < 365) {
      final months = (diff.inDays / 30).floor();
      return months <= 1 ? '1 Month Ago' : '$months Months Ago';
    }
    final years = (diff.inDays / 365).floor();
    return years <= 1 ? '1 Year Ago' : '$years Years Ago';
  }

  /// Gets sales for a specific zamindar
  Future<List<Map<String, dynamic>>> getSalesForZamindar(
    String zamindarName, {
    String? season,
  }) async {
    final db = await database;
    final salesMaps = await db.rawQuery(
      '''
      SELECT
        s.*,
        z.${ZamindarTable.nameColumn} AS ${SalesTable.zamindarName},
        k.${KisaanTable.nameColumn} AS ${SalesTable.kisaanName}
      FROM ${SalesTable.name} s
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
      LEFT JOIN ${KisaanTable.name} k
        ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
      WHERE z.${ZamindarTable.nameColumn} = ?
      ORDER BY s.${SalesTable.dateTime} DESC
      ''',
      [zamindarName],
    );

    final salesWithDetails = <Map<String, dynamic>>[];

    for (final saleMap in salesMaps) {
      final invoiceNumber = saleMap[SalesTable.invoiceNumber] as String;

      final itemsMaps = await db.query(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      final paymentsMaps = await db.query(
        PaymentsTable.name,
        where: '${PaymentsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      final initialPaid =
          (saleMap[SalesTable.paidAmount] as num?)?.toDouble() ?? 0.0;
      final totalCollected = _sumPaymentsCollected(initialPaid, paymentsMaps);

      salesWithDetails.add({
        'sale': saleMap,
        'items': itemsMaps,
        'payments': paymentsMaps,
        'totalCollected': totalCollected,
      });
    }

    return salesWithDetails;
  }

  /// Flat sales rows for Zamindar Ledger PDF export.
  ///
  /// Each map: invoice_number, date_time, kisaan_name, products,
  /// products_qty, cost_per_product, payment_type, total, paid, remaining.
  Future<List<Map<String, dynamic>>> getZamindarLedgerPdfRows({
    required int zamindarId,
    Set<String>? seasons,
  }) async {
    final db = await database;
    final salesMaps = await db.rawQuery(
      '''
      SELECT
        s.${SalesTable.invoiceNumber} AS invoice_number,
        s.${SalesTable.dateTime} AS date_time,
        s.${SalesTable.season} AS season,
        s.${SalesTable.paymentMethod} AS payment_method,
        s.${SalesTable.paymentTerm} AS payment_term,
        s.${SalesTable.totalPayable} AS total,
        ($_sqlSaleCollectedExpr) AS paid,
        ($_sqlSaleRemainingExpr) AS remaining,
        COALESCE(
          NULLIF(TRIM(k.${KisaanTable.nameColumn}), ''),
          'Self'
        ) AS kisaan_name,
        s.${SalesTable.kisaanId} AS kisaan_id
      FROM ${SalesTable.name} s
      LEFT JOIN ${KisaanTable.name} k
        ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
      WHERE s.${SalesTable.zamindarId} = ?
      ORDER BY s.${SalesTable.dateTime} DESC
      ''',
      [zamindarId],
    );

    final seasonFilter = seasons
        ?.map((s) => s.trim())
        .where((s) => s.isNotEmpty && s.toLowerCase() != 'all seasons')
        .toSet();

    final rows = <Map<String, dynamic>>[];
    for (final sale in salesMaps) {
      final season = (sale['season'] as String?)?.trim() ?? '';
      if (seasonFilter != null && seasonFilter.isNotEmpty) {
        final seasonLower = season.toLowerCase();
        final matches = seasonFilter.any((selected) {
          final s = selected.toLowerCase();
          if (s == seasonLower) return true;
          if (season.isEmpty) return true;
          final family = seasonLower.contains('rabi')
              ? 'rabi'
              : seasonLower.contains('kharif')
                  ? 'kharif'
                  : null;
          return family != null && s.contains(family);
        });
        if (!matches) continue;
      }

      final invoice =
          (sale['invoice_number'] as String?)?.trim() ?? '';
      if (invoice.isEmpty) continue;

      final items = await db.query(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoice],
        orderBy: '${SaleItemsTable.id} ASC',
      );

      final productNames = <String>[];
      final qtyParts = <String>[];
      final costParts = <String>[];
      for (final item in items) {
        final name =
            (item[SaleItemsTable.productName] as String?)?.trim() ?? '';
        if (name.isEmpty) continue;
        final qty = (item[SaleItemsTable.quantity] as num?)?.toDouble() ?? 0;
        final unit =
            (item[SaleItemsTable.unitPrice] as num?)?.toDouble() ?? 0;
        final seasonal =
            (item[SaleItemsTable.seasonalIncrement] as num?)?.toDouble() ??
                0;
        final unitCost = unit + seasonal;
        productNames.add(name);
        qtyParts.add(
          qty == qty.roundToDouble()
              ? qty.toStringAsFixed(0)
              : qty.toStringAsFixed(1),
        );
        costParts.add('Rs ${_formatIntMoney(unitCost)}');
      }

      final paymentMethod =
          (sale['payment_method'] as String?)?.trim() ?? '';
      final paymentTerm = (sale['payment_term'] as String?)?.trim() ?? '';
      final paymentType = paymentMethod.isNotEmpty
          ? paymentMethod
          : (paymentTerm.isNotEmpty ? paymentTerm : '-');

      DateTime? dateTime;
      final dateRaw = sale['date_time'] as String?;
      if (dateRaw != null && dateRaw.isNotEmpty) {
        dateTime = DateTime.tryParse(dateRaw);
      }

      rows.add({
        'invoice_number': invoice,
        'date_time': dateTime ?? dateRaw,
        'kisaan_name': (sale['kisaan_name'] as String?)?.trim() ?? 'Self',
        'kisaan_id': sale['kisaan_id'],
        'products':
            productNames.isEmpty ? '-' : productNames.join(', '),
        'products_qty': qtyParts.isEmpty ? '-' : qtyParts.join(', '),
        'cost_per_product':
            costParts.isEmpty ? '-' : costParts.join(', '),
        'payment_type': paymentType,
        'total': (sale['total'] as num?)?.toDouble() ?? 0.0,
        'paid': (sale['paid'] as num?)?.toDouble() ?? 0.0,
        'remaining': (sale['remaining'] as num?)?.toDouble() ?? 0.0,
        'season': season,
      });
    }

    return rows;
  }

  String _formatIntMoney(double value) {
    final rounded = value.round();
    final formatted = rounded.toString();
    final chars = formatted.split('').reversed.toList();
    final buffer = StringBuffer();
    for (int i = 0; i < chars.length; i++) {
      buffer.write(chars[i]);
      final pos = i + 1;
      if (pos == 3 || (pos > 3 && (pos - 3) % 2 == 0)) {
        if (i != chars.length - 1) buffer.write(',');
      }
    }
    return buffer.toString().split('').reversed.join('');
  }

  /// Inserts a payment settlement for a specific invoice.
  /// [invoiceNumber] must reference an existing sale — never pass synthetic values.
  Future<String> insertPayment({
    String? paymentId,
    required String invoiceNumber,
    required int zamindarId,
    required DateTime dateTime,
    required String zamindarName,
    String? kisaanName,
    int? kisaanId,
    required double amountPaid,
    required String paymentMethod,
    required String season,
  }) async {
    if (invoiceNumber.trim().isEmpty) {
      throw ArgumentError(
        'invoiceNumber is required for invoice-scoped settlements.',
      );
    }

    final remainingBalance = await getInvoiceRemainingBalance(invoiceNumber);
    if (amountPaid > remainingBalance + 0.01) {
      throw StateError(
        'Payment amount exceeds invoice remaining balance '
        '(Rs ${remainingBalance.toStringAsFixed(0)}).',
      );
    }

    final db = await database;
    late final String resolvedPaymentId;
    await db.transaction((txn) async {
      resolvedPaymentId =
          paymentId ?? await generateNextPaymentId(txn, isAdvance: false);

      await txn.insert(PaymentsTable.name, {
        PaymentsTable.paymentId: resolvedPaymentId,
        PaymentsTable.invoiceNumber: invoiceNumber,
        PaymentsTable.dateTime: _formatDateTime(dateTime),
        PaymentsTable.zamindarId: zamindarId,
        PaymentsTable.kisaanId: kisaanId,
        PaymentsTable.amountPaid: amountPaid.round(),
        PaymentsTable.paymentMethod: paymentMethod,
        PaymentsTable.season: season,
      });
      // after_payment_insert trigger writes the ledger CREDIT row.

      await _recalculateZamindarBalanceOn(txn, zamindarId);
    });

    notifyListeners();
    return resolvedPaymentId;
  }

  /// Outstanding debt for a Kisaan based on sales minus all payments collected.
  /// Uses the same collected/remaining formula as dashboard & zamindar balances.
  Future<double> getKisaanSalesOutstandingDebt({
    required int zamindarId,
    required String kisaanName,
  }) async {
    final zamindar = await getZamindar(zamindarId);
    if (zamindar == null) return 0.0;

    final db = await database;
    final rows = await db.rawQuery(
      '''
        SELECT COALESCE(SUM($_sqlSaleRemainingExpr), 0) AS outstanding
        FROM ${SalesTable.name} s
        LEFT JOIN ${KisaanTable.name} k
          ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
        WHERE s.${SalesTable.zamindarId} = ?
          AND (
            k.${KisaanTable.nameColumn} = ?
            OR (s.${SalesTable.kisaanId} IS NULL AND ? = 'Self')
          )
      ''',
      [zamindarId, kisaanName, kisaanName],
    );
    return (rows.first['outstanding'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getKisaanSalesOutstandingDebtById({
    required int zamindarId,
    required int kisaanId,
  }) async {
    final kisaan = await getKisaan(kisaanId);
    if (kisaan == null) return 0.0;
    return getKisaanSalesOutstandingDebt(
      zamindarId: zamindarId,
      kisaanName: kisaan.name,
    );
  }

  /// Allocates a bulk Kisaan payment across unpaid invoices oldest-first (FIFO).
  Future<void> settleKisaanBulkPayment({
    required int zamindarId,
    required String kisaanName,
    required double amountPaid,
    required String paymentMethod,
    required String season,
  }) async {
    if (amountPaid <= 0) {
      throw ArgumentError('amountPaid must be greater than zero.');
    }

    final outstanding = await getKisaanSalesOutstandingDebt(
      zamindarId: zamindarId,
      kisaanName: kisaanName,
    );
    if (amountPaid > outstanding + 0.01) {
      throw StateError(
        'Payment amount exceeds Kisaan outstanding debt '
        '(Rs ${outstanding.toStringAsFixed(0)}).',
      );
    }

    final zamindar = await getZamindar(zamindarId);
    if (zamindar == null) {
      throw StateError('Zamindar not found.');
    }

    int? kisaanId;
    final kisaans = await getKisaansForZamindar(zamindarId);
    for (final k in kisaans) {
      if (k.name == kisaanName) {
        kisaanId = k.id;
        break;
      }
    }

    final db = await database;
    await db.transaction((txn) async {
      double remainingCash = amountPaid;

      final List<Map<String, dynamic>> invoices = await txn.rawQuery(
        '''
          SELECT s.${SalesTable.invoiceNumber},
                 s.${SalesTable.totalPayable},
                 s.${SalesTable.zamindarId},
                 s.${SalesTable.paidAmount}
          FROM ${SalesTable.name} s
          LEFT JOIN ${KisaanTable.name} k
            ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
          WHERE s.${SalesTable.zamindarId} = ?
            AND (
              k.${KisaanTable.nameColumn} = ?
              OR (s.${SalesTable.kisaanId} IS NULL AND ? = 'Self')
            )
          ORDER BY s.${SalesTable.dateTime} ASC
        ''',
        [zamindarId, kisaanName, kisaanName],
      );

      for (var inv in invoices) {
        if (remainingCash <= 0) break;

        final invoiceNumber = inv[SalesTable.invoiceNumber] as String;
        final totalPayable = (inv[SalesTable.totalPayable] as num).toDouble();
        final initialPaid = (inv[SalesTable.paidAmount] as num).toDouble();

        final paymentsResult = await txn.rawQuery(
          '''
            SELECT COALESCE(SUM(${PaymentsTable.amountPaid}), 0) AS total_collected
            FROM ${PaymentsTable.name}
            WHERE ${PaymentsTable.invoiceNumber} = ?
          ''',
          [invoiceNumber],
        );
        final additionalPayments =
            (paymentsResult.first['total_collected'] as num).toDouble();

        final remainingDebt = totalPayable - initialPaid - additionalPayments;
        if (remainingDebt <= 0) continue;

        final allocation = remainingCash >= remainingDebt
            ? remainingDebt
            : remainingCash;
        final now = DateTime.now();
        final paymentId = await generateNextPaymentId(txn, isAdvance: false);

        await txn.insert(PaymentsTable.name, {
          PaymentsTable.paymentId: paymentId,
          PaymentsTable.invoiceNumber: invoiceNumber,
          PaymentsTable.dateTime: _formatDateTime(now),
          PaymentsTable.zamindarId: zamindarId,
          PaymentsTable.kisaanId: kisaanId,
          PaymentsTable.amountPaid: allocation.round(),
          PaymentsTable.paymentMethod: paymentMethod,
          PaymentsTable.season: season,
        });
        // after_payment_insert trigger writes the ledger CREDIT row.

        remainingCash -= allocation;
      }
    });

    notifyListeners();
  }

  /// Records a kisaan-level settlement via FIFO invoice allocation.
  Future<void> recordKisaanSettlement({
    required int zamindarId,
    required int kisaanId,
    required double amountPaid,
    required String season,
    String paymentMethod = 'Cash',
  }) async {
    final kisaan = await getKisaan(kisaanId);
    if (kisaan == null) {
      throw StateError('Kisaan not found.');
    }
    await settleKisaanBulkPayment(
      zamindarId: zamindarId,
      kisaanName: kisaan.name,
      amountPaid: amountPaid,
      paymentMethod: paymentMethod,
      season: season,
    );
  }

  /// Gets all payments with aggregated sale line items for linked invoices.
  Future<List<Map<String, dynamic>>> getAllPayments({String? season}) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];

    if (season != null) {
      where.add('p.${PaymentsTable.season} = ?');
      args.add(season);
    }

    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    return db.rawQuery('''
      SELECT
        p.*,
        COALESCE(
          z.${ZamindarTable.nameColumn},
          zs.${ZamindarTable.nameColumn}
        ) AS ${PaymentsTable.zamindarName},
        COALESCE(
          k.${KisaanTable.nameColumn},
          ks.${KisaanTable.nameColumn}
        ) AS ${PaymentsTable.kisaanName},
        CASE
          WHEN p.${PaymentsTable.invoiceNumber} IS NULL
            THEN 'N/A (Advance Collection)'
          ELSE (
            SELECT GROUP_CONCAT(
              item.${SaleItemsTable.productName}
                || ' x'
                || CAST(item.${SaleItemsTable.quantity} AS TEXT),
              ', '
            )
            FROM ${SaleItemsTable.name} item
            WHERE item.${SaleItemsTable.invoiceNumber}
                = p.${PaymentsTable.invoiceNumber}
          )
        END AS ${PaymentsTable.itemsSummary}
      FROM ${PaymentsTable.name} p
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = p.${PaymentsTable.zamindarId}
      LEFT JOIN ${KisaanTable.name} k
        ON k.${KisaanTable.id} = p.${PaymentsTable.kisaanId}
      LEFT JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = p.${PaymentsTable.invoiceNumber}
      LEFT JOIN ${ZamindarTable.name} zs
        ON zs.${ZamindarTable.id} = s.${SalesTable.zamindarId}
      LEFT JOIN ${KisaanTable.name} ks
        ON ks.${KisaanTable.id} = s.${SalesTable.kisaanId}
      $whereSql
      ORDER BY p.${PaymentsTable.dateTime} DESC
      ''', args);
  }

  /// Gets payments for a specific invoice
  Future<List<Map<String, dynamic>>> getPaymentsForInvoice(
    String invoiceNumber,
  ) async {
    final db = await database;
    return await db.query(
      PaymentsTable.name,
      where: '${PaymentsTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
      orderBy: '${PaymentsTable.dateTime} DESC',
    );
  }

  /// Calculates remaining balance for an invoice using the shared sales/payments
  /// formula (same as dashboard receivables & zamindar balances).
  Future<double> getInvoiceRemainingBalance(String invoiceNumber) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT
        s.${SalesTable.totalPayable} - ($_sqlSaleCollectedExpr) AS remaining
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.invoiceNumber} = ?
      LIMIT 1
      ''',
      [invoiceNumber],
    );
    if (rows.isEmpty) return 0.0;
    return (rows.first['remaining'] as num?)?.toDouble() ?? 0.0;
  }

  /// Updates an existing sale and fully resyncs payments + ledger rows so
  /// Main Ledger, Zamindar Ledger, and Dashboard share one financial truth.
  Future<void> updateSaleInNewSchema({
    required String invoiceNumber,
    required DateTime dateTime,
    required String zamindarName,
    String? kisaanName,
    required List<SaleLineItem> items,
    required double overallDiscount,
    required double paidAmount,
    required String paymentMethod,
    required String productType,
    required String season,
    String? paymentTerm,
  }) async {
    final isCashSale = paymentMethod == 'Cash';
    final isCreditSale = paymentMethod == 'Credit';
    final db = await database;
    final affectedZamindarIds = <int>{};

    await db.transaction((txn) async {
      final existingSale = await txn.query(
        SalesTable.name,
        columns: [SalesTable.zamindarId],
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (existingSale.isEmpty) {
        throw StateError('Invoice $invoiceNumber was not found.');
      }

      final previousZamindarId =
          existingSale.first[SalesTable.zamindarId] as int?;
      if (previousZamindarId != null) {
        affectedZamindarIds.add(previousZamindarId);
      }

      // Restore stock for old line items.
      final oldItems = await txn.query(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      for (final oldItem in oldItems) {
        final productName = oldItem[SaleItemsTable.productName] as String;
        final oldQuantity =
            (oldItem[SaleItemsTable.quantity] as num?)?.toInt() ?? 0;
        final products = await txn.query(
          ProductTable.name,
          where: '${ProductTable.nameColumn} = ?',
          whereArgs: [productName],
          limit: 1,
        );
        if (products.isEmpty) continue;
        final productId = products.first[ProductTable.id] as int;
        final currentStock = _readIntValue(
          products.first[ProductTable.availableStock],
        );
        await txn.update(
          ProductTable.name,
          {
            ProductTable.availableStock: (currentStock + oldQuantity).clamp(
              0,
              1 << 31,
            ),
          },
          where: '${ProductTable.id} = ?',
          whereArgs: [productId],
        );
      }

      await txn.delete(
        StockMovementTable.name,
        where:
            '${StockMovementTable.referenceType} = ? AND '
            '${StockMovementTable.referenceId} = ?',
        whereArgs: [StockMovementRef.sale, invoiceNumber],
      );

      await txn.delete(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      // Undo prior wallet drawdowns, then drop sale-originated money rows.
      await _reverseInvoiceWalletDrawdowns(txn, invoiceNumber);
      await _clearSaleOriginatedFinancials(txn, invoiceNumber);

      final subtotal = items.fold<double>(
        0.0,
        (sum, item) => sum + (item.qty * item.unitPrice),
      );
      final itemDiscountsTotal = items.fold<double>(
        0.0,
        (sum, item) => sum + item.discount,
      );
      const seasonalIncrementTotal = 0.0;
      final totalPayable =
          subtotal +
          seasonalIncrementTotal -
          itemDiscountsTotal -
          overallDiscount;

      var effectivePaidAmount = paidAmount;
      var drawdown = 0.0;
      var remainingAdvance = 0.0;
      var remainingPhysicalCash = totalPayable;
      int? advanceZamindarId;

      if (isCashSale) {
        final zamindarRows = await txn.query(
          ZamindarTable.name,
          columns: [ZamindarTable.id, ZamindarTable.advanceBalance],
          where: '${ZamindarTable.nameColumn} = ?',
          whereArgs: [zamindarName],
          limit: 1,
        );
        if (zamindarRows.isNotEmpty) {
          advanceZamindarId = zamindarRows.first[ZamindarTable.id] as int;
          final originalAdvanceBalance = _readIntValue(
            zamindarRows.first[ZamindarTable.advanceBalance],
          );
          drawdown = totalPayable >= originalAdvanceBalance
              ? originalAdvanceBalance.toDouble()
              : totalPayable;
          remainingAdvance = originalAdvanceBalance - drawdown;
          remainingPhysicalCash = totalPayable - drawdown;
          effectivePaidAmount = remainingPhysicalCash;
        }
      }

      if (isCreditSale) {
        if (effectivePaidAmount < 0) effectivePaidAmount = 0;
        if (effectivePaidAmount > totalPayable) {
          effectivePaidAmount = totalPayable;
        }
        remainingPhysicalCash = effectivePaidAmount;
      }

      final usesAdvanceWallet =
          isCashSale && drawdown > 0 && advanceZamindarId != null;
      final hasCreditCashPayment = isCreditSale && effectivePaidAmount > 0;
      final salePaidAmount = (usesAdvanceWallet || hasCreditCashPayment)
          ? 0.0
          : effectivePaidAmount;
      final creditAmount = isCreditSale
          ? (totalPayable - effectivePaidAmount).clamp(0.0, totalPayable)
          : 0.0;

      int? resolvedZamindarId = advanceZamindarId;
      resolvedZamindarId ??=
          await _resolveZamindarIdByName(txn, zamindarName);
      int? resolvedKisaanId;
      if (resolvedZamindarId != null &&
          kisaanName != null &&
          kisaanName.isNotEmpty &&
          kisaanName != 'Self') {
        final kisaanRows = await txn.query(
          KisaanTable.name,
          columns: [KisaanTable.id],
          where:
              '${KisaanTable.zamindarId} = ? AND ${KisaanTable.nameColumn} = ?',
          whereArgs: [resolvedZamindarId, kisaanName],
          limit: 1,
        );
        if (kisaanRows.isNotEmpty) {
          resolvedKisaanId = kisaanRows.first[KisaanTable.id] as int?;
        }
      }

      if (resolvedZamindarId == null) {
        throw StateError(
          'Cannot update sale: zamindar "$zamindarName" was not resolved to an id.',
        );
      }

      await txn.update(
        SalesTable.name,
        {
          SalesTable.dateTime: _formatDateTime(dateTime),
          SalesTable.subtotal: subtotal.round(),
          SalesTable.itemDiscountsTotal: itemDiscountsTotal.round(),
          SalesTable.seasonalIncrementTotal: seasonalIncrementTotal.round(),
          SalesTable.overallDiscount: overallDiscount.round(),
          SalesTable.totalPayable: totalPayable.round(),
          SalesTable.paidAmount: salePaidAmount.round(),
          SalesTable.paymentMethod: paymentMethod,
          SalesTable.season: season,
          SalesTable.paymentTerm: isCreditSale ? paymentTerm : null,
          SalesTable.transactionType: SaleTransactionType.productSale,
          SalesTable.creditAmount: creditAmount.round(),
          SalesTable.zamindarId: resolvedZamindarId,
          SalesTable.kisaanId: resolvedKisaanId,
        },
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      // after_sale_update trigger refreshes the sale DEBIT ledger row.

      for (final item in items) {
        final itemSubtotal = (item.qty * item.unitPrice) - item.discount;
        await txn.insert(SaleItemsTable.name, {
          SaleItemsTable.invoiceNumber: invoiceNumber,
          SaleItemsTable.productName: item.productName,
          SaleItemsTable.productType: productType,
          SaleItemsTable.quantity: item.qty.round(),
          SaleItemsTable.unitPrice: item.unitPrice.round(),
          SaleItemsTable.seasonalIncrement: 0,
          SaleItemsTable.itemDiscount: item.discount.round(),
          SaleItemsTable.subtotal: itemSubtotal.round(),
        });
      }

      final partyLabel = await _resolveSalePartyLabel(txn, zamindarName);
      for (final item in items) {
        if (item.productId == null) continue;
        final rows = await txn.query(
          ProductTable.name,
          columns: [ProductTable.availableStock],
          where: '${ProductTable.id} = ?',
          whereArgs: [item.productId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final currentStock = _readIntValue(
          rows.first[ProductTable.availableStock],
        );
        final qtyOut = item.qty.ceil();
        await txn.update(
          ProductTable.name,
          {
            ProductTable.availableStock: (currentStock - qtyOut).clamp(
              0,
              1 << 31,
            ),
          },
          where: '${ProductTable.id} = ?',
          whereArgs: [item.productId],
        );
        await _insertStockMovement(
          txn,
          productId: item.productId!,
          movementType: StockMovementType.stockOut,
          quantity: qtyOut,
          partyLabel: partyLabel,
          referenceType: StockMovementRef.sale,
          referenceId: invoiceNumber,
          dateTime: dateTime,
          notes: 'Invoice $invoiceNumber',
        );
      }

      String? walletPaymentId;
      String? cashPaymentId;

      if (usesAdvanceWallet) {
        await txn.update(
          ZamindarTable.name,
          {ZamindarTable.advanceBalance: remainingAdvance.round()},
          where: '${ZamindarTable.id} = ?',
          whereArgs: [advanceZamindarId],
        );

        walletPaymentId = await generateNextPaymentId(txn, isAdvance: false);
        await txn.insert(PaymentsTable.name, {
          PaymentsTable.paymentId: walletPaymentId,
          PaymentsTable.invoiceNumber: invoiceNumber,
          PaymentsTable.dateTime: _formatDateTime(dateTime),
          PaymentsTable.zamindarId: resolvedZamindarId,
          PaymentsTable.kisaanId: resolvedKisaanId,
          PaymentsTable.amountPaid: drawdown.round(),
          PaymentsTable.paymentMethod: 'Advance Wallet Deduction',
          PaymentsTable.season: season,
        });

        if (remainingPhysicalCash > 0) {
          cashPaymentId = await generateNextPaymentId(txn, isAdvance: false);
          await txn.insert(PaymentsTable.name, {
            PaymentsTable.paymentId: cashPaymentId,
            PaymentsTable.invoiceNumber: invoiceNumber,
            PaymentsTable.dateTime: _formatDateTime(dateTime),
            PaymentsTable.zamindarId: resolvedZamindarId,
            PaymentsTable.kisaanId: resolvedKisaanId,
            PaymentsTable.amountPaid: remainingPhysicalCash.round(),
            PaymentsTable.paymentMethod: 'Cash',
            PaymentsTable.season: season,
          });
        }
      } else if (hasCreditCashPayment) {
        cashPaymentId = await generateNextPaymentId(txn, isAdvance: false);
        await txn.insert(PaymentsTable.name, {
          PaymentsTable.paymentId: cashPaymentId,
          PaymentsTable.invoiceNumber: invoiceNumber,
          PaymentsTable.dateTime: _formatDateTime(dateTime),
          PaymentsTable.zamindarId: resolvedZamindarId,
          PaymentsTable.kisaanId: resolvedKisaanId,
          PaymentsTable.amountPaid: effectivePaidAmount.round(),
          PaymentsTable.paymentMethod: 'Cash',
          PaymentsTable.season: season,
        });
      }
      // Ledger CREDIT rows for payments are created by after_payment_insert.

      affectedZamindarIds.add(resolvedZamindarId);
      for (final id in affectedZamindarIds) {
        await _recalculateZamindarBalanceOn(txn, id);
      }
    });

    notifyListeners();
  }

  // -----------------------------
  // Advance Payment Methods
  // -----------------------------

  /// Updates the advance balance for a Zamindar
  Future<int> updateAdvanceBalance(int zamindarId, int newBalance) async {
    final db = await database;
    final result = await db.update(
      ZamindarTable.name,
      {ZamindarTable.advanceBalance: newBalance},
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
    );
    notifyListeners();
    return result;
  }

  /// Gets the current advance balance for a Zamindar
  Future<int> getAdvanceBalance(int zamindarId) async {
    final db = await database;
    final result = await db.query(
      ZamindarTable.name,
      columns: [ZamindarTable.advanceBalance],
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
      limit: 1,
    );

    if (result.isEmpty) return 0;
    return _readIntValue(result.first[ZamindarTable.advanceBalance]);
  }

  /// Adds to the advance balance and creates a ledger entry
  Future<void> receiveAdvancePayment({
    required int zamindarId,
    required int amount,
    required DateTime dateTime,
    required String season,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final zamindarMaps = await txn.query(
        ZamindarTable.name,
        columns: [ZamindarTable.advanceBalance],
        where: '${ZamindarTable.id} = ?',
        whereArgs: [zamindarId],
        limit: 1,
      );

      if (zamindarMaps.isEmpty) {
        throw StateError('Zamindar not found.');
      }

      final currentBalance = _readIntValue(
        zamindarMaps.first[ZamindarTable.advanceBalance],
      );
      final newBalance = currentBalance + amount;

      await txn.update(
        ZamindarTable.name,
        {ZamindarTable.advanceBalance: newBalance},
        where: '${ZamindarTable.id} = ?',
        whereArgs: [zamindarId],
      );

      final paymentId = await generateNextPaymentId(txn, isAdvance: true);
      final formattedDateTime = _formatDateTime(dateTime);

      await txn.insert(PaymentsTable.name, {
        PaymentsTable.paymentId: paymentId,
        PaymentsTable.invoiceNumber: null,
        PaymentsTable.dateTime: formattedDateTime,
        PaymentsTable.zamindarId: zamindarId,
        PaymentsTable.kisaanId: null,
        PaymentsTable.amountPaid: amount,
        PaymentsTable.paymentMethod: 'Cash',
        PaymentsTable.season: season,
      });
      // after_payment_insert trigger writes ADVANCE_PAYMENT ledger CREDIT.
    });

    notifyListeners();
  }

  /// Gets the 'Self' Kisaan for a Zamindar
  Future<Kisaan?> getSelfKisaan(int zamindarId) async {
    final db = await database;
    final maps = await db.query(
      KisaanTable.name,
      where: '${KisaanTable.zamindarId} = ? AND ${KisaanTable.nameColumn} = ?',
      whereArgs: [zamindarId, 'Self'],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Kisaan.fromMap(maps.first);
  }
}

/// =========================
/// Strongly Typed Schema
/// =========================

class ZamindarTable {
  static const String name = 'zamindars';
  static const String id = 'id';
  static const String nameColumn = 'name';
  static const String fathersName = 'fathers_name';
  static const String whatsappNumber = 'whatsapp_number';
  static const String locationGoth = 'location_goth';
  static const String village = 'village';
  static const String description = 'description';
  static const String creditLimit = 'credit_limit';
  static const String landArea = 'land_area';
  static const String landUnit = 'land_unit';
  static const String paymentTerms = 'payment_terms';
  static const String activeSeasons = 'active_seasons';
  static const String activeCrops = 'active_crops';
  static const String isDraft = 'is_draft';
  static const String advanceBalance = 'advance_balance';
  /// Cached outstanding udhaar: SUM(invoice totals) − SUM(collections).
  /// Always refreshed via [DatabaseHelper.recalculateZamindarBalance].
  static const String currentBalance = 'current_balance';
}

class KisaanTable {
  static const String name = 'kisaans';
  static const String id = 'id';
  static const String zamindarId = 'zamindar_id';
  static const String nameColumn = 'name';
  static const String village = 'village';
  static const String phone = 'phone';
  static const String landAcres = 'land_acres';
  static const String currentCrop = 'current_crop';
}

class ProductTable {
  static const String name = 'products';
  static const String id = 'id';
  static const String nameColumn = 'name';
  static const String brand = 'brand';
  static const String productType = 'product_type';
  static const String packagingSize = 'packaging_size';
  static const String costPrice = 'cost_price';
  static const String retailPrice = 'retail_price';
  static const String seasonalIncrement = 'seasonal_increment';
  static const String availableStock = 'available_stock';
  static const String uom = 'uom';
  static const String expiryDate = 'expiry_date';
  static const String lowStockThreshold = 'low_stock_threshold';
  static const String description = 'description';
}

class LedgerTransactionTable {
  static const String name = 'ledger_transactions';
  static const String id = 'id';
  static const String zamindarId = 'zamindar_id';
  static const String kisaanId = 'kisaan_id';

  // ➕ New Explicit Linkage Keys
  static const String invoiceNumber = 'invoice_number';
  static const String paymentId = 'payment_id';

  static const String type = 'type';
  static const String category = 'category';
  static const String description = 'description';
  static const String amount = 'amount';
  static const String dateTime = 'date_time';
  static const String season = 'season';
}

class LedgerTransactionType {
  static const String debit = 'DEBIT';
  static const String credit = 'CREDIT';
}

class SalesTable {
  static const String name = 'sales';
  static const String invoiceNumber = 'invoice_number';
  static const String dateTime = 'date_time';
  /// JOIN alias only — not a physical column after schema v26.
  static const String zamindarName = 'zamindar_name';
  /// JOIN alias only — not a physical column after schema v26.
  static const String kisaanName = 'kisaan_name';
  static const String subtotal = 'subtotal';
  static const String itemDiscountsTotal = 'item_discounts_total';
  static const String seasonalIncrementTotal = 'seasonal_increment_total';
  static const String overallDiscount = 'overall_discount';
  static const String totalPayable = 'total_payable';
  static const String paidAmount = 'paid_amount';
  static const String paymentMethod = 'payment_method';
  static const String season = 'season';
  static const String paymentTerm = 'payment_term';
  static const String transactionType = 'transaction_type';
  static const String creditAmount = 'credit_amount';
  static const String fuelQuantity = 'fuel_quantity';
  static const String remarks = 'remarks';
  static const String zamindarId = 'zamindar_id';
  static const String kisaanId = 'kisaan_id';
}

/// Sale / advance kinds stored on [SalesTable.transactionType].
class SaleTransactionType {
  static const String productSale = 'PRODUCT_SALE';
  static const String cashAdvance = 'CASH_ADVANCE';
  static const String dieselAdvance = 'DIESEL_ADVANCE';
  static const String petrolAdvance = 'PETROL_ADVANCE';

  static const Set<String> advances = {
    cashAdvance,
    dieselAdvance,
    petrolAdvance,
  };

  static bool isAdvance(String? type) =>
      type != null && advances.contains(type);

  static bool isFuelAdvance(String? type) =>
      type == dieselAdvance || type == petrolAdvance;

  static String displayLabel(String type) {
    switch (type) {
      case cashAdvance:
        return 'Cash Advance';
      case dieselAdvance:
        return 'Diesel Advance';
      case petrolAdvance:
        return 'Petrol Advance';
      default:
        return 'Product Sale';
    }
  }
}

class SaleItemsTable {
  static const String name = 'sale_items';
  static const String id = 'id';
  static const String invoiceNumber = 'invoice_number';
  static const String productName = 'product_name';
  static const String productType = 'product_type';
  static const String quantity = 'quantity';
  static const String unitPrice = 'unit_price';
  static const String seasonalIncrement = 'seasonal_increment';
  static const String itemDiscount = 'item_discount';
  static const String subtotal = 'subtotal';
}

class PaymentsTable {
  static const String name = 'payments';
  static const String paymentId = 'payment_id';
  static const String invoiceNumber = 'invoice_number';
  static const String dateTime = 'date_time';
  static const String zamindarId = 'zamindar_id';
  static const String kisaanId = 'kisaan_id';
  /// JOIN alias only — not a physical column after schema v26.
  static const String zamindarName = 'zamindar_name';
  /// JOIN alias only — not a physical column after schema v26.
  static const String kisaanName = 'kisaan_name';
  static const String amountPaid = 'amount_paid';
  static const String paymentMethod = 'payment_method';
  static const String season = 'season';

  /// Query alias: aggregated sale line items or advance-collection label.
  static const String itemsSummary = 'items_summary';
}

class StockMovementTable {
  static const String name = 'stock_movements';
  static const String id = 'id';
  static const String productId = 'product_id';
  static const String movementType = 'movement_type';
  static const String quantity = 'quantity';
  static const String partyLabel = 'party_label';
  static const String referenceType = 'reference_type';
  static const String referenceId = 'reference_id';
  static const String dateTime = 'date_time';
  static const String notes = 'notes';
}

class StockMovementType {
  static const String stockIn = 'STOCK_IN';
  static const String stockOut = 'STOCK_OUT';
}

class StockMovementRef {
  static const String sale = 'SALE';
  static const String restock = 'RESTOCK';
  static const String create = 'CREATE';
  static const String adjust = 'ADJUST';
  static const String purchase = 'PURCHASE';
}

class WholesalerTable {
  static const String name = 'wholesalers';
  static const String id = 'id';
  static const String nameColumn = 'name';
  static const String city = 'city';
  static const String phone = 'phone';
  static const String balance = 'balance';
}

class PurchaseInvoicesTable {
  static const String name = 'purchase_invoices';
  static const String invoiceNumber = 'invoice_number';
  static const String wholesalerId = 'wholesaler_id';
  /// JOIN alias only — not a physical column after schema v26.
  static const String wholesalerName = 'wholesaler_name';
  static const String dateTime = 'date_time';
  static const String subtotal = 'subtotal';
  static const String transportCharges = 'transport_charges';
  static const String grandTotal = 'grand_total';
  static const String paymentType = 'payment_type';
  static const String amountPaid = 'amount_paid';
  static const String outstanding = 'outstanding';
  static const String description = 'description';
}

class PurchaseItemsTable {
  static const String name = 'purchase_items';
  static const String id = 'id';
  static const String invoiceNumber = 'invoice_number';
  static const String productId = 'product_id';
  static const String productName = 'product_name';
  static const String quantity = 'quantity';
  static const String purchaseRate = 'purchase_rate';
  static const String expiryDate = 'expiry_date';
  static const String lineTotal = 'line_total';
}

class WholesalerLedgerTable {
  static const String name = 'wholesaler_ledger';
  static const String id = 'id';
  static const String wholesalerId = 'wholesaler_id';
  static const String transactionType = 'transaction_type';
  static const String referenceId = 'reference_id';
  static const String date = 'date';
  static const String debit = 'debit';
  static const String credit = 'credit';
  /// Computed in SELECT via window function — not a physical column after v26.
  static const String runningBalance = 'running_balance';
  static const String description = 'description';
}

class WholesalerLedgerTxnType {
  static const String purchase = 'Purchase';
  static const String payment = 'Payment';
}

class WholesalerPaymentsTable {
  static const String name = 'wholesaler_payments';
  static const String id = 'id';
  static const String wholesalerId = 'wholesaler_id';
  static const String amount = 'amount';
  static const String paymentMethod = 'payment_method';
  static const String paymentSource = 'payment_source';
  static const String referenceNo = 'reference_no';
  static const String date = 'date';
  static const String notes = 'notes';

  /// Query alias: aggregated purchase line items or clearance label.
  static const String itemsSummary = 'items_summary';
}

class WholesalerPaymentSource {
  static const String cashPurchaseOutlay = 'Cash Purchase Outlay';
  static const String manualKhataPayment = 'Manual Khata Payment';
}

class ExpenseTable {
  static const String name = 'expenses';
  static const String id = 'id';
  static const String category = 'category';
  static const String amount = 'amount';
  static const String remarks = 'remarks';
  static const String expenseDate = 'expense_date';
  static const String employeeId = 'employee_id';
  static const String payrollType = 'payroll_type';
}

class EmployeeTable {
  static const String name = 'employees';
  static const String id = 'id';
  static const String nameColumn = 'name';
  static const String phone = 'phone';
  static const String role = 'role';
  static const String salaryType = 'salary_type';
  static const String baseSalary = 'base_salary';
  static const String createdAt = 'created_at';
  static const String isActive = 'is_active';
}

class EmployeeAttendanceTable {
  static const String name = 'employee_attendance';
  static const String attendanceId = 'attendance_id';
  static const String employeeId = 'employee_id';
  static const String date = 'date';
  static const String status = 'status';
}

class EmployeeSalaryType {
  static const String monthly = 'monthly';
  static const String daily = 'daily';
}

class AttendanceStatus {
  static const String present = 'PRESENT';
  static const String absent = 'ABSENT';
  static const String halfDay = 'HALF_DAY';
}

class ExpensePayrollType {
  static const String kharchi = 'kharchi';
  static const String settlement = 'settlement';
}

class PurchasePaymentType {
  static const String udhaar = 'Udhaar';
  static const String cash = 'Cash';
  static const String partial = 'Partial';
}

/// =========================
/// Models
/// =========================

class ZamindarLandAllocationSummary {
  final double totalLand;
  final double allocatedLand;
  final double remainingLand;
  final String landUnit;

  const ZamindarLandAllocationSummary({
    required this.totalLand,
    required this.allocatedLand,
    required this.remainingLand,
    required this.landUnit,
  });
}

class Zamindar {
  final int? id;
  final String name;
  final String? fathersName;
  final String whatsappNumber;
  final String? locationGoth;
  final String? village;
  final String? description;
  final int creditLimit;
  final double landArea;
  final String landUnit;
  final List<String> paymentTerms;
  final List<String> activeSeasons;
  final List<String> activeCrops;
  final double udhaarBalance;
  final int activeKisaans;
  final bool isOverLimit;
  final bool isDraft;
  final int advanceBalance;

  const Zamindar({
    this.id,
    required this.name,
    this.fathersName,
    required this.whatsappNumber,
    this.locationGoth,
    this.village,
    this.description,
    required this.creditLimit,
    required this.landArea,
    required this.landUnit,
    required this.paymentTerms,
    this.activeSeasons = const [],
    this.activeCrops = const [],
    this.udhaarBalance = 0,
    this.activeKisaans = 0,
    this.isOverLimit = false,
    this.isDraft = false,
    this.advanceBalance = 0,
  });

  double get totalLandAcres => landArea;
  String get villageDisplay => village ?? locationGoth ?? 'Unknown location';
  String get paymentTermsDisplay =>
      paymentTerms.isEmpty ? '—' : paymentTerms.join(' · ');

  Zamindar copyWith({
    int? id,
    String? name,
    String? fathersName,
    String? whatsappNumber,
    String? locationGoth,
    String? village,
    String? description,
    int? creditLimit,
    double? landArea,
    String? landUnit,
    List<String>? paymentTerms,
    List<String>? activeSeasons,
    List<String>? activeCrops,
    double? udhaarBalance,
    int? activeKisaans,
    bool? isOverLimit,
    bool? isDraft,
    int? advanceBalance,
  }) {
    return Zamindar(
      id: id ?? this.id,
      name: name ?? this.name,
      fathersName: fathersName ?? this.fathersName,
      whatsappNumber: whatsappNumber ?? this.whatsappNumber,
      locationGoth: locationGoth ?? this.locationGoth,
      village: village ?? this.village,
      description: description ?? this.description,
      creditLimit: creditLimit ?? this.creditLimit,
      landArea: landArea ?? this.landArea,
      landUnit: landUnit ?? this.landUnit,
      paymentTerms: paymentTerms ?? this.paymentTerms,
      activeSeasons: activeSeasons ?? this.activeSeasons,
      activeCrops: activeCrops ?? this.activeCrops,
      udhaarBalance: udhaarBalance ?? this.udhaarBalance,
      activeKisaans: activeKisaans ?? this.activeKisaans,
      isOverLimit: isOverLimit ?? this.isOverLimit,
      isDraft: isDraft ?? this.isDraft,
      advanceBalance: advanceBalance ?? this.advanceBalance,
    );
  }

  static int _parseIntValue(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static List<String> _parseCsvList(Object? value) {
    if (value is List) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final raw = value as String? ?? '';
    if (raw.isEmpty) return [];
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Map<String, Object?> toMap() => {
    if (id != null) ZamindarTable.id: id,
    ZamindarTable.nameColumn: name,
    ZamindarTable.fathersName: fathersName,
    ZamindarTable.whatsappNumber: whatsappNumber,
    ZamindarTable.locationGoth: locationGoth,
    ZamindarTable.village: village,
    ZamindarTable.description: description,
    ZamindarTable.creditLimit: creditLimit,
    ZamindarTable.landArea: landArea,
    ZamindarTable.landUnit: landUnit,
    ZamindarTable.paymentTerms: paymentTerms.join(','),
    ZamindarTable.activeSeasons: activeSeasons.join(','),
    ZamindarTable.activeCrops: activeCrops.join(','),
    ZamindarTable.isDraft: isDraft ? 1 : 0,
    ZamindarTable.advanceBalance: advanceBalance,
  };

  factory Zamindar.fromMap(Map<String, Object?> map) {
    return Zamindar(
      id: map[ZamindarTable.id] as int?,
      name: map[ZamindarTable.nameColumn] as String? ?? '',
      fathersName: map[ZamindarTable.fathersName] as String?,
      whatsappNumber: map[ZamindarTable.whatsappNumber] as String? ?? '',
      locationGoth: map[ZamindarTable.locationGoth] as String?,
      village: map[ZamindarTable.village] as String?,
      description: map[ZamindarTable.description] as String?,
      creditLimit: _parseIntValue(map[ZamindarTable.creditLimit]),
      landArea: (map[ZamindarTable.landArea] as num?)?.toDouble() ?? 0,
      landUnit: map[ZamindarTable.landUnit] as String? ?? 'Acre',
      paymentTerms: _parseCsvList(map[ZamindarTable.paymentTerms]),
      activeSeasons: _parseCsvList(map[ZamindarTable.activeSeasons]),
      activeCrops: _parseCsvList(map[ZamindarTable.activeCrops]),
      isDraft: _parseIntValue(map[ZamindarTable.isDraft]) == 1,
      advanceBalance: _parseIntValue(map[ZamindarTable.advanceBalance]),
    );
  }
}

class Kisaan {
  final int? id;
  final int zamindarId;
  final String name;
  final String village;
  final String? phone;
  final double landAcres;
  final String currentCrop;

  const Kisaan({
    this.id,
    required this.zamindarId,
    required this.name,
    required this.village,
    this.phone,
    required this.landAcres,
    required this.currentCrop,
  });

  Map<String, Object?> toMap() => {
    KisaanTable.zamindarId: zamindarId,
    KisaanTable.nameColumn: name,
    KisaanTable.village: village,
    KisaanTable.phone: phone,
    KisaanTable.landAcres: landAcres,
    KisaanTable.currentCrop: currentCrop,
  };

  factory Kisaan.fromMap(Map<String, Object?> map) {
    return Kisaan(
      id: map[KisaanTable.id] as int?,
      zamindarId: map[KisaanTable.zamindarId] as int,
      name: map[KisaanTable.nameColumn] as String,
      village: map[KisaanTable.village] as String,
      phone: map[KisaanTable.phone] as String?,
      landAcres: (map[KisaanTable.landAcres] as num).toDouble(),
      currentCrop: map[KisaanTable.currentCrop] as String,
    );
  }
}

class ProductItem {
  final int? id;
  final String name;
  final String brand;
  final String productType;
  final String packagingSize;
  final int costPrice;
  final int retailPrice;
  final int seasonalIncrement;
  final int availableStock;
  final String uom;
  final DateTime expiryDate;
  final int lowStockThreshold;
  final String? description;

  const ProductItem({
    this.id,
    required this.name,
    required this.brand,
    this.productType = 'Fertilizer',
    required this.packagingSize,
    required this.costPrice,
    required this.retailPrice,
    this.seasonalIncrement = 0,
    required this.availableStock,
    required this.uom,
    required this.expiryDate,
    required this.lowStockThreshold,
    this.description,
  });

  bool get isExpired => expiryDate.isBefore(DateTime.now());
  bool get isLowStock => !isExpired && availableStock <= lowStockThreshold;
  bool get isInStock => !isExpired && !isLowStock;

  String get statusLabel {
    if (isExpired) return "Expired";
    if (isLowStock) return "Low Stock";
    return "In Stock";
  }

  Map<String, Object?> toMap() => {
    ProductTable.nameColumn: name,
    ProductTable.brand: brand,
    ProductTable.productType: productType,
    ProductTable.packagingSize: packagingSize,
    ProductTable.costPrice: costPrice,
    ProductTable.retailPrice: retailPrice,
    ProductTable.seasonalIncrement: seasonalIncrement,
    ProductTable.availableStock: availableStock,
    ProductTable.uom: uom,
    ProductTable.expiryDate: DatabaseHelper._formatDateOnly(expiryDate),
    ProductTable.lowStockThreshold: lowStockThreshold,
    ProductTable.description: description,
  };

  factory ProductItem.fromMap(Map<String, Object?> map) {
    return ProductItem(
      id: map[ProductTable.id] as int?,
      name: map[ProductTable.nameColumn] as String,
      brand: map[ProductTable.brand] as String,
      productType: map[ProductTable.productType] as String? ?? 'Fertilizer',
      packagingSize: map[ProductTable.packagingSize] as String,
      costPrice: map[ProductTable.costPrice] as int,
      retailPrice: map[ProductTable.retailPrice] as int,
      seasonalIncrement: map[ProductTable.seasonalIncrement] as int? ?? 0,
      availableStock: map[ProductTable.availableStock] as int,
      uom: map[ProductTable.uom] as String,
      expiryDate: DatabaseHelper._parseDateOnly(
        map[ProductTable.expiryDate] as String,
      ),
      lowStockThreshold: map[ProductTable.lowStockThreshold] as int,
      description: map[ProductTable.description] as String?,
    );
  }
}

class LedgerTransaction {
  final int? id;
  final int zamindarId;
  final int? kisaanId;
  final String? invoiceNumber;
  final String? paymentId;
  final String type;
  final String category;
  final String description;
  final int amount;
  final DateTime dateTime;
  final String season;

  const LedgerTransaction({
    this.id,
    required this.zamindarId,
    this.kisaanId,
    this.invoiceNumber,
    this.paymentId,
    required this.type,
    required this.category,
    required this.description,
    required this.amount,
    required this.dateTime,
    required this.season,
  });

  Map<String, Object?> toMap() => {
    LedgerTransactionTable.zamindarId: zamindarId,
    LedgerTransactionTable.kisaanId: kisaanId,
    LedgerTransactionTable.invoiceNumber: invoiceNumber,
    LedgerTransactionTable.paymentId: paymentId,
    LedgerTransactionTable.type: type,
    LedgerTransactionTable.category: category,
    LedgerTransactionTable.description: description,
    LedgerTransactionTable.amount: amount,
    LedgerTransactionTable.dateTime: DatabaseHelper._formatDateTime(dateTime),
    LedgerTransactionTable.season: season,
  };

  factory LedgerTransaction.fromMap(Map<String, Object?> map) {
    return LedgerTransaction(
      id: map[LedgerTransactionTable.id] as int?,
      zamindarId: map[LedgerTransactionTable.zamindarId] as int,
      kisaanId: map[LedgerTransactionTable.kisaanId] as int?,
      invoiceNumber: map[LedgerTransactionTable.invoiceNumber] as String?,
      paymentId: map[LedgerTransactionTable.paymentId] as String?,
      type: map[LedgerTransactionTable.type] as String,
      category: map[LedgerTransactionTable.category] as String,
      description: map[LedgerTransactionTable.description] as String,
      amount: map[LedgerTransactionTable.amount] as int,
      dateTime: DatabaseHelper._parseDateTime(
        map[LedgerTransactionTable.dateTime] as String,
      ),
      season: map[LedgerTransactionTable.season] as String,
    );
  }
}

/// One sale line-item row for the Zamindar product-wise ledger panel.
class ZamindarProductLedgerEntry {
  final String invoiceNumber;
  final DateTime dateTime;
  final String kisaanName;
  final String productName;
  final int quantity;
  final String uom;

  const ZamindarProductLedgerEntry({
    required this.invoiceNumber,
    required this.dateTime,
    required this.kisaanName,
    required this.productName,
    required this.quantity,
    required this.uom,
  });
}

class ProductInventoryStatus {
  final int id;
  final String name;
  final String brand;
  final String packagingSize;
  final int availableStock;
  final int lowStockThreshold;
  final DateTime expiryDate;
  final String status;

  const ProductInventoryStatus({
    required this.id,
    required this.name,
    required this.brand,
    required this.packagingSize,
    required this.availableStock,
    required this.lowStockThreshold,
    required this.expiryDate,
    required this.status,
  });
}

class ProductInventorySummary {
  final int totalItems;
  final int lowStockCount;
  final int expiredCount;

  const ProductInventorySummary({
    required this.totalItems,
    required this.lowStockCount,
    required this.expiredCount,
  });
}

class DashboardLowStockAlert {
  final int productId;
  final String productName;
  final String brand;
  final String packagingSize;
  final int availableStock;
  final int lowStockThreshold;
  final String uom;

  const DashboardLowStockAlert({
    required this.productId,
    required this.productName,
    required this.brand,
    required this.packagingSize,
    required this.availableStock,
    required this.lowStockThreshold,
    required this.uom,
  });

  /// Display label matching the approved dashboard HTML (name + pack size).
  String get displayName {
    final pack = packagingSize.trim();
    if (pack.isEmpty) return productName;
    if (productName.contains(pack)) return productName;
    return '$productName ($pack)';
  }

  bool get isCritical => availableStock <= 5;
}

class DashboardExpiryAlert {
  final int? productId;
  final String productName;
  final String brand;
  final int quantity;
  final String uom;
  final DateTime expiryDate;
  final String? invoiceNumber;
  final String source;

  const DashboardExpiryAlert({
    this.productId,
    required this.productName,
    required this.brand,
    required this.quantity,
    required this.uom,
    required this.expiryDate,
    this.invoiceNumber,
    required this.source,
  });

  int get daysRemaining {
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    return expiryDate.difference(todayStart).inDays;
  }

  bool get isCritical => daysRemaining <= 30;
}

class DashboardRecoveryRow {
  final int? zamindarId;
  final String name;
  final double outstandingBalance;
  final String? whatsappNumber;
  final String paymentTerm;

  const DashboardRecoveryRow({
    this.zamindarId,
    required this.name,
    required this.outstandingBalance,
    this.whatsappNumber,
    required this.paymentTerm,
  });
}

class DashboardMetrics {
  final double totalReceivables;
  final double totalPayables;
  final double cashInHand;
  final double todayCashSales;
  final double todayLedgerPayments;
  final double todaySupplierCashPayments;
  final double todayCashSalesVolume;
  final double todayCreditSalesVolume;
  final int activeAccounts;
  final int activeZamindars;
  final int activeWholesalers;
  final List<DashboardLowStockAlert> lowStockAlerts;
  final List<DashboardExpiryAlert> expiryAlerts;
  final List<DashboardRecoveryRow> topRecoveries;

  const DashboardMetrics({
    required this.totalReceivables,
    required this.totalPayables,
    required this.cashInHand,
    required this.todayCashSales,
    required this.todayLedgerPayments,
    required this.todaySupplierCashPayments,
    required this.todayCashSalesVolume,
    required this.todayCreditSalesVolume,
    required this.activeAccounts,
    required this.activeZamindars,
    required this.activeWholesalers,
    required this.lowStockAlerts,
    required this.expiryAlerts,
    required this.topRecoveries,
  });

  factory DashboardMetrics.empty() {
    return const DashboardMetrics(
      totalReceivables: 0,
      totalPayables: 0,
      cashInHand: 0,
      todayCashSales: 0,
      todayLedgerPayments: 0,
      todaySupplierCashPayments: 0,
      todayCashSalesVolume: 0,
      todayCreditSalesVolume: 0,
      activeAccounts: 0,
      activeZamindars: 0,
      activeWholesalers: 0,
      lowStockAlerts: <DashboardLowStockAlert>[],
      expiryAlerts: <DashboardExpiryAlert>[],
      topRecoveries: <DashboardRecoveryRow>[],
    );
  }

  bool get hasOperationalAlerts =>
      lowStockAlerts.isNotEmpty || expiryAlerts.isNotEmpty;
}

class SaleLineItem {
  final int? productId;
  final String productName;
  final double qty;
  final double unitPrice;
  final double discount;

  const SaleLineItem({
    this.productId,
    required this.productName,
    required this.qty,
    required this.unitPrice,
    this.discount = 0,
  });
}

class PurchaseLineItem {
  final int? productId;
  final String productName;
  final int quantity;
  final double purchaseRate;
  final DateTime? expiryDate;

  const PurchaseLineItem({
    this.productId,
    required this.productName,
    required this.quantity,
    required this.purchaseRate,
    this.expiryDate,
  });

  double get lineTotal => quantity * purchaseRate;
}

class DbWholesaler {
  final int? id;
  final String name;
  final String city;
  final String phone;
  final double balance;

  const DbWholesaler({
    this.id,
    required this.name,
    required this.city,
    required this.phone,
    this.balance = 0,
  });

  Map<String, Object?> toMap() => {
    WholesalerTable.nameColumn: name,
    WholesalerTable.city: city,
    WholesalerTable.phone: phone,
    WholesalerTable.balance: balance,
  };

  factory DbWholesaler.fromMap(Map<String, Object?> map) {
    return DbWholesaler(
      id: map[WholesalerTable.id] as int?,
      name: map[WholesalerTable.nameColumn] as String,
      city: map[WholesalerTable.city] as String? ?? '',
      phone: map[WholesalerTable.phone] as String? ?? '',
      balance: (map[WholesalerTable.balance] as num?)?.toDouble() ?? 0,
    );
  }

  DbWholesaler copyWith({
    int? id,
    String? name,
    String? city,
    String? phone,
    double? balance,
  }) {
    return DbWholesaler(
      id: id ?? this.id,
      name: name ?? this.name,
      city: city ?? this.city,
      phone: phone ?? this.phone,
      balance: balance ?? this.balance,
    );
  }
}

class DbExpense {
  final int? id;
  final String category;
  final double amount;
  final String remarks;
  final DateTime expenseDate;
  final int? employeeId;
  final String? payrollType;

  const DbExpense({
    this.id,
    required this.category,
    required this.amount,
    required this.remarks,
    required this.expenseDate,
    this.employeeId,
    this.payrollType,
  });

  Map<String, Object?> toMap() => {
    ExpenseTable.category: category,
    ExpenseTable.amount: amount,
    ExpenseTable.remarks: remarks,
    ExpenseTable.expenseDate: DatabaseHelper._formatDateTime(expenseDate),
    ExpenseTable.employeeId: employeeId,
    ExpenseTable.payrollType: payrollType,
  };

  factory DbExpense.fromMap(Map<String, Object?> map) {
    final rawDate = map[ExpenseTable.expenseDate] as String? ?? '';
    return DbExpense(
      id: map[ExpenseTable.id] as int?,
      category: map[ExpenseTable.category] as String? ?? '',
      amount: (map[ExpenseTable.amount] as num?)?.toDouble() ?? 0,
      remarks: map[ExpenseTable.remarks] as String? ?? '',
      expenseDate: DateTime.tryParse(rawDate) ?? DateTime.now(),
      employeeId: map[ExpenseTable.employeeId] as int?,
      payrollType: map[ExpenseTable.payrollType] as String?,
    );
  }
}

class DbEmployee {
  final int? id;
  final String name;
  final String phone;
  final String role;
  final String salaryType;
  final double baseSalary;
  final DateTime createdAt;
  final bool isActive;

  const DbEmployee({
    this.id,
    required this.name,
    this.phone = '',
    this.role = '',
    required this.salaryType,
    required this.baseSalary,
    required this.createdAt,
    this.isActive = true,
  });

  bool get isMonthly => salaryType == EmployeeSalaryType.monthly;
  bool get isDaily => salaryType == EmployeeSalaryType.daily;

  Map<String, Object?> toMap() => {
    EmployeeTable.nameColumn: name,
    EmployeeTable.phone: phone,
    EmployeeTable.role: role,
    EmployeeTable.salaryType: salaryType,
    EmployeeTable.baseSalary: baseSalary,
    EmployeeTable.createdAt: DatabaseHelper._formatDateTime(createdAt),
    EmployeeTable.isActive: isActive ? 1 : 0,
  };

  factory DbEmployee.fromMap(Map<String, Object?> map) {
    final rawCreated = map[EmployeeTable.createdAt] as String? ?? '';
    return DbEmployee(
      id: map[EmployeeTable.id] as int?,
      name: map[EmployeeTable.nameColumn] as String? ?? '',
      phone: map[EmployeeTable.phone] as String? ?? '',
      role: map[EmployeeTable.role] as String? ?? '',
      salaryType:
          map[EmployeeTable.salaryType] as String? ?? EmployeeSalaryType.monthly,
      baseSalary: (map[EmployeeTable.baseSalary] as num?)?.toDouble() ?? 0,
      createdAt: DateTime.tryParse(rawCreated) ?? DateTime.now(),
      isActive: ((map[EmployeeTable.isActive] as num?)?.toInt() ?? 1) == 1,
    );
  }

  DbEmployee copyWith({
    int? id,
    String? name,
    String? phone,
    String? role,
    String? salaryType,
    double? baseSalary,
    DateTime? createdAt,
    bool? isActive,
  }) {
    return DbEmployee(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      salaryType: salaryType ?? this.salaryType,
      baseSalary: baseSalary ?? this.baseSalary,
      createdAt: createdAt ?? this.createdAt,
      isActive: isActive ?? this.isActive,
    );
  }
}

class DbAttendance {
  final int? attendanceId;
  final int employeeId;
  final String date;
  final String status;

  const DbAttendance({
    this.attendanceId,
    required this.employeeId,
    required this.date,
    required this.status,
  });

  factory DbAttendance.fromMap(Map<String, Object?> map) {
    return DbAttendance(
      attendanceId: map[EmployeeAttendanceTable.attendanceId] as int?,
      employeeId: map[EmployeeAttendanceTable.employeeId] as int? ?? 0,
      date: map[EmployeeAttendanceTable.date] as String? ?? '',
      status: map[EmployeeAttendanceTable.status] as String? ?? '',
    );
  }
}

/// Monthly payroll snapshot for one employee.
class EmployeeMonthPayroll {
  final DbEmployee employee;
  final int year;
  final int month;
  final int presentDays;
  final int absentDays;
  final int halfDays;
  final int unmarkedDays;
  final double baseSalary;
  final double earnedAmount;
  final double kharchiTotal;
  final double settlementTotal;
  final double netRemaining;
  final bool isSettled;
  final List<DbAttendance> attendance;
  final List<DbExpense> payrollExpenses;

  const EmployeeMonthPayroll({
    required this.employee,
    required this.year,
    required this.month,
    required this.presentDays,
    required this.absentDays,
    required this.halfDays,
    required this.unmarkedDays,
    required this.baseSalary,
    required this.earnedAmount,
    required this.kharchiTotal,
    required this.settlementTotal,
    required this.netRemaining,
    required this.isSettled,
    required this.attendance,
    required this.payrollExpenses,
  });
}

class ProductHistoryEntry {
  final int? id;
  final int productId;
  final DateTime dateTime;
  final String movementType;
  final int quantity;
  final String uom;
  final String partyLabel;
  final String referenceType;
  final String? referenceId;
  final String? notes;

  const ProductHistoryEntry({
    this.id,
    required this.productId,
    required this.dateTime,
    required this.movementType,
    required this.quantity,
    required this.uom,
    required this.partyLabel,
    required this.referenceType,
    this.referenceId,
    this.notes,
  });

  bool get isStockIn => movementType == StockMovementType.stockIn;

  String get quantityLabel {
    final sign = isStockIn ? '+' : '-';
    return '$sign$quantity $uom';
  }

  String get typeLabel => isStockIn ? 'STOCK IN' : 'STOCK OUT';
}
