import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../data/repositories/media_repository.dart';
import 'visual_embedding_service.dart';
import 'visual_search_indexer.dart';
import 'visual_search_repository.dart';

class SimilarImagesScreen extends StatefulWidget {
  const SimilarImagesScreen({super.key, required this.queryAssetId});

  final String queryAssetId;

  @override
  State<SimilarImagesScreen> createState() => _SimilarImagesScreenState();
}

class _SimilarImagesScreenState extends State<SimilarImagesScreen> {
  final VisualEmbeddingService _embeddingService = VisualEmbeddingService();
  final VisualSearchRepository _repository = VisualSearchRepository();
  final MediaRepository _mediaRepository = MediaRepository();

  late final VisualSearchIndexer _indexer;

  final Map<String, Future<AssetEntity?>> _assetCache = {};

  AssetEntity? _queryAsset;
  VisualSearchResults _results = const VisualSearchResults(
    topMatches: [],
    otherMatches: [],
  );

  bool _loading = true;
  bool _indexing = false;
  bool _cancelRequested = false;

  int _indexedCount = 0;
  int _totalImages = 0;

  VisualIndexProgress? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();

    _indexer = VisualSearchIndexer(
      embeddingService: _embeddingService,
      repository: _repository,
    );

    _loadSearch();
  }

  Future<void> _loadSearch() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final asset = await AssetEntity.fromId(widget.queryAssetId);
      if (asset == null) {
        throw StateError('لم تعد صورة البحث موجودة على الجهاز.');
      }

      final queryEmbedding = await _indexer.ensureEmbedding(asset);
      final results = await _repository.findSimilarImages(
        queryAssetId: asset.id,
        queryEmbedding: queryEmbedding,
        topCount: 10,
      );

      final indexedCount = await _repository.countIndexedImages();
      final totalImages = await _mediaRepository.getTotalCount(
        RequestType.image,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _queryAsset = asset;
        _results = results;
        _indexedCount = indexedCount;
        _totalImages = totalImages;
      });
    } catch (error, stackTrace) {
      debugPrint('Visual search failed: $error');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _indexAllMissing() async {
    if (_indexing) {
      return;
    }

    setState(() {
      _indexing = true;
      _cancelRequested = false;
      _progress = null;
      _error = null;
    });

    try {
      await _indexer.indexAllMissing(
        shouldCancel: () => _cancelRequested || !mounted,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _progress = progress;
          });
        },
      );

      if (mounted) {
        await _loadSearch();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _indexing = false;
        });
      }
    }
  }

  Future<AssetEntity?> _assetFor(String assetId) {
    return _assetCache.putIfAbsent(assetId, () => AssetEntity.fromId(assetId));
  }

  @override
  void dispose() {
    _cancelRequested = true;
    _embeddingService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('صور مشابهة')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_queryAsset == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error ?? 'تعذر فتح صورة البحث.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader(context)),
        if (_results.topMatches.isNotEmpty) ...[
          _sectionTitle(
            context,
            'أفضل 10 نتائج',
            'الصور الأقرب بصريًا للصورة المختارة.',
          ),
          _resultsGrid(_results.topMatches),
        ],
        if (_results.otherMatches.isNotEmpty) ...[
          _sectionTitle(
            context,
            'نتائج أخرى أقل تشابهًا',
            'صور أبعد قليلًا، مرتبة من الأقرب إلى الأبعد.',
          ),
          _resultsGrid(_results.otherMatches),
        ],
        if (_results.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _indexedCount <= 1
                    ? 'فهرس صور أكثر ثم أعد البحث.'
                    : 'لا توجد نتائج أخرى.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final progress = _progress;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 180,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AssetEntityImage(
                _queryAsset!,
                isOriginal: false,
                thumbnailSize: const ThumbnailSize.square(512),
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'الصورة المستخدمة للبحث',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text('مفهرس $_indexedCount من $_totalImages صورة للبحث بالصور.'),
          if (_indexedCount < _totalImages) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _indexing ? null : _indexAllMissing,
              icon: const Icon(Icons.storage_outlined),
              label: const Text('استكمال فهرسة الصور'),
            ),
          ],
          if (_indexing && progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress.progress),
            const SizedBox(height: 8),
            Text(
              '${progress.visited} / ${progress.total}\n'
              'جديد: ${progress.indexed}  '
              'موجود: ${progress.skipped}  '
              'تعذر: ${progress.failed}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _cancelRequested = true;
                });
              },
              icon: const Icon(Icons.stop),
              label: const Text('إيقاف بعد الصورة الحالية'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  SliverToBoxAdapter _sectionTitle(
    BuildContext context,
    String title,
    String subtitle,
  ) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  SliverGrid _resultsGrid(List<SimilarImageResult> results) {
    return SliverGrid(
      delegate: SliverChildBuilderDelegate((context, index) {
        final result = results[index];

        return FutureBuilder<AssetEntity?>(
          future: _assetFor(result.assetId),
          builder: (context, snapshot) {
            final asset = snapshot.data;
            if (asset == null) {
              return const SizedBox.shrink();
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                AssetEntityImage(
                  asset,
                  isOriginal: false,
                  thumbnailSize: const ThumbnailSize.square(320),
                  fit: BoxFit.cover,
                ),
                Positioned(
                  left: 5,
                  right: 5,
                  bottom: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${result.similarityPercent.toStringAsFixed(1)}%',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      }, childCount: results.length),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
      ),
    );
  }
}
