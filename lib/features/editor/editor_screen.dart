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
// محرّر صور مبني من الصفر — بدون أي مكتبة تعديل خارجية.
//
// كل شي معتمد على dart:ui مباشرة:
//   • التدوير/القلب     → تحويلات على الـ Canvas
//   • القص              → مستطيل مصدر (src rect) وقت الرسم
//   • السطوع/التباين/التشبّع/الدفء → ColorFilter.matrix
//
// نفس الـ painter بيستخدم للمعاينة وللحفظ، فاللي بتشوفه
// هو بالضبط اللي بينحفظ.
// ═══════════════════════════════════════════════════════════════

enum _Tool { adjust, crop, draw, text, retouch }

/// خط مرسوم باليد — النقاط بإحداثيات نسبية 0..1 من مساحة الخرج،
/// حتى تضل صح مهما تغيّر حجم المعاينة أو دقّة التصدير.
class DrawStroke {
  final List<Offset> points;
  final Color color;
  final double width; // نسبة من عرض الخرج
  DrawStroke({required this.points, required this.color, required this.width});
}

/// نص مكتوب على الصورة.
class TextItem {
  Offset position; // نسبي 0..1
  String text;
  Color color;
  double size; // نسبة من عرض الخرج
  TextItem({
    required this.position,
    required this.text,
    required this.color,
    required this.size,
  });
}

/// بقعة تمويه لإخفاء/إزالة شي من الصورة.
class RetouchBlob {
  final Offset center; // نسبي 0..1
  final double radius; // نسبة من عرض الخرج
  RetouchBlob({required this.center, required this.radius});
}

class EditingScreen extends ConsumerStatefulWidget {
  final String assetId;
  const EditingScreen({super.key, required this.assetId});

  @override
  ConsumerState<EditingScreen> createState() => _EditingScreenState();
}

class _EditingScreenState extends ConsumerState<EditingScreen> {
  ui.Image? _image;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  _Tool _tool = _Tool.adjust;

  // التعديلات
  int _quarterTurns = 0; // 0..3
  bool _flipH = false;
  bool _flipV = false;
  double _brightness = 0; // -1..1
  double _contrast = 1; // 0..2
  double _saturation = 1; // 0..2
  double _warmth = 0; // -1..1

  // مستطيل القص بإحداثيات نسبية 0..1 من الصورة الأصلية
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1);

  // ── التعليقات (رسم/نص/تمويه) ─────────────────────────────────
  final List<DrawStroke> _strokes = [];
  final List<TextItem> _texts = [];
  final List<RetouchBlob> _retouches = [];
  DrawStroke? _activeStroke;

  /// النص المحدّد حالياً — بينحرّك ويتكبّر ويتغيّر لونه.
  int? _selectedText;
  double _textSizeAtScaleStart = 0;

  Color _brushColor = const Color(0xFFFF3B30);
  double _brushWidth = 0.012; // نسبة من عرض الخرج
  double _retouchRadius = 0.06;
  double _textSize = 0.09;

  static const _palette = [
    Color(0xFFFF3B30),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF0FDFAF),
    Color(0xFF007AFF),
    Color(0xFFAF52DE),
    Colors.white,
    Colors.black,
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final asset = await AssetEntity.fromId(widget.assetId);
      final file = await asset?.originFile;
      if (file == null) {
        setState(() {
          _loading = false;
          _error = 'Could not open this image';
        });
        return;
      }
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _image = frame.image;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load image';
      });
    }
  }

  bool get _hasEdits =>
      _quarterTurns != 0 ||
      _flipH ||
      _flipV ||
      _brightness != 0 ||
      _contrast != 1 ||
      _saturation != 1 ||
      _warmth != 0 ||
      _crop != const Rect.fromLTRB(0, 0, 1, 1) ||
      _strokes.isNotEmpty ||
      _texts.isNotEmpty ||
      _retouches.isNotEmpty;

  void _reset() => setState(() {
    _quarterTurns = 0;
    _flipH = false;
    _flipV = false;
    _brightness = 0;
    _contrast = 1;
    _saturation = 1;
    _warmth = 0;
    _crop = const Rect.fromLTRB(0, 0, 1, 1);
    _strokes.clear();
    _texts.clear();
    _retouches.clear();
  });

  /// تراجع عن آخر إضافة حسب الأداة الحالية.
  void _undo() => setState(() {
    switch (_tool) {
      case _Tool.draw:
        if (_strokes.isNotEmpty) _strokes.removeLast();
        break;
      case _Tool.text:
        if (_texts.isNotEmpty) _texts.removeLast();
        break;
      case _Tool.retouch:
        if (_retouches.isNotEmpty) _retouches.removeLast();
        break;
      default:
        break;
    }
  });

  /// إعدادات المعاينة (فيها إطار التحديد)، والتصدير بيستخدم
  /// نسخة بدون تحديد حتى ما ينحفظ الإطار مع الصورة.
  _EditSettings get _settings => _settingsWith(_selectedText);
  _EditSettings get _exportSettings => _settingsWith(null);

  _EditSettings _settingsWith(int? selected) => _EditSettings(
    selectedText: selected,
    quarterTurns: _quarterTurns,
    flipH: _flipH,
    flipV: _flipV,
    brightness: _brightness,
    contrast: _contrast,
    saturation: _saturation,
    warmth: _warmth,
    crop: _crop,
    strokes: [..._strokes, if (_activeStroke != null) _activeStroke!],
    texts: _texts,
    retouches: _retouches,
  );

  // ── الحفظ: نرسم بنفس الإعدادات على canvas ونصدّر PNG ─────────
  Future<void> _save() async {
    final image = _image;
    if (image == null || _saving) return;
    setState(() => _saving = true);

    try {
      final s = _exportSettings;
      final srcRect = s.sourceRect(image);
      // أبعاد الخرج: تنقلب لو التدوير ربع أو ثلاثة أرباع
      final swap = s.quarterTurns.isOdd;
      final outW = (swap ? srcRect.height : srcRect.width).round();
      final outH = (swap ? srcRect.width : srcRect.height).round();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      s.paintImage(
        canvas: canvas,
        image: image,
        outputSize: Size(outW.toDouble(), outH.toDouble()),
      );
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(outW, outH);
      picture.dispose();

      final byteData = await rendered.toByteData(
        format: ui.ImageByteFormat.png,
      );
      rendered.dispose();
      if (byteData == null) throw Exception('encode failed');

      final saved = await PhotoManager.editor.saveImage(
        byteData.buffer.asUint8List(),
        filename: 'PixMind_${DateTime.now().millisecondsSinceEpoch}.png',
        title: 'PixMind edit',
      );

      if (!mounted) return;
      // المعرض صار فيه صورة جديدة — خلّي الرئيسية تعيد التحميل
      ref.read(galleryNeedsRefreshProvider.notifier).state = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved as ${saved.title ?? 'new photo'}')),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to save the edited photo'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_hasEdits) return true;
    final leave = await showDialog<bool>(
      context: context,
      // كونتكست الدايالوج — الخارجي كان بيسكّر شاشة المحرّر نفسها
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text(
              'Discard',
              style: TextStyle(color: AppColors.errorRed),
            ),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (leave && context.mounted) context.pop();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
        ),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(child: _buildCanvas()),
                if (_image != null) _buildToolPanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 390;
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () async {
                  final leave = await _confirmDiscard();
                  if (leave && mounted) context.pop();
                },
              ),
              const Text(
                'Edit',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (_hasEdits && !_saving)
                compact
                    ? IconButton(
                        tooltip: 'Reset edits',
                        onPressed: _reset,
                        icon: const Icon(
                          Icons.restart_alt_rounded,
                          color: Colors.white70,
                        ),
                      )
                    : TextButton(
                        onPressed: _reset,
                        child: const Text(
                          'Reset',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
              const SizedBox(width: 2),
              if (_saving)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.mintAccent,
                    ),
                  ),
                )
              else
                Tooltip(
                  message: 'Save a new edited copy',
                  child: ElevatedButton(
                    onPressed: _image == null ? null : _save,
                    style: ElevatedButton.styleFrom(
                      minimumSize: Size(compact ? 44 : 94, 40),
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 10 : 14,
                      ),
                      backgroundColor: AppColors.mintAccent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child: compact
                        ? const Icon(Icons.save_alt_rounded, size: 21)
                        : const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.save_alt_rounded, size: 18),
                              SizedBox(width: 6),
                              Text(
                                'Save',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCanvas() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.mintAccent),
      );
    }
    if (_error != null || _image == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.broken_image_outlined,
              color: Colors.white38,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? 'Unavailable',
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: _tool == _Tool.crop
          ? _CropView(
              image: _image!,
              settings: _settings,
              crop: _crop,
              onCropChanged: (r) => setState(() => _crop = r),
            )
          : Center(
              child: _InteractivePreview(
                image: _image!,
                settings: _settings,
                // الرسم/التمويه/النص شغّالين بس بأدواتهم
                onPanStart: _tool == _Tool.draw
                    ? _startStroke
                    : _tool == _Tool.retouch
                    ? _addRetouch
                    : null,
                onPanUpdate: _tool == _Tool.draw
                    ? _extendStroke
                    : _tool == _Tool.retouch
                    ? _addRetouch
                    : null,
                onPanEnd: _tool == _Tool.draw ? _endStroke : null,
                // بوضع النص منستخدم إيماءة scale — بتغطّي التحريك
                // بإصبع والتكبير بإصبعين بنفس الوقت.
                onTapAt: _tool == _Tool.text
                    ? (p) => _onTextTap(p, _aspect)
                    : null,
                onScaleStartAt: _tool == _Tool.text
                    ? (p) => _onTextScaleStart(p, _aspect)
                    : null,
                onScaleUpdateAt: _tool == _Tool.text
                    ? _onTextScaleUpdate
                    : null,
              ),
            ),
    );
  }

  /// نسبة العرض للارتفاع لمساحة الخرج — لازمة لقياس حدود النص.
  double get _aspect {
    final img = _image;
    if (img == null) return 1;
    final out = _settings.outputSize(img);
    if (out.height <= 0) return 1;
    return out.width / out.height;
  }

  // ── الرسم ────────────────────────────────────────────────────
  void _startStroke(Offset p) => setState(() {
    _activeStroke = DrawStroke(
      points: [p],
      color: _brushColor,
      width: _brushWidth,
    );
  });

  void _extendStroke(Offset p) {
    if (_activeStroke == null) return;
    setState(() => _activeStroke!.points.add(p));
  }

  void _endStroke() => setState(() {
    if (_activeStroke != null) _strokes.add(_activeStroke!);
    _activeStroke = null;
  });

  // ── التمويه لإخفاء/إزالة شي ──────────────────────────────────
  void _addRetouch(Offset p) => setState(() {
    _retouches.add(RetouchBlob(center: p, radius: _retouchRadius));
  });

  // ── النصوص: تحديد / تحريك / تكبير ────────────────────────────

  /// حدود النص بإحداثيات نسبية — منقيسها بعرض وهمي وبنسبة الخرج.
  Rect _textBounds(TextItem t, double aspect) {
    const nominalW = 1000.0;
    final nominalH = nominalW / aspect;
    final painter = _EditSettings.buildTextPainter(t, nominalW);
    final w = painter.width / nominalW;
    final h = painter.height / nominalH;
    return Rect.fromCenter(center: t.position, width: w, height: h);
  }

  /// لمسة على النص: إذا صابت نص موجود منحدّده، وإلا منضيف نص جديد.
  Future<void> _onTextTap(Offset p, double aspect) async {
    for (var i = _texts.length - 1; i >= 0; i--) {
      // هامش بسيط حتى يسهل الإمساك بالنص
      if (_textBounds(_texts[i], aspect).inflate(0.02).contains(p)) {
        setState(() => _selectedText = i);
        return;
      }
    }
    if (_selectedText != null) {
      setState(() => _selectedText = null);
      return;
    }
    await _addTextAt(p);
  }

  void _onTextScaleStart(Offset focal, double aspect) {
    // لو بلشت السحبة فوق نص، منحدّده حتى يتحرّك مباشرة
    for (var i = _texts.length - 1; i >= 0; i--) {
      if (_textBounds(_texts[i], aspect).inflate(0.02).contains(focal)) {
        setState(() => _selectedText = i);
        break;
      }
    }
    final idx = _selectedText;
    if (idx != null && idx < _texts.length) {
      _textSizeAtScaleStart = _texts[idx].size;
    }
  }

  void _onTextScaleUpdate(Offset normDelta, double scale) {
    final idx = _selectedText;
    if (idx == null || idx >= _texts.length) return;
    setState(() {
      final t = _texts[idx];
      // إصبع وحدة = تحريك، إصبعين = تكبير/تصغير
      t.position = Offset(
        (t.position.dx + normDelta.dx).clamp(0.0, 1.0),
        (t.position.dy + normDelta.dy).clamp(0.0, 1.0),
      );
      if (scale != 1.0) {
        t.size = (_textSizeAtScaleStart * scale).clamp(0.02, 0.5);
      }
    });
  }

  void _editSelectedText() async {
    final idx = _selectedText;
    if (idx == null || idx >= _texts.length) return;
    final controller = TextEditingController(text: _texts[idx].text);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Edit text'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    setState(() {
      if (value.isEmpty) {
        _texts.removeAt(idx);
        _selectedText = null;
      } else {
        _texts[idx].text = value;
      }
    });
  }

  void _deleteSelectedText() {
    final idx = _selectedText;
    if (idx == null || idx >= _texts.length) return;
    setState(() {
      _texts.removeAt(idx);
      _selectedText = null;
    });
  }

  // ── إضافة نص بمكان اللمس ─────────────────────────────────────
  Future<void> _addTextAt(Offset p) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Your text'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty || !mounted) return;
    setState(() {
      _texts.add(
        TextItem(position: p, text: value, color: _brushColor, size: _textSize),
      );
      // نحدّده مباشرة حتى يقدر يحرّكه ويكبّره فوراً
      _selectedText = _texts.length - 1;
    });
  }

  Widget _buildToolPanel() {
    return Container(
      color: const Color(0xFF12181F),
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_tool == _Tool.adjust) _buildAdjustPanel(),
          if (_tool == _Tool.crop) _buildCropPanel(),
          if (_tool == _Tool.draw) _buildDrawPanel(),
          if (_tool == _Tool.text) _buildTextPanel(),
          if (_tool == _Tool.retouch) _buildRetouchPanel(),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _TabBtn(
                  icon: Icons.tune_rounded,
                  label: 'Adjust',
                  active: _tool == _Tool.adjust,
                  onTap: () => setState(() => _tool = _Tool.adjust),
                ),
                _TabBtn(
                  icon: Icons.crop_rounded,
                  label: 'Crop',
                  active: _tool == _Tool.crop,
                  onTap: () => setState(() => _tool = _Tool.crop),
                ),
                _TabBtn(
                  icon: Icons.brush_rounded,
                  label: 'Draw',
                  active: _tool == _Tool.draw,
                  onTap: () => setState(() => _tool = _Tool.draw),
                ),
                _TabBtn(
                  icon: Icons.title_rounded,
                  label: 'Text',
                  active: _tool == _Tool.text,
                  onTap: () => setState(() => _tool = _Tool.text),
                ),
                _TabBtn(
                  icon: Icons.auto_fix_high_rounded,
                  label: 'Remove',
                  active: _tool == _Tool.retouch,
                  onTap: () => setState(() => _tool = _Tool.retouch),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdjustPanel() {
    return Column(
      children: [
        _Slider(
          label: 'Brightness',
          value: _brightness,
          min: -1,
          max: 1,
          onChanged: (v) => setState(() => _brightness = v),
        ),
        _Slider(
          label: 'Contrast',
          value: _contrast,
          min: 0.2,
          max: 2,
          onChanged: (v) => setState(() => _contrast = v),
        ),
        _Slider(
          label: 'Saturation',
          value: _saturation,
          min: 0,
          max: 2,
          onChanged: (v) => setState(() => _saturation = v),
        ),
        _Slider(
          label: 'Warmth',
          value: _warmth,
          min: -1,
          max: 1,
          onChanged: (v) => setState(() => _warmth = v),
        ),
      ],
    );
  }

  // ── لوحات الأدوات الجديدة ────────────────────────────────────
  Widget _buildDrawPanel() => Column(
    children: [
      _hint('Drag on the photo to draw'),
      _colorRow(),
      _Slider(
        label: 'Brush',
        value: _brushWidth,
        min: 0.004,
        max: 0.06,
        onChanged: (v) => setState(() => _brushWidth = v),
      ),
      _undoRow(_strokes.isNotEmpty),
    ],
  );

  Widget _buildTextPanel() {
    final idx = _selectedText;
    final sel = (idx != null && idx < _texts.length) ? _texts[idx] : null;

    return Column(
      children: [
        _hint(
          sel == null
              ? 'Tap the photo to add text'
              : 'Drag to move · pinch to resize',
        ),
        // اللون يشتغل على النص المحدّد، وإذا ما في تحديد بيصير لون الجديد
        _colorRow(
          onPick: (c) {
            setState(() {
              _brushColor = c;
              if (sel != null) sel.color = c;
            });
          },
        ),
        _Slider(
          label: 'Size',
          value: sel?.size ?? _textSize,
          min: 0.02,
          max: 0.5,
          onChanged: (v) => setState(() {
            if (sel != null) {
              sel.size = v;
            } else {
              _textSize = v;
            }
          }),
        ),
        if (sel != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: _editSelectedText,
                icon: const Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: Colors.white70,
                ),
                label: const Text(
                  'Edit',
                  style: TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
              ),
              TextButton.icon(
                onPressed: _deleteSelectedText,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: AppColors.errorRed,
                ),
                label: const Text(
                  'Delete',
                  style: TextStyle(color: AppColors.errorRed, fontSize: 12.5),
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _selectedText = null),
                icon: const Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: AppColors.mintAccent,
                ),
                label: const Text(
                  'Done',
                  style: TextStyle(color: AppColors.mintAccent, fontSize: 12.5),
                ),
              ),
            ],
          )
        else
          _undoRow(_texts.isNotEmpty),
      ],
    );
  }

  Widget _buildRetouchPanel() => Column(
    children: [
      _hint('Drag over what you want to hide'),
      _Slider(
        label: 'Size',
        value: _retouchRadius,
        min: 0.02,
        max: 0.2,
        onChanged: (v) => setState(() => _retouchRadius = v),
      ),
      _undoRow(_retouches.isNotEmpty),
    ],
  );

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white38, fontSize: 11.5),
    ),
  );

  Widget _undoRow(bool enabled) => TextButton.icon(
    onPressed: enabled ? _undo : null,
    icon: Icon(
      Icons.undo_rounded,
      size: 18,
      color: enabled ? Colors.white70 : Colors.white24,
    ),
    label: Text(
      'Undo',
      style: TextStyle(
        color: enabled ? Colors.white70 : Colors.white24,
        fontSize: 12.5,
      ),
    ),
  );

  /// [onPick] بيسمح لأداة النص تغيّر لون النص المحدّد بدل لون الفرشاة.
  Widget _colorRow({ValueChanged<Color>? onPick}) => SizedBox(
    height: 34,
    child: ListView(
      scrollDirection: Axis.horizontal,
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      children: _palette.map((c) {
        final active = c == _brushColor;
        return GestureDetector(
          onTap: () =>
              onPick != null ? onPick(c) : setState(() => _brushColor = c),
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? AppColors.mintAccent : Colors.white24,
                width: active ? 3 : 1,
              ),
            ),
          ),
        );
      }).toList(),
    ),
  );

  Widget _buildCropPanel() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _IconAction(
              icon: Icons.rotate_90_degrees_ccw_rounded,
              label: 'Rotate',
              onTap: () =>
                  setState(() => _quarterTurns = (_quarterTurns + 1) % 4),
            ),
            _IconAction(
              icon: Icons.flip_rounded,
              label: 'Flip H',
              active: _flipH,
              onTap: () => setState(() => _flipH = !_flipH),
            ),
            _IconAction(
              icon: Icons.flip_rounded,
              label: 'Flip V',
              active: _flipV,
              rotateIcon: true,
              onTap: () => setState(() => _flipV = !_flipV),
            ),
            _IconAction(
              icon: Icons.crop_free_rounded,
              label: 'Full',
              onTap: () =>
                  setState(() => _crop = const Rect.fromLTRB(0, 0, 1, 1)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _RatioChip(label: '1:1', onTap: () => _applyRatio(1)),
              _RatioChip(label: '4:5', onTap: () => _applyRatio(4 / 5)),
              _RatioChip(label: '3:4', onTap: () => _applyRatio(3 / 4)),
              _RatioChip(label: '16:9', onTap: () => _applyRatio(16 / 9)),
              _RatioChip(label: '9:16', onTap: () => _applyRatio(9 / 16)),
            ],
          ),
        ),
      ],
    );
  }

  /// يضبط مستطيل القص على نسبة معيّنة، متمركز، وأكبر ما يمكن.
  void _applyRatio(double ratio) {
    final image = _image;
    if (image == null) return;
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();

    // النسبة بوحدات البكسل → نحولها لوحدات نسبية
    var w = 1.0;
    var h = (iw / ratio) / ih;
    if (h > 1) {
      h = 1.0;
      w = (ih * ratio) / iw;
    }
    setState(() {
      _crop = Rect.fromCenter(
        center: const Offset(0.5, 0.5),
        width: w,
        height: h,
      );
    });
  }
}

// ═══════════════════════════════════════════════════════════════
// الإعدادات + منطق الرسم المشترك (معاينة وحفظ)
// ═══════════════════════════════════════════════════════════════
class _EditSettings {
  final int quarterTurns;
  final bool flipH;
  final bool flipV;
  final double brightness;
  final double contrast;
  final double saturation;
  final double warmth;
  final Rect crop;
  final List<DrawStroke> strokes;
  final List<TextItem> texts;
  final List<RetouchBlob> retouches;

  /// فهرس النص المحدّد — للمعاينة فقط (ما بينحفظ بالصورة).
  final int? selectedText;

  const _EditSettings({
    this.selectedText,
    required this.quarterTurns,
    required this.flipH,
    required this.flipV,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.warmth,
    required this.crop,
    this.strokes = const [],
    this.texts = const [],
    this.retouches = const [],
  });

  Rect sourceRect(ui.Image image) {
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    return Rect.fromLTRB(
      (crop.left * iw).clamp(0, iw),
      (crop.top * ih).clamp(0, ih),
      (crop.right * iw).clamp(0, iw),
      (crop.bottom * ih).clamp(0, ih),
    );
  }

  /// حجم النتيجة بعد القص والتدوير (بالبكسل).
  Size outputSize(ui.Image image) {
    final src = sourceRect(image);
    return quarterTurns.isOdd
        ? Size(src.height, src.width)
        : Size(src.width, src.height);
  }

  ColorFilter get colorFilter => ColorFilter.matrix(_composedMatrix());

  List<double> _composedMatrix() {
    var m = _identity;
    if (contrast != 1) m = _mul(_contrastMatrix(contrast), m);
    if (brightness != 0) m = _mul(_brightnessMatrix(brightness), m);
    if (saturation != 1) m = _mul(_saturationMatrix(saturation), m);
    if (warmth != 0) m = _mul(_warmthMatrix(warmth), m);
    return m;
  }

  /// يرسم الصورة (مقصوصة + مدوّرة + مقلوبة + مفلترة) لتملأ [outputSize].
  void paintImage({
    required Canvas canvas,
    required ui.Image image,
    required Size outputSize,
  }) {
    final src = sourceRect(image);
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..colorFilter = colorFilter;

    // رسم الصورة نفسها (مقصوصة + مدوّرة + مقلوبة + مفلترة)
    void drawBase(Paint p) {
      canvas.save();
      // نشتغل من مركز مساحة الخرج
      canvas.translate(outputSize.width / 2, outputSize.height / 2);
      canvas.rotate(quarterTurns * math.pi / 2);
      canvas.scale(flipH ? -1.0 : 1.0, flipV ? -1.0 : 1.0);

      // بعد التدوير صار عرض الوجهة = عرض المصدر
      final dst = Rect.fromCenter(
        center: Offset.zero,
        width: src.width,
        height: src.height,
      );
      canvas.drawImageRect(image, src, dst, p);
      canvas.restore();
    }

    drawBase(paint);
    _paintAnnotations(canvas, outputSize, drawBase, paint);
  }

  /// التعليقات كلها بإحداثيات نسبية من مساحة الخرج، فمنضربها بالحجم.
  void _paintAnnotations(
    Canvas canvas,
    Size out,
    void Function(Paint) drawBase,
    Paint basePaint,
  ) {
    // 1) التمويه (إخفاء/إزالة أشياء) — منعيد رسم الصورة مموّهة
    //    داخل دائرة فقط، فتختفي التفاصيل بمكانها.
    for (final blob in retouches) {
      final c = Offset(blob.center.dx * out.width, blob.center.dy * out.height);
      final r = blob.radius * out.width;
      canvas.save();
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
      final blurred = Paint()
        ..filterQuality = FilterQuality.low
        ..colorFilter = basePaint.colorFilter
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: r * 0.55,
          sigmaY: r * 0.55,
          tileMode: TileMode.decal,
        );
      drawBase(blurred);
      canvas.restore();
    }

    // 2) خطوط الرسم
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width * out.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      final path = Path();
      final first = stroke.points.first;
      path.moveTo(first.dx * out.width, first.dy * out.height);
      for (final p in stroke.points.skip(1)) {
        path.lineTo(p.dx * out.width, p.dy * out.height);
      }
      // نقطة وحدة = دائرة صغيرة بدل خط ما بينرسم
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          Offset(first.dx * out.width, first.dy * out.height),
          stroke.width * out.width / 2,
          Paint()..color = stroke.color,
        );
      } else {
        canvas.drawPath(path, paint);
      }
    }

    // 3) النصوص
    for (var i = 0; i < texts.length; i++) {
      final t = texts[i];
      if (t.text.isEmpty) continue;
      final painter = buildTextPainter(t, out.width);

      final topLeft = Offset(
        t.position.dx * out.width - painter.width / 2,
        t.position.dy * out.height - painter.height / 2,
      );
      painter.paint(canvas, topLeft);

      // إطار التحديد — معاينة فقط
      if (selectedText == i) {
        final box = Rect.fromLTWH(
          topLeft.dx,
          topLeft.dy,
          painter.width,
          painter.height,
        ).inflate(out.width * 0.012);
        canvas.drawRRect(
          RRect.fromRectAndRadius(box, Radius.circular(out.width * 0.012)),
          Paint()
            ..color = AppColors.mintAccent
            ..style = PaintingStyle.stroke
            ..strokeWidth = out.width * 0.005,
        );
      }
    }
  }

  /// نفس الإعداد المستخدم بالرسم — مشترك حتى قياس الحدود يطابق العرض.
  static TextPainter buildTextPainter(TextItem t, double outWidth) =>
      TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            color: t.color,
            fontSize: t.size * outWidth,
            fontWeight: FontWeight.w700,
            shadows: const [
              Shadow(
                color: Colors.black54,
                blurRadius: 6,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: outWidth * 0.95);

  // ── مصفوفات الألوان (4×5) ──────────────────────────────────
  static const List<double> _identity = [
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  static List<double> _brightnessMatrix(double b) {
    final o = b * 255.0;
    return [
      1, 0, 0, 0, o, //
      0, 1, 0, 0, o, //
      0, 0, 1, 0, o, //
      0, 0, 0, 1, 0, //
    ];
  }

  static List<double> _contrastMatrix(double c) {
    final t = 127.5 * (1 - c);
    return [
      c, 0, 0, 0, t, //
      0, c, 0, 0, t, //
      0, 0, c, 0, t, //
      0, 0, 0, 1, 0, //
    ];
  }

  static List<double> _saturationMatrix(double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
    return [
      sr + s, sg, sb, 0, 0, //
      sr, sg + s, sb, 0, 0, //
      sr, sg, sb + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// دفء: يرفع الأحمر ويخفض الأزرق (والعكس للبرودة).
  static List<double> _warmthMatrix(double w) {
    final r = 1 + 0.18 * w;
    final b = 1 - 0.18 * w;
    return [
      r, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, //
      0, 0, b, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// ضرب مصفوفتَي ألوان 4×5 (نطبّق [a] أولاً بعدين [b]).
  static List<double> _mul(List<double> b, List<double> a) {
    final out = List<double>.filled(20, 0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 5; col++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += b[row * 5 + k] * a[k * 5 + col];
        }
        // العمود الأخير فيه الإزاحة الثابتة
        if (col == 4) sum += b[row * 5 + 4];
        out[row * 5 + col] = sum;
      }
    }
    return out;
  }
}

// ═══════════════════════════════════════════════════════════════
// معاينة الصورة بعد التعديل
// ═══════════════════════════════════════════════════════════════
/// معاينة + لمس: بتحوّل إحداثيات اللمس لإحداثيات نسبية (0..1)
/// من مساحة الخرج، حتى الرسم يطلع بنفس المكان وقت التصدير.
class _InteractivePreview extends StatelessWidget {
  final ui.Image image;
  final _EditSettings settings;
  final void Function(Offset)? onPanStart;
  final void Function(Offset)? onPanUpdate;
  final VoidCallback? onPanEnd;
  final void Function(Offset)? onTapAt;

  /// إيماءة scale — بتغطّي التحريك بإصبع والتكبير بإصبعين.
  /// لما تنمرّر، منستخدمها بدل onPan (ما بينفع الاثنين مع بعض).
  final void Function(Offset normFocal)? onScaleStartAt;
  final void Function(Offset normDelta, double scale)? onScaleUpdateAt;

  const _InteractivePreview({
    required this.image,
    required this.settings,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.onTapAt,
    this.onScaleStartAt,
    this.onScaleUpdateAt,
  });

  @override
  Widget build(BuildContext context) {
    final out = settings.outputSize(image);
    if (out.width <= 0 || out.height <= 0) return const SizedBox.shrink();

    return AspectRatio(
      aspectRatio: out.width / out.height,
      child: LayoutBuilder(
        builder: (context, c) {
          // الودجت نفسه بنسبة الخرج، فالتحويل مجرّد قسمة
          Offset toNorm(Offset local) => Offset(
            (local.dx / c.maxWidth).clamp(0.0, 1.0),
            (local.dy / c.maxHeight).clamp(0.0, 1.0),
          );

          final useScale = onScaleStartAt != null || onScaleUpdateAt != null;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: onTapAt == null
                ? null
                : (d) => onTapAt!(toNorm(d.localPosition)),
            // scale و pan ما بينفعوا مع بعض بنفس الـ GestureDetector
            onScaleStart: !useScale
                ? null
                : (d) => onScaleStartAt?.call(toNorm(d.localFocalPoint)),
            onScaleUpdate: !useScale
                ? null
                : (d) => onScaleUpdateAt?.call(
                    Offset(
                      d.focalPointDelta.dx / c.maxWidth,
                      d.focalPointDelta.dy / c.maxHeight,
                    ),
                    d.scale,
                  ),
            onPanStart: useScale || onPanStart == null
                ? null
                : (d) => onPanStart!(toNorm(d.localPosition)),
            onPanUpdate: useScale || onPanUpdate == null
                ? null
                : (d) => onPanUpdate!(toNorm(d.localPosition)),
            onPanEnd: useScale || onPanEnd == null ? null : (_) => onPanEnd!(),
            child: CustomPaint(
              painter: _EditPainter(image: image, settings: settings),
              size: Size.infinite,
            ),
          );
        },
      ),
    );
  }
}

class _EditPainter extends CustomPainter {
  final ui.Image image;
  final _EditSettings settings;
  _EditPainter({required this.image, required this.settings});

  @override
  void paint(Canvas canvas, Size size) {
    final out = settings.outputSize(image);
    if (out.width <= 0 || out.height <= 0) return;
    // نصغّر مساحة الخرج الحقيقية لتناسب حجم الودجت
    final scale = math.min(size.width / out.width, size.height / out.height);
    canvas.save();
    canvas.translate(
      (size.width - out.width * scale) / 2,
      (size.height - out.height * scale) / 2,
    );
    canvas.scale(scale);
    settings.paintImage(canvas: canvas, image: image, outputSize: out);
    canvas.restore();
  }

  // الإعدادات كائن جديد بكل build، فمنعيد الرسم دايماً —
  // الرسمة وحدة وبسيطة فما في داعي لمقارنة دقيقة.
  @override
  bool shouldRepaint(_EditPainter old) => true;
}

// ═══════════════════════════════════════════════════════════════
// واجهة القص — الصورة كاملة + مستطيل قابل للسحب
// ═══════════════════════════════════════════════════════════════
class _CropView extends StatelessWidget {
  final ui.Image image;
  final _EditSettings settings;
  final Rect crop;
  final ValueChanged<Rect> onCropChanged;

  const _CropView({
    required this.image,
    required this.settings,
    required this.crop,
    required this.onCropChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // نعرض الصورة الكاملة (بدون قص) عشان يشوف وين بده يقص
        final full = _EditSettings(
          quarterTurns: settings.quarterTurns,
          flipH: settings.flipH,
          flipV: settings.flipV,
          brightness: settings.brightness,
          contrast: settings.contrast,
          saturation: settings.saturation,
          warmth: settings.warmth,
          crop: const Rect.fromLTRB(0, 0, 1, 1),
        );
        final out = full.outputSize(image);
        final scale = math.min(
          constraints.maxWidth / out.width,
          constraints.maxHeight / out.height,
        );
        final dispW = out.width * scale;
        final dispH = out.height * scale;
        final dx = (constraints.maxWidth - dispW) / 2;
        final dy = (constraints.maxHeight - dispH) / 2;
        final imageRect = Rect.fromLTWH(dx, dy, dispW, dispH);

        return Stack(
          children: [
            Positioned.fromRect(
              rect: imageRect,
              child: CustomPaint(
                painter: _EditPainter(image: image, settings: full),
              ),
            ),
            Positioned.fill(
              child: _CropOverlay(
                imageRect: imageRect,
                crop: crop,
                onCropChanged: onCropChanged,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CropOverlay extends StatelessWidget {
  final Rect imageRect;
  final Rect crop;
  final ValueChanged<Rect> onCropChanged;

  const _CropOverlay({
    required this.imageRect,
    required this.crop,
    required this.onCropChanged,
  });

  Rect get _cropPx => Rect.fromLTRB(
    imageRect.left + crop.left * imageRect.width,
    imageRect.top + crop.top * imageRect.height,
    imageRect.left + crop.right * imageRect.width,
    imageRect.top + crop.bottom * imageRect.height,
  );

  void _emit(Rect px) {
    // أدنى مقاس للمستطيل حتى ما ينهار
    const minFrac = 0.08;
    var l = ((px.left - imageRect.left) / imageRect.width).clamp(0.0, 1.0);
    var t = ((px.top - imageRect.top) / imageRect.height).clamp(0.0, 1.0);
    var r = ((px.right - imageRect.left) / imageRect.width).clamp(0.0, 1.0);
    var b = ((px.bottom - imageRect.top) / imageRect.height).clamp(0.0, 1.0);
    if (r - l < minFrac) r = math.min(1.0, l + minFrac);
    if (b - t < minFrac) b = math.min(1.0, t + minFrac);
    onCropChanged(Rect.fromLTRB(l, t, r, b));
  }

  @override
  Widget build(BuildContext context) {
    final px = _cropPx;
    const handle = 28.0;

    Widget corner(Alignment align, void Function(Offset) onDrag) {
      return Positioned(
        left: align.x < 0 ? px.left - handle / 2 : px.right - handle / 2,
        top: align.y < 0 ? px.top - handle / 2 : px.bottom - handle / 2,
        width: handle,
        height: handle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => onDrag(d.delta),
          child: Center(
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: AppColors.mintAccent,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black26, width: 1),
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        // تعتيم خارج منطقة القص
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _CropDimPainter(cropPx: px)),
          ),
        ),
        // سحب المستطيل كامل
        Positioned.fromRect(
          rect: px,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) {
              var moved = px.shift(d.delta);
              // ما نخلي المستطيل يطلع برّا الصورة
              final dx = moved.left < imageRect.left
                  ? imageRect.left - moved.left
                  : moved.right > imageRect.right
                  ? imageRect.right - moved.right
                  : 0.0;
              final dy = moved.top < imageRect.top
                  ? imageRect.top - moved.top
                  : moved.bottom > imageRect.bottom
                  ? imageRect.bottom - moved.bottom
                  : 0.0;
              moved = moved.shift(Offset(dx, dy));
              _emit(moved);
            },
            child: const SizedBox.expand(),
          ),
        ),
        corner(
          Alignment.topLeft,
          (d) => _emit(
            Rect.fromLTRB(px.left + d.dx, px.top + d.dy, px.right, px.bottom),
          ),
        ),
        corner(
          Alignment.topRight,
          (d) => _emit(
            Rect.fromLTRB(px.left, px.top + d.dy, px.right + d.dx, px.bottom),
          ),
        ),
        corner(
          Alignment.bottomLeft,
          (d) => _emit(
            Rect.fromLTRB(px.left + d.dx, px.top, px.right, px.bottom + d.dy),
          ),
        ),
        corner(
          Alignment.bottomRight,
          (d) => _emit(
            Rect.fromLTRB(px.left, px.top, px.right + d.dx, px.bottom + d.dy),
          ),
        ),
      ],
    );
  }
}

class _CropDimPainter extends CustomPainter {
  final Rect cropPx;
  _CropDimPainter({required this.cropPx});

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, dim);
    canvas.drawRect(cropPx, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    // إطار + شبكة أثلاث
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(cropPx, border);

    final grid = Paint()
      ..color = Colors.white54
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = cropPx.left + cropPx.width * i / 3;
      final y = cropPx.top + cropPx.height * i / 3;
      canvas.drawLine(Offset(x, cropPx.top), Offset(x, cropPx.bottom), grid);
      canvas.drawLine(Offset(cropPx.left, y), Offset(cropPx.right, y), grid);
    }
  }

  @override
  bool shouldRepaint(_CropDimPainter old) => old.cropPx != cropPx;
}

// ═══════════════════════════════════════════════════════════════
// عناصر واجهة صغيرة
// ═══════════════════════════════════════════════════════════════
class _Slider extends StatelessWidget {
  final String label;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        SizedBox(
          width: 78,
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
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
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

class _TabBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabBtn({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.mintAccent : Colors.white60;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool rotateIcon;
  final VoidCallback onTap;
  const _IconAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.rotateIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.mintAccent : Colors.white70;
    final iconWidget = Icon(icon, color: color, size: 22);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            rotateIcon
                ? Transform.rotate(angle: math.pi / 2, child: iconWidget)
                : iconWidget,
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _RatioChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _RatioChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 12.5),
        ),
      ),
    ),
  );
}
