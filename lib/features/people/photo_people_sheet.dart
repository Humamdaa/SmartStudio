import 'package:flutter/material.dart';

import '../../data/models/media_item.dart';
import '../../data/models/person_group.dart';
import '../../data/repositories/person_repository.dart';
import '../../services/ai/face_service.dart';

Future<void> showPhotoPeopleSheet({
  required BuildContext context,
  required MediaItem item,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: .72,
      child: _PhotoPeopleBody(item: item),
    ),
  );
}

class _PhotoPeopleBody extends StatefulWidget {
  final MediaItem item;

  const _PhotoPeopleBody({required this.item});

  @override
  State<_PhotoPeopleBody> createState() => _PhotoPeopleBodyState();
}

class _PhotoPeopleBodyState extends State<_PhotoPeopleBody> {
  final _repository = PersonRepository();
  List<PersonGroup>? _people;
  String _status = 'جاري التعرف على الوجوه محليًا…';

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  Future<void> _analyze() async {
    try {
      var people = await _repository.peopleForAsset(widget.item.id);
      final file = await widget.item.asset.file;
      if (file != null) {
        // Always ask FaceService. It is version-aware: an up-to-date photo is
        // returned from SQLite immediately, while an older face-pipeline scan
        // is re-run. This makes People in Photo a reliable way to pick up face
        // fixes without forcing YOLO/OCR to run again.
        final result = await FaceService.instance.analyzeAndStore(
          assetId: widget.item.id,
          imagePath: file.path,
        );
        people = result.people;
        _status = result.faceCount == 0
            ? 'لم نجد وجهًا واضحًا في هذه الصورة.'
            : 'تم العثور على ${result.faceCount} وجه وربطها بالتجمعات المحلية.';
      } else if (people.isNotEmpty) {
        _status = 'تم العثور على ${people.length} تجمع مخزن لهذه الصورة.';
      }
      if (mounted) setState(() => _people = people);
    } catch (error) {
      if (mounted) {
        setState(() {
          _people = const [];
          _status = 'تعذر تحليل الوجوه: $error';
        });
      }
    }
  }

  Future<void> _rename(PersonGroup person) async {
    final controller = TextEditingController(text: person.isNamed ? person.name : '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('أعطِ الشخص اسمًا'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _repository.rename(person.id, name);
    final people = await _repository.peopleForAsset(widget.item.id);
    if (mounted) setState(() => _people = people);
  }


  Future<void> _assignToExisting(PersonGroup person) async {
    final all = await _repository.allPeople(visibleOnly: false);
    final others = all.where((item) => item.id != person.id).toList()
      ..sort((a, b) {
        if (a.isNamed != b.isNamed) return a.isNamed ? -1 : 1;
        return b.photoCount.compareTo(a.photoCount);
      });
    if (!mounted) return;
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد شخص آخر لربط هذا الوجه به.')),
      );
      return;
    }

    final target = await showDialog<PersonGroup>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('هذا الوجه يعود لمن؟'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: ListView.separated(
              itemCount: others.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final candidate = others[index];
                final face = candidate.coverFaceJpeg;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: face?.isNotEmpty == true
                        ? MemoryImage(face!)
                        : null,
                    child: face?.isNotEmpty == true
                        ? null
                        : const Icon(Icons.person_outline),
                  ),
                  title: Text(candidate.name),
                  subtitle: Text('${candidate.photoCount} صورة'),
                  onTap: () => Navigator.pop(dialogContext, candidate),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
          ],
        ),
      ),
    );
    if (target == null) return;

    // Explicit user correction: the selected target survives. This is much
    // safer than lowering automatic face thresholds until different people
    // start contaminating one another.
    await _repository.merge(target.id, person.id);
    final people = await _repository.peopleForAsset(widget.item.id);
    if (mounted) {
      setState(() {
        _people = people;
        _status = 'تم ربط الوجه بالشخص الذي اخترته.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('الأشخاص في الصورة',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(_status),
            const SizedBox(height: 14),
            if (people == null)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (people.isEmpty)
              const Expanded(
                child: Center(child: Icon(Icons.face_retouching_off, size: 60)),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: people.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, index) {
                    final person = people[index];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text('${index + 1}'),
                      ),
                      title: Text(person.name),
                      subtitle: Text('${person.photoCount} صورة في ألبومه الذكي'),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'خيارات الشخص',
                        onSelected: (action) {
                          if (action == 'rename') _rename(person);
                          if (action == 'assign') _assignToExisting(person);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'rename',
                            child: Text(person.isNamed ? 'تعديل الاسم' : 'تسمية الشخص'),
                          ),
                          const PopupMenuItem(
                            value: 'assign',
                            child: Text('ربط بشخص موجود'),
                          ),
                        ],
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
