import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Singleton database helper for the AgriKhata local relational database.
///
/// This file contains:
/// - a strongly typed schema definition via model classes and column constants
/// - table creation scripts
/// - CRUD helpers for all four tables
/// - business helpers for zamindar balances and product inventory status
class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  static Database? _database;
  static bool _factoryInitialized = false;

  Future<Database> get database async {
    await _ensureDatabaseFactory();
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'agrikhata.db');

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 6,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute(_createZamindarsTable());
          await db.execute(_createKisaansTable());
          await db.execute(_createProductsTable());
          await db.execute(_createLedgerTransactionsTable());
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
            debugPrint('Migrating to version 5: Adding seasonal_increment to products');
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
              debugPrint('Products table recreated successfully with correct column names');
            } catch (e) {
              debugPrint('Error recreating products table: $e');
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
      ${ZamindarTable.isDraft} INTEGER DEFAULT 0
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
      ${LedgerTransactionTable.type} TEXT NOT NULL,
      ${LedgerTransactionTable.category} TEXT NOT NULL,
      ${LedgerTransactionTable.description} TEXT NOT NULL,
      ${LedgerTransactionTable.amount} INTEGER NOT NULL,
      ${LedgerTransactionTable.dateTime} TEXT NOT NULL,
      ${LedgerTransactionTable.season} TEXT NOT NULL,
      FOREIGN KEY (${LedgerTransactionTable.zamindarId}) REFERENCES ${ZamindarTable.name}(${ZamindarTable.id})
        ON DELETE CASCADE,
      FOREIGN KEY (${LedgerTransactionTable.kisaanId}) REFERENCES ${KisaanTable.name}(${KisaanTable.id})
        ON DELETE SET NULL
    )
  ''';

  // -----------------------------
  // Zamindar CRUD
  // -----------------------------

  Future<int> insertZamindar(Zamindar zamindar) async {
    final db = await database;
    return db.insert(ZamindarTable.name, zamindar.toMap());
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
    return db.update(
      ZamindarTable.name,
      zamindar.toMap(),
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindar.id],
    );
  }

  Future<int> deleteZamindar(int id) async {
    final db = await database;
    return db.delete(
      ZamindarTable.name,
      where: '${ZamindarTable.id} = ?',
      whereArgs: [id],
    );
  }

  // -----------------------------
  // Kisaan CRUD
  // -----------------------------

  Future<int> insertKisaan(Kisaan kisaan) async {
    final db = await database;
    return db.insert(KisaanTable.name, kisaan.toMap());
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
    return db.update(
      KisaanTable.name,
      kisaan.toMap(),
      where: '${KisaanTable.id} = ?',
      whereArgs: [kisaan.id],
    );
  }

  Future<int> deleteKisaan(int id) async {
    final db = await database;
    return db.delete(
      KisaanTable.name,
      where: '${KisaanTable.id} = ?',
      whereArgs: [id],
    );
  }

  // -----------------------------
  // Product CRUD
  // -----------------------------

  Future<int> insertProduct(ProductItem product) async {
    final db = await database;
    return db.insert(ProductTable.name, product.toMap());
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
    return db.update(
      ProductTable.name,
      product.toMap(),
      where: '${ProductTable.id} = ?',
      whereArgs: [product.id],
    );
  }

  Future<int> deleteProduct(int id) async {
    final db = await database;
    return db.delete(
      ProductTable.name,
      where: '${ProductTable.id} = ?',
      whereArgs: [id],
    );
  }

  // -----------------------------
  // Ledger Transaction CRUD
  // -----------------------------

  Future<int> insertLedgerTransaction(LedgerTransaction transaction) async {
    final db = await database;
    return db.insert(LedgerTransactionTable.name, transaction.toMap());
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

  Future<List<LedgerTransaction>> getLedgerTransactionsForZamindar(
    int zamindarId,
  ) async {
    final db = await database;
    final maps = await db.query(
      LedgerTransactionTable.name,
      where: '${LedgerTransactionTable.zamindarId} = ?',
      whereArgs: [zamindarId],
      orderBy: '${LedgerTransactionTable.dateTime} DESC',
    );
    return maps.map(LedgerTransaction.fromMap).toList();
  }

  Future<List<LedgerTransaction>> getAllLedgerTransactions() async {
    final db = await database;
    final maps = await db.query(
      LedgerTransactionTable.name,
      orderBy: '${LedgerTransactionTable.dateTime} DESC',
    );
    return maps.map(LedgerTransaction.fromMap).toList();
  }

  Future<int> updateLedgerTransaction(LedgerTransaction transaction) async {
    final db = await database;
    return db.update(
      LedgerTransactionTable.name,
      transaction.toMap(),
      where: '${LedgerTransactionTable.id} = ?',
      whereArgs: [transaction.id],
    );
  }

  Future<int> deleteLedgerTransaction(int id) async {
    final db = await database;
    return db.delete(
      LedgerTransactionTable.name,
      where: '${LedgerTransactionTable.id} = ?',
      whereArgs: [id],
    );
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
      columns: [ZamindarTable.creditLimit],
      where: '${ZamindarTable.id} = ?',
      whereArgs: [zamindarId],
      limit: 1,
    );

    if (zamindarRows.isEmpty) return null;

    final creditLimit =
        (zamindarRows.first[ZamindarTable.creditLimit] as int?) ?? 0;

    final salesResult = await db.rawQuery(
      '''
        SELECT COALESCE(SUM(${LedgerTransactionTable.amount}), 0) AS total_sales
        FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.zamindarId} = ?
          AND ${LedgerTransactionTable.type} = ?
      ''',
      [zamindarId, LedgerTransactionType.debit],
    );

    final paymentsResult = await db.rawQuery(
      '''
        SELECT COALESCE(SUM(${LedgerTransactionTable.amount}), 0) AS total_payments
        FROM ${LedgerTransactionTable.name}
        WHERE ${LedgerTransactionTable.zamindarId} = ?
          AND ${LedgerTransactionTable.type} = ?
      ''',
      [zamindarId, LedgerTransactionType.credit],
    );

    final totalSales = _readIntValue(salesResult.first['total_sales']);
    final totalPayments = _readIntValue(paymentsResult.first['total_payments']);
    final outstandingBalance = totalSales - totalPayments;

    return {
      'totalSales': totalSales,
      'totalPayments': totalPayments,
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
  final String paymentTerms;
  final List<String> activeSeasons;
  final List<String> activeCrops;
  final double udhaarBalance;
  final int activeKisaans;
  final bool isOverLimit;
  final bool isDraft;

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
  });

  double get totalLandAcres => landArea;
  String get villageDisplay => village ?? locationGoth ?? 'Unknown location';

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
    String? paymentTerms,
    List<String>? activeSeasons,
    List<String>? activeCrops,
    double? udhaarBalance,
    int? activeKisaans,
    bool? isOverLimit,
    bool? isDraft,
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
    );
  }

  static int _parseIntValue(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
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
    ZamindarTable.paymentTerms: paymentTerms,
    ZamindarTable.activeSeasons: activeSeasons.join(','),
    ZamindarTable.activeCrops: activeCrops.join(','),
    ZamindarTable.isDraft: isDraft ? 1 : 0,
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
      paymentTerms: map[ZamindarTable.paymentTerms] as String? ?? 'Seasonal',
      activeSeasons: (map[ZamindarTable.activeSeasons] as String? ?? '')
          .split(',')
          .where((item) => item.isNotEmpty)
          .toList(),
      activeCrops: (map[ZamindarTable.activeCrops] as String? ?? '')
          .split(',')
          .where((item) => item.isNotEmpty)
          .toList(),
      isDraft: _parseIntValue(map[ZamindarTable.isDraft]) == 1,
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
