class IndexDashboardStats {
  final int totalImages;
  final int indexedImages;
  final int queuedImages;
  final int failedImages;
  final int detectedFaces;
  final int people;
  final int namedPeople;
  final int arabicOcrImages;
  final DateTime? lastRunAt;

  const IndexDashboardStats({
    required this.totalImages,
    required this.indexedImages,
    required this.queuedImages,
    required this.failedImages,
    required this.detectedFaces,
    required this.people,
    required this.namedPeople,
    required this.arabicOcrImages,
    required this.lastRunAt,
  });

  static const empty = IndexDashboardStats(
    totalImages: 0,
    indexedImages: 0,
    queuedImages: 0,
    failedImages: 0,
    detectedFaces: 0,
    people: 0,
    namedPeople: 0,
    arabicOcrImages: 0,
    lastRunAt: null,
  );

  double get progress => totalImages == 0
      ? 0
      : (indexedImages / totalImages).clamp(0.0, 1.0).toDouble();
}
