import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/providers/gallery_refresh_provider.dart';
import '../../data/database/objectbox/entities.dart';
import '../../data/database/objectbox/secure_repo.dart';
import '../../main.dart';
import '../../services/secure_storage_service.dart';

// ── Providers ─────────────────────────────────────────────────

final secureRepoProvider = Provider<SecureRepo>(
      (ref) => SecureRepo(ref.read(objectBoxProvider)),
);

// هل المجلد مفتوح؟
final _unlockedProvider = StateProvider<bool>((_) => false);

// قائمة الملفات المحمية
final _secureFilesProvider =
StateNotifierProvider<_SecureNotifier, AsyncValue<List<SecureFile>>>(
      (ref) => _SecureNotifier(ref.read(secureRepoProvider), ref),
);

class _SecureNotifier
    extends StateNotifier<AsyncValue<List<SecureFile>>> {
  final SecureRepo _repo;
  final Ref _ref;
  _SecureNotifier(this._repo, this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  void load() {
    try {
      final files = _repo.getAll();
      // رتّب: الأحدث أول
      files.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      state = AsyncValue.data(files);
    } catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
    }
  }

  // يرجع true فقط إذا انتقل الملف فعلاً — الواجهة تعتمد عليها
  // لعرض رسالة نجاح/فشل صحيحة بدل ما تفترض النجاح دايماً
  Future<bool> addAsset(AssetEntity asset) async {
    final added = await addAssets([asset]);
    return added > 0;
  }

  // إضافة دفعة كاملة بعملية حذف واحدة من المعرض (بدل واحدة لكل صورة)
  // يرجع عدد العناصر اللي انتقلت فعلاً
  Future<int> addAssets(List<AssetEntity> assets) async {
    final secureFiles = await SecureStorageService.instance.addAssets(assets);
    for (final f in secureFiles) {
      _repo.save(f);
    }
    load();
    return secureFiles.length;
  }

  // يرجع true إذا رجع الملف فعلاً للمعرض
  Future<bool> restoreFile(SecureFile file) async {
    // 1. نرجع الملف للمعرض العام
    final ok = await SecureStorageService.instance.restoreFile(file);
    if (!ok) return false;

    // 2. نحذف من ObjectBox
    _repo.remove(file.id);

    // 3. نعلّم إن المعرض صار قديم — الرئيسية بتعيد التحميل لما نرجعلها
    _ref.read(galleryNeedsRefreshProvider.notifier).state = true;

    load();
    return true;
  }

  Future<void> deleteFile(SecureFile file) async {
    // 1. حذف فيزيائي
    await SecureStorageService.instance.deleteFile(file);

    // 2. حذف من ObjectBox
    _repo.remove(file.id);

    load();
  }
}

// ═══════════════════════════════════════════════════════════════
// SecureScreen — entry point
// ═══════════════════════════════════════════════════════════════
class SecureScreen extends ConsumerStatefulWidget {
  const SecureScreen({super.key});

  @override
  ConsumerState<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends ConsumerState<SecureScreen>
    with WidgetsBindingObserver {
  // نخزن الـ notifier مباشرة بدل ما نستخدم ref بالـ dispose
  // لأن Riverpod يمنع استخدام ref بعد ما يبلش تفكيك الـ widget
  late final StateController<bool> _unlockedCtrl;

  @override
  void initState() {
    super.initState();
    _unlockedCtrl = ref.read(_unlockedProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // نقفل المجلد الآمن دايماً عند الخروج — لازم كلمة السر من جديد كل مرة.
    //
    // لازم نأجّل التعديل: Riverpod يمنع تعديل أي provider أثناء dispose
    // (وقت ما تكون شجرة الودجت عم تتفكك)، وكان يرمي استثناء غير معالج
    // كل مرة نطلع فيها من المجلد الآمن ويخرّب حالة التنقّل بعدها.
    final ctrl = _unlockedCtrl;
    Future(() => ctrl.state = false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // نقفل أيضاً لو التطبيق راح للخلفية (تبديل تطبيقات، قفل الشاشة...)
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _unlockedCtrl.state = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = ref.watch(_unlockedProvider);
    return unlocked ? const _VaultView() : const _AuthGate();
  }
}

// ═══════════════════════════════════════════════════════════════
// _AuthGate — المصادقة
// ═══════════════════════════════════════════════════════════════
class _AuthGate extends ConsumerStatefulWidget {
  const _AuthGate();
  @override
  ConsumerState<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<_AuthGate> {
  final _auth = LocalAuthentication();
  static const _storage = FlutterSecureStorage();
  static const _pinKey = 'pixmind_secure_pin';

  bool _showPin = false;
  String _entered = '';
  bool _loading = false;
  String? _error;

  /// First of the two entries while choosing a new PIN.
  String? _firstEntry;
  bool _pinExists = false;

  @override
  void initState() {
    super.initState();
    _loadPinState();
  }

  Future<void> _loadPinState() async {
    final stored = await _storage.read(key: _pinKey);
    if (!mounted) return;
    setState(() => _pinExists = stored != null);
  }

  // ── Biometric ────────────────────────────────────────────────
  Future<void> _biometric() async {
    setState(() { _loading = true; _error = null; });
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Open Secure Folder',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      if (ok) {
        ref.read(_unlockedProvider.notifier).state = true;
      } else {
        setState(() => _error = 'Authentication failed');
      }
    } on PlatformException catch (e) {
      setState(() => _error = e.message ?? 'Error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── PIN ───────────────────────────────────────────────────────
  Future<void> _onDigit(String d) async {
    if (_entered.length >= 6) return;
    final pin = _entered + d;
    setState(() { _entered = pin; _error = null; });
    if (pin.length < 6) return;

    setState(() => _loading = true);
    final stored = await _storage.read(key: _pinKey);

    if (stored == null) {
      // إنشاء رقم جديد — منطلبه مرتين قبل ما نحفظ أي شي. النسخة القديمة كانت
      // تحفظ أول ستة أرقام تُكتب بصمت، فرقم مكتوب بحكم العادة أو بالخطأ يصير
      // الرقم الدائم بلا أي طريقة لتغييره.
      final first = _firstEntry;
      if (first == null) {
        setState(() {
          _firstEntry = pin;
          _entered = '';
          _loading = false;
        });
        return;
      }
      if (first != pin) {
        setState(() {
          _error = 'الرقمان غير متطابقين — ابدأ من جديد';
          _firstEntry = null;
          _entered = '';
          _loading = false;
        });
        return;
      }
      await _storage.write(key: _pinKey, value: pin);
      if (!mounted) return;
      _pinExists = true;
      ref.read(_unlockedProvider.notifier).state = true;
    } else if (stored == pin) {
      ref.read(_unlockedProvider.notifier).state = true;
    } else {
      setState(() {
        _error = 'Wrong PIN';
        _entered = '';
        _loading = false;
      });
    }
  }

  /// يمسح رقمًا منسيًّا بعد إثبات الهوية بقفل الجهاز نفسه (بصمة أو رقم الجهاز)،
  /// فيصير بالإمكان تعيين رقم جديد. قبل هذا ما كان في أي طريق لتغيير الرقم
  /// بعد حفظه أول مرة.
  Future<void> _resetPin() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Confirm your identity to reset the Secure Folder PIN',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      if (!ok) {
        setState(() => _error = 'Authentication failed');
        return;
      }
      await _storage.delete(key: _pinKey);
      if (!mounted) return;
      setState(() {
        _pinExists = false;
        _firstEntry = null;
        _entered = '';
        _error = 'تم مسح الرقم — اكتب رقمًا جديدًا مرتين';
      });
    } on PlatformException catch (e) {
      setState(() => _error = e.message ?? 'Error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.navyDeep,
      body: SafeArea(
        child: _showPin ? _buildPin() : _buildChoose(),
      ),
    );
  }

  Widget _buildChoose() => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSizes.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88, height: 88,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock_outline_rounded,
                color: Colors.white, size: 44),
          ),
          const SizedBox(height: 24),
          const Text('Secure Folder',
              style: TextStyle(color: Colors.white, fontSize: 26,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Your hidden private files',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.5), fontSize: 14)),
          const SizedBox(height: 56),
          _AuthBtn(
            icon: Icons.fingerprint_rounded,
            label: 'Fingerprint / Face ID',
            bg: AppColors.mintAccent,
            fg: Colors.black,
            loading: _loading,
            onTap: _biometric,
          ),
          const SizedBox(height: 14),
          _AuthBtn(
            icon: Icons.dialpad_rounded,
            label: 'Enter PIN',
            bg: Colors.white.withOpacity(0.12),
            fg: Colors.white,
            onTap: () => setState(() => _showPin = true),
          ),
          if (_error != null) ...[
            const SizedBox(height: 20),
            Text(_error!,
                style: const TextStyle(
                    color: AppColors.errorRed, fontSize: 13)),
          ],
        ],
      ),
    ),
  );

  Widget _buildPin() {
    return Column(
      children: [
        // back
        Align(
          alignment: Alignment.topLeft,
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => setState(() {
              _showPin = false;
              _entered = '';
              _error = null;
            }),
          ),
        ),
        const SizedBox(height: 24),
        // كان هذا FutureBuilder يقرأ التخزين الآمن مع كل رقم يُضغط.
        Text(
          _pinExists
              ? 'Enter PIN'
              : _firstEntry == null
                  ? 'Create a 6-digit PIN'
                  : 'Confirm your PIN',
          style: const TextStyle(color: Colors.white, fontSize: 20,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 32),
        // نقاط
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(6, (i) {
            final filled = i < _entered.length;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 10),
              width: 16, height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled
                    ? AppColors.mintAccent
                    : Colors.white.withOpacity(0.2),
                border: Border.all(
                  color: filled
                      ? AppColors.mintAccent
                      : Colors.white.withOpacity(0.4),
                ),
              ),
            );
          }),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!,
              style: const TextStyle(
                  color: AppColors.errorRed, fontSize: 13)),
        ],
        const SizedBox(height: 40),
        if (_loading)
          const CircularProgressIndicator(color: AppColors.mintAccent)
        else
          _PinPad(
            onDigit: _onDigit,
            onDelete: () => setState(() {
              if (_entered.isNotEmpty)
                _entered = _entered.substring(0, _entered.length - 1);
            }),
          ),
        if (_pinExists && !_loading)
          TextButton(
            onPressed: _resetPin,
            child: const Text('نسيت الرقم؟',
                style: TextStyle(color: AppColors.mintAccent)),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// _VaultView — عرض الملفات المحمية
// ═══════════════════════════════════════════════════════════════
class _VaultView extends ConsumerStatefulWidget {
  const _VaultView();

  @override
  ConsumerState<_VaultView> createState() => _VaultViewState();
}

class _VaultViewState extends ConsumerState<_VaultView> {
  @override
  void initState() {
    super.initState();
    // نضمن قائمة محدّثة من القرص كل مرة يفتح فيها المجلد الآمن
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(_secureFilesProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final asyncFiles = ref.watch(_secureFilesProvider);
    final notifier = ref.read(_secureFilesProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.navyDeep,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: asyncFiles.when(
          data: (files) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Secure Folder',
                  style: TextStyle(color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w700)),
              Text('${files.length} hidden files',
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 11)),
            ],
          ),
          loading: () => const Text('Secure Folder',
              style: TextStyle(color: Colors.white)),
          error: (_, __) => const Text('Secure Folder',
              style: TextStyle(color: Colors.white)),
        ),
        actions: [
          // زر قفل
          IconButton(
            icon: const Icon(Icons.lock_rounded,
                color: AppColors.mintAccent),
            tooltip: 'Lock folder',
            onPressed: () =>
            ref.read(_unlockedProvider.notifier).state = false,
          ),
          // زر إضافة
          IconButton(
            icon: const Icon(Icons.add_photo_alternate_outlined,
                color: Colors.white),
            tooltip: 'Add from gallery',
            onPressed: () => _showPicker(context, notifier),
          ),
        ],
      ),
      body: asyncFiles.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.mintAccent)),
        error: (e, _) => Center(
            child: Text('$e', style: const TextStyle(color: Colors.white70))),
        data: (files) => files.isEmpty
            ? _buildEmpty(context, notifier)
            : _buildGrid(context, ref, files, notifier),
      ),
    );
  }

  Widget _buildEmpty(
      BuildContext context, _SecureNotifier notifier) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.lock_open_outlined,
            size: 72, color: Colors.white.withOpacity(0.22)),
        const SizedBox(height: 20),
        const Text('No hidden files',
            style: TextStyle(fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white)),
        const SizedBox(height: 8),
        Text(
          'Files you add here will be removed\nfrom your gallery permanently.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13,
              color: Colors.white.withOpacity(0.55), height: 1.5),
        ),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          onPressed: () => _showPicker(context, notifier),
          icon: const Icon(Icons.add, color: AppColors.navyDeep),
          label: const Text('Add Files',
              style: TextStyle(
                  color: AppColors.navyDeep, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.mintAccent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14))),
        ),
      ],
    ),
  );

  Widget _buildGrid(
      BuildContext context,
      WidgetRef ref,
      List<SecureFile> files,
      _SecureNotifier notifier,
      ) {
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: files.length,
      itemBuilder: (context, i) {
        final file = files[i];
        return GestureDetector(
          onTap: () => _openFile(context, file, files),
          onLongPress: () => _showOptions(context, file, notifier),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(fit: StackFit.expand, children: [
              // الـ thumbnail الفيزيائي (الصورة اتحذفت من photo_manager)
              file.thumbnailPath != null
                  ? Image.file(
                      File(file.thumbnailPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _filePlaceholder(file),
                    )
                  : _filePlaceholder(file),
              Positioned(
                top: 5,
                left: 5,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: AppColors.navyDeep.withOpacity(0.85),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_rounded,
                      color: AppColors.mintAccent, size: 11),
                ),
              ),
              if (file.isVideo)
                Positioned(
                  bottom: 5,
                  right: 5,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4)),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.white, size: 13),
                  ),
                ),
            ]),
          ),
        );
      },
    );
  }

  Widget _filePlaceholder(SecureFile file) => Container(
    color: AppColors.navyDeep.withOpacity(0.15),
    child: Center(
      child: Icon(
        file.isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        color: AppColors.textHint,
        size: 32,
      ),
    ),
  );

  // ── فتح ملف في detail screen ─────────────────────────────────
  void _openFile(
      BuildContext context, SecureFile file, List<SecureFile> all) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SecureDetailScreen(file: file, allFiles: all),
      ),
    );
  }

  // ── خيارات long press ─────────────────────────────────────────
  void _showOptions(
      BuildContext context, SecureFile file, _SecureNotifier notifier) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2B3A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: const Icon(Icons.lock_open_outlined,
                  color: Colors.white70),
              title: const Text('Restore to Gallery',
                  style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                  'File will reappear in your gallery',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              onTap: () async {
                Navigator.pop(context);
                // restoreFile يرجّع النتيجة الحقيقية — قبل كان الكود
                // يعتبر أي انتهاء نجاح حتى لو فشلت الاستعادة فعلياً
                var ok = false;
                try {
                  ok = await notifier.restoreFile(file);
                } catch (_) {
                  ok = false;
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(ok
                        ? 'Restored to gallery'
                        : 'Failed to restore'),
                    backgroundColor: ok ? null : AppColors.errorRed,
                  ));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined,
                  color: AppColors.errorRed),
              title: const Text('Delete permanently',
                  style: TextStyle(color: AppColors.errorRed)),
              subtitle: const Text('Cannot be recovered',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(context, file, notifier);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, SecureFile file,
      _SecureNotifier notifier) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: const Text(
            'This file will be deleted forever and cannot be recovered.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              notifier.deleteFile(file);
            },
            child: const Text('Delete',
                style: TextStyle(color: AppColors.errorRed)),
          ),
        ],
      ),
    );
  }

  // ── Picker: اختيار صور من المعرض ─────────────────────────────
  void _showPicker(BuildContext context, _SecureNotifier notifier) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.lightBackground,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _GalleryPicker(
        onConfirm: (assets) async {
          // دفعة وحدة: نسخ الكل ثم حذف الكل من المعرض بطلب واحد
          // (بدل ديالوج تأكيد حذف منفصل لكل صورة كان يوقف/يتجاهل الباقي)
          final succeeded = await notifier.addAssets(assets);
          if (!context.mounted) return;
          final failed = assets.length - succeeded;
          final message = failed == 0
              ? '$succeeded file(s) moved to Secure Folder'
              : '$succeeded moved, $failed failed';
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(message),
            backgroundColor: failed == 0 ? null : AppColors.errorRed,
          ));
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// _SecureDetailScreen — عرض ملف محمي بالحجم الكامل
//
// يستخدم Image.file مش AssetEntityImageProvider
// لأن الصورة في مجلد السيكيور مش في photo_manager
// ═══════════════════════════════════════════════════════════════
class _SecureDetailScreen extends StatefulWidget {
  final SecureFile file;
  final List<SecureFile> allFiles;

  const _SecureDetailScreen(
      {required this.file, required this.allFiles});

  @override
  State<_SecureDetailScreen> createState() => _SecureDetailScreenState();
}

class _SecureDetailScreenState extends State<_SecureDetailScreen> {
  late PageController _pageCtrl;
  late int _idx;
  bool _uiVisible = true;

  @override
  void initState() {
    super.initState();
    _idx = widget.allFiles.indexOf(widget.file);
    if (_idx < 0) _idx = 0;
    _pageCtrl = PageController(initialPage: _idx);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _toggleUI() {
    setState(() => _uiVisible = !_uiVisible);
    if (_uiVisible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.allFiles[_idx];
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _uiVisible
          ? AppBar(
        backgroundColor: Colors.black.withOpacity(0.55),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(current.originalName,
                style: const TextStyle(
                    fontSize: 14, color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Text('${_idx + 1} / ${widget.allFiles.length}',
                style: const TextStyle(
                    fontSize: 11, color: Colors.white54)),
          ],
        ),
      )
          : null,
      body: PageView.builder(
        controller: _pageCtrl,
        onPageChanged: (i) => setState(() => _idx = i),
        itemCount: widget.allFiles.length,
        itemBuilder: (_, i) {
          final f = widget.allFiles[i];
          return GestureDetector(
            onTap: _toggleUI,
            child: Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5.0,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                child: Image.file(
                  File(f.securePath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white38, size: 48),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// _GalleryPicker — يختار صور من المعرض لنقلها للسيكيور
// ═══════════════════════════════════════════════════════════════
class _GalleryPicker extends StatefulWidget {
  final ValueChanged<List<AssetEntity>> onConfirm;
  const _GalleryPicker({required this.onConfirm});

  @override
  State<_GalleryPicker> createState() => _GalleryPickerState();
}

class _GalleryPickerState extends State<_GalleryPicker> {
  static const _pageSize = 120;

  final List<AssetEntity> _assets = [];
  final Set<String> _selected = {};
  final _scrollCtrl = ScrollController();
  AssetPathEntity? _album;
  int _page = 0;
  bool _hasMore = true;
  bool _loadingMore = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.extentAfter < 600) _loadPage();
  }

  Future<void> _load() async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      // الأحدث أول
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    if (albums.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _album = albums.first;
    await _loadPage();
    if (mounted) setState(() => _loading = false);
  }

  /// Loads one page and keeps the rest reachable by scrolling. The picker used
  /// to fetch a single 200-item page, so older photos could not be hidden at
  /// all on a large library.
  Future<void> _loadPage() async {
    final album = _album;
    if (album == null || _loadingMore || !_hasMore) return;
    _loadingMore = true;

    final batch = await album.getAssetListPaged(page: _page, size: _pageSize);
    if (!mounted) return;
    setState(() {
      _assets.addAll(batch);
      _page++;
      _hasMore = batch.length >= _pageSize;
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Select files to hide',
                        style: TextStyle(fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    Text(
                      _selected.isEmpty
                          ? 'Tap photos to select'
                          : '${_selected.length} selected',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Stays on screen while nothing is selected: hiding it made the
              // sheet look like it had no way to confirm at all.
              ElevatedButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () {
                        final selected = _assets
                            .where((a) => _selected.contains(a.id))
                            .toList();
                        Navigator.pop(context);
                        widget.onConfirm(selected);
                      },
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.navyDeep,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 18)),
                child: Text(
                    _selected.isEmpty ? 'Add' : 'Add ${_selected.length}',
                    style: const TextStyle(color: Colors.white)),
              ),
            ]),
          ),
          // تحذير
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.errorRed.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.errorRed.withOpacity(0.2)),
            ),
            child: const Row(children: [
              Icon(Icons.warning_amber_rounded,
                  color: AppColors.errorRed, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Selected files will be removed from your gallery and hidden.',
                  style: TextStyle(
                      color: AppColors.errorRed, fontSize: 12),
                ),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(
                color: AppColors.navyDeep))
                : GridView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(2),
              gridDelegate:
              const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: _assets.length,
              itemBuilder: (_, i) {
                final asset = _assets[i];
                final sel = _selected.contains(asset.id);
                return GestureDetector(
                  onTap: () => setState(() {
                    sel
                        ? _selected.remove(asset.id)
                        : _selected.add(asset.id);
                  }),
                  child: Stack(fit: StackFit.expand, children: [
                    // A cached provider rather than a per-build thumbnail
                    // future: every selection tap rebuilds the grid, and the
                    // old FutureBuilder refetched each visible thumbnail on
                    // each rebuild, so tapping looked like it did nothing.
                    Image(
                      image: AssetEntityImageProvider(
                        asset,
                        isOriginal: false,
                        thumbnailSize: const ThumbnailSize.square(200),
                      ),
                      fit: BoxFit.cover,
                    ),
                    if (sel)
                      Container(
                        color: AppColors.navyDeep.withOpacity(0.5),
                        child: const Center(
                          child: Icon(Icons.check_circle_rounded,
                              color: AppColors.mintAccent,
                              size: 32),
                        ),
                      ),
                    if (asset.type == AssetType.video)
                      Positioned(
                        bottom: 4, right: 4,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius:
                              BorderRadius.circular(3)),
                          child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white, size: 12),
                        ),
                      ),
                  ]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helper Widgets ─────────────────────────────────────────────

class _AuthBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bg, fg;
  final VoidCallback onTap;
  final bool loading;

  const _AuthBtn({
    required this.icon, required this.label,
    required this.bg, required this.fg,
    required this.onTap, this.loading = false,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity, height: 52,
    child: ElevatedButton.icon(
      onPressed: loading ? null : onTap,
      icon: loading
          ? const SizedBox(width: 20, height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Colors.black45))
          : Icon(icon, color: fg),
      label: Text(label,
          style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
      style: ElevatedButton.styleFrom(
        backgroundColor: bg,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSizes.radiusMd)),
      ),
    ),
  );
}

class _PinPad extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;
  const _PinPad({required this.onDigit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1','2','3'],
      ['4','5','6'],
      ['7','8','9'],
      ['','0','⌫'],
    ];
    return Column(
      children: rows.map((row) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: row.map((d) {
            if (d.isEmpty) return const SizedBox(width: 72, height: 72);
            return GestureDetector(
              onTap: () => d == '⌫' ? onDelete() : onDigit(d),
              child: Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.1),
                ),
                child: Center(
                  child: d == '⌫'
                      ? const Icon(Icons.backspace_outlined,
                      color: Colors.white, size: 22)
                      : Text(d,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 24, fontWeight: FontWeight.w400)),
                ),
              ),
            );
          }).toList(),
        ),
      )).toList(),
    );
  }
}