import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/constants/app_colors.dart';
import '../../services/album_service.dart';

/// الوجهة اللي اختارها المستخدم: إما مجلد موجود على الجهاز،
/// أو اسم ألبوم جديد بننشئه وقت النقل/النسخ.
class AlbumTarget {
  final String name;
  final AssetPathEntity? path; // null = ألبوم جديد
  const AlbumTarget.existing(this.path, this.name);
  const AlbumTarget.create(this.name) : path = null;

  bool get isNew => path == null;
}

/// شيت اختيار مجلد حقيقي من مجلدات الجهاز (أو إنشاء واحد جديد).
/// بيسكّر بـ pop(AlbumTarget).
class AlbumPickerSheet extends StatefulWidget {
  final String title;

  /// المسار النسبي للمجلد الحالي — ما في فايدة نعرضه كوجهة.
  final String? currentAlbumId;

  const AlbumPickerSheet({super.key, required this.title, this.currentAlbumId});

  @override
  State<AlbumPickerSheet> createState() => _AlbumPickerSheetState();
}

class _AlbumPickerSheetState extends State<AlbumPickerSheet> {
  List<AssetPathEntity> _paths = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final paths = await AlbumService.instance.loadTargets();
    if (!mounted) return;
    setState(() {
      _paths = paths;
      _loading = false;
    });
  }

  Future<void> _createNew() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      // كونتكست الدايالوج نفسه — مش كونتكست الشيت، وإلا منسكّر الشيت
      builder: (dialogCtx) => AlertDialog(
        title: const Text('New album'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Album name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    Navigator.pop(context, AlbumTarget.create(name));
  }

  @override
  Widget build(BuildContext context) {
    final targets = _paths
        .where((p) => p.id != widget.currentAlbumId && p.name != 'Recent')
        .toList();

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.create_new_folder_outlined,
                color: AppColors.mintAccent,
              ),
              title: const Text(
                'New album',
                style: TextStyle(
                  color: AppColors.mintAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: const Text(
                'Creates a real folder on your device',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              onTap: _createNew,
            ),
            const Divider(color: Colors.white24, height: 1),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 34),
                child: CircularProgressIndicator(color: AppColors.mintAccent),
              )
            else if (targets.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Text(
                  'No other folders on this device',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: targets.length,
                  itemBuilder: (context, i) {
                    final p = targets[i];
                    return ListTile(
                      leading: const Icon(
                        Icons.folder_outlined,
                        color: Colors.white70,
                      ),
                      title: Text(
                        p.name,
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () => Navigator.pop(
                        context,
                        AlbumTarget.existing(p, p.name),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
