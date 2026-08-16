import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core/constants/app_colors.dart';
import '../../data/database/db_helper.dart';
import '../search/search_vocabulary.dart';
import '../../services/ai/ocr_service.dart';

class OcrScreen extends StatefulWidget {
  final String assetId;

  const OcrScreen({super.key, required this.assetId});

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen> {
  AssetEntity? _asset;
  String _text = '';
  String _status = 'يقرأ العربية والإنجليزية داخل الصورة…';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _extract();
  }

  Future<void> _extract() async {
    setState(() => _loading = true);
    try {
      final asset = await AssetEntity.fromId(widget.assetId);
      final file = await asset?.file;
      if (asset == null || file == null) throw StateError('الصورة غير متاحة');
      final result = await OcrService.instance.extractCombinedText(
        file.path,
        runArabic: true,
        thoroughArabic: true,
      );

      if (result.text.trim().isNotEmpty) {
        // Keep manual OCR and gallery search consistent: once the user can see
        // extracted text here, the same text becomes searchable immediately.
        await DatabaseHelper.instance.upsertManualOcr(
          assetId: asset.id,
          title: asset.title ?? '',
          takenAt: asset.createDateTime.millisecondsSinceEpoch,
          width: asset.width,
          height: asset.height,
          ocrText: result.text,
          ocrSearchText: SearchVocabulary.normalize(result.text),
          ocrScriptsJson: jsonEncode(result.scripts),
        );
      }

      if (!mounted) return;
      setState(() {
        _asset = asset;
        _text = result.text;
        _status = result.text.isEmpty
            ? 'لم نجد نصًا واضحًا. جرّب صورة أقرب أو أوضح.'
            : 'اكتمل OCR المحلي وتم تحديث البحث: ${result.scripts.join(' + ')}';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'تعذر OCR: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم نسخ النص')),
      );
    }
  }

  Future<void> _showSelectableText() async {
    if (_text.trim().isEmpty || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'النص داخل الصورة',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'اضغط مطولًا على أي كلمة أو سطر لتحديد الجزء الذي تريد نسخه.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.55,
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _text,
                      style: const TextStyle(fontSize: 18, height: 1.8),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _text));
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  icon: const Icon(Icons.copy_all_rounded),
                  label: const Text('نسخ كل النص'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xfff4f6fb),
        appBar: AppBar(
          backgroundColor: AppColors.navyDeep,
          foregroundColor: Colors.white,
          title: const Text('Live Text / OCR'),
          actions: [
            if (_text.isNotEmpty)
              IconButton(onPressed: _copy, tooltip: 'نسخ', icon: const Icon(Icons.copy)),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_asset != null) ...[
              GestureDetector(
                onLongPress: _text.isEmpty ? null : _showSelectableText,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: 210,
                    child: AssetEntityImage(
                      _asset!,
                      isOriginal: false,
                      thumbnailSize: const ThumbnailSize(800, 600),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                _text.isEmpty
                    ? 'بعد استخراج النص سيصبح قابلًا للتحديد والنسخ.'
                    : 'اضغط مطولًا على الصورة لفتح النص القابل للتحديد والنسخ.',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (_loading) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(_status),
            const SizedBox(height: 14),
            if (_text.isNotEmpty) ...[
              OutlinedButton.icon(
                onPressed: _showSelectableText,
                icon: const Icon(Icons.select_all_rounded),
                label: const Text('تحديد ونسخ جزء من النص'),
              ),
              const SizedBox(height: 10),
              SelectableText(
                _text,
                style: const TextStyle(fontSize: 17, height: 1.8),
              ),
            ],
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _loading ? null : _extract,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة القراءة'),
            ),
          ],
        ),
      ),
    );
  }
}
