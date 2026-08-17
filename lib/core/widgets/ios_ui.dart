import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

// ═══════════════════════════════════════════════════════════════
// عناصر واجهة بطابع iOS — بألوان مشروع PixMind.
// مشتركة بين شاشات البحث والألبومات الذكية والاقتراحات.
// ═══════════════════════════════════════════════════════════════

/// خلفية iOS المجمّعة (Grouped background).
const kIosGroupedBg = Color(0xFFF2F3F7);
const kIosSeparator = Color(0xFFE3E5EA);

/// عنوان صفحة كبير بطراز iOS (Large Title).
class IosLargeTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final VoidCallback? onBack;

  const IosLargeTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (onBack != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: onBack,
                child: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: AppColors.navyDeep,
                  size: 20,
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// بطاقة بيضاء بحواف دائرية — أساس تجميع iOS.
class IosCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  const IosCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  });

  @override
  Widget build(BuildContext context) => Container(
    margin: margin,
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: kIosSeparator),
    ),
    child: child,
  );
}

/// عنوان قسم صغير فوق البطاقات (زي iOS Settings).
class IosSectionHeader extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const IosSectionHeader(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 18, 20, 6),
    child: Row(
      children: [
        Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

/// صف داخل بطاقة — أيقونة ملوّنة + عنوان + وصف + سهم.
class IosRow extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  const IosRow({
    super.key,
    required this.icon,
    required this.iconBg,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(7.5),
                  ),
                  child: Icon(icon, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            subtitle!,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
                if (onTap != null)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 14,
                      color: AppColors.textHint,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (showDivider)
          const Padding(
            padding: EdgeInsets.only(left: 42),
            child: Divider(height: 1, thickness: 0.6, color: kIosSeparator),
          ),
      ],
    );
  }
}

/// مفتاح تبديل بطابع iOS.
class IosSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const IosSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Switch.adaptive(
    value: value,
    onChanged: onChanged,
    activeTrackColor: AppColors.mintAccent,
  );
}

/// شريط اختيار مقسّم (Segmented Control) بطابع iOS.
class IosSegmented<T> extends StatelessWidget {
  final Map<T, String> segments;
  final T value;
  final ValueChanged<T> onChanged;
  const IosSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: const Color(0xFFEBECF0),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: segments.entries.map((e) {
          final active = e.key == value;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(e.key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: active ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  e.value,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active
                        ? AppColors.navyDeep
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// حقل بحث بطابع iOS.
class IosSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final VoidCallback? onMic;
  final bool listening;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const IosSearchField({
    super.key,
    required this.controller,
    this.hint = 'Search',
    this.onMic,
    this.listening = false,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFEBECF0),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.search_rounded,
            color: AppColors.textSecondary,
            size: 19,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              style: const TextStyle(fontSize: 15.5),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(
                  color: AppColors.textHint,
                  fontSize: 15.5,
                ),
              ),
            ),
          ),
          if (onMic != null)
            GestureDetector(
              onTap: onMic,
              child: Icon(
                listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                color: listening ? AppColors.errorRed : AppColors.textSecondary,
                size: 20,
              ),
            ),
        ],
      ),
    );
  }
}

/// شارة صغيرة تقول إن الميزة واجهة فقط لسا.
class IosBadge extends StatelessWidget {
  final String text;
  final Color color;
  const IosBadge(this.text, {super.key, this.color = AppColors.skyBlue});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}
