import 'package:objectbox/objectbox.dart';
import 'package:uuid/uuid.dart';
import '../../../objectbox.g.dart';
import 'entities.dart';
import 'objectbox_store.dart';

class PersonRepo {
  final ObjectBoxStore _store;
  final _uuid = const Uuid();

  PersonRepo(this._store);

  Box<PersonGroup>  get _groupBox  => _store.personBox;
  Box<PersonAsset>  get _assetBox  => _store.personAssetBox;

  // إنشاء مجموعة وجه جديدة
  PersonGroup createGroup(String name, {String? coverAssetId}) {
    final group = PersonGroup(
      groupId: _uuid.v4(),
      name: name,
      coverAssetId: coverAssetId,
      createdAt: DateTime.now(),
    );
    _groupBox.put(group);
    return group;
  }

  // إضافة صورة لمجموعة
  void addAssetToGroup(int groupId, String assetId) {
    final group = _groupBox.get(groupId);
    if (group == null) return;

    final asset = PersonAsset(assetId: assetId);
    asset.person.target = group;
    _assetBox.put(asset);
  }

  // كل المجموعات
  List<PersonGroup> getAllGroups() => _groupBox.getAll();

  // الصور التابعة لشخص معين
  List<String> getAssetIdsForGroup(int groupId) {
    return _assetBox
        .query(PersonAsset_.person.equals(groupId))
        .build()
        .find()
        .map((a) => a.assetId)
        .toList();
  }

  // تعديل اسم شخص
  void renameGroup(int groupId, String newName) {
    final group = _groupBox.get(groupId);
    if (group == null) return;
    group.name = newName;
    _groupBox.put(group);
  }
}
