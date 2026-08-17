import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart';
import '../../services/indexing_service.dart';

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
