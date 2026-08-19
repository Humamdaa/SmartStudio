import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/models/media_item.dart';
import '../../services/ai/face_service.dart';

Future<void> showFaceStickerSheet({
  required BuildContext context,
  required MediaItem item,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF101820),
    useSafeArea: true,
    builder: (_) => FaceStickerSheet(item: item),
  );
}

class FaceStickerSheet extends StatefulWidget {
  final MediaItem item;

  const FaceStickerSheet({
    super.key,
    required this.item,
  });

  @override
  State<FaceStickerSheet> createState() => _FaceStickerSheetState();
}

class _FaceStickerSheetState extends State<FaceStickerSheet> {
  bool _loading = true;
  bool _sharing = false;
  String? _error;

  Uint8List? _previewBytes;
  int _imageWidth = 1;
  int _imageHeight = 1;
  List<_FaceStickerCandidate> _faces = const [];
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadFaces();
  }

  Future<void> _loadFaces() async {
    try {
      final file = await widget.item.asset.originFile;
      if (file == null) {
        throw StateError('تعذر الوصول إلى ملف الصورة الأصلي');
      }

      final detected = await FaceService.instance.detectFaces(file.path);
      final rawBytes = await file.readAsBytes();
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) {
        throw StateError('تعذر فتح الصورة');
      }

      // نفس الفكرة الموجودة في FaceService: نثبت EXIF حتى تتطابق أبعاد
      // الصورة المرئية مع إحداثيات ML Kit قدر الإمكان على صور الهاتف.
      final baked = img.bakeOrientation(decoded);
      final candidates = <_FaceStickerCandidate>[];

      for (var i = 0; i < detected.length; i++) {
        final rect = detected[i].boundingBox;
        final clipped = _clipRect(
          rect,
          imageWidth: baked.width,
          imageHeight: baked.height,
        );
        if (clipped.width < 2 || clipped.height < 2) continue;

        final crop = _cropFaceSticker(baked, clipped);
        candidates.add(
          _FaceStickerCandidate(
            index: i,
            normalizedRect: Rect.fromLTRB(
              clipped.left / baked.width,
              clipped.top / baked.height,
              clipped.right / baked.width,
              clipped.bottom / baked.height,
            ),
            pngBytes: Uint8List.fromList(img.encodePng(crop)),
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _previewBytes = Uint8List.fromList(img.encodeJpg(baked, quality: 90));
        _imageWidth = baked.width;
        _imageHeight = baked.height;
        _faces = candidates;
        _selectedIndex = 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Rect _clipRect(
    Rect rect, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final left = rect.left.clamp(0.0, imageWidth.toDouble());
    final top = rect.top.clamp(0.0, imageHeight.toDouble());
    final right = rect.right.clamp(0.0, imageWidth.toDouble());
    final bottom = rect.bottom.clamp(0.0, imageHeight.toDouble());
    return Rect.fromLTRB(left, top, right, bottom);
  }

  img.Image _cropFaceSticker(img.Image image, Rect faceRect) {
    // نترك مساحة حول الوجه بدل قصّ الذقن/الشعر مباشرة.
    // 1.70 تعني تقريباً 35% فراغ إضافي حول كل جهة مقارنة بالوجه نفسه.
    final side = math.max(faceRect.width, faceRect.height) * 1.70;
    final cx = (faceRect.left + faceRect.right) / 2;
    final cy = (faceRect.top + faceRect.bottom) / 2;

    final left = (cx - side / 2)
        .round()
        .clamp(0, math.max(0, image.width - 1))
        .toInt();
    final top = (cy - side / 2)
        .round()
        .clamp(0, math.max(0, image.height - 1))
        .toInt();
    final width = side
        .round()
        .clamp(1, math.max(1, image.width - left))
        .toInt();
    final height = side
        .round()
        .clamp(1, math.max(1, image.height - top))
        .toInt();

    final cropped = img.copyCrop(
      image,
      x: left,
      y: top,
      width: width,
      height: height,
    );

    // Telegram/Sticker workflows غالباً ترتاح مع صورة مربعة؛ هذه ليست بعد
    // "Sticker" بخلفية شفافة، بل crop جاهز للمرحلة التالية.
    return img.copyResizeCropSquare(cropped, size: 512);
  }

  Future<void> _shareSelected() async {
    if (_faces.isEmpty || _sharing) return;
    setState(() => _sharing = true);

    try {
      final selected = _faces[_selectedIndex];
      final temp = await getTemporaryDirectory();
      final output = File(
        '${temp.path}/pixmind_face_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await output.writeAsBytes(selected.pngBytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(output.path, mimeType: 'image/png')],
          title: 'PixMind Face',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر مشاركة الوجه: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          children: [
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Face Sticker',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }

    if (_previewBytes == null) {
      return const Center(
        child: Text('تعذر تحميل الصورة', style: TextStyle(color: Colors.white70)),
      );
    }

    return Column(
      children: [
        Expanded(
          flex: 5,
          child: Center(
            child: AspectRatio(
              aspectRatio: _imageWidth / _imageHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    _previewBytes!,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _FaceBoxesPainter(
                        faces: _faces,
                        selectedIndex: _selectedIndex,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (_faces.isEmpty)
          const Expanded(
            flex: 2,
            child: Center(
              child: Text(
                'لم يتم اكتشاف أي وجه في هذه الصورة.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          )
        else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'تم اكتشاف ${_faces.length} وجه — اختر الوجه المطلوب',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _faces.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final selected = index == _selectedIndex;
                return GestureDetector(
                  onTap: () => setState(() => _selectedIndex = index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 88,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected ? Colors.cyanAccent : Colors.white24,
                        width: selected ? 2.5 : 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _faces[index].pngBytes,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _sharing ? null : _shareSelected,
              icon: _sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share_rounded),
              label: Text(_sharing ? 'جاري التحضير…' : 'مشاركة الوجه'),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'حالياً نشارك قصاصة PNG. إزالة الخلفية وتحويلها إلى Sticker شفاف هي المرحلة التالية.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _FaceStickerCandidate {
  final int index;
  final Rect normalizedRect;
  final Uint8List pngBytes;

  const _FaceStickerCandidate({
    required this.index,
    required this.normalizedRect,
    required this.pngBytes,
  });
}

class _FaceBoxesPainter extends CustomPainter {
  final List<_FaceStickerCandidate> faces;
  final int selectedIndex;

  const _FaceBoxesPainter({
    required this.faces,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < faces.length; i++) {
      final r = faces[i].normalizedRect;
      final rect = Rect.fromLTRB(
        r.left * size.width,
        r.top * size.height,
        r.right * size.width,
        r.bottom * size.height,
      );

      final selected = i == selectedIndex;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 4 : 2.2
        ..color = selected ? Colors.cyanAccent : Colors.white;

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        paint,
      );

      final labelPainter = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            color: Colors.black,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            backgroundColor: selected ? Colors.cyanAccent : Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      labelPainter.paint(
        canvas,
        Offset(rect.left + 3, math.max(0, rect.top - labelPainter.height - 2)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FaceBoxesPainter oldDelegate) {
    return oldDelegate.faces != faces || oldDelegate.selectedIndex != selectedIndex;
  }
}
