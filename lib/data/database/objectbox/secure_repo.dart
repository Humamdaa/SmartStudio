import 'package:objectbox/objectbox.dart';
import '../../../objectbox.g.dart';
import 'entities.dart';
import 'objectbox_store.dart';
class SecureRepo {
  final ObjectBoxStore _store;
  SecureRepo(this._store);

  Box<SecureFile> get _box => _store.secureBox;

  // حفظ SecureFile بعد ما SecureStorageService ينقل الملف
  int save(SecureFile file) => _box.put(file);

  void remove(int id) => _box.remove(id);

  List<SecureFile> getAll() => _box.getAll();

  SecureFile? getById(int id) => _box.get(id);

  bool isSecured(String originalAssetId) {
    return _box
        .query(SecureFile_.originalAssetId.equals(originalAssetId))
        .build()
        .findFirst() != null;
  }

  SecureFile? getByOriginalId(String originalAssetId) {
    return _box
        .query(SecureFile_.originalAssetId.equals(originalAssetId))
        .build()
        .findFirst();
  }

  int get count => _box.count();
}
