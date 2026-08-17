import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/constants/app_colors.dart';
import '../../core/providers/gallery_refresh_provider.dart';

// ═══════════════════════════════════════════════════════════════
// كولاج — دمج أكثر من صورة بشبكة، مبني على dart:ui بدون مكتبات.
//
// نفس فكرة المحرّر: نفس دالة الرسم بتستخدم للمعاينة وللتصدير،
// فاللي بتشوفه هو بالضبط اللي بينحفظ.
// ═══════════════════════════════════════════════════════════════

/// تخطيط الشبكة: عدد الأعمدة والصفوف.
class CollageLayout {
  final String label;
  final int cols;
  final int rows;
  const CollageLayout(this.label, this.cols, this.rows);

  int get capacity => cols * rows;
}

const _layouts = [
  CollageLayout('1×2', 1, 2),
  CollageLayout('2×1', 2, 1),
  CollageLayout('2×2', 2, 2),
  CollageLayout('2×3', 2, 3),
  CollageLayout('3×3', 3, 3),
];

class CollageScreen extends ConsumerStatefulWidget {
  /// الأصول اللي اختارها المستخدم قبل ما يفتح الشاشة.
  final List<AssetEntity> assets;
  const CollageScreen({super.key, required this.assets});

  @override
  ConsumerState<CollageScreen> createState() => _CollageScreenState();
}

class _CollageScreenState extends ConsumerState<CollageScreen> {
  final List<ui.Image> _images = [];
  bool _loading = true;
  bool _saving = false;

  CollageLayout _layout = _layouts[2];
  double _gap = 8; // بالبكسل على مقاس الخرج
  double _radius = 12;
  Color _bg = Colors.white;

  /// مقاس الخرج النهائي (مربع افتراضياً، بيتعدّل حسب التخطيط).
  static const _cell = 900.0;

  @override
  void initState() {
    super.initState();
    _load();
    // نختار تخطيط يناسب عدد الصور تلقائياً
    final n = widget.assets.length;
    _layout = _layouts.firstWhere(
      (l) => l.capacity >= n,
      orElse: () => _layouts.last,
    );
  }

  @override
  void dispose() {
    for (final img in _images) {
      img.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    for (final asset in widget.assets) {
      try {
        final file = await asset.originFile;
        if (file == null) continue;
        final bytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(
          bytes,
          // منصغّرها شوي — الكولاج ما بده الدقّة الكاملة لكل صورة
          targetWidth: 1200,
        );
        final frame = await codec.getNextFrame();
        _images.add(frame.image);
      } catch (_) {
        // منتجاهل أي صورة ما فتحت ومنكمّل
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Size get _outputSize => Size(_cell * _layout.cols, _cell * _layout.rows);

  Future<void> _save() async {
    if (_images.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final out = _outputSize;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      _paintCollage(
        canvas: canvas,
        size: out,
        images: _images,
        layout: _layout,
        gap: _gap,
        radius: _radius,
        bg: _bg,
      );
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(
        out.width.round(),
        out.height.round(),
      );
      picture.dispose();

      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      rendered.dispose();
      if (data == null) throw Exception('encode failed');

      await PhotoManager.editor.saveImage(
        data.buffer.asUint8List(),
        filename:
            'PixMind_collage_${DateTime.now().millisecondsSinceEpoch}.png',
        title: 'PixMind collage',
      );

      if (!mounted) return;
      ref.read(galleryNeedsRefreshProvider.notifier).state = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Collage saved to your gallery')),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to save the collage'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Collage', style: TextStyle(fontSize: 18)),
          actions: [
            _saving
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 18),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.mintAccent,
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: ElevatedButton(
                      onPressed: _images.isEmpty ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.mintAccent,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: const Text(
                        'Save',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
          ],
        ),
        body: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.mintAccent),
              )
            : _images.isEmpty
            ? const Center(
                child: Text(
                  'Could not open the selected photos',
                  style: TextStyle(color: Colors.white54),
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _outputSize.width / _outputSize.height,
                          child: CustomPaint(
                            painter: _CollagePainter(
                              images: _images,
                              layout: _layout,
                              gap: _gap,
                              radius: _radius,
                              bg: _bg,
                              outputSize: _outputSize,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _buildPanel(),
                ],
              ),
      ),
    );
  }

  Widget _buildPanel() {
    return Container(
      color: const Color(0xFF12181F),
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // التخطيطات
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: _layouts.map((l) {
                final active = l.label == _layout.label;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _layout = l),
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.mintAccent
                            : Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(19),
                      ),
                      child: Text(
                        l.label,
                        style: TextStyle(
                          color: active ? Colors.black : Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          _slider('Gap', _gap, 0, 40, (v) => setState(() => _gap = v)),
          _slider(
            'Corners',
            _radius,
            0,
            60,
            (v) => setState(() => _radius = v),
          ),
          // لون الخلفية
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children:
                  const [
                    Colors.white,
                    Colors.black,
                    Color(0xFF1A3A5C),
                    Color(0xFF0FDFAF),
                    Color(0xFFFFCC00),
                    Color(0xFFFF3B30),
                  ].map((c) {
                    final active = c == _bg;
                    return GestureDetector(
                      onTap: () => setState(() => _bg = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: active
                                ? AppColors.mintAccent
                                : Colors.white24,
                            width: active ? 3 : 1,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              activeTrackColor: AppColors.mintAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: AppColors.mintAccent,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    ),
  );
}

/// يرسم الكولاج — تُستخدم للمعاينة وللتصدير بنفس المنطق.
void _paintCollage({
  required Canvas canvas,
  required Size size,
  required List<ui.Image> images,
  required CollageLayout layout,
  required double gap,
  required double radius,
  required Color bg,
}) {
  canvas.drawRect(Offset.zero & size, Paint()..color = bg);

  final cellW = (size.width - gap * (layout.cols + 1)) / layout.cols;
  final cellH = (size.height - gap * (layout.rows + 1)) / layout.rows;

  for (var i = 0; i < layout.capacity && i < images.length; i++) {
    final col = i % layout.cols;
    final row = i ~/ layout.cols;
    final rect = Rect.fromLTWH(
      gap + col * (cellW + gap),
      gap + row * (cellH + gap),
      cellW,
      cellH,
    );

    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));

    // نملأ الخانة مع الحفاظ على نسبة الصورة (cover)
    final img = images[i];
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    final scale = math.max(rect.width / iw, rect.height / ih);
    final dw = iw * scale;
    final dh = ih * scale;
    final dst = Rect.fromCenter(center: rect.center, width: dw, height: dh);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, iw, ih),
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();
  }
}

class _CollagePainter extends CustomPainter {
  final List<ui.Image> images;
  final CollageLayout layout;
  final double gap;
  final double radius;
  final Color bg;
  final Size outputSize;

  _CollagePainter({
    required this.images,
    required this.layout,
    required this.gap,
    required this.radius,
    required this.bg,
    required this.outputSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // منرسم بمقاس الخرج الحقيقي ومنصغّره — فالمعاينة مطابقة تماماً
    final scale = size.width / outputSize.width;
    canvas.save();
    canvas.scale(scale);
    _paintCollage(
      canvas: canvas,
      size: outputSize,
      images: images,
      layout: layout,
      gap: gap,
      radius: radius,
      bg: bg,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CollagePainter old) => true;
}
