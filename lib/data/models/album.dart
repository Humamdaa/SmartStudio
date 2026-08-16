import 'media_item.dart';

class Album {
  final String id;
  final String name;
  final List<MediaItem> items;
  final bool isSmartAlbum;
  final String? coverAssetId;

  const Album({
    required this.id,
    required this.name,
    required this.items,
    this.isSmartAlbum = false,
    this.coverAssetId,
  });

  int get count => items.length;

  MediaItem? get coverItem =>
      items.isNotEmpty ? items.first : null;
}

class PersonGroup {
  final String id;
  final String name;
  final List<String> assetIds;
  final String? coverAssetId;

  const PersonGroup({
    required this.id,
    required this.name,
    required this.assetIds,
    this.coverAssetId,
  });

  PersonGroup copyWith({String? name}) {
    return PersonGroup(
      id: id,
      name: name ?? this.name,
      assetIds: assetIds,
      coverAssetId: coverAssetId,
    );
  }
}
