import 'package:photo_manager/photo_manager.dart';

enum MediaType { image, video }

class MediaItem {
  final String id;
  final String title;
  final MediaType type;
  final DateTime createDate;
  final int width;
  final int height;
  final int size; // bytes
  final AssetEntity asset;

  final String? aiCaption;
  final String? extractedText;
  final String? sentiment; // 'positive' | 'negative' | 'neutral'
  final double? credibilityScore;
  final List<String>? labels;

  const MediaItem({
    required this.id,
    required this.title,
    required this.type,
    required this.createDate,
    required this.width,
    required this.height,
    required this.size,
    required this.asset,
    this.aiCaption,
    this.extractedText,
    this.sentiment,
    this.credibilityScore,
    this.labels,
  });

  factory MediaItem.fromAsset(AssetEntity asset) {
    return MediaItem(
      id: asset.id,
      title: asset.title ?? '',
      type: asset.type == AssetType.video ? MediaType.video : MediaType.image,
      createDate: asset.createDateTime,
      width: asset.width,
      height: asset.height,
      asset: asset,
      size: 5,
    );
  }

  MediaItem copyWith({
    String? aiCaption,
    String? extractedText,
    String? sentiment,
    double? credibilityScore,
    List<String>? labels,
  }) {
    return MediaItem(
      id: id,
      title: title,
      type: type,
      createDate: createDate,
      width: width,
      height: height,
      size: size,
      asset: asset,
      aiCaption: aiCaption ?? this.aiCaption,
      extractedText: extractedText ?? this.extractedText,
      sentiment: sentiment ?? this.sentiment,
      credibilityScore: credibilityScore ?? this.credibilityScore,
      labels: labels ?? this.labels,
    );
  }

  String get formattedSize {
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get resolution => '${width}×$height';

  bool get isVideo => type == MediaType.video;
}
