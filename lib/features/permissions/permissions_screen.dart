import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/constants/app_strings.dart';
import '../../core/router/app_router.dart';
import '../../data/prefs/app_prefs.dart';

class PermissionsScreen extends StatefulWidget {
  final String? reason;
  const PermissionsScreen({super.key, this.reason});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  bool _loading = false;

  bool get _wasRevoked => widget.reason == 'revoked';

  Future<void> _requestPermissions() async {
    setState(() => _loading = true);

    // Photo access is the only permission required to use the gallery/search.
    // Microphone stays optional for the teammate voice-search UI.
    final pm = await PhotoManager.requestPermissionExtend();
    final granted = pm.hasAccess;
    if (granted && !_wasRevoked) {
      await Permission.microphone.request();
    }

    await AppPrefs.instance.markLaunched();

    if (!mounted) return;
    setState(() => _loading = false);

    if (granted) {
      context.go(AppRoutes.home);
    } else {
      await PhotoManager.openSetting();
    }
  }

  Future<void> _skip() async {
    await AppPrefs.instance.markLaunched();
    if (mounted) context.go(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSizes.lg, vertical: AppSizes.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: _wasRevoked
                      ? AppColors.errorRed.withOpacity(0.1)
                      : AppColors.navyDeep.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _wasRevoked ? Icons.no_photography_outlined : Icons.security_outlined,
                  color: _wasRevoked ? AppColors.errorRed : AppColors.navyDeep,
                  size: 30,
                ),
              ),
              const SizedBox(height: AppSizes.lg),

              Text(
                _wasRevoked ? 'Photo access revoked' : AppStrings.permissionsTitle,
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary, height: 1.2),
              ),
              const SizedBox(height: AppSizes.sm),
              Text(
                _wasRevoked
                    ? 'PixMind needs access to show your gallery.\nPlease enable it in settings.'
                    : AppStrings.permissionsSubtitle,
                style: const TextStyle(
                    fontSize: 14, color: AppColors.textSecondary, height: 1.6),
              ),
              const SizedBox(height: AppSizes.xl),

              _PermTile(
                icon: Icons.photo_library_outlined,
                title: AppStrings.permPhotos,
                subtitle: AppStrings.permPhotosSub,
                color: AppColors.skyBlue,
                required: true,
              ),
              _PermTile(
                icon: Icons.mic_outlined,
                title: AppStrings.permMic,
                subtitle: AppStrings.permMicSub,
                color: AppColors.mintAccent,
              ),
              _PermTile(
                icon: Icons.fingerprint_outlined,
                title: AppStrings.permBio,
                subtitle: AppStrings.permBioSub,
                color: AppColors.navyDeep,
              ),

              const Spacer(),

              SizedBox(
                width: double.infinity, height: 52,
                child: ElevatedButton(
                  onPressed: _loading ? null : _requestPermissions,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.navyDeep,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppSizes.radiusMd)),
                  ),
                  child: _loading
                      ? const SizedBox(width: 22, height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                      : Text(
                      _wasRevoked ? AppStrings.openSettings : AppStrings.allowBtn,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 12),

              if (!_wasRevoked)
                Center(
                  child: TextButton(
                    onPressed: _skip,
                    child: const Text(AppStrings.skipBtn,
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 14)),
                  ),
                ),
              const SizedBox(height: AppSizes.md),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermTile extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final Color color;
  final bool required;

  const _PermTile({
    required this.icon, required this.title,
    required this.subtitle, required this.color,
    this.required = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: AppSizes.md),
    padding: const EdgeInsets.all(AppSizes.md),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
            color: AppColors.navyDeep.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 4)),
      ],
    ),
    child: Row(children: [
      Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(AppSizes.radiusSm)),
        child: Icon(icon, color: color, size: 22),
      ),
      const SizedBox(width: AppSizes.md),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(title, style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 14)),
            if (required) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                    color: AppColors.errorRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4)),
                child: const Text('Required',
                    style: TextStyle(
                        color: AppColors.errorRed, fontSize: 10,
                        fontWeight: FontWeight.w600)),
              ),
            ]
          ]),
          Text(subtitle, style: const TextStyle(
              color: AppColors.textSecondary, fontSize: 12)),
        ],
      )),
    ]),
  );
}
