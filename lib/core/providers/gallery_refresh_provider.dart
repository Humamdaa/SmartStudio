import 'package:flutter_riverpod/flutter_riverpod.dart';

/// يصير true لما يتغيّر شي بالمعرض من برّا الشاشة الرئيسية
/// (استعادة ملف من المجلد الآمن، حفظ صورة معدّلة...).
/// الشاشة الرئيسية بتقرأه لما ترجعلها وتعيد التحميل تلقائياً.
final galleryNeedsRefreshProvider = StateProvider<bool>((_) => false);
