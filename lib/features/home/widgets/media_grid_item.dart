import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../../../core/constants/app_colors.dart';
import '../../../data/models/media_item.dart';

class MediaGridItem extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// وضع التحديد فعّال (يظهر دائرة الاختيار).
  final bool selectionMode;

  /// هل هذا العنصر محدّد حالياً؟
  final bool selected;

  const MediaGridItem({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(fit: StackFit.expand, children: [
        // الصورة — بدون أي wrappers بوضع التصفح العادي (أداء كامل).
        Image(
          image: AssetEntityImageProvider(
            item.asset,
            isOriginal: false,
            // 200 بدل 300 — أسرع بـ 50% في التحميل على الـ grid
            thumbnailSize: const ThumbnailSize.square(200),
          ),
          fit: BoxFit.cover,
          frameBuilder: (_, child, frame, sync) {
            if (sync) return child;
            return AnimatedOpacity(
              opacity: frame != null ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: frame != null
                  ? child
                  : Container(color: AppColors.textHint.withOpacity(0.12)),
            );
          },
          errorBuilder: (_, __, ___) => Container(
            color: AppColors.textHint.withOpacity(0.12),
            child: const Icon(Icons.broken_image_outlined,
                color: AppColors.textHint, size: 20),
          ),
        ),

        if (item.isVideo)
          Positioned(
            bottom: 5, right: 5,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4)),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 13),
            ),
          ),

        if (item.aiCaption != null && !selectionMode)
          Positioned(
            top: 4, left: 4,
            child: Container(
              width: 14, height: 14,
              decoration: const BoxDecoration(
                  color: AppColors.mintAccent, shape: BoxShape.circle),
              child: const Icon(Icons.auto_awesome,
                  color: Colors.white, size: 8),
            ),
          ),

        // ── طبقة التحديد: بترسم فقط بوضع التحديد (صفر حِمل بالتصفح العادي) ──
        if (selectionMode && selected)
          Container(color: AppColors.navyDeep.withOpacity(0.35)),

        if (selectionMode)
          Positioned(
            top: 4, right: 4,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.mintAccent : Colors.black26,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white, size: 14)
                  : null,
            ),
          ),
      ]),
    );
  }
}
