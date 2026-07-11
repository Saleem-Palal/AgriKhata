import 'dart:io';

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

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
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
        version: 17,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute(_createZamindarsTable());
          await db.execute(_createKisaansTable());
          await db.execute(_createProductsTable());
          await db.execute(_createLedgerTransactionsTable());
          await db.execute(_createSalesTable());
          await db.execute(_createSaleItemsTable());
          await db.execute(_createPaymentsTable());
          await db.execute(_createPaymentSequencesTable());
          await db.execute(_createStockMovementsTable());
          await _createIndexes(db);
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
        },
      ),
    );
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
        where:
            'UPPER(${LedgerTransactionTable.category}) IN (?, ?)',
        whereArgs: const ['ADVANCE_PAYMENT', 'ADVANCE'],
      );

      for (final row in rows) {
        final id = row[LedgerTransactionTable.id] as int?;
        final dateRaw = row[LedgerTransactionTable.dateTime] as String?;
        if (id == null || dateRaw == null || dateRaw.isEmpty) continue;

        final correctSeason = SeasonUtils.getSeasonString(
          _parseDateTime(dateRaw),
        );
        final current =
            (row[LedgerTransactionTable.season] as String? ?? '').trim();
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
          description: description.isEmpty ? 'Sale $invoiceNumber' : description,
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
        LedgerTransactionTable.category:
            paymentMethod == 'Cash' ? 'CASH_PAYMENT' : 'PAYMENT',
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

  String _createPaymentSequencesTable() =>
      '''
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
      await db.insert(
        'payment_sequences',
        {'sequence_key': key, 'last_value': maxSeq},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
      ${ZamindarTable.advanceBalance} INTEGER DEFAULT 0
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
        ON DELETE SET NULL,
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
      ${SalesTable.paymentTerm} TEXT
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
        ON DELETE CASCADE
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
    await db.execute('ALTER TABLE payments_new RENAME TO ${PaymentsTable.name}');
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

  Future<void> _renamePaymentId(
    Database db,
    String oldId,
    String newId,
  ) async {
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
      orderBy:
          '${PaymentsTable.dateTime} ASC, ${PaymentsTable.paymentId} ASC',
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

    await executor.insert(
      'payment_sequences',
      {'sequence_key': key, 'last_value': 1000},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

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
      movementType: delta > 0 ? StockMovementType.stockIn : StockMovementType.stockOut,
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
      orderBy: '${StockMovementTable.dateTime} DESC, ${StockMovementTable.id} DESC',
    );

    return rows.map((row) {
      final type = row[StockMovementTable.movementType] as String;
      final qty = (row[StockMovementTable.quantity] as num).toInt();
      return ProductHistoryEntry(
        id: row[StockMovementTable.id] as int?,
        productId: productId,
        dateTime: DateTime.tryParse(
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
    return db.rawQuery('''
      SELECT lt.*, k.${KisaanTable.nameColumn} AS kisaan_name
      FROM ${LedgerTransactionTable.name} lt
      LEFT JOIN ${KisaanTable.name} k
        ON lt.${LedgerTransactionTable.kisaanId} = k.${KisaanTable.id}
      WHERE lt.${LedgerTransactionTable.zamindarId} = ?
      ORDER BY lt.${LedgerTransactionTable.dateTime} DESC$limitClause
    ''', [zamindarId]);
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
    final rows = await db.rawQuery(
      '''
      SELECT ${SaleItemsTable.invoiceNumber},
             ${SaleItemsTable.productName},
             ${SaleItemsTable.quantity}
      FROM ${SaleItemsTable.name}
      WHERE ${SaleItemsTable.invoiceNumber} IN ($placeholders)
      ORDER BY ${SaleItemsTable.id} ASC
      ''',
      unique,
    );

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
  Future<int> getTotalPaymentsReceived(int zamindarId) async {
    final db = await database;
    final result = await db.rawQuery(
      '''
        SELECT COALESCE(SUM(${LedgerTransactionTable.amount}), 0) AS total
        FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.zamindarId} = ?
          AND ${LedgerTransactionTable.type} = ?
          AND UPPER(${LedgerTransactionTable.category}) NOT IN ('ADVANCE', 'ADVANCE_PAYMENT')
      ''',
      [zamindarId, LedgerTransactionType.credit],
    );
    return _readIntValue(result.first['total']);
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

  /// Calculates total land allocated to all Kisaans under a Zamindar (in Acres).
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

  /// Calculates total debits, total credits, outstanding balance,
  /// and whether the balance exceeds the zamindar's credit limit.
  /// Returns null when the zamindar does not exist.
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

    // Sales schema is the source of truth for invoices and collections.
    final salesWithDetails = await getSalesForZamindar(zamindarName);
    var totalSales = 0;
    var totalPayments = 0;

    for (final saleData in salesWithDetails) {
      final sale = saleData['sale'] as Map<String, dynamic>;
      totalSales += (sale[SalesTable.totalPayable] as num).round();
      totalPayments += (saleData['totalCollected'] as num).round();
    }

    final rawOutstanding = totalSales - totalPayments;
    final outstandingBalance = rawOutstanding < 0 ? 0 : rawOutstanding;

    return {
      'totalSales': totalSales,
      'totalPayments': totalPayments,
      'totalDebits': totalSales,
      'outstandingBalance': outstandingBalance,
      'isOverLimit': outstandingBalance > creditLimit,
    };
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
    final db = await database;
    final salesResult = await db.rawQuery(
      '''
        SELECT COALESCE(SUM(${LedgerTransactionTable.amount}), 0) AS total_sales
        FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.kisaanId} = ?
          AND ${LedgerTransactionTable.type} = ?
      ''',
      [kisaanId, LedgerTransactionType.debit],
    );
    final paymentsResult = await db.rawQuery(
      '''
        SELECT COALESCE(SUM(${LedgerTransactionTable.amount}), 0) AS total_payments
        FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.kisaanId} = ?
          AND ${LedgerTransactionTable.type} = ?
      ''',
      [kisaanId, LedgerTransactionType.credit],
    );
    final totalSales = _readIntValue(salesResult.first['total_sales']);
    final totalPayments = _readIntValue(paymentsResult.first['total_payments']);
    return (totalSales - totalPayments).toDouble();
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
    final totalCollected =
        _sumPaymentsCollected(initialPaid, paymentsMaps);

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

  /// Removes a single invoice and all linked sales, payments, and ledger rows.
  Future<void> deleteInvoiceEntirely(String invoiceNumber) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      await txn.delete(
        SalesTable.name,
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      await txn.delete(
        PaymentsTable.name,
        where: '${PaymentsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
      await txn.delete(
        LedgerTransactionTable.name,
        where: '${LedgerTransactionTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );
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
    ];

    await db.transaction((txn) async {
      for (final table in tables) {
        await txn.delete(table);
        await txn.rawDelete(
          'DELETE FROM sqlite_sequence WHERE name = ?',
          [table],
        );
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
          columns: [
            ZamindarTable.id,
            ZamindarTable.advanceBalance,
          ],
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
      final totalCollected =
          _sumPaymentsCollected(initialPaid, paymentsMaps);

      salesWithDetails.add({
        'sale': saleMap,
        'items': itemsMaps,
        'payments': paymentsMaps,
        'totalCollected': totalCollected,
      });
    }

    return salesWithDetails;
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
      final totalCollected =
          _sumPaymentsCollected(initialPaid, paymentsMaps);

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
      resolvedPaymentId = paymentId ??
          await generateNextPaymentId(txn, isAdvance: false);

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
    });

    notifyListeners();
    return resolvedPaymentId;
  }

  /// Outstanding debt for a Kisaan based on sales minus all payments collected.
  /// Debt = Sum(total_payable) - Sum(paid_amount + subsequent payments) per invoice.
  Future<double> getKisaanSalesOutstandingDebt({
    required int zamindarId,
    required String kisaanName,
  }) async {
    final zamindar = await getZamindar(zamindarId);
    if (zamindar == null) return 0.0;

    final db = await database;
    final invoices = await db.rawQuery(
      '''
        SELECT s.${SalesTable.invoiceNumber},
               s.${SalesTable.totalPayable},
               s.${SalesTable.paidAmount},
               COALESCE((
                 SELECT SUM(p.${PaymentsTable.amountPaid})
                 FROM ${PaymentsTable.name} p
                 WHERE p.${PaymentsTable.invoiceNumber} = s.${SalesTable.invoiceNumber}
               ), 0) AS total_collected
        FROM ${SalesTable.name} s
        WHERE s.${SalesTable.zamindarName} = ?
          AND s.${SalesTable.kisaanName} = ?
      ''',
      [zamindar.name, kisaanName],
    );

    double debt = 0.0;
    for (final inv in invoices) {
      final totalPayable =
          (inv[SalesTable.totalPayable] as num?)?.toDouble() ?? 0.0;
      final initialPaid =
          (inv[SalesTable.paidAmount] as num?)?.toDouble() ?? 0.0;
      final additionalPayments =
          (inv['total_collected'] as num?)?.toDouble() ?? 0.0;
      final remaining = totalPayable - initialPaid - additionalPayments;
      if (remaining > 0) debt += remaining;
    }
    return debt;
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
        final totalPayable =
            (inv[SalesTable.totalPayable] as num).toDouble();
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

  /// Gets all payments
  Future<List<Map<String, dynamic>>> getAllPayments({String? season}) async {
    final db = await database;
    String? whereClause;
    List<dynamic>? whereArgs;

    if (season != null) {
      whereClause = '${PaymentsTable.season} = ?';
      whereArgs = [season];
    }

    return await db.query(
      PaymentsTable.name,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: '${PaymentsTable.dateTime} DESC',
    );
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

  /// Calculates remaining balance for an invoice
  Future<double> getInvoiceRemainingBalance(String invoiceNumber) async {
    final db = await database;

    // Get the sale record
    final saleMaps = await db.query(
      SalesTable.name,
      where: '${SalesTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
      limit: 1,
    );

    if (saleMaps.isEmpty) return 0.0;

    final totalPayable =
        (saleMaps.first[SalesTable.totalPayable] as num?)?.toDouble() ?? 0.0;
    final initialPaid =
        (saleMaps.first[SalesTable.paidAmount] as num?)?.toDouble() ?? 0.0;

    // Get all payments for this invoice
    final paymentsMaps = await db.query(
      PaymentsTable.name,
      where: '${PaymentsTable.invoiceNumber} = ?',
      whereArgs: [invoiceNumber],
    );

    final totalCollected = _sumPaymentsCollected(initialPaid, paymentsMaps);

    return totalPayable - totalCollected;
  }

  /// Updates an existing sale (for edit functionality)
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
    final db = await database;
    await db.transaction((txn) async {
      // First, get old items to restore stock
      final oldItems = await txn.query(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      // Restore stock for old items
      for (final oldItem in oldItems) {
        final productName = oldItem[SaleItemsTable.productName] as String;
        final oldQuantity =
            (oldItem[SaleItemsTable.quantity] as num?)?.toInt() ?? 0;

        // Find product by name to get ID
        final products = await txn.query(
          ProductTable.name,
          where: '${ProductTable.nameColumn} = ?',
          whereArgs: [productName],
          limit: 1,
        );

        if (products.isNotEmpty) {
          final productId = products.first[ProductTable.id] as int;
          final currentStock = _readIntValue(
            products.first[ProductTable.availableStock],
          );
          final restoredStock = (currentStock + oldQuantity).clamp(0, 1 << 31);

          await txn.update(
            ProductTable.name,
            {ProductTable.availableStock: restoredStock},
            where: '${ProductTable.id} = ?',
            whereArgs: [productId],
          );
        }
      }

      // Remove prior SALE stock movements for this invoice (rewritten below).
      await txn.delete(
        StockMovementTable.name,
        where:
            '${StockMovementTable.referenceType} = ? AND ${StockMovementTable.referenceId} = ?',
        whereArgs: [StockMovementRef.sale, invoiceNumber],
      );

      // Delete old items
      await txn.delete(
        SaleItemsTable.name,
        where: '${SaleItemsTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      // Calculate new totals
      final subtotal = items.fold<double>(
        0.0,
        (sum, item) => sum + (item.qty * item.unitPrice),
      );
      final itemDiscountsTotal = items.fold<double>(
        0.0,
        (sum, item) => sum + item.discount,
      );
      final seasonalIncrementTotal = 0.0; // Will be calculated from sale_items
      final totalPayable =
          subtotal +
          seasonalIncrementTotal -
          itemDiscountsTotal -
          overallDiscount;

      // Update sales table
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
          SalesTable.paidAmount: paidAmount,
          SalesTable.paymentMethod: paymentMethod,
          SalesTable.season: season,
          SalesTable.paymentTerm:
              paymentMethod == 'Credit' ? paymentTerm : null,
        },
        where: '${SalesTable.invoiceNumber} = ?',
        whereArgs: [invoiceNumber],
      );

      // Insert new items
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

      // Decrement stock for new items + rewrite STOCK OUT ledger
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
    });

    // Notify listeners that database has changed
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
        columns: [
          ZamindarTable.advanceBalance,
          ZamindarTable.nameColumn,
        ],
        where: '${ZamindarTable.id} = ?',
        whereArgs: [zamindarId],
        limit: 1,
      );

      if (zamindarMaps.isEmpty) {
        throw StateError('Zamindar not found.');
      }

      final zamindarName =
          zamindarMaps.first[ZamindarTable.nameColumn] as String;
      final currentBalance =
          _readIntValue(zamindarMaps.first[ZamindarTable.advanceBalance]);
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
}

/// =========================
/// Models
/// =========================

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
      return value.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
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
