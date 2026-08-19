import 'package:shared_preferences/shared_preferences.dart';

class AppPrefs {
  AppPrefs._();
  static final AppPrefs instance = AppPrefs._();

  static const _keyFirstLaunch = 'first_launch';
  static const _keyGridColumns = 'grid_columns';
  static const _keyThemeMode = 'theme_mode'; // 'light' | 'dark' | 'system'
  static const _keyBackgroundIndexing = 'background_indexing_enabled';
  static const _keyBackgroundFaceIndexing = 'background_face_indexing_enabled';
  static const _keyArabicOcr = 'arabic_ocr_enabled';
  static const _keyVideoIndexing = 'smart_video_indexing_enabled';

  Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  Future<bool> get isFirstLaunch async =>
      (await _p).getBool(_keyFirstLaunch) ?? true;

  Future<void> markLaunched() async =>
      (await _p).setBool(_keyFirstLaunch, false);

  // ── Grid Columns ──────────────────────────────
  Future<int> get gridColumns async => (await _p).getInt(_keyGridColumns) ?? 3;

  Future<void> setGridColumns(int n) async =>
      (await _p).setInt(_keyGridColumns, n);

  Future<String> get themeMode async =>
      (await _p).getString(_keyThemeMode) ?? 'system';

  Future<void> setThemeMode(String mode) async =>
      (await _p).setString(_keyThemeMode, mode);

  Future<bool> get backgroundIndexingEnabled async =>
      (await _p).getBool(_keyBackgroundIndexing) ?? false;

  Future<void> setBackgroundIndexingEnabled(bool enabled) async =>
      (await _p).setBool(_keyBackgroundIndexing, enabled);

  Future<bool> get backgroundFaceIndexingEnabled async =>
      (await _p).getBool(_keyBackgroundFaceIndexing) ?? false;

  Future<void> setBackgroundFaceIndexingEnabled(bool enabled) async =>
      (await _p).setBool(_keyBackgroundFaceIndexing, enabled);

  Future<bool> get arabicOcrEnabled async =>
      (await _p).getBool(_keyArabicOcr) ?? true;

  Future<void> setArabicOcrEnabled(bool enabled) async =>
      (await _p).setBool(_keyArabicOcr, enabled);

  Future<bool> get videoIndexingEnabled async =>
      (await _p).getBool(_keyVideoIndexing) ?? true;

  Future<void> setVideoIndexingEnabled(bool enabled) async =>
      (await _p).setBool(_keyVideoIndexing, enabled);
}
