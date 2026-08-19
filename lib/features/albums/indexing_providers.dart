import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart';
import '../../services/indexing_service.dart';
import '../../services/smart_search_bridge.dart';
import '../../services/gallery/complete_smart_index_service.dart';
import '../visual_search/visual_embedding_service.dart';
import '../visual_search/visual_search_indexer.dart';
import '../visual_search/visual_search_repository.dart';
import '../../data/repositories/media_repository.dart';

/// خدمة الفهرسة — واحدة لكل التطبيق حتى ما يصير تحليل مزدوج.
final indexingServiceProvider = Provider<IndexingService>(
  (ref) => IndexingService(ref.read(objectBoxProvider)),
);

/// تقدّم الفهرسة الحيّ — الواجهة بتراقبه وتحدّث نفسها.
final indexProgressProvider = StreamProvider<IndexProgress>((ref) {
  final svc = ref.read(indexingServiceProvider);
  final controller = StreamController<IndexProgress>();

  void listener() => controller.add(svc.progress.value);
  svc.progress.addListener(listener);
  controller.add(svc.progress.value);

  ref.onDispose(() {
    svc.progress.removeListener(listener);
    controller.close();
  });

  return controller.stream;
});

/// يشغّل الفهرسة التلقائية مرة وحدة بعمر التطبيق.
///
/// المستخدم ما لازم يضغط أي زر — أول ما يفتح المعرض وتكون
/// الأذونات جاهزة، منبلّش نفهرس بالخلفية بهدوء.
class AutoIndexStarter {
  AutoIndexStarter(this._ref);
  final Ref _ref;

  bool _started = false;

  void startOnce() {
    if (_started) return;
    _started = true;

    // منأخّر شوي حتى تخلص الشاشة الرئيسية تحميلها الأول،
    // فما نتزاحم معها على الموارد.
    Future.delayed(const Duration(seconds: 3), () {
      _ref.read(indexingServiceProvider).indexLibrary(background: true);
    });
  }
}

final autoIndexStarterProvider = Provider<AutoIndexStarter>(
  (ref) => AutoIndexStarter(ref),
);


/// App-lifetime visual embedding engine.
///
/// Keeping this provider outside SearchScreen means leaving the Search tab no
/// longer closes the TFLite interpreters while Complete Smart Index is in its
/// Visual stage.
final visualEmbeddingServiceProvider = Provider<VisualEmbeddingService>((ref) {
  final service = VisualEmbeddingService();
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

/// Shared local repository for visual embeddings.
final visualSearchRepositoryProvider = Provider<VisualSearchRepository>(
  (ref) => VisualSearchRepository(),
);

/// App-lifetime visual indexer used by both manual Visual indexing and the
/// five-stage Smart Index orchestrator.
final visualSearchIndexerProvider = Provider<VisualSearchIndexer>((ref) {
  return VisualSearchIndexer(
    embeddingService: ref.read(visualEmbeddingServiceProvider),
    repository: ref.read(visualSearchRepositoryProvider),
    mediaRepository: MediaRepository(),
  );
});

/// App-level Complete/Continue Smart Index.
///
/// This is deliberately a normal (non-autoDispose) provider. Once created it
/// belongs to the root ProviderScope, not to SearchScreen, so switching Home / 
/// Search / Albums / For You cannot stop the current Smart Index pipeline.
/// Progress and completed work remain available when Search is opened again.
final completeSmartIndexServiceProvider = Provider<CompleteSmartIndexService>((ref) {
  return CompleteSmartIndexService(
    galleryIndexer: ref.read(indexingServiceProvider),
    contentBridge: SmartSearchBridge(),
    visualIndexer: ref.read(visualSearchIndexerProvider),
    visualRepository: ref.read(visualSearchRepositoryProvider),
    mediaRepository: MediaRepository(),
  );
});
