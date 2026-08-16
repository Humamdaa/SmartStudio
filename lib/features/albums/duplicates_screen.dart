import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core/constants/app_colors.dart';
import '../../core/providers/gallery_refresh_provider.dart';
import '../../core/widgets/ios_ui.dart';
import 'indexing_providers.dart';

// ═══════════════════════════════════════════════════════════════
// الصور المكرّرة.
//
// المستخدم هو اللي يقرّر شو ينحذف — منقترح فقط.
// كل صورة لحالها قابلة للتحديد، والاقتراح الافتراضي:
// نحتفظ بالأعلى جودة ونحدّد الباقي للحذف.
// ═══════════════════════════════════════════════════════════════

class _Group {
  final List<AssetEntity> assets;
  final List<double> scores; // درجة جودة كل صورة بنفس الترتيب
  _Group(this.assets, this.scores);
}

/// حساسية المطابقة — كل خيار له معنى عملي مختلف.
class _Sensitivity {
  final String label;
  final int threshold;
  final String description;
  const _Sensitivity(this.label, this.threshold, this.description);
}

const _sensitivities = [
  _Sensitivity('Identical', 2,
      'Exact copies — same photo saved twice (e.g. downloaded again).'),
  _Sensitivity('Very similar', 8,
      'Same photo, different size, compression or a light edit.'),
  _Sensitivity('Similar', 14,
      'Burst shots and near-identical scenes taken seconds apart.'),
];

class DuplicatesScreen extends ConsumerStatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  ConsumerState<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends ConsumerState<DuplicatesScreen> {
  List<_Group> _groups = [];

  /// معرّفات الصور المحدّدة للحذف — المستخدم يتحكّم فيها بالكامل.
  final Set<String> _toDelete = {};

  bool _loading = true;
  bool _deleting = false;
  String? _error;

  _Sensitivity _sensitivity = _sensitivities[1];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final svc = ref.read(indexingServiceProvider);
      final raw =
          await svc.findDuplicateGroups(threshold: _sensitivity.threshold);
      final quality = svc.qualityByAssetId();

      final resolved = <_Group>[];
      for (final ids in raw) {
        final assets = <AssetEntity>[];
        final scores = <double>[];
        for (final id in ids) {
          final a = await AssetEntity.fromId(id);
          if (a != null) {
            assets.add(a);
            scores.add(quality[id] ?? 0);
          }
        }
        if (assets.length > 1) resolved.add(_Group(assets, scores));
      }

      if (!mounted) return;
      setState(() {
        _groups = resolved;
        // الاقتراح الافتراضي: احتفظ بالأولى (الأعلى جودة)، حدّد الباقي
        _toDelete
          ..clear()
          ..addAll(resolved.expand((g) => g.assets.skip(1).map((a) => a.id)));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _toggle(String assetId) => setState(() {
        _toDelete.contains(assetId)
            ? _toDelete.remove(assetId)
            : _toDelete.add(assetId);
      });

  /// يمنع حذف مجموعة بالكامل — لازم يضل واحدة على الأقل.
  bool _wouldEmptyGroup(_Group g, String candidateId) {
    final remaining = g.assets
        .where((a) => a.id != candidateId && !_toDelete.contains(a.id))
        .length;
    return remaining == 0;
  }

  Future<void> _deleteSelected() async {
    if (_toDelete.isEmpty || _deleting) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Delete ${_toDelete.length} photo(s)?'),
        content: const Text(
            'The selected photos will be removed from your device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Delete',
                style: TextStyle(color: AppColors.errorRed)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    final deleted = await PhotoManager.editor.deleteWithIds(_toDelete.toList());

    if (deleted.isNotEmpty) {
      // مهم: نشيل تحليلهم كمان، وإلا بيضلّوا يظهروا بالنتائج
      // وبيضل العدّاد يحسبهم رغم إنهم انحذفوا فعليًا.
      ref.read(indexingServiceProvider).removeAnalysisFor(deleted);
    }

    if (!mounted) return;
    setState(() => _deleting = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(deleted.isEmpty
          ? 'Nothing was deleted'
          : 'Deleted ${deleted.length} photo(s)'),
      backgroundColor: deleted.isEmpty ? AppColors.errorRed : null,
    ));

    if (deleted.isNotEmpty) {
      ref.read(galleryNeedsRefreshProvider.notifier).state = true;
      _load(); // إعادة بناء المجموعات بدون المحذوفات
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: kIosGroupedBg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              IosLargeTitle(
                title: 'Duplicates',
                subtitle: _loading
                    ? 'Scanning…'
                    : '${_groups.length} groups · ${_toDelete.length} selected',
                onBack: () => context.pop(),
              ),
              _buildSensitivity(),
              Expanded(child: _buildBody()),
              if (!_loading && _error == null && _groups.isNotEmpty)
                _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSensitivity() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IosSegmented<int>(
              value: _sensitivity.threshold,
              segments: {
                for (final s in _sensitivities) s.threshold: s.label,
              },
              onChanged: (v) {
                setState(() => _sensitivity =
                    _sensitivities.firstWhere((s) => s.threshold == v));
                _load();
              },
            ),
            const SizedBox(height: 7),
            Text(_sensitivity.description,
                style: const TextStyle(
                    fontSize: 11.5, color: AppColors.textSecondary)),
          ],
        ),
      );

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.navyDeep));
    }
    if (_error != null) {
      return _message(
        icon: Icons.error_outline_rounded,
        color: AppColors.errorRed,
        title: 'Could not scan for duplicates',
        body: _error!,
        action: TextButton(onPressed: _load, child: const Text('Try again')),
      );
    }
    if (_groups.isEmpty) {
      return _message(
        icon: Icons.check_rounded,
        color: AppColors.navyDeep,
        title: 'No duplicates found',
        body: 'Your library is still being analyzed in the background. '
            'Come back in a moment if you just installed the app.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _groups.length,
      itemBuilder: (_, i) => _buildGroupCard(i),
    );
  }

  Widget _message({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    Widget? action,
  }) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 30, color: color),
              ),
              const SizedBox(height: 14),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 6),
              Text(body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.textSecondary)),
              if (action != null) ...[const SizedBox(height: 10), action],
            ],
          ),
        ),
      );

  Widget _buildGroupCard(int i) {
    final group = _groups[i];
    final markedInGroup =
        group.assets.where((a) => _toDelete.contains(a.id)).length;

    return IosCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Group ${i + 1}',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(width: 8),
              IosBadge('${group.assets.length} photos'),
              const Spacer(),
              Text('$markedInGroup selected',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Tap a photo to keep or remove it',
              style: TextStyle(fontSize: 11, color: AppColors.textHint)),
          const SizedBox(height: 8),
          SizedBox(
            height: 96,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: group.assets.length,
              itemBuilder: (_, j) => _buildThumb(group, j),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumb(_Group group, int j) {
    final asset = group.assets[j];
    final quality = group.scores[j];
    final marked = _toDelete.contains(asset.id);
    final isTopScore = j == 0;

    return GestureDetector(
      onTap: () {
        // ما منسمح يحذف كل المجموعة — لازم يضل نسخة وحدة
        if (!marked && _wouldEmptyGroup(group, asset.id)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Keep at least one photo in each group')),
          );
          return;
        }
        _toggle(asset.id);
      },
      child: Container(
        width: 84,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: marked ? AppColors.errorRed : AppColors.mintAccent,
            width: 2.4,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(fit: StackFit.expand, children: [
            Image(
              image: AssetEntityImageProvider(
                asset,
                isOriginal: false,
                thumbnailSize: const ThumbnailSize.square(200),
              ),
              fit: BoxFit.cover,
            ),
            if (marked)
              Container(color: AppColors.errorRed.withValues(alpha: 0.35)),

            // حالة الصورة: محذوفة أم محفوظة
            Positioned(
              top: 3,
              left: 3,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: marked ? AppColors.errorRed : AppColors.mintAccent,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  marked ? Icons.delete_outline_rounded : Icons.check_rounded,
                  size: 13,
                  color: marked ? Colors.white : Colors.black87,
                ),
              ),
            ),

            // أعلى جودة بالمجموعة — مجرّد اقتراح
            if (isTopScore)
              const Positioned(top: 3, right: 3, child: _TopBadge()),

            // درجة الجودة
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text('Q ${quality.round()}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildBottomBar() => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: kIosSeparator)),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Q = quality score (sharpness, exposure, resolution)',
                style:
                    TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
            ),
            ElevatedButton.icon(
              onPressed:
                  _toDelete.isEmpty || _deleting ? null : _deleteSelected,
              icon: _deleting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.delete_outline_rounded,
                      color: Colors.white, size: 18),
              label: Text('Delete ${_toDelete.length}',
                  style:
                      const TextStyle(color: Colors.white, fontSize: 13.5)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.errorRed,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22)),
              ),
            ),
          ],
        ),
      );
}

class _TopBadge extends StatelessWidget {
  const _TopBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text('TOP Q',
            style: TextStyle(
                fontSize: 7.5,
                fontWeight: FontWeight.w800,
                color: Colors.white)),
      );
}
