import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../../data/models/media_item.dart';

class SelectionActions {
  SelectionActions._();

  static Future<bool> share(List<MediaItem> items) async {
    final files = <XFile>[];
    for (final it in items) {
      final f = await it.asset.originFile;
      if (f != null && await f.exists()) {
        files.add(XFile(f.path));
      }
    }
    if (files.isEmpty) return false;
    await SharePlus.instance.share(ShareParams(files: files));
    return true;
  }

  static Future<List<String>> delete(List<MediaItem> items) async {
    if (items.isEmpty) return const [];
    final ids = items.map((e) => e.id).toList();
    return PhotoManager.editor.deleteWithIds(ids);
  }
}
