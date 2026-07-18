import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../utils/season_utils.dart';

/// Singleton database helper for the AgriKhata local relational database.
///
/// This file contains:
/// - a strongly typed schema definition via model classes and column constants
/// - table creation scripts
/// - CRUD helpers for all four tables
/// - business helpers for zamindar balances and product inventory status
/// - ChangeNotifier mixin for reactive UI updates
class DatabaseHelper with ChangeNotifier {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

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
        version: 25,
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
          await _createIndexes(db);
        },
        onOpen: (db) async {
          // Reinforce FK enforcement on every connection (Desktop FFI).
          await db.execute('PRAGMA foreign_keys = ON');
          await _ensureWholesalerLedgerSchema(db);
          await _ensureWholesalerPaymentsSchema(db);
          await _ensureExpensesSchema(db);
          await _ensureSalesAdvanceSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 3) {
            try {
              await db.execute(
                'ALTER TABLE ${ZamindarTable.name} ADD COLUMN ${ZamindarTable.village} TEXT',
              );
            } catch (e) {
              debugPrint(
                'Column ${ZamindarTable.village} might already exist: $e',
              );
            }
            try {
              await db.execute(
                'ALTER TABLE ${ZamindarTable.name} ADD COLUMN ${ZamindarTable.isDraft} INTEGER DEFAULT 0',
              );
            } catch (e) {
              debugPrint(
                'Column ${ZamindarTable.isDraft} might already exist: $e',
              );
            }
          }
          if (oldVersion < 4) {
            debugPrint('Migrating to version 4: Fixing kisaans table schema');
            try {
              await db.execute('DROP TABLE IF EXISTS ${KisaanTable.name}');
              await db.execute(_createKisaansTable());
              await db.execute('''
              CREATE INDEX IF NOT EXISTS idx_kisaans_zamindar_id
              ON kisaans(zamindar_id)
            ''');
              debugPrint('Kisaans table recreated successfully');
            } catch (e) {
              debugPrint('Error recreating kisaans table: $e');
            }
          }
          if (oldVersion < 5) {
            debugPrint(
              'Migrating to version 5: Adding seasonal_increment to products',
            );
            try {
              await db.execute(
                'ALTER TABLE ${ProductTable.name} ADD COLUMN ${ProductTable.seasonalIncrement} INTEGER DEFAULT 0',
              );
              debugPrint('Seasonal increment column added successfully');
            } catch (e) {
              debugPrint(
                'Column ${ProductTable.seasonalIncrement} might already exist: $e',
              );
            }
          }
          if (oldVersion < 6) {
            debugPrint('Migrating to version 6: Fixing products table schema');
            try {
              await db.execute('DROP TABLE IF EXISTS ${ProductTable.name}');
              await db.execute(_createProductsTable());
              debugPrint(
                'Products table recreated successfully with correct column names',
              );
            } catch (e) {
              debugPrint('Error recreating products table: $e');
            }
          }
          if (oldVersion < 7) {
            debugPrint(
              'Migrating to version 7: Adding product_type to products',
            );
            try {
              await db.execute(
                'ALTER TABLE ${ProductTable.name} ADD COLUMN ${ProductTable.productType} TEXT DEFAULT \'Fertilizer\'',
              );
              debugPrint('Product type column added successfully');
            } catch (e) {
              debugPrint(
                'Column ${ProductTable.productType} might already exist: $e',
              );
            }
          }
          if (oldVersion < 8) {
            debugPrint(
              'Migrating to version 8: Adding advance_balance to zamindars',
            );
            try {
              await db.execute(
                'ALTER TABLE ${ZamindarTable.name} ADD COLUMN ${ZamindarTable.advanceBalance} INTEGER DEFAULT 0',
              );
              debugPrint('Advance balance column added successfully');
            } catch (e) {
              debugPrint(
                'Column ${ZamindarTable.advanceBalance} might already exist: $e',
              );
            }
          }
          if (oldVersion < 9) {
            debugPrint(
              'Migrating to version 9: Creating three-table relational schema',
            );
            try {
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
              debugPrint('Three-table schema created successfully');
            } catch (e) {
              debugPrint('Error creating three-table schema: $e');
            }
          }
          if (oldVersion < 10) {
            debugPrint(
              'Migrating to version 10: Fixing sales table schema with season column',
            );
            try {
              // Drop incomplete version 9 tables and recreate with correct schema
              await db.execute('DROP TABLE IF EXISTS ${PaymentsTable.name}');
              await db.execute('DROP TABLE IF EXISTS ${SaleItemsTable.name}');
              await db.execute('DROP TABLE IF EXISTS ${SalesTable.name}');

              // Recreate with corrected schema including season column
              await db.execute(_createSalesTable());
              await db.execute(_createSaleItemsTable());
              await db.execute(_createPaymentsTable());

              // Recreate indexes
              await db.execute('''
                CREATE INDEX IF NOT EXISTS idx_sale_items_invoice
                ON sale_items(invoice_number)
              ''');
              await db.execute('''
                CREATE INDEX IF NOT EXISTS idx_payments_invoice
                ON payments(invoice_number)
              ''');

              debugPrint(
                'Version 10 migration completed: Sales table now includes season column',
              );
            } catch (e) {
              debugPrint('Error migrating to version 10: $e');
            }
          }
          if (oldVersion < 11) {
            debugPrint(
              'Migrating to version 11: Adding audit trail linkage columns to ledger_transactions',
            );
            try {
              // Add invoice_number column for linking DEBITs to sales invoices
              await db.execute(
                'ALTER TABLE ${LedgerTransactionTable.name} ADD COLUMN ${LedgerTransactionTable.invoiceNumber} TEXT',
              );
              debugPrint('Added invoice_number column to ledger_transactions');

              // Add payment_id column for linking CREDITs to payment records
              await db.execute(
                'ALTER TABLE ${LedgerTransactionTable.name} ADD COLUMN ${LedgerTransactionTable.paymentId} TEXT',
              );
              debugPrint('Added payment_id column to ledger_transactions');

              debugPrint(
                'Version 11 migration completed: Audit trail linkage columns added successfully',
              );
            } catch (e) {
              debugPrint('Error migrating to version 11: $e');
            }
          }
          if (oldVersion < 12) {
            debugPrint(
              'Migrating to version 12: Backfilling ledger_transactions from sales',
            );
            try {
              await _backfillLedgerFromSales(db);
              debugPrint('Version 12 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 12: $e');
            }
          }
          if (oldVersion < 13) {
            debugPrint(
              'Migrating to version 13: Nullable payment invoice + advance backfill',
            );
            try {
              await _migratePaymentsTableNullableInvoice(db);
              await _backfillAdvancePayments(db);
              debugPrint('Version 13 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 13: $e');
            }
          }
          if (oldVersion < 14) {
            debugPrint(
              'Migrating to version 14: Payment sequences + ghost payment cleanup',
            );
            try {
              await db.execute(_createPaymentSequencesTable());
              await _seedPaymentSequences(db);
              await _cleanupGhostAdvancePayments(db);
              await db.update(
                LedgerTransactionTable.name,
                {LedgerTransactionTable.category: 'WALLET_DEDUCTION'},
                where:
                    '${LedgerTransactionTable.category} = ? AND ${LedgerTransactionTable.description} = ?',
                whereArgs: ['ADVANCE_PAYMENT', 'Advance wallet deduction'],
              );
              debugPrint('Version 14 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 14: $e');
            }
          }
          if (oldVersion < 15) {
            debugPrint(
              'Migrating to version 15: Renumber legacy payment receipt IDs',
            );
            try {
              await db.execute(_createPaymentSequencesTable());
              await _renumberLegacyPaymentIds(db);
              debugPrint('Version 15 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 15: $e');
            }
          }
          if (oldVersion < 16) {
            debugPrint(
              'Migrating to version 16: Sales payment_term + multi payment terms',
            );
            try {
              await db.execute(
                'ALTER TABLE ${SalesTable.name} ADD COLUMN ${SalesTable.paymentTerm} TEXT',
              );
              debugPrint('Added payment_term column to sales');
              debugPrint('Version 16 migration completed');
            } catch (e) {
              debugPrint(
                'Column ${SalesTable.paymentTerm} might already exist: $e',
              );
            }
          }
          if (oldVersion < 17) {
            debugPrint(
              'Migrating to version 17: Creating stock_movements ledger',
            );
            try {
              await db.execute(_createStockMovementsTable());
              await db.execute('''
                CREATE INDEX IF NOT EXISTS idx_stock_movements_product
                ON ${StockMovementTable.name}(${StockMovementTable.productId})
              ''');
              await _backfillStockMovementsFromSales(db);
              debugPrint('Version 17 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 17: $e');
            }
          }
          if (oldVersion < 18) {
            debugPrint(
              'Migrating to version 18: Wholesalers + Purchase invoices',
            );
            try {
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
              debugPrint('Version 18 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 18: $e');
            }
          }
          if (oldVersion < 19) {
            debugPrint('Migrating to version 19: wholesaler_ledger');
            try {
              await db.execute(_createWholesalerLedgerTable());
              await db.execute('''
                CREATE INDEX IF NOT EXISTS idx_wholesaler_ledger_wholesaler
                ON ${WholesalerLedgerTable.name}(${WholesalerLedgerTable.wholesalerId})
              ''');
              debugPrint('Version 19 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 19: $e');
            }
          }
          if (oldVersion < 20) {
            debugPrint(
              'Migrating to version 20: backfill wholesaler_ledger from purchases',
            );
            try {
              await _ensureWholesalerLedgerSchema(db);
              debugPrint('Version 20 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 20: $e');
            }
          }
          if (oldVersion < 21) {
            debugPrint('Migrating to version 21: wholesaler_payments');
            try {
              await _ensureWholesalerPaymentsSchema(db);
              debugPrint('Version 21 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 21: $e');
            }
          }
          if (oldVersion < 22) {
            debugPrint(
              'Migrating to version 22: purchase + wholesaler ledger description',
            );
            try {
              await db.execute(
                'ALTER TABLE ${PurchaseInvoicesTable.name} '
                'ADD COLUMN ${PurchaseInvoicesTable.description} TEXT',
              );
            } catch (e) {
              debugPrint(
                'Column ${PurchaseInvoicesTable.description} might already exist: $e',
              );
            }
            try {
              await db.execute(
                'ALTER TABLE ${WholesalerLedgerTable.name} '
                'ADD COLUMN ${WholesalerLedgerTable.description} TEXT',
              );
            } catch (e) {
              debugPrint(
                'Column ${WholesalerLedgerTable.description} might already exist: $e',
              );
            }
            debugPrint('Version 22 migration completed');
          }
          if (oldVersion < 23) {
            debugPrint('Migrating to version 23: Creating expenses table');
            try {
              await _ensureExpensesSchema(db);
              debugPrint('Version 23 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 23: $e');
            }
          }
          if (oldVersion < 24) {
            debugPrint(
              'Migrating to version 24: Cascade invoice FKs + current_balance sync',
            );
            try {
              await _migrateInvoiceIntegrityV24(db);
              debugPrint('Version 24 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 24: $e');
              rethrow;
            }
          }
          if (oldVersion < 25) {
            debugPrint(
              'Migrating to version 25: Cash/Fuel advance columns on sales',
            );
            try {
              await _ensureSalesAdvanceSchema(db);
              debugPrint('Version 25 migration completed');
            } catch (e) {
              debugPrint('Error migrating to version 25: $e');
              rethrow;
            }
          }
        },
      ),
    );
  }

  /// v24: cascade ledger/payments on invoice delete, add cached current_balance,
  /// purge orphaned ledger rows, and recalculate every zamindar balance.
  Future<void> _migrateInvoiceIntegrityV24(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE ${ZamindarTable.name} '
        'ADD COLUMN ${ZamindarTable.currentBalance} INTEGER NOT NULL DEFAULT 0',
      );
    } catch (e) {
      debugPrint(
        'Column ${ZamindarTable.currentBalance} might already exist: $e',
      );
    }

    await _rebuildLedgerTransactionsWithInvoiceCascade(db);
    await _rebuildPaymentsWithInvoiceCascade(db);

    // Orphan SALE/payment ledger rows left behind by the old ON DELETE SET NULL.
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

    await _backfillLedgerFromSales(db);
    await _recalculateAllZamindarBalances(db);
  }

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

  Future<void> _rebuildLedgerTransactionsWithInvoiceCascade(Database db) async {
    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.execute('DROP TABLE IF EXISTS ledger_transactions_new');
      await db.execute('''
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
      ''');

      await db.execute('''
        INSERT INTO ledger_transactions_new (
          ${LedgerTransactionTable.id},
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
          ${LedgerTransactionTable.id},
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
        FROM ${LedgerTransactionTable.name}
      ''');

      await db.execute('DROP TABLE ${LedgerTransactionTable.name}');
      await db.execute(
        'ALTER TABLE ledger_transactions_new RENAME TO ${LedgerTransactionTable.name}',
      );
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_ledger_zamindar_id
        ON ${LedgerTransactionTable.name}(${LedgerTransactionTable.zamindarId})
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_ledger_kisaan_id
        ON ${LedgerTransactionTable.name}(${LedgerTransactionTable.kisaanId})
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_ledger_invoice_number
        ON ${LedgerTransactionTable.name}(${LedgerTransactionTable.invoiceNumber})
      ''');
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }
  }

  Future<void> _rebuildPaymentsWithInvoiceCascade(Database db) async {
    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.execute('DROP TABLE IF EXISTS payments_new');
      await db.execute('''
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
      ''');

      await db.execute('''
        INSERT INTO payments_new (
          ${PaymentsTable.paymentId},
          ${PaymentsTable.invoiceNumber},
          ${PaymentsTable.dateTime},
          ${PaymentsTable.zamindarName},
          ${PaymentsTable.kisaanName},
          ${PaymentsTable.amountPaid},
          ${PaymentsTable.paymentMethod},
          ${PaymentsTable.season}
        )
        SELECT
          ${PaymentsTable.paymentId},
          ${PaymentsTable.invoiceNumber},
          ${PaymentsTable.dateTime},
          ${PaymentsTable.zamindarName},
          ${PaymentsTable.kisaanName},
          ${PaymentsTable.amountPaid},
          ${PaymentsTable.paymentMethod},
          ${PaymentsTable.season}
        FROM ${PaymentsTable.name}
      ''');

      await db.execute('DROP TABLE ${PaymentsTable.name}');
      await db.execute(
        'ALTER TABLE payments_new RENAME TO ${PaymentsTable.name}',
      );
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_payments_invoice
        ON ${PaymentsTable.name}(${PaymentsTable.invoiceNumber})
      ''');
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }
  }

  /// Creates expenses table + date index if missing.
  Future<void> _ensureExpensesSchema(Database db) async {
    await db.execute(_createExpensesTable());
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_expenses_expense_date
      ON ${ExpenseTable.name}(${ExpenseTable.expenseDate})
    ''');
  }

  /// Adds Cash/Fuel Advance columns on [SalesTable] (idempotent).
  Future<void> _ensureSalesAdvanceSchema(Database db) async {
    Future<void> addColumn(String sql, String columnLabel) async {
      try {
        await db.execute(sql);
        debugPrint('Added $columnLabel to ${SalesTable.name}');
      } catch (e) {
        debugPrint('Column $columnLabel might already exist: $e');
      }
    }

    await addColumn(
      'ALTER TABLE ${SalesTable.name} '
      'ADD COLUMN ${SalesTable.transactionType} TEXT NOT NULL '
      "DEFAULT '${SaleTransactionType.productSale}'",
      SalesTable.transactionType,
    );
    await addColumn(
      'ALTER TABLE ${SalesTable.name} '
      'ADD COLUMN ${SalesTable.creditAmount} REAL NOT NULL DEFAULT 0',
      SalesTable.creditAmount,
    );
    await addColumn(
      'ALTER TABLE ${SalesTable.name} '
      'ADD COLUMN ${SalesTable.fuelQuantity} REAL',
      SalesTable.fuelQuantity,
    );
    await addColumn(
      'ALTER TABLE ${SalesTable.name} '
      'ADD COLUMN ${SalesTable.remarks} TEXT',
      SalesTable.remarks,
    );
    await addColumn(
      'ALTER TABLE ${SalesTable.name} '
      'ADD COLUMN ${SalesTable.zamindarId} INTEGER',
      SalesTable.zamindarId,
    );
    await addColumn(
      'ALTER TABLE ${SalesTable.name} '
      'ADD COLUMN ${SalesTable.kisaanId} INTEGER',
      SalesTable.kisaanId,
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

      // Reconstruct running balance snapshot from current vendor balance
      // (best-effort for historical rows).
      final balRows = await db.query(
        WholesalerTable.name,
        columns: [WholesalerTable.balance],
        where: '${WholesalerTable.id} = ?',
        whereArgs: [wholesalerId],
        limit: 1,
      );
      final currentBal = balRows.isEmpty
          ? outstanding
          : (balRows.first[WholesalerTable.balance] as num?)?.toDouble() ??
                outstanding;

      await db.insert(WholesalerLedgerTable.name, {
        WholesalerLedgerTable.wholesalerId: wholesalerId,
        WholesalerLedgerTable.transactionType: WholesalerLedgerTxnType.purchase,
        WholesalerLedgerTable.referenceId: invoiceNumber,
        WholesalerLedgerTable.date: dateRaw,
        WholesalerLedgerTable.debit: grandTotal > 0 ? grandTotal : outstanding,
        WholesalerLedgerTable.credit: 0,
        WholesalerLedgerTable.runningBalance: currentBal,
      });

      if (paid > 0) {
        await db.insert(WholesalerLedgerTable.name, {
          WholesalerLedgerTable.wholesalerId: wholesalerId,
          WholesalerLedgerTable.transactionType:
              WholesalerLedgerTxnType.payment,
          WholesalerLedgerTable.referenceId: '$invoiceNumber-PAID',
          WholesalerLedgerTable.date: dateRaw,
          WholesalerLedgerTable.debit: 0,
          WholesalerLedgerTable.credit: paid,
          WholesalerLedgerTable.runningBalance: currentBal,
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
    final salesMaps = await db.query(SalesTable.name);
    for (final sale in salesMaps) {
      final invoiceNumber = sale[SalesTable.invoiceNumber] as String;
      final existing = await db.query(
        LedgerTransactionTable.name,
        where:
            '${LedgerTransactionTable.invoiceNumber} = ? AND ${LedgerTransactionTable.category} = ?',
        whereArgs: [invoiceNumber, 'SALE'],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;

      final zamindarName = sale[SalesTable.zamindarName] as String;
      final kisaanName = sale[SalesTable.kisaanName] as String?;
      final paidAmount =
          (sale[SalesTable.paidAmount] as num?)?.toDouble() ?? 0.0;
      final paymentMethod = sale[SalesTable.paymentMethod] as String;
      final season = sale[SalesTable.season] as String;
      final dateTimeStr = sale[SalesTable.dateTime] as String;
      final totalPayable =
          (sale[SalesTable.totalPayable] as num?)?.toDouble() ?? 0.0;

      final itemsMaps = await db.query(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      final description = itemsMaps
          .map(
            (item) =>
                '${item[SaleItemsTable.productName]} x${item[SaleItemsTable.quantity]}',
          )
          .join(' · ');

      await db.transaction((txn) async {
        await _insertLedgerEntriesForSale(
          txn,
          invoiceNumber: invoiceNumber,
          zamindarName: zamindarName,
          kisaanName: kisaanName,
          description: description.isEmpty
              ? 'Sale $invoiceNumber'
              : description,
          totalPayable: totalPayable,
          paidAmount: paidAmount,
          paymentMethod: paymentMethod,
          season: season,
          dateTime: _parseDateTime(dateTimeStr),
        );
      });
    }
  }

  Future<void> _insertLedgerEntriesForSale(
    DatabaseExecutor txn, {
    required String invoiceNumber,
    required String zamindarName,
    String? kisaanName,
    required String description,
    required double totalPayable,
    required double paidAmount,
    required String paymentMethod,
    required String season,
    required DateTime dateTime,
    double advanceDrawdown = 0,
    String? walletPaymentId,
    String? cashPaymentId,
  }) async {
    final zamindarRows = await txn.query(
      ZamindarTable.name,
      columns: [ZamindarTable.id],
      where: '${ZamindarTable.nameColumn} = ?',
      whereArgs: [zamindarName],
      limit: 1,
    );
    if (zamindarRows.isEmpty) return;

    final zamindarId = zamindarRows.first[ZamindarTable.id] as int;
    int? kisaanId;
    if (kisaanName != null && kisaanName.isNotEmpty) {
      final kisaanRows = await txn.query(
        KisaanTable.name,
        columns: [KisaanTable.id],
        where:
            '${KisaanTable.zamindarId} = ? AND ${KisaanTable.nameColumn} = ?',
        whereArgs: [zamindarId, kisaanName],
        limit: 1,
      );
      if (kisaanRows.isNotEmpty) {
        kisaanId = kisaanRows.first[KisaanTable.id] as int;
      }
    }

    final netAmount = totalPayable.round();
    await txn.insert(LedgerTransactionTable.name, {
      LedgerTransactionTable.zamindarId: zamindarId,
      LedgerTransactionTable.kisaanId: kisaanId,
      LedgerTransactionTable.invoiceNumber: invoiceNumber,
      LedgerTransactionTable.type: LedgerTransactionType.debit,
      LedgerTransactionTable.category: 'SALE',
      LedgerTransactionTable.description: description,
      LedgerTransactionTable.amount: netAmount,
      LedgerTransactionTable.dateTime: _formatDateTime(dateTime),
      LedgerTransactionTable.season: season,
    });

    if (advanceDrawdown > 0) {
      await txn.insert(LedgerTransactionTable.name, {
        LedgerTransactionTable.zamindarId: zamindarId,
        LedgerTransactionTable.kisaanId: kisaanId,
        LedgerTransactionTable.invoiceNumber: invoiceNumber,
        LedgerTransactionTable.paymentId: walletPaymentId,
        LedgerTransactionTable.type: LedgerTransactionType.credit,
        LedgerTransactionTable.category: 'WALLET_DEDUCTION',
        LedgerTransactionTable.description: 'Advance wallet deduction',
        LedgerTransactionTable.amount: advanceDrawdown.round(),
        LedgerTransactionTable.dateTime: _formatDateTime(dateTime),
        LedgerTransactionTable.season: season,
      });
    }

    if (paidAmount > 0) {
      await txn.insert(LedgerTransactionTable.name, {
        LedgerTransactionTable.zamindarId: zamindarId,
        LedgerTransactionTable.kisaanId: kisaanId,
        LedgerTransactionTable.invoiceNumber: invoiceNumber,
        LedgerTransactionTable.paymentId: cashPaymentId,
        LedgerTransactionTable.type: LedgerTransactionType.credit,
        LedgerTransactionTable.category: paymentMethod == 'Cash'
            ? 'CASH_PAYMENT'
            : 'PAYMENT',
        LedgerTransactionTable.description: paymentMethod == 'Cash'
            ? 'Cash payment for sale'
            : 'Payment for $invoiceNumber',
        LedgerTransactionTable.amount: paidAmount.round(),
        LedgerTransactionTable.dateTime: _formatDateTime(dateTime),
        LedgerTransactionTable.season: season,
      });
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
        ON DELETE SET NULL
    )
  ''';

  String _createSalesTable() =>
      '''
    CREATE TABLE IF NOT EXISTS ${SalesTable.name} (
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
      ${SalesTable.season} TEXT NOT NULL,
      ${SalesTable.paymentTerm} TEXT,
      ${SalesTable.transactionType} TEXT NOT NULL
        DEFAULT '${SaleTransactionType.productSale}',
      ${SalesTable.creditAmount} REAL NOT NULL DEFAULT 0,
      ${SalesTable.fuelQuantity} REAL,
      ${SalesTable.remarks} TEXT,
      ${SalesTable.zamindarId} INTEGER,
      ${SalesTable.kisaanId} INTEGER
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
      ${SaleItemsTable.unitPrice} REAL NOT NULL,
      ${SaleItemsTable.seasonalIncrement} REAL NOT NULL DEFAULT 0,
      ${SaleItemsTable.itemDiscount} REAL NOT NULL DEFAULT 0,
      ${SaleItemsTable.subtotal} REAL NOT NULL,
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
      ${PaymentsTable.zamindarName} TEXT NOT NULL,
      ${PaymentsTable.kisaanName} TEXT,
      ${PaymentsTable.amountPaid} REAL NOT NULL,
      ${PaymentsTable.paymentMethod} TEXT NOT NULL,
      ${PaymentsTable.season} TEXT NOT NULL,
      FOREIGN KEY (${PaymentsTable.invoiceNumber}) REFERENCES ${SalesTable.name}(${SalesTable.invoiceNumber})
        ON UPDATE CASCADE ON DELETE CASCADE
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
      ${PurchaseInvoicesTable.wholesalerName} TEXT NOT NULL,
      ${PurchaseInvoicesTable.dateTime} TEXT NOT NULL,
      ${PurchaseInvoicesTable.subtotal} REAL NOT NULL,
      ${PurchaseInvoicesTable.transportCharges} REAL NOT NULL DEFAULT 0,
      ${PurchaseInvoicesTable.grandTotal} REAL NOT NULL,
      ${PurchaseInvoicesTable.paymentType} TEXT NOT NULL,
      ${PurchaseInvoicesTable.amountPaid} REAL NOT NULL DEFAULT 0,
      ${PurchaseInvoicesTable.outstanding} REAL NOT NULL DEFAULT 0,
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
      ${PurchaseItemsTable.purchaseRate} REAL NOT NULL,
      ${PurchaseItemsTable.expiryDate} TEXT,
      ${PurchaseItemsTable.lineTotal} REAL NOT NULL,
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
      ${WholesalerLedgerTable.debit} REAL NOT NULL DEFAULT 0,
      ${WholesalerLedgerTable.credit} REAL NOT NULL DEFAULT 0,
      ${WholesalerLedgerTable.runningBalance} REAL NOT NULL DEFAULT 0,
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
      ${WholesalerPaymentsTable.amount} REAL NOT NULL,
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
      ${ExpenseTable.expenseDate} TEXT NOT NULL
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
        s.${SalesTable.zamindarName} AS zamindar_name,
        s.${SalesTable.invoiceNumber} AS invoice_number,
        s.${SalesTable.dateTime} AS date_time,
        CASE
          WHEN z.${ZamindarTable.id} IS NULL THEN 'Walk-in Customer'
          ELSE s.${SalesTable.zamindarName}
        END AS party_label
      FROM ${SaleItemsTable.name} si
      INNER JOIN ${SalesTable.name} s
        ON s.${SalesTable.invoiceNumber} = si.${SaleItemsTable.invoiceNumber}
      INNER JOIN ${ProductTable.name} p
        ON p.${ProductTable.nameColumn} = si.${SaleItemsTable.productName}
      LEFT JOIN ${ZamindarTable.name} z
        ON z.${ZamindarTable.nameColumn} = s.${SalesTable.zamindarName}
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

  Future<void> _migratePaymentsTableNullableInvoice(Database db) async {
    final tableInfo = await db.rawQuery(
      'PRAGMA table_info(${PaymentsTable.name})',
    );
    final invoiceColumn = tableInfo.cast<Map<String, Object?>>().where(
      (col) => col['name'] == PaymentsTable.invoiceNumber,
    );
    if (invoiceColumn.isNotEmpty && invoiceColumn.first['notnull'] == 0) {
      return;
    }

    await db.execute('DROP TABLE IF EXISTS payments_new');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS payments_new (
        ${PaymentsTable.paymentId} TEXT PRIMARY KEY,
        ${PaymentsTable.invoiceNumber} TEXT,
        ${PaymentsTable.dateTime} TEXT NOT NULL,
        ${PaymentsTable.zamindarName} TEXT NOT NULL,
        ${PaymentsTable.kisaanName} TEXT,
        ${PaymentsTable.amountPaid} REAL NOT NULL,
        ${PaymentsTable.paymentMethod} TEXT NOT NULL,
        ${PaymentsTable.season} TEXT NOT NULL
      )
    ''');

    await db.execute('''
      INSERT INTO payments_new (
        ${PaymentsTable.paymentId},
        ${PaymentsTable.invoiceNumber},
        ${PaymentsTable.dateTime},
        ${PaymentsTable.zamindarName},
        ${PaymentsTable.kisaanName},
        ${PaymentsTable.amountPaid},
        ${PaymentsTable.paymentMethod},
        ${PaymentsTable.season}
      )
      SELECT
        ${PaymentsTable.paymentId},
        ${PaymentsTable.invoiceNumber},
        ${PaymentsTable.dateTime},
        ${PaymentsTable.zamindarName},
        ${PaymentsTable.kisaanName},
        ${PaymentsTable.amountPaid},
        ${PaymentsTable.paymentMethod},
        ${PaymentsTable.season}
      FROM ${PaymentsTable.name}
    ''');

    await db.execute('DROP TABLE ${PaymentsTable.name}');
    await db.execute(
      'ALTER TABLE payments_new RENAME TO ${PaymentsTable.name}',
    );
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_payments_invoice
      ON ${PaymentsTable.name}(${PaymentsTable.invoiceNumber})
    ''');
  }

  Future<void> _backfillAdvancePayments(Database db) async {
    final advanceRows = await db.query(
      LedgerTransactionTable.name,
      where:
          '${LedgerTransactionTable.category} = ? AND ${LedgerTransactionTable.description} = ? AND (${LedgerTransactionTable.paymentId} IS NULL OR ${LedgerTransactionTable.paymentId} = \'\')',
      whereArgs: ['ADVANCE_PAYMENT', 'Advance payment received'],
      orderBy: '${LedgerTransactionTable.dateTime} ASC',
    );

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

      final zamindarName =
          zamindarRows.first[ZamindarTable.nameColumn] as String;

      final paymentId = await generateNextPaymentId(db, isAdvance: true);
      final dateTime = row[LedgerTransactionTable.dateTime] as String;
      final amount = (row[LedgerTransactionTable.amount] as num).toDouble();
      final season = row[LedgerTransactionTable.season] as String;

      await db.insert(PaymentsTable.name, {
        PaymentsTable.paymentId: paymentId,
        PaymentsTable.invoiceNumber: null,
        PaymentsTable.dateTime: dateTime,
        PaymentsTable.zamindarName: zamindarName,
        PaymentsTable.kisaanName: null,
        PaymentsTable.amountPaid: amount,
        PaymentsTable.paymentMethod: 'Cash',
        PaymentsTable.season: season,
      });

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
      final zamindarName = zamindar.name;

      final invoiceRows = await txn.query(
        SalesTable.name,
        columns: [SalesTable.invoiceNumber],
        where: '${SalesTable.zamindarName} = ?',
        whereArgs: [zamindarName],
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
        where: '${SalesTable.zamindarName} = ?',
        whereArgs: [zamindarName],
      );
      await txn.delete(
        PaymentsTable.name,
        where: '${PaymentsTable.zamindarName} = ?',
        whereArgs: [zamindarName],
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
      where: '${SalesTable.kisaanName} = ? AND ${SalesTable.zamindarName} = ?',
      whereArgs: [kisaanName, zamindarName],
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
      where: '${SalesTable.kisaanName} = ? AND ${SalesTable.zamindarName} = ?',
      whereArgs: [kisaanName, zamindarName],
    );
    await txn.delete(
      PaymentsTable.name,
      where:
          '${PaymentsTable.kisaanName} = ? AND ${PaymentsTable.zamindarName} = ?',
      whereArgs: [kisaanName, zamindarName],
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
      WHERE s.${SalesTable.zamindarName} = ?
        AND s.${SalesTable.kisaanName} = ?
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
    final rows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(s.${SalesTable.totalPayable}), 0) AS total_sales,
        COALESCE(SUM($_sqlSaleCollectedExpr), 0) AS total_payments,
        COALESCE(SUM($_sqlSaleRemainingExpr), 0) AS outstanding
      FROM ${SalesTable.name} s
      WHERE s.${SalesTable.zamindarName} = ?
      ''',
      [zamindarName],
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
    final outstanding = totals['outstandingBalance']!;

    await db.update(
      ZamindarTable.name,
      {ZamindarTable.currentBalance: outstanding},
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
    );
    return outstanding;
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
        await txn.insert(WholesalerLedgerTable.name, {
          WholesalerLedgerTable.wholesalerId: id,
          WholesalerLedgerTable.transactionType:
              WholesalerLedgerTxnType.purchase,
          WholesalerLedgerTable.referenceId: 'OPENING',
          WholesalerLedgerTable.date: _formatDateTime(DateTime.now()),
          WholesalerLedgerTable.debit: wholesaler.balance,
          WholesalerLedgerTable.credit: 0,
          WholesalerLedgerTable.runningBalance: wholesaler.balance,
        });
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

  /// Khata statement rows for a wholesaler, newest first.
  Future<List<Map<String, dynamic>>> fetchWholesalerLedger(
    int wholesalerId,
  ) async {
    final db = await database;
    await _ensureWholesalerLedgerSchema(db);
    final rows = await db.rawQuery(
      'SELECT * FROM ${WholesalerLedgerTable.name} '
      'WHERE ${WholesalerLedgerTable.wholesalerId} = ? '
      'ORDER BY ${WholesalerLedgerTable.date} DESC, '
      '${WholesalerLedgerTable.id} DESC',
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
    required double runningBalance,
    String? description,
  }) async {
    await txn.insert(WholesalerLedgerTable.name, {
      WholesalerLedgerTable.wholesalerId: wholesalerId,
      WholesalerLedgerTable.transactionType: transactionType,
      WholesalerLedgerTable.referenceId: referenceId,
      WholesalerLedgerTable.date: _formatDateTime(date),
      WholesalerLedgerTable.debit: debit,
      WholesalerLedgerTable.credit: credit,
      WholesalerLedgerTable.runningBalance: runningBalance,
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
      WholesalerPaymentsTable.amount: amount,
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
        '(COALESCE(w.${WholesalerTable.nameColumn}, pi.${PurchaseInvoicesTable.wholesalerName}) LIKE ? '
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
        COALESCE(
          w.${WholesalerTable.nameColumn},
          pi.${PurchaseInvoicesTable.wholesalerName}
        ) AS wholesaler_name,
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

      await _insertWholesalerLedgerEntry(
        txn,
        wholesalerId: wholesalerId,
        transactionType: WholesalerLedgerTxnType.payment,
        referenceId: receiptNo,
        date: when,
        debit: 0,
        credit: amount,
        runningBalance: newBalance,
      );

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

  /// Atomically saves a purchase invoice:
  /// 1) insert header  2) insert line items  3) increment stock
  /// 4) increase wholesaler balance when Udhaar / Partial
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
      await txn.insert(PurchaseInvoicesTable.name, {
        PurchaseInvoicesTable.invoiceNumber: invoiceNumber,
        PurchaseInvoicesTable.wholesalerId: wholesalerId,
        PurchaseInvoicesTable.wholesalerName: wholesalerName,
        PurchaseInvoicesTable.dateTime: _formatDateTime(dateTime),
        PurchaseInvoicesTable.subtotal: subtotal,
        PurchaseInvoicesTable.transportCharges: transportCharges,
        PurchaseInvoicesTable.grandTotal: grandTotal,
        PurchaseInvoicesTable.paymentType: paymentType,
        PurchaseInvoicesTable.amountPaid: paid,
        PurchaseInvoicesTable.outstanding: outstanding,
        if (trimmedDescription.isNotEmpty)
          PurchaseInvoicesTable.description: trimmedDescription,
      });

      for (final item in items) {
        await txn.insert(PurchaseItemsTable.name, {
          PurchaseItemsTable.invoiceNumber: invoiceNumber,
          PurchaseItemsTable.productId: item.productId,
          PurchaseItemsTable.productName: item.productName,
          PurchaseItemsTable.quantity: item.quantity,
          PurchaseItemsTable.purchaseRate: item.purchaseRate,
          PurchaseItemsTable.expiryDate: item.expiryDate != null
              ? _formatDateOnly(item.expiryDate!)
              : null,
          PurchaseItemsTable.lineTotal: item.lineTotal,
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

      if (outstanding > 0 &&
          (paymentType == PurchasePaymentType.udhaar ||
              paymentType == PurchasePaymentType.partial)) {
        await txn.rawUpdate(
          'UPDATE ${WholesalerTable.name} '
          'SET ${WholesalerTable.balance} = ${WholesalerTable.balance} + ? '
          'WHERE ${WholesalerTable.id} = ?',
          [outstanding, wholesalerId],
        );
      }

      // Always write khata rows so purchases appear in Wholesaler ledger.
      final balRows = await txn.query(
        WholesalerTable.name,
        columns: [WholesalerTable.balance],
        where: '${WholesalerTable.id} = ?',
        whereArgs: [wholesalerId],
        limit: 1,
      );
      final runningBalance = balRows.isEmpty
          ? outstanding
          : (balRows.first[WholesalerTable.balance] as num?)?.toDouble() ??
                outstanding;

      await _insertWholesalerLedgerEntry(
        txn,
        wholesalerId: wholesalerId,
        transactionType: WholesalerLedgerTxnType.purchase,
        referenceId: invoiceNumber,
        date: dateTime,
        debit: grandTotal,
        credit: 0,
        runningBalance: runningBalance,
        description: trimmedDescription.isNotEmpty
            ? trimmedDescription
            : 'Purchase $invoiceNumber',
      );

      if (paid > 0) {
        await _insertWholesalerLedgerEntry(
          txn,
          wholesalerId: wholesalerId,
          transactionType: WholesalerLedgerTxnType.payment,
          referenceId: '$invoiceNumber-PAID',
          date: dateTime,
          debit: 0,
          credit: paid,
          runningBalance: runningBalance,
        );

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

  /// Fetches complete invoice data for editing via invoice_number
  /// Returns a map with all necessary information to reconstruct the sale
  Future<Map<String, dynamic>?> getInvoiceDataByInvoiceNumber(
    String invoiceNumber,
  ) async {
    final db = await database;

    // Fetch the main sale record
    final salesMaps = await db.query(
      SalesTable.name,
      where: '${SalesTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
      limit: 1,
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
      final zamindarName = payment[PaymentsTable.zamindarName] as String? ?? '';
      final amount =
          (payment[PaymentsTable.amountPaid] as num?)?.round() ?? 0;
      if (zamindarName.isEmpty || amount <= 0) continue;

      final zamindarId = await _resolveZamindarIdByName(txn, zamindarName);
      if (zamindarId == null) continue;

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

  /// Removes sale-originated payments/ledger for an invoice, keeping later
  /// settlement rows (`category = PAYMENT` from [insertPayment]).
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

    await txn.delete(
      LedgerTransactionTable.name,
      where:
          '${LedgerTransactionTable.invoiceNumber} = ? AND '
          'UPPER(${LedgerTransactionTable.category}) != ?',
      whereArgs: [invoiceNumber, 'PAYMENT'],
    );

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
        columns: [SalesTable.zamindarName],
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (saleRows.isEmpty) return;

      final zamindarName =
          saleRows.first[SalesTable.zamindarName] as String? ?? '';
      affectedZamindarId = await _resolveZamindarIdByName(txn, zamindarName);

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

  /// Wipes all transactional business data while preserving table schemas.
  /// Product inventory is intentionally left intact.
  Future<void> truncateFullDatabase() async {
    final db = await database;
    final tables = [
      SaleItemsTable.name,
      PaymentsTable.name,
      LedgerTransactionTable.name,
      SalesTable.name,
      KisaanTable.name,
      ZamindarTable.name,
      ExpenseTable.name,
    ];

    await db.transaction((txn) async {
      for (final table in tables) {
        await txn.delete(table);
        await txn.rawDelete('DELETE FROM sqlite_sequence WHERE name = ?', [
          table,
        ]);
      }
    });

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

      // Step 1: Insert the sale parent record first (FK target for payments).
      await txn.insert(SalesTable.name, {
        SalesTable.invoiceNumber: invoiceNumber,
        SalesTable.dateTime: _formatDateTime(dateTime),
        SalesTable.zamindarName: zamindarName,
        SalesTable.kisaanName: kisaanName,
        SalesTable.subtotal: subtotal,
        SalesTable.itemDiscountsTotal: itemDiscountsTotal,
        SalesTable.seasonalIncrementTotal: seasonalIncrementTotal,
        SalesTable.overallDiscount: overallDiscount,
        SalesTable.totalPayable: totalPayable,
        SalesTable.paidAmount: salePaidAmount,
        SalesTable.paymentMethod: paymentMethod,
        SalesTable.season: season,
        SalesTable.paymentTerm: isCreditSale ? paymentTerm : null,
        SalesTable.transactionType: SaleTransactionType.productSale,
        SalesTable.creditAmount: creditAmount,
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
          SaleItemsTable.unitPrice: item.unitPrice,
          SaleItemsTable.seasonalIncrement: 0,
          SaleItemsTable.itemDiscount: item.discount,
          SaleItemsTable.subtotal: itemSubtotal,
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
          PaymentsTable.zamindarName: zamindarName,
          PaymentsTable.kisaanName: kisaanName,
          PaymentsTable.amountPaid: drawdown,
          PaymentsTable.paymentMethod: 'Advance Wallet Deduction',
          PaymentsTable.season: season,
        });

        if (remainingPhysicalCash > 0) {
          cashPaymentId = await generateNextPaymentId(txn, isAdvance: false);
          await txn.insert(PaymentsTable.name, {
            PaymentsTable.paymentId: cashPaymentId,
            PaymentsTable.invoiceNumber: invoiceNumber,
            PaymentsTable.dateTime: _formatDateTime(dateTime),
            PaymentsTable.zamindarName: zamindarName,
            PaymentsTable.kisaanName: kisaanName,
            PaymentsTable.amountPaid: remainingPhysicalCash,
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
          PaymentsTable.zamindarName: zamindarName,
          PaymentsTable.kisaanName: kisaanName,
          PaymentsTable.amountPaid: effectivePaidAmount,
          PaymentsTable.paymentMethod: 'Cash',
          PaymentsTable.season: season,
        });
      }

      // Step 3: Ledger entries — payment_id FKs require payments to exist first.
      await _insertLedgerEntriesForSale(
        txn,
        invoiceNumber: invoiceNumber,
        zamindarName: zamindarName,
        kisaanName: kisaanName,
        description: items
            .map((item) => '${item.productName} x${item.qty.round()}')
            .join(' · '),
        totalPayable: totalPayable,
        paidAmount: usesAdvanceWallet
            ? remainingPhysicalCash
            : effectivePaidAmount,
        paymentMethod: paymentMethod,
        season: season,
        dateTime: dateTime,
        advanceDrawdown: drawdown,
        walletPaymentId: walletPaymentId,
        cashPaymentId: cashPaymentId,
      );

      final zamindarId = await _resolveZamindarIdByName(txn, zamindarName);
      if (zamindarId != null) {
        await _recalculateZamindarBalanceOn(txn, zamindarId);
      }
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
    final ledgerDescription = (trimmedRemarks != null &&
            trimmedRemarks.isNotEmpty)
        ? '$itemLabel — $trimmedRemarks'
        : itemLabel;

    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(SalesTable.name, {
        SalesTable.invoiceNumber: invoiceNumber,
        SalesTable.dateTime: _formatDateTime(dateTime),
        SalesTable.zamindarName: zamindarName,
        SalesTable.kisaanName: kisaanName ?? 'Self',
        SalesTable.subtotal: amount,
        SalesTable.itemDiscountsTotal: 0,
        SalesTable.seasonalIncrementTotal: 0,
        SalesTable.overallDiscount: 0,
        SalesTable.totalPayable: amount,
        SalesTable.paidAmount: 0,
        SalesTable.paymentMethod: 'Credit',
        SalesTable.season: season,
        SalesTable.paymentTerm: 'After Harvest',
        SalesTable.transactionType: transactionType,
        SalesTable.creditAmount: amount,
        SalesTable.fuelQuantity: liters,
        SalesTable.remarks:
            (trimmedRemarks != null && trimmedRemarks.isNotEmpty)
            ? trimmedRemarks
            : null,
        SalesTable.zamindarId: zamindarId,
        SalesTable.kisaanId: kisaanId,
      });

      // Liters live on sales.fuel_quantity; line qty stays 1 so reports
      // that multiply qty × unit price stay accurate.
      await txn.insert(SaleItemsTable.name, {
        SaleItemsTable.invoiceNumber: invoiceNumber,
        SaleItemsTable.productName: itemLabel,
        SaleItemsTable.productType: 'Advance',
        SaleItemsTable.quantity: 1,
        SaleItemsTable.unitPrice: amount,
        SaleItemsTable.seasonalIncrement: 0,
        SaleItemsTable.itemDiscount: 0,
        SaleItemsTable.subtotal: amount,
      });

      await _insertLedgerEntriesForSale(
        txn,
        invoiceNumber: invoiceNumber,
        zamindarName: zamindarName,
        kisaanName: kisaanName ?? 'Self',
        description: ledgerDescription,
        totalPayable: amount,
        paidAmount: 0,
        paymentMethod: 'Credit',
        season: season,
        dateTime: dateTime,
      );

      // Prefer explicit IDs on the sale row for ledger when names resolve oddly.
      if (kisaanId != null) {
        await txn.update(
          LedgerTransactionTable.name,
          {
            LedgerTransactionTable.zamindarId: zamindarId,
            LedgerTransactionTable.kisaanId: kisaanId,
            LedgerTransactionTable.category: transactionType,
          },
          where:
              '${LedgerTransactionTable.invoiceNumber} = ? AND '
              '${LedgerTransactionTable.type} = ?',
          whereArgs: [invoiceNumber, LedgerTransactionType.debit],
        );
      } else {
        await txn.update(
          LedgerTransactionTable.name,
          {
            LedgerTransactionTable.zamindarId: zamindarId,
            LedgerTransactionTable.category: transactionType,
          },
          where:
              '${LedgerTransactionTable.invoiceNumber} = ? AND '
              '${LedgerTransactionTable.type} = ?',
          whereArgs: [invoiceNumber, LedgerTransactionType.debit],
        );
      }

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

    final salesMaps = await db.query(
      SalesTable.name,
      where: season != null ? '${SalesTable.season} = ?' : null,
      whereArgs: season != null ? [season] : null,
      orderBy: '${SalesTable.dateTime} DESC',
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
        s.${SalesTable.zamindarName} AS zamindar_name,
        s.${SalesTable.dateTime} AS date_time,
        s.${SalesTable.paymentTerm} AS payment_term,
        ($_sqlSaleRemainingExpr) AS remaining
      FROM ${SalesTable.name} s
    ''');

    final paymentRows = await db.query(
      PaymentsTable.name,
      columns: [
        PaymentsTable.invoiceNumber,
        PaymentsTable.dateTime,
        PaymentsTable.zamindarName,
      ],
    );
    final paymentDatesByInvoice = <String, List<DateTime>>{};
    for (final payment in paymentRows) {
      final invoice = payment[PaymentsTable.invoiceNumber] as String?;
      final paidAt = _parseDateTime(
        payment[PaymentsTable.dateTime] as String? ?? '',
      );
      if (invoice != null && invoice.isNotEmpty) {
        paymentDatesByInvoice.putIfAbsent(invoice, () => []).add(paidAt);
      }
      // Advance / unscoped payments still count toward last activity by name.
      final payee = (payment[PaymentsTable.zamindarName] as String? ?? '')
          .trim();
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
    final salesMaps = await db.query(
      SalesTable.name,
      where: '${SalesTable.zamindarName} = ?',
      whereArgs: [zamindarName],
      orderBy: '${SalesTable.dateTime} DESC',
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
        PaymentsTable.zamindarName: zamindarName,
        PaymentsTable.kisaanName: kisaanName,
        PaymentsTable.amountPaid: amountPaid,
        PaymentsTable.paymentMethod: paymentMethod,
        PaymentsTable.season: season,
      });

      await txn.insert(LedgerTransactionTable.name, {
        LedgerTransactionTable.zamindarId: zamindarId,
        LedgerTransactionTable.kisaanId: kisaanId,
        LedgerTransactionTable.invoiceNumber: invoiceNumber,
        LedgerTransactionTable.paymentId: resolvedPaymentId,
        LedgerTransactionTable.type: LedgerTransactionType.credit,
        LedgerTransactionTable.category: 'PAYMENT',
        LedgerTransactionTable.description: 'Payment for $invoiceNumber',
        LedgerTransactionTable.amount: amountPaid.round(),
        LedgerTransactionTable.dateTime: _formatDateTime(dateTime),
        LedgerTransactionTable.season: season,
      });

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
        WHERE s.${SalesTable.zamindarName} = ?
          AND s.${SalesTable.kisaanName} = ?
      ''',
      [zamindar.name, kisaanName],
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
                 s.${SalesTable.zamindarName},
                 s.${SalesTable.paidAmount}
          FROM ${SalesTable.name} s
          WHERE s.${SalesTable.zamindarName} = ?
            AND s.${SalesTable.kisaanName} = ?
          ORDER BY s.${SalesTable.dateTime} ASC
        ''',
        [zamindar.name, kisaanName],
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
          PaymentsTable.zamindarName: inv[SalesTable.zamindarName],
          PaymentsTable.kisaanName: kisaanName,
          PaymentsTable.amountPaid: allocation,
          PaymentsTable.paymentMethod: paymentMethod,
          PaymentsTable.season: season,
        });

        await txn.insert(LedgerTransactionTable.name, {
          LedgerTransactionTable.zamindarId: zamindarId,
          LedgerTransactionTable.kisaanId: kisaanId,
          LedgerTransactionTable.invoiceNumber: invoiceNumber,
          LedgerTransactionTable.paymentId: paymentId,
          LedgerTransactionTable.type: LedgerTransactionType.credit,
          LedgerTransactionTable.category: 'PAYMENT',
          LedgerTransactionTable.description: 'Payment for $invoiceNumber',
          LedgerTransactionTable.amount: allocation.round(),
          LedgerTransactionTable.dateTime: _formatDateTime(now),
          LedgerTransactionTable.season: season,
        });

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
        columns: [SalesTable.zamindarName],
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
        limit: 1,
      );
      if (existingSale.isEmpty) {
        throw StateError('Invoice $invoiceNumber was not found.');
      }

      final previousZamindarName =
          existingSale.first[SalesTable.zamindarName] as String? ?? '';
      final previousZamindarId = await _resolveZamindarIdByName(
        txn,
        previousZamindarName,
      );
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

      await txn.update(
        SalesTable.name,
        {
          SalesTable.dateTime: _formatDateTime(dateTime),
          SalesTable.zamindarName: zamindarName,
          SalesTable.kisaanName: kisaanName,
          SalesTable.subtotal: subtotal,
          SalesTable.itemDiscountsTotal: itemDiscountsTotal,
          SalesTable.seasonalIncrementTotal: seasonalIncrementTotal,
          SalesTable.overallDiscount: overallDiscount,
          SalesTable.totalPayable: totalPayable,
          SalesTable.paidAmount: salePaidAmount,
          SalesTable.paymentMethod: paymentMethod,
          SalesTable.season: season,
          SalesTable.paymentTerm: isCreditSale ? paymentTerm : null,
          SalesTable.transactionType: SaleTransactionType.productSale,
          SalesTable.creditAmount: creditAmount,
          SalesTable.zamindarId: resolvedZamindarId,
          SalesTable.kisaanId: resolvedKisaanId,
        },
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      for (final item in items) {
        final itemSubtotal = (item.qty * item.unitPrice) - item.discount;
        await txn.insert(SaleItemsTable.name, {
          SaleItemsTable.invoiceNumber: invoiceNumber,
          SaleItemsTable.productName: item.productName,
          SaleItemsTable.productType: productType,
          SaleItemsTable.quantity: item.qty.round(),
          SaleItemsTable.unitPrice: item.unitPrice,
          SaleItemsTable.seasonalIncrement: 0,
          SaleItemsTable.itemDiscount: item.discount,
          SaleItemsTable.subtotal: itemSubtotal,
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
          PaymentsTable.zamindarName: zamindarName,
          PaymentsTable.kisaanName: kisaanName,
          PaymentsTable.amountPaid: drawdown,
          PaymentsTable.paymentMethod: 'Advance Wallet Deduction',
          PaymentsTable.season: season,
        });

        if (remainingPhysicalCash > 0) {
          cashPaymentId = await generateNextPaymentId(txn, isAdvance: false);
          await txn.insert(PaymentsTable.name, {
            PaymentsTable.paymentId: cashPaymentId,
            PaymentsTable.invoiceNumber: invoiceNumber,
            PaymentsTable.dateTime: _formatDateTime(dateTime),
            PaymentsTable.zamindarName: zamindarName,
            PaymentsTable.kisaanName: kisaanName,
            PaymentsTable.amountPaid: remainingPhysicalCash,
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
          PaymentsTable.zamindarName: zamindarName,
          PaymentsTable.kisaanName: kisaanName,
          PaymentsTable.amountPaid: effectivePaidAmount,
          PaymentsTable.paymentMethod: 'Cash',
          PaymentsTable.season: season,
        });
      }

      await _insertLedgerEntriesForSale(
        txn,
        invoiceNumber: invoiceNumber,
        zamindarName: zamindarName,
        kisaanName: kisaanName,
        description: items
            .map((item) => '${item.productName} x${item.qty.round()}')
            .join(' · '),
        totalPayable: totalPayable,
        paidAmount: usesAdvanceWallet
            ? remainingPhysicalCash
            : effectivePaidAmount,
        paymentMethod: paymentMethod,
        season: season,
        dateTime: dateTime,
        advanceDrawdown: drawdown,
        walletPaymentId: walletPaymentId,
        cashPaymentId: cashPaymentId,
      );

      final newZamindarId = await _resolveZamindarIdByName(txn, zamindarName);
      if (newZamindarId != null) {
        affectedZamindarIds.add(newZamindarId);
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
        columns: [ZamindarTable.advanceBalance, ZamindarTable.nameColumn],
        where: '${ZamindarTable.id} = ?',
        whereArgs: [zamindarId],
        limit: 1,
      );

      if (zamindarMaps.isEmpty) {
        throw StateError('Zamindar not found.');
      }

      final zamindarName =
          zamindarMaps.first[ZamindarTable.nameColumn] as String;
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
        PaymentsTable.zamindarName: zamindarName,
        PaymentsTable.kisaanName: null,
        PaymentsTable.amountPaid: amount,
        PaymentsTable.paymentMethod: 'Cash',
        PaymentsTable.season: season,
      });

      await txn.insert(LedgerTransactionTable.name, {
        LedgerTransactionTable.zamindarId: zamindarId,
        LedgerTransactionTable.kisaanId: null,
        LedgerTransactionTable.invoiceNumber: null,
        LedgerTransactionTable.paymentId: paymentId,
        LedgerTransactionTable.type: LedgerTransactionType.credit,
        LedgerTransactionTable.category: 'ADVANCE_PAYMENT',
        LedgerTransactionTable.description: 'Advance payment received',
        LedgerTransactionTable.amount: amount,
        LedgerTransactionTable.dateTime: formattedDateTime,
        LedgerTransactionTable.season: season,
      });
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
  static const String zamindarName = 'zamindar_name';
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
  static const String zamindarName = 'zamindar_name';
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

  const DbExpense({
    this.id,
    required this.category,
    required this.amount,
    required this.remarks,
    required this.expenseDate,
  });

  Map<String, Object?> toMap() => {
    ExpenseTable.category: category,
    ExpenseTable.amount: amount,
    ExpenseTable.remarks: remarks,
    ExpenseTable.expenseDate: DatabaseHelper._formatDateTime(expenseDate),
  };

  factory DbExpense.fromMap(Map<String, Object?> map) {
    final rawDate = map[ExpenseTable.expenseDate] as String? ?? '';
    return DbExpense(
      id: map[ExpenseTable.id] as int?,
      category: map[ExpenseTable.category] as String? ?? '',
      amount: (map[ExpenseTable.amount] as num?)?.toDouble() ?? 0,
      remarks: map[ExpenseTable.remarks] as String? ?? '',
      expenseDate: DateTime.tryParse(rawDate) ?? DateTime.now(),
    );
  }
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
