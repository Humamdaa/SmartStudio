import 'package:objectbox/objectbox.dart';
import '../../../objectbox.g.dart';
import 'entities.dart';
import 'objectbox_store.dart';

class CustomAlbumRepo {
  final ObjectBoxStore _store;
  CustomAlbumRepo(this._store);

  Box<CustomAlbum> get _albumBox => _store.customAlbumBox;
  Box<CustomAlbumItem> get _itemBox => _store.customAlbumItemBox;

  List<CustomAlbum> getAll() {
    final albums = _albumBox.getAll();
    albums.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return albums;
  }

  CustomAlbum createAlbum(String name) {
    final album = CustomAlbum(name: name, createdAt: DateTime.now());
    final id = _albumBox.put(album);
    album.id = id;
    return album;
  }

  void deleteAlbum(int albumId) {
    final items = _itemBox
        .query(CustomAlbumItem_.album.equals(albumId))
        .build()
        .find();
    _itemBox.removeMany(items.map((e) => e.id).toList());
    _albumBox.remove(albumId);
  }

  List<CustomAlbumItem> getItems(int albumId) {
    final items = _itemBox
        .query(CustomAlbumItem_.album.equals(albumId))
        .build()
        .find();
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return items;
  }

  bool containsAsset(int albumId, String assetId) {
    return _itemBox
            .query(
              CustomAlbumItem_.album
                  .equals(albumId)
                  .and(CustomAlbumItem_.assetId.equals(assetId)),
            )
            .build()
            .findFirst() !=
        null;
  }

  // يرجع true إذا انضافت، false إذا كانت موجودة أصلاً بالألبوم
  bool addAsset(int albumId, String assetId) {
    if (containsAsset(albumId, assetId)) return false;

    final item = CustomAlbumItem(assetId: assetId, addedAt: DateTime.now());
    item.album.targetId = albumId;
    _itemBox.put(item);

    // أول صورة تنضاف تصير الغلاف
    final album = _albumBox.get(albumId);
    if (album != null && album.coverAssetId == null) {
      album.coverAssetId = assetId;
      _albumBox.put(album);
    }
    return true;
  }

  void removeItem(int itemId) => _itemBox.remove(itemId);

  int itemCount(int albumId) =>
      _itemBox.query(CustomAlbumItem_.album.equals(albumId)).build().count();
}
