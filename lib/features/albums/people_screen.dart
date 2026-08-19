import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core/constants/app_colors.dart';
import '../../core/router/app_router.dart';
import '../../data/models/media_item.dart';
import '../../data/prefs/app_prefs.dart';
import '../../data/models/person_group.dart';
import '../../data/repositories/person_repository.dart';
import '../../services/gallery/background_indexer.dart';
import '../../services/gallery/face_index_service.dart';

class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  final _repository = PersonRepository();
  List<PersonGroup>? _people;
  int _candidateCount = 0;
  bool _showCandidates = false;
  bool _rebuilding = false;
  int _rebuildProcessed = 0;
  int _rebuildTotal = 0;
  int _rebuildFailed = 0;
  int _rebuildDetected = 0;
  int _rebuildIgnored = 0;
  String? _rebuildStatus;
  bool _backgroundFacesEnabled = false;
  int _lastFaceProcessed = -1;
  bool _lastFaceRunning = false;

  @override
  void initState() {
    super.initState();
    FaceIndexService.instance.progress.addListener(_onFaceProgress);
    _applyFaceProgress(FaceIndexService.instance.progress.value, notify: false);
    _lastFaceRunning = FaceIndexService.instance.progress.value.running;
    _reload();
    _loadBackgroundFaceSetting();
  }

  @override
  void dispose() {
    FaceIndexService.instance.progress.removeListener(_onFaceProgress);
    super.dispose();
  }

  Future<void> _loadBackgroundFaceSetting() async {
    final enabled = await AppPrefs.instance.backgroundFaceIndexingEnabled;
    if (mounted) setState(() => _backgroundFacesEnabled = enabled);
  }

  void _onFaceProgress() {
    final value = FaceIndexService.instance.progress.value;
    final shouldReload =
        (value.processed > 0 && value.processed % 20 == 0 &&
            value.processed != _lastFaceProcessed) ||
        (_lastFaceRunning && !value.running);
    _lastFaceProcessed = value.processed;
    _lastFaceRunning = value.running;
    _applyFaceProgress(value);
    if (shouldReload) _reload();
  }

  void _applyFaceProgress(FaceIndexProgress value, {bool notify = true}) {
    void apply() {
      _rebuilding = value.running;
      _rebuildProcessed = value.processed;
      _rebuildTotal = value.total;
      _rebuildFailed = value.failed;
      _rebuildDetected = value.detected;
      _rebuildIgnored = value.ignored;
      _rebuildStatus = value.status;
    }

    if (notify && mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  Future<void> _toggleBackgroundFaces(bool enabled) async {
    setState(() => _backgroundFacesEnabled = enabled);
    await BackgroundIndexService.instance.setFaceEnabled(enabled);
  }

  Future<void> _reload() async {
    final people = await _repository.allPeople(visibleOnly: !_showCandidates);
    final candidates = await _repository.candidateCount();
    if (mounted) {
      setState(() {
        _people = people;
        _candidateCount = candidates;
      });
    }
  }

  Future<void> _rename(PersonGroup person) async {
    final controller = TextEditingController(
      text: person.isNamed ? person.name : '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('من هذا الشخص؟'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'مثال: أحمد'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
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
    await _reload();
  }

  Future<void> _merge(PersonGroup person) async {
    final all = await _repository.allPeople(visibleOnly: false);
    final others = all
        .where((item) => item.id != person.id)
        .toList(growable: false);
    if (!mounted) return;
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد ألبوم شخص آخر لدمجه حاليًا.')),
      );
      return;
    }
    final other = await showDialog<PersonGroup>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('دمج ${person.name} مع…'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: ListView.separated(
              itemCount: others.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final candidate = others[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: candidate.coverFaceJpeg?.isNotEmpty == true
                        ? MemoryImage(candidate.coverFaceJpeg!)
                        : null,
                    child: candidate.coverFaceJpeg?.isNotEmpty == true
                        ? null
                        : const Icon(Icons.person),
                  ),
                  title: Text(candidate.name),
                  subtitle: Text('${candidate.photoCount} صورة'),
                  onTap: () => Navigator.pop(context, candidate),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
          ],
        ),
      ),
    );
    if (other == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد الدمج'),
          content: Text(
            'سيتم اعتبار «${person.name}» و«${other.name}» الشخص نفسه ونقل الصور إلى ألبوم واحد.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('دمج'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await _repository.merge(person.id, other.id);
    await _reload();
  }

  Future<void> _startFaceRebuild() async {
    if (_rebuilding) return;
    final limit = await showDialog<int?>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('Face Lab v3 — متابعة ذكية'),
          content: const Text(
            'فهرسة الوجوه تحفظ تقدمها تلقائيًا. الصور التي اكتملت بنفس إصدار '
            'Face v3 لن يعاد تحليلها عند الضغط مرة ثانية أو بعد إعادة فتح التطبيق. '
            'يمكنك معالجة 20 صورة جديدة فقط أو إكمال كل الصور المتبقية. '
            'لن يعاد YOLO أو OCR أو فهرس البحث البصري.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(context, 20),
              icon: const Icon(Icons.skip_next_rounded),
              label: const Text('20 التالية'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, -1),
              icon: const Icon(Icons.playlist_add_check_circle_rounded),
              label: const Text('إكمال كل الصور'),
            ),
          ],
        ),
      ),
    );
    if (limit == null) return;
    await _runFaceRebuild(limit: limit < 0 ? null : limit);
  }

  Future<void> _runFaceRebuild({int? limit}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(limit == 20 ? 'فهرسة 20 صورة جديدة؟' : 'إكمال فهرسة الوجوه؟'),
          content: Text(
            limit == 20
                ? 'سيتم تخطي كل صورة اكتملت سابقًا بـFace v3 ومعالجة 20 صورة غير مفهرسة فقط. يمكنك مغادرة صفحة الأشخاص وستستمر المعالجة داخل التطبيق.'
                : 'سيتم متابعة الصور غير المفهرسة فقط حتى نهاية المكتبة. يمكنك مغادرة صفحة الأشخاص؛ والتقدم محفوظ دائمًا. لا يتم تشغيل YOLO أو OCR.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('متابعة'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      final started = await FaceIndexService.instance.start(limit: limit);
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Face Lab يعمل بالفعل في الخلفية داخل التطبيق.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر بدء Face Lab: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xfff4f6fb),
        appBar: AppBar(
          backgroundColor: AppColors.navyDeep,
          foregroundColor: Colors.white,
          title: const Text('الأشخاص'),
          actions: [
            IconButton(
              onPressed: _rebuilding ? null : _startFaceRebuild,
              tooltip: 'Face Lab v3 — اختبار الوجوه فقط',
              icon: const Icon(Icons.face_retouching_natural),
            ),
            IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: Column(
          children: [
            _PeopleInfoBanner(
              candidateCount: _candidateCount,
              rebuilding: _rebuilding,
              processed: _rebuildProcessed,
              total: _rebuildTotal,
              failed: _rebuildFailed,
              detected: _rebuildDetected,
              ignored: _rebuildIgnored,
              status: _rebuildStatus,
              onStop: _rebuilding ? FaceIndexService.instance.stop : null,
              onRebuild: _rebuilding ? null : _startFaceRebuild,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
              child: Card(
                elevation: 0,
                child: SwitchListTile.adaptive(
                  value: _backgroundFacesEnabled,
                  onChanged: _toggleBackgroundFaces,
                  secondary: const Icon(Icons.battery_saver_outlined),
                  title: const Text(
                    'معالجة الأشخاص بالخلفية',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Android يعالج دفعات صغيرة من 4 صور عند توفر البطارية والحرارة المناسبة. Face Lab اليدوي يبقى أسرع.',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
            ),
            if (_candidateCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _showCandidates
                            ? 'نعرض الآن كل التجمعات، حتى الشخص الموجود في صورة واحدة.'
                            : 'يوجد $_candidateCount تجمع مخفي أقل من 3 صور.',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Colors.blueGrey,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      selected: _showCandidates,
                      label: Text(
                        _showCandidates ? 'إخفاء المرشحين' : 'إظهار المرشحين',
                      ),
                      onSelected: (value) async {
                        setState(() => _showCandidates = value);
                        await _reload();
                      },
                    ),
                  ],
                ),
              ),
            Expanded(
              child: people == null
                  ? const Center(child: CircularProgressIndicator())
                  : people.isEmpty
                  ? const _PeopleEmpty()
                  : GridView.builder(
                      padding: const EdgeInsets.all(14),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: .82,
                          ),
                      itemCount: people.length,
                      itemBuilder: (context, index) {
                        final person = people[index];
                        return _PersonCard(
                          person: person,
                          onRename: () => _rename(person),
                          onMerge: () => _merge(person),
                          onTap: () async {
                            await context.push(
                              AppRoutes.personDetail,
                              extra: person.id,
                            );
                            _reload();
                          },
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

class _PeopleInfoBanner extends StatelessWidget {
  final int candidateCount;
  final bool rebuilding;
  final int processed;
  final int total;
  final int failed;
  final int detected;
  final int ignored;
  final String? status;
  final VoidCallback? onStop;
  final VoidCallback? onRebuild;

  const _PeopleInfoBanner({
    required this.candidateCount,
    required this.rebuilding,
    required this.processed,
    required this.total,
    required this.failed,
    required this.detected,
    required this.ignored,
    required this.status,
    required this.onStop,
    required this.onRebuild,
  });

  @override
  Widget build(BuildContext context) {
    final progress = total <= 0
        ? null
        : (processed / total).clamp(0.0, 1.0).toDouble();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'الألبوم يظهر تلقائيًا بعد وجود الشخص في 3 صور مختلفة. الألبوم الذي تسميه بنفسك يظهر فورًا.',
            style: TextStyle(fontSize: 12, height: 1.35),
          ),
          if (candidateCount > 0) ...[
            const SizedBox(height: 5),
            Text(
              '$candidateCount مجموعة مرشحة مخفية تنتظر صورًا إضافية أو دمجًا آمنًا.',
              style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
            ),
          ],
          if (!rebuilding) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: onRebuild,
                icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                label: const Text('Face Lab v3 — وجوه فقط'),
              ),
            ),
          ],
          if (rebuilding || status != null) ...[
            const SizedBox(height: 9),
            if (rebuilding) LinearProgressIndicator(value: progress),
            const SizedBox(height: 5),
            Text(
              status ?? 'إعادة بناء الوجوه… $processed/$total',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (rebuilding)
              Row(
                children: [
                  Text(
                    '$processed/$total  •  كشف: $detected  •  تجاهل بعيد/ضعيف: $ignored  •  تعذر: $failed',
                    style: const TextStyle(fontSize: 11),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('إيقاف'),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _PersonCard extends StatelessWidget {
  final PersonGroup person;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onMerge;

  const _PersonCard({
    required this.person,
    required this.onTap,
    required this.onRename,
    required this.onMerge,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _PersonCover(person: person)),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          person.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '${person.photoCount} صورة',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'خيارات الشخص',
                    onSelected: (value) {
                      if (value == 'rename') onRename();
                      if (value == 'merge') onMerge();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'rename',
                        child: ListTile(
                          leading: Icon(Icons.badge_outlined),
                          title: Text('تسمية / تعديل الاسم'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'merge',
                        child: ListTile(
                          leading: Icon(Icons.merge_type),
                          title: Text('دمج مع شخص آخر'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonCover extends StatelessWidget {
  final PersonGroup person;

  const _PersonCover({required this.person});

  @override
  Widget build(BuildContext context) {
    final faceBytes = person.coverFaceJpeg;
    if (faceBytes != null && faceBytes.isNotEmpty) {
      return Image.memory(
        faceBytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      );
    }
    final assetId = person.coverAssetId;
    if (assetId == null) {
      return const ColoredBox(
        color: Color(0xffdfe5ef),
        child: Icon(Icons.face_retouching_natural, size: 52),
      );
    }
    // Compatibility fallback for albums created by the old pipeline. A v2.1
    // rebuild will replace this with the cropped best face.
    return FutureBuilder<AssetEntity?>(
      future: AssetEntity.fromId(assetId),
      builder: (context, snapshot) {
        final asset = snapshot.data;
        if (asset == null) {
          return const ColoredBox(
            color: Color(0xffdfe5ef),
            child: Icon(Icons.face_retouching_natural, size: 52),
          );
        }
        return AssetEntityImage(
          asset,
          isOriginal: false,
          thumbnailSize: const ThumbnailSize.square(420),
          fit: BoxFit.cover,
        );
      },
    );
  }
}

class _PeopleEmpty extends StatelessWidget {
  const _PeopleEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.face_retouching_natural, size: 64),
            SizedBox(height: 12),
            Text(
              'ابدأ الفهرسة أو أعد بناء الأشخاص. يظهر الألبوم التلقائي بعد 3 صور للشخص نفسه.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class PersonDetailScreen extends StatefulWidget {
  final String personId;

  const PersonDetailScreen({super.key, required this.personId});

  @override
  State<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<PersonDetailScreen> {
  final _repository = PersonRepository();
  PersonGroup? _person;
  List<AssetEntity>? _assets;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final person = await _repository.person(widget.personId);
    final ids = await _repository.assetIdsForPerson(widget.personId);
    final resolved = await Future.wait(ids.map(AssetEntity.fromId));
    if (mounted) {
      setState(() {
        _person = person;
        _assets = resolved.whereType<AssetEntity>().toList(growable: false);
      });
    }
  }

  Future<void> _removeWrongAsset(AssetEntity asset) async {
    final person = _person;
    if (person == null) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('هذه الصورة ليست لهذا الشخص؟'),
          content: Text(
            'سنزيل الصورة من ألبوم «${person.name}» ونتذكر هذا التصحيح كي لا يعيد المحرك إسنادها لنفس الشخص.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('إزالة'),
            ),
          ],
        ),
      ),
    );
    if (remove != true) return;
    await _repository.removeAsset(person.id, asset.id);
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تم التصحيح. سيعاد تصنيف وجه الصورة في التحليل القادم.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    final assets = _assets;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.navyDeep,
          foregroundColor: Colors.white,
          title: Text(person?.name ?? 'ألبوم شخص'),
        ),
        body: assets == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
                    child: Text(
                      'ضغط مطوّل على أي صورة إذا كانت لا تخص هذا الشخص.',
                      style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.all(4),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 4,
                            mainAxisSpacing: 4,
                          ),
                      itemCount: assets.length,
                      itemBuilder: (context, index) {
                        final asset = assets[index];
                        return InkWell(
                          onLongPress: () => _removeWrongAsset(asset),
                          onTap: () => context.push(
                            AppRoutes.detail,
                            extra: {
                              'id': asset.id,
                              'items': assets
                                  .map(MediaItem.fromAsset)
                                  .toList(growable: false),
                            },
                          ),
                          child: AssetEntityImage(
                            asset,
                            isOriginal: false,
                            thumbnailSize: const ThumbnailSize.square(300),
                            fit: BoxFit.cover,
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
