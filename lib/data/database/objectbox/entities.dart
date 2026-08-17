import 'dart:typed_data';
import 'package:objectbox/objectbox.dart';

@Entity()
class MediaAnalysis {
  @Id()
  int id = 0;

  @Unique()
  String assetId;
  String? aiCaption;
  String? extractedText;
  String? sentiment; // 'positive' | 'negative' | 'neutral'
  double? credibilityScore;
  String? labelsJson;

  @HnswIndex(dimensions: 512, distanceType: VectorDistanceType.cosine)
  Float32List? embedding;

  // ── المرحلة الأولى: تحليل بدون أي نموذج ذكاء اصطناعي ──────────

  /// بصمة إدراكية 64-bit (pHash) — لكشف الصور المكرّرة/المتشابهة.
  /// نخزّنها كـ int لأن مقارنة البتّات أسرع بكثير من النصوص.
  @Index()
  int? phash;

  /// اللون السائد بالصورة (ARGB) — للبحث باللون.
  int? dominantColor;

  /// درجة جودة 0..100 (حدّة + إضاءة) — لاقتراح الصورة الشخصية/الغلاف.
  double? qualityScore;
  double? sharpness; // تباين لابلاسي — الحدّة الخام
  double? brightness; // متوسط الإضاءة 0..1

  DateTime analyzedAt;
  bool isAnalyzed;

  MediaAnalysis({
    this.id = 0,
    required this.assetId,
    this.aiCaption,
    this.extractedText,
    this.sentiment,
    this.credibilityScore,
    this.labelsJson,
    this.embedding,
    this.phash,
    this.dominantColor,
    this.qualityScore,
    this.sharpness,
    this.brightness,
    required this.analyzedAt,
    this.isAnalyzed = false,
  });
}

@Entity()
class PersonGroup {
  @Id()
  int id = 0;

  String groupId; // UUID نولده نحن
  String name; // اسم الشخص (قابل للتعديل)
  String? coverAssetId;
  DateTime createdAt;

  // علاقة one-to-many مع PersonAsset
  @Backlink('person')
  final assets = ToMany<PersonAsset>();

  PersonGroup({
    this.id = 0,
    required this.groupId,
    required this.name,
    this.coverAssetId,
    required this.createdAt,
  });
}

@Entity()
class PersonAsset {
  @Id()
  int id = 0;

  String assetId;

  // ToOne = many-to-one: صورة تنتمي لشخص واحد
  final person = ToOne<PersonGroup>();

  PersonAsset({this.id = 0, required this.assetId});
}

@Entity()
class SecureFile {
  @Id()
  int id = 0;

  String? originalAssetId;
  String securePath;
  String originalName;
  String mimeType;
  String? thumbnailPath;
  int width;
  int height;
  int duration;
  DateTime addedAt;

  SecureFile({
    this.id = 0,
    this.originalAssetId,
    required this.securePath,
    required this.originalName,
    required this.mimeType,
    this.thumbnailPath,
    this.width = 0,
    this.height = 0,
    this.duration = 0,
    required this.addedAt,
  });

  bool get isVideo => mimeType == 'video';
}

@Entity()
class CustomAlbum {
  @Id()
  int id = 0;

  String name;
  String? coverAssetId;
  DateTime createdAt;

  @Backlink('album')
  final items = ToMany<CustomAlbumItem>();

  CustomAlbum({
    this.id = 0,
    required this.name,
    this.coverAssetId,
    required this.createdAt,
  });
}

@Entity()
class CustomAlbumItem {
  @Id()
  int id = 0;

  String assetId;
  DateTime addedAt;

  final album = ToOne<CustomAlbum>();

  CustomAlbumItem({this.id = 0, required this.assetId, required this.addedAt});
}

@Entity()
class DuplicateGroup {
  @Id()
  int id = 0;

  String groupHash;
  DateTime foundAt;

  @Backlink('group')
  final members = ToMany<DuplicateMember>();

  DuplicateGroup({this.id = 0, required this.groupHash, required this.foundAt});
}

@Entity()
class DuplicateMember {
  @Id()
  int id = 0;

  String assetId;
  String phash;
  int hammingDistance; // المسافة عن الـ groupHash

  final group = ToOne<DuplicateGroup>();

  DuplicateMember({
    this.id = 0,
    required this.assetId,
    required this.phash,
    required this.hammingDistance,
  });
}
