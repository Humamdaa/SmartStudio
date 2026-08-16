import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core/constants/app_colors.dart';
import '../../core/router/app_router.dart';
import '../../core/widgets/ios_ui.dart';
import '../albums/indexing_providers.dart';

typedef _Suggestion = ({
  AssetEntity asset,
  double score,
  double quality,
  double fit,
  double faceScore,
  int faceCount,
  bool faceIndexed,
});

// ═══════════════════════════════════════════════════════════════
// اقتراح صور شخصية / غلاف يعمل محليًا بدون تشغيل مودل جديد من الشاشة.
// الترتيب يعتمد على تحليل الجودة المخزن + ملاءمة القص + الدقة الأصلية،
// وللصورة الشخصية يستفيد من نتائج الوجوه الموجودة مسبقًا إن توفرت.
// ═══════════════════════════════════════════════════════════════

class SuggestionsScreen extends ConsumerStatefulWidget {
  const SuggestionsScreen({super.key});

  @override
  ConsumerState<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends ConsumerState<SuggestionsScreen> {
  int _tab = 0; // 0 = شخصية، 1 = غلاف

  List<_Suggestion> _items = [];
  bool _loading = true;
  int _topIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await ref
        .read(indexingServiceProvider)
        .suggestPhotos(forProfile: _tab == 0);
    if (!mounted) return;
    setState(() {
      _items = items;
      _topIndex = 0;
      _loading = false;
    });
  }

  /// "اقتراح آخر" — منلفّ على المرشّحين بالترتيب.
  void _nextSuggestion() {
    if (_items.length < 2) return;
    setState(() => _topIndex = (_topIndex + 1) % _items.length);
  }

  @override
  Widget build(BuildContext context) {
    final isProfile = _tab == 0;
    final top = _items.isEmpty ? null : _items[_topIndex];

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
              IosLargeTitle(
                title: 'For You',
                subtitle: isProfile
                    ? 'Offline picks using quality, crop fit and indexed faces'
                    : 'Offline picks using quality, crop fit and resolution',
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: IosSegmented<int>(
                  value: _tab,
                  segments: const {0: 'Profile', 1: 'Cover'},
                  onChanged: (v) {
                    setState(() => _tab = v);
                    _load(); // الترتيب بيتغيّر حسب الأبعاد المطلوبة
                  },
                ),
              ),

              // ── الاقتراح الأفضل ───────────────────────────────
              const IosSectionHeader('Top pick'),
              IosCard(
                child: Column(
                  children: [
                    AspectRatio(
                      aspectRatio: isProfile ? 1 : 16 / 9,
                      child: ClipRRect(
                        borderRadius:
                            BorderRadius.circular(isProfile ? 400 : 12),
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.navyDeep.withValues(alpha: 0.07),
                            border: Border.all(
                                color: AppColors.mintAccent, width: 2.5),
                            borderRadius:
                                BorderRadius.circular(isProfile ? 400 : 12),
                          ),
                          child: _loading
                              ? const Center(
                                  child: CircularProgressIndicator(
                                      color: AppColors.navyDeep))
                              : top == null
                                  ? const Center(
                                      child: Icon(Icons.image_outlined,
                                          size: 42,
                                          color: AppColors.textHint))
                                  : Image(
                                      image: AssetEntityImageProvider(
                                        top.asset,
                                        isOriginal: false,
                                        thumbnailSize:
                                            const ThumbnailSize.square(600),
                                      ),
                                      fit: BoxFit.cover,
                                    ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (top != null)
                      Text(
                        'Overall match ${top.score.round()}/100',
                        style: const TextStyle(
                          color: AppColors.navyDeep,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        _ScorePill(
                          label: 'Quality',
                          value: top?.quality.round(),
                        ),
                        const SizedBox(width: 8),
                        if (isProfile) ...[
                          _ScorePill(
                            label: top?.faceIndexed == true
                                ? (top!.faceCount == 1 ? 'Face' : 'Faces')
                                : 'Face n/a',
                            value: top?.faceIndexed == true
                                ? top!.faceScore.round()
                                : null,
                          ),
                          const SizedBox(width: 8),
                        ],
                        _ScorePill(
                          label: isProfile ? 'Square fit' : 'Wide fit',
                          value: top?.fit.round(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed:
                                _items.length < 2 ? null : _nextSuggestion,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: kIosSeparator),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(22)),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                            ),
                            child: const Text('Another pick',
                                style: TextStyle(
                                    color: AppColors.navyDeep, fontSize: 13.5)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: top == null
                                ? null
                                : () => context.push(
                                      AppRoutes.editing,
                                      extra: top.asset.id,
                                    ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.navyDeep,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(22)),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                            ),
                            child: Text(
                              isProfile ? 'Edit for profile' : 'Edit for cover',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ── باقي المرشّحين ────────────────────────────────
              const IosSectionHeader('Other candidates'),
              SizedBox(
                height: isProfile ? 128 : 108,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _items.length,
                  itemBuilder: (_, i) {
                    final s = _items[i];
                    final active = i == _topIndex;
                    return GestureDetector(
                      onTap: () => setState(() => _topIndex = i),
                      child: Container(
                        width: isProfile ? 104 : 168,
                        margin: const EdgeInsets.only(right: 10),
                        child: Column(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                    isProfile ? 400 : 12),
                                child: Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                        isProfile ? 400 : 12),
                                    border: Border.all(
                                      color: active
                                          ? AppColors.mintAccent
                                          : kIosSeparator,
                                      width: active ? 2.5 : 1,
                                    ),
                                  ),
                                  child: Image(
                                    image: AssetEntityImageProvider(
                                      s.asset,
                                      isOriginal: false,
                                      thumbnailSize:
                                          const ThumbnailSize.square(300),
                                    ),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text('${s.score.round()}',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: active
                                        ? AppColors.navyDeep
                                        : AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

              // ── معايير الترشيح ────────────────────────────────
              const IosSectionHeader('Ranking criteria'),
              IosCard(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
                child: Column(
                  children: [
                    const IosRow(
                      icon: Icons.auto_awesome_rounded,
                      iconBg: AppColors.mintAccent,
                      title: 'Image quality',
                      subtitle: 'Sharpness, exposure and blur',
                    ),
                    if (isProfile)
                      const IosRow(
                        icon: Icons.face_rounded,
                        iconBg: AppColors.skyBlue,
                        title: 'Face suitability',
                        subtitle:
                            'Prefers one clear, well-sized face when already indexed',
                      ),
                    IosRow(
                      icon: Icons.crop_rounded,
                      iconBg: AppColors.navyDeep,
                      title: isProfile ? 'Square fit' : 'Wide fit',
                      subtitle: isProfile
                          ? 'Fits a 1:1 circular crop'
                          : 'Fits a wide 16:9 banner',
                    ),
                    const IosRow(
                      icon: Icons.high_quality_outlined,
                      iconBg: AppColors.skyBlue,
                      title: 'Original resolution',
                      subtitle: 'A small bonus for higher-resolution originals',
                      showDivider: false,
                    ),
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

class _ScorePill extends StatelessWidget {
  final String label;
  final int? value;
  const _ScorePill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: AppColors.navyDeep.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Text(value == null ? '—' : '$value',
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: AppColors.navyDeep)),
              Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
        ),
      );
}
