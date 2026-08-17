import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../data/database/db_helper.dart';
import '../../data/models/person_group.dart';
import '../../features/search/search_vocabulary.dart';

class FaceAnalysisResult {
  final int faceCount;
  final List<PersonGroup> people;

  const FaceAnalysisResult({required this.faceCount, required this.people});
}

/// Offline People Intelligence v2.1.
///
/// Improvements over the first MVP:
/// - roll-aware face alignment before MobileFaceNet
/// - a quality score for covers/prototypes
/// - several representative embeddings per person, not one drifting centroid
/// - conservative matching with a runner-up margin
/// - never maps two different faces in the same photo to the same cluster
/// - a conservative post-pass that can merge duplicate unnamed clusters
/// - stores every face embedding so clusters can be rebuilt without YOLO/OCR
class FaceService {
  FaceService._();
  static final FaceService instance = FaceService._();

  static const facePipelineVersion = 'faces-v2.2.4-named-anchor-1';
  static const _modelAsset = 'assets/models/mobilefacenet.tflite';

  // These are deliberately conservative. A grey-zone face becomes a hidden
  // candidate instead of contaminating an existing person album.
  static const _baseStrongThreshold = 0.73;
  // A user-named cluster is a stronger identity anchor, so allow a slightly
  // more permissive strong match while still requiring the quality guard and
  // runner-up margin. This mainly helps the second/third photo inherit a name.
  static const _namedStrongThreshold = 0.72;
  static const _supportedThreshold = 0.695;
  static const _runnerUpMargin = 0.028;
  static const _prototypeSupportThreshold = 0.655;

  final DatabaseHelper _database = DatabaseHelper.instance;
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: false,
      enableContours: false,
      enableLandmarks: true,
      enableTracking: false,
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.08,
    ),
  );

  Interpreter? _interpreter;
  Future<void> _analysisTail = Future<void>.value();
  String? lastError;

  Future<Interpreter> _getInterpreter() async {
    final current = _interpreter;
    if (current != null) return current;
    final options = InterpreterOptions()..threads = 2;
    final loaded = await Interpreter.fromAsset(_modelAsset, options: options);
    _interpreter = loaded;
    return loaded;
  }

  Future<List<Face>> detectFaces(String imagePath) async {
    lastError = null;
    try {
      return await _detector.processImage(InputImage.fromFilePath(imagePath));
    } catch (error, stackTrace) {
      lastError = 'Face detector: $error';
      debugPrint('PixMind face detection error: $error\n$stackTrace');
      rethrow;
    }
  }

  Future<int> countFaces(String imagePath) async {
    return (await detectFaces(imagePath)).length;
  }

  Future<FaceAnalysisResult> analyzeAndStore({
    required String assetId,
    required String imagePath,
    bool force = false,
  }) {
    final turn = Completer<void>();
    final previous = _analysisTail;
    _analysisTail = turn.future;
    return previous.then((_) async {
      try {
        return await _analyzeAndStore(
          assetId: assetId,
          imagePath: imagePath,
          force: force,
        );
      } finally {
        turn.complete();
      }
    });
  }

  Future<FaceAnalysisResult> _analyzeAndStore({
    required String assetId,
    required String imagePath,
    required bool force,
  }) async {
    final hasScan = await _database.hasFaceScan(assetId);
    final scanVersion = hasScan
        ? await _database.getFaceScanVersion(assetId)
        : '';
    if (!force && hasScan && scanVersion == facePipelineVersion) {
      final faceCount = await _database.getFaceScanCount(assetId);
      final storedFaces = await _database.getFaceInstanceCount(assetId);
      if (faceCount == 0 || storedFaces >= faceCount) {
        final people = await _database.getPeopleForAsset(assetId);
        return FaceAnalysisResult(faceCount: faceCount, people: people);
      }
    }

    // Any old/incomplete pass must replace its face rows. This does not touch
    // the image's YOLO/OCR/scene index.
    if (force || hasScan || await _database.hasFacesForAsset(assetId)) {
      await _database.prepareAssetFaceReanalysis(assetId);
    }

    final faces = await detectFaces(imagePath);
    if (faces.isEmpty) {
      await _database.markFaceScanned(
        assetId,
        0,
        pipelineVersion: facePipelineVersion,
      );
      return const FaceAnalysisResult(faceCount: 0, people: []);
    }

    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      lastError = 'تعذر فتح الصورة لتحليل بصمة الوجه';
      throw StateError(lastError!);
    }
    // ML Kit honors camera orientation. Baking EXIF makes our crop coordinates
    // agree with the visual orientation used by the detector on most phones.
    final image = img.bakeOrientation(decoded);

    final rejectedPersonIds = await _database.getRejectedPersonIds(assetId);
    final assignedPersonIds = <String>{};
    var embeddingFailures = 0;

    for (var faceIndex = 0; faceIndex < faces.length; faceIndex++) {
      final face = faces[faceIndex];
      _PreparedFace prepared;
      try {
        prepared = await _prepareFace(image, face);
      } catch (error, stackTrace) {
        embeddingFailures++;
        lastError = 'MobileFaceNet: $error';
        debugPrint('PixMind face embedding error: $error\n$stackTrace');
        continue;
      }
      if (prepared.embedding.isEmpty) {
        embeddingFailures++;
        lastError = 'MobileFaceNet أعاد بصمة فارغة';
        continue;
      }

      final groups = await _database.getPersonGroupsDetailed(
        visibleOnly: false,
      );
      final prototypes = await _database.getPersonPrototypeEmbeddings(
        perPerson: 5,
        minQuality: 0.24,
      );

      final candidates = <_ClusterScore>[];
      for (final person in groups) {
        if (rejectedPersonIds.contains(person.id)) continue;
        // In one real photo a person normally occurs once. Preventing a second
        // detected face from entering the same cluster is a strong guard
        // against merging look-alike people in group photos.
        if (assignedPersonIds.contains(person.id)) continue;
        final score = _scoreCluster(
          person,
          prototypes[person.id] ?? const [],
          prepared.embedding,
        );
        if (score != null) candidates.add(score);
      }
      candidates.sort((a, b) => b.bestScore.compareTo(a.bestScore));

      final best = candidates.isEmpty ? null : candidates.first;
      final runnerUp = candidates.length > 1 ? candidates[1] : null;

      // Precision-first guard for the gallery use case. A small, blurry or
      // strongly turned face is still stored (so the user can later merge or
      // rebuild people), but it is not allowed to contaminate an existing
      // person's cluster automatically. False splits are much easier to fix
      // than two different people being merged into one album.
      final canAutoMatch =
          prepared.qualityScore >= 0.30 && prepared.poseScore >= 0.35;
      final matched =
          canAutoMatch &&
          best != null &&
          _acceptMatch(best, runnerUp, faceQuality: prepared.qualityScore);

      if (kDebugMode && best != null) {
        final runnerScore = runnerUp?.bestScore;
        debugPrint(
          'PixMind face match asset=$assetId index=$faceIndex '
          'q=${prepared.qualityScore.toStringAsFixed(3)} '
          'pose=${prepared.poseScore.toStringAsFixed(3)} '
          'best=${best.bestScore.toStringAsFixed(3)} '
          'runner=${runnerScore?.toStringAsFixed(3) ?? '-'} '
          'auto=$canAutoMatch matched=$matched',
        );
      }

      final unnamedNumber = matched
          ? 0
          : await _database.nextUnnamedPersonNumber();
      final personId = matched
          ? best.person.id
          : 'person_${DateTime.now().microsecondsSinceEpoch}_$faceIndex';
      final personName = matched
          ? best.person.name
          : 'شخص غير مسمى $unnamedNumber';
      final updatedCentroid = matched
          ? _rollingCentroid(
              best.person.centroid,
              prepared.embedding,
              best.person.sampleCount,
            )
          : prepared.embedding;
      final sampleCount = matched ? best.person.sampleCount + 1 : 1;
      final rect = face.boundingBox;
      double normalized(double value, int extent) =>
          (value / math.max(1, extent)).clamp(0.0, 1.0).toDouble();

      await _database.saveRecognizedFace(
        faceKey: '$assetId:$faceIndex',
        assetId: assetId,
        personId: personId,
        initialName: personName,
        searchName: SearchVocabulary.normalize(personName),
        centroid: updatedCentroid,
        embedding: prepared.embedding,
        sampleCount: sampleCount,
        left: normalized(rect.left, image.width),
        top: normalized(rect.top, image.height),
        right: normalized(rect.right, image.width),
        bottom: normalized(rect.bottom, image.height),
        confidence: matched ? best.bestScore : 1.0,
        qualityScore: prepared.qualityScore,
        poseScore: prepared.poseScore,
        faceCropJpeg: prepared.coverJpeg,
        pipelineVersion: facePipelineVersion,
        isNewPerson: !matched,
      );
      assignedPersonIds.add(personId);
    }

    await _database.markFaceScanned(
      assetId,
      faces.length,
      pipelineVersion: embeddingFailures == 0
          ? facePipelineVersion
          : 'partial:$facePipelineVersion',
    );

    final people = await _database.getPeopleForAsset(assetId);
    if (embeddingFailures > 0 && people.isEmpty) {
      throw StateError(lastError ?? 'تعذرت بصمة الوجه');
    }
    return FaceAnalysisResult(faceCount: faces.length, people: people);
  }

  _ClusterScore? _scoreCluster(
    PersonGroup person,
    List<List<double>> prototypes,
    List<double> embedding,
  ) {
    final scores = <double>[];
    if (person.centroid.length == embedding.length) {
      scores.add(_cosine(person.centroid, embedding));
    }
    for (final prototype in prototypes) {
      if (prototype.length == embedding.length) {
        scores.add(_cosine(prototype, embedding));
      }
    }
    if (scores.isEmpty) return null;
    scores.sort((a, b) => b.compareTo(a));
    final supportCount = scores
        .where((score) => score >= _prototypeSupportThreshold)
        .length;
    final topSupport = scores.take(math.min(2, scores.length)).toList();
    final supportAverage = topSupport.isEmpty
        ? -1.0
        : topSupport.reduce((a, b) => a + b) / topSupport.length;
    return _ClusterScore(
      person: person,
      bestScore: scores.first,
      supportCount: supportCount,
      supportAverage: supportAverage,
    );
  }

  bool _acceptMatch(
    _ClusterScore best,
    _ClusterScore? runnerUp, {
    required double faceQuality,
  }) {
    final lowQualityPenalty = faceQuality < 0.42
        ? ((0.42 - faceQuality) * 0.12).clamp(0.0, 0.035).toDouble()
        : 0.0;
    final strongThreshold =
        (best.person.isNamed ? _namedStrongThreshold : _baseStrongThreshold) +
        lowQualityPenalty;
    final margin = runnerUp == null ? 1.0 : best.bestScore - runnerUp.bestScore;

    // Very strong identity evidence can stand alone. Otherwise ask for two
    // supporting representatives and a clear lead over the next person.
    if (best.bestScore >= strongThreshold &&
        (margin >= _runnerUpMargin || best.bestScore >= 0.82)) {
      return true;
    }
    final supported =
        best.bestScore >= _supportedThreshold + lowQualityPenalty &&
        best.supportCount >= 2 &&
        best.supportAverage >= _prototypeSupportThreshold &&
        margin >= _runnerUpMargin + 0.01;
    return supported;
  }

  Future<_PreparedFace> _prepareFace(img.Image image, Face face) async {
    final rect = face.boundingBox;
    final cx = (rect.left + rect.right) / 2;
    final cy = (rect.top + rect.bottom) / 2;
    final side = math.max(rect.width, rect.height) * 1.55;
    if (side < 2 || image.width < 1 || image.height < 1) {
      return _PreparedFace(
        embedding: const [],
        coverJpeg: Uint8List(0),
        qualityScore: 0,
        poseScore: 0,
      );
    }

    final left = (cx - side / 2).round().clamp(0, image.width - 1).toInt();
    final top = (cy - side / 2).round().clamp(0, image.height - 1).toInt();
    final width = side.round().clamp(1, image.width - left).toInt();
    final height = side.round().clamp(1, image.height - top).toInt();
    var cropped = img.copyCrop(
      image,
      x: left,
      y: top,
      width: width,
      height: height,
    );

    // Prefer the actual eye line when both ML Kit landmarks are available.
    // Euler roll remains the fallback for small/partially occluded faces.
    final roll = _alignmentRoll(face).clamp(-45.0, 45.0).toDouble();
    if (roll.abs() >= 1.5) {
      cropped = img.copyRotate(cropped, angle: -roll);
    }

    final aligned = img.copyResizeCropSquare(cropped, size: 160);
    final modelImage = img.copyResize(aligned, width: 112, height: 112);
    final input = List.generate(1, (_) {
      return List.generate(112, (y) {
        return List.generate(112, (x) {
          final pixel = modelImage.getPixel(x, y);
          return <double>[
            pixel.r.toDouble() / 127.5 - 1,
            pixel.g.toDouble() / 127.5 - 1,
            pixel.b.toDouble() / 127.5 - 1,
          ];
        });
      });
    });

    final interpreter = await _getInterpreter();
    final shape = interpreter.getOutputTensor(0).shape;
    final dimensions = shape.isEmpty ? 192 : shape.last;
    final output = [List<double>.filled(dimensions, 0)];
    interpreter.run(input, output);

    final yaw = (face.headEulerAngleY ?? 0.0).abs();
    final poseScore = (1.0 - ((yaw / 50.0) * 0.62 + (roll.abs() / 40.0) * 0.38))
        .clamp(0.0, 1.0)
        .toDouble();
    final areaRatio =
        (rect.width * rect.height) / math.max(1, image.width * image.height);
    final sizeScore = ((math.sqrt(areaRatio) - 0.055) / 0.23)
        .clamp(0.0, 1.0)
        .toDouble();
    final visualScore = _visualFaceQuality(aligned);
    final qualityScore =
        (sizeScore * 0.45 + poseScore * 0.35 + visualScore * 0.20)
            .clamp(0.0, 1.0)
            .toDouble();

    return _PreparedFace(
      embedding: _normalize(output.first),
      coverJpeg: img.encodeJpg(aligned, quality: 84),
      qualityScore: qualityScore,
      poseScore: poseScore,
    );
  }

  double _visualFaceQuality(img.Image image) {
    // Cheap on-device proxy for a useful cover: enough local detail and not
    // severely under/over-exposed. It avoids another ML model.
    var edgeTotal = 0.0;
    var edgeCount = 0;
    var luminanceTotal = 0.0;
    var luminanceCount = 0;
    for (var y = 4; y < image.height - 4; y += 4) {
      for (var x = 4; x < image.width - 4; x += 4) {
        final centerPixel = image.getPixel(x, y);
        final rightPixel = image.getPixel(x + 4, y);
        final downPixel = image.getPixel(x, y + 4);
        double luma(dynamic pixel) =>
            (pixel.r.toDouble() * 0.299 +
                pixel.g.toDouble() * 0.587 +
                pixel.b.toDouble() * 0.114) /
            255.0;
        final center = luma(centerPixel);
        final right = luma(rightPixel);
        final down = luma(downPixel);
        edgeTotal += (center - right).abs() + (center - down).abs();
        edgeCount += 2;
        luminanceTotal += center;
        luminanceCount++;
      }
    }
    if (edgeCount == 0 || luminanceCount == 0) return 0.0;
    final meanEdge = edgeTotal / edgeCount;
    final sharpness = ((meanEdge - 0.025) / 0.12).clamp(0.0, 1.0).toDouble();
    final meanLuma = luminanceTotal / luminanceCount;
    final exposure = (1.0 - ((meanLuma - 0.52).abs() / 0.52))
        .clamp(0.0, 1.0)
        .toDouble();
    return (sharpness * 0.68 + exposure * 0.32).clamp(0.0, 1.0).toDouble();
  }

  double _alignmentRoll(Face face) {
    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    if (leftEye != null && rightEye != null) {
      final dx = (rightEye.x - leftEye.x).toDouble();
      final dy = (rightEye.y - leftEye.y).toDouble();
      if (dx.abs() + dy.abs() >= 4) {
        return math.atan2(dy, dx) * 180 / math.pi;
      }
    }
    return face.headEulerAngleZ ?? 0.0;
  }

  /// Conservative duplicate-cluster refinement. It never automatically merges
  /// two differently named people, and never merges clusters that have appeared
  /// together in the same photo (strong evidence they are different humans).
  Future<int> refineClusters({int maxMerges = 8}) async {
    // Recompute from individual embeddings first, so an accidental early face
    // cannot keep pulling a rolling centroid toward the wrong identity.
    await _database.recomputeAllPersonGroups();
    var merges = 0;
    while (merges < maxMerges) {
      final groups = await _database.getPersonGroupsDetailed(
        visibleOnly: false,
      );
      if (groups.length < 2) break;
      final prototypes = await _database.getPersonPrototypeEmbeddings(
        perPerson: 4,
        minQuality: 0.30,
      );

      _MergeCandidate? strongest;
      for (var i = 0; i < groups.length; i++) {
        final first = groups[i];
        for (var j = i + 1; j < groups.length; j++) {
          final second = groups[j];
          if (first.centroid.isEmpty || second.centroid.isEmpty) continue;
          if (first.centroid.length != second.centroid.length) continue;
          if (first.isNamed &&
              second.isNamed &&
              first.searchName != second.searchName) {
            continue;
          }

          // Cheap vector pre-filter before any per-pair SQLite query. This
          // keeps refinement practical when a gallery has many one-photo
          // candidate clusters.
          final centroidScore = _cosine(first.centroid, second.centroid);
          final prefilter = first.isNamed || second.isNamed ? 0.64 : 0.60;
          if (centroidScore < prefilter) continue;
          if (await _database.peopleShareAnyAsset(first.id, second.id)) {
            continue;
          }

          final crossScores = <double>[];
          for (final a in prototypes[first.id] ?? const <List<double>>[]) {
            for (final b in prototypes[second.id] ?? const <List<double>>[]) {
              if (a.length == b.length) crossScores.add(_cosine(a, b));
            }
          }
          crossScores.sort((a, b) => b.compareTo(a));
          final bestCross = crossScores.isEmpty
              ? centroidScore
              : crossScores.first;
          final topTwoAverage = crossScores.length >= 2
              ? (crossScores[0] + crossScores[1]) / 2
              : bestCross;

          final threshold = first.isNamed || second.isNamed ? 0.805 : 0.765;
          final sameNamed =
              first.isNamed &&
              second.isNamed &&
              first.searchName == second.searchName &&
              first.searchName.isNotEmpty;
          final accepted = sameNamed
              ? bestCross >= 0.73 && centroidScore >= 0.66
              : bestCross >= threshold &&
                    centroidScore >= threshold - 0.075 &&
                    topTwoAverage >= threshold - 0.035;
          if (!accepted) continue;

          final combined =
              bestCross * 0.55 + centroidScore * 0.30 + topTwoAverage * 0.15;
          if (strongest == null || combined > strongest.score) {
            strongest = _MergeCandidate(first, second, combined);
          }
        }
      }

      if (strongest == null) break;
      final first = strongest.first;
      final second = strongest.second;
      final PersonGroup target;
      final PersonGroup source;
      if (first.isNamed && !second.isNamed) {
        target = first;
        source = second;
      } else if (second.isNamed && !first.isNamed) {
        target = second;
        source = first;
      } else if (first.photoCount >= second.photoCount) {
        target = first;
        source = second;
      } else {
        target = second;
        source = first;
      }
      await _database.mergePersons(target.id, source.id);
      merges++;
    }
    return merges;
  }

  List<double> _rollingCentroid(
    List<double> centroid,
    List<double> sample,
    int oldSampleCount,
  ) {
    if (centroid.length != sample.length || centroid.isEmpty) return sample;
    final count = math.max(1, oldSampleCount);
    return _normalize(
      List.generate(
        sample.length,
        (index) => (centroid[index] * count + sample[index]) / (count + 1),
      ),
    );
  }

  List<double> _normalize(List<double> values) {
    final norm = math.sqrt(
      values.fold<double>(0, (sum, value) => sum + value * value),
    );
    if (norm == 0) return values;
    return values.map((value) => value / norm).toList(growable: false);
  }

  double _cosine(List<double> first, List<double> second) {
    var score = 0.0;
    for (var index = 0; index < first.length; index++) {
      score += first[index] * second[index];
    }
    return score;
  }

  void dispose() {
    _detector.close();
    _interpreter?.close();
    _interpreter = null;
  }
}

class _PreparedFace {
  final List<double> embedding;
  final Uint8List coverJpeg;
  final double qualityScore;
  final double poseScore;

  const _PreparedFace({
    required this.embedding,
    required this.coverJpeg,
    required this.qualityScore,
    required this.poseScore,
  });
}

class _ClusterScore {
  final PersonGroup person;
  final double bestScore;
  final int supportCount;
  final double supportAverage;

  const _ClusterScore({
    required this.person,
    required this.bestScore,
    required this.supportCount,
    required this.supportAverage,
  });
}

class _MergeCandidate {
  final PersonGroup first;
  final PersonGroup second;
  final double score;

  const _MergeCandidate(this.first, this.second, this.score);
}
