import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'data/database/objectbox/objectbox_store.dart';
import 'services/secure_storage_service.dart';
import 'services/gallery/background_indexer.dart';

final objectBoxProvider = Provider<ObjectBoxStore>((ref) {
  throw UnimplementedError('Override in main()');
});

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundIndexService.instance.initialize();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  final obStore = await ObjectBoxStore.create();

  // لازم قبل أي استخدام للمجلد الآمن: ينشئ مجلد secure/ وملف .nomedia
  await SecureStorageService.instance.init();

  runApp(
    ProviderScope(
      overrides: [objectBoxProvider.overrideWithValue(obStore)],
      child: PixMindApp(),
    ),
  );
}
