import 'package:flutter/material.dart';

enum SearchScope {
  general('عام', Icons.auto_awesome_rounded),
  people('أشخاص', Icons.face_retouching_natural),
  ocr('نص OCR', Icons.text_snippet_outlined),
  objects('عناصر', Icons.category_outlined),
  colors('ألوان', Icons.palette_outlined),
  scenes('مشاهد', Icons.landscape_outlined),
  date('تاريخ', Icons.calendar_month_outlined);

  final String label;
  final IconData icon;

  const SearchScope(this.label, this.icon);
}
