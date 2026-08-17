import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:objectbox/objectbox.dart';
import '../../../objectbox.g.dart';
import 'entities.dart';

class ObjectBoxStore {
  late final Store store;

  ObjectBoxStore._create(this.store);
  static Future<ObjectBoxStore> create() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'pixmind-db');

    final store = await openStore(directory: dbPath);

    return ObjectBoxStore._create(store);
  }

  Box<MediaAnalysis> get analysisBox => store.box<MediaAnalysis>();
  Box<PersonGroup> get personBox => store.box<PersonGroup>();
  Box<PersonAsset> get personAssetBox => store.box<PersonAsset>();
  Box<SecureFile> get secureBox => store.box<SecureFile>();
  Box<DuplicateGroup> get dupGroupBox => store.box<DuplicateGroup>();
  Box<DuplicateMember> get dupMemberBox => store.box<DuplicateMember>();
  Box<CustomAlbum> get customAlbumBox => store.box<CustomAlbum>();
  Box<CustomAlbumItem> get customAlbumItemBox => store.box<CustomAlbumItem>();

  void close() => store.close();
}
