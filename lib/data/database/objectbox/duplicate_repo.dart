import 'package:objectbox/objectbox.dart';
import '../../../objectbox.g.dart';
import 'entities.dart';
import 'objectbox_store.dart';

class DuplicateRepo {
  final ObjectBoxStore _store;
  DuplicateRepo(this._store);

  Box<DuplicateGroup>  get _groupBox  => _store.dupGroupBox;
  Box<DuplicateMember> get _memberBox => _store.dupMemberBox;

  // حفظ مجموعة مكررات
  void saveGroup(String groupHash, List<_DupEntry> members) {
    final group = DuplicateGroup(
      groupHash: groupHash,
      foundAt: DateTime.now(),
    );
    _groupBox.put(group);

    for (final m in members) {
      final member = DuplicateMember(
        assetId: m.assetId,
        phash: m.phash,
        hammingDistance: m.distance,
      );
      member.group.target = group;
      _memberBox.put(member);
    }
  }

  // كل مجموعات المكررات
  List<DuplicateGroup> getAllGroups() => _groupBox.getAll();

  // أعضاء مجموعة معينة
  List<DuplicateMember> getMembers(int groupId) {
    return _memberBox
        .query(DuplicateMember_.group.equals(groupId))
        .build()
        .find();
  }

  // هل تم فحص هاد الـ asset؟
  bool isChecked(String assetId) {
    return _memberBox
            .query(DuplicateMember_.assetId.equals(assetId))
            .build()
            .findFirst() !=
        null;
  }

  int get totalGroups => _groupBox.count();
}

class _DupEntry {
  final String assetId, phash;
  final int distance;
  _DupEntry(this.assetId, this.phash, this.distance);
}
