import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core/constants/app_colors.dart';
import '../../core/router/app_router.dart';
import '../../core/widgets/ios_ui.dart';
import '../../data/database/db_helper.dart';
import '../../data/models/media_item.dart';
import '../../services/indexing_service.dart';
import 'indexing_providers.dart';

// ═══════════════════════════════════════════════════════════════
// تنظيم الصور والألبومات الذكية.
//
// فهرسة ObjectBox + كشف المكرّر شغّالين من نسخة الفريق.
// ألبومات الأشخاص الحقيقية مربوطة بمحرك الوجوه المدموج من v2.1.1.
// الوصف التلقائي ما زال خيار واجهة ولم نربطه بمودل في هذه النسخة.
// ═══════════════════════════════════════════════════════════════

class SmartAlbumsScreen extends ConsumerStatefulWidget {
  const SmartAlbumsScreen({super.key});

  @override
  ConsumerState<SmartAlbumsScreen> createState() => _SmartAlbumsScreenState();
}

class _SmartAlbumsScreenState extends ConsumerState<SmartAlbumsScreen> {
  /// إجمالي صور الجهاز — لعرض "X من Y محلّلة".
  int _totalPhotos = 0;
  Map<String, int> _suggestedCounts = const {
    'nature': 0,
    'documents': 0,
    'food': 0,
    'pets': 0,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final n = await ref.read(indexingServiceProvider).totalPhotoCount();
      if (mounted) setState(() => _totalPhotos = n);
      await _reloadOrganizationSignals();
    });
  }

  Future<void> _reloadOrganizationSignals() async {
    try {
      final database = DatabaseHelper.instance;
      final counts = <String, int>{};
      for (final key in const ['nature', 'documents', 'food', 'pets']) {
        counts[key] = (await database.getSuggestedAlbumAssetIds(key)).length;
      }
      if (!mounted) return;
      setState(() {
        _suggestedCounts = counts;
      });
    } catch (_) {
      // Suggestions are secondary UI. An incomplete index must never block the
      // Albums screen itself.
    }
  }

  Future<void> _openSuggestedAlbum(String key, String label) async {
    final ids = await DatabaseHelper.instance.getSuggestedAlbumAssetIds(key);
    final assets = <AssetEntity>[];
    for (final id in ids) {
      final asset = await AssetEntity.fromId(id);
      if (asset != null) assets.add(asset);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SuggestedAlbumResultsScreen(
          title: label,
          assets: assets,
        ),
      ),
    );
  }

  /// فحص يدوي — أسرع من التلقائي لأن المستخدم مستنّي النتيجة.
  Future<void> _startScan() async {
    await ref.read(indexingServiceProvider).indexLibrary();
    await _reloadOrganizationSignals();
  }

  /// بطاقة الفهرسة.
  ///
  /// الفهرسة تلقائية بالخلفية، بس منخلّي زر يدوي لأن التلقائية
  /// بطيئة عن قصد (استراحة 120ms بين الدفعات حتى ما تزاحم
  /// المستخدم). الزر بيشتغل بأقصى سرعة لما المستخدم مستعجل —
  /// وبيظهر **فقط** لما يكون في صور باقية فعلًا.
  Widget _buildIndexCard() {
    final progress = ref.watch(indexProgressProvider).valueOrNull ??
        const IndexProgress();
    final analyzed = ref.read(indexingServiceProvider).analyzedCount;
    final remaining = (_totalPhotos - analyzed).clamp(0, 1 << 30);

    return IosCard(
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.mintAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.auto_awesome_rounded,
                    color: AppColors.navyDeep, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Analyze library',
                        style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    Text(
                      progress.running
                          ? 'Analyzing ${progress.done} of ${progress.total}…'
                          : _totalPhotos > 0
                              ? '$analyzed of $_totalPhotos photos analyzed'
                              : 'Runs automatically in the background',
                      style: const TextStyle(
                          fontSize: 12.5, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              progress.running
                  ? TextButton(
                      onPressed: () =>
                          ref.read(indexingServiceProvider).cancel(),
                      child: const Text('Stop',
                          style: TextStyle(
                              color: AppColors.errorRed, fontSize: 13)),
                    )
                  // ما في داعي للزر لما يكون كل شي محلّل
                  : remaining == 0
                      ? const Icon(Icons.check_circle_rounded,
                          color: AppColors.mintAccent, size: 24)
                      : ElevatedButton(
                          onPressed: _startScan,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.navyDeep,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                          ),
                          child: Text('Finish $remaining',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13)),
                        ),
            ],
          ),
          if (progress.running) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 5,
                backgroundColor: kIosSeparator,
                valueColor: const AlwaysStoppedAnimation(AppColors.mintAccent),
              ),
            ),
          ],
        ],
      ),
    );
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
          child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              const IosLargeTitle(
                title: 'Smart Albums',
                subtitle: 'People, duplicates, sorting and captions',
              ),

              // ── حالة الفهرسة الحقيقية ─────────────────────────
              _buildIndexCard(),

              // ── الأشخاص ───────────────────────────────────────
              IosSectionHeader('People',
                  trailing: GestureDetector(
                    onTap: () => context.push(AppRoutes.people),
                    child: const Text('See all',
                        style: TextStyle(
                            color: AppColors.skyBlue,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  )),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: IosCard(
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
                  child: IosRow(
                    icon: Icons.face_retouching_natural_rounded,
                    iconBg: AppColors.skyBlue,
                    title: 'Real people albums',
                    subtitle: 'Local face grouping • albums appear after 3 photos',
                    showDivider: false,
                    onTap: () => context.push(AppRoutes.people),
                  ),
                ),
              ),

              // ── أدوات التنظيم ─────────────────────────────────
              const IosSectionHeader('Organization'),
              IosCard(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
                child: Column(
                  children: [
                    IosRow(
                      icon: Icons.copy_all_rounded,
                      iconBg: AppColors.errorRed,
                      title: 'Duplicate photos',
                      subtitle: 'Real pHash groups from analyzed photos',
                      trailing: const IosBadge(
                        'Scan',
                        color: AppColors.errorRed,
                      ),
                      onTap: () => context.push(AppRoutes.duplicates),
                    ),
                    const IosRow(
                      icon: Icons.face_retouching_natural_rounded,
                      iconBg: AppColors.skyBlue,
                      title: 'Face grouping',
                      subtitle: 'Active through the offline AI index',
                      trailing: IosBadge('On', color: AppColors.skyBlue),
                    ),
                    const IosRow(
                      icon: Icons.sort_rounded,
                      iconBg: AppColors.navyDeep,
                      title: 'Gallery organization',
                      subtitle: 'Folders, date and AI suggestions are available',
                      trailing: IosBadge('Active', color: AppColors.navyDeep),
                    ),
                    const IosRow(
                      icon: Icons.subtitles_outlined,
                      iconBg: AppColors.mintAccent,
                      title: 'Auto captions',
                      subtitle: 'Not enabled in this stable build',
                      showDivider: false,
                      trailing: IosBadge('Planned', color: AppColors.mintAccent),
                    ),
                  ],
                ),
              ),

              // ── ألبومات ذكية مقترحة ───────────────────────────
              const IosSectionHeader('Suggested albums'),
              SizedBox(
                height: 146,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _SmartAlbumCard(
                        icon: Icons.landscape_outlined,
                        label: 'Nature',
                        count: _suggestedCounts['nature'] ?? 0,
                        color: const Color(0xFF34C759),
                        onTap: () => _openSuggestedAlbum('nature', 'Nature')),
                    _SmartAlbumCard(
                        icon: Icons.description_outlined,
                        label: 'Documents',
                        count: _suggestedCounts['documents'] ?? 0,
                        color: const Color(0xFF2D5F9E),
                        onTap: () => _openSuggestedAlbum('documents', 'Documents')),
                    _SmartAlbumCard(
                        icon: Icons.restaurant_outlined,
                        label: 'Food',
                        count: _suggestedCounts['food'] ?? 0,
                        color: const Color(0xFFFF9500),
                        onTap: () => _openSuggestedAlbum('food', 'Food')),
                    _SmartAlbumCard(
                        icon: Icons.pets_outlined,
                        label: 'Pets',
                        count: _suggestedCounts['pets'] ?? 0,
                        color: const Color(0xFFAF52DE),
                        onTap: () => _openSuggestedAlbum('pets', 'Pets')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestedAlbumResultsScreen extends StatelessWidget {
  final String title;
  final List<AssetEntity> assets;

  const _SuggestedAlbumResultsScreen({
    required this.title,
    required this.assets,
  });

  @override
  Widget build(BuildContext context) {
    final items = assets.map(MediaItem.fromAsset).toList(growable: false);
    return Scaffold(
      backgroundColor: kIosGroupedBg,
      appBar: AppBar(
        title: Text('$title (${assets.length})'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
      ),
      body: assets.isEmpty
          ? const Center(
              child: Text(
                'No matching indexed photos yet.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 3,
                mainAxisSpacing: 3,
              ),
              itemCount: assets.length,
              itemBuilder: (context, index) {
                final asset = assets[index];
                return GestureDetector(
                  onTap: () => context.push(
                    AppRoutes.detail,
                    extra: {'id': asset.id, 'items': items},
                  ),
                  child: Image(
                    image: AssetEntityImageProvider(
                      asset,
                      isOriginal: false,
                      thumbnailSize: const ThumbnailSize.square(260),
                    ),
                    fit: BoxFit.cover,
                  ),
                );
              },
            ),
    );
  }
}

class _PersonBubble extends StatelessWidget {
  final String name;
  final int count;
  final VoidCallback onTap;
  const _PersonBubble({
    required this.name,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 76,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.navyDeep, AppColors.skyBlue],
                  ),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.person_rounded,
                    color: Colors.white, size: 30),
              ),
              const SizedBox(height: 6),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              Text('$count',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
        ),
      );
}

class _SmartAlbumCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final Color color;
  final VoidCallback onTap;
  const _SmartAlbumCard({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
        width: 122,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kIosSeparator),
        ),
        // spaceBetween بدل Spacer + mainAxisSize.min على النصوص
        // حتى ما يصير تجاوز 1 بكسل مع اختلاف ارتفاع الخطوط بين الأجهزة
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: color, size: 21),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text('$count photos',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12,
                        height: 1.2,
                        color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
}
