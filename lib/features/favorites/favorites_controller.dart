import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Favorites = a virtual album of asset IDs, persisted with SharedPreferences.
/// Works for both photos and videos.
class FavoritesController extends StateNotifier<Set<String>> {
  FavoritesController() : super(const {}) {
    _load();
  }

  static const _key = 'favorite_asset_ids';

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    state = (p.getStringList(_key) ?? const <String>[]).toSet();
  }

  bool isFavorite(String id) => state.contains(id);

  Future<void> toggle(String id) async {
    final next = Set<String>.from(state);
    if (!next.remove(id)) next.add(id);
    await _persist(next);
  }

  /// يشيل صور ما عادت موجودة على الجهاز (انحذفت أو انتقلت للمجلد الآمن).
  /// بدونها كان العدّاد يضل يحسب صور مش موجودة.
  Future<void> removeMissing(Set<String> missingIds) async {
    if (missingIds.isEmpty) return;
    final next = Set<String>.from(state)..removeAll(missingIds);
    if (next.length == state.length) return;
    await _persist(next);
  }

  Future<void> _persist(Set<String> next) async {
    state = next;
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_key, next.toList());
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesController, Set<String>>(
  (ref) => FavoritesController(),
);
