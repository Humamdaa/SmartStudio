import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/router/app_router.dart';
import '../../data/prefs/app_prefs.dart';
import 'package:flutter_svg/flutter_svg.dart';


class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));

    _fade  = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _scale = Tween<double>(begin: 0.85, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));

    _ctrl.forward();
    _navigate();
  }

  Future<void> _navigate() async {
    await Future.delayed(const Duration(milliseconds: 3000));
    if (!mounted) return;

    final isFirst = await AppPrefs.instance.isFirstLaunch;

    if (isFirst) {
      // أول مرة → شاشة الصلاحيات
      if (mounted) context.go(AppRoutes.permissions);
      return;
    }

    final permission = await PhotoManager.requestPermissionExtend();

    if (!mounted) return;

    final granted = permission == PermissionState.authorized ||
        permission == PermissionState.limited;

    if (granted) {
      context.go(AppRoutes.home);
    } else {
      context.go(AppRoutes.permissions, extra: 'revoked');
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.navyDeep,
      body: FadeTransition(
        opacity: _fade,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: _scale,
                child: SvgPicture.asset(
                  'assets/images/logo_dark.svg',
                  width: 96,
                  height: 96,
                ),
              ),
              const SizedBox(height: 28),

              // ── App Name ────────────────────────────────
              const Text(
                AppStrings.appName,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                AppStrings.appTagline.toUpperCase(),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 3,
                ),
              ),

              const SizedBox(height: 72),

              // ── Loading dots ────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                    3, (i) => _PulseDot(delay: Duration(milliseconds: i * 180))),
              ),
              const SizedBox(height: 20),
              Text(
                AppStrings.version,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.25), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Duration delay;
  const _PulseDot({required this.delay});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _a;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 550));
    _a = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
    Future.delayed(widget.delay, () { if (mounted) _c.repeat(reverse: true); });
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: FadeTransition(
      opacity: _a,
      child: Container(
        width: 7, height: 7,
        decoration: const BoxDecoration(
            color: AppColors.mintAccent, shape: BoxShape.circle),
      ),
    ),
  );
}
