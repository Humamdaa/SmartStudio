import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core/constants/app_colors.dart';
import '../../core/router/app_router.dart';
import '../../core/widgets/ios_ui.dart';
import '../../data/models/index_dashboard_stats.dart';
import '../../data/models/media_item.dart';
import '../../data/prefs/app_prefs.dart';
import '../../data/repositories/media_repository.dart';
import '../../services/smart_search_bridge.dart';
import '../../services/gallery/complete_smart_index_service.dart';
import '../../services/gallery/ocr_index_service.dart';
import '../albums/indexing_providers.dart';
import '../visual_search/visual_search_indexer.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import '../visual_search/visual_search_repository.dart';
import 'search_query.dart';
import 'search_vocabulary.dart';
import 'text_embedding_api.dart';

// ═══════════════════════════════════════════════════════════════
// Smart Search — teammate UI + stable v2.1.1 offline search engine.
//
// The app UI is always English. The AR/EN toggle picks the
// language the USER types or speaks in — not the interface.
//
// Local search is federated across the indexes that already know something:
// Face Lab supplies people, ObjectBox supplies dominant colors, the fast
// Content index supplies YOLO/scene/date, and Text Recognition fills OCR later. Filters
// are intersected by asset id, so a photo does not need one monolithic index
// row to be searchable. Image similarity stays on-device; natural-language
// descriptions use the FastAPI text-embedding service, while speech is only
// an input method.
// ═══════════════════════════════════════════════════════════════

enum SearchMethod {
  text,
  ocr,
  objects,
  people,
  scenes,
  date,
  image,
  color,
  voice,
}


/// Language of the query itself (speech locale + text matching).
enum QueryLang { arabic, english }

enum SearchScope { photos, videos, all }

enum VoiceState { idle, recording, transcribing, done }

class _CommittedFilter {
  final SearchMethod method;
  final String value;

  const _CommittedFilter(this.method, this.value);
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _transcript = TextEditingController();

  SearchMethod _method = SearchMethod.text;
  QueryLang _lang = QueryLang.arabic;
  SearchScope _scope = SearchScope.all;
  Color? _pickedColor;
  final List<_CommittedFilter> _filters = [];

  // ── نتائج البحث: text/OCR من v2.1.1، واللون من ObjectBox ─────
  final _smart = SmartSearchBridge();
  final _ocrIndexer = OcrIndexService.instance;
  final _textEmbeddingApi = TextEmbeddingApi();
  late final VisualSearchRepository _visualSearchRepository;

  int _semanticSearchRequest = 0;
  List<MediaItem> _results = [];
  bool _searching = false;
  Timer? _searchDebounce;
  String _searchStatus = 'Type a query to search the available local indexes.';

  IndexDashboardStats _aiStats = IndexDashboardStats.empty;
  bool _aiIndexing = false;
  bool _cancelAiIndex = false;
  bool _backgroundEnabled = false;
  bool _arabicOcrEnabled = true;
  bool _videoIndexingEnabled = true;
  String _aiStatus = 'Offline Content index is ready.';
  double? _aiProgress;
  int _ocrIndexedCount = 0;
  int _ocrFailedCount = 0;
  int _ocrTotalImages = 0;
  bool _lastOcrIndexRunning = false;


  final _mediaRepository = MediaRepository();
  late final VisualSearchIndexer _visualIndexer;
  late final CompleteSmartIndexService _completeSmartIndex;
  bool _lastCompleteSmartIndexRunning = false;
  int _visualIndexedCount = 0;
  int _visualTotalImages = 0;
  bool _visualIndexing = false;
  bool _cancelVisualIndex = false;
  VisualIndexProgress? _visualProgress;
  String _visualStatus = 'Visual index is ready.';

  @override
  void initState() {
    super.initState();
    // v2.3.9: Smart Index ownership moved to the root ProviderScope.
    // SearchScreen is now only a controller/view over the app-level job, so
    // switching tabs cannot dispose the running pipeline or its visual models.
    _visualSearchRepository = ref.read(visualSearchRepositoryProvider);
    _visualIndexer = ref.read(visualSearchIndexerProvider);
    _completeSmartIndex = ref.read(completeSmartIndexServiceProvider);
    _lastCompleteSmartIndexRunning = _completeSmartIndex.isRunning;
    _completeSmartIndex.progress.addListener(_onCompleteSmartIndexChanged);
    _lastOcrIndexRunning = _ocrIndexer.isRunning;
    _ocrIndexer.progress.addListener(_onOcrIndexChanged);
    _loadSmartState();
    _initSpeech();
  }

  Future<void> _submitTopSearch(String value) async {
    if (_method == SearchMethod.voice) {
      await _runSemanticTextSearch(value);
      return;
    }

    await _runIndexedSearch();
  }

  Future<void> _initSpeech() async {
    try {
      final available = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: (error) {
          _timer?.cancel();

          if (!mounted) return;

          setState(() {
            _speechError = error.errorMsg;

            if (_transcript.text.trim().isNotEmpty) {
              _voice = VoiceState.done;
            } else {
              _voice = VoiceState.idle;
            }
          });
        },
      );

      if (!available) {
        if (!mounted) return;

        setState(() {
          _speechReady = false;
          _speechError = 'Speech recognition is not available on this device.';
        });
        return;
      }

      final locales = await _speech.locales();

      String? arabicLocale;
      String? englishLocale;

      for (final locale in locales) {
        final id = locale.localeId.toLowerCase();

        if (arabicLocale == null && id.startsWith('ar')) {
          arabicLocale = locale.localeId;
        }

        if (englishLocale == null && id.startsWith('en')) {
          englishLocale = locale.localeId;
        }
      }

      if (!mounted) return;

      setState(() {
        _speechReady = true;
        _arabicLocaleId = arabicLocale;
        _englishLocaleId = englishLocale;
        _speechError = null;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _speechReady = false;
        _speechError = 'Speech initialization failed: $error';
      });
    }
  }

  Future<void> _loadSmartState() async {
    final background = await AppPrefs.instance.backgroundIndexingEnabled;
    final arabic = await AppPrefs.instance.arabicOcrEnabled;
    final videoIndexing = await AppPrefs.instance.videoIndexingEnabled;
    await _refreshAiStats();
    await _refreshOcrStats();
    await _refreshVisualStats();
    await _refreshCompleteSmartIndex();
    if (!mounted) return;
    setState(() {
      _backgroundEnabled = background;
      _arabicOcrEnabled = arabic;
      _videoIndexingEnabled = videoIndexing;
    });
  }

  Future<void> _refreshAiStats() async {
    try {
      final value = await _smart.stats();
      if (mounted) setState(() => _aiStats = value);
    } catch (_) {
      // Permission screen may still be active during first startup.
    }
  }

  Future<void> _refreshOcrStats() async {
    try {
      final indexed = await _ocrIndexer.indexedCount();
      final failed = await _ocrIndexer.failedCount();
      final total = await _mediaRepository.getTotalCount(RequestType.image);
      if (!mounted) return;
      setState(() {
        _ocrIndexedCount = indexed;
        _ocrFailedCount = failed;
        _ocrTotalImages = total;
      });
    } catch (_) {
      // Gallery/database permission may still be pending on first startup.
    }
  }

  Future<void> _refreshVisualStats() async {
    try {
      final indexed = await _visualSearchRepository.countIndexedImages();
      final total = await _mediaRepository.getTotalCount(RequestType.image);
      if (!mounted) return;
      setState(() {
        _visualIndexedCount = indexed;
        _visualTotalImages = total;
      });
    } catch (_) {
      // Gallery permission may still be pending during first startup.
    }
  }

  Future<void> _refreshCompleteSmartIndex() async {
    try {
      await _completeSmartIndex.refresh();
    } catch (_) {
      // The permission flow may still be active during first startup.
    }
  }

  void _onCompleteSmartIndexChanged() {
    final running = _completeSmartIndex.isRunning;
    if (_lastCompleteSmartIndexRunning && !running) {
      unawaited(_refreshAiStats());
      unawaited(_refreshOcrStats());
      unawaited(_refreshVisualStats());
    }
    _lastCompleteSmartIndexRunning = running;
  }

  void _onOcrIndexChanged() {
    final running = _ocrIndexer.isRunning;
    if (_lastOcrIndexRunning && !running) {
      unawaited(_refreshOcrStats());
      unawaited(_refreshCompleteSmartIndex());
      if (_composedQuery().isNotEmpty || _pickedColor != null) {
        unawaited(_runIndexedSearch());
      }
    }
    _lastOcrIndexRunning = running;
  }

  Future<void> _indexMissingVisualImages() async {
    if (_visualIndexing || _completeSmartIndex.isRunning) return;
    setState(() {
      _visualIndexing = true;
      _cancelVisualIndex = false;
      _visualProgress = null;
      _visualStatus = 'Preparing the visual index…';
    });
    try {
      final summary = await _visualIndexer.indexAllMissing(
        shouldCancel: () => _cancelVisualIndex || !mounted,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _visualProgress = progress;
            _visualStatus = progress.assetName == null
                ? 'Indexing visual embeddings…'
                : 'Indexing visual embeddings…\n${progress.assetName}';
          });
        },
      );
      await _refreshVisualStats();
      if (!mounted) return;
      setState(() {
        _visualStatus = summary.cancelled
            ? 'Visual indexing stopped safely.'
            : 'Visual index updated: ${summary.indexed} new, ${summary.failed} failed.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _visualStatus = 'Visual indexing error: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _visualIndexing = false;
          _visualProgress = null;
        });
      }
    }
  }

  Future<void> _pickImageForVisualSearch() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo access is required for image search.')),
      );
      return;
    }

    final total = await _mediaRepository.getTotalCount(RequestType.image);
    if (!mounted) return;
    if (total <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No photos are available to search with.')),
      );
      return;
    }

    final selected = await showModalBottomSheet<AssetEntity>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      showDragHandle: true,
      builder: (_) => _VisualPhotoPickerSheet(
        repository: _mediaRepository,
        total: total,
      ),
    );

    if (selected != null && mounted) {
      context.push(AppRoutes.visualSearch, extra: selected.id);
    }
  }


  bool _supportsIndexedText(SearchMethod method) => switch (method) {
    SearchMethod.text ||
    SearchMethod.ocr ||
    SearchMethod.objects ||
    SearchMethod.people ||
    SearchMethod.scenes ||
    SearchMethod.date => true,
    _ => false,
  };

  String? _prefixFor(SearchMethod method) => switch (method) {
    SearchMethod.ocr => 'ocr',
    SearchMethod.objects => 'object',
    SearchMethod.people => 'person',
    SearchMethod.scenes => 'scene',
    SearchMethod.date => 'date',
    _ => null,
  };

  String _filterLabel(SearchMethod method) => switch (method) {
    SearchMethod.ocr => 'OCR',
    SearchMethod.objects => 'Object',
    SearchMethod.people => 'Person',
    SearchMethod.scenes => 'Scene',
    SearchMethod.date => 'Date',
    SearchMethod.text => 'All',
    _ => 'Text',
  };

  String _qualified(SearchMethod method, String value) {
    final clean = value.trim().replaceAll('"', ' ');
    if (clean.isEmpty) return '';
    final prefix = _prefixFor(method);
    if (prefix == null) {
      // Unqualified text is the local All search. Multi-word input is split
      // into indexed terms by SearchQueryParser and combined with AND.
      return clean;
    }
    // Typed clauses are quoted so a value like "Fouad Dalloul" stays one
    // clause instead of being split by the compact query parser.
    return '$prefix:"$clean"';
  }

  String _composedQuery() {
    final parts = <String>[
      for (final filter in _filters) _qualified(filter.method, filter.value),
    ];
    if (_supportsIndexedText(_method)) {
      final current = _controller.text.trim();
      if (current.isNotEmpty) parts.add(_qualified(_method, current));
    }
    return parts.where((part) => part.isNotEmpty).join(' ');
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();

    if (_method == SearchMethod.voice) {
      _searchDebounce = Timer(
        const Duration(milliseconds: 700),
        () => _runSemanticTextSearch(value),
      );
      return;
    }

    if (!_supportsIndexedText(_method)) return;

    _searchDebounce = Timer(
      const Duration(milliseconds: 320),
      _runIndexedSearch,
    );
  }

  Future<void> _runSemanticTextSearch(String rawText) async {
    final text = rawText.trim();

    final requestId = ++_semanticSearchRequest;

    if (text.isEmpty) {
      if (!mounted) return;

      setState(() {
        _results = [];
        _searching = false;
        _searchStatus = 'Type or speak a description to search photos.';
      });

      return;
    }

    if (_scope == SearchScope.videos) {
      if (!mounted) return;

      setState(() {
        _results = [];
        _searching = false;
        _searchStatus =
            'Semantic embedding search currently works with indexed photos.';
      });

      return;
    }

    setState(() {
      _searching = true;
      _searchStatus = 'Creating text embedding…';
    });

    try {
      // Laptop:
      // text -> USE v4 -> text_projection -> normalized 256-D vector
      final textEmbedding = await _textEmbeddingApi.embed(text);

      if (!mounted ||
          requestId != _semanticSearchRequest ||
          _method != SearchMethod.voice) {
        return;
      }

      setState(() {
        _searchStatus = 'Comparing with indexed photos…';
      });

      // Phone:
      // 256-D text vector vs stored 256-D image vectors.
      final matches = await _visualSearchRepository.findSimilarByEmbedding(
        queryEmbedding: textEmbedding,
        limit: 60,
      );

      if (!mounted ||
          requestId != _semanticSearchRequest ||
          _method != SearchMethod.voice) {
        return;
      }

      final assets = await Future.wait(
        matches.map((match) => AssetEntity.fromId(match.assetId)),
      );

      if (!mounted ||
          requestId != _semanticSearchRequest ||
          _method != SearchMethod.voice) {
        return;
      }

      final items = <MediaItem>[];

      for (final asset in assets) {
        if (asset != null) {
          items.add(MediaItem.fromAsset(asset));
        }
      }

      setState(() {
        _results = items;
        _searching = false;

        if (items.isEmpty) {
          _searchStatus = 'No visual embeddings are available for this search.';
        } else {
          _searchStatus =
              '${items.length} semantic photo match${items.length == 1 ? '' : 'es'}';
        }
      });
    } catch (error) {
      if (!mounted || requestId != _semanticSearchRequest) {
        return;
      }

      final details = error.toString();
      final serviceUnavailable = details.contains('SocketException') ||
          details.contains('Connection refused') ||
          details.contains('Failed host lookup');
      final timedOut = details.contains('TimeoutException');

      setState(() {
        _results = [];
        _searching = false;
        _searchStatus = serviceUnavailable
            ? 'Semantic search service is unavailable. Start the FastAPI service or use the local search filters.'
            : timedOut
                ? 'Semantic search service did not respond in time. Try again or use the local search filters.'
                : 'Semantic search could not complete. Local AI search is still available.';
      });
    }
  }

  Future<void> _commitCurrentAs(SearchMethod method) async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _method = method);
      return;
    }
    setState(() {
      if (!_filters.any((f) => f.method == method && f.value == value)) {
        _filters.add(_CommittedFilter(method, value));
      }
      _controller.clear();
      _method = SearchMethod.text;
    });
    await _runIndexedSearch();
  }

  Future<void> _removeFilter(_CommittedFilter filter) async {
    setState(() => _filters.remove(filter));
    await _runIndexedSearch();
  }

  Future<void> _clearSearchFilters() async {
    setState(() {
      _filters.clear();
      _pickedColor = null;
      _method = SearchMethod.text;
    });
    await _runIndexedSearch();
  }

  Future<Set<String>> _colorIdsForArgb(int argb) async {
    final svc = ref.read(indexingServiceProvider);
    // One stable tolerance for the lightweight dominant-color index. Keeping
    // this source independent lets color search work before YOLO/OCR indexing.
    const maxDistance = 0.32;
    return svc
        .searchByColor(argb, maxDistance: maxDistance)
        .map((row) => row.assetId)
        .toSet();
  }

  Future<Set<String>> _matchingColorIds() async {
    final color = _pickedColor;
    if (color == null) return const <String>{};
    return _colorIdsForArgb(color.toARGB32());
  }

  String _indexedQueryForClause(SearchClause clause) {
    final value = clause.value.replaceAll('"', ' ').trim();
    if (value.isEmpty) return '';
    if (clause.field == SearchField.general) {
      return clause.exactPhrase || value.contains(' ') ? '"$value"' : value;
    }
    final prefix = switch (clause.field) {
      SearchField.people => 'person',
      SearchField.ocr => 'ocr',
      SearchField.objects => 'object',
      SearchField.colors => 'color',
      SearchField.scenes => 'scene',
      SearchField.date => 'date',
      SearchField.general => '',
    };
    return '$prefix:"$value"';
  }

  /// Returns ids for one logical clause from every local source that can
  /// answer it. Sources are UNIONed inside a clause; different clauses are
  /// intersected later. Example: `Fouad red` can use Face Lab for Fouad and
  /// ObjectBox for red even when neither photo has a heavy AI-index row.
  Future<Set<String>> _federatedIdsForClause(SearchClause clause) async {
    final indexedQuery = _indexedQueryForClause(clause);

    switch (clause.field) {
      case SearchField.people:
        final ids = await _smart.searchPersonAssetIds(clause.value);
        if (indexedQuery.isNotEmpty) {
          ids.addAll(
            await _smart.searchIndexedAssetIds(
              indexedQuery,
              domain: SmartSearchDomain.general,
            ),
          );
        }
        return ids;

      case SearchField.colors:
        final ids = <String>{};
        final argb = SearchVocabulary.colorArgbForTerm(clause.value);
        if (argb != null) ids.addAll(await _colorIdsForArgb(argb));
        if (indexedQuery.isNotEmpty) {
          ids.addAll(
            await _smart.searchIndexedAssetIds(
              indexedQuery,
              domain: SmartSearchDomain.general,
            ),
          );
        }
        return ids;

      case SearchField.general:
        final ids = <String>{};
        if (indexedQuery.isNotEmpty) {
          ids.addAll(
            await _smart.searchIndexedAssetIds(
              indexedQuery,
              domain: SmartSearchDomain.general,
            ),
          );
        }

        // A normal unqualified word may be a person's name. Query Face Lab
        // directly so naming someone is useful immediately, without Index All.
        ids.addAll(await _smart.searchPersonAssetIds(clause.value));

        // Likewise, a normal color word can use the lightweight ObjectBox
        // analysis that starts independently from the heavy content index.
        final argb = SearchVocabulary.colorArgbForTerm(clause.value);
        if (argb != null) ids.addAll(await _colorIdsForArgb(argb));
        return ids;

      case SearchField.ocr:
      case SearchField.objects:
      case SearchField.scenes:
      case SearchField.date:
        if (indexedQuery.isEmpty) return const <String>{};
        return _smart.searchIndexedAssetIds(
          indexedQuery,
          domain: SmartSearchDomain.general,
        );
    }
  }

  Future<Set<String>> _videoIdsForClause(SearchClause clause) async {
    switch (clause.field) {
      case SearchField.people:
        return _smart.searchVideoPersonAssetIds(clause.value);
      case SearchField.objects:
        return _smart.searchVideoObjectAssetIds(clause.value);
      case SearchField.general:
        return _smart.searchVideoGeneralAssetIds(clause.value);
      case SearchField.ocr:
      case SearchField.colors:
      case SearchField.scenes:
      case SearchField.date:
        // Smart Video Index v1 intentionally starts with objects + known
        // people only. Unsupported video filters simply contribute no ids.
        return const <String>{};
    }
  }

  Future<Set<String>> _scopedIdsForClause(SearchClause clause) async {
    switch (_scope) {
      case SearchScope.photos:
        return _federatedIdsForClause(clause);
      case SearchScope.videos:
        return _videoIdsForClause(clause);
      case SearchScope.all:
        final photoIds = await _federatedIdsForClause(clause);
        final videoIds = await _videoIdsForClause(clause);
        return <String>{...photoIds, ...videoIds};
    }
  }

  Future<List<MediaItem>> _resolveFederatedIds(Set<String> ids) async {
    if (ids.isEmpty) return const [];

    // Keep search responsive on huge libraries. Resolve in modest batches,
    // then order by the real PhotoManager creation date so Face/ObjectBox-only
    // results mix naturally with AI-indexed results.
    final candidates = ids.take(500).toList(growable: false);
    final items = <MediaItem>[];
    const batchSize = 32;
    for (var start = 0; start < candidates.length; start += batchSize) {
      final end = (start + batchSize < candidates.length)
          ? start + batchSize
          : candidates.length;
      final assets = await Future.wait(
        candidates.sublist(start, end).map(AssetEntity.fromId),
      );
      for (final asset in assets) {
        if (asset != null) items.add(MediaItem.fromAsset(asset));
      }
    }
    items.sort((a, b) => b.createDate.compareTo(a.createDate));
    return items.take(120).toList(growable: false);
  }

  Future<void> _runIndexedSearch() async {
    if (_method == SearchMethod.image || _method == SearchMethod.voice) return;
    final query = _composedQuery();
    final hasPickedColor = _pickedColor != null;
    if (query.isEmpty && !hasPickedColor) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _searching = false;
        _searchStatus =
            'Type a query or add a filter to search the local indexes.';
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchStatus = 'Searching available local indexes…';
    });

    try {
      Set<String>? combinedIds;

      if (query.isNotEmpty) {
        final parsed = SearchQueryParser.parse(query);
        for (final clause in parsed.clauses) {
          final clauseIds = await _scopedIdsForClause(clause);
          if (combinedIds == null) {
            combinedIds = Set<String>.of(clauseIds);
          } else {
            combinedIds.retainAll(clauseIds);
          }
          if (combinedIds.isEmpty) break;
        }
      }

      if (hasPickedColor) {
        final colorIds = _scope == SearchScope.videos
            ? const <String>{}
            : await _matchingColorIds();
        if (combinedIds == null) {
          combinedIds = Set<String>.of(colorIds);
        } else {
          combinedIds.retainAll(colorIds);
        }
      }

      final items = await _resolveFederatedIds(
        combinedIds ?? const <String>{},
      );
      if (!mounted) return;
      setState(() {
        _results = items;
        _searching = false;
        _searchStatus = items.isEmpty
            ? (_scope == SearchScope.videos
                ? 'No indexed video matched. Smart Video Index v1 searches sampled objects and known people.'
                : 'No available local index matched all selected filters.')
            : '${items.length} local ${_scope == SearchScope.videos ? 'video ' : ''}result${items.length == 1 ? '' : 's'} • using available indexes';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _searching = false;
        _searchStatus = 'Search error: $error';
      });
    }
  }

  Future<void> _indexNextAi() async {
    if (_aiIndexing || _completeSmartIndex.isRunning) return;
    setState(() {
      _aiIndexing = true;
      _cancelAiIndex = false;
      _aiProgress = null;
      _aiStatus = 'Preparing the next 20 unindexed photos…';
    });
    try {
      final result = await _smart.indexNext(
        limit: 20,
        shouldCancel: () => _cancelAiIndex,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _aiProgress = p.total <= 0 ? null : p.processed / p.total;
            _aiStatus = p.assetName == null
                ? p.phase
                : '${p.phase}\n${p.assetName}';
          });
        },
      );
      await _refreshAiStats();
      if (!mounted) return;
      setState(() {
        _aiStatus =
            result.pausedReason ??
            (result.cancelled
                ? 'Indexing stopped safely.'
                : 'Next batch finished: ${result.processed} processed, ${result.failed} failed.');
        if (!result.yoloReady && result.yoloError != null) {
          _aiStatus += '\nYOLO: ${result.yoloError}';
        }
      });
      if (_composedQuery().isNotEmpty || _pickedColor != null) {
        await _runIndexedSearch();
      }
    } catch (error) {
      if (mounted) setState(() => _aiStatus = 'Indexing error: $error');
    } finally {
      if (mounted) {
        setState(() {
          _aiIndexing = false;
          _aiProgress = null;
        });
      }
    }
  }

  Future<void> _reindexLatestAi() async {
    if (_aiIndexing || _completeSmartIndex.isRunning) return;
    setState(() {
      _aiIndexing = true;
      _cancelAiIndex = false;
      _aiProgress = null;
      _aiStatus = 'Refreshing the latest 20 photos…';
    });
    try {
      final result = await _smart.reindexRecent(
        limit: 20,
        shouldCancel: () => _cancelAiIndex,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _aiProgress = p.total <= 0 ? null : p.processed / p.total;
            _aiStatus = p.assetName == null
                ? p.phase
                : '${p.phase}\n${p.assetName}';
          });
        },
      );
      await _refreshAiStats();
      if (!mounted) return;
      setState(() {
        _aiStatus =
            result.pausedReason ??
            (result.cancelled
                ? 'Refresh stopped safely.'
                : 'Latest 20 refreshed: ${result.processed} processed, ${result.failed} failed.');
        if (!result.yoloReady && result.yoloError != null) {
          _aiStatus += '\nYOLO: ${result.yoloError}';
        }
      });
      if (_composedQuery().isNotEmpty || _pickedColor != null) {
        await _runIndexedSearch();
      }
    } catch (error) {
      if (mounted) setState(() => _aiStatus = 'Indexing error: $error');
    } finally {
      if (mounted) {
        setState(() {
          _aiIndexing = false;
          _aiProgress = null;
        });
      }
    }
  }

  Future<void> _indexAllAi() async {
    if (_aiIndexing || _completeSmartIndex.isRunning) return;
    setState(() {
      _aiIndexing = true;
      _cancelAiIndex = false;
      _aiProgress = null;
      _aiStatus = 'Discovering the complete photo library…';
    });
    try {
      final result = await _smart.indexAll(
        shouldCancel: () => _cancelAiIndex,
        onQueueProgress: (p) {
          if (!mounted) return;
          setState(() {
            _aiProgress = p.progress;
            _aiStatus = 'Queue: ${p.discovered}/${p.total} photos';
          });
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _aiProgress = p.total <= 0 ? null : p.processed / p.total;
            _aiStatus = p.assetName == null
                ? p.phase
                : '${p.phase}\n${p.assetName}';
          });
        },
      );
      await _refreshAiStats();
      if (!mounted) return;
      setState(() {
        _aiStatus =
            result.pausedReason ??
            (result.cancelled
                ? 'Indexing stopped safely; it can resume later.'
                : 'Content index finished: ${result.processed} processed, ${result.failed} failed.');
      });
      if (_controller.text.trim().isNotEmpty) await _runIndexedSearch();
    } catch (error) {
      if (mounted) setState(() => _aiStatus = 'Indexing error: $error');
    } finally {
      if (mounted) {
        setState(() {
          _aiIndexing = false;
          _aiProgress = null;
        });
      }
    }
  }

  Future<void> _indexNextOcr() async {
    if (_ocrIndexer.isRunning || _completeSmartIndex.isRunning) return;
    await _ocrIndexer.start(limit: 20);
  }

  Future<void> _refreshLatestOcr() async {
    if (_ocrIndexer.isRunning || _completeSmartIndex.isRunning) return;
    await _ocrIndexer.start(limit: 20, refreshRecent: true);
  }

  Future<void> _indexAllOcr() async {
    if (_ocrIndexer.isRunning || _completeSmartIndex.isRunning) return;
    await _ocrIndexer.start(limit: null);
  }

  Future<void> _toggleBackgroundIndex(bool enabled) async {
    setState(() => _backgroundEnabled = enabled);
    await _smart.setBackgroundEnabled(enabled);
  }

  Future<void> _toggleArabicOcr(bool enabled) async {
    setState(() => _arabicOcrEnabled = enabled);
    await AppPrefs.instance.setArabicOcrEnabled(enabled);
    await _refreshOcrStats();
    await _refreshCompleteSmartIndex();
  }

  Future<void> _toggleVideoIndexing(bool enabled) async {
    setState(() => _videoIndexingEnabled = enabled);
    await AppPrefs.instance.setVideoIndexingEnabled(enabled);
    await _refreshCompleteSmartIndex();
  }

  Future<void> _retryFailedAi() async {
    await _smart.retryFailed();
    await _refreshAiStats();
    if (mounted) {
      setState(() {
        _aiStatus = 'Failed photos returned to the queue.';
      });
    }
  }

  /// البحث باللون — بيقرأ من الألوان السائدة المفهرسة مسبقًا،
  /// فالنتيجة فورية بدون إعادة تحليل.
  ///
  /// نوع البحث بيتحكّم بمدى التسامح: "عام" بيوسّع النتائج،
  /// و"دقيق" بيرجّع الأقرب للّون المطلوب فقط.
  Future<void> _searchByColor(Color color) async {
    setState(() => _pickedColor = color);
    await _runIndexedSearch();
  }

  // ── Voice recording state ──────────────────────────────────
  final stt.SpeechToText _speech = stt.SpeechToText();

  VoiceState _voice = VoiceState.idle;
  Timer? _timer;
  int _seconds = 0;

  bool _speechReady = false;
  String? _arabicLocaleId;
  String? _englishLocaleId;
  String? _speechError;

  static const _colorSwatches = [
    Color(0xFFE24B4A),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF0FDFAF),
    Color(0xFF2D5F9E),
    Color(0xFF5856D6),
    Color(0xFFAF52DE),
    Color(0xFF8E8E93),
    Color(0xFF1A1A2E),
    Colors.white,
    Color(0xFF8B5A2B),
  ];

  @override
  void dispose() {
    _timer?.cancel();
    _searchDebounce?.cancel();
    _cancelVisualIndex = true;
    _speech.cancel();
    _completeSmartIndex.progress.removeListener(_onCompleteSmartIndexChanged);
    _ocrIndexer.progress.removeListener(_onOcrIndexChanged);
    _textEmbeddingApi.close();
    _controller.dispose();
    _transcript.dispose();
    super.dispose();
  }

  String get _langLabel => _lang == QueryLang.arabic ? 'العربية' : 'English';

  // ── Voice flow: idle → recording → transcribing → done ─────

  Future<void> _toggleRecording() async {
    if (_voice == VoiceState.recording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (!_speechReady) {
      setState(() {
        _speechError = 'Speech recognition is not ready.';
      });
      return;
    }

    final localeId = _lang == QueryLang.arabic
        ? _arabicLocaleId
        : _englishLocaleId;

    if (localeId == null) {
      setState(() {
        _speechError = _lang == QueryLang.arabic
            ? 'Arabic speech recognition is not installed on this device.'
            : 'English speech recognition is not installed on this device.';
      });
      return;
    }

    setState(() {
      _method = SearchMethod.voice;
      _voice = VoiceState.recording;
      _seconds = 0;
      _speechError = null;
      _transcript.clear();
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _seconds++);
      }
    });

    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        listenOptions: stt.SpeechListenOptions(
          localeId: localeId,
          partialResults: true,
          cancelOnError: true,
          listenMode: stt.ListenMode.dictation,
          pauseFor: const Duration(seconds: 3),
          listenFor: const Duration(seconds: 30),
        ),
      );
    } catch (error) {
      _timer?.cancel();

      if (!mounted) return;

      setState(() {
        _voice = VoiceState.idle;
        _speechError = 'Could not start speech recognition: $error';
      });
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final words = result.recognizedWords.trim();

    if (!mounted || words.isEmpty) return;

    setState(() {
      _transcript.text = words;

      _transcript.selection = TextSelection.fromPosition(
        TextPosition(offset: _transcript.text.length),
      );
    });
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();

    if (mounted) {
      setState(() {
        _voice = VoiceState.transcribing;
      });
    }

    await _speech.stop();

    if (!mounted) return;

    setState(() {
      _voice = VoiceState.done;
    });
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;

    if (status == 'done' || status == 'notListening') {
      _timer?.cancel();

      if (_voice == VoiceState.recording || _voice == VoiceState.transcribing) {
        setState(() {
          _voice = VoiceState.done;
        });
      }
    }
  }

  Future<void> _resetVoice() async {
    _timer?.cancel();

    if (_speech.isListening) {
      await _speech.cancel();
    }

    if (!mounted) return;

    setState(() {
      _voice = VoiceState.idle;
      _seconds = 0;
      _speechError = null;
      _transcript.clear();
    });
  }

  String get _timeLabel {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: kIosGroupedBg,
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              _buildSearchHeader(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: IosSearchField(
                  controller: _controller,
                  hint: _hintForMethod,
                  listening: _voice == VoiceState.recording,
                  onMic: _toggleRecording,
                  onChanged: _onQueryChanged,
                  onSubmitted: (value) async {
                    if (_method == SearchMethod.voice) {
                      _searchDebounce?.cancel();
                      await _runSemanticTextSearch(value);
                    } else {
                      await _runIndexedSearch();
                    }
                  },
                ),
              ),
              const IosSectionHeader('Search by'),
              _buildMethodRow(),
              if (_filters.isNotEmpty || _pickedColor != null)
                _buildActiveFilters(),
              _buildQueryOptionsSummary(),
              if (_method == SearchMethod.color) _buildColorPicker(),
              if (_method == SearchMethod.voice) _buildVoicePanel(),
              IosSectionHeader(
                _results.isEmpty ? 'Results' : 'Results (${_results.length})',
              ),
              _buildResults(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: TextButton.icon(
              onPressed: () => context.go(AppRoutes.home),
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 15),
              label: const Text('Photos'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.navyDeep,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              ),
            ),
          ),
          const Expanded(
            child: Column(
              children: [
                Text(
                  'Smart Search',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Local AI + semantic search',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 92,
            child: Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Search & indexing settings',
                onPressed: _showSearchSettings,
                icon: const Icon(Icons.settings_outlined),
                color: AppColors.navyDeep,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _scopeLabel => switch (_scope) {
        SearchScope.photos => 'Photos',
        SearchScope.videos => 'Videos',
        SearchScope.all => 'All media',
      };

  Widget _buildQueryOptionsSummary() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _showQueryOptions,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: kIosSeparator),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.tune_rounded,
                  size: 18,
                  color: AppColors.navyDeep,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '$_langLabel  •  $_scopeLabel',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showQueryOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kIosGroupedBg,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void refresh() => setSheetState(() {});
            return SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Search options',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Query language',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    IosSegmented<QueryLang>(
                      value: _lang,
                      segments: const {
                        QueryLang.arabic: 'العربية',
                        QueryLang.english: 'English',
                      },
                      onChanged: (value) {
                        setState(() => _lang = value);
                        refresh();
                      },
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Search in',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    IosSegmented<SearchScope>(
                      value: _scope,
                      segments: const {
                        SearchScope.photos: 'Photos',
                        SearchScope.videos: 'Videos',
                        SearchScope.all: 'All',
                      },
                      onChanged: (value) {
                        setState(() => _scope = value);
                        refresh();
                        _runIndexedSearch();
                      },
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Local filters search the on-device index. Use Describe for natural-language semantic search.',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showSearchSettings() async {
    await _refreshAiStats();
    await _refreshVisualStats();
    await _refreshCompleteSmartIndex();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: kIosGroupedBg,
      showDragHandle: true,
      builder: (_) => _SearchSettingsSheet(owner: this),
    );
  }

  String get _hintForMethod {
    switch (_method) {
      case SearchMethod.text:
        return _filters.isEmpty
            ? 'Search a word or phrase…'
            : 'Add another term…';
      case SearchMethod.ocr:
        return 'Type OCR text, then tap OCR to lock it…';
      case SearchMethod.objects:
        return 'Type an object, e.g. car…';
      case SearchMethod.people:
        return 'Type a named person…';
      case SearchMethod.scenes:
        return 'Type a scene, e.g. beach…';
      case SearchMethod.date:
        return 'Type a date/year…';
      case SearchMethod.voice:
        return 'Describe a photo, e.g. sunset over the sea…';
      default:
        return 'Search…';
    }
  }

  Widget _buildMethodRow() {
    const items = {
      SearchMethod.text: (Icons.auto_awesome_rounded, 'All'),
      SearchMethod.ocr: (Icons.document_scanner_outlined, 'OCR'),
      SearchMethod.objects: (Icons.category_outlined, 'Object'),
      SearchMethod.people: (Icons.face_retouching_natural, 'Person'),
      SearchMethod.scenes: (Icons.landscape_outlined, 'Scene'),
      SearchMethod.date: (Icons.calendar_month_outlined, 'Date'),
      SearchMethod.color: (Icons.palette_outlined, 'Color'),
      SearchMethod.image: (Icons.image_outlined, 'Image'),
      SearchMethod.voice: (Icons.auto_awesome_outlined, 'Describe'),
    };

    return SizedBox(
      height: 84,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: items.entries.map((e) {
          final active = e.key == _method;
          final (icon, label) = e.value;
          return GestureDetector(
            onTap: () async {
              if (_supportsIndexedText(e.key)) {
                // iPhone-like token flow for every searchable domain,
                // INCLUDING All: type a term -> tap a domain -> the term is
                // committed as a removable chip and the field becomes ready
                // for the next condition.
                await _commitCurrentAs(e.key);
                return;
              }
              if (e.key == SearchMethod.image) {
                await _pickImageForVisualSearch();
                return;
              }
              setState(() => _method = e.key);
              if (e.key == SearchMethod.voice) {
                final text = _controller.text.trim();
                if (text.isNotEmpty) {
                  await _runSemanticTextSearch(text);
                }
                return;
              }
              if (e.key == SearchMethod.color && _pickedColor != null) {
                await _runIndexedSearch();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 170),
              width: 78,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: active ? AppColors.navyDeep : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: active ? AppColors.navyDeep : kIosSeparator),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      color: active ? AppColors.mintAccent : AppColors.navyDeep,
                      size: 24),
                  const SizedBox(height: 7),
                  Text(label,
                      style: TextStyle(
                        color: active ? Colors.white : AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      )),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildActiveFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final filter in _filters)
            InputChip(
              label: Text('${_filterLabel(filter.method)}: ${filter.value}'),
              onDeleted: () => _removeFilter(filter),
              visualDensity: VisualDensity.compact,
              backgroundColor: AppColors.mintAccent.withValues(alpha: 0.14),
              side: BorderSide(
                color: AppColors.navyDeep.withValues(alpha: 0.18),
              ),
              labelStyle: const TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              deleteIconColor: AppColors.navyDeep,
            ),
          if (_pickedColor != null)
            InputChip(
              avatar: CircleAvatar(backgroundColor: _pickedColor, radius: 7),
              label: const Text('Color'),
              onDeleted: () async {
                setState(() => _pickedColor = null);
                await _runIndexedSearch();
              },
              visualDensity: VisualDensity.compact,
              backgroundColor: AppColors.mintAccent.withValues(alpha: 0.14),
              side: BorderSide(
                color: AppColors.navyDeep.withValues(alpha: 0.18),
              ),
              labelStyle: const TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              deleteIconColor: AppColors.navyDeep,
            ),
          TextButton(
            onPressed: _clearSearchFilters,
            child: const Text('Clear filters'),
          ),
        ],
      ),
    );
  }

  Widget _buildColorPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const IosSectionHeader('Pick a color'),
        IosCard(
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _colorSwatches.map((c) {
              final active = c == _pickedColor;
              return GestureDetector(
                onTap: () {
                  setState(() => _pickedColor = c);
                  _searchByColor(c);
                },
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: active ? AppColors.navyDeep : kIosSeparator,
                      width: active ? 3 : 1,
                    ),
                  ),
                  child: active
                      ? Icon(
                          Icons.check_rounded,
                          size: 20,
                          color: c.computeLuminance() > 0.6
                              ? Colors.black
                              : Colors.white,
                        )
                      : null,
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildImagePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const IosSectionHeader('Search by image'),
        const IosCard(
          child: DottedPlaceholder(
            icon: Icons.add_photo_alternate_outlined,
            label: 'Choose Image above to start the on-device similarity search',
          ),
        ),
      ],
    );
  }

  // ═════════════════════════════════════════════════════════════
  // Voice panel — explicit start/stop with a visible timer,
  // then an editable transcript before searching.
  // ═════════════════════════════════════════════════════════════
  Widget _buildVoicePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IosSectionHeader(
          'Describe with voice',
          trailing: _voice == VoiceState.idle
              ? null
              : GestureDetector(
                  onTap: _resetVoice,
                  child: const Text(
                    'Reset',
                    style: TextStyle(
                      color: AppColors.skyBlue,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
        ),
        IosCard(
          child: Column(
            children: [
              _buildVoiceStatus(),
              if (_speechError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _speechError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.errorRed,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 14),

              // زر التسجيل — واضح إنه ابدأ / إيقاف
              GestureDetector(
                onTap: _voice == VoiceState.transcribing
                    ? null
                    : _toggleRecording,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: _voice == VoiceState.recording
                        ? AppColors.errorRed
                        : AppColors.navyDeep,
                    shape: BoxShape.circle,
                    boxShadow: _voice == VoiceState.recording
                        ? [
                            BoxShadow(
                              color: AppColors.errorRed.withValues(alpha: 0.35),
                              blurRadius: 18,
                              spreadRadius: 4,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    _voice == VoiceState.recording
                        ? Icons.stop_rounded
                        : Icons.mic_rounded,
                    size: 38,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _voice == VoiceState.recording
                    ? 'Tap to stop'
                    : _voice == VoiceState.transcribing
                    ? 'Please wait…'
                    : 'Tap to start recording',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),

              // النص المحوّل — قابل للتعديل قبل البحث
              if (_voice == VoiceState.done) ...[
                const SizedBox(height: 16),
                const Divider(height: 1, color: kIosSeparator),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Transcript ($_langHintStatic)',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _transcript,
                  maxLines: 2,

                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),

                  cursorColor: AppColors.navyDeep,

                  textDirection: _lang == QueryLang.arabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,

                  textAlign: _lang == QueryLang.arabic
                      ? TextAlign.right
                      : TextAlign.left,
                  decoration: InputDecoration(
                    hintText: 'Your speech will appear here',

                    hintStyle: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),

                    filled: true,
                    fillColor: const Color(0xFFF4F5F8),

                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),

                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: kIosSeparator),
                    ),

                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: kIosSeparator),
                    ),

                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                        color: AppColors.navyDeep,
                        width: 1.4,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _searching
                        ? null
                        : () => _runSemanticTextSearch(_transcript.text),
                    icon: const Icon(Icons.image_search_rounded),
                    label: const Text('Search by description'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.navyDeep,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.skyBlue.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: AppColors.skyBlue,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _scope == SearchScope.videos
                            ? 'Video-audio matching is a UI prototype and is not connected yet.'
                            : 'Speech is converted to editable text, then the description is matched semantically against indexed photo embeddings.',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _langHintStatic = 'editable';

  Widget _buildVoiceStatus() {
    switch (_voice) {
      case VoiceState.recording:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: AppColors.errorRed,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Recording',
              style: TextStyle(
                color: AppColors.errorRed,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _timeLabel,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      case VoiceState.transcribing:
        return const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.navyDeep,
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Converting speech to text…',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13.5),
            ),
          ],
        );
      case VoiceState.done:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.check_circle_rounded,
              size: 16,
              color: AppColors.mintAccent,
            ),
            const SizedBox(width: 7),
            Text(
              'Recorded $_timeLabel',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      case VoiceState.idle:
        return Text(
          'Speaking in $_langLabel',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        );
    }
  }

  Widget _buildCompleteSmartIndexCard() {
    return ValueListenableBuilder<CompleteSmartIndexState>(
      valueListenable: _completeSmartIndex.progress,
      builder: (context, state, _) {
        final snapshot = state.snapshot;
        final total = snapshot.total;
        final complete = snapshot.isComplete;
        return IosCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.mintAccent.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      size: 20,
                      color: AppColors.mintAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '5-stage Smart Index pipeline',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'One coordinated pipeline; each specialized stage skips work that is already complete.',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (complete)
                    const Icon(
                      Icons.check_circle_rounded,
                      color: AppColors.mintAccent,
                      size: 22,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: state.overallFraction.clamp(0.0, 1.0),
                color: AppColors.navyDeep,
              ),
              const SizedBox(height: 12),
              _buildSmartIndexStageRow(
                icon: Icons.photo_library_outlined,
                label: 'Gallery analysis',
                subtitle: 'pHash • dominant color • quality',
                done: snapshot.safeGalleryAnalyzed,
                total: total,
                active: state.running &&
                    state.stage == CompleteSmartIndexStage.gallery,
              ),
              _buildSmartIndexStageRow(
                icon: Icons.psychology_alt_outlined,
                label: 'Content understanding',
                subtitle: snapshot.videoIndexingEnabled
                    ? 'Photos: objects • scenes • colors • metadata\nVideos: sampled objects ${snapshot.safeVideoContentIndexed}/${snapshot.videoTotal}'
                    : 'Objects • scenes • named colors • metadata • Video indexing off',
                done: snapshot.safeContentIndexed,
                total: total,
                active: state.running &&
                    state.stage == CompleteSmartIndexStage.content,
                completeOverride: snapshot.contentComplete,
              ),
              _buildSmartIndexStageRow(
                icon: Icons.text_snippet_outlined,
                label: 'Text recognition',
                subtitle: snapshot.arabicOcrEnabled
                    ? 'English OCR • Arabic OCR when needed'
                    : 'English OCR • Arabic OCR off',
                done: snapshot.safeOcrIndexed,
                total: total,
                active: state.running &&
                    state.stage == CompleteSmartIndexStage.ocr,
              ),
              _buildSmartIndexStageRow(
                icon: Icons.people_alt_outlined,
                label: 'People',
                subtitle: snapshot.videoIndexingEnabled
                    ? 'Photos: Face v3 • MobileFaceNet\nVideos: known-person matches ${snapshot.safeVideoPeopleIndexed}/${snapshot.videoTotal}'
                    : 'Face v3 • alignment • MobileFaceNet • clustering • Video indexing off',
                done: snapshot.safePeopleIndexed,
                total: total,
                active: state.running &&
                    state.stage == CompleteSmartIndexStage.people,
                completeOverride: snapshot.peopleComplete,
              ),
              _buildSmartIndexStageRow(
                icon: Icons.image_search_outlined,
                label: 'Visual search',
                subtitle: 'Image embeddings for Image + Describe search',
                done: snapshot.safeVisualIndexed,
                total: total,
                active: state.running &&
                    state.stage == CompleteSmartIndexStage.visual,
                showDivider: false,
              ),
              const SizedBox(height: 10),
              const Divider(height: 1, color: kIosSeparator),
              IosRow(
                icon: Icons.video_settings_outlined,
                iconBg: AppColors.mintAccent,
                title: 'Smart video indexing',
                subtitle: _videoIndexingEnabled
                    ? 'On. Samples video frames for objects and known people. Turn it off for faster photo-only indexing.'
                    : 'Off. Complete Smart Index skips all video AI processing for a faster photo pass.',
                showDivider: false,
                trailing: IosSwitch(
                  value: _videoIndexingEnabled,
                  onChanged: (value) {
                    if (!state.running) {
                      unawaited(_toggleVideoIndexing(value));
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                state.status,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              if (state.running)
                OutlinedButton.icon(
                  onPressed: _completeSmartIndex.stop,
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('Stop safely'),
                )
              else
                FilledButton.icon(
                  onPressed: complete || _aiIndexing || _ocrIndexer.isRunning || _visualIndexing
                      ? null
                      : () async {
                          await _completeSmartIndex.start();
                        },
                  icon: Icon(
                    complete
                        ? Icons.check_circle_outline_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  label: Text(
                    complete ? 'Smart index complete' : 'Continue Smart Index',
                  ),
                ),
              const SizedBox(height: 8),
              const Text(
                'Pipeline: Gallery → Content → Text Recognition → People → Visual. It continues across app tabs, while each stage remains independently resumable and searchable through the unified local indexes.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 10.8,
                  height: 1.35,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSmartIndexStageRow({
    required IconData icon,
    required String label,
    required String subtitle,
    required int done,
    required int total,
    required bool active,
    bool? completeOverride,
    bool showDivider = true,
  }) {
    final stageComplete = completeOverride ?? (total > 0 && done >= total);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(
                stageComplete
                    ? Icons.check_circle_rounded
                    : active
                        ? Icons.timelapse_rounded
                        : icon,
                size: 19,
                color: stageComplete || active
                    ? AppColors.mintAccent
                    : AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 10.8,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                total <= 0 ? '—' : '$done / $total',
                style: TextStyle(
                  color: stageComplete
                      ? AppColors.mintAccent
                      : AppColors.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (showDivider) const Divider(height: 1, color: kIosSeparator),
      ],
    );
  }

  Widget _buildAiIndexCard() {
    final s = _aiStats;
    return IosCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Content ${s.indexedImages}/${s.totalImages}  •  Failed ${s.failedImages}\n'
                  'Objects • scenes • named colors • metadata',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ),
              if (_aiIndexing)
                IconButton(
                  tooltip: 'Stop after current step',
                  onPressed: () => setState(() => _cancelAiIndex = true),
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    color: AppColors.errorRed,
                  ),
                ),
            ],
          ),
          if (_aiProgress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _aiProgress!.clamp(0.0, 1.0),
              color: AppColors.navyDeep,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _aiStatus,
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _aiIndexing ? null : _indexNextAi,
                icon: const Icon(Icons.skip_next_rounded, size: 18),
                label: const Text('Index next 20'),
              ),
              OutlinedButton.icon(
                onPressed: _aiIndexing ? null : _reindexLatestAi,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Refresh latest 20'),
              ),
              OutlinedButton.icon(
                onPressed: _aiIndexing ? null : _indexAllAi,
                icon: const Icon(Icons.all_inclusive_rounded, size: 18),
                label: const Text('Index all content'),
              ),
              if (s.failedImages > 0)
                TextButton.icon(
                  onPressed: _aiIndexing ? null : _retryFailedAi,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text('Retry failed (${s.failedImages})'),
                ),
            ],
          ),
          const Divider(height: 20, color: kIosSeparator),
          IosRow(
            icon: Icons.battery_saver_outlined,
            iconBg: AppColors.mintAccent,
            title: 'Background AI indexing',
            subtitle:
                'YOLO + Scene + named colors + metadata in small Android slices; OCR and People are separate stages',
            showDivider: false,
            trailing: IosSwitch(
              value: _backgroundEnabled,
              onChanged: _toggleBackgroundIndex,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOcrIndexCard() {
    return ValueListenableBuilder<OcrIndexProgress>(
      valueListenable: _ocrIndexer.progress,
      builder: (context, p, _) {
        final complete = _ocrTotalImages > 0 && _ocrIndexedCount >= _ocrTotalImages;
        return IosCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Text recognized $_ocrIndexedCount/$_ocrTotalImages  •  Failed $_ocrFailedCount\n'
                      '${_arabicOcrEnabled ? 'English + optional Arabic' : 'English only • Arabic off'}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                        height: 1.45,
                      ),
                    ),
                  ),
                  if (p.running)
                    IconButton(
                      tooltip: 'Stop after current photo',
                      onPressed: _ocrIndexer.stop,
                      icon: const Icon(
                        Icons.stop_circle_outlined,
                        color: AppColors.errorRed,
                      ),
                    ),
                ],
              ),
              if (p.running && p.fraction != null) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: p.fraction!.clamp(0.0, 1.0),
                  color: AppColors.navyDeep,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                p.status,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: p.running || _completeSmartIndex.isRunning
                        ? null
                        : _indexNextOcr,
                    icon: const Icon(Icons.skip_next_rounded, size: 18),
                    label: const Text('OCR next 20'),
                  ),
                  OutlinedButton.icon(
                    onPressed: p.running || _completeSmartIndex.isRunning
                        ? null
                        : _refreshLatestOcr,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Refresh OCR latest 20'),
                  ),
                  OutlinedButton.icon(
                    onPressed: p.running || _completeSmartIndex.isRunning || complete
                        ? null
                        : _indexAllOcr,
                    icon: const Icon(Icons.text_snippet_outlined, size: 18),
                    label: Text(complete ? 'OCR complete' : 'Index all text'),
                  ),
                ],
              ),
              const Divider(height: 20, color: kIosSeparator),
              IosRow(
                icon: Icons.translate_rounded,
                iconBg: AppColors.skyBlue,
                title: 'Arabic OCR',
                subtitle: _arabicOcrEnabled
                    ? 'Enabled. Full OCR uses the text-heavy heuristic; Refresh latest 20 forces Arabic for testing.'
                    : 'Disabled. Text Recognition runs the faster English ML Kit stage only.',
                showDivider: false,
                trailing: IosSwitch(
                  value: _arabicOcrEnabled,
                  onChanged: (value) {
                    if (!p.running) _toggleArabicOcr(value);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildVisualIndexCard() {
    final progress = _visualProgress;
    final complete = _visualTotalImages > 0 &&
        _visualIndexedCount >= _visualTotalImages;
    return IosCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.skyBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.image_search_rounded,
                  size: 19,
                  color: AppColors.skyBlue,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Image similarity embeddings',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$_visualIndexedCount / $_visualTotalImages photos ready for image search',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (_visualIndexing)
                IconButton(
                  tooltip: 'Stop after current image',
                  onPressed: () => setState(() => _cancelVisualIndex = true),
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    color: AppColors.errorRed,
                  ),
                ),
            ],
          ),
          if (_visualIndexing && progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: progress.progress,
              color: AppColors.navyDeep,
            ),
            const SizedBox(height: 6),
            Text(
              '${progress.visited}/${progress.total} checked  •  '
              '${progress.indexed} new  •  ${progress.failed} failed',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11.5,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _visualStatus,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: _visualIndexing || complete
                ? null
                : _indexMissingVisualImages,
            icon: Icon(
              complete ? Icons.check_circle_outline : Icons.add_photo_alternate_outlined,
              size: 18,
            ),
            label: Text(complete ? 'Visual index is complete' : 'Index missing photos'),
          ),
        ],
      ),
    );
  }

  /// النتائج — شبكة صور حقيقية للبحث باللون وبالفهرس الذكي المحلي.
  Widget _buildResults() {
    if (_searching) {
      return const IosCard(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: CircularProgressIndicator(color: AppColors.navyDeep),
        ),
      );
    }
    if (_results.isEmpty) return _buildEmptyResults();

    return IosCard(
      padding: const EdgeInsets.all(6),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: _results.length,
        itemBuilder: (_, i) {
          final item = _results[i];
          return GestureDetector(
            onTap: () => context.push(
              AppRoutes.detail,
              extra: {'id': item.id, 'items': _results},
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image(
                    image: AssetEntityImageProvider(
                      item.asset,
                      isOriginal: false,
                      thumbnailSize: const ThumbnailSize.square(200),
                    ),
                    fit: BoxFit.cover,
                  ),
                  if (item.isVideo)
                    const Positioned(
                      right: 5,
                      bottom: 5,
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 21,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 4),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyResults() => IosCard(
    padding: const EdgeInsets.symmetric(vertical: 38, horizontal: 16),
    child: Column(
      children: [
        Container(
          width: 62,
          height: 62,
          decoration: BoxDecoration(
            color: AppColors.navyDeep.withValues(alpha: 0.06),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.search_rounded,
            size: 30,
            color: AppColors.navyDeep.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          _searchStatus,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
}

class _SearchSettingsSheet extends StatefulWidget {
  const _SearchSettingsSheet({required this.owner});

  final _SearchScreenState owner;

  @override
  State<_SearchSettingsSheet> createState() => _SearchSettingsSheetState();
}

class _SearchSettingsSheetState extends State<_SearchSettingsSheet> {
  Timer? _refreshTimer;
  bool _statsRefreshBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStats());
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refreshStats());
    });
  }

  Future<void> _refreshStats() async {
    if (_statsRefreshBusy || !mounted || !widget.owner.mounted) return;
    _statsRefreshBusy = true;
    try {
      final owner = widget.owner;
      await Future.wait([
        owner._refreshAiStats(),
        owner._refreshOcrStats(),
        owner._refreshVisualStats(),
        owner._refreshCompleteSmartIndex(),
      ]);
      if (mounted) setState(() {});
    } finally {
      _statsRefreshBusy = false;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget.owner;
    if (!owner.mounted) return const SizedBox.shrink();

    return FractionallySizedBox(
      heightFactor: 0.92,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Search & Indexing',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Advanced controls stay here so search results remain uncluttered.',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh stats',
                  onPressed: _statsRefreshBusy ? null : _refreshStats,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text(
              'Smart Index',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            owner._buildCompleteSmartIndexCard(),
            const SizedBox(height: 22),
            const Text(
              'AI Index',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            owner._buildAiIndexCard(),
            const SizedBox(height: 22),
            const Text(
              'Text Recognition',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            owner._buildOcrIndexCard(),
            const SizedBox(height: 22),
            const Text(
              'Visual Index',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            owner._buildVisualIndexCard(),
            const SizedBox(height: 22),
            const Text(
              'Semantic Search',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            IosCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded,
                          color: AppColors.navyDeep, size: 20),
                      SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Natural-language descriptions',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Only the text query is sent to the configured FastAPI embedding service. Photo embeddings and similarity matching stay on the device.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Service: ${owner._textEmbeddingApi.baseUrl}',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty picking area with a dashed-looking border.
class DottedPlaceholder extends StatelessWidget {
  final IconData icon;
  final String label;
  const DottedPlaceholder({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
    height: 128,
    width: double.infinity,
    decoration: BoxDecoration(
      color: AppColors.navyDeep.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: AppColors.navyDeep.withValues(alpha: 0.18),
        width: 1.4,
      ),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 30, color: AppColors.navyDeep),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
      ],
    ),
  );
}

class _VisualPhotoPickerSheet extends StatefulWidget {
  const _VisualPhotoPickerSheet({
    required this.repository,
    required this.total,
  });

  final MediaRepository repository;
  final int total;

  @override
  State<_VisualPhotoPickerSheet> createState() =>
      _VisualPhotoPickerSheetState();
}

class _VisualPhotoPickerSheetState extends State<_VisualPhotoPickerSheet> {
  static const _pageSize = 80;
  final ScrollController _scrollController = ScrollController();
  final List<AssetEntity> _assets = [];
  bool _loading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loading || !_hasMore) return;
    if (_scrollController.position.extentAfter < 700) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    final start = _assets.length;
    final requestedEnd = start + _pageSize;
    final end = requestedEnd > widget.total ? widget.total : requestedEnd;
    try {
      final next = await widget.repository.loadAssetRange(
        type: RequestType.image,
        start: start,
        end: end,
      );
      if (!mounted) return;
      setState(() {
        _assets.addAll(next);
        _hasMore = _assets.length < widget.total && next.isNotEmpty;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.86,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Choose a photo',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_assets.length}/${widget.total} loaded • scroll for older photos',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 3,
                crossAxisSpacing: 3,
              ),
              itemCount: _assets.length,
              itemBuilder: (_, index) {
                final asset = _assets[index];
                return GestureDetector(
                  onTap: () => Navigator.of(context).pop(asset),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image(
                      image: AssetEntityImageProvider(
                        asset,
                        isOriginal: false,
                        thumbnailSize: const ThumbnailSize.square(220),
                      ),
                      fit: BoxFit.cover,
                    ),
                  ),
                );
              },
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

