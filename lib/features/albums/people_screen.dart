import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core/constants/app_colors.dart';
import '../../core/router/app_router.dart';
import '../../data/models/media_item.dart';
import '../../data/models/person_group.dart';
import '../../data/repositories/person_repository.dart';
import '../../services/ai/face_service.dart';
import '../../services/device/device_health_service.dart';

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
  bool _cancelRebuild = false;
  int _rebuildProcessed = 0;
  int _rebuildTotal = 0;
  int _rebuildFailed = 0;
  int _rebuildDetected = 0;
  int _rebuildIgnored = 0;
  String? _rebuildStatus;

  @override
  void initState() {
    super.initState();
    _reload();
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
                ? 'سيتم تخطي كل صورة اكتملت سابقًا بـFace v3 ومعالجة 20 صورة غير مفهرسة فقط، بدءًا من الأحدث. التقدم محفوظ حتى لو أوقفت العملية.'
                : 'سيتم تخطي كل الصور المكتملة سابقًا ومتابعة الصور غير المفهرسة فقط حتى نهاية المكتبة. التقدم محفوظ حتى بعد إغلاق التطبيق. لا يتم تشغيل YOLO أو OCR.',
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

    setState(() {
      _rebuilding = true;
      _cancelRebuild = false;
      _rebuildProcessed = 0;
      _rebuildTotal = limit ?? 0;
      _rebuildFailed = 0;
      _rebuildDetected = 0;
      _rebuildIgnored = 0;
      _rebuildStatus = 'تجهيز Face Lab v3 واستعادة التقدم…';
    });

    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        throw StateError('لا يوجد إذن للوصول إلى الصور.');
      }
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      if (paths.isEmpty) {
        throw StateError('لا توجد صور متاحة للتحليل.');
      }
      final album = paths.first;
      final libraryTotal = await album.assetCountAsync;

      // One lightweight SQLite query restores persistent progress. We then
      // skip these ids while paging through the gallery; image bytes are never
      // opened for already-completed photos.
      final completedIds = await FaceService.instance.completedAssetIds();
      final estimatedRemaining =
          (libraryTotal - completedIds.length).clamp(0, libraryTotal).toInt();
      // The database may still contain ids for photos deleted from the device,
      // so this number is only a UI estimate. The actual stop condition below
      // is based on finding 20 new photos or physically reaching gallery end.
      final displayTarget = limit ?? estimatedRemaining;

      if (!mounted) return;
      setState(() {
        _rebuildTotal = displayTarget;
        _rebuildStatus =
            'متبقٍ تقريبًا $estimatedRemaining صورة للوجوه؛ جاري التحقق من المكتبة…';
      });

      const pageSize = 60;
      var page = 0;
      var reachedLibraryEnd = false;
      while ((limit == null || _rebuildProcessed < limit) &&
          !_cancelRebuild &&
          mounted) {
        final assets = await album.getAssetListPaged(page: page, size: pageSize);
        if (assets.isEmpty) {
          reachedLibraryEnd = true;
          break;
        }
        page++;

        for (final asset in assets) {
          if (_cancelRebuild ||
              !mounted ||
              (limit != null && _rebuildProcessed >= limit)) {
            break;
          }

          // This is the key resume rule: an already-complete photo costs no
          // face detection, image decode, alignment, or MobileFaceNet pass.
          if (completedIds.contains(asset.id)) continue;

          if (_rebuildProcessed % 4 == 0) {
            final gate = await DeviceHealthService.instance.canContinueIndexing(
              checkLowBattery: false,
              checkThermal: true,
            );
            if (!gate.allowed) {
              setState(() => _rebuildStatus = gate.reason);
              _cancelRebuild = true;
              break;
            }
          }

          final file = await asset.file;
          if (file == null) {
            _rebuildProcessed++;
            _rebuildFailed++;
            continue;
          }
          if (mounted) {
            setState(() {
              _rebuildStatus = limit == null
                  ? 'Face Lab فقط: ${asset.title ?? 'صورة'}  '
                        '${_rebuildProcessed + 1} صورة جديدة'
                  : 'Face Lab فقط: ${asset.title ?? 'صورة'}  '
                        '${_rebuildProcessed + 1}/$limit';
            });
          }
          try {
            final result = await FaceService.instance.analyzeAndStore(
              assetId: asset.id,
              imagePath: file.path,
              // Do not force a rerun. Old/partial pipeline rows are still
              // reprocessed automatically by FaceService itself.
              force: false,
            );
            _rebuildDetected += result.detectedFaceCount;
            _rebuildIgnored += result.ignoredFaceCount;
          } catch (error, stackTrace) {
            _rebuildFailed++;
            debugPrint('PixMind Face Lab ${asset.id}: $error\n$stackTrace');
          }
          _rebuildProcessed++;

          if (_rebuildProcessed % 20 == 0) {
            // Global refinement uses stored embeddings only; no inference is
            // repeated here.
            await FaceService.instance.refineClusters(maxMerges: 80);
            await _reload();
          } else if (mounted) {
            setState(() {});
          }
        }
      }

      // If stale database ids made the initial estimate slightly optimistic,
      // make the progress bar finish honestly at the amount actually found.
      if (reachedLibraryEnd && _rebuildProcessed < _rebuildTotal && mounted) {
        setState(() => _rebuildTotal = _rebuildProcessed);
      }

      if (!_cancelRebuild && _rebuildProcessed > 0) {
        await FaceService.instance.refineClusters(maxMerges: 160);
      }
      await _reload();
      if (mounted) {
        setState(() {
          if (_cancelRebuild) {
            _rebuildStatus =
                'تم إيقاف Face Lab بعد $_rebuildProcessed صورة. التقدم محفوظ؛ المرة القادمة سيكمل من الصور غير المفهرسة.';
          } else if (_rebuildProcessed == 0) {
            _rebuildStatus = 'كل الصور الحالية مفهرسة للوجوه بالفعل.';
          } else {
            _rebuildStatus =
                'اكتمل Face Lab: عالج $_rebuildProcessed صورة جديدة، '
                'كشف $_rebuildDetected وجهًا وتجاهل $_rebuildIgnored وجهًا بعيدًا/ضعيفًا. '
                'تعذر $_rebuildFailed صورة. الضغط مرة أخرى سيبدأ من الصور المتبقية.';
          }
        });
      }
    } catch (error, stackTrace) {
      debugPrint('PixMind Face Lab failed: $error\n$stackTrace');
      if (mounted) {
        setState(() => _rebuildStatus = 'تعذر Face Lab: $error');
      }
    } finally {
      if (mounted) setState(() => _rebuilding = false);
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
              onStop: _rebuilding
                  ? () => setState(() => _cancelRebuild = true)
                  : null,
              onRebuild: _rebuilding ? null : _startFaceRebuild,
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
