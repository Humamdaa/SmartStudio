import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/index_dashboard_stats.dart';
import '../models/person_group.dart';

class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  static const _databaseVersion = 6;
  static Database? _db;

  Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'pixmind.db');
    return openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: _ensurePresentationSchema,
    );
  }

  Future<void> _onCreate(Database database, int version) async {
    await database.execute('''
      CREATE TABLE media_analysis (
        id TEXT PRIMARY KEY,
        ai_caption TEXT,
        extracted_text TEXT,
        sentiment TEXT,
        credibility_score REAL,
        labels TEXT,
        analyzed_at INTEGER
      )
    ''');
    await database.execute('''
      CREATE TABLE secure_files (
        id TEXT PRIMARY KEY,
        asset_id TEXT NOT NULL,
        added_at INTEGER
      )
    ''');
    await database.execute('''
      CREATE TABLE duplicates (
        asset_id TEXT PRIMARY KEY,
        group_id TEXT,
        phash TEXT
      )
    ''');
    await _ensurePresentationSchema(database);
  }

  Future<void> _onUpgrade(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    await _ensurePresentationSchema(database);
  }

  Future<void> _ensurePresentationSchema(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS search_index (
        asset_id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        taken_at INTEGER NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        objects TEXT NOT NULL DEFAULT '[]',
        scenes TEXT NOT NULL DEFAULT '[]',
        colors TEXT NOT NULL DEFAULT '[]',
        ocr_text TEXT NOT NULL DEFAULT '',
        ocr_search_text TEXT NOT NULL DEFAULT '',
        ocr_scripts TEXT NOT NULL DEFAULT '[]',
        metadata TEXT NOT NULL DEFAULT '',
        searchable_text TEXT NOT NULL DEFAULT '',
        people TEXT NOT NULL DEFAULT '[]',
        face_count INTEGER NOT NULL DEFAULT 0,
        indexed_at INTEGER NOT NULL,
        model_version TEXT NOT NULL DEFAULT '',
        last_error TEXT
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS person_groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        search_name TEXT NOT NULL DEFAULT '',
        cover_asset_id TEXT,
        cover_face_key TEXT,
        cover_face_jpeg BLOB,
        cover_quality REAL NOT NULL DEFAULT 0,
        centroid TEXT NOT NULL DEFAULT '[]',
        sample_count INTEGER NOT NULL DEFAULT 0,
        is_named INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS person_assets (
        person_id TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        PRIMARY KEY (person_id, asset_id)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS face_instances (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        face_key TEXT NOT NULL UNIQUE,
        asset_id TEXT NOT NULL,
        person_id TEXT NOT NULL,
        bbox_left REAL NOT NULL,
        bbox_top REAL NOT NULL,
        bbox_right REAL NOT NULL,
        bbox_bottom REAL NOT NULL,
        confidence REAL NOT NULL DEFAULT 0,
        embedding TEXT NOT NULL DEFAULT '[]',
        quality_score REAL NOT NULL DEFAULT 0,
        pose_score REAL NOT NULL DEFAULT 0,
        face_crop_jpeg BLOB,
        pipeline_version TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS face_scans (
        asset_id TEXT PRIMARY KEY,
        scanned_at INTEGER NOT NULL,
        face_count INTEGER NOT NULL DEFAULT 0,
        pipeline_version TEXT NOT NULL DEFAULT ''
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS face_rejections (
        asset_id TEXT NOT NULL,
        person_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (asset_id, person_id)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS index_queue (
        asset_id TEXT PRIMARY KEY,
        state TEXT NOT NULL DEFAULT 'pending',
        priority INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        added_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS index_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mode TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER,
        processed INTEGER NOT NULL DEFAULT 0,
        failed INTEGER NOT NULL DEFAULT 0,
        note TEXT
      )
    ''');

    // The APK already used early versions of these tables. Additive checks
    // keep its local index and albums intact during this upgrade.
    await _addColumnIfMissing(
      database,
      'search_index',
      'ocr_scripts',
      "TEXT NOT NULL DEFAULT '[]'",
    );
    await _addColumnIfMissing(
      database,
      'search_index',
      'ocr_search_text',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      database,
      'search_index',
      'people',
      "TEXT NOT NULL DEFAULT '[]'",
    );
    await _addColumnIfMissing(
      database,
      'search_index',
      'face_count',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(database, 'search_index', 'last_error', 'TEXT');
    await _addColumnIfMissing(
      database,
      'person_groups',
      'search_name',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      database,
      'person_groups',
      'centroid',
      "TEXT NOT NULL DEFAULT '[]'",
    );
    await _addColumnIfMissing(
      database,
      'person_groups',
      'sample_count',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      database,
      'person_groups',
      'is_named',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      database,
      'person_groups',
      'updated_at',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      database,
      'person_groups',
      'cover_face_key',
      'TEXT',
    );
    await _addColumnIfMissing(
      database,
      'person_groups',
      'cover_face_jpeg',
      'BLOB',
    );
    await _addColumnIfMissing(
      database,
      'person_groups',
      'cover_quality',
      'REAL NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      database,
      'face_instances',
      'embedding',
      "TEXT NOT NULL DEFAULT '[]'",
    );
    await _addColumnIfMissing(
      database,
      'face_instances',
      'quality_score',
      'REAL NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      database,
      'face_instances',
      'pose_score',
      'REAL NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      database,
      'face_instances',
      'face_crop_jpeg',
      'BLOB',
    );
    await _addColumnIfMissing(
      database,
      'face_instances',
      'pipeline_version',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      database,
      'face_scans',
      'pipeline_version',
      "TEXT NOT NULL DEFAULT ''",
    );

    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_search_index_taken_at ON search_index(taken_at DESC)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_index_queue_state ON index_queue(state, priority DESC, added_at ASC)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_face_instances_asset ON face_instances(asset_id)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_face_instances_person ON face_instances(person_id, quality_score DESC)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_person_assets_asset ON person_assets(asset_id)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_person_assets_person ON person_assets(person_id, asset_id)',
    );
  }

  //  for search in images by image

  Future<void> _ensureVisualSearchSchema(Database database) async {
    await database.execute('''
    CREATE TABLE IF NOT EXISTS visual_image_embeddings (
      asset_id TEXT PRIMARY KEY,
      embedding BLOB NOT NULL,
      dimension INTEGER NOT NULL,
      model_version TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');

    await database.execute('''
    CREATE INDEX IF NOT EXISTS
    idx_visual_image_embeddings_model
    ON visual_image_embeddings(model_version)
  ''');
  }

  Future<void> ensureVisualSearchSchema() async {
    final database = await db;
    await _ensureVisualSearchSchema(database);
  }

  Future<void> saveVisualImageEmbedding({
    required String assetId,
    required Uint8List embedding,
    required int dimension,
    required String modelVersion,
  }) async {
    final database = await db;

    await _ensureVisualSearchSchema(database);

    await database.insert('visual_image_embeddings', {
      'asset_id': assetId,
      'embedding': embedding,
      'dimension': dimension,
      'model_version': modelVersion,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>?> getVisualImageEmbedding({
    required String assetId,
    required String modelVersion,
  }) async {
    final database = await db;

    await _ensureVisualSearchSchema(database);

    final rows = await database.query(
      'visual_image_embeddings',
      where: 'asset_id = ? AND model_version = ?',
      whereArgs: [assetId, modelVersion],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return rows.first;
  }

  Future<Set<String>> getVisualImageEmbeddingAssetIds({
    required String modelVersion,
  }) async {
    final database = await db;

    await _ensureVisualSearchSchema(database);

    final rows = await database.query(
      'visual_image_embeddings',
      columns: const ['asset_id'],
      where: 'model_version = ?',
      whereArgs: [modelVersion],
    );

    return rows
        .map((row) => row['asset_id']?.toString())
        .whereType<String>()
        .toSet();
  }

  Future<List<Map<String, Object?>>> getVisualImageEmbeddingPage({
    required String modelVersion,
    required int limit,
    required int offset,
    String? excludeAssetId,
  }) async {
    final database = await db;

    await _ensureVisualSearchSchema(database);

    if (excludeAssetId == null) {
      return database.query(
        'visual_image_embeddings',
        where: 'model_version = ?',
        whereArgs: [modelVersion],
        orderBy: 'asset_id ASC',
        limit: limit,
        offset: offset,
      );
    }

    return database.query(
      'visual_image_embeddings',
      where: 'model_version = ? AND asset_id != ?',
      whereArgs: [modelVersion, excludeAssetId],
      orderBy: 'asset_id ASC',
      limit: limit,
      offset: offset,
    );
  }

  Future<int> countVisualImageEmbeddings({required String modelVersion}) async {
    final database = await db;

    await _ensureVisualSearchSchema(database);

    final result = await database.rawQuery(
      '''
    SELECT COUNT(*) AS count
    FROM visual_image_embeddings
    WHERE model_version = ?
    ''',
      [modelVersion],
    );

    return (result.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<void> deleteVisualImageEmbedding(String assetId) async {
    final database = await db;

    await database.delete(
      'visual_image_embeddings',
      where: 'asset_id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> _addColumnIfMissing(
    Database database,
    String table,
    String column,
    String declaration,
  ) async {
    final info = await database.rawQuery('PRAGMA table_info($table)');
    if (info.any((row) => row['name'] == column)) return;
    await database.execute(
      'ALTER TABLE $table ADD COLUMN $column $declaration',
    );
  }

  // Existing application data ----------------------------------------------

  Future<void> saveAnalysis(String assetId, Map<String, dynamic> data) async {
    final database = await db;
    await database.insert('media_analysis', {
      'id': assetId,
      ...data,
      'analyzed_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getAnalysis(String assetId) async {
    final database = await db;
    final results = await database.query(
      'media_analysis',
      where: 'id = ?',
      whereArgs: [assetId],
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<void> addSecureFile(String assetId) async {
    final database = await db;
    await database.insert('secure_files', {
      'id': assetId,
      'asset_id': assetId,
      'added_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeSecureFile(String assetId) async {
    final database = await db;
    await database.delete(
      'secure_files',
      where: 'asset_id = ?',
      whereArgs: [assetId],
    );
  }

  Future<List<String>> getSecureFileIds() async {
    final database = await db;
    final results = await database.query('secure_files');
    return results.map((row) => row['asset_id'] as String).toList();
  }

  // Search index ------------------------------------------------------------

  Future<void> saveSearchIndex(Map<String, dynamic> data) async {
    final database = await db;
    await database.insert(
      'search_index',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }


  /// Stores OCR extracted from the per-photo OCR screen in the same SQLite
  /// index used by gallery search. Existing YOLO/scene/face fields are kept.
  /// If the photo has not been AI-indexed yet, create a minimal searchable row
  /// that can later be replaced by the full indexer.
  Future<void> upsertManualOcr({
    required String assetId,
    required String title,
    required int takenAt,
    required int width,
    required int height,
    required String ocrText,
    required String ocrSearchText,
    required String ocrScriptsJson,
  }) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await database.rawInsert('''
      INSERT INTO search_index (
        asset_id, title, taken_at, width, height,
        ocr_text, ocr_search_text, ocr_scripts,
        indexed_at, model_version
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(asset_id) DO UPDATE SET
        ocr_text = excluded.ocr_text,
        ocr_search_text = excluded.ocr_search_text,
        ocr_scripts = excluded.ocr_scripts,
        indexed_at = excluded.indexed_at
    ''', [
      assetId,
      title,
      takenAt,
      width,
      height,
      ocrText,
      ocrSearchText,
      ocrScriptsJson,
      now,
      'manual-ocr-v1',
    ]);
  }

  Future<bool> hasSearchIndex(String assetId) async {
    final database = await db;
    final rows = await database.query(
      'search_index',
      columns: const ['asset_id'],
      where: 'asset_id = ?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<int> getIndexedCount() async {
    final database = await db;
    final result = await database.rawQuery(
      'SELECT COUNT(*) AS count FROM search_index',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<Set<String>> getIndexedAssetIds() async {
    final database = await db;
    final rows = await database.query(
      'search_index',
      columns: const ['asset_id'],
    );
    return rows.map((row) => row['asset_id'] as String).toSet();
  }

  Future<Set<String>> getPresentationIndexedAssetIds() async {
    final database = await db;
    final rows = await database.query(
      'search_index',
      columns: const ['asset_id'],
      where: "model_version LIKE 'presentation-v2.0.2:%'",
    );
    return rows.map((row) => row['asset_id'] as String).toSet();
  }

  Future<List<Map<String, dynamic>>> searchIndex(
    List<String> terms, {
    String scope = 'general',
    int limit = 250,
  }) {
    return searchIndexAdvanced(
      terms
          .map((term) => SearchIndexCondition(field: scope, value: term))
          .toList(growable: false),
      limit: limit,
    );
  }

  Future<List<Map<String, dynamic>>> searchIndexAdvanced(
    List<SearchIndexCondition> conditions, {
    int limit = 250,
  }) async {
    if (conditions.isEmpty) return const [];
    final database = await db;
    const personNames = '''
      (SELECT COALESCE(group_concat(pg.search_name, ' '), '')
       FROM person_assets pa
       JOIN person_groups pg ON pg.id = pa.person_id
       WHERE pa.asset_id = s.asset_id)
    ''';
    const personDisplayNames = '''
      (SELECT COALESCE(group_concat(pg.name, '، '), '')
       FROM person_assets pa
       JOIN person_groups pg ON pg.id = pa.person_id
       WHERE pa.asset_id = s.asset_id)
    ''';

    String sourceFor(String field) {
      return switch (field) {
        'people' => 'person_names',
        'ocr' => 'ocr_search_text',
        'objects' => 'objects',
        'colors' => 'colors',
        'scenes' => 'scenes',
        'date' => "metadata || ' ' || title",
        // Build the general source dynamically instead of relying on the old
        // searchable_text people snapshot. Renaming/merging a person therefore
        // affects search immediately without re-indexing the photo.
        _ =>
          "title || ' ' || objects || ' ' || scenes || ' ' || colors || ' ' || "
              "ocr_search_text || ' ' || metadata || ' ' || person_names",
      };
    }

    final whereParts = <String>[];
    final args = <Object?>[];
    for (final condition in conditions) {
      final value = condition.value.trim();
      if (value.isEmpty) continue;
      whereParts.add('${sourceFor(condition.field)} LIKE ?');
      args.add('%$value%');
    }
    if (whereParts.isEmpty) return const [];

    return database.rawQuery(
      '''
      SELECT * FROM (
        SELECT s.*,
               $personNames AS person_names,
               $personDisplayNames AS person_display_names
        FROM search_index s
      ) search_rows
      WHERE ${whereParts.join(' AND ')}
      ORDER BY taken_at DESC
      LIMIT ?
    ''',
      [...args, limit],
    );
  }

  Future<void> clearSearchIndex() async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('search_index');
      await txn.delete('index_queue');
      await txn.delete('face_instances');
      await txn.delete('face_scans');
      await txn.delete('face_rejections');
      await txn.delete('person_assets');
      await txn.delete('person_groups');
    });
  }

  // Persistent indexing queue ----------------------------------------------

  Future<void> enqueueAssets(
    Iterable<String> assetIds, {
    int priority = 0,
    bool force = false,
  }) async {
    // Preserve PhotoManager order (newest -> oldest). Previously every row in
    // the batch received the same timestamp, so SQLite was free to return ties
    // in any order and "full index" did not reliably begin with recent media.
    final orderedIds = <String>[];
    final seen = <String>{};
    for (final id in assetIds) {
      if (seen.add(id)) orderedIds.add(id);
    }
    if (orderedIds.isEmpty) return;

    final database = await db;
    // Rows from an older pipeline stay searchable, but are queued once for the
    // current pipeline version so new face/OCR fixes can be applied safely.
    final indexed = await getPresentationIndexedAssetIds();
    final baseTime = DateTime.now().millisecondsSinceEpoch;
    final batch = database.batch();
    var sequence = 0;
    for (final id in orderedIds) {
      if (!force && indexed.contains(id)) continue;
      final orderedTime = baseTime + sequence++;
      batch.insert('index_queue', {
        'asset_id': id,
        'state': 'pending',
        'priority': priority,
        'attempts': 0,
        'added_at': orderedTime,
        'updated_at': baseTime,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      // INSERT OR IGNORE used to throw away the higher priority assigned to
      // recent photos if the full-library queue already contained the row.
      // Promote existing pending rows as well, preserving the requested order.
      batch.rawUpdate(
        "UPDATE index_queue "
        "SET state = CASE WHEN state IN ('done', 'failed') THEN 'pending' ELSE state END, "
        "attempts = CASE WHEN state IN ('done', 'failed') THEN 0 ELSE attempts END, "
        "last_error = CASE WHEN state IN ('done', 'failed') THEN NULL ELSE last_error END, "
        "priority = CASE WHEN priority < ? THEN ? ELSE priority END, "
        "added_at = CASE WHEN state IN ('done', 'failed') OR priority < ? THEN ? ELSE added_at END, "
        "updated_at = ? "
        "WHERE asset_id = ? AND state != 'processing'",
        [priority, priority, priority, orderedTime, baseTime, id],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> getFailedQueueDetails({
    int limit = 20,
  }) async {
    final database = await db;
    return database.query(
      'index_queue',
      columns: const ['asset_id', 'attempts', 'last_error', 'updated_at'],
      where: "state = 'failed'",
      orderBy: 'updated_at DESC',
      limit: limit,
    );
  }

  Future<void> resetStaleQueue() async {
    final database = await db;
    final staleBefore = DateTime.now()
        .subtract(const Duration(minutes: 12))
        .millisecondsSinceEpoch;
    await database.update(
      'index_queue',
      {'state': 'pending', 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: "state = 'processing' AND updated_at < ?",
      whereArgs: [staleBefore],
    );
  }

  Future<List<String>> claimPendingAssets({
    int limit = 12,
    int? minPriority,
  }) async {
    final database = await db;
    await resetStaleQueue();
    return database.transaction((txn) async {
      final rows = await txn.query(
        'index_queue',
        columns: const ['asset_id'],
        where: minPriority == null
            ? "state = 'pending'"
            : "state = 'pending' AND priority >= ?",
        whereArgs: minPriority == null ? null : [minPriority],
        orderBy: 'priority DESC, added_at ASC',
        limit: limit,
      );
      final ids = rows.map((row) => row['asset_id'] as String).toList();
      if (ids.isEmpty) return const <String>[];
      final placeholders = List.filled(ids.length, '?').join(',');
      await txn.rawUpdate(
        "UPDATE index_queue SET state = 'processing', updated_at = ? WHERE asset_id IN ($placeholders)",
        [DateTime.now().millisecondsSinceEpoch, ...ids],
      );
      return ids;
    });
  }

  Future<void> markQueueDone(String assetId) async {
    final database = await db;
    await database.update(
      'index_queue',
      {
        'state': 'done',
        'last_error': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'asset_id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> releaseQueueAssets(Iterable<String> assetIds) async {
    final ids = assetIds.toList(growable: false);
    if (ids.isEmpty) return;
    final database = await db;
    final placeholders = List.filled(ids.length, '?').join(',');
    await database.rawUpdate(
      "UPDATE index_queue SET state = 'pending', updated_at = ? WHERE state = 'processing' AND asset_id IN ($placeholders)",
      [DateTime.now().millisecondsSinceEpoch, ...ids],
    );
  }

  Future<void> markQueueFailed(String assetId, Object error) async {
    final database = await db;
    await database.rawUpdate(
      '''
      UPDATE index_queue
      SET attempts = attempts + 1,
          state = CASE WHEN attempts + 1 >= 3 THEN 'failed' ELSE 'pending' END,
          last_error = ?, updated_at = ?
      WHERE asset_id = ?
    ''',
      [error.toString(), DateTime.now().millisecondsSinceEpoch, assetId],
    );
  }

  Future<int> getPendingQueueCount({int? minPriority}) async {
    final database = await db;
    final result = minPriority == null
        ? await database.rawQuery(
            "SELECT COUNT(*) FROM index_queue WHERE state IN ('pending', 'processing')",
          )
        : await database.rawQuery(
            "SELECT COUNT(*) FROM index_queue "
            "WHERE state IN ('pending', 'processing') AND priority >= ?",
            [minPriority],
          );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> retryFailedQueue() async {
    final database = await db;
    await database.update('index_queue', {
      'state': 'pending',
      'attempts': 0,
      'last_error': null,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, where: "state = 'failed'");
  }

  Future<int> startIndexRun(String mode) async {
    final database = await db;
    return database.insert('index_runs', {
      'mode': mode,
      'started_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> finishIndexRun(
    int runId, {
    required int processed,
    required int failed,
    String? note,
  }) async {
    final database = await db;
    await database.update(
      'index_runs',
      {
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'processed': processed,
        'failed': failed,
        'note': note,
      },
      where: 'id = ?',
      whereArgs: [runId],
    );
  }

  // People and face clustering ---------------------------------------------

  Future<bool> hasFacesForAsset(String assetId) async {
    final database = await db;
    final rows = await database.query(
      'face_instances',
      columns: const ['id'],
      where: 'asset_id = ?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> hasFaceScan(String assetId) async {
    final database = await db;
    final rows = await database.query(
      'face_scans',
      columns: const ['asset_id'],
      where: 'asset_id = ?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<String> getFaceScanVersion(String assetId) async {
    final database = await db;
    final rows = await database.query(
      'face_scans',
      columns: const ['pipeline_version'],
      where: 'asset_id = ?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isEmpty ? '' : rows.first['pipeline_version']?.toString() ?? '';
  }

  Future<int> getFaceScanCount(String assetId) async {
    final database = await db;
    final rows = await database.query(
      'face_scans',
      columns: const ['face_count'],
      where: 'asset_id = ?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isEmpty ? 0 : (rows.first['face_count'] as num?)?.toInt() ?? 0;
  }

  Future<int> getFaceInstanceCount(String assetId) async {
    final database = await db;
    final rows = await database.rawQuery(
      'SELECT COUNT(*) FROM face_instances WHERE asset_id = ?',
      [assetId],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> markFaceScanned(
    String assetId,
    int faceCount, {
    String pipelineVersion = '',
  }) async {
    final database = await db;
    await database.insert('face_scans', {
      'asset_id': assetId,
      'scanned_at': DateTime.now().millisecondsSinceEpoch,
      'face_count': faceCount,
      'pipeline_version': pipelineVersion,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Lightweight face signals for the For You ranking.
  ///
  /// This only reads results that the smart-search face pipeline has already
  /// stored. It never runs ML Kit or MobileFaceNet from the suggestions screen,
  /// so opening For You does not add AI load or battery pressure.
  Future<Map<String,
      ({int faceCount, double bestQuality, double bestPose, double bestArea})>>
      getFaceSuggestionSignals(Iterable<String> assetIds) async {
    final ids = assetIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};

    final database = await db;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await database.rawQuery('''
      SELECT
        fs.asset_id AS asset_id,
        fs.face_count AS face_count,
        COALESCE(MAX(fi.quality_score), 0) AS best_quality,
        COALESCE(MAX(fi.pose_score), 0) AS best_pose,
        COALESCE(MAX(
          (fi.bbox_right - fi.bbox_left) *
          (fi.bbox_bottom - fi.bbox_top)
        ), 0) AS best_area
      FROM face_scans fs
      LEFT JOIN face_instances fi ON fi.asset_id = fs.asset_id
      WHERE fs.asset_id IN ($placeholders)
      GROUP BY fs.asset_id, fs.face_count
    ''', ids);

    final result = <
        String,
        ({int faceCount, double bestQuality, double bestPose, double bestArea})>{};
    for (final row in rows) {
      final assetId = row['asset_id']?.toString();
      if (assetId == null) continue;
      result[assetId] = (
        faceCount: (row['face_count'] as num?)?.toInt() ?? 0,
        bestQuality: (row['best_quality'] as num?)?.toDouble() ?? 0,
        bestPose: (row['best_pose'] as num?)?.toDouble() ?? 0,
        bestArea: (row['best_area'] as num?)?.toDouble() ?? 0,
      );
    }
    return result;
  }

  /// Visible People albums require at least three distinct photos. A person the
  /// user explicitly named remains visible even with fewer photos.
  Future<List<PersonGroup>> getPersonGroupsDetailed({
    bool visibleOnly = true,
  }) async {
    final database = await db;
    final having = visibleOnly
        ? 'HAVING pg.is_named = 1 OR COUNT(DISTINCT pa.asset_id) >= 3'
        : '';
    final rows = await database.rawQuery('''
      SELECT pg.*, COUNT(DISTINCT pa.asset_id) AS photo_count
      FROM person_groups pg
      LEFT JOIN person_assets pa ON pa.person_id = pg.id
      GROUP BY pg.id
      $having
      ORDER BY pg.is_named DESC, photo_count DESC, pg.updated_at DESC
    ''');
    return rows.map(PersonGroup.fromDatabase).toList(growable: false);
  }

  Future<int> getCandidatePersonCount() async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT COUNT(*) FROM (
        SELECT pg.id
        FROM person_groups pg
        LEFT JOIN person_assets pa ON pa.person_id = pg.id
        WHERE pg.is_named = 0
        GROUP BY pg.id
        HAVING COUNT(DISTINCT pa.asset_id) < 3
      )
    ''');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<PersonGroup?> getPersonGroup(String personId) async {
    final database = await db;
    final rows = await database.rawQuery(
      '''
      SELECT pg.*, COUNT(DISTINCT pa.asset_id) AS photo_count
      FROM person_groups pg
      LEFT JOIN person_assets pa ON pa.person_id = pg.id
      WHERE pg.id = ?
      GROUP BY pg.id LIMIT 1
    ''',
      [personId],
    );
    return rows.isEmpty ? null : PersonGroup.fromDatabase(rows.first);
  }

  Future<List<PersonGroup>> getPeopleForAsset(String assetId) async {
    final database = await db;
    final rows = await database.rawQuery(
      '''
      SELECT pg.*, COUNT(DISTINCT all_pa.asset_id) AS photo_count
      FROM person_assets selected
      JOIN person_groups pg ON pg.id = selected.person_id
      LEFT JOIN person_assets all_pa ON all_pa.person_id = pg.id
      WHERE selected.asset_id = ?
      GROUP BY pg.id
      ORDER BY pg.is_named DESC, pg.name
    ''',
      [assetId],
    );
    return rows.map(PersonGroup.fromDatabase).toList(growable: false);
  }

  Future<int> nextUnnamedPersonNumber() async {
    final database = await db;
    final result = await database.rawQuery(
      'SELECT COUNT(*) FROM person_groups WHERE is_named = 0',
    );
    return (Sqflite.firstIntValue(result) ?? 0) + 1;
  }

  /// Returns the strongest individual face embeddings per cluster. Comparing a
  /// new face with several exemplars is more robust than a single drifting
  /// centroid when pose or lighting changes.
  Future<Map<String, List<List<double>>>> getPersonPrototypeEmbeddings({
    int perPerson = 5,
    double minQuality = 0.25,
  }) async {
    final database = await db;
    final rows = await database.query(
      'face_instances',
      columns: const ['person_id', 'embedding', 'quality_score'],
      where: "embedding != '[]' AND quality_score >= ?",
      whereArgs: [minQuality],
      orderBy: 'person_id ASC, quality_score DESC, created_at DESC',
    );
    final result = <String, List<List<double>>>{};
    for (final row in rows) {
      final personId = row['person_id']?.toString();
      if (personId == null) continue;
      final list = result.putIfAbsent(personId, () => <List<double>>[]);
      if (list.length >= perPerson) continue;
      final embedding = PersonGroup.decodeEmbedding(row['embedding']);
      if (embedding.isNotEmpty) list.add(embedding);
    }
    return result;
  }

  Future<bool> peopleShareAnyAsset(
    String firstPersonId,
    String secondPersonId,
  ) async {
    final database = await db;
    final rows = await database.rawQuery(
      '''
      SELECT 1
      FROM person_assets a
      JOIN person_assets b ON b.asset_id = a.asset_id
      WHERE a.person_id = ? AND b.person_id = ?
      LIMIT 1
    ''',
      [firstPersonId, secondPersonId],
    );
    return rows.isNotEmpty;
  }

  Future<Set<String>> getRejectedPersonIds(String assetId) async {
    final database = await db;
    final rows = await database.query(
      'face_rejections',
      columns: const ['person_id'],
      where: 'asset_id = ?',
      whereArgs: [assetId],
    );
    return rows
        .map((row) => row['person_id']?.toString())
        .whereType<String>()
        .toSet();
  }

  /// Removes stale face rows for one photo before the v2.1 pipeline re-runs.
  /// Other AI index fields stay untouched.
  Future<void> prepareAssetFaceReanalysis(String assetId) async {
    final database = await db;
    final affected = await database.query(
      'face_instances',
      distinct: true,
      columns: const ['person_id'],
      where: 'asset_id = ?',
      whereArgs: [assetId],
    );
    final personIds = affected
        .map((row) => row['person_id']?.toString())
        .whereType<String>()
        .toList(growable: false);

    await database.transaction((txn) async {
      await txn.delete(
        'face_instances',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
      await txn.delete(
        'person_assets',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
      await txn.delete(
        'face_scans',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
    });
    for (final personId in personIds) {
      await _recomputePersonGroup(database, personId);
    }
  }

  Future<void> saveRecognizedFace({
    required String faceKey,
    required String assetId,
    required String personId,
    required String initialName,
    required String searchName,
    required List<double> centroid,
    required List<double> embedding,
    required int sampleCount,
    required double left,
    required double top,
    required double right,
    required double bottom,
    required double confidence,
    required double qualityScore,
    required double poseScore,
    required Uint8List faceCropJpeg,
    required String pipelineVersion,
    required bool isNewPerson,
  }) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await database.transaction((txn) async {
      if (isNewPerson) {
        await txn.insert('person_groups', {
          'id': personId,
          'name': initialName,
          'search_name': searchName,
          'cover_asset_id': assetId,
          'cover_face_key': faceKey,
          'cover_face_jpeg': faceCropJpeg,
          'cover_quality': qualityScore,
          'centroid': jsonEncode(centroid),
          'sample_count': sampleCount,
          'is_named': 0,
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      final inserted = await txn.rawInsert(
        '''
        INSERT OR REPLACE INTO face_instances (
          face_key, asset_id, person_id, bbox_left, bbox_top,
          bbox_right, bbox_bottom, confidence, embedding, quality_score,
          pose_score, face_crop_jpeg, pipeline_version, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        [
          faceKey,
          assetId,
          personId,
          left,
          top,
          right,
          bottom,
          confidence,
          jsonEncode(embedding),
          qualityScore,
          poseScore,
          faceCropJpeg,
          pipelineVersion,
          now,
        ],
      );

      await txn.insert('person_assets', {
        'person_id': personId,
        'asset_id': assetId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      if (!isNewPerson && inserted != 0) {
        final current = await txn.query(
          'person_groups',
          columns: const ['cover_quality'],
          where: 'id = ?',
          whereArgs: [personId],
          limit: 1,
        );
        final oldCoverQuality = current.isEmpty
            ? 0.0
            : (current.first['cover_quality'] as num?)?.toDouble() ?? 0.0;
        final update = <String, Object?>{
          'centroid': jsonEncode(centroid),
          'sample_count': sampleCount,
          'updated_at': now,
        };
        if (faceCropJpeg.isNotEmpty && qualityScore > oldCoverQuality) {
          update.addAll({
            'cover_asset_id': assetId,
            'cover_face_key': faceKey,
            'cover_face_jpeg': faceCropJpeg,
            'cover_quality': qualityScore,
          });
        }
        await txn.update(
          'person_groups',
          update,
          where: 'id = ?',
          whereArgs: [personId],
        );
      }
    });
  }

  Future<void> renamePerson(
    String personId,
    String name,
    String normalizedName,
  ) async {
    final database = await db;
    await database.update(
      'person_groups',
      {
        'name': name.trim(),
        'search_name': normalizedName,
        'is_named': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [personId],
    );
  }

  /// Explicit user merge. The target survives; if only the source was named,
  /// its name is preserved on the surviving group.
  Future<void> mergePersons(String targetId, String sourceId) async {
    if (targetId == sourceId) return;
    final database = await db;
    final targetRows = await database.query(
      'person_groups',
      where: 'id = ?',
      whereArgs: [targetId],
      limit: 1,
    );
    final sourceRows = await database.query(
      'person_groups',
      where: 'id = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    if (targetRows.isEmpty || sourceRows.isEmpty) return;
    final target = targetRows.first;
    final source = sourceRows.first;
    final targetNamed = ((target['is_named'] as num?)?.toInt() ?? 0) == 1;
    final sourceNamed = ((source['is_named'] as num?)?.toInt() ?? 0) == 1;

    await database.transaction((txn) async {
      await txn.update(
        'face_instances',
        {'person_id': targetId},
        where: 'person_id = ?',
        whereArgs: [sourceId],
      );
      await txn.rawInsert(
        '''
        INSERT OR IGNORE INTO person_assets(person_id, asset_id)
        SELECT ?, asset_id FROM person_assets WHERE person_id = ?
      ''',
        [targetId, sourceId],
      );
      await txn.delete(
        'person_assets',
        where: 'person_id = ?',
        whereArgs: [sourceId],
      );

      await txn.rawInsert(
        '''
        INSERT OR IGNORE INTO face_rejections(asset_id, person_id, created_at)
        SELECT asset_id, ?, created_at
        FROM face_rejections WHERE person_id = ?
      ''',
        [targetId, sourceId],
      );
      await txn.delete(
        'face_rejections',
        where: 'person_id = ?',
        whereArgs: [sourceId],
      );

      if (!targetNamed && sourceNamed) {
        await txn.update(
          'person_groups',
          {
            'name': source['name'],
            'search_name': source['search_name'],
            'is_named': 1,
          },
          where: 'id = ?',
          whereArgs: [targetId],
        );
      }
      await txn.delete('person_groups', where: 'id = ?', whereArgs: [sourceId]);
    });
    await _recomputePersonGroup(database, targetId);
  }

  /// Marks an image as not belonging to this person. The next face pass for
  /// that photo will not assign any of its faces back to the rejected cluster.
  Future<void> removeAssetFromPerson(String personId, String assetId) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await database.transaction((txn) async {
      await txn.insert('face_rejections', {
        'asset_id': assetId,
        'person_id': personId,
        'created_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.delete(
        'face_instances',
        where: 'person_id = ? AND asset_id = ?',
        whereArgs: [personId, assetId],
      );
      await txn.delete(
        'person_assets',
        where: 'person_id = ? AND asset_id = ?',
        whereArgs: [personId, assetId],
      );
      await txn.delete(
        'face_scans',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
    });
    await _recomputePersonGroup(database, personId);
  }

  /// Start a clean v2.1 clustering pass without touching YOLO/OCR/search data.
  /// Named identities are kept as optional anchors so user labels are not
  /// discarded; unnamed development clusters are rebuilt from scratch.
  Future<void> resetPeopleForRebuild({bool preserveNamed = true}) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('face_instances');
      await txn.delete('face_scans');
      await txn.delete('person_assets');
      if (preserveNamed) {
        await txn.delete(
          'face_rejections',
          where:
              'person_id IN (SELECT id FROM person_groups WHERE is_named = 0)',
        );
        await txn.delete('person_groups', where: 'is_named = 0');
        await txn.rawUpdate(
          '''
          UPDATE person_groups
          SET cover_asset_id = NULL,
              cover_face_key = NULL,
              cover_face_jpeg = NULL,
              cover_quality = 0,
              sample_count = CASE WHEN centroid = '[]' THEN 0 ELSE 1 END,
              updated_at = ?
          WHERE is_named = 1
        ''',
          [DateTime.now().millisecondsSinceEpoch],
        );
      } else {
        await txn.delete('face_rejections');
        await txn.delete('person_groups');
      }
    });
  }

  /// Rebuild exact centroids/covers from the stored per-face embeddings.
  /// This removes rolling-centroid drift before duplicate-cluster refinement.
  Future<void> recomputeAllPersonGroups() async {
    final database = await db;
    final rows = await database.query('person_groups', columns: const ['id']);
    for (final row in rows) {
      final personId = row['id']?.toString();
      if (personId == null || personId.isEmpty) continue;
      await _recomputePersonGroup(database, personId);
    }
  }

  Future<List<String>> getIndexedAssetIdsOrdered() async {
    final database = await db;
    final rows = await database.query(
      'search_index',
      columns: const ['asset_id'],
      orderBy: 'taken_at DESC',
    );
    return rows.map((row) => row['asset_id'] as String).toList(growable: false);
  }

  Future<void> _recomputePersonGroup(
    DatabaseExecutor database,
    String personId,
  ) async {
    final groupRows = await database.query(
      'person_groups',
      where: 'id = ?',
      whereArgs: [personId],
      limit: 1,
    );
    if (groupRows.isEmpty) return;
    final group = groupRows.first;
    final named = ((group['is_named'] as num?)?.toInt() ?? 0) == 1;

    final rows = await database.query(
      'face_instances',
      columns: const [
        'asset_id',
        'face_key',
        'embedding',
        'quality_score',
        'face_crop_jpeg',
      ],
      where: 'person_id = ?',
      whereArgs: [personId],
      orderBy: 'quality_score DESC, created_at DESC',
    );

    await database.delete(
      'person_assets',
      where: 'person_id = ?',
      whereArgs: [personId],
    );
    final assetIds = <String>{};
    for (final row in rows) {
      final assetId = row['asset_id']?.toString();
      if (assetId != null) assetIds.add(assetId);
    }
    for (final assetId in assetIds) {
      await database.insert('person_assets', {
        'person_id': personId,
        'asset_id': assetId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final embeddings = rows
        .map((row) => PersonGroup.decodeEmbedding(row['embedding']))
        .where((embedding) => embedding.isNotEmpty)
        .toList(growable: false);

    if (embeddings.isEmpty) {
      if (!named) {
        await database.delete(
          'person_groups',
          where: 'id = ?',
          whereArgs: [personId],
        );
        return;
      }
      await database.update(
        'person_groups',
        {
          'sample_count': group['centroid']?.toString() == '[]' ? 0 : 1,
          'cover_asset_id': null,
          'cover_face_key': null,
          'cover_face_jpeg': null,
          'cover_quality': 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [personId],
      );
      return;
    }

    final dimensions = embeddings.first.length;
    final mean = List<double>.filled(dimensions, 0);
    var used = 0;
    for (final embedding in embeddings) {
      if (embedding.length != dimensions) continue;
      used++;
      for (var index = 0; index < dimensions; index++) {
        mean[index] += embedding[index];
      }
    }
    if (used > 0) {
      for (var index = 0; index < dimensions; index++) {
        mean[index] /= used;
      }
    }
    final centroid = _normalizeVector(mean);
    final best = rows.first;
    await database.update(
      'person_groups',
      {
        'centroid': jsonEncode(centroid),
        'sample_count': embeddings.length,
        'cover_asset_id': best['asset_id'],
        'cover_face_key': best['face_key'],
        'cover_face_jpeg': best['face_crop_jpeg'],
        'cover_quality': (best['quality_score'] as num?)?.toDouble() ?? 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [personId],
    );
  }

  List<double> _normalizeVector(List<double> values) {
    final norm = math.sqrt(
      values.fold<double>(0, (sum, value) => sum + value * value),
    );
    if (norm == 0) return values;
    return values.map((value) => value / norm).toList(growable: false);
  }

  // Compatibility methods used by the original project.
  Future<void> savePersonGroup(String id, String name, String? coverId) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await database.insert('person_groups', {
      'id': id,
      'name': name,
      'search_name': name.toLowerCase(),
      'cover_asset_id': coverId,
      'created_at': now,
      'updated_at': now,
      'is_named': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> addAssetToPerson(String personId, String assetId) async {
    final database = await db;
    await database.insert('person_assets', {
      'person_id': personId,
      'asset_id': assetId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> getPersonGroups() async {
    final people = await getPersonGroupsDetailed();
    return people
        .map(
          (person) => <String, dynamic>{
            'id': person.id,
            'name': person.name,
            'cover_asset_id': person.coverAssetId,
            'photo_count': person.photoCount,
          },
        )
        .toList(growable: false);
  }

  Future<List<String>> getPersonAssetIds(String personId) async {
    final database = await db;
    final results = await database.rawQuery(
      '''
      SELECT pa.asset_id
      FROM person_assets pa
      LEFT JOIN search_index s ON s.asset_id = pa.asset_id
      WHERE pa.person_id = ?
      ORDER BY s.taken_at DESC
    ''',
      [personId],
    );
    return results.map((row) => row['asset_id'] as String).toList();
  }


  /// Real smart-album suggestions derived from the existing offline AI index.
  /// No model is run here; this is only a cheap read over labels/OCR already
  /// stored by YOLO/scene/OCR indexing.
  Future<List<String>> getSuggestedAlbumAssetIds(
    String key, {
    int limit = 240,
  }) async {
    final database = await db;
    late final String where;
    late final List<Object?> args;

    switch (key) {
      case 'nature':
        const terms = [
          'tree', 'plant', 'flower', 'forest', 'grass', 'mountain',
          'sky', 'outdoor', 'landscape', 'garden',
        ];
        where = terms
            .map((_) => '(LOWER(objects) LIKE ? OR LOWER(scenes) LIKE ?)')
            .join(' OR ');
        args = [
          for (final term in terms) ...['%$term%', '%$term%'],
        ];
        break;
      case 'documents':
        // Text-rich and document-like, not merely a photo containing one word.
        const photoSubjectTerms = [
          'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus',
          'train', 'truck', 'boat', 'bird', 'cat', 'dog', 'horse', 'sheep',
          'cow', 'elephant', 'bear', 'zebra', 'giraffe', 'sports ball',
          'kite', 'skateboard', 'surfboard', 'tennis racket', 'banana',
          'apple', 'sandwich', 'orange', 'broccoli', 'carrot', 'hot dog',
          'pizza', 'donut', 'cake',
        ];
        final exclusions = photoSubjectTerms
            .map((_) => 'LOWER(objects) NOT LIKE ?')
            .join(' AND ');
        where = '''
          LENGTH(TRIM(COALESCE(ocr_text, ''))) >= ?
          AND (
            LENGTH(COALESCE(ocr_text, '')) -
            LENGTH(REPLACE(COALESCE(ocr_text, ''), ' ', ''))
          ) >= ?
          AND COALESCE(face_count, 0) = 0
          AND $exclusions
        ''';
        args = [
          45,
          4,
          for (final term in photoSubjectTerms) '%$term%',
        ];
        break;
      case 'food':
        const terms = [
          'food', 'pizza', 'sandwich', 'hot dog', 'cake', 'donut',
          'banana', 'apple', 'orange', 'broccoli', 'carrot', 'dining table',
          'cup', 'bowl',
        ];
        where = terms
            .map((_) => '(LOWER(objects) LIKE ? OR LOWER(scenes) LIKE ?)')
            .join(' OR ');
        args = [
          for (final term in terms) ...['%$term%', '%$term%'],
        ];
        break;
      case 'pets':
        const terms = ['cat', 'dog', 'bird', 'horse'];
        where = terms.map((_) => 'LOWER(objects) LIKE ?').join(' OR ');
        args = [for (final term in terms) '%$term%'];
        break;
      default:
        return const [];
    }

    final rows = await database.query(
      'search_index',
      columns: const ['asset_id'],
      where: where,
      whereArgs: args,
      orderBy: 'taken_at DESC',
      limit: limit,
    );
    return rows
        .map((row) => row['asset_id']?.toString())
        .whereType<String>()
        .toList(growable: false);
  }

  // Dashboard ---------------------------------------------------------------

  Future<IndexDashboardStats> getDashboardStats({
    required int totalImages,
  }) async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM search_index) AS indexed_images,
        (SELECT COUNT(*) FROM index_queue WHERE state IN ('pending', 'processing')) AS queued_images,
        (SELECT COUNT(*) FROM index_queue WHERE state = 'failed') AS failed_images,
        (SELECT COALESCE(SUM(face_count), 0) FROM face_scans) AS detected_faces,
        (SELECT COUNT(*) FROM person_groups pg
         WHERE pg.is_named = 1 OR
               (SELECT COUNT(DISTINCT pa.asset_id)
                FROM person_assets pa WHERE pa.person_id = pg.id) >= 3) AS people,
        (SELECT COUNT(*) FROM person_groups WHERE is_named = 1) AS named_people,
        (SELECT COUNT(*) FROM search_index WHERE ocr_scripts LIKE '%arabic%') AS arabic_ocr_images,
        (SELECT MAX(finished_at) FROM index_runs) AS last_run_at
    ''');
    final row = rows.first;
    int value(String key) => (row[key] as num?)?.toInt() ?? 0;
    final lastRunRaw = (row['last_run_at'] as num?)?.toInt();
    return IndexDashboardStats(
      totalImages: totalImages,
      indexedImages: value('indexed_images'),
      queuedImages: value('queued_images'),
      failedImages: value('failed_images'),
      detectedFaces: value('detected_faces'),
      people: value('people'),
      namedPeople: value('named_people'),
      arabicOcrImages: value('arabic_ocr_images'),
      lastRunAt: lastRunRaw == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastRunRaw),
    );
  }
}

class SearchIndexCondition {
  final String field;
  final String value;

  const SearchIndexCondition({required this.field, required this.value});
}
