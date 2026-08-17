import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core/constants/app_colors.dart';

/// شاشة اختيار صور/فيديوهات من المعرض — بترجع اللي انختار بالـ pop.
/// مرتّبة من الأحدث للأقدم.
class AssetPickerScreen extends StatefulWidget {
  final String title;
  const AssetPickerScreen({super.key, required this.title});

  @override
  State<AssetPickerScreen> createState() => _AssetPickerScreenState();
}

class _AssetPickerScreenState extends State<AssetPickerScreen> {
  final List<AssetEntity> _assets = [];
  final Set<String> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (albums.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final items = await albums.first.getAssetListPaged(page: 0, size: 300);
    if (!mounted) return;
    setState(() {
      _assets
        ..clear()
        ..addAll(items);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBackground,
      appBar: AppBar(
        backgroundColor: AppColors.navyDeep,
        foregroundColor: Colors.white,
        title: Text(
          widget.title,
          style: const TextStyle(fontSize: 16, color: Colors.white),
        ),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                _assets.where((a) => _selected.contains(a.id)).toList(),
              ),
              child: Text(
                'Move ${_selected.length}',
                style: const TextStyle(
                  color: AppColors.mintAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.navyDeep),
            )
          : _assets.isEmpty
          ? const Center(
              child: Text(
                'No photos found',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                    sel ? _selected.remove(asset.id) : _selected.add(asset.id);
                  }),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
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
                          color: AppColors.navyDeep.withValues(alpha: 0.5),
                          child: const Center(
                            child: Icon(
                              Icons.check_circle_rounded,
                              color: AppColors.mintAccent,
                              size: 30,
                            ),
                          ),
                        ),
                      if (asset.type == AssetType.video)
                        const Positioned(
                          bottom: 4,
                          right: 4,
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
