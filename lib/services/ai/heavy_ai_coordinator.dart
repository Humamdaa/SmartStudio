import 'dart:async';

import '../../data/database/db_helper.dart';

/// Coordinates CPU-heavy local AI stages across the foreground app and
/// WorkManager background isolates.
///
/// The lease lives in SQLite rather than a Dart singleton, so a background
/// worker and the visible app cannot accidentally run Face, YOLO/OCR and
/// visual embeddings at full speed at the same time.
class HeavyAiCoordinator {
  HeavyAiCoordinator._();
  static final HeavyAiCoordinator instance = HeavyAiCoordinator._();

  final DatabaseHelper _database = DatabaseHelper.instance;

  Future<HeavyAiLease?> acquire({
    required String task,
    bool wait = true,
    Duration maxWait = const Duration(seconds: 25),
  }) async {
    final owner =
        '$task:${DateTime.now().microsecondsSinceEpoch}:${identityHashCode(this)}';
    final deadline = DateTime.now().add(maxWait);

    while (true) {
      final acquired = await _database.tryAcquireAiWorkLease(owner: owner);
      if (acquired) {
        return HeavyAiLease._(_database, owner);
      }
      if (!wait || DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
  }
}

class HeavyAiLease {
  HeavyAiLease._(this._database, this.owner);

  final DatabaseHelper _database;
  final String owner;
  bool _released = false;

  Future<void> refresh() => _database.refreshAiWorkLease(owner);

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _database.releaseAiWorkLease(owner);
  }
}
