import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/audit_log_model.dart';
import '../models/ledger_models.dart' hide Season;
import '../models/partner_model.dart';
import '../models/season.dart';
import '../models/user_model.dart';
import '../services/session_context.dart';
import '../utils/season_utils.dart';
import '../utils/shop_settings.dart';
import 'migration_framework.dart';

export '../models/ledger_models.dart'
    show BillSettlementInvoiceSummary, BillSettlementResult;

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
  static const int schemaVersion = 39;

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

  /// Absolute path to the on-disk SQLite file (`agrikhata.db`).
  Future<String> get databaseFilePath async {
    final supportDir = await getApplicationSupportDirectory();
    await supportDir.create(recursive: true);
    return p.join(supportDir.path, 'agrikhata.db');
  }

  /// Re-opens the database after an external file replace (cloud restore).
  Future<Database> reopenAfterRestore() async {
    await close();
    final db = await database;
    notifyListeners();
    return db;
  }

  Future<Database> _initDatabase() async {
    // Use Application Support (writable under MSIX); getDatabasesPath() can
    // resolve inside the read-only package and cause SQLITE_CANTOPEN (14).
    final path = await databaseFilePath;

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
          // seasons before sales/payments so season_id FKs can reference them.
          await db.execute(_createSeasonsTable());
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
          await db.execute(_createPartnersTable());
          await db.execute(_createPartnerDrawingsTable());
          await db.execute(_createPartnerTransactionsTable());
          await db.execute(_createArchivedSeasonsTable());
          await db.execute(_createUsersTable());
          await db.execute(_createAuditLogsTable());
          await _createIndexes(db);
          await _createLedgerSyncTriggers(db);
          await ensureSeededActiveSeasonOn(db);
        },
        onOpen: (db) async {
          // Reinforce FK enforcement on every connection (Desktop FFI).
          await db.execute('PRAGMA foreign_keys = ON');
          await _ensureWholesalerLedgerSchema(db);
          await _ensureWholesalerPaymentsSchema(db);
          await _ensureWholesalerProfileSchema(db);
          await _ensureExpensesSchema(db);
          await _ensureEmployeeSchema(db);
          await _ensureSalesAdvanceSchema(db);
          await _ensurePartnerSchema(db);
          await _ensureArchivedSeasonsSchema(db);
          await _ensureSeasonsSchema(db);
          await _ensureUserAuthSchema(db);
          await _ensurePaymentEditAuditSchema(db);
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
        MigrationStep(
          toVersion: 29,
          description: 'partners + partner_drawings equity tables',
          run: _migrateToV29,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 30,
          description: 'users + audit_logs + created_by actor stamps',
          run: _migrateToV30,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 31,
          description: 'immutable created_at footprint on transactional tables',
          run: _migrateToV31,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 32,
          description: 'partner equity ledger + out-of-pocket columns',
          run: _migrateToV32,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 33,
          description: 'archived seasons lock for settled ledgers',
          run: _migrateToV33,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 34,
          description:
              'advance loans: ADVANCE_LOAN_RECORD ledger + receipt labels',
          run: _migrateToV34,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 35,
          description: 'wholesaler address + soft-archive is_active',
          run: _migrateToV35,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 36,
          description: 'payment edit audit columns (edited_at/by, original_amount, notes)',
          run: _migrateToV36,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 37,
          description: 'manual seasons table + season_id on transactions',
          run: _migrateToV37,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 38,
          description: 'sales.description optional transaction notes',
          run: _migrateToV38,
          verifyIntegrity: false,
        ),
        MigrationStep(
          toVersion: 39,
          description: 'ledger_transactions.notes + payment notes on khaata',
          run: _migrateToV39,
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

  Future<void> _migrateToV29(Database db, MigrationLog log) async {
    log.step('ensure partners + partner_drawings schema');
    await _ensurePartnerSchema(db);
  }

  Future<void> _migrateToV30(Database db, MigrationLog log) async {
    log.step('ensure users + audit_logs + created_by columns');
    await _ensureUserAuthSchema(db);
  }

  Future<void> _migrateToV31(Database db, MigrationLog log) async {
    log.step('ensure created_at actor footprint columns');
    await _ensureUserAuthSchema(db);
  }

  Future<void> _migrateToV32(Database db, MigrationLog log) async {
    log.step('ensure partner equity ledger schema');
    await _ensurePartnerSchema(db);
  }

  Future<void> _migrateToV33(Database db, MigrationLog log) async {
    log.step('ensure archived_seasons table');
    await _ensureArchivedSeasonsSchema(db);
  }

  /// v35: wholesaler directory address + soft-archive flag.
  Future<void> _migrateToV35(Database db, MigrationLog log) async {
    await _ensureWholesalerProfileSchema(db, log: log);
  }

  /// v36: payment edit audit trail + optional notes.
  Future<void> _migrateToV36(Database db, MigrationLog log) async {
    await _ensurePaymentEditAuditSchema(db, log: log);
  }

  /// v37: manual Season System — seasons master table + season_id FKs.
  Future<void> _migrateToV37(Database db, MigrationLog log) async {
    log.step('ensure seasons table + season_id columns');
    await _ensureSeasonsSchema(db, log: log);

    log.step('backfill seasons from distinct transaction labels');
    await _backfillSeasonsFromLabels(db, log);

    log.step('seed active season if missing');
    await ensureSeededActiveSeasonOn(db);

    log.step('recreate ledger sync triggers with season_id');
    await _createLedgerSyncTriggers(db);
  }

  /// v38: optional free-text notes on sales (separate from walk-in name in remarks).
  Future<void> _migrateToV38(Database db, MigrationLog log) async {
    log.step('add sales.description');
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.description,
      columnDefSql: '${SalesTable.description} TEXT',
      log: log,
    );

    log.step('recreate sale ledger triggers to include description notes');
    await _createLedgerSyncTriggers(db);
  }

  /// v39: optional notes on ledger_transactions, copied from payment remarks.
  Future<void> _migrateToV39(Database db, MigrationLog log) async {
    log.step('add ledger_transactions.notes');
    await addColumnIfMissing(
      db,
      table: LedgerTransactionTable.name,
      column: LedgerTransactionTable.notes,
      columnDefSql: '${LedgerTransactionTable.notes} TEXT',
      log: log,
    );

    log.step('recreate ledger sync triggers to attach payment notes');
    await _createLedgerSyncTriggers(db);
  }

  /// Adds edit-audit columns on [PaymentsTable] (idempotent).
  Future<void> _ensurePaymentEditAuditSchema(
    Database db, {
    MigrationLog? log,
  }) async {
    await addColumnIfMissing(
      db,
      table: PaymentsTable.name,
      column: PaymentsTable.editedAt,
      columnDefSql: '${PaymentsTable.editedAt} TEXT',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: PaymentsTable.name,
      column: PaymentsTable.editedBy,
      columnDefSql: '${PaymentsTable.editedBy} TEXT',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: PaymentsTable.name,
      column: PaymentsTable.originalAmount,
      columnDefSql: '${PaymentsTable.originalAmount} INTEGER',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: PaymentsTable.name,
      column: PaymentsTable.notes,
      columnDefSql: '${PaymentsTable.notes} TEXT',
      log: log,
    );
  }

  Future<void> _ensureWholesalerProfileSchema(
    Database db, {
    MigrationLog? log,
  }) async {
    await addColumnIfMissing(
      db,
      table: WholesalerTable.name,
      column: WholesalerTable.address,
      columnDefSql: '${WholesalerTable.address} TEXT',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: WholesalerTable.name,
      column: WholesalerTable.isActive,
      columnDefSql: '${WholesalerTable.isActive} INTEGER NOT NULL DEFAULT 1',
      log: log,
    );
  }

  /// v34: zero-margin advance loans — recreate sale→ledger triggers with
  /// [ADVANCE_LOAN_RECORD] category + khaata receipt descriptions; backfill
  /// existing advance ledger rows and sale_items labels.
  Future<void> _migrateToV34(Database db, MigrationLog log) async {
    log.step('recreate ledger sync triggers (ADVANCE_LOAN_RECORD)');
    await _createLedgerSyncTriggers(db);

    log.step('backfill advance ledger categories');
    await db.rawUpdate('''
      UPDATE ${LedgerTransactionTable.name}
      SET ${LedgerTransactionTable.category} = 'ADVANCE_LOAN_RECORD'
      WHERE UPPER(${LedgerTransactionTable.category}) IN (
        'CASH_ADVANCE', 'DIESEL_ADVANCE', 'PETROL_ADVANCE'
      )
    ''');

    log.step('backfill advance sale_items receipt labels');
    await db.rawUpdate('''
      UPDATE ${SaleItemsTable.name}
      SET ${SaleItemsTable.productName} = 'Advance Loan (Khaata Record)'
      WHERE ${SaleItemsTable.invoiceNumber} IN (
        SELECT ${SalesTable.invoiceNumber} FROM ${SalesTable.name}
        WHERE ${SalesTable.transactionType} = '${SaleTransactionType.cashAdvance}'
      )
        AND ${SaleItemsTable.productType} = 'Advance'
    ''');
    await db.rawUpdate('''
      UPDATE ${SaleItemsTable.name}
      SET ${SaleItemsTable.productName} =
        'Fuel Slip (Khaata Record)' ||
        CASE
          WHEN COALESCE(
            (SELECT s.${SalesTable.fuelQuantity}
             FROM ${SalesTable.name} s
             WHERE s.${SalesTable.invoiceNumber}
               = ${SaleItemsTable.name}.${SaleItemsTable.invoiceNumber}),
            0
          ) > 0
          THEN ' (' || (
            SELECT CAST(s.${SalesTable.fuelQuantity} AS TEXT)
            FROM ${SalesTable.name} s
            WHERE s.${SalesTable.invoiceNumber}
              = ${SaleItemsTable.name}.${SaleItemsTable.invoiceNumber}
          ) || ' L)'
          ELSE ''
        END
      WHERE ${SaleItemsTable.invoiceNumber} IN (
        SELECT ${SalesTable.invoiceNumber} FROM ${SalesTable.name}
        WHERE ${SalesTable.transactionType} IN (
          '${SaleTransactionType.dieselAdvance}',
          '${SaleTransactionType.petrolAdvance}'
        )
      )
        AND ${SaleItemsTable.productType} = 'Advance'
    ''');
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

  /// Creates partners / partner_drawings / partner_transactions (idempotent).
  Future<void> _ensurePartnerSchema(Database db) async {
    await db.execute(_createPartnersTable());
    await db.execute(_createPartnerDrawingsTable());
    await db.execute(_createPartnerTransactionsTable());
    await addColumnIfMissing(
      db,
      table: PartnerTable.name,
      column: PartnerTable.createdAt,
      columnDefSql: "${PartnerTable.createdAt} TEXT NOT NULL DEFAULT ''",
    );
    await addColumnIfMissing(
      db,
      table: PartnerTable.name,
      column: PartnerTable.outOfPocketInjections,
      columnDefSql:
          '${PartnerTable.outOfPocketInjections} REAL NOT NULL DEFAULT 0',
    );
    await addColumnIfMissing(
      db,
      table: PartnerTable.name,
      column: PartnerTable.totalDrawings,
      columnDefSql: '${PartnerTable.totalDrawings} REAL NOT NULL DEFAULT 0',
    );
    await addColumnIfMissing(
      db,
      table: PartnerTable.name,
      column: PartnerTable.permanentCapitalWithdrawals,
      columnDefSql:
          '${PartnerTable.permanentCapitalWithdrawals} REAL NOT NULL DEFAULT 0',
    );
    await addColumnIfMissing(
      db,
      table: PartnerTable.name,
      column: PartnerTable.unsettledProfit,
      columnDefSql: '${PartnerTable.unsettledProfit} REAL NOT NULL DEFAULT 0',
    );
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_partners_active
      ON ${PartnerTable.name}(${PartnerTable.isActive})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_partner_drawings_partner
      ON ${PartnerDrawingTable.name}(${PartnerDrawingTable.partnerId})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_partner_tx_partner
      ON ${PartnerTransactionTable.name}(${PartnerTransactionTable.partnerId})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_partner_tx_type
      ON ${PartnerTransactionTable.name}(${PartnerTransactionTable.type})
    ''');
  }

  Future<void> _ensureArchivedSeasonsSchema(Database db) async {
    await db.execute(_createArchivedSeasonsTable());
  }

  /// Creates [SeasonsTable] and nullable `season_id` columns (idempotent).
  Future<void> _ensureSeasonsSchema(
    DatabaseExecutor db, {
    MigrationLog? log,
  }) async {
    await db.execute(_createSeasonsTable());
    await addColumnIfMissing(
      db,
      table: SalesTable.name,
      column: SalesTable.seasonId,
      columnDefSql: '${SalesTable.seasonId} INTEGER',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: PaymentsTable.name,
      column: PaymentsTable.seasonId,
      columnDefSql: '${PaymentsTable.seasonId} INTEGER',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: LedgerTransactionTable.name,
      column: LedgerTransactionTable.seasonId,
      columnDefSql: '${LedgerTransactionTable.seasonId} INTEGER',
      log: log,
    );
    await addColumnIfMissing(
      db,
      table: ExpenseTable.name,
      column: ExpenseTable.seasonId,
      columnDefSql: '${ExpenseTable.seasonId} INTEGER',
      log: log,
    );
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sales_season_id
      ON ${SalesTable.name}(${SalesTable.seasonId})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_payments_season_id
      ON ${PaymentsTable.name}(${PaymentsTable.seasonId})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_ledger_season_id
      ON ${LedgerTransactionTable.name}(${LedgerTransactionTable.seasonId})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_expenses_season_id
      ON ${ExpenseTable.name}(${ExpenseTable.seasonId})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_seasons_active
      ON ${SeasonsTable.name}(${SeasonsTable.isActive})
    ''');
  }

  Future<void> _backfillSeasonsFromLabels(
    Database db,
    MigrationLog log,
  ) async {
    final labelRows = await db.rawQuery('''
      SELECT DISTINCT label FROM (
        SELECT TRIM(${SalesTable.season}) AS label FROM ${SalesTable.name}
        UNION
        SELECT TRIM(${PaymentsTable.season}) AS label FROM ${PaymentsTable.name}
        UNION
        SELECT TRIM(${LedgerTransactionTable.season}) AS label
          FROM ${LedgerTransactionTable.name}
      )
      WHERE label IS NOT NULL AND label != ''
    ''');

    final calendarActive = SeasonUtils.getCurrentSeason().displayName;
    final nowIso = _formatDateOnly(DateTime.now());

    for (final row in labelRows) {
      final label = (row['label'] as String?)?.trim() ?? '';
      if (label.isEmpty) continue;

      final existing = await db.query(
        SeasonsTable.name,
        columns: [SeasonsTable.id],
        where: '${SeasonsTable.nameCol} = ?',
        whereArgs: [label],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;

      final parsed = SeasonUtils.parseSeasonDisplayName(label);
      final type = parsed?.name == 'Rabi' ? SeasonType.rabi : SeasonType.kharif;
      final start = parsed?.startDate ?? DateTime.now();
      final end = parsed?.endDate;
      final isActive = label == calendarActive ? 1 : 0;

      await db.insert(SeasonsTable.name, {
        SeasonsTable.nameCol: label,
        SeasonsTable.seasonType: type,
        SeasonsTable.startDate: _formatDateOnly(start),
        SeasonsTable.endDate:
            isActive == 1 ? null : (end == null ? null : _formatDateOnly(end)),
        SeasonsTable.isActive: isActive,
      });
      log.step('seeded season row "$label" (active=$isActive)');
    }

    // Link sales / payments / ledger by label.
    await db.execute('''
      UPDATE ${SalesTable.name}
      SET ${SalesTable.seasonId} = (
        SELECT s.${SeasonsTable.id} FROM ${SeasonsTable.name} s
        WHERE s.${SeasonsTable.nameCol} = TRIM(${SalesTable.name}.${SalesTable.season})
        LIMIT 1
      )
      WHERE ${SalesTable.seasonId} IS NULL
    ''');
    await db.execute('''
      UPDATE ${PaymentsTable.name}
      SET ${PaymentsTable.seasonId} = (
        SELECT s.${SeasonsTable.id} FROM ${SeasonsTable.name} s
        WHERE s.${SeasonsTable.nameCol} = TRIM(${PaymentsTable.name}.${PaymentsTable.season})
        LIMIT 1
      )
      WHERE ${PaymentsTable.seasonId} IS NULL
    ''');
    await db.execute('''
      UPDATE ${LedgerTransactionTable.name}
      SET ${LedgerTransactionTable.seasonId} = (
        SELECT s.${SeasonsTable.id} FROM ${SeasonsTable.name} s
        WHERE s.${SeasonsTable.nameCol}
          = TRIM(${LedgerTransactionTable.name}.${LedgerTransactionTable.season})
        LIMIT 1
      )
      WHERE ${LedgerTransactionTable.seasonId} IS NULL
    ''');

    // Expenses: map by calendar season of expense_date.
    final expenses = await db.query(
      ExpenseTable.name,
      columns: [ExpenseTable.id, ExpenseTable.expenseDate],
    );
    for (final exp in expenses) {
      final id = exp[ExpenseTable.id] as int?;
      if (id == null) continue;
      final raw = exp[ExpenseTable.expenseDate] as String? ?? '';
      final date = DateTime.tryParse(raw) ?? DateTime.now();
      final label = SeasonUtils.getSeasonString(date);
      var seasonRows = await db.query(
        SeasonsTable.name,
        columns: [SeasonsTable.id],
        where: '${SeasonsTable.nameCol} = ?',
        whereArgs: [label],
        limit: 1,
      );
      if (seasonRows.isEmpty) {
        final parsed = SeasonUtils.parseSeasonDisplayName(label);
        final type =
            parsed?.name == 'Rabi' ? SeasonType.rabi : SeasonType.kharif;
        final start = parsed?.startDate ?? date;
        final newId = await db.insert(SeasonsTable.name, {
          SeasonsTable.nameCol: label,
          SeasonsTable.seasonType: type,
          SeasonsTable.startDate: _formatDateOnly(start),
          SeasonsTable.endDate: label == calendarActive
              ? null
              : _formatDateOnly(parsed?.endDate ?? date),
          SeasonsTable.isActive: label == calendarActive ? 1 : 0,
        });
        seasonRows = [
          {SeasonsTable.id: newId},
        ];
      }
      await db.update(
        ExpenseTable.name,
        {ExpenseTable.seasonId: seasonRows.first[SeasonsTable.id]},
        where: '${ExpenseTable.id} = ?',
        whereArgs: [id],
      );
    }

    // Ensure only one active season.
    final actives = await db.query(
      SeasonsTable.name,
      where: '${SeasonsTable.isActive} = 1',
      orderBy: '${SeasonsTable.startDate} DESC',
    );
    if (actives.length > 1) {
      for (var i = 1; i < actives.length; i++) {
        await db.update(
          SeasonsTable.name,
          {
            SeasonsTable.isActive: 0,
            SeasonsTable.endDate: nowIso,
          },
          where: '${SeasonsTable.id} = ?',
          whereArgs: [actives[i][SeasonsTable.id]],
        );
      }
    }
  }

  /// Creates users / audit_logs and actor stamp columns (idempotent).
  Future<void> _ensureUserAuthSchema(Database db) async {
    await db.execute(_createUsersTable());
    await db.execute(_createAuditLogsTable());

    Future<void> addActorCols(String table) async {
      await addColumnIfMissing(
        db,
        table: table,
        column: ActorColumns.createdByUserId,
        columnDefSql: '${ActorColumns.createdByUserId} TEXT',
      );
      await addColumnIfMissing(
        db,
        table: table,
        column: ActorColumns.createdByUserName,
        columnDefSql: '${ActorColumns.createdByUserName} TEXT',
      );
      await addColumnIfMissing(
        db,
        table: table,
        column: ActorColumns.createdAt,
        columnDefSql: '${ActorColumns.createdAt} TEXT',
      );
    }

    await addActorCols(SalesTable.name);
    await addActorCols(PurchaseInvoicesTable.name);
    await addActorCols(ProductTable.name);
    await addActorCols(ExpenseTable.name);
    await addActorCols(PartnerDrawingTable.name);
    await addActorCols(StockMovementTable.name);

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_users_role
      ON ${UserTable.name}(${UserTable.role})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_users_pin
      ON ${UserTable.name}(${UserTable.pinCode})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_audit_logs_user
      ON ${AuditLogTable.name}(${AuditLogTable.userId}, ${AuditLogTable.timestamp})
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_audit_logs_ref
      ON ${AuditLogTable.name}(${AuditLogTable.actionType}, ${AuditLogTable.referenceId})
    ''');
  }

  /// Hardcodes an immutable actor footprint into an INSERT payload.
  ///
  /// Stores `id`, `"Name (Role)"`, and write-time `created_at` — never a live
  /// lookup key for historical display.
  void _applyActorStamp(Map<String, Object?> row) {
    row[ActorColumns.createdAt] = _formatDateTime(DateTime.now());
    final user = SessionContext.currentUser;
    if (user == null) return;
    row[ActorColumns.createdByUserId] = user.id;
    row[ActorColumns.createdByUserName] = user.footprintLabel;
  }

  Future<void> _writeAuditLog({
    required String actionType,
    required String referenceId,
    required String description,
    DatabaseExecutor? executor,
  }) async {
    final user = SessionContext.currentUser;
    if (user == null) return;
    final db = executor ?? await database;
    final id =
        'a_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(99999)}';
    await db.insert(AuditLogTable.name, {
      AuditLogTable.id: id,
      AuditLogTable.userId: user.id,
      AuditLogTable.userName: user.footprintLabel,
      AuditLogTable.actionType: actionType,
      AuditLogTable.referenceId: referenceId,
      AuditLogTable.description: description,
      AuditLogTable.timestamp: DateTime.now().toIso8601String(),
    });
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
            "('SALE', 'ADVANCE_LOAN_RECORD', 'CASH_ADVANCE', "
            "'DIESEL_ADVANCE', 'PETROL_ADVANCE')",
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

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_partners_active
      ON ${PartnerTable.name}(${PartnerTable.isActive})
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_partner_drawings_partner
      ON ${PartnerDrawingTable.name}(${PartnerDrawingTable.partnerId})
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
          THEN 'Advance payments deducted for (' || COALESCE((
            SELECT GROUP_CONCAT(
              item.${SaleItemsTable.productName}
                || ' x'
                || CAST(item.${SaleItemsTable.quantity} AS TEXT),
              ', '
            )
            FROM ${SaleItemsTable.name} item
            WHERE item.${SaleItemsTable.invoiceNumber}
                = NEW.${PaymentsTable.invoiceNumber}
          ), '—') || ')'
        ELSE 'Bill Payment for ' || NEW.${PaymentsTable.invoiceNumber}
      END
    ''';
    const paymentNotesSuffix = '''
      CASE
        WHEN NULLIF(TRIM(COALESCE(NEW.${PaymentsTable.notes}, '')), '')
          IS NOT NULL
        THEN ' | Note: ' || TRIM(NEW.${PaymentsTable.notes})
        ELSE ''
      END
    ''';
    const paymentDescriptionWithNotes =
        '($paymentDescriptionCase) || ($paymentNotesSuffix)';
    const saleCategoryCase = '''
      CASE
        WHEN NEW.${SalesTable.transactionType} IN (
          '${SaleTransactionType.cashAdvance}',
          '${SaleTransactionType.dieselAdvance}',
          '${SaleTransactionType.petrolAdvance}'
        ) THEN 'ADVANCE_LOAN_RECORD'
        ELSE 'SALE'
      END
    ''';
    const saleDescriptionCase = '''
      CASE
        WHEN NEW.${SalesTable.transactionType} = '${SaleTransactionType.cashAdvance}'
          THEN 'Advance Loan (Khaata Record)' ||
            CASE
              WHEN NULLIF(TRIM(COALESCE(NEW.${SalesTable.remarks}, '')), '')
                IS NOT NULL
              THEN ': ' || TRIM(NEW.${SalesTable.remarks})
              ELSE ''
            END
        WHEN NEW.${SalesTable.transactionType} = '${SaleTransactionType.dieselAdvance}'
          THEN 'Fuel Slip (Khaata Record) (' ||
            NEW.${SalesTable.fuelQuantity} || ' L)' ||
            CASE
              WHEN NULLIF(TRIM(COALESCE(NEW.${SalesTable.remarks}, '')), '')
                IS NOT NULL
              THEN ': ' || TRIM(NEW.${SalesTable.remarks})
              ELSE ''
            END
        WHEN NEW.${SalesTable.transactionType} = '${SaleTransactionType.petrolAdvance}'
          THEN 'Fuel Slip (Khaata Record) (' ||
            NEW.${SalesTable.fuelQuantity} || ' L)' ||
            CASE
              WHEN NULLIF(TRIM(COALESCE(NEW.${SalesTable.remarks}, '')), '')
                IS NOT NULL
              THEN ': ' || TRIM(NEW.${SalesTable.remarks})
              ELSE ''
            END
        ELSE
          'Product Sale Invoice ' || NEW.${SalesTable.invoiceNumber} ||
          ': Base Rs ' || CAST(NEW.${SalesTable.subtotal} AS TEXT) ||
          CASE
            WHEN COALESCE(NEW.${SalesTable.seasonalIncrementTotal}, 0) > 0
              THEN ' + Seasonal Inc Rs ' ||
                CAST(NEW.${SalesTable.seasonalIncrementTotal} AS TEXT)
            ELSE ''
          END ||
          CASE
            WHEN COALESCE(NEW.${SalesTable.itemDiscountsTotal}, 0) > 0
              THEN ' - Item Disc Rs ' ||
                CAST(NEW.${SalesTable.itemDiscountsTotal} AS TEXT)
            ELSE ''
          END ||
          CASE
            WHEN COALESCE(NEW.${SalesTable.overallDiscount}, 0) > 0
              THEN ' - Overall Disc Rs ' ||
                CAST(NEW.${SalesTable.overallDiscount} AS TEXT)
            ELSE ''
          END ||
          ' = Net Debit Rs ' || CAST(NEW.${SalesTable.totalPayable} AS TEXT) ||
          CASE
            WHEN NULLIF(TRIM(COALESCE(NEW.${SalesTable.description}, '')), '')
              IS NOT NULL
            THEN ' | Note: ' || TRIM(NEW.${SalesTable.description})
            ELSE ''
          END
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
          ${LedgerTransactionTable.season},
          ${LedgerTransactionTable.seasonId}
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
          NEW.${SalesTable.season},
          NEW.${SalesTable.seasonId}
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
          ${LedgerTransactionTable.season},
          ${LedgerTransactionTable.seasonId}
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
          NEW.${SalesTable.season},
          NEW.${SalesTable.seasonId}
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
          ${LedgerTransactionTable.season},
          ${LedgerTransactionTable.seasonId},
          ${LedgerTransactionTable.notes}
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
              THEN 'Advance payments deducted for (' || COALESCE((
                SELECT GROUP_CONCAT(
                  item.${SaleItemsTable.productName}
                    || ' x'
                    || CAST(item.${SaleItemsTable.quantity} AS TEXT),
                  ', '
                )
                FROM ${SaleItemsTable.name} item
                WHERE item.${SaleItemsTable.invoiceNumber}
                    = p.${PaymentsTable.invoiceNumber}
              ), '—') || ')'
            ELSE 'Bill Payment for ' || p.${PaymentsTable.invoiceNumber}
          END || CASE
            WHEN NULLIF(TRIM(COALESCE(p.${PaymentsTable.notes}, '')), '')
              IS NOT NULL
            THEN ' | Note: ' || TRIM(p.${PaymentsTable.notes})
            ELSE ''
          END,
          p.${PaymentsTable.amountPaid},
          p.${PaymentsTable.dateTime},
          p.${PaymentsTable.season},
          p.${PaymentsTable.seasonId},
          p.${PaymentsTable.notes}
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
          ${LedgerTransactionTable.season},
          ${LedgerTransactionTable.seasonId},
          ${LedgerTransactionTable.notes}
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
          $paymentDescriptionWithNotes,
          NEW.${PaymentsTable.amountPaid},
          NEW.${PaymentsTable.dateTime},
          NEW.${PaymentsTable.season},
          NEW.${PaymentsTable.seasonId},
          NEW.${PaymentsTable.notes}
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
          ${LedgerTransactionTable.season},
          ${LedgerTransactionTable.seasonId},
          ${LedgerTransactionTable.notes}
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
          $paymentDescriptionWithNotes,
          NEW.${PaymentsTable.amountPaid},
          NEW.${PaymentsTable.dateTime},
          NEW.${PaymentsTable.season},
          NEW.${PaymentsTable.seasonId},
          NEW.${PaymentsTable.notes}
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
      ${ProductTable.description} TEXT,
      ${ActorColumns.createdByUserId} TEXT,
      ${ActorColumns.createdByUserName} TEXT,
      ${ActorColumns.createdAt} TEXT
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
      ${LedgerTransactionTable.seasonId} INTEGER,
      ${LedgerTransactionTable.notes} TEXT,
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
      ${SalesTable.seasonId} INTEGER,
      ${SalesTable.paymentTerm} TEXT,
      ${SalesTable.transactionType} TEXT NOT NULL
        DEFAULT '${SaleTransactionType.productSale}',
      ${SalesTable.creditAmount} INTEGER NOT NULL DEFAULT 0,
      ${SalesTable.fuelQuantity} REAL,
      ${SalesTable.remarks} TEXT,
      ${SalesTable.description} TEXT,
      ${SalesTable.zamindarId} INTEGER,
      ${SalesTable.kisaanId} INTEGER,
      ${ActorColumns.createdByUserId} TEXT,
      ${ActorColumns.createdByUserName} TEXT,
      ${ActorColumns.createdAt} TEXT,
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
      ${PaymentsTable.seasonId} INTEGER,
      ${PaymentsTable.editedAt} TEXT,
      ${PaymentsTable.editedBy} TEXT,
      ${PaymentsTable.originalAmount} INTEGER,
      ${PaymentsTable.notes} TEXT,
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
      ${ActorColumns.createdByUserId} TEXT,
      ${ActorColumns.createdByUserName} TEXT,
      ${ActorColumns.createdAt} TEXT,
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
      ${WholesalerTable.address} TEXT,
      ${WholesalerTable.balance} REAL NOT NULL DEFAULT 0,
      ${WholesalerTable.isActive} INTEGER NOT NULL DEFAULT 1
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
      ${ActorColumns.createdByUserId} TEXT,
      ${ActorColumns.createdByUserName} TEXT,
      ${ActorColumns.createdAt} TEXT,
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
      ${ExpenseTable.payrollType} TEXT,
      ${ExpenseTable.seasonId} INTEGER,
      ${ActorColumns.createdByUserId} TEXT,
      ${ActorColumns.createdByUserName} TEXT,
      ${ActorColumns.createdAt} TEXT
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

  String _createPartnersTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${PartnerTable.name} (
      ${PartnerTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${PartnerTable.nameColumn} TEXT NOT NULL,
      ${PartnerTable.phone} TEXT NOT NULL DEFAULT '',
      ${PartnerTable.userAccountId} TEXT,
      ${PartnerTable.zamindarId} INTEGER,
      ${PartnerTable.initialCapital} REAL NOT NULL DEFAULT 0,
      ${PartnerTable.outOfPocketInjections} REAL NOT NULL DEFAULT 0,
      ${PartnerTable.reinvestedProfit} REAL NOT NULL DEFAULT 0,
      ${PartnerTable.totalDrawings} REAL NOT NULL DEFAULT 0,
      ${PartnerTable.permanentCapitalWithdrawals} REAL NOT NULL DEFAULT 0,
      ${PartnerTable.unsettledProfit} REAL NOT NULL DEFAULT 0,
      ${PartnerTable.activeDrawings} REAL NOT NULL DEFAULT 0,
      ${PartnerTable.isActive} INTEGER NOT NULL DEFAULT 1,
      ${PartnerTable.createdAt} TEXT NOT NULL DEFAULT '',
      FOREIGN KEY (${PartnerTable.zamindarId})
        REFERENCES ${ZamindarTable.name}(${ZamindarTable.id})
        ON DELETE SET NULL
    )
  ''';

  String _createPartnerDrawingsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${PartnerDrawingTable.name} (
      ${PartnerDrawingTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${PartnerDrawingTable.partnerId} INTEGER NOT NULL,
      ${PartnerDrawingTable.amount} REAL NOT NULL,
      ${PartnerDrawingTable.type} TEXT NOT NULL,
      ${PartnerDrawingTable.date} TEXT NOT NULL,
      ${PartnerDrawingTable.notes} TEXT,
      ${PartnerDrawingTable.isSettled} INTEGER NOT NULL DEFAULT 0,
      ${ActorColumns.createdByUserId} TEXT,
      ${ActorColumns.createdByUserName} TEXT,
      ${ActorColumns.createdAt} TEXT,
      FOREIGN KEY (${PartnerDrawingTable.partnerId})
        REFERENCES ${PartnerTable.name}(${PartnerTable.id})
        ON DELETE CASCADE
    )
  ''';

  String _createPartnerTransactionsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${PartnerTransactionTable.name} (
      ${PartnerTransactionTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${PartnerTransactionTable.partnerId} INTEGER NOT NULL,
      ${PartnerTransactionTable.type} TEXT NOT NULL,
      ${PartnerTransactionTable.amount} REAL NOT NULL,
      ${PartnerTransactionTable.date} TEXT NOT NULL,
      ${PartnerTransactionTable.paymentChannel} TEXT,
      ${PartnerTransactionTable.reference} TEXT,
      ${PartnerTransactionTable.notes} TEXT,
      ${PartnerTransactionTable.seasonLabel} TEXT,
      ${PartnerTransactionTable.equityPctBefore} REAL,
      ${PartnerTransactionTable.equityPctAfter} REAL,
      ${PartnerTransactionTable.invoiceNumber} TEXT,
      ${ActorColumns.createdByUserId} TEXT,
      ${ActorColumns.createdByUserName} TEXT,
      ${ActorColumns.createdAt} TEXT,
      FOREIGN KEY (${PartnerTransactionTable.partnerId})
        REFERENCES ${PartnerTable.name}(${PartnerTable.id})
        ON DELETE CASCADE
    )
  ''';

  String _createArchivedSeasonsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${ArchivedSeasonTable.name} (
      ${ArchivedSeasonTable.seasonLabel} TEXT PRIMARY KEY,
      ${ArchivedSeasonTable.archivedAt} TEXT NOT NULL,
      ${ArchivedSeasonTable.notes} TEXT
    )
  ''';

  String _createSeasonsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${SeasonsTable.name} (
      ${SeasonsTable.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${SeasonsTable.nameCol} TEXT NOT NULL UNIQUE,
      ${SeasonsTable.seasonType} TEXT NOT NULL,
      ${SeasonsTable.startDate} TEXT NOT NULL,
      ${SeasonsTable.endDate} TEXT,
      ${SeasonsTable.isActive} INTEGER NOT NULL DEFAULT 0
    )
  ''';

  String _createUsersTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${UserTable.name} (
      ${UserTable.id} TEXT PRIMARY KEY,
      ${UserTable.nameColumn} TEXT NOT NULL,
      ${UserTable.phone} TEXT NOT NULL DEFAULT '',
      ${UserTable.email} TEXT,
      ${UserTable.role} TEXT NOT NULL,
      ${UserTable.pinCode} TEXT NOT NULL,
      ${UserTable.partnerId} TEXT,
      ${UserTable.isActive} INTEGER NOT NULL DEFAULT 1,
      ${UserTable.createdAt} TEXT NOT NULL
    )
  ''';

  String _createAuditLogsTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${AuditLogTable.name} (
      ${AuditLogTable.id} TEXT PRIMARY KEY,
      ${AuditLogTable.userId} TEXT NOT NULL,
      ${AuditLogTable.userName} TEXT NOT NULL,
      ${AuditLogTable.actionType} TEXT NOT NULL,
      ${AuditLogTable.referenceId} TEXT NOT NULL,
      ${AuditLogTable.description} TEXT NOT NULL,
      ${AuditLogTable.timestamp} TEXT NOT NULL
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
          WHEN z.${ZamindarTable.id} IS NULL THEN COALESCE(
            NULLIF(TRIM(s.${SalesTable.remarks}), ''),
            'Walk-in Customer'
          )
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
        PaymentsTable.seasonId: await _lookupSeasonIdForLabel(db, season),
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
    final row = product.toMap();
    _applyActorStamp(row);
    final result = await db.insert(ProductTable.name, row);
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
    final actor = SessionContext.currentUser;
    await _writeAuditLog(
      actionType: AuditActionType.addProduct,
      referenceId: result.toString(),
      description:
          'Product "${product.name}" added by ${actor?.name ?? 'Unknown'} (${actor?.roleLabel ?? 'Staff'})',
    );
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
        COALESCE(s.${SalesTable.overallDiscount}, 0) AS overall_discount,
        COALESCE(
          NULLIF(TRIM(k.${KisaanTable.nameColumn}), ''),
          'Self'
        ) AS kisaan_name,
        si.${SaleItemsTable.productName} AS product_name,
        si.${SaleItemsTable.quantity} AS quantity,
        si.${SaleItemsTable.unitPrice} AS unit_price,
        COALESCE(si.${SaleItemsTable.seasonalIncrement}, 0)
          AS seasonal_increment,
        COALESCE(si.${SaleItemsTable.itemDiscount}, 0) AS item_discount,
        -- Line net before invoice-level overall discount:
        -- qty × (base + seasonal_inc − per-unit discount)
        (
          si.${SaleItemsTable.quantity} * (
            si.${SaleItemsTable.unitPrice}
            + COALESCE(si.${SaleItemsTable.seasonalIncrement}, 0)
            - COALESCE(si.${SaleItemsTable.itemDiscount}, 0)
          )
        ) AS line_subtotal,
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

    // Build rows, then allocate each invoice's overall discount across its
    // lines by line-subtotal weight so product totals match net payable.
    final pending = <_ProductLedgerDraft>[];
    for (final row in rows) {
      final productName = (row['product_name'] as String?)?.trim() ?? '';
      if (productName.isEmpty) continue;
      final kisaanRaw = (row['kisaan_name'] as String?)?.trim() ?? '';
      final uomRaw = (row['uom'] as String?)?.trim() ?? '';
      final qty = (row['quantity'] as num?)?.round() ?? 0;
      final unitPrice = (row['unit_price'] as num?)?.round() ?? 0;
      final seasonalInc = (row['seasonal_increment'] as num?)?.round() ?? 0;
      final itemDiscount = (row['item_discount'] as num?)?.round() ?? 0;
      final lineSubtotal = (row['line_subtotal'] as num?)?.round() ??
          (qty * (unitPrice + seasonalInc - itemDiscount));
      pending.add(
        _ProductLedgerDraft(
          invoiceNumber: (row['invoice_number'] as String?)?.trim() ?? '',
          dateTime: _parseDateTime(row['date_time'] as String? ?? ''),
          kisaanName: kisaanRaw.isNotEmpty ? kisaanRaw : 'Self',
          productName: productName,
          quantity: qty,
          unitPrice: unitPrice,
          seasonalIncrement: seasonalInc,
          itemDiscount: itemDiscount,
          lineSubtotal: lineSubtotal,
          invoiceOverallDiscount:
              (row['overall_discount'] as num?)?.round() ?? 0,
          uom: uomRaw.isNotEmpty ? uomRaw : 'Bags',
        ),
      );
    }

    final byInvoice = <String, List<_ProductLedgerDraft>>{};
    for (final draft in pending) {
      byInvoice.putIfAbsent(draft.invoiceNumber, () => []).add(draft);
    }

    final result = <ZamindarProductLedgerEntry>[];
    for (final drafts in byInvoice.values) {
      final invoiceOverall = drafts.first.invoiceOverallDiscount;
      final invoiceSubtotal = drafts.fold<int>(
        0,
        (sum, d) => sum + d.lineSubtotal,
      );
      var allocatedRunning = 0;
      for (var i = 0; i < drafts.length; i++) {
        final d = drafts[i];
        int allocated;
        if (invoiceOverall <= 0 || invoiceSubtotal <= 0) {
          allocated = 0;
        } else if (i == drafts.length - 1) {
          // Last line absorbs rounding remainder.
          allocated = invoiceOverall - allocatedRunning;
        } else {
          allocated =
              ((invoiceOverall * d.lineSubtotal) / invoiceSubtotal).round();
          allocatedRunning += allocated;
        }
        if (allocated < 0) allocated = 0;
        if (allocated > d.lineSubtotal) allocated = d.lineSubtotal;
        result.add(
          ZamindarProductLedgerEntry(
            invoiceNumber: d.invoiceNumber,
            dateTime: d.dateTime,
            kisaanName: d.kisaanName,
            productName: d.productName,
            quantity: d.quantity,
            unitPrice: d.unitPrice,
            seasonalIncrement: d.seasonalIncrement,
            itemDiscount: d.itemDiscount,
            allocatedOverallDiscount: allocated,
            lineSubtotal: d.lineSubtotal,
            lineTotal: d.lineSubtotal - allocated,
            uom: d.uom,
          ),
        );
      }
    }

    // Preserve original date/invoice sort (group order may shuffle).
    result.sort((a, b) {
      final byDate = b.dateTime.compareTo(a.dateTime);
      if (byDate != 0) return byDate;
      return a.invoiceNumber.compareTo(b.invoiceNumber);
    });
    return result;
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
        createdByUserName:
            row[ActorColumns.createdByUserName] as String?,
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
    final row = <String, Object?>{
      StockMovementTable.productId: productId,
      StockMovementTable.movementType: movementType,
      StockMovementTable.quantity: quantity,
      StockMovementTable.partyLabel: partyLabel,
      StockMovementTable.referenceType: referenceType,
      StockMovementTable.referenceId: referenceId,
      StockMovementTable.dateTime: _formatDateTime(dateTime),
      StockMovementTable.notes: notes,
    };
    _applyActorStamp(row);
    await txn.insert(StockMovementTable.name, row);
  }

  Future<String> _resolveSalePartyLabel(
    DatabaseExecutor txn,
    String zamindarName,
  ) async {
    final trimmed = zamindarName.trim();
    if (trimmed.isEmpty) return 'Walk-in Customer';
    return trimmed;
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
    await _ensurePaymentEditAuditSchema(db);
    final limitClause = limit != null ? ' LIMIT $limit' : '';
    return db.rawQuery(
      '''
      SELECT
        lt.*,
        k.${KisaanTable.nameColumn} AS kisaan_name,
        p.${PaymentsTable.editedAt} AS payment_edited_at,
        p.${PaymentsTable.editedBy} AS payment_edited_by,
        p.${PaymentsTable.originalAmount} AS payment_original_amount,
        p.${PaymentsTable.notes} AS payment_notes,
        s.${SalesTable.subtotal} AS ${SaleJoinColumns.subtotal},
        s.${SalesTable.seasonalIncrementTotal} AS ${SaleJoinColumns.seasonalIncrementTotal},
        s.${SalesTable.itemDiscountsTotal} AS ${SaleJoinColumns.itemDiscountsTotal},
        s.${SalesTable.overallDiscount} AS ${SaleJoinColumns.overallDiscount},
        s.${SalesTable.totalPayable} AS ${SaleJoinColumns.totalPayable},
        s.${SalesTable.remarks} AS ${SaleJoinColumns.remarks},
        s.${SalesTable.description} AS ${SaleJoinColumns.description}
      FROM ${LedgerTransactionTable.name} lt
      LEFT JOIN ${KisaanTable.name} k
        ON lt.${LedgerTransactionTable.kisaanId} = k.${KisaanTable.id}
      LEFT JOIN ${PaymentsTable.name} p
        ON p.${PaymentsTable.paymentId} = lt.${LedgerTransactionTable.paymentId}
      LEFT JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = lt.${LedgerTransactionTable.invoiceNumber}
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

  /// Batch sale pricing breakdown keyed by invoice number.
  ///
  /// Keys: `subtotal` (base), `seasonal_increment_total`,
  /// `item_discounts_total`, `overall_discount`, `total_payable`.
  Future<Map<String, Map<String, double>>> getSaleDiscountSummariesForInvoices(
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
        s.${SalesTable.subtotal} AS subtotal,
        s.${SalesTable.seasonalIncrementTotal} AS seasonal_increment_total,
        s.${SalesTable.itemDiscountsTotal} AS item_discounts_total,
        s.${SalesTable.overallDiscount} AS overall_discount,
        s.${SalesTable.totalPayable} AS total_payable
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.invoiceNumber} IN ($placeholders)
      ''',
      unique,
    );

    return {
      for (final row in rows)
        (row['invoice_number'] as String): {
          'subtotal': (row['subtotal'] as num?)?.toDouble() ?? 0.0,
          'seasonal_increment_total':
              (row['seasonal_increment_total'] as num?)?.toDouble() ?? 0.0,
          'item_discounts_total':
              (row['item_discounts_total'] as num?)?.toDouble() ?? 0.0,
          'overall_discount':
              (row['overall_discount'] as num?)?.toDouble() ?? 0.0,
          'total_payable':
              (row['total_payable'] as num?)?.toDouble() ?? 0.0,
        },
    };
  }

  /// Batch invoice notes keyed by invoice number (description, else advance remarks).
  Future<Map<String, String>> getSaleRemarksForInvoices(
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
        COALESCE(
          NULLIF(TRIM(s.${SalesTable.description}), ''),
          CASE
            WHEN s.${SalesTable.transactionType} != '${SaleTransactionType.productSale}'
              THEN NULLIF(TRIM(s.${SalesTable.remarks}), '')
            ELSE NULL
          END
        ) AS remarks
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.invoiceNumber} IN ($placeholders)
      ''',
      unique,
    );

    final result = <String, String>{};
    for (final row in rows) {
      final invoice = (row['invoice_number'] as String?)?.trim() ?? '';
      if (invoice.isEmpty) continue;
      final remarks = (row['remarks'] as String?)?.trim() ?? '';
      if (remarks.isNotEmpty) result[invoice] = remarks;
    }
    return result;
  }

  /// Aggregated product-sale pricing adjustments for KPIs / partner equity.
  ///
  /// Returns: `grossSales`, `seasonalIncrements`, `itemDiscounts`,
  /// `overallDiscounts`, `totalDiscounts`, `netPayable`.
  Future<Map<String, double>> getProductSaleAdjustmentTotals({
    int? zamindarId,
    String? season,
  }) async {
    final db = await database;
    final where = <String>[
      '(${SalesTable.transactionType} IS NULL OR '
          '${SalesTable.transactionType} = ?)',
    ];
    final args = <Object?>[SaleTransactionType.productSale];

    if (zamindarId != null) {
      where.add('${SalesTable.zamindarId} = ?');
      args.add(zamindarId);
    }
    if (season != null && season.trim().isNotEmpty) {
      where.add('${SalesTable.season} = ?');
      args.add(season.trim());
    }

    final rows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(${SalesTable.subtotal}), 0) AS gross_sales,
        COALESCE(SUM(${SalesTable.seasonalIncrementTotal}), 0)
          AS seasonal_increments,
        COALESCE(SUM(${SalesTable.itemDiscountsTotal}), 0) AS item_discounts,
        COALESCE(SUM(${SalesTable.overallDiscount}), 0) AS overall_discounts,
        COALESCE(SUM(${SalesTable.totalPayable}), 0) AS net_payable
      FROM ${SalesTable.name}
      WHERE ${where.join(' AND ')}
      ''',
      args,
    );

    final row = rows.isEmpty ? <String, Object?>{} : rows.first;
    final itemDisc = (row['item_discounts'] as num?)?.toDouble() ?? 0.0;
    final overallDisc = (row['overall_discounts'] as num?)?.toDouble() ?? 0.0;
    return {
      'grossSales': (row['gross_sales'] as num?)?.toDouble() ?? 0.0,
      'seasonalIncrements':
          (row['seasonal_increments'] as num?)?.toDouble() ?? 0.0,
      'itemDiscounts': itemDisc,
      'overallDiscounts': overallDisc,
      'totalDiscounts': itemDisc + overallDisc,
      'netPayable': (row['net_payable'] as num?)?.toDouble() ?? 0.0,
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
    final totals = await _aggregateSalesBalancesForZamindarId(db, zamindarId);
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
      columns: [ZamindarTable.creditLimit],
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
      limit: 1,
    );

    if (zamindarRows.isEmpty) return null;

    final creditLimit =
        (zamindarRows.first[ZamindarTable.creditLimit] as int?) ?? 0;

    final totals = await _aggregateSalesBalancesForZamindarId(db, zamindarId);
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

  /// Recalculates every zamindar outstanding cache from live invoice math.
  Future<void> recalculateAllZamindarBalances() async {
    final db = await database;
    await _recalculateAllZamindarBalances(db);
    notifyListeners();
  }

  /// Live outstanding for one zamindar (same formula as ledger KPIs).
  Future<double> sumOutstandingForZamindar(int zamindarId) async {
    final db = await database;
    final totals = await _aggregateSalesBalancesForZamindarId(db, zamindarId);
    return totals['outstandingBalance']!.toDouble();
  }

  Future<double> sumTotalReceivablesPublic() async {
    final db = await database;
    return _sumTotalReceivables(db);
  }

  Future<int> countOrphanLedgerRows() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS c FROM ${LedgerTransactionTable.name} lt
      WHERE lt.${LedgerTransactionTable.invoiceNumber} IS NOT NULL
        AND TRIM(lt.${LedgerTransactionTable.invoiceNumber}) != ''
        AND NOT EXISTS (
          SELECT 1 FROM ${SalesTable.name} s
          WHERE s.${SalesTable.invoiceNumber}
            = lt.${LedgerTransactionTable.invoiceNumber}
        )
    ''');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> countOrphanPaymentRows() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS c FROM ${PaymentsTable.name} p
      WHERE p.${PaymentsTable.invoiceNumber} IS NOT NULL
        AND TRIM(p.${PaymentsTable.invoiceNumber}) != ''
        AND NOT EXISTS (
          SELECT 1 FROM ${SalesTable.name} s
          WHERE s.${SalesTable.invoiceNumber}
            = p.${PaymentsTable.invoiceNumber}
        )
    ''');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> purgeOrphanFinancialRows() async {
    final db = await database;
    var purged = 0;
    purged += await db.rawDelete('''
      DELETE FROM ${LedgerTransactionTable.name}
      WHERE ${LedgerTransactionTable.invoiceNumber} IS NOT NULL
        AND TRIM(${LedgerTransactionTable.invoiceNumber}) != ''
        AND NOT EXISTS (
          SELECT 1 FROM ${SalesTable.name} s
          WHERE s.${SalesTable.invoiceNumber}
            = ${LedgerTransactionTable.name}.${LedgerTransactionTable.invoiceNumber}
        )
    ''');
    purged += await db.rawDelete('''
      DELETE FROM ${PaymentsTable.name}
      WHERE ${PaymentsTable.invoiceNumber} IS NOT NULL
        AND TRIM(${PaymentsTable.invoiceNumber}) != ''
        AND NOT EXISTS (
          SELECT 1 FROM ${SalesTable.name} s
          WHERE s.${SalesTable.invoiceNumber}
            = ${PaymentsTable.name}.${PaymentsTable.invoiceNumber}
        )
    ''');
    if (purged > 0) notifyListeners();
    return purged;
  }

  /// Returns `{drift, fixed}` counts for product stock vs movement ledger.
  Future<Map<String, int>> auditProductStock({bool reconcile = false}) async {
    final db = await database;
    final products = await db.query(
      ProductTable.name,
      columns: [ProductTable.id, ProductTable.availableStock],
    );
    var drift = 0;
    var fixed = 0;
    for (final product in products) {
      final id = product[ProductTable.id] as int;
      final stock =
          _readIntValue(product[ProductTable.availableStock]);
      final movementCountRows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${StockMovementTable.name} '
        'WHERE ${StockMovementTable.productId} = ?',
        [id],
      );
      final hasMovements =
          ((movementCountRows.first['c'] as num?)?.toInt() ?? 0) > 0;
      if (!hasMovements) continue;

      final derivedRows = await db.rawQuery('''
        SELECT COALESCE(SUM(
          CASE
            WHEN ${StockMovementTable.movementType} = ?
              THEN ${StockMovementTable.quantity}
            WHEN ${StockMovementTable.movementType} = ?
              THEN -${StockMovementTable.quantity}
            ELSE 0
          END
        ), 0) AS derived
        FROM ${StockMovementTable.name}
        WHERE ${StockMovementTable.productId} = ?
      ''', [
        StockMovementType.stockIn,
        StockMovementType.stockOut,
        id,
      ]);
      final derived =
          ((derivedRows.first['derived'] as num?)?.toInt() ?? 0)
              .clamp(0, 1 << 31);
      if (stock != derived) {
        drift++;
        if (reconcile) {
          await db.update(
            ProductTable.name,
            {ProductTable.availableStock: derived},
            where: '${ProductTable.id} = ?',
            whereArgs: [id],
          );
          fixed++;
        }
      }
    }
    if (fixed > 0) notifyListeners();
    return {'drift': drift, 'fixed': fixed};
  }

  Future<Map<String, double>> auditWholesalerPayables() async {
    final db = await database;
    final storedRows = await db.rawQuery('''
      SELECT COALESCE(SUM(${WholesalerTable.balance}), 0) AS total
      FROM ${WholesalerTable.name}
      WHERE ${WholesalerTable.balance} > 0
        AND (${WholesalerTable.isActive} IS NULL
             OR ${WholesalerTable.isActive} = 1)
    ''');
    final liveRows = await db.rawQuery('''
      SELECT COALESCE(SUM(${PurchaseInvoicesTable.outstanding}), 0) AS total
      FROM ${PurchaseInvoicesTable.name}
      WHERE ${PurchaseInvoicesTable.outstanding} > 0.005
    ''');
    return {
      'stored': (storedRows.first['total'] as num?)?.toDouble() ?? 0,
      'live': (liveRows.first['total'] as num?)?.toDouble() ?? 0,
    };
  }

  Future<Map<String, double>> sumLedgerDebitCredit() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN ${LedgerTransactionTable.type} = 'DEBIT'
          THEN ${LedgerTransactionTable.amount} ELSE 0 END), 0) AS debits,
        COALESCE(SUM(CASE WHEN ${LedgerTransactionTable.type} = 'CREDIT'
          THEN ${LedgerTransactionTable.amount} ELSE 0 END), 0) AS credits
      FROM ${LedgerTransactionTable.name}
    ''');
    return {
      'debits': (rows.first['debits'] as num?)?.toDouble() ?? 0,
      'credits': (rows.first['credits'] as num?)?.toDouble() ?? 0,
    };
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

  /// Top [limit] zamindar IDs by product/advance sale frequency.
  Future<List<int>> getTopFrequentZamindarIds({int limit = 3}) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT
        ${SalesTable.zamindarId} AS zamindar_id,
        COUNT(*) AS usage_count
      FROM ${SalesTable.name}
      WHERE ${SalesTable.zamindarId} IS NOT NULL
      GROUP BY ${SalesTable.zamindarId}
      ORDER BY usage_count DESC
      LIMIT ?
      ''',
      [limit],
    );
    return [
      for (final row in rows)
        if (row['zamindar_id'] is int) row['zamindar_id'] as int,
    ];
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
        (sum, item) => sum + item.totalItemDiscount.round(),
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

  Future<List<DbWholesaler>> getAllWholesalers({bool includeArchived = false}) async {
    final db = await database;
    await _ensureWholesalerProfileSchema(db);
    final maps = await db.query(
      WholesalerTable.name,
      where: includeArchived ? null : '${WholesalerTable.isActive} = 1',
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
    await _ensureWholesalerProfileSchema(db);
    final result = await db.update(
      WholesalerTable.name,
      wholesaler.toMap(),
      where: '${WholesalerTable.id} = ?',
      whereArgs: [wholesaler.id],
    );
    notifyListeners();
    return result;
  }

  /// Soft-archives a wholesaler so they disappear from the active directory.
  Future<void> archiveWholesaler(int wholesalerId) async {
    final db = await database;
    await _ensureWholesalerProfileSchema(db);
    final updated = await db.update(
      WholesalerTable.name,
      {WholesalerTable.isActive: 0},
      where: '${WholesalerTable.id} = ?',
      whereArgs: [wholesalerId],
    );
    if (updated == 0) {
      throw StateError('Wholesaler $wholesalerId not found');
    }
    notifyListeners();
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
    final active = await getActiveSeason();
    final row = <String, Object?>{
      ExpenseTable.category: trimmedCategory,
      ExpenseTable.amount: amount,
      ExpenseTable.remarks: remarks.trim(),
      ExpenseTable.expenseDate: _formatDateTime(DateTime.now()),
      ExpenseTable.seasonId: active?.id,
    };
    _applyActorStamp(row);
    final id = await db.insert(ExpenseTable.name, row);
    final actor = SessionContext.currentUser;
    await _writeAuditLog(
      actionType: AuditActionType.recordExpense,
      referenceId: id.toString(),
      description:
          'Expense "$trimmedCategory" recorded by ${actor?.name ?? 'Unknown'} (${actor?.roleLabel ?? 'Staff'})',
    );
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

  /// Expenses with [ExpenseTable.expenseDate] inside `[start, end]` inclusive.
  Future<List<DbExpense>> getExpensesInRange({
    required DateTime start,
    required DateTime end,
  }) async {
    final db = await database;
    await _ensureExpensesSchema(db);
    final maps = await db.query(
      ExpenseTable.name,
      where:
          '${ExpenseTable.expenseDate} >= ? AND ${ExpenseTable.expenseDate} <= ?',
      whereArgs: [_formatDateTime(start), _formatDateTime(end)],
      orderBy:
          '${ExpenseTable.expenseDate} DESC, ${ExpenseTable.id} DESC',
    );
    return maps.map(DbExpense.fromMap).toList();
  }

  Future<bool> isSeasonArchived(String seasonLabel) async {
    final label = seasonLabel.trim();
    if (label.isEmpty) return false;
    final db = await database;
    await _ensureArchivedSeasonsSchema(db);
    final rows = await db.query(
      ArchivedSeasonTable.name,
      columns: [ArchivedSeasonTable.seasonLabel],
      where: '${ArchivedSeasonTable.seasonLabel} = ?',
      whereArgs: [label],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> archiveSeason(String seasonLabel, {String? notes}) async {
    final label = seasonLabel.trim();
    if (label.isEmpty) {
      throw ArgumentError('Season label is required to archive');
    }
    final db = await database;
    await _ensureArchivedSeasonsSchema(db);
    await db.insert(
      ArchivedSeasonTable.name,
      {
        ArchivedSeasonTable.seasonLabel: label,
        ArchivedSeasonTable.archivedAt: _formatDateTime(DateTime.now()),
        ArchivedSeasonTable.notes: notes,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> assertSeasonEditable(
    String? seasonLabel, {
    int? seasonId,
    bool masterAdminAuthorized = false,
  }) async {
    final past = await isPastSeasonRecord(
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!past) return;

    final isOwner = SessionContext.currentUser?.isOwner == true;
    if (isOwner || masterAdminAuthorized) return;

    final label = (seasonLabel ?? '').trim();
    throw StateError(
      label.isEmpty
          ? '🔒 Past-season entries are read-only. '
              'Only the Owner / Master Admin can modify them.'
          : '🔒 Season "$label" is closed. '
              'Past-season entries are read-only for standard users.',
    );
  }

  Future<bool> isPastSeasonRecord({
    int? seasonId,
    String? seasonLabel,
  }) async {
    final db = await database;
    await _ensureSeasonsSchema(db);

    if (seasonId != null) {
      final rows = await db.query(
        SeasonsTable.name,
        columns: [SeasonsTable.isActive],
        where: '${SeasonsTable.id} = ?',
        whereArgs: [seasonId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return (rows.first[SeasonsTable.isActive] as num?)?.toInt() != 1;
      }
    }

    final label = (seasonLabel ?? '').trim();
    if (label.isNotEmpty) {
      final byName = await db.query(
        SeasonsTable.name,
        columns: [SeasonsTable.isActive],
        where: '${SeasonsTable.nameCol} = ?',
        whereArgs: [label],
        limit: 1,
      );
      if (byName.isNotEmpty) {
        return (byName.first[SeasonsTable.isActive] as num?)?.toInt() != 1;
      }
      if (await isSeasonArchived(label)) return true;
    }
    return false;
  }

  Future<Season?> getActiveSeason() async {
    final db = await database;
    await _ensureSeasonsSchema(db);
    final rows = await db.query(
      SeasonsTable.name,
      where: '${SeasonsTable.isActive} = 1',
      orderBy: '${SeasonsTable.startDate} DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Season.fromMap(rows.first);
  }

  Future<Season?> getSeasonById(int id) async {
    final db = await database;
    await _ensureSeasonsSchema(db);
    final rows = await db.query(
      SeasonsTable.name,
      where: '${SeasonsTable.id} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Season.fromMap(rows.first);
  }

  Future<Season?> getSeasonByName(String name) async {
    final label = name.trim();
    if (label.isEmpty) return null;
    final db = await database;
    await _ensureSeasonsSchema(db);
    final rows = await db.query(
      SeasonsTable.name,
      where: '${SeasonsTable.nameCol} = ?',
      whereArgs: [label],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Season.fromMap(rows.first);
  }

  Future<List<Season>> getAllSeasons() async {
    final db = await database;
    await _ensureSeasonsSchema(db);
    final rows = await db.query(
      SeasonsTable.name,
      orderBy: '${SeasonsTable.startDate} DESC',
    );
    return rows.map(Season.fromMap).toList();
  }

  Future<Season> ensureSeededActiveSeason() async {
    final db = await database;
    return ensureSeededActiveSeasonOn(db);
  }

  Future<Season> ensureSeededActiveSeasonOn(DatabaseExecutor db) async {
    await _ensureSeasonsSchema(db);
    final existing = await db.query(
      SeasonsTable.name,
      where: '${SeasonsTable.isActive} = 1',
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return Season.fromMap(existing.first);
    }

    final calendar = SeasonUtils.getCurrentSeason();
    final type =
        calendar.name == 'Rabi' ? SeasonType.rabi : SeasonType.kharif;
    // Prefer continuity with existing TEXT labels on first seed.
    final name = calendar.displayName;
    final byName = await db.query(
      SeasonsTable.name,
      where: '${SeasonsTable.nameCol} = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (byName.isNotEmpty) {
      await db.update(
        SeasonsTable.name,
        {
          SeasonsTable.isActive: 1,
          SeasonsTable.endDate: null,
        },
        where: '${SeasonsTable.id} = ?',
        whereArgs: [byName.first[SeasonsTable.id]],
      );
      return Season.fromMap({
        ...byName.first,
        SeasonsTable.isActive: 1,
        SeasonsTable.endDate: null,
      });
    }

    final id = await db.insert(SeasonsTable.name, {
      SeasonsTable.nameCol: name,
      SeasonsTable.seasonType: type,
      SeasonsTable.startDate: _formatDateOnly(calendar.startDate),
      SeasonsTable.endDate: null,
      SeasonsTable.isActive: 1,
    });
    return Season(
      id: id,
      name: name,
      seasonType: type,
      startDate: calendar.startDate,
      endDate: null,
      isActive: true,
    );
  }

  /// Ends the current active season and opens a new one. Preserves history.
  Future<Season> rollOverToNextSeason({
    required String seasonType,
    required int startYear,
    String? notes,
  }) async {
    if (!SeasonType.isValid(seasonType)) {
      throw ArgumentError('Invalid season type: $seasonType');
    }
    final db = await database;
    await _ensureSeasonsSchema(db);
    final window = Season.dateWindow(seasonType, startYear);
    final name = Season.buildName(seasonType, startYear);
    final today = DateTime.now();

    late final Season next;
    await db.transaction((txn) async {
      final actives = await txn.query(
        SeasonsTable.name,
        where: '${SeasonsTable.isActive} = 1',
      );
      for (final row in actives) {
        final label = row[SeasonsTable.nameCol] as String? ?? '';
        await txn.update(
          SeasonsTable.name,
          {
            SeasonsTable.isActive: 0,
            SeasonsTable.endDate: _formatDateOnly(today),
          },
          where: '${SeasonsTable.id} = ?',
          whereArgs: [row[SeasonsTable.id]],
        );
        if (label.isNotEmpty) {
          await txn.insert(
            ArchivedSeasonTable.name,
            {
              ArchivedSeasonTable.seasonLabel: label,
              ArchivedSeasonTable.archivedAt: _formatDateTime(today),
              ArchivedSeasonTable.notes:
                  notes ?? 'Closed via manual season rollover',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }

      final duplicate = await txn.query(
        SeasonsTable.name,
        where: '${SeasonsTable.nameCol} = ?',
        whereArgs: [name],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        await txn.update(
          SeasonsTable.name,
          {
            SeasonsTable.isActive: 1,
            SeasonsTable.endDate: null,
            SeasonsTable.seasonType: seasonType,
            SeasonsTable.startDate: _formatDateOnly(window.start),
          },
          where: '${SeasonsTable.id} = ?',
          whereArgs: [duplicate.first[SeasonsTable.id]],
        );
        next = Season.fromMap({
          ...duplicate.first,
          SeasonsTable.isActive: 1,
          SeasonsTable.endDate: null,
          SeasonsTable.seasonType: seasonType,
          SeasonsTable.startDate: _formatDateOnly(window.start),
        });
      } else {
        final id = await txn.insert(SeasonsTable.name, {
          SeasonsTable.nameCol: name,
          SeasonsTable.seasonType: seasonType,
          SeasonsTable.startDate: _formatDateOnly(window.start),
          SeasonsTable.endDate: null,
          SeasonsTable.isActive: 1,
        });
        next = Season(
          id: id,
          name: name,
          seasonType: seasonType,
          startDate: window.start,
          endDate: null,
          isActive: true,
        );
      }
    });

    await _writeAuditLog(
      actionType: AuditActionType.seasonRollover,
      referenceId: next.id.toString(),
      description: 'Season rollover → ${next.name}',
    );
    notifyListeners();
    return next;
  }

  Future<int?> _lookupSeasonIdForLabel(
    DatabaseExecutor db,
    String seasonLabel,
  ) async {
    final label = seasonLabel.trim();
    if (label.isEmpty) return null;
    final rows = await db.query(
      SeasonsTable.name,
      columns: [SeasonsTable.id],
      where: '${SeasonsTable.nameCol} = ?',
      whereArgs: [label],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return rows.first[SeasonsTable.id] as int?;
    }
    final active = await db.query(
      SeasonsTable.name,
      columns: [SeasonsTable.id],
      where: '${SeasonsTable.isActive} = 1',
      limit: 1,
    );
    if (active.isEmpty) return null;
    return active.first[SeasonsTable.id] as int?;
  }

  // ---------------------------------------------------------------------------
  // Users & audit footprints
  // ---------------------------------------------------------------------------

  Future<bool> hasAnyUsers() async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${UserTable.name}',
    );
    return ((rows.first['c'] as num?)?.toInt() ?? 0) > 0;
  }

  /// True when an active Owner row exists (gates first-launch onboarding).
  Future<bool> hasOwner() async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${UserTable.name} '
      'WHERE ${UserTable.role} = ? AND ${UserTable.isActive} = 1',
      [UserRole.owner],
    );
    return ((rows.first['c'] as num?)?.toInt() ?? 0) > 0;
  }

  Future<UserModel?> getOwnerUser() async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final maps = await db.query(
      UserTable.name,
      where: '${UserTable.role} = ? AND ${UserTable.isActive} = 1',
      whereArgs: [UserRole.owner],
      orderBy: '${UserTable.createdAt} ASC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return UserModel.fromMap(maps.first);
  }

  Future<List<UserModel>> getUsers() async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final maps = await db.query(
      UserTable.name,
      orderBy: '''
        CASE ${UserTable.role}
          WHEN '${UserRole.owner}' THEN 0
          WHEN '${UserRole.partner}' THEN 1
          WHEN '${UserRole.manager}' THEN 2
          ELSE 3
        END,
        ${UserTable.nameColumn} COLLATE NOCASE ASC
      ''',
    );
    return maps.map(UserModel.fromMap).toList();
  }

  Future<UserModel?> getUserById(String id) async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final maps = await db.query(
      UserTable.name,
      where: '${UserTable.id} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return UserModel.fromMap(maps.first);
  }

  Future<UserModel?> findUserByPin(String pinCode) async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final maps = await db.query(
      UserTable.name,
      where: '${UserTable.pinCode} = ? AND ${UserTable.isActive} = 1',
      whereArgs: [pinCode],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return UserModel.fromMap(maps.first);
  }

  Future<bool> isPinInUse(String pinCode, {String? excludeUserId}) async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final maps = await db.query(
      UserTable.name,
      columns: [UserTable.id],
      where: excludeUserId == null
          ? '${UserTable.pinCode} = ?'
          : '${UserTable.pinCode} = ? AND ${UserTable.id} != ?',
      whereArgs: excludeUserId == null ? [pinCode] : [pinCode, excludeUserId],
      limit: 1,
    );
    return maps.isNotEmpty;
  }

  Future<UserModel> insertUser(UserModel user) async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    if (await isPinInUse(user.pinCode)) {
      throw StateError('This PIN is already assigned to another account');
    }
    await db.insert(UserTable.name, user.toMap());
    notifyListeners();
    return user;
  }

  Future<UserModel> updateUser(UserModel user) async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    if (await isPinInUse(user.pinCode, excludeUserId: user.id)) {
      throw StateError('This PIN is already assigned to another account');
    }
    await db.update(
      UserTable.name,
      user.toMap(),
      where: '${UserTable.id} = ?',
      whereArgs: [user.id],
    );
    notifyListeners();
    return user;
  }

  Future<void> setUserActive(String userId, bool isActive) async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final existing = await getUserById(userId);
    if (existing == null) return;
    if (existing.isOwner && !isActive) {
      throw StateError('The Owner account cannot be deactivated');
    }
    await db.update(
      UserTable.name,
      {UserTable.isActive: isActive ? 1 : 0},
      where: '${UserTable.id} = ?',
      whereArgs: [userId],
    );
    notifyListeners();
  }

  Future<List<AuditLogModel>> getAuditLogsForUser(
    String userId, {
    int limit = 50,
  }) async {
    final db = await database;
    await _ensureUserAuthSchema(db);
    final maps = await db.query(
      AuditLogTable.name,
      where: '${AuditLogTable.userId} = ?',
      whereArgs: [userId],
      orderBy: '${AuditLogTable.timestamp} DESC',
      limit: limit,
    );
    return maps.map(AuditLogModel.fromMap).toList();
  }

  Future<AuditLogModel?> getLatestAuditLogForUser(String userId) async {
    final logs = await getAuditLogsForUser(userId, limit: 1);
    return logs.isEmpty ? null : logs.first;
  }

  Future<Map<String, AuditLogModel?>> getLatestAuditLogsByUserIds(
    List<String> userIds,
  ) async {
    final result = <String, AuditLogModel?>{
      for (final id in userIds) id: null,
    };
    if (userIds.isEmpty) return result;
    final db = await database;
    await _ensureUserAuthSchema(db);
    final placeholders = List.filled(userIds.length, '?').join(',');
    final maps = await db.rawQuery(
      '''
      SELECT a.*
      FROM ${AuditLogTable.name} a
      INNER JOIN (
        SELECT ${AuditLogTable.userId} AS uid, MAX(${AuditLogTable.timestamp}) AS max_ts
        FROM ${AuditLogTable.name}
        WHERE ${AuditLogTable.userId} IN ($placeholders)
        GROUP BY ${AuditLogTable.userId}
      ) latest
        ON latest.uid = a.${AuditLogTable.userId}
       AND latest.max_ts = a.${AuditLogTable.timestamp}
      ''',
      userIds,
    );
    for (final map in maps) {
      final log = AuditLogModel.fromMap(map);
      result[log.userId] = log;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Partners & equity drawings
  // ---------------------------------------------------------------------------

  Future<List<PartnerModel>> getPartners({bool activeOnly = false}) async {
    final db = await database;
    await _ensurePartnerSchema(db);
    final maps = await db.query(
      PartnerTable.name,
      where: activeOnly ? '${PartnerTable.isActive} = 1' : null,
      orderBy: '${PartnerTable.nameColumn} COLLATE NOCASE ASC',
    );
    return maps.map(PartnerModel.fromMap).toList();
  }

  Future<PartnerModel?> getPartnerById(String id) async {
    final parsed = int.tryParse(id);
    if (parsed == null) return null;
    final db = await database;
    await _ensurePartnerSchema(db);
    final maps = await db.query(
      PartnerTable.name,
      where: '${PartnerTable.id} = ?',
      whereArgs: [parsed],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return PartnerModel.fromMap(maps.first);
  }

  Future<PartnerModel?> getPartnerByZamindarId(String zamindarId) async {
    final parsed = int.tryParse(zamindarId);
    if (parsed == null) return null;
    final db = await database;
    await _ensurePartnerSchema(db);
    final maps = await db.query(
      PartnerTable.name,
      where:
          '${PartnerTable.zamindarId} = ? AND ${PartnerTable.isActive} = 1',
      whereArgs: [parsed],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return PartnerModel.fromMap(maps.first);
  }

  Future<PartnerModel> insertPartner(PartnerModel partner) async {
    final name = partner.name.trim();
    if (name.isEmpty) {
      throw ArgumentError('Partner name is required');
    }
    if (partner.initialCapital < 0) {
      throw ArgumentError('Initial capital cannot be negative');
    }

    final db = await database;
    await _ensurePartnerSchema(db);
    final id = await db.insert(PartnerTable.name, {
      PartnerTable.nameColumn: name,
      PartnerTable.phone: partner.phone.trim(),
      PartnerTable.userAccountId: partner.userAccountId,
      PartnerTable.zamindarId: partner.zamindarId == null
          ? null
          : int.tryParse(partner.zamindarId!),
      PartnerTable.initialCapital: partner.initialCapital,
      PartnerTable.outOfPocketInjections: partner.outOfPocketInjections,
      PartnerTable.reinvestedProfit: partner.reinvestedProfit,
      PartnerTable.totalDrawings: partner.totalDrawings,
      PartnerTable.permanentCapitalWithdrawals:
          partner.permanentCapitalWithdrawals,
      PartnerTable.unsettledProfit: partner.unsettledProfit,
      PartnerTable.activeDrawings: partner.activeDrawings,
      PartnerTable.isActive: partner.isActive ? 1 : 0,
      PartnerTable.createdAt: _formatDateTime(partner.createdAt),
    });
    notifyListeners();
    return partner.copyWith(id: id.toString());
  }

  Future<PartnerModel> updatePartner(PartnerModel partner) async {
    final parsed = int.tryParse(partner.id);
    if (parsed == null) {
      throw ArgumentError('Invalid partner id');
    }
    final db = await database;
    await _ensurePartnerSchema(db);
    await db.update(
      PartnerTable.name,
      {
        PartnerTable.nameColumn: partner.name.trim(),
        PartnerTable.phone: partner.phone.trim(),
        PartnerTable.userAccountId: partner.userAccountId,
        PartnerTable.zamindarId: partner.zamindarId == null
            ? null
            : int.tryParse(partner.zamindarId!),
        PartnerTable.initialCapital: partner.initialCapital,
        PartnerTable.outOfPocketInjections: partner.outOfPocketInjections,
        PartnerTable.reinvestedProfit: partner.reinvestedProfit,
        PartnerTable.totalDrawings: partner.totalDrawings,
        PartnerTable.permanentCapitalWithdrawals:
            partner.permanentCapitalWithdrawals,
        PartnerTable.unsettledProfit: partner.unsettledProfit,
        PartnerTable.activeDrawings: partner.activeDrawings,
        PartnerTable.isActive: partner.isActive ? 1 : 0,
        PartnerTable.createdAt: _formatDateTime(partner.createdAt),
      },
      where: '${PartnerTable.id} = ?',
      whereArgs: [parsed],
    );
    notifyListeners();
    return partner;
  }

  Future<PartnerTransactionModel> insertPartnerTransaction({
    required String partnerId,
    required String type,
    required double amount,
    required DateTime date,
    String? paymentChannel,
    String? reference,
    String? notes,
    String? seasonLabel,
    double? equityPctBefore,
    double? equityPctAfter,
    String? invoiceNumber,
  }) async {
    final pid = int.tryParse(partnerId);
    if (pid == null) throw ArgumentError('Invalid partner id');
    final db = await database;
    await _ensurePartnerSchema(db);
    final row = <String, Object?>{
      PartnerTransactionTable.partnerId: pid,
      PartnerTransactionTable.type: type,
      PartnerTransactionTable.amount: amount,
      PartnerTransactionTable.date: _formatDateTime(date),
      PartnerTransactionTable.paymentChannel: paymentChannel,
      PartnerTransactionTable.reference: reference,
      PartnerTransactionTable.notes: notes,
      PartnerTransactionTable.seasonLabel: seasonLabel,
      PartnerTransactionTable.equityPctBefore: equityPctBefore,
      PartnerTransactionTable.equityPctAfter: equityPctAfter,
      PartnerTransactionTable.invoiceNumber: invoiceNumber,
    };
    _applyActorStamp(row);
    final id = await db.insert(PartnerTransactionTable.name, row);
    notifyListeners();
    return PartnerTransactionModel(
      id: id.toString(),
      partnerId: partnerId,
      type: type,
      amount: amount,
      date: date,
      paymentChannel: paymentChannel,
      reference: reference,
      notes: notes,
      seasonLabel: seasonLabel,
      equityPctBefore: equityPctBefore,
      equityPctAfter: equityPctAfter,
      invoiceNumber: invoiceNumber,
      createdByUserId: SessionContext.userId ?? '',
      createdByUserName: SessionContext.footprintLabel ?? '',
      createdAt: DateTime.now(),
    );
  }

  Future<List<PartnerTransactionModel>> getPartnerTransactions({
    String? type,
    String? partnerId,
  }) async {
    final db = await database;
    await _ensurePartnerSchema(db);
    final where = <String>[];
    final args = <Object?>[];
    if (type != null) {
      where.add('${PartnerTransactionTable.type} = ?');
      args.add(type);
    }
    if (partnerId != null) {
      where.add('${PartnerTransactionTable.partnerId} = ?');
      args.add(int.tryParse(partnerId));
    }
    final maps = await db.query(
      PartnerTransactionTable.name,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy:
          '${PartnerTransactionTable.date} DESC, ${PartnerTransactionTable.id} DESC',
    );
    return maps.map(PartnerTransactionModel.fromMap).toList();
  }

  Future<PartnerDrawingModel> recordPartnerDrawing({
    required String partnerId,
    required double amount,
    required String type,
    String? notes,
    DateTime? date,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('Drawing amount must be greater than zero');
    }
    final normalized = type.toUpperCase();
    if (normalized != PartnerDrawingType.taken &&
        normalized != PartnerDrawingType.returned) {
      throw ArgumentError('Drawing type must be TAKEN or RETURNED');
    }

    final partner = await getPartnerById(partnerId);
    if (partner == null) {
      throw StateError('Partner not found');
    }

    final db = await database;
    await _ensurePartnerSchema(db);
    final when = date ?? DateTime.now();
    final drawingRow = <String, Object?>{
      PartnerDrawingTable.partnerId: int.parse(partnerId),
      PartnerDrawingTable.amount: amount,
      PartnerDrawingTable.type: normalized,
      PartnerDrawingTable.date: _formatDateTime(when),
      PartnerDrawingTable.notes: notes?.trim(),
      PartnerDrawingTable.isSettled: 0,
    };
    _applyActorStamp(drawingRow);
    final drawingId = await db.insert(PartnerDrawingTable.name, drawingRow);

    final delta =
        normalized == PartnerDrawingType.taken ? amount : -amount;
    final nextDrawings = partner.activeDrawings + delta;
    final nextTotal = normalized == PartnerDrawingType.taken
        ? partner.totalDrawings + amount
        : (partner.totalDrawings - amount).clamp(0, double.infinity);
    await db.update(
      PartnerTable.name,
      {
        PartnerTable.activeDrawings: nextDrawings < 0 ? 0 : nextDrawings,
        PartnerTable.totalDrawings: nextTotal,
      },
      where: '${PartnerTable.id} = ?',
      whereArgs: [int.parse(partnerId)],
    );
    final actor = SessionContext.currentUser;
    await _writeAuditLog(
      actionType: AuditActionType.drawingEntry,
      referenceId: drawingId.toString(),
      description:
          'Drawing $normalized for ${partner.name} by ${actor?.name ?? 'Unknown'} (${actor?.roleLabel ?? 'Staff'})',
    );
    notifyListeners();

    return PartnerDrawingModel(
      id: drawingId.toString(),
      partnerId: partnerId,
      amount: amount,
      type: normalized,
      date: when,
      notes: notes?.trim(),
      createdByUserId:
          drawingRow[ActorColumns.createdByUserId]?.toString() ?? '',
      createdByUserName:
          drawingRow[ActorColumns.createdByUserName] as String? ?? '',
      createdAt: DateTime.tryParse(
            drawingRow[ActorColumns.createdAt] as String? ?? '',
          ) ??
          when,
    );
  }

  Future<void> settlePartnerDrawing(String drawingId) async {
    final parsed = int.tryParse(drawingId);
    if (parsed == null) return;
    final db = await database;
    await _ensurePartnerSchema(db);

    final rows = await db.query(
      PartnerDrawingTable.name,
      where: '${PartnerDrawingTable.id} = ?',
      whereArgs: [parsed],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final drawing = PartnerDrawingModel.fromMap(rows.first);
    if (drawing.isSettled) return;

    await db.update(
      PartnerDrawingTable.name,
      {PartnerDrawingTable.isSettled: 1},
      where: '${PartnerDrawingTable.id} = ?',
      whereArgs: [parsed],
    );

    // Settling a TAKEN drawing clears that amount from active drawings debt.
    if (drawing.isTaken) {
      final partner = await getPartnerById(drawing.partnerId);
      if (partner != null) {
        final next = partner.activeDrawings - drawing.amount;
        await db.update(
          PartnerTable.name,
          {
            PartnerTable.activeDrawings: next < 0 ? 0 : next,
          },
          where: '${PartnerTable.id} = ?',
          whereArgs: [int.parse(drawing.partnerId)],
        );
      }
    }
    notifyListeners();
  }

  Future<List<PartnerDrawingModel>> getPartnerDrawings({
    String? partnerId,
  }) async {
    final db = await database;
    await _ensurePartnerSchema(db);
    final maps = await db.query(
      PartnerDrawingTable.name,
      where: partnerId == null
          ? null
          : '${PartnerDrawingTable.partnerId} = ?',
      whereArgs: partnerId == null ? null : [int.tryParse(partnerId)],
      orderBy:
          '${PartnerDrawingTable.date} DESC, ${PartnerDrawingTable.id} DESC',
    );
    return maps.map(PartnerDrawingModel.fromMap).toList();
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
    final row = <String, Object?>{
      ExpenseTable.category: 'Employee Salaries',
      ExpenseTable.amount: amount,
      ExpenseTable.remarks: note,
      ExpenseTable.expenseDate: _formatDateTime(date ?? DateTime.now()),
      ExpenseTable.employeeId: employeeId,
      ExpenseTable.payrollType: ExpensePayrollType.kharchi,
    };
    _applyActorStamp(row);
    final id = await db.insert(ExpenseTable.name, row);
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
      final row = <String, Object?>{
        ExpenseTable.category: 'Employee Salaries',
        ExpenseTable.amount: net > 0 ? net : 0,
        ExpenseTable.remarks:
            'Salary settlement $monthLabel — ${employee.name}'
            '${net <= 0 ? ' (no payout; advances covered earnings)' : ''}',
        ExpenseTable.expenseDate: _formatDateTime(DateTime.now()),
        ExpenseTable.employeeId: employeeId,
        ExpenseTable.payrollType: ExpensePayrollType.settlement,
      };
      _applyActorStamp(row);
      expenseId = await txn.insert(ExpenseTable.name, row);
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

  /// Updates a manual khata payment (amount / date / method / notes / receipt).
  /// Restores or deducts vendor balance by the amount delta and syncs ledger.
  Future<void> updateWholesalerPayment({
    required int paymentId,
    required double amount,
    required String method,
    required DateTime date,
    String notes = '',
    String? referenceNo,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('Payment amount must be greater than zero');
    }

    final db = await database;
    await _ensureWholesalerPaymentsSchema(db);
    await db.transaction((txn) async {
      final rows = await txn.query(
        WholesalerPaymentsTable.name,
        where: '${WholesalerPaymentsTable.id} = ?',
        whereArgs: [paymentId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Payment $paymentId not found');
      }
      final row = rows.first;
      final source =
          row[WholesalerPaymentsTable.paymentSource] as String? ?? '';
      if (source != WholesalerPaymentSource.manualKhataPayment) {
        throw StateError(
          'Only manual khata payments can be edited. '
          'Edit the linked purchase invoice instead.',
        );
      }

      final wholesalerId = row[WholesalerPaymentsTable.wholesalerId] as int;
      final oldAmount =
          (row[WholesalerPaymentsTable.amount] as num?)?.toDouble() ?? 0;
      final oldRef =
          row[WholesalerPaymentsTable.referenceNo] as String? ?? '';
      final newRef = (referenceNo ?? oldRef).trim().isEmpty
          ? oldRef
          : referenceNo!.trim();
      final delta = amount - oldAmount;

      final balanceRows = await txn.query(
        WholesalerTable.name,
        columns: [WholesalerTable.balance],
        where: '${WholesalerTable.id} = ?',
        whereArgs: [wholesalerId],
        limit: 1,
      );
      if (balanceRows.isEmpty) {
        throw StateError('Wholesaler $wholesalerId not found');
      }
      final current =
          (balanceRows.first[WholesalerTable.balance] as num?)?.toDouble() ??
              0;
      final newBalance = (current - delta).clamp(0.0, double.infinity);

      await txn.rawUpdate(
        'UPDATE ${WholesalerTable.name} '
        'SET ${WholesalerTable.balance} = ? '
        'WHERE ${WholesalerTable.id} = ?',
        [newBalance, wholesalerId],
      );

      await txn.update(
        WholesalerPaymentsTable.name,
        {
          WholesalerPaymentsTable.amount: amount.round(),
          WholesalerPaymentsTable.paymentMethod: method,
          WholesalerPaymentsTable.referenceNo: newRef.isEmpty ? null : newRef,
          WholesalerPaymentsTable.date: _formatDateTime(date),
          WholesalerPaymentsTable.notes: notes.trim().isEmpty
              ? null
              : notes.trim(),
        },
        where: '${WholesalerPaymentsTable.id} = ?',
        whereArgs: [paymentId],
      );

      // No UPDATE trigger — sync ledger credit row in place.
      await txn.delete(
        WholesalerLedgerTable.name,
        where:
            '${WholesalerLedgerTable.wholesalerId} = ? AND '
            '${WholesalerLedgerTable.referenceId} = ? AND '
            '${WholesalerLedgerTable.transactionType} = ?',
        whereArgs: [
          wholesalerId,
          oldRef,
          WholesalerLedgerTxnType.payment,
        ],
      );
      await _insertWholesalerLedgerEntry(
        txn,
        wholesalerId: wholesalerId,
        transactionType: WholesalerLedgerTxnType.payment,
        referenceId: newRef.isEmpty ? null : newRef,
        date: date,
        debit: 0,
        credit: amount,
        description: notes,
      );
    });

    notifyListeners();
  }

  /// Deletes a manual khata payment and restores the amount to outstanding.
  Future<void> deleteWholesalerPayment(int paymentId) async {
    final db = await database;
    await _ensureWholesalerPaymentsSchema(db);
    await db.transaction((txn) async {
      final rows = await txn.query(
        WholesalerPaymentsTable.name,
        where: '${WholesalerPaymentsTable.id} = ?',
        whereArgs: [paymentId],
        limit: 1,
      );
      if (rows.isEmpty) return;

      final row = rows.first;
      final source =
          row[WholesalerPaymentsTable.paymentSource] as String? ?? '';
      if (source != WholesalerPaymentSource.manualKhataPayment) {
        throw StateError(
          'Cash purchase outlay payments are reversed by deleting '
          'the linked purchase invoice.',
        );
      }

      final wholesalerId = row[WholesalerPaymentsTable.wholesalerId] as int;
      final amount =
          (row[WholesalerPaymentsTable.amount] as num?)?.toDouble() ?? 0;

      final balanceRows = await txn.query(
        WholesalerTable.name,
        columns: [WholesalerTable.balance],
        where: '${WholesalerTable.id} = ?',
        whereArgs: [wholesalerId],
        limit: 1,
      );
      if (balanceRows.isNotEmpty) {
        final current =
            (balanceRows.first[WholesalerTable.balance] as num?)?.toDouble() ??
                0;
        await txn.rawUpdate(
          'UPDATE ${WholesalerTable.name} '
          'SET ${WholesalerTable.balance} = ? '
          'WHERE ${WholesalerTable.id} = ?',
          [current + amount, wholesalerId],
        );
      }

      // after_wholesaler_payment_delete purges the ledger credit row.
      await txn.delete(
        WholesalerPaymentsTable.name,
        where: '${WholesalerPaymentsTable.id} = ?',
        whereArgs: [paymentId],
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
      final purchaseRow = <String, Object?>{
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
      };
      _applyActorStamp(purchaseRow);
      await txn.insert(PurchaseInvoicesTable.name, purchaseRow);

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

    final actor = SessionContext.currentUser;
    await _writeAuditLog(
      actionType: AuditActionType.purchaseEntry,
      referenceId: invoiceNumber,
      description:
          'Purchase $invoiceNumber created by ${actor?.name ?? 'Unknown'} (${actor?.roleLabel ?? 'Staff'})',
    );
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
        COALESCE(
          z.${ZamindarTable.nameColumn},
          NULLIF(TRIM(s.${SalesTable.remarks}), ''),
          'Walk-in Customer'
        ) AS ${SalesTable.zamindarName},
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

    final zamindarName = sale[SalesTable.zamindarName] as String? ??
        'Walk-in Customer';
    final kisaanName = sale[SalesTable.kisaanName] as String?;
    final totalPayable = (sale[SalesTable.totalPayable] as num).toDouble();
    final initialPaid = (sale[SalesTable.paidAmount] as num).toDouble();
    final paymentMethod = sale[SalesTable.paymentMethod] as String;
    final dateTimeStr = sale[SalesTable.dateTime] as String;
    final season = sale[SalesTable.season] as String;

    // Calculate total collected (all payments) and sale-origin cash only
    // (excludes post-sale settlements so edit reload won't double-count).
    final totalCollected = _sumPaymentsCollected(initialPaid, paymentsMaps);
    var saleOriginCash = 0.0;
    if (paymentsMaps.isEmpty) {
      saleOriginCash = paymentMethod.toLowerCase() == 'cash'
          ? initialPaid
          : (initialPaid > 0 ? initialPaid : 0.0);
    } else {
      for (final payment in paymentsMaps) {
        final method =
            (payment[PaymentsTable.paymentMethod] as String? ?? '').trim();
        if (method == 'Advance Wallet Deduction') continue;
        final paidAt =
            (payment[PaymentsTable.dateTime] as String? ?? '').trim();
        if (paidAt.isNotEmpty &&
            dateTimeStr.isNotEmpty &&
            paidAt.compareTo(dateTimeStr) > 0) {
          continue; // post-sale settlement
        }
        if (method.toLowerCase() == 'cash') {
          saleOriginCash +=
              (payment[PaymentsTable.amountPaid] as num?)?.toDouble() ?? 0.0;
        }
      }
    }

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
      'saleOriginCashCollected': saleOriginCash,
      'paidAmount': initialPaid,
      'paymentTerm': sale[SalesTable.paymentTerm] as String?,
      'isCredit': paymentMethod.toLowerCase() == 'credit',
      'season': season,
      'dateTime': dateTimeStr,
      'payments': paymentsMaps,
      'transactionType':
          sale[SalesTable.transactionType] as String? ??
          SaleTransactionType.productSale,
      'remarks': sale[SalesTable.remarks] as String?,
      'description': sale[SalesTable.description] as String?,
      'fuelQuantity':
          (sale[SalesTable.fuelQuantity] as num?)?.toDouble(),
      'zamindarId': sale[SalesTable.zamindarId] as int?,
      'kisaanId': sale[SalesTable.kisaanId] as int?,
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
  /// - Payables: active wholesaler balances where balance > 0 (You Will Give)
  /// - Cash in hand: Opening + all-time spot cash sales + cash recoveries
  ///   − expenses − partner cash drawings − supplier cash out
  ///   (advance loans are zero-drawer khaata records and are not deducted)
  /// - Active accounts: non-draft zamindars + active wholesalers
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
    final activeSeason = await getActiveSeason();
    final seasonId = activeSeason?.id;
    final seasonFilter = seasonId == null
        ? ''
        : ' AND ${SalesTable.seasonId} = $seasonId';
    final paymentSeasonFilter = seasonId == null
        ? ''
        : ' AND ${PaymentsTable.seasonId} = $seasonId';

    final totalReceivables = await _sumTotalReceivables(db);
    final totalPayables = await _sumTotalPayables(db);

    final cashBreakdown = await getCashInHandBreakdown();
    final cashInHand = cashBreakdown.netCashInHand;

    // Today volumes for the snapshot cards (product sales only).
    // Scoped to the active manual season when one exists.
    final todayCashSalesRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${SalesTable.paidAmount}), 0) AS total
      FROM ${SalesTable.name}
      WHERE ${SalesTable.paymentMethod} = 'Cash'
        AND ${SalesTable.dateTime} >= ?
        AND ${SalesTable.dateTime} < ?
        AND (
          ${SalesTable.transactionType} IS NULL
          OR ${SalesTable.transactionType} = ?
          OR ${SalesTable.transactionType} NOT IN (?, ?, ?)
        )
        $seasonFilter
      ''',
      [
        todayStartIso,
        todayEndIso,
        SaleTransactionType.productSale,
        SaleTransactionType.cashAdvance,
        SaleTransactionType.dieselAdvance,
        SaleTransactionType.petrolAdvance,
      ],
    );
    final todayCashSales =
        (todayCashSalesRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final todayLedgerPaymentRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${PaymentsTable.amountPaid}), 0) AS total
      FROM ${PaymentsTable.name}
      WHERE ${PaymentsTable.paymentMethod} = 'Cash'
        AND ${PaymentsTable.dateTime} >= ?
        AND ${PaymentsTable.dateTime} < ?
        $paymentSeasonFilter
      ''',
      [todayStartIso, todayEndIso],
    );
    final todayLedgerPayments =
        (todayLedgerPaymentRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final todaySupplierPaymentRows = await db.rawQuery(
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
        (todaySupplierPaymentRows.first['total'] as num?)?.toDouble() ?? 0.0;

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
        AND (
          ${SalesTable.transactionType} IS NULL
          OR ${SalesTable.transactionType} = ?
          OR ${SalesTable.transactionType} NOT IN (?, ?, ?)
        )
        $seasonFilter
      ''',
      [
        todayStartIso,
        todayEndIso,
        SaleTransactionType.productSale,
        SaleTransactionType.cashAdvance,
        SaleTransactionType.dieselAdvance,
        SaleTransactionType.petrolAdvance,
      ],
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
      WHERE ${WholesalerTable.isActive} IS NULL OR ${WholesalerTable.isActive} = 1
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

  /// Pending cash / fuel advance loans for the dashboard reminder card.
  Future<PendingAdvancesReminder> getPendingAdvancesReminder({
    int recentLimit = 5,
  }) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        s.${SalesTable.invoiceNumber} AS invoice_number,
        s.${SalesTable.transactionType} AS transaction_type,
        s.${SalesTable.dateTime} AS date_time,
        s.${SalesTable.zamindarId} AS zamindar_id,
        z.${ZamindarTable.nameColumn} AS zamindar_name,
        ($_sqlSaleRemainingExpr) AS remaining
      FROM ${SalesTable.name} s
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
      WHERE s.${SalesTable.transactionType} IN (?, ?, ?)
      ORDER BY s.${SalesTable.dateTime} DESC
    ''', [
      SaleTransactionType.cashAdvance,
      SaleTransactionType.dieselAdvance,
      SaleTransactionType.petrolAdvance,
    ]);

    var totalCash = 0.0;
    var totalFuel = 0.0;
    final zamindarIds = <int>{};
    final recent = <PendingAdvanceRow>[];
    final limit = recentLimit < 1 ? 5 : recentLimit;

    for (final row in rows) {
      final remaining = (row['remaining'] as num?)?.toDouble() ?? 0.0;
      if (remaining <= 0.005) continue;

      final txType = row['transaction_type'] as String? ?? '';
      final zamindarId = row['zamindar_id'] as int?;
      if (zamindarId != null) zamindarIds.add(zamindarId);

      if (SaleTransactionType.isFuelAdvance(txType)) {
        totalFuel += remaining;
      } else {
        totalCash += remaining;
      }

      if (recent.length < limit) {
        recent.add(
          PendingAdvanceRow(
            invoiceNumber: row['invoice_number'] as String? ?? '',
            zamindarId: zamindarId,
            zamindarName: row['zamindar_name'] as String? ?? 'Zamindar',
            transactionType: txType,
            amount: remaining,
            dateIssued: DateTime.tryParse(
                  row['date_time'] as String? ?? '',
                ) ??
                DateTime.now(),
          ),
        );
      }
    }

    return PendingAdvancesReminder(
      totalActiveCashAdvances: totalCash,
      totalActiveFuelSlips: totalFuel,
      zamindarCountWithPending: zamindarIds.length,
      recentPending: recent,
    );
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

  /// Unpaid wholesaler debt balances (You Will Give) — active vendors only.
  Future<double> _sumTotalPayables(Database db) async {
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(${WholesalerTable.balance}), 0) AS total
      FROM ${WholesalerTable.name}
      WHERE ${WholesalerTable.balance} > 0
        AND (${WholesalerTable.isActive} IS NULL
             OR ${WholesalerTable.isActive} = 1)
    ''');
    return (rows.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  /// Party-wise receivables for the dashboard "You Will Get" drill-down.
  /// Sorted highest outstanding first (same invoice-remaining formula as KPI).
  Future<List<DashboardReceivableRow>> getReceivablesBreakdown() async {
    final directory = await getOutstandingCreditDirectory();
    return directory
        .map(
          (row) => DashboardReceivableRow(
            zamindarId: row['zamindarId'] as int?,
            name: row['name'] as String? ?? '',
            phone: (row['whatsappNumber'] as String?)?.trim(),
            lastTransactionAt: row['lastActiveAt'] as DateTime?,
            outstandingBalance:
                (row['outstandingBalance'] as num?)?.toDouble() ?? 0.0,
          ),
        )
        .where((row) => row.name.isNotEmpty && row.outstandingBalance > 0.005)
        .toList();
  }

  /// Active wholesalers with positive balances for "You Will Give" drill-down.
  Future<List<DashboardPayableRow>> getPayablesBreakdown() async {
    final wholesalers = await getAllWholesalers();
    final rows = wholesalers
        .where((w) => w.balance > 0.005)
        .map(
          (w) => DashboardPayableRow(
            wholesalerId: w.id,
            name: w.name,
            contact: w.phone.trim().isEmpty ? null : w.phone.trim(),
            pendingAmount: w.balance,
          ),
        )
        .toList();
    rows.sort((a, b) => b.pendingAmount.compareTo(a.pendingAmount));
    return rows;
  }

  /// Explicit cash-drawer math used by the Cash in Hand KPI.
  ///
  /// Cash / fuel advances are khaata loan records and have zero drawer impact.
  Future<CashInHandBreakdown> getCashInHandBreakdown() async {
    final db = await database;

    final cashSalesRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${SalesTable.paidAmount}), 0) AS total
      FROM ${SalesTable.name}
      WHERE ${SalesTable.paymentMethod} = 'Cash'
        AND (
          ${SalesTable.transactionType} IS NULL
          OR ${SalesTable.transactionType} = ?
          OR ${SalesTable.transactionType} NOT IN (?, ?, ?)
        )
      ''',
      [
        SaleTransactionType.productSale,
        SaleTransactionType.cashAdvance,
        SaleTransactionType.dieselAdvance,
        SaleTransactionType.petrolAdvance,
      ],
    );
    final cashSalesReceived =
        (cashSalesRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final ledgerPaymentRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${PaymentsTable.amountPaid}), 0) AS total
      FROM ${PaymentsTable.name}
      WHERE ${PaymentsTable.paymentMethod} = 'Cash'
      ''',
    );
    final zamindarCashRecoveries =
        (ledgerPaymentRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final supplierPaymentRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${WholesalerPaymentsTable.amount}), 0) AS total
      FROM ${WholesalerPaymentsTable.name}
      WHERE ${WholesalerPaymentsTable.paymentMethod} = 'Cash'
      ''',
    );
    final wholesalerCashPayments =
        (supplierPaymentRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final expenseRows = await db.rawQuery('''
      SELECT COALESCE(SUM(${ExpenseTable.amount}), 0) AS total
      FROM ${ExpenseTable.name}
    ''');
    final expensesPaid =
        (expenseRows.first['total'] as num?)?.toDouble() ?? 0.0;

    final drawingRows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN ${PartnerDrawingTable.type} = ?
          THEN ${PartnerDrawingTable.amount} ELSE 0 END), 0) AS taken,
        COALESCE(SUM(CASE WHEN ${PartnerDrawingTable.type} = ?
          THEN ${PartnerDrawingTable.amount} ELSE 0 END), 0) AS returned
      FROM ${PartnerDrawingTable.name}
    ''', [PartnerDrawingType.taken, PartnerDrawingType.returned]);
    final partnerDrawingsTaken =
        (drawingRows.first['taken'] as num?)?.toDouble() ?? 0.0;
    final partnerDrawingsReturned =
        (drawingRows.first['returned'] as num?)?.toDouble() ?? 0.0;

    final openingBalance = await ShopSettings.getCashOpeningBalance();
    final netCashInHand = openingBalance +
        cashSalesReceived +
        zamindarCashRecoveries -
        wholesalerCashPayments -
        expensesPaid -
        partnerDrawingsTaken +
        partnerDrawingsReturned;

    return CashInHandBreakdown(
      openingBalance: openingBalance,
      cashSalesReceived: cashSalesReceived,
      zamindarCashRecoveries: zamindarCashRecoveries,
      expensesPaid: expensesPaid,
      wholesalerCashPayments: wholesalerCashPayments,
      partnerDrawingsTaken: partnerDrawingsTaken,
      partnerDrawingsReturned: partnerDrawingsReturned,
      netCashInHand: netCashInHand,
    );
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

  /// Restores product stock for an invoice using [stock_movements] product_id
  /// (preferred). Falls back to product-name lookup for legacy rows.
  Future<void> _restoreStockForInvoice(
    DatabaseExecutor txn,
    String invoiceNumber,
  ) async {
    final movements = await txn.query(
      StockMovementTable.name,
      where:
          '${StockMovementTable.referenceType} = ? AND '
          '${StockMovementTable.referenceId} = ? AND '
          '${StockMovementTable.movementType} = ?',
      whereArgs: [
        StockMovementRef.sale,
        invoiceNumber,
        StockMovementType.stockOut,
      ],
    );

    if (movements.isNotEmpty) {
      for (final movement in movements) {
        final productId = movement[StockMovementTable.productId] as int?;
        final qty =
            (movement[StockMovementTable.quantity] as num?)?.toInt() ?? 0;
        if (productId == null || productId <= 0 || qty <= 0) continue;
        final rows = await txn.query(
          ProductTable.name,
          columns: [ProductTable.availableStock],
          where: '${ProductTable.id} = ?',
          whereArgs: [productId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final currentStock =
            _readIntValue(rows.first[ProductTable.availableStock]);
        await txn.update(
          ProductTable.name,
          {
            ProductTable.availableStock: (currentStock + qty).clamp(0, 1 << 31),
          },
          where: '${ProductTable.id} = ?',
          whereArgs: [productId],
        );
      }
      return;
    }

    // Legacy fallback: restore by product name when no movement rows exist.
    final oldItems = await txn.query(
      SaleItemsTable.name,
      where: '${SaleItemsTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
    );
    for (final oldItem in oldItems) {
      final productName = oldItem[SaleItemsTable.productName] as String;
      final oldQuantity =
          (oldItem[SaleItemsTable.quantity] as num?)?.toInt() ?? 0;
      if (oldQuantity <= 0) continue;
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
  }

  /// Removes sale-originated payment vouchers for an invoice, keeping later
  /// settlement rows (payments posted strictly after the sale timestamp).
  ///
  /// Ledger rebuild is owned by `after_sale_update` / payment triggers —
  /// this method only touches the `payments` table.
  Future<void> _clearSaleOriginatedFinancials(
    DatabaseExecutor txn,
    String invoiceNumber,
  ) async {
    final saleRows = await txn.query(
      SalesTable.name,
      columns: [SalesTable.dateTime],
      where: '${SalesTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
      limit: 1,
    );
    if (saleRows.isEmpty) return;

    final saleDateTime =
        (saleRows.first[SalesTable.dateTime] as String? ?? '').trim();

    // Keep post-sale recoveries (any method). Delete sale-time Cash / Wallet
    // rows and anything dated at-or-before the invoice timestamp.
    await txn.delete(
      PaymentsTable.name,
      where:
          '${PaymentsTable.invoiceNumber} = ? AND '
          '('
          '  ${PaymentsTable.paymentMethod} = ? OR '
          '  ${PaymentsTable.dateTime} IS NULL OR '
          '  ${PaymentsTable.dateTime} <= ?'
          ')',
      whereArgs: [
        invoiceNumber,
        'Advance Wallet Deduction',
        saleDateTime,
      ],
    );
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

      await _restoreStockForInvoice(txn, invoiceNumber);
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
    String? description,
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
      // Calculate totals — unitPrice is base; seasonal & discount are per-unit.
      final subtotal = items.fold<double>(
        0.0,
        (sum, item) => sum + (item.qty * item.unitPrice),
      );
      final itemDiscountsTotal = items.fold<double>(
        0.0,
        (sum, item) => sum + item.totalItemDiscount,
      );
      final seasonalIncrementTotal = items.fold<double>(
        0.0,
        (sum, item) => sum + item.totalItemSeasonalInc,
      );
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

      // Walk-in / cash customers have no zamindar row. Ledger triggers skip
      // when zamindar_id is null; store the typed name in remarks for display.
      // Free-text transaction notes always go in [SalesTable.description].
      final isWalkInSale = resolvedZamindarId == null;
      if (isWalkInSale && isCreditSale) {
        throw StateError(
          'Cannot insert credit sale: zamindar "$zamindarName" was not '
          'resolved to an id. Credit requires a registered Zamindar.',
        );
      }
      if (isWalkInSale && zamindarName.trim().isEmpty) {
        throw StateError(
          'Cannot insert walk-in sale: customer name is empty.',
        );
      }

      final trimmedDescription = description?.trim();
      final storedDescription =
          (trimmedDescription != null && trimmedDescription.isNotEmpty)
          ? trimmedDescription
          : null;

      // Step 1: Insert sale (after_sale_insert trigger writes ledger DEBIT).
      final resolvedSeasonId = await _lookupSeasonIdForLabel(txn, season);
      final saleRow = <String, Object?>{
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
        SalesTable.seasonId: resolvedSeasonId,
        SalesTable.paymentTerm: isCreditSale ? paymentTerm : null,
        SalesTable.transactionType: SaleTransactionType.productSale,
        SalesTable.creditAmount: creditAmount.round(),
        SalesTable.fuelQuantity: null,
        SalesTable.remarks: isWalkInSale ? zamindarName.trim() : null,
        SalesTable.description: storedDescription,
        SalesTable.zamindarId: resolvedZamindarId,
        SalesTable.kisaanId: resolvedKisaanId,
      };
      _applyActorStamp(saleRow);
      await txn.insert(SalesTable.name, saleRow);

      // Insert line items into sale_items table
      for (final item in items) {
        await txn.insert(SaleItemsTable.name, {
          SaleItemsTable.invoiceNumber: invoiceNumber,
          SaleItemsTable.productName: item.productName,
          SaleItemsTable.productType: productType,
          SaleItemsTable.quantity: item.qty.round(),
          SaleItemsTable.unitPrice: item.unitPrice.round(),
          SaleItemsTable.seasonalIncrement: item.seasonalIncrement.round(),
          // Stored per-unit (same convention as seasonalIncrement).
          SaleItemsTable.itemDiscount: item.discount.round(),
          SaleItemsTable.subtotal: item.lineSubtotal.round(),
        });
      }

      // Decrement product stock + record STOCK OUT movements
      final partyLabel = await _resolveSalePartyLabel(txn, zamindarName);
      for (final item in items) {
        final pid = item.productId;
        if (pid == null || pid <= 0) continue;
        final rows = await txn.query(
          ProductTable.name,
          columns: [ProductTable.availableStock],
          where: '${ProductTable.id} = ?',
          whereArgs: [pid],
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
          whereArgs: [pid],
        );
        await _insertStockMovement(
          txn,
          productId: pid,
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
          PaymentsTable.seasonId: await _lookupSeasonIdForLabel(txn, season),
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
          PaymentsTable.seasonId: await _lookupSeasonIdForLabel(txn, season),
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
          PaymentsTable.seasonId: await _lookupSeasonIdForLabel(txn, season),
        });
      }
      // Ledger CREDIT rows for payments are created by after_payment_insert.

      if (resolvedZamindarId != null) {
        await _recalculateZamindarBalanceOn(txn, resolvedZamindarId);
      }
    });

    final actor = SessionContext.currentUser;
    await _writeAuditLog(
      actionType: AuditActionType.newSale,
      referenceId: invoiceNumber,
      description:
          'Sale #$invoiceNumber created by ${actor?.name ?? 'Unknown'} (${actor?.roleLabel ?? 'Staff'})',
    );

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
  /// outstanding via [recalculateZamindarBalance]. Advances are zero-margin
  /// loan records: no stock movement and no cash-drawer impact.
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

    final liters = SaleTransactionType.isFuelAdvance(transactionType)
        ? fuelQuantityLiters
        : null;
    final trimmedRemarks = remarks?.trim();
    final itemLabel = SaleTransactionType.khaataReceiptLabel(
      transactionType,
      liters: liters,
    );

    final db = await database;
    await db.transaction((txn) async {
      final resolvedSeasonId = await _lookupSeasonIdForLabel(txn, season);
      final advanceRow = <String, Object?>{
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
        SalesTable.seasonId: resolvedSeasonId,
        SalesTable.paymentTerm: 'After Harvest',
        SalesTable.transactionType: transactionType,
        SalesTable.creditAmount: amount.round(),
        SalesTable.fuelQuantity: liters,
        SalesTable.remarks:
            (trimmedRemarks != null && trimmedRemarks.isNotEmpty)
            ? trimmedRemarks
            : null,
        SalesTable.description:
            (trimmedRemarks != null && trimmedRemarks.isNotEmpty)
            ? trimmedRemarks
            : null,
        SalesTable.zamindarId: zamindarId,
        SalesTable.kisaanId: kisaanId,
      };
      _applyActorStamp(advanceRow);
      await txn.insert(SalesTable.name, advanceRow);
      // after_sale_insert → ADVANCE_LOAN_RECORD debit on khaata.

      // Non-stock line: qty 1, COGS conceptually = sale price (zero margin).
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
      'affectsCashDrawer': false,
      'ledgerCategory': 'ADVANCE_LOAN_RECORD',
      'zeroMargin': true,
    };
  }

  /// Updates an existing kisaan advance invoice (cash / diesel / petrol).
  ///
  /// Refreshes sales + advance line item; `after_sale_update` rebuilds the
  /// ledger debit (and any linked payment credits).
  Future<void> updateKisaanAdvance({
    required String invoiceNumber,
    required DateTime dateTime,
    required String transactionType,
    required double amount,
    double? fuelQuantityLiters,
    String? remarks,
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

    final liters = SaleTransactionType.isFuelAdvance(transactionType)
        ? fuelQuantityLiters
        : null;
    final trimmedRemarks = remarks?.trim();
    final itemLabel = SaleTransactionType.khaataReceiptLabel(
      transactionType,
      liters: liters,
    );

    final db = await database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        SalesTable.name,
        columns: [
          SalesTable.zamindarId,
          SalesTable.season,
          SalesTable.transactionType,
        ],
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (existing.isEmpty) {
        throw StateError('Advance invoice $invoiceNumber was not found.');
      }

      final season =
          (existing.first[SalesTable.season] as String? ?? '').trim();
      if (season.isNotEmpty) {
        final archived = await txn.query(
          ArchivedSeasonTable.name,
          columns: [ArchivedSeasonTable.seasonLabel],
          where: '${ArchivedSeasonTable.seasonLabel} = ?',
          whereArgs: [season],
          limit: 1,
        );
        if (archived.isNotEmpty) {
          throw StateError(
            'Season "$season" is locked & archived. '
            'Past invoices for this closed season cannot be edited.',
          );
        }
      }

      final existingType =
          existing.first[SalesTable.transactionType] as String?;
      if (!SaleTransactionType.isAdvance(existingType)) {
        throw StateError(
          'Invoice $invoiceNumber is not a kisaan advance.',
        );
      }

      final zamindarId = existing.first[SalesTable.zamindarId] as int?;

      await txn.update(
        SalesTable.name,
        {
          SalesTable.dateTime: _formatDateTime(dateTime),
          SalesTable.subtotal: amount.round(),
          SalesTable.itemDiscountsTotal: 0,
          SalesTable.seasonalIncrementTotal: 0,
          SalesTable.overallDiscount: 0,
          SalesTable.totalPayable: amount.round(),
          SalesTable.paidAmount: 0,
          SalesTable.paymentMethod: 'Credit',
          SalesTable.paymentTerm: 'After Harvest',
          SalesTable.transactionType: transactionType,
          SalesTable.creditAmount: amount.round(),
          SalesTable.fuelQuantity: liters,
          SalesTable.remarks:
              (trimmedRemarks != null && trimmedRemarks.isNotEmpty)
              ? trimmedRemarks
              : null,
          SalesTable.description:
              (trimmedRemarks != null && trimmedRemarks.isNotEmpty)
              ? trimmedRemarks
              : null,
        },
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      // after_sale_update refreshes the advance DEBIT ledger row.

      await txn.delete(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
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

      if (zamindarId != null) {
        await _recalculateZamindarBalanceOn(txn, zamindarId);
      }
    });

    notifyListeners();
  }

  /// Gets all sales with their associated items and payments
  Future<List<Map<String, dynamic>>> getAllSalesWithDetails({
    String? season,
    int? seasonId,
  }) async {
    final db = await database;

    String seasonClause = '';
    List<Object?> args = [];
    if (seasonId != null) {
      seasonClause = 'WHERE s.${SalesTable.seasonId} = ?';
      args = [seasonId];
    } else if (season != null) {
      seasonClause = 'WHERE s.${SalesTable.season} = ?';
      args = [season];
    }
    final salesMaps = await db.rawQuery(
      '''
      SELECT
        s.*,
        COALESCE(
          z.${ZamindarTable.nameColumn},
          NULLIF(TRIM(s.${SalesTable.remarks}), ''),
          'Walk-in Customer'
        ) AS ${SalesTable.zamindarName},
        k.${KisaanTable.nameColumn} AS ${SalesTable.kisaanName}
      FROM ${SalesTable.name} s
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.id} = s.${SalesTable.zamindarId}
      LEFT JOIN ${KisaanTable.name} k
        ON k.${KisaanTable.id} = s.${SalesTable.kisaanId}
      $seasonClause
      ORDER BY s.${SalesTable.dateTime} DESC
      ''',
      args,
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
  /// - `totalPurchases` / cash vs credit purchase split
  /// - `totalRevenue`, `cashSales`, `creditSales` (product sales only)
  /// - `netProfit` — Σ qty × (sold unit − cost) − season overheads
  /// - `totalMarketDebt`, `highRiskDues`, `todaysRecovery`
  /// - `collectionEfficiency` — today's recovery / total due × 100
  /// - `season` — season display name used for the aggregation
  Future<Map<String, dynamic>> getSeasonalMetrics({String? season}) async {
    final db = await database;
    final seasonName = season ?? SeasonUtils.getCurrentSeason().displayName;
    final seasonObj = SeasonUtils.parseSeasonDisplayName(seasonName) ??
        SeasonUtils.getCurrentSeason();

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
        AND (
          ${SalesTable.transactionType} IS NULL
          OR ${SalesTable.transactionType} = ?
          OR ${SalesTable.transactionType} NOT IN (?, ?, ?)
        )
      ''',
      [
        seasonName,
        SaleTransactionType.productSale,
        SaleTransactionType.cashAdvance,
        SaleTransactionType.dieselAdvance,
        SaleTransactionType.petrolAdvance,
      ],
    );

    final totalRevenue =
        (revenueRows.first['total_revenue'] as num?)?.toDouble() ?? 0.0;
    final cashSales =
        (revenueRows.first['cash_sales'] as num?)?.toDouble() ?? 0.0;
    final creditSales =
        (revenueRows.first['credit_sales'] as num?)?.toDouble() ?? 0.0;

    // Gross margin = net invoice (after seasonal + discounts) − catalog COGS.
    // Advance loans are zero-margin and excluded.
    final profitRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(
        s.${SalesTable.totalPayable} - COALESCE((
          SELECT SUM(
            si.${SaleItemsTable.quantity} *
              COALESCE(p.${ProductTable.costPrice}, 0)
          )
          FROM ${SaleItemsTable.name} si
          LEFT JOIN ${ProductTable.name} p
            ON p.${ProductTable.nameColumn} = si.${SaleItemsTable.productName}
          WHERE si.${SaleItemsTable.invoiceNumber}
              = s.${SalesTable.invoiceNumber}
        ), 0)
      ), 0) AS gross_margin
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.season} = ?
        AND (
          s.${SalesTable.transactionType} IS NULL
          OR s.${SalesTable.transactionType} = ?
          OR s.${SalesTable.transactionType} NOT IN (?, ?, ?)
        )
      ''',
      [
        seasonName,
        SaleTransactionType.productSale,
        SaleTransactionType.cashAdvance,
        SaleTransactionType.dieselAdvance,
        SaleTransactionType.petrolAdvance,
      ],
    );
    final grossMargin =
        (profitRows.first['gross_margin'] as num?)?.toDouble() ?? 0.0;

    final adjustmentRows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(${SalesTable.subtotal}), 0) AS gross_sales,
        COALESCE(SUM(${SalesTable.seasonalIncrementTotal}), 0)
          AS seasonal_increments,
        COALESCE(SUM(${SalesTable.itemDiscountsTotal}), 0) AS item_discounts,
        COALESCE(SUM(${SalesTable.overallDiscount}), 0) AS overall_discounts
      FROM ${SalesTable.name}
      WHERE ${SalesTable.season} = ?
        AND (
          ${SalesTable.transactionType} IS NULL
          OR ${SalesTable.transactionType} = ?
          OR ${SalesTable.transactionType} NOT IN (?, ?, ?)
        )
      ''',
      [
        seasonName,
        SaleTransactionType.productSale,
        SaleTransactionType.cashAdvance,
        SaleTransactionType.dieselAdvance,
        SaleTransactionType.petrolAdvance,
      ],
    );
    final seasonalIncrements =
        (adjustmentRows.first['seasonal_increments'] as num?)?.toDouble() ??
            0.0;
    final itemDiscounts =
        (adjustmentRows.first['item_discounts'] as num?)?.toDouble() ?? 0.0;
    final overallDiscounts =
        (adjustmentRows.first['overall_discounts'] as num?)?.toDouble() ?? 0.0;
    final grossSalesBase =
        (adjustmentRows.first['gross_sales'] as num?)?.toDouble() ?? 0.0;

    final seasonStartIso = _formatDateTime(seasonObj.startDate);
    final seasonEndIso = _formatDateTime(seasonObj.endDate);
    final overheadRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(${ExpenseTable.amount}), 0) AS total
      FROM ${ExpenseTable.name}
      WHERE ${ExpenseTable.expenseDate} >= ?
        AND ${ExpenseTable.expenseDate} <= ?
      ''',
      [seasonStartIso, seasonEndIso],
    );
    final overheads =
        (overheadRows.first['total'] as num?)?.toDouble() ?? 0.0;
    final netProfit = grossMargin - overheads;

    final purchaseKpis = await fetchPurchaseLedgerKpis(
      seasonStart: seasonObj.startDate,
      seasonEnd: seasonObj.endDate,
    );
    final totalPurchases = purchaseKpis['totalPurchases'] ?? 0.0;

    final purchaseSplitRows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE
          WHEN LOWER(${PurchaseInvoicesTable.paymentType}) LIKE '%cash%'
          THEN ${PurchaseInvoicesTable.grandTotal} ELSE 0 END), 0) AS cash_purchases,
        COALESCE(SUM(CASE
          WHEN LOWER(${PurchaseInvoicesTable.paymentType}) NOT LIKE '%cash%'
          THEN ${PurchaseInvoicesTable.grandTotal} ELSE 0 END), 0) AS credit_purchases
      FROM ${PurchaseInvoicesTable.name}
      WHERE ${PurchaseInvoicesTable.dateTime} >= ?
        AND ${PurchaseInvoicesTable.dateTime} <= ?
      ''',
      [seasonStartIso, seasonEndIso],
    );
    final cashPurchases =
        (purchaseSplitRows.first['cash_purchases'] as num?)?.toDouble() ?? 0.0;
    final creditPurchases =
        (purchaseSplitRows.first['credit_purchases'] as num?)?.toDouble() ??
            0.0;

    // Outstanding figures use the same sales/payments formula as Dashboard.
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));
    final todayStartIso = _formatDateTime(todayStart);
    final todayEndIso = _formatDateTime(todayEnd);

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

    for (final row in outstandingRows) {
      final remaining = (row['remaining'] as num?)?.toDouble() ?? 0.0;
      if (remaining <= 0.005) continue;

      totalMarketDebt += remaining;

      final saleDate = _parseDateTime(row['date_time'] as String? ?? '');
      if (now.difference(saleDate).inDays > 180) {
        highRiskDues += remaining;
      }
    }

    // Today's recovery: khaata collections posted after the sale (not sale-time cash).
    final recoveryRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(p.${PaymentsTable.amountPaid}), 0) AS total
      FROM ${PaymentsTable.name} p
      INNER JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = p.${PaymentsTable.invoiceNumber}
      WHERE p.${PaymentsTable.dateTime} >= ?
        AND p.${PaymentsTable.dateTime} < ?
        AND p.${PaymentsTable.paymentMethod} != 'Advance Wallet Deduction'
        AND p.${PaymentsTable.dateTime} > s.${SalesTable.dateTime}
      ''',
      [todayStartIso, todayEndIso],
    );
    final todaysRecovery =
        (recoveryRows.first['total'] as num?)?.toDouble() ?? 0.0;

    const dailyTarget = 100000.0;
    // Collection efficiency = today's recovery / total due recoverable × 100.
    final collectionEfficiency = totalMarketDebt > 0
        ? (todaysRecovery / totalMarketDebt) * 100.0
        : 0.0;

    return {
      'season': seasonName,
      'totalPurchases': totalPurchases,
      'cashPurchases': cashPurchases,
      'creditPurchases': creditPurchases,
      'totalRevenue': totalRevenue,
      'cashSales': cashSales,
      'creditSales': creditSales,
      'grossSalesBase': grossSalesBase,
      'seasonalIncrements': seasonalIncrements,
      'itemDiscounts': itemDiscounts,
      'overallDiscounts': overallDiscounts,
      'totalDiscounts': itemDiscounts + overallDiscounts,
      'netProfit': netProfit,
      'grossMargin': grossMargin,
      'cogs': totalRevenue - grossMargin,
      'overheads': overheads,
      'totalMarketDebt': totalMarketDebt,
      'highRiskDues': highRiskDues,
      'todaysRecovery': todaysRecovery,
      'dailyTarget': dailyTarget,
      'collectionEfficiency': collectionEfficiency,
    };
  }

  /// Full P&L audit payload for Reports KPI drill-downs (current season by default).
  Future<ProfitAndLossBreakdown> getProfitAndLossBreakdown({
    String? season,
  }) async {
    final metrics = await getSeasonalMetrics(season: season);
    final seasonName = metrics['season'] as String? ?? '';
    final topProducts = await getTopProfitableProducts(
      season: seasonName,
      limit: 5,
    );

    return ProfitAndLossBreakdown(
      season: seasonName,
      grossSalesRevenue:
          (metrics['grossSalesBase'] as num?)?.toDouble() ?? 0.0,
      seasonalIncrements:
          (metrics['seasonalIncrements'] as num?)?.toDouble() ?? 0.0,
      totalDiscounts: (metrics['totalDiscounts'] as num?)?.toDouble() ?? 0.0,
      cogs: (metrics['cogs'] as num?)?.toDouble() ?? 0.0,
      shopExpenses: (metrics['overheads'] as num?)?.toDouble() ?? 0.0,
      netProfit: (metrics['netProfit'] as num?)?.toDouble() ?? 0.0,
      totalRevenue: (metrics['totalRevenue'] as num?)?.toDouble() ?? 0.0,
      cashSales: (metrics['cashSales'] as num?)?.toDouble() ?? 0.0,
      creditSales: (metrics['creditSales'] as num?)?.toDouble() ?? 0.0,
      topProducts: topProducts,
    );
  }

  /// Top products by contribution margin for the season P&L audit.
  Future<List<ProductProfitRow>> getTopProfitableProducts({
    required String season,
    int limit = 5,
  }) async {
    final db = await database;
    final capped = limit < 1 ? 5 : limit;
    final rows = await db.rawQuery(
      '''
      SELECT
        si.${SaleItemsTable.productName} AS product_name,
        COALESCE(SUM(
          si.${SaleItemsTable.quantity} * (
            COALESCE(si.${SaleItemsTable.unitPrice}, 0)
            + COALESCE(si.${SaleItemsTable.seasonalIncrement}, 0)
            - COALESCE(si.${SaleItemsTable.itemDiscount}, 0)
          )
        ), 0) AS revenue,
        COALESCE(SUM(
          si.${SaleItemsTable.quantity} *
            COALESCE(p.${ProductTable.costPrice}, 0)
        ), 0) AS cogs,
        COALESCE(SUM(
          si.${SaleItemsTable.quantity} * (
            COALESCE(si.${SaleItemsTable.unitPrice}, 0)
            + COALESCE(si.${SaleItemsTable.seasonalIncrement}, 0)
            - COALESCE(si.${SaleItemsTable.itemDiscount}, 0)
            - COALESCE(p.${ProductTable.costPrice}, 0)
          )
        ), 0) AS margin
      FROM ${SaleItemsTable.name} si
      INNER JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = si.${SaleItemsTable.invoiceNumber}
      LEFT JOIN ${ProductTable.name} p
        ON p.${ProductTable.nameColumn} = si.${SaleItemsTable.productName}
      WHERE s.${SalesTable.season} = ?
        AND LOWER(TRIM(COALESCE(si.${SaleItemsTable.productType}, ''))) != 'advance'
        AND (
          s.${SalesTable.transactionType} IS NULL
          OR s.${SalesTable.transactionType} = ?
          OR s.${SalesTable.transactionType} NOT IN (?, ?, ?)
        )
      GROUP BY si.${SaleItemsTable.productName}
      ORDER BY margin DESC
      LIMIT ?
      ''',
      [
        season,
        SaleTransactionType.productSale,
        SaleTransactionType.cashAdvance,
        SaleTransactionType.dieselAdvance,
        SaleTransactionType.petrolAdvance,
        capped,
      ],
    );

    return rows
        .map(
          (row) => ProductProfitRow(
            productName: row['product_name'] as String? ?? '',
            revenue: (row['revenue'] as num?)?.toDouble() ?? 0.0,
            cogs: (row['cogs'] as num?)?.toDouble() ?? 0.0,
            margin: (row['margin'] as num?)?.toDouble() ?? 0.0,
          ),
        )
        .where((r) => r.productName.isNotEmpty)
        .toList();
  }

  /// Cash / credit purchase split + stock additions by product category.
  Future<PurchasesBreakdown> getPurchasesBreakdown({String? season}) async {
    final metrics = await getSeasonalMetrics(season: season);
    final seasonName = metrics['season'] as String? ??
        SeasonUtils.getCurrentSeason().displayName;
    final seasonObj = SeasonUtils.parseSeasonDisplayName(seasonName) ??
        SeasonUtils.getCurrentSeason();
    final seasonStartIso = _formatDateTime(seasonObj.startDate);
    final seasonEndIso = _formatDateTime(seasonObj.endDate);

    final db = await database;
    final categoryRows = await db.rawQuery(
      '''
      SELECT
        COALESCE(p.${ProductTable.productType}, 'Fertilizer') AS product_type,
        COALESCE(SUM(pi.${PurchaseItemsTable.lineTotal}), 0) AS total
      FROM ${PurchaseItemsTable.name} pi
      INNER JOIN ${PurchaseInvoicesTable.name} inv
        ON inv.${PurchaseInvoicesTable.invoiceNumber}
          = pi.${PurchaseItemsTable.invoiceNumber}
      LEFT JOIN ${ProductTable.name} p
        ON p.${ProductTable.id} = pi.${PurchaseItemsTable.productId}
      WHERE inv.${PurchaseInvoicesTable.dateTime} >= ?
        AND inv.${PurchaseInvoicesTable.dateTime} <= ?
      GROUP BY COALESCE(p.${ProductTable.productType}, 'Fertilizer')
      ORDER BY total DESC
      ''',
      [seasonStartIso, seasonEndIso],
    );

    final byCategory = <String, double>{
      'Fertilizers': 0.0,
      'Seeds': 0.0,
      'Pesticides': 0.0,
    };
    for (final row in categoryRows) {
      final raw = row['product_type'] as String? ?? 'Fertilizer';
      final key = _normalizeProductCategory(raw);
      final amount = (row['total'] as num?)?.toDouble() ?? 0.0;
      byCategory[key] = (byCategory[key] ?? 0.0) + amount;
    }

    final categoryList = byCategory.entries
        .map(
          (e) => PurchaseCategoryAmount(category: e.key, amount: e.value),
        )
        .toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));

    return PurchasesBreakdown(
      season: seasonName,
      totalPurchases: (metrics['totalPurchases'] as num?)?.toDouble() ?? 0.0,
      cashPurchases: (metrics['cashPurchases'] as num?)?.toDouble() ?? 0.0,
      creditPurchases: (metrics['creditPurchases'] as num?)?.toDouble() ?? 0.0,
      byCategory: categoryList,
    );
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

  /// Village auto-suggest for Zamindar / Kisaan forms.
  ///
  /// Returns up to 5 distinct matching villages from both [ZamindarTable] and
  /// [KisaanTable] using `WHERE village LIKE '%query%'`.
  Future<List<String>> fetchVillageSuggestions(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT DISTINCT TRIM(village) AS village
      FROM (
        SELECT village FROM ${ZamindarTable.name}
        WHERE village IS NOT NULL AND TRIM(village) != '' AND village LIKE ?
        UNION
        SELECT village FROM ${KisaanTable.name}
        WHERE village IS NOT NULL AND TRIM(village) != '' AND village LIKE ?
      )
      ORDER BY village COLLATE NOCASE ASC
      LIMIT 5
      ''',
      ['%$trimmed%', '%$trimmed%'],
    );

    return rows
        .map((r) => (r['village'] as String?)?.trim() ?? '')
        .where((v) => v.isNotEmpty)
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
        s.${SalesTable.subtotal} AS subtotal,
        s.${SalesTable.itemDiscountsTotal} AS item_discounts_total,
        s.${SalesTable.overallDiscount} AS overall_discount,
        s.${SalesTable.seasonalIncrementTotal} AS seasonal_increment_total,
        COALESCE(
          NULLIF(TRIM(s.${SalesTable.description}), ''),
          CASE
            WHEN s.${SalesTable.transactionType} != '${SaleTransactionType.productSale}'
              THEN NULLIF(TRIM(s.${SalesTable.remarks}), '')
            ELSE NULL
          END
        ) AS invoice_description,
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
        'subtotal': (sale['subtotal'] as num?)?.toDouble() ?? 0.0,
        'seasonal_increment_total':
            (sale['seasonal_increment_total'] as num?)?.toDouble() ?? 0.0,
        'item_discounts_total':
            (sale['item_discounts_total'] as num?)?.toDouble() ?? 0.0,
        'overall_discount':
            (sale['overall_discount'] as num?)?.toDouble() ?? 0.0,
        'invoice_description':
            (sale['invoice_description'] as String?)?.trim() ?? '',
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

  static String formatBillPaymentDescription(String invoiceNumber) {
    final trimmed = invoiceNumber.trim();
    return trimmed.isEmpty ? 'Bill Payment' : 'Bill Payment for $trimmed';
  }

  static String formatBillPaymentDescriptionForInvoices(
    List<String> invoiceNumbers,
  ) {
    final unique = invoiceNumbers
        .map((invoice) => invoice.trim())
        .where((invoice) => invoice.isNotEmpty)
        .toList();
    if (unique.isEmpty) return 'Bill Payment';
    return 'Bill Payment for ${unique.join(', ')}';
  }

  static String formatWalletDeductionDescription(List<String> invoiceNumbers) {
    final unique = invoiceNumbers
        .map((invoice) => invoice.trim())
        .where((invoice) => invoice.isNotEmpty)
        .toList();
    if (unique.isEmpty) return 'Advance wallet deducted';
    return 'Advance wallet deducted for ${unique.join(', ')}';
  }

  static String _withSettlementNotes(String description, String? remarks) {
    final trimmed = remarks?.trim() ?? '';
    if (trimmed.isEmpty) return description;
    return '$description | Note: $trimmed';
  }

  static String _normalizedRemarks(String? remarks) {
    final trimmed = remarks?.trim() ?? '';
    return trimmed;
  }

  static String _splitSettlementPaymentMethod({
    required double walletDeductionAmount,
    required double cashReceivedAmount,
  }) {
    if (walletDeductionAmount > 0 && cashReceivedAmount > 0) {
      return 'Cash + Advance Wallet';
    }
    if (walletDeductionAmount > 0) return 'Advance Wallet Deduction';
    return 'Cash';
  }

  static String _ledgerCategoryForPaymentMethod(String paymentMethod) {
    if (paymentMethod == 'Advance Wallet Deduction') return 'WALLET_DEDUCTION';
    if (paymentMethod == 'Cash') return 'CASH_PAYMENT';
    return 'PAYMENT';
  }

  Future<void> _decrementAdvanceWalletOn(
    DatabaseExecutor txn, {
    required int zamindarId,
    required double amount,
  }) async {
    if (amount <= 0) return;
    final rows = await txn.query(
      ZamindarTable.name,
      columns: [ZamindarTable.advanceBalance],
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Zamindar $zamindarId not found');
    }
    final current = _readIntValue(rows.first[ZamindarTable.advanceBalance]);
    final deduct = amount.round();
    if (deduct > current) {
      throw StateError(
        'Deduction amount cannot exceed available wallet balance or outstanding dues.',
      );
    }
    await txn.update(
      ZamindarTable.name,
      {ZamindarTable.advanceBalance: current - deduct},
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
    );
  }

  /// Positive [delta] credits the wallet; negative [delta] draws it down.
  Future<void> _adjustAdvanceWalletOn(
    DatabaseExecutor txn, {
    required int zamindarId,
    required int delta,
  }) async {
    if (delta == 0) return;
    final rows = await txn.query(
      ZamindarTable.name,
      columns: [ZamindarTable.advanceBalance],
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Zamindar $zamindarId not found');
    }
    final current = _readIntValue(rows.first[ZamindarTable.advanceBalance]);
    final next = current + delta;
    if (next < 0) {
      throw StateError(
        delta < 0
            ? 'Deduction amount cannot exceed available wallet balance '
                '(Rs $current).'
            : 'Cannot reduce advance below zero (current wallet Rs $current).',
      );
    }
    await txn.update(
      ZamindarTable.name,
      {ZamindarTable.advanceBalance: next},
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
    );
  }

  /// Keeps [SalesTable.paidAmount] aligned with remaining payment rows so
  /// outstanding falls back correctly when the last payment is removed.
  Future<void> _syncInvoicePaidAmountOn(
    DatabaseExecutor txn,
    String invoiceNumber,
  ) async {
    final invoice = invoiceNumber.trim();
    if (invoice.isEmpty) return;
    final sumRows = await txn.rawQuery(
      '''
      SELECT COALESCE(SUM(${PaymentsTable.amountPaid}), 0) AS paid
      FROM ${PaymentsTable.name}
      WHERE ${PaymentsTable.invoiceNumber} = ?
      ''',
      [invoice],
    );
    final paid = (sumRows.first['paid'] as num?)?.round() ?? 0;
    await txn.update(
      SalesTable.name,
      {SalesTable.paidAmount: paid},
      where: '${SalesTable.invoiceNumber} = ?',
      whereArgs: [invoice],
    );
  }

  Future<int?> _resolvePaymentZamindarIdOn(
    DatabaseExecutor txn,
    Map<String, Object?> row,
  ) async {
    int? zamindarId = row[PaymentsTable.zamindarId] as int?;
    if (zamindarId != null) return zamindarId;
    final invoiceNumber =
        (row[PaymentsTable.invoiceNumber] as String?)?.trim();
    if (invoiceNumber == null || invoiceNumber.isEmpty) return null;
    final saleRows = await txn.query(
      SalesTable.name,
      columns: [SalesTable.zamindarId],
      where: '${SalesTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
      limit: 1,
    );
    if (saleRows.isEmpty) return null;
    return saleRows.first[SalesTable.zamindarId] as int?;
  }

  Future<String> _insertInvoicePaymentRow(
    DatabaseExecutor txn, {
    required String invoiceNumber,
    required DateTime dateTime,
    required int zamindarId,
    int? kisaanId,
    required double amount,
    required String paymentMethod,
    required String season,
    int? seasonId,
    String? notes,
  }) async {
    final paymentId = await generateNextPaymentId(txn, isAdvance: false);
    final trimmedNotes = _normalizedRemarks(notes);
    await txn.insert(PaymentsTable.name, {
      PaymentsTable.paymentId: paymentId,
      PaymentsTable.invoiceNumber: invoiceNumber,
      PaymentsTable.dateTime: _formatDateTime(dateTime),
      PaymentsTable.zamindarId: zamindarId,
      PaymentsTable.kisaanId: kisaanId,
      PaymentsTable.amountPaid: amount.round(),
      PaymentsTable.paymentMethod: paymentMethod,
      PaymentsTable.season: season,
      PaymentsTable.seasonId: seasonId,
      if (trimmedNotes.isNotEmpty) PaymentsTable.notes: trimmedNotes,
    });
    return paymentId;
  }

  Future<void> _upsertBillPaymentLedgerEntry(
    DatabaseExecutor txn, {
    required String paymentId,
    required int zamindarId,
    int? kisaanId,
    String? invoiceNumber,
    required String paymentMethod,
    required int amount,
    required DateTime dateTime,
    required String season,
    int? seasonId,
    required String description,
    String? notes,
  }) async {
    await txn.delete(
      LedgerTransactionTable.name,
      where: '${LedgerTransactionTable.paymentId} = ?',
      whereArgs: [paymentId],
    );

    final trimmedNotes = _normalizedRemarks(notes);
    await txn.insert(LedgerTransactionTable.name, {
      LedgerTransactionTable.zamindarId: zamindarId,
      LedgerTransactionTable.kisaanId: kisaanId,
      LedgerTransactionTable.invoiceNumber: invoiceNumber,
      LedgerTransactionTable.paymentId: paymentId,
      LedgerTransactionTable.type: LedgerTransactionType.credit,
      LedgerTransactionTable.category: _ledgerCategoryForPaymentMethod(
        paymentMethod,
      ),
      LedgerTransactionTable.description: _withSettlementNotes(
        description,
        trimmedNotes,
      ),
      LedgerTransactionTable.amount: amount,
      LedgerTransactionTable.dateTime: _formatDateTime(dateTime),
      LedgerTransactionTable.season: season,
      if (seasonId != null) LedgerTransactionTable.seasonId: seasonId,
      if (trimmedNotes.isNotEmpty) LedgerTransactionTable.notes: trimmedNotes,
    });
  }

  /// Inserts a payment settlement for a specific invoice.
  /// [invoiceNumber] must reference an existing sale — never pass synthetic values.
  ///
  /// When [walletDeductionAmount] > 0, the settlement is split:
  /// wallet drawdown + remaining cash. [amountPaid] is the total settlement.
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
    double walletDeductionAmount = 0,
    String? remarks,
  }) async {
    if (invoiceNumber.trim().isEmpty) {
      throw ArgumentError(
        'invoiceNumber is required for invoice-scoped settlements.',
      );
    }
    if (amountPaid <= 0) {
      throw ArgumentError('amountPaid must be greater than zero.');
    }

    final wallet = walletDeductionAmount < 0 ? 0.0 : walletDeductionAmount;
    final cash = amountPaid - wallet;
    if (wallet > amountPaid + 0.01 || cash < -0.01) {
      throw StateError(
        'Deduction amount cannot exceed available wallet balance or outstanding dues.',
      );
    }

    final remainingBalance = await getInvoiceRemainingBalance(invoiceNumber);
    if (amountPaid > remainingBalance + 0.01) {
      throw StateError(
        'Payment amount exceeds invoice remaining balance '
        '(Rs ${remainingBalance.toStringAsFixed(0)}).',
      );
    }
    if (wallet > remainingBalance + 0.01) {
      throw StateError(
        'Deduction amount cannot exceed available wallet balance or outstanding dues.',
      );
    }
    if (wallet > 0) {
      final advance = await getAdvanceBalance(zamindarId);
      if (wallet > advance + 0.01) {
        throw StateError(
          'Deduction amount cannot exceed available wallet balance or outstanding dues.',
        );
      }
    }

    final db = await database;
    late final String resolvedPaymentId;
    final notes = _normalizedRemarks(remarks);
    await db.transaction((txn) async {
      final seasonId = await _lookupSeasonIdForLabel(txn, season);
      String? lastPaymentId = paymentId;

      if (wallet > 0) {
        lastPaymentId = await _insertInvoicePaymentRow(
          txn,
          invoiceNumber: invoiceNumber,
          dateTime: dateTime,
          zamindarId: zamindarId,
          kisaanId: kisaanId,
          amount: wallet,
          paymentMethod: 'Advance Wallet Deduction',
          season: season,
          seasonId: seasonId,
          notes: notes,
        );
        await _upsertBillPaymentLedgerEntry(
          txn,
          paymentId: lastPaymentId,
          zamindarId: zamindarId,
          kisaanId: kisaanId,
          invoiceNumber: invoiceNumber,
          paymentMethod: 'Advance Wallet Deduction',
          amount: wallet.round(),
          dateTime: dateTime,
          season: season,
          seasonId: seasonId,
          description: formatWalletDeductionDescription([invoiceNumber]),
          notes: notes,
        );
        await _decrementAdvanceWalletOn(
          txn,
          zamindarId: zamindarId,
          amount: wallet,
        );
      }

      if (cash > 0.01) {
        if (wallet <= 0 && paymentId != null) {
          lastPaymentId = paymentId;
          await txn.insert(PaymentsTable.name, {
            PaymentsTable.paymentId: lastPaymentId,
            PaymentsTable.invoiceNumber: invoiceNumber,
            PaymentsTable.dateTime: _formatDateTime(dateTime),
            PaymentsTable.zamindarId: zamindarId,
            PaymentsTable.kisaanId: kisaanId,
            PaymentsTable.amountPaid: cash.round(),
            PaymentsTable.paymentMethod: paymentMethod,
            PaymentsTable.season: season,
            PaymentsTable.seasonId: seasonId,
            if (notes.isNotEmpty) PaymentsTable.notes: notes,
          });
        } else {
          lastPaymentId = await _insertInvoicePaymentRow(
            txn,
            invoiceNumber: invoiceNumber,
            dateTime: dateTime,
            zamindarId: zamindarId,
            kisaanId: kisaanId,
            amount: cash,
            paymentMethod: paymentMethod,
            season: season,
            seasonId: seasonId,
            notes: notes,
          );
        }
        await _upsertBillPaymentLedgerEntry(
          txn,
          paymentId: lastPaymentId,
          zamindarId: zamindarId,
          kisaanId: kisaanId,
          invoiceNumber: invoiceNumber,
          paymentMethod: paymentMethod,
          amount: cash.round(),
          dateTime: dateTime,
          season: season,
          seasonId: seasonId,
          description: formatBillPaymentDescription(invoiceNumber),
          notes: notes,
        );
      }

      if (lastPaymentId == null) {
        throw StateError('Settlement produced no payment rows.');
      }
      resolvedPaymentId = lastPaymentId;

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
  ///
  /// [amountPaid] is the total settlement. When [walletDeductionAmount] > 0,
  /// wallet is applied first, then remaining cash.
  Future<BillSettlementResult> settleKisaanBulkPayment({
    required int zamindarId,
    required String kisaanName,
    required double amountPaid,
    required String paymentMethod,
    required String season,
    double walletDeductionAmount = 0,
    String? remarks,
  }) async {
    if (amountPaid <= 0) {
      throw ArgumentError('amountPaid must be greater than zero.');
    }

    final wallet = walletDeductionAmount < 0 ? 0.0 : walletDeductionAmount;
    final cash = amountPaid - wallet;
    if (wallet > amountPaid + 0.01 || cash < -0.01) {
      throw StateError(
        'Deduction amount cannot exceed available wallet balance or outstanding dues.',
      );
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
    if (wallet > outstanding + 0.01) {
      throw StateError(
        'Deduction amount cannot exceed available wallet balance or outstanding dues.',
      );
    }
    if (wallet > 0) {
      final advance = await getAdvanceBalance(zamindarId);
      if (wallet > advance + 0.01) {
        throw StateError(
          'Deduction amount cannot exceed available wallet balance or outstanding dues.',
        );
      }
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

    final settledInvoices = <String>[];
    final walletPaymentIds = <String>[];
    final cashPaymentIds = <String>[];
    final cashPaidNowByInvoice = <String, double>{};
    final now = DateTime.now();
    final notes = _normalizedRemarks(remarks);

    String resolvedSeason = season.trim();
    int? resolvedSeasonId;
    if (resolvedSeason.isEmpty) {
      final active = await getActiveSeason();
      resolvedSeason = active?.name ?? '';
      resolvedSeasonId = active?.id;
    }

    final db = await database;
    await db.transaction((txn) async {
      if (resolvedSeason.isNotEmpty && resolvedSeasonId == null) {
        resolvedSeasonId = await _lookupSeasonIdForLabel(txn, resolvedSeason);
      }

      double remainingWallet = wallet;
      double remainingCash = cash;

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
        if (remainingWallet <= 0 && remainingCash <= 0) break;

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

        final walletAlloc = remainingWallet >= remainingDebt
            ? remainingDebt
            : remainingWallet;
        final cashAlloc = (remainingDebt - walletAlloc) <= remainingCash
            ? (remainingDebt - walletAlloc)
            : remainingCash;
        if (walletAlloc <= 0 && cashAlloc <= 0) continue;

        settledInvoices.add(invoiceNumber);
        cashPaidNowByInvoice[invoiceNumber] = walletAlloc + cashAlloc;

        if (walletAlloc > 0) {
          final paymentId = await _insertInvoicePaymentRow(
            txn,
            invoiceNumber: invoiceNumber,
            dateTime: now,
            zamindarId: zamindarId,
            kisaanId: kisaanId,
            amount: walletAlloc,
            paymentMethod: 'Advance Wallet Deduction',
            season: resolvedSeason,
            seasonId: resolvedSeasonId,
            notes: notes,
          );
          walletPaymentIds.add(paymentId);
          remainingWallet -= walletAlloc;
        }

        if (cashAlloc > 0) {
          final paymentId = await _insertInvoicePaymentRow(
            txn,
            invoiceNumber: invoiceNumber,
            dateTime: now,
            zamindarId: zamindarId,
            kisaanId: kisaanId,
            amount: cashAlloc,
            paymentMethod: paymentMethod,
            season: resolvedSeason,
            seasonId: resolvedSeasonId,
            notes: notes,
          );
          cashPaymentIds.add(paymentId);
          remainingCash -= cashAlloc;
        }
      }

      final allPaymentIds = [...walletPaymentIds, ...cashPaymentIds];
      if (allPaymentIds.isNotEmpty) {
        for (final paymentId in allPaymentIds) {
          await txn.delete(
            LedgerTransactionTable.name,
            where: '${LedgerTransactionTable.paymentId} = ?',
            whereArgs: [paymentId],
          );
        }

        if (walletPaymentIds.isNotEmpty) {
          await txn.insert(LedgerTransactionTable.name, {
            LedgerTransactionTable.zamindarId: zamindarId,
            LedgerTransactionTable.kisaanId: kisaanId,
            LedgerTransactionTable.invoiceNumber: settledInvoices.first,
            LedgerTransactionTable.paymentId: walletPaymentIds.first,
            LedgerTransactionTable.type: LedgerTransactionType.credit,
            LedgerTransactionTable.category: 'WALLET_DEDUCTION',
            LedgerTransactionTable.description: _withSettlementNotes(
              formatWalletDeductionDescription(settledInvoices),
              notes,
            ),
            LedgerTransactionTable.amount: wallet.round(),
            LedgerTransactionTable.dateTime: _formatDateTime(now),
            LedgerTransactionTable.season: resolvedSeason,
            if (resolvedSeasonId != null)
              LedgerTransactionTable.seasonId: resolvedSeasonId,
            if (notes.isNotEmpty) LedgerTransactionTable.notes: notes,
          });
        }

        if (cashPaymentIds.isNotEmpty) {
          await txn.insert(LedgerTransactionTable.name, {
            LedgerTransactionTable.zamindarId: zamindarId,
            LedgerTransactionTable.kisaanId: kisaanId,
            LedgerTransactionTable.invoiceNumber: settledInvoices.first,
            LedgerTransactionTable.paymentId: cashPaymentIds.first,
            LedgerTransactionTable.type: LedgerTransactionType.credit,
            LedgerTransactionTable.category: _ledgerCategoryForPaymentMethod(
              paymentMethod,
            ),
            LedgerTransactionTable.description: _withSettlementNotes(
              formatBillPaymentDescriptionForInvoices(settledInvoices),
              notes,
            ),
            LedgerTransactionTable.amount: cash.round(),
            LedgerTransactionTable.dateTime: _formatDateTime(now),
            LedgerTransactionTable.season: resolvedSeason,
            if (resolvedSeasonId != null)
              LedgerTransactionTable.seasonId: resolvedSeasonId,
            if (notes.isNotEmpty) LedgerTransactionTable.notes: notes,
          });
        }
      }

      await _decrementAdvanceWalletOn(
        txn,
        zamindarId: zamindarId,
        amount: wallet,
      );
      await _recalculateZamindarBalanceOn(txn, zamindarId);
    });

    notifyListeners();

    final invoiceSummaries = <BillSettlementInvoiceSummary>[];
    for (final invoiceNumber in settledInvoices) {
      invoiceSummaries.add(
        await getInvoiceSettlementSnapshot(
          invoiceNumber,
          cashPaidNow: cashPaidNowByInvoice[invoiceNumber] ?? 0,
        ),
      );
    }

    final resolvedMethod = _splitSettlementPaymentMethod(
      walletDeductionAmount: wallet,
      cashReceivedAmount: cash,
    );
    final description = _withSettlementNotes(
      formatBillPaymentDescriptionForInvoices(settledInvoices),
      notes,
    );

    return BillSettlementResult(
      zamindarId: zamindarId,
      zamindarName: zamindar.name,
      kisaanId: kisaanId,
      kisaanName: kisaanName,
      amountPaid: amountPaid,
      walletDeductionAmount: wallet,
      cashReceivedAmount: cash,
      remarks: notes.isEmpty ? null : notes,
      invoiceNumbers: List.unmodifiable(settledInvoices),
      paymentId: cashPaymentIds.isNotEmpty
          ? cashPaymentIds.first
          : (walletPaymentIds.isNotEmpty ? walletPaymentIds.first : null),
      dateTime: now,
      description: description,
      paymentMethod: resolvedMethod,
      invoiceSummaries: List.unmodifiable(invoiceSummaries),
    );
  }

  /// Records a kisaan-level settlement via FIFO invoice allocation.
  Future<void> recordKisaanSettlement({
    required int zamindarId,
    required int kisaanId,
    required double amountPaid,
    required String season,
    String paymentMethod = 'Cash',
    double walletDeductionAmount = 0,
    String? remarks,
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
      walletDeductionAmount: walletDeductionAmount,
      remarks: remarks,
    );
  }

  /// Gets all payments with aggregated sale line items for linked invoices.
  Future<List<Map<String, dynamic>>> getAllPayments({
    String? season,
    int? seasonId,
  }) async {
    final db = await database;
    await _ensurePaymentEditAuditSchema(db);
    final where = <String>[];
    final args = <Object?>[];

    if (seasonId != null) {
      where.add('p.${PaymentsTable.seasonId} = ?');
      args.add(seasonId);
    } else if (season != null) {
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
          WHEN p.${PaymentsTable.paymentMethod} = 'Advance Wallet Deduction'
            THEN 'Advance payments deducted for (' || COALESCE((
              SELECT GROUP_CONCAT(
                item.${SaleItemsTable.productName}
                  || ' x'
                  || CAST(item.${SaleItemsTable.quantity} AS TEXT),
                ', '
              )
              FROM ${SaleItemsTable.name} item
              WHERE item.${SaleItemsTable.invoiceNumber}
                  = p.${PaymentsTable.invoiceNumber}
            ), '—') || ')'
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

  /// Single payment row by receipt id (includes JOIN name aliases).
  Future<Map<String, dynamic>?> getPaymentById(String paymentId) async {
    final id = paymentId.trim();
    if (id.isEmpty) return null;
    final db = await database;
    await _ensurePaymentEditAuditSchema(db);
    final rows = await db.rawQuery('''
      SELECT
        p.*,
        COALESCE(
          z.${ZamindarTable.nameColumn},
          zs.${ZamindarTable.nameColumn}
        ) AS ${PaymentsTable.zamindarName},
        COALESCE(
          k.${KisaanTable.nameColumn},
          ks.${KisaanTable.nameColumn}
        ) AS ${PaymentsTable.kisaanName}
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
      WHERE p.${PaymentsTable.paymentId} = ?
      LIMIT 1
      ''', [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// Updates a customer payment entry with audit fields.
  ///
  /// Triggers rebuild the linked `ledger_transactions` CREDIT row.
  /// Cash-drawer impact follows from live SUM of Cash payments — no
  /// separate drawer mutation is required.
  /// Wallet deductions adjust [ZamindarTable.advanceBalance] by the amount delta.
  Future<void> updatePaymentEntry({
    required String paymentId,
    required DateTime dateTime,
    required double amountPaid,
    required String paymentMethod,
    String notes = '',
    required String editedBy,
  }) async {
    if (amountPaid <= 0) {
      throw ArgumentError('Payment amount must be greater than zero');
    }
    final method = paymentMethod.trim();
    if (method.isEmpty) {
      throw ArgumentError('Payment method is required');
    }

    final db = await database;
    await _ensurePaymentEditAuditSchema(db);

    // Pre-read outside the write transaction to avoid nested DB access.
    final existingRows = await db.query(
      PaymentsTable.name,
      where: '${PaymentsTable.paymentId} = ?',
      whereArgs: [paymentId],
      limit: 1,
    );
    if (existingRows.isEmpty) {
      throw StateError('Payment $paymentId not found');
    }
    final existing = existingRows.first;
    final existingMethod =
        (existing[PaymentsTable.paymentMethod] as String?)?.trim() ?? '';
    final isWallet = existingMethod == 'Advance Wallet Deduction';
    if (isWallet && method != 'Advance Wallet Deduction') {
      throw StateError(
        'Wallet deduction entries cannot be converted to another payment mode.',
      );
    }
    if (!isWallet && method == 'Advance Wallet Deduction') {
      throw StateError(
        'Cash payments cannot be converted to a wallet deduction.',
      );
    }
    final season = (existing[PaymentsTable.season] as String?)?.trim() ?? '';
    if (season.isNotEmpty && await isSeasonArchived(season)) {
      throw StateError(
        'This payment belongs to a closed/settled season and cannot be modified.',
      );
    }

    await db.transaction((txn) async {
      final rows = await txn.query(
        PaymentsTable.name,
        where: '${PaymentsTable.paymentId} = ?',
        whereArgs: [paymentId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Payment $paymentId not found');
      }
      final row = rows.first;
      final oldMethod =
          (row[PaymentsTable.paymentMethod] as String?)?.trim() ?? '';
      final wasWallet = oldMethod == 'Advance Wallet Deduction';
      if (wasWallet && method != 'Advance Wallet Deduction') {
        throw StateError(
          'Wallet deduction entries cannot be converted to another payment mode.',
        );
      }
      if (!wasWallet && method == 'Advance Wallet Deduction') {
        throw StateError(
          'Cash payments cannot be converted to a wallet deduction.',
        );
      }

      final oldAmount =
          (row[PaymentsTable.amountPaid] as num?)?.toDouble() ?? 0;
      final invoiceNumber =
          (row[PaymentsTable.invoiceNumber] as String?)?.trim();
      final isAdvanceCollection =
          invoiceNumber == null || invoiceNumber.isEmpty;

      final zamindarId = await _resolvePaymentZamindarIdOn(txn, row);
      if (zamindarId == null) {
        throw StateError('Payment $paymentId is not linked to a Zamindar');
      }

      // Invoice-scoped: new amount cannot exceed remaining + current payment.
      if (!isAdvanceCollection) {
        final remaining = await _invoiceRemainingOn(txn, invoiceNumber);
        final maxAllowed = remaining + oldAmount;
        if (amountPaid > maxAllowed + 0.01) {
          throw StateError(
            'Payment amount exceeds invoice remaining balance '
            '(Rs ${maxAllowed.toStringAsFixed(0)}).',
          );
        }
      }

      final amountDelta = amountPaid.round() - oldAmount.round();
      if (isAdvanceCollection) {
        await _adjustAdvanceWalletOn(
          txn,
          zamindarId: zamindarId,
          delta: amountDelta,
        );
      } else if (wasWallet) {
        // Larger deduction draws more from the wallet.
        await _adjustAdvanceWalletOn(
          txn,
          zamindarId: zamindarId,
          delta: -amountDelta,
        );
      }

      final existingOriginal = row[PaymentsTable.originalAmount];
      final originalAmount = existingOriginal is num
          ? existingOriginal.round()
          : oldAmount.round();

      await txn.update(
        PaymentsTable.name,
        {
          PaymentsTable.dateTime: _formatDateTime(dateTime),
          PaymentsTable.amountPaid: amountPaid.round(),
          PaymentsTable.paymentMethod: method,
          PaymentsTable.notes: notes.trim().isEmpty ? null : notes.trim(),
          PaymentsTable.editedAt: _formatDateTime(DateTime.now()),
          PaymentsTable.editedBy: editedBy,
          PaymentsTable.originalAmount: originalAmount,
        },
        where: '${PaymentsTable.paymentId} = ?',
        whereArgs: [paymentId],
      );
      // after_payment_update rebuilds ledger_transactions CREDIT row.

      if (!isAdvanceCollection) {
        await _syncInvoicePaidAmountOn(txn, invoiceNumber);
      }
      await _recalculateZamindarBalanceOn(txn, zamindarId);

      await _writeAuditLog(
        actionType: AuditActionType.editPayment,
        referenceId: paymentId,
        description:
            'Edited payment $paymentId: '
            'Rs ${oldAmount.round()} ($oldMethod) → '
            'Rs ${amountPaid.round()} ($method)',
        executor: txn,
      );
    });

    notifyListeners();
  }

  Future<double> _invoiceRemainingOn(
    DatabaseExecutor txn,
    String invoiceNumber,
  ) async {
    final remRows = await txn.rawQuery(
      '''
      SELECT
        s.${SalesTable.totalPayable} - ($_sqlSaleCollectedExpr) AS remaining
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.invoiceNumber} = ?
      LIMIT 1
      ''',
      [invoiceNumber],
    );
    if (remRows.isEmpty) {
      throw StateError('Linked invoice $invoiceNumber not found');
    }
    return (remRows.first['remaining'] as num?)?.toDouble() ?? 0;
  }

  /// Deletes a cash settlement or wallet-deduction payment and reverses
  /// outstanding / advance-wallet impact. Linked ledger CREDIT rows are
  /// removed by `after_payment_delete` (and payment_id ON DELETE CASCADE).
  Future<void> deletePaymentEntry({required String paymentId}) async {
    final db = await database;
    await _ensurePaymentEditAuditSchema(db);

    final existingRows = await db.query(
      PaymentsTable.name,
      where: '${PaymentsTable.paymentId} = ?',
      whereArgs: [paymentId],
      limit: 1,
    );
    if (existingRows.isEmpty) {
      throw StateError('Payment $paymentId not found');
    }
    final existing = existingRows.first;
    final season = (existing[PaymentsTable.season] as String?)?.trim() ?? '';
    if (season.isNotEmpty && await isSeasonArchived(season)) {
      throw StateError(
        'This payment belongs to a closed/settled season and cannot be modified.',
      );
    }

    await db.transaction((txn) async {
      final rows = await txn.query(
        PaymentsTable.name,
        where: '${PaymentsTable.paymentId} = ?',
        whereArgs: [paymentId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Payment $paymentId not found');
      }
      final row = rows.first;
      final oldMethod =
          (row[PaymentsTable.paymentMethod] as String?)?.trim() ?? '';
      final oldAmount =
          (row[PaymentsTable.amountPaid] as num?)?.round() ?? 0;
      final invoiceNumber =
          (row[PaymentsTable.invoiceNumber] as String?)?.trim();
      final isAdvanceCollection =
          invoiceNumber == null || invoiceNumber.isEmpty;
      final isWallet = oldMethod == 'Advance Wallet Deduction';

      final zamindarId = await _resolvePaymentZamindarIdOn(txn, row);
      if (zamindarId == null) {
        throw StateError('Payment $paymentId is not linked to a Zamindar');
      }

      if (isAdvanceCollection) {
        await _adjustAdvanceWalletOn(
          txn,
          zamindarId: zamindarId,
          delta: -oldAmount,
        );
      } else if (isWallet) {
        await _adjustAdvanceWalletOn(
          txn,
          zamindarId: zamindarId,
          delta: oldAmount,
        );
      }

      await txn.delete(
        PaymentsTable.name,
        where: '${PaymentsTable.paymentId} = ?',
        whereArgs: [paymentId],
      );

      if (!isAdvanceCollection) {
        await _syncInvoicePaidAmountOn(txn, invoiceNumber);
      }
      await _recalculateZamindarBalanceOn(txn, zamindarId);

      await _writeAuditLog(
        actionType: AuditActionType.deletePayment,
        referenceId: paymentId,
        description:
            'Deleted payment $paymentId: '
            'Rs $oldAmount ($oldMethod)',
        executor: txn,
      );
    });

    notifyListeners();
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

  /// Outstanding balance for a single invoice after all payments.
  Future<double> getInvoiceRemainingBalance(String invoiceNumber) async {
    final snapshot = await getInvoiceSettlementSnapshot(invoiceNumber);
    return snapshot.remainingBalance;
  }

  /// Paid / remaining snapshot for receipt printing after settlement.
  Future<BillSettlementInvoiceSummary> getInvoiceSettlementSnapshot(
    String invoiceNumber, {
    double cashPaidNow = 0,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT
        s.${SalesTable.totalPayable} AS total,
        ($_sqlSaleCollectedExpr) AS paid,
        ($_sqlSaleRemainingExpr) AS remaining
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.invoiceNumber} = ?
      LIMIT 1
      ''',
      [invoiceNumber],
    );
    if (rows.isEmpty) {
      return BillSettlementInvoiceSummary(
        invoiceNumber: invoiceNumber,
        cashPaidNow: cashPaidNow,
        totalPaidCash: 0,
        remainingBalance: 0,
        invoiceTotal: 0,
      );
    }
    final row = rows.first;
    return BillSettlementInvoiceSummary(
      invoiceNumber: invoiceNumber,
      cashPaidNow: cashPaidNow,
      totalPaidCash: (row['paid'] as num?)?.toDouble() ?? 0,
      remainingBalance: (row['remaining'] as num?)?.toDouble() ?? 0,
      invoiceTotal: (row['total'] as num?)?.toDouble() ?? 0,
    );
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
    String? description,
  }) async {
    final isCashSale = paymentMethod == 'Cash';
    final isCreditSale = paymentMethod == 'Credit';
    final db = await database;
    final affectedZamindarIds = <int>{};

    await db.transaction((txn) async {
      final existingSale = await txn.query(
        SalesTable.name,
        columns: [SalesTable.zamindarId, SalesTable.season],
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (existingSale.isEmpty) {
        throw StateError('Invoice $invoiceNumber was not found.');
      }

      final existingSeason =
          (existingSale.first[SalesTable.season] as String? ?? '').trim();
      if (existingSeason.isNotEmpty) {
        final archived = await txn.query(
          ArchivedSeasonTable.name,
          columns: [ArchivedSeasonTable.seasonLabel],
          where: '${ArchivedSeasonTable.seasonLabel} = ?',
          whereArgs: [existingSeason],
          limit: 1,
        );
        if (archived.isNotEmpty) {
          throw StateError(
            'Season "$existingSeason" is locked & archived. '
            'Past invoices for this closed season cannot be edited.',
          );
        }
      }

      final previousZamindarId =
          existingSale.first[SalesTable.zamindarId] as int?;
      if (previousZamindarId != null) {
        affectedZamindarIds.add(previousZamindarId);
      }

      // Restore stock for old line items (by stock_movements product_id).
      await _restoreStockForInvoice(txn, invoiceNumber);

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
        (sum, item) => sum + item.totalItemDiscount,
      );
      final seasonalIncrementTotal = items.fold<double>(
        0.0,
        (sum, item) => sum + item.totalItemSeasonalInc,
      );
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

      final isWalkInSale = resolvedZamindarId == null;
      if (isWalkInSale && isCreditSale) {
        throw StateError(
          'Cannot update credit sale: zamindar "$zamindarName" was not '
          'resolved to an id. Credit requires a registered Zamindar.',
        );
      }
      if (isWalkInSale && zamindarName.trim().isEmpty) {
        throw StateError(
          'Cannot update walk-in sale: customer name is empty.',
        );
      }

      final trimmedDescription = description?.trim();
      final storedDescription =
          (trimmedDescription != null && trimmedDescription.isNotEmpty)
          ? trimmedDescription
          : null;

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
          SalesTable.seasonId: await _lookupSeasonIdForLabel(txn, season),
          SalesTable.paymentTerm: isCreditSale ? paymentTerm : null,
          SalesTable.transactionType: SaleTransactionType.productSale,
          SalesTable.creditAmount: creditAmount.round(),
          SalesTable.remarks: isWalkInSale ? zamindarName.trim() : null,
          SalesTable.description: storedDescription,
          SalesTable.zamindarId: resolvedZamindarId,
          SalesTable.kisaanId: resolvedKisaanId,
        },
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      // after_sale_update trigger refreshes the sale DEBIT ledger row.

      for (final item in items) {
        await txn.insert(SaleItemsTable.name, {
          SaleItemsTable.invoiceNumber: invoiceNumber,
          SaleItemsTable.productName: item.productName,
          SaleItemsTable.productType: productType,
          SaleItemsTable.quantity: item.qty.round(),
          SaleItemsTable.unitPrice: item.unitPrice.round(),
          SaleItemsTable.seasonalIncrement: item.seasonalIncrement.round(),
          // Stored per-unit (same convention as seasonalIncrement).
          SaleItemsTable.itemDiscount: item.discount.round(),
          SaleItemsTable.subtotal: item.lineSubtotal.round(),
        });
      }

      final partyLabel = await _resolveSalePartyLabel(txn, zamindarName);
      for (final item in items) {
        final pid = item.productId;
        if (pid == null || pid <= 0) continue;
        final rows = await txn.query(
          ProductTable.name,
          columns: [ProductTable.availableStock],
          where: '${ProductTable.id} = ?',
          whereArgs: [pid],
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
          whereArgs: [pid],
        );
        await _insertStockMovement(
          txn,
          productId: pid,
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
          PaymentsTable.seasonId: await _lookupSeasonIdForLabel(txn, season),
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
          PaymentsTable.seasonId: await _lookupSeasonIdForLabel(txn, season),
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
          PaymentsTable.seasonId: await _lookupSeasonIdForLabel(txn, season),
        });
      }
      // Ledger CREDIT rows for payments are created by after_payment_insert.

      if (resolvedZamindarId != null) {
        affectedZamindarIds.add(resolvedZamindarId);
      }
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
          PaymentsTable.seasonId: await _lookupSeasonIdForLabel(txn, season),
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
  static const String seasonId = 'season_id';
  static const String notes = 'notes';
}

class LedgerTransactionType {
  static const String debit = 'DEBIT';
  static const String credit = 'CREDIT';
}

/// Aliases for [SalesTable] columns joined onto ledger transaction queries.
class SaleJoinColumns {
  static const String subtotal = 'sale_subtotal';
  static const String seasonalIncrementTotal = 'sale_seasonal_increment_total';
  static const String itemDiscountsTotal = 'sale_item_discounts_total';
  static const String overallDiscount = 'sale_overall_discount';
  static const String totalPayable = 'sale_total_payable';
  static const String remarks = 'sale_remarks';
  static const String description = 'sale_description';
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
  static const String seasonId = 'season_id';
  static const String paymentTerm = 'payment_term';
  static const String transactionType = 'transaction_type';
  static const String creditAmount = 'credit_amount';
  static const String fuelQuantity = 'fuel_quantity';
  /// Walk-in customer display name (when zamindar_id is null) or advance notes.
  static const String remarks = 'remarks';
  /// Optional free-text transaction / invoice notes.
  static const String description = 'description';
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

  /// Invoice / receipt line for zero-margin khaata loan records.
  static String khaataReceiptLabel(String type, {double? liters}) {
    if (isFuelAdvance(type)) {
      if (liters != null && liters > 0) {
        final lit = liters == liters.roundToDouble()
            ? liters.toStringAsFixed(0)
            : liters
                .toStringAsFixed(2)
                .replaceFirst(RegExp(r'0+$'), '')
                .replaceFirst(RegExp(r'\.$'), '');
        return 'Fuel Slip (Khaata Record) ($lit L)';
      }
      return 'Fuel Slip (Khaata Record)';
    }
    if (type == cashAdvance) {
      return 'Advance Loan (Khaata Record)';
    }
    return displayLabel(type);
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
  static const String seasonId = 'season_id';
  static const String editedAt = 'edited_at';
  static const String editedBy = 'edited_by';
  static const String originalAmount = 'original_amount';
  static const String notes = 'notes';

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
  static const String address = 'address';
  static const String balance = 'balance';
  static const String isActive = 'is_active';
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
  static const String seasonId = 'season_id';
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

class PartnerTable {
  static const String name = 'partners';
  static const String id = 'id';
  static const String nameColumn = 'name';
  static const String phone = 'phone';
  static const String userAccountId = 'user_account_id';
  static const String zamindarId = 'zamindar_id';
  static const String initialCapital = 'initial_capital';
  static const String outOfPocketInjections = 'out_of_pocket_injections';
  static const String reinvestedProfit = 'reinvested_profit';
  static const String totalDrawings = 'total_drawings';
  static const String permanentCapitalWithdrawals =
      'permanent_capital_withdrawals';
  static const String unsettledProfit = 'unsettled_profit';
  static const String activeDrawings = 'active_drawings';
  static const String isActive = 'is_active';
  static const String createdAt = 'created_at';
}

class PartnerDrawingTable {
  static const String name = 'partner_drawings';
  static const String id = 'id';
  static const String partnerId = 'partner_id';
  static const String amount = 'amount';
  static const String type = 'type';
  static const String date = 'date';
  static const String notes = 'notes';
  static const String isSettled = 'is_settled';
}

class PartnerTransactionTable {
  static const String name = 'partner_transactions';
  static const String id = 'id';
  static const String partnerId = 'partner_id';
  static const String type = 'type';
  static const String amount = 'amount';
  static const String date = 'date';
  static const String paymentChannel = 'payment_channel';
  static const String reference = 'reference';
  static const String notes = 'notes';
  static const String seasonLabel = 'season_label';
  static const String equityPctBefore = 'equity_pct_before';
  static const String equityPctAfter = 'equity_pct_after';
  static const String invoiceNumber = 'invoice_number';
}

class ArchivedSeasonTable {
  static const String name = 'archived_seasons';
  static const String seasonLabel = 'season_label';
  static const String archivedAt = 'archived_at';
  static const String notes = 'notes';
}

class SeasonsTable {
  static const String name = 'seasons';
  static const String id = 'id';
  static const String nameCol = 'name';
  static const String seasonType = 'season_type';
  static const String startDate = 'start_date';
  static const String endDate = 'end_date';
  static const String isActive = 'is_active';
}

/// Shared actor-stamp column names on transactional tables.
class ActorColumns {
  static const String createdByUserId = 'created_by_user_id';
  static const String createdByUserName = 'created_by_user_name';
  static const String createdAt = 'created_at';
}

class UserTable {
  static const String name = 'users';
  static const String id = 'id';
  static const String nameColumn = 'name';
  static const String phone = 'phone';
  static const String email = 'email';
  static const String role = 'role';
  static const String pinCode = 'pin_code';
  static const String partnerId = 'partner_id';
  static const String isActive = 'is_active';
  static const String createdAt = 'created_at';
}

class AuditLogTable {
  static const String name = 'audit_logs';
  static const String id = 'id';
  static const String userId = 'user_id';
  static const String userName = 'user_name';
  static const String actionType = 'action_type';
  static const String referenceId = 'reference_id';
  static const String description = 'description';
  static const String timestamp = 'timestamp';
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

/// Scratch row used while allocating invoice-level overall discount.
class _ProductLedgerDraft {
  final String invoiceNumber;
  final DateTime dateTime;
  final String kisaanName;
  final String productName;
  final int quantity;
  final int unitPrice;
  final int seasonalIncrement;
  final int itemDiscount;
  final int lineSubtotal;
  final int invoiceOverallDiscount;
  final String uom;

  const _ProductLedgerDraft({
    required this.invoiceNumber,
    required this.dateTime,
    required this.kisaanName,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    required this.seasonalIncrement,
    required this.itemDiscount,
    required this.lineSubtotal,
    required this.invoiceOverallDiscount,
    required this.uom,
  });
}

/// One sale line-item row for the Zamindar product-wise ledger panel.
class ZamindarProductLedgerEntry {
  final String invoiceNumber;
  final DateTime dateTime;
  final String kisaanName;
  final String productName;
  final int quantity;
  /// Base unit price (excludes seasonal increment).
  final int unitPrice;
  /// Per-unit seasonal increment.
  final int seasonalIncrement;
  /// Per-unit item discount.
  final int itemDiscount;
  /// This line's share of the invoice overall discount.
  final int allocatedOverallDiscount;
  /// Line net before overall discount:
  /// qty × (unitPrice + seasonalIncrement − itemDiscount).
  final int lineSubtotal;
  /// Final line total after allocated overall discount.
  final int lineTotal;
  final String uom;

  const ZamindarProductLedgerEntry({
    required this.invoiceNumber,
    required this.dateTime,
    required this.kisaanName,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    this.seasonalIncrement = 0,
    this.itemDiscount = 0,
    this.allocatedOverallDiscount = 0,
    int? lineSubtotal,
    required this.lineTotal,
    required this.uom,
  }) : lineSubtotal = lineSubtotal ?? lineTotal;

  int get effectiveUnitPrice => unitPrice + seasonalIncrement - itemDiscount;
  int get totalSeasonalIncrement => seasonalIncrement * quantity;
  int get totalItemDiscount => itemDiscount * quantity;
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

class DashboardReceivableRow {
  final int? zamindarId;
  final String name;
  final String? phone;
  final DateTime? lastTransactionAt;
  final double outstandingBalance;

  const DashboardReceivableRow({
    this.zamindarId,
    required this.name,
    this.phone,
    this.lastTransactionAt,
    required this.outstandingBalance,
  });
}

class DashboardPayableRow {
  final int? wholesalerId;
  final String name;
  final String? contact;
  final double pendingAmount;

  const DashboardPayableRow({
    this.wholesalerId,
    required this.name,
    this.contact,
    required this.pendingAmount,
  });
}

class CashInHandBreakdown {
  final double openingBalance;
  final double cashSalesReceived;
  final double zamindarCashRecoveries;
  final double expensesPaid;
  final double wholesalerCashPayments;
  final double partnerDrawingsTaken;
  final double partnerDrawingsReturned;
  final double netCashInHand;

  const CashInHandBreakdown({
    required this.openingBalance,
    required this.cashSalesReceived,
    required this.zamindarCashRecoveries,
    required this.expensesPaid,
    required this.wholesalerCashPayments,
    required this.partnerDrawingsTaken,
    required this.partnerDrawingsReturned,
    required this.netCashInHand,
  });

  /// Net partner cash leaving the drawer (taken − returned).
  double get partnerDrawingsNet =>
      partnerDrawingsTaken - partnerDrawingsReturned;

  factory CashInHandBreakdown.empty() => const CashInHandBreakdown(
        openingBalance: 0,
        cashSalesReceived: 0,
        zamindarCashRecoveries: 0,
        expensesPaid: 0,
        wholesalerCashPayments: 0,
        partnerDrawingsTaken: 0,
        partnerDrawingsReturned: 0,
        netCashInHand: 0,
      );
}

class ProductProfitRow {
  final String productName;
  final double revenue;
  final double cogs;
  final double margin;

  const ProductProfitRow({
    required this.productName,
    required this.revenue,
    required this.cogs,
    required this.margin,
  });
}

class ProfitAndLossBreakdown {
  final String season;
  final double grossSalesRevenue;
  final double seasonalIncrements;
  final double totalDiscounts;
  final double cogs;
  final double shopExpenses;
  final double netProfit;
  final double totalRevenue;
  final double cashSales;
  final double creditSales;
  final List<ProductProfitRow> topProducts;

  const ProfitAndLossBreakdown({
    required this.season,
    required this.grossSalesRevenue,
    required this.seasonalIncrements,
    required this.totalDiscounts,
    required this.cogs,
    required this.shopExpenses,
    required this.netProfit,
    required this.totalRevenue,
    required this.cashSales,
    required this.creditSales,
    required this.topProducts,
  });

  double get profitMargin =>
      totalRevenue > 0 ? (netProfit / totalRevenue) * 100.0 : 0.0;

  factory ProfitAndLossBreakdown.empty() => const ProfitAndLossBreakdown(
        season: '',
        grossSalesRevenue: 0,
        seasonalIncrements: 0,
        totalDiscounts: 0,
        cogs: 0,
        shopExpenses: 0,
        netProfit: 0,
        totalRevenue: 0,
        cashSales: 0,
        creditSales: 0,
        topProducts: <ProductProfitRow>[],
      );
}

class PurchaseCategoryAmount {
  final String category;
  final double amount;

  const PurchaseCategoryAmount({
    required this.category,
    required this.amount,
  });
}

class PurchasesBreakdown {
  final String season;
  final double totalPurchases;
  final double cashPurchases;
  final double creditPurchases;
  final List<PurchaseCategoryAmount> byCategory;

  const PurchasesBreakdown({
    required this.season,
    required this.totalPurchases,
    required this.cashPurchases,
    required this.creditPurchases,
    required this.byCategory,
  });

  factory PurchasesBreakdown.empty() => const PurchasesBreakdown(
        season: '',
        totalPurchases: 0,
        cashPurchases: 0,
        creditPurchases: 0,
        byCategory: <PurchaseCategoryAmount>[],
      );
}

class PendingAdvanceRow {
  final String invoiceNumber;
  final int? zamindarId;
  final String zamindarName;
  final String transactionType;
  final double amount;
  final DateTime dateIssued;

  const PendingAdvanceRow({
    required this.invoiceNumber,
    this.zamindarId,
    required this.zamindarName,
    required this.transactionType,
    required this.amount,
    required this.dateIssued,
  });

  bool get isFuel => SaleTransactionType.isFuelAdvance(transactionType);
  String get typeLabel => isFuel ? 'Fuel' : 'Cash';
}

class PendingAdvancesReminder {
  final double totalActiveCashAdvances;
  final double totalActiveFuelSlips;
  final int zamindarCountWithPending;
  final List<PendingAdvanceRow> recentPending;

  const PendingAdvancesReminder({
    required this.totalActiveCashAdvances,
    required this.totalActiveFuelSlips,
    required this.zamindarCountWithPending,
    required this.recentPending,
  });

  factory PendingAdvancesReminder.empty() => const PendingAdvancesReminder(
        totalActiveCashAdvances: 0,
        totalActiveFuelSlips: 0,
        zamindarCountWithPending: 0,
        recentPending: <PendingAdvanceRow>[],
      );

  bool get hasPending =>
      totalActiveCashAdvances > 0.005 ||
      totalActiveFuelSlips > 0.005 ||
      recentPending.isNotEmpty;
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
  /// Base unit price (excludes seasonal increment).
  final double unitPrice;
  /// Per-unit seasonal increment (After Harvest credit sales).
  final double seasonalIncrement;
  /// Per-unit discount.
  final double discount;

  const SaleLineItem({
    this.productId,
    required this.productName,
    required this.qty,
    required this.unitPrice,
    this.seasonalIncrement = 0,
    this.discount = 0,
  });

  double get effectiveUnitPrice => unitPrice + seasonalIncrement - discount;
  double get lineSubtotal => qty * effectiveUnitPrice;
  double get totalItemDiscount => qty * discount;
  double get totalItemSeasonalInc => qty * seasonalIncrement;
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
  final String address;
  final double balance;
  final bool isActive;

  const DbWholesaler({
    this.id,
    required this.name,
    required this.city,
    required this.phone,
    this.address = '',
    this.balance = 0,
    this.isActive = true,
  });

  Map<String, Object?> toMap() => {
    WholesalerTable.nameColumn: name,
    WholesalerTable.city: city,
    WholesalerTable.phone: phone,
    WholesalerTable.address: address.trim().isEmpty ? null : address.trim(),
    WholesalerTable.balance: balance,
    WholesalerTable.isActive: isActive ? 1 : 0,
  };

  factory DbWholesaler.fromMap(Map<String, Object?> map) {
    return DbWholesaler(
      id: map[WholesalerTable.id] as int?,
      name: map[WholesalerTable.nameColumn] as String,
      city: map[WholesalerTable.city] as String? ?? '',
      phone: map[WholesalerTable.phone] as String? ?? '',
      address: map[WholesalerTable.address] as String? ?? '',
      balance: (map[WholesalerTable.balance] as num?)?.toDouble() ?? 0,
      isActive: (map[WholesalerTable.isActive] as int?) != 0,
    );
  }

  DbWholesaler copyWith({
    int? id,
    String? name,
    String? city,
    String? phone,
    String? address,
    double? balance,
    bool? isActive,
  }) {
    return DbWholesaler(
      id: id ?? this.id,
      name: name ?? this.name,
      city: city ?? this.city,
      phone: phone ?? this.phone,
      address: address ?? this.address,
      balance: balance ?? this.balance,
      isActive: isActive ?? this.isActive,
    );
  }
}

/// Shop operating expense with permanent actor footprint.
typedef ExpenseModel = DbExpense;

class DbExpense {
  final int? id;
  final String category;
  final double amount;
  final String remarks;
  final DateTime expenseDate;
  final int? employeeId;
  final String? payrollType;

  /// Permanent actor snapshot at insert time (never look up live users).
  final String createdByUserId;
  final String createdByUserName;
  final DateTime createdAt;

  const DbExpense({
    this.id,
    required this.category,
    required this.amount,
    required this.remarks,
    required this.expenseDate,
    this.employeeId,
    this.payrollType,
    this.createdByUserId = '',
    this.createdByUserName = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? expenseDate;

  Map<String, Object?> toMap() => {
    ExpenseTable.category: category,
    ExpenseTable.amount: amount,
    ExpenseTable.remarks: remarks,
    ExpenseTable.expenseDate: DatabaseHelper._formatDateTime(expenseDate),
    ExpenseTable.employeeId: employeeId,
    ExpenseTable.payrollType: payrollType,
    ActorColumns.createdByUserId: createdByUserId,
    ActorColumns.createdByUserName: createdByUserName,
    ActorColumns.createdAt: DatabaseHelper._formatDateTime(createdAt),
  };

  factory DbExpense.fromMap(Map<String, Object?> map) {
    final rawDate = map[ExpenseTable.expenseDate] as String? ?? '';
    final expenseDate = DateTime.tryParse(rawDate) ?? DateTime.now();
    final rawCreated = map[ActorColumns.createdAt] as String?;
    return DbExpense(
      id: map[ExpenseTable.id] as int?,
      category: map[ExpenseTable.category] as String? ?? '',
      amount: (map[ExpenseTable.amount] as num?)?.toDouble() ?? 0,
      remarks: map[ExpenseTable.remarks] as String? ?? '',
      expenseDate: expenseDate,
      employeeId: map[ExpenseTable.employeeId] as int?,
      payrollType: map[ExpenseTable.payrollType] as String?,
      createdByUserId:
          map[ActorColumns.createdByUserId]?.toString() ?? '',
      createdByUserName:
          map[ActorColumns.createdByUserName] as String? ?? '',
      createdAt: DateTime.tryParse(rawCreated ?? '') ?? expenseDate,
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
  final String? createdByUserName;

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
    this.createdByUserName,
  });

  bool get isStockIn => movementType == StockMovementType.stockIn;

  String get quantityLabel {
    final sign = isStockIn ? '+' : '-';
    return '$sign$quantity $uom';
  }

  String get typeLabel => isStockIn ? 'STOCK IN' : 'STOCK OUT';
}
