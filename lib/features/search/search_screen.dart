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
import '../../services/smart_search_bridge.dart';
import '../albums/indexing_providers.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import '../visual_search/visual_search_repository.dart';
import 'text_embedding_api.dart';

// ═══════════════════════════════════════════════════════════════
// Smart Search — teammate UI + stable v2.1.1 offline search engine.
//
// The app UI is always English. The AR/EN toggle picks the
// language the USER types or speaks in — not the interface.
//
// Text/OCR/object/person/scene/date use the merged local SQLite AI index.
// Color keeps the teammate ObjectBox color-distance index and can now be
// intersected with the typed AI filters. Image and voice remain UI prototypes.
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

enum SearchMode { general, precise }

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
  SearchMode _mode = SearchMode.general;
  QueryLang _lang = QueryLang.arabic;
  SearchScope _scope = SearchScope.all;
  Color? _pickedColor;
  final List<_CommittedFilter> _filters = [];

  // ── نتائج البحث: text/OCR من v2.1.1، واللون من ObjectBox ─────
  final _smart = SmartSearchBridge();
  final _textEmbeddingApi = TextEmbeddingApi();
  final _visualSearchRepository = VisualSearchRepository();

  int _semanticSearchRequest = 0;
  List<MediaItem> _results = [];
  bool _searching = false;
  Timer? _searchDebounce;
  String _searchStatus = 'Type a query to search the offline index.';

  IndexDashboardStats _aiStats = IndexDashboardStats.empty;
  bool _aiIndexing = false;
  bool _cancelAiIndex = false;
  bool _backgroundEnabled = false;
  bool _arabicOcrEnabled = true;
  String _aiStatus = 'Offline AI index is ready.';
  double? _aiProgress;

  @override
  void initState() {
    super.initState();
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
    await _refreshAiStats();
    if (!mounted) return;
    setState(() {
      _backgroundEnabled = background;
      _arabicOcrEnabled = arabic;
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
      return _mode == SearchMode.precise ? '"$clean"' : clean;
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

      setState(() {
        _results = [];
        _searching = false;
        _searchStatus = 'Semantic search error: $error';
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

  Future<Set<String>> _matchingColorIds() async {
    final color = _pickedColor;
    if (color == null) return const <String>{};
    final svc = ref.read(indexingServiceProvider);
    final maxDistance = _mode == SearchMode.general ? 0.32 : 0.14;
    return svc
        .searchByColor(color.toARGB32(), maxDistance: maxDistance)
        .map((row) => row.assetId)
        .toSet();
  }

  Future<List<MediaItem>> _resolveColorOnly(Set<String> ids) async {
    final items = <MediaItem>[];
    for (final id in ids.take(120)) {
      final asset = await AssetEntity.fromId(id);
      if (asset != null) items.add(MediaItem.fromAsset(asset));
    }
    return items;
  }

  String? _aiColorLabel(Color? color) {
    if (color == null) return null;
    final value = color.toARGB32();
    const labels = <int, String>{
      0xFFE24B4A: 'red',
      0xFFFF9500: 'orange-color',
      0xFFFFCC00: 'yellow',
      0xFF34C759: 'green',
      0xFF0FDFAF: 'cyan',
      0xFF2D5F9E: 'blue',
      0xFF5856D6: 'blue',
      0xFFAF52DE: 'purple',
      0xFF8E8E93: 'gray',
      0xFF1A1A2E: 'black',
      0xFFFFFFFF: 'white',
      0xFF8B5A2B: 'brown',
    };
    return labels[value];
  }

  Future<void> _runIndexedSearch() async {
    if (_method == SearchMethod.image || _method == SearchMethod.voice) return;
    final query = _composedQuery();
    final hasColor = _pickedColor != null;
    if (query.isEmpty && !hasColor) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _searching = false;
        _searchStatus =
            'Type a query or add a filter to search the offline index.';
      });
      return;
    }
    if (_scope == SearchScope.videos) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _searching = false;
        _searchStatus =
            'The current AI index covers photos; video semantic search is not wired yet.';
      });
      return;
    }

    setState(() {
      _searching = true;
      _searchStatus = 'Searching locally…';
    });
    try {
      List<MediaItem> items;
      if (query.isEmpty) {
        // Color-only search keeps the teammate ObjectBox distance matcher,
        // which supports near-RGB matches better than named color labels.
        final colorIds = await _matchingColorIds();
        items = await _resolveColorOnly(colorIds);
      } else {
        // Combined filters must all come from the same indexed snapshot.
        // This avoids an empty result caused only by SQLite and ObjectBox
        // covering different subsets of the gallery.
        final colorLabel = hasColor ? _aiColorLabel(_pickedColor) : null;
        final combinedQuery = colorLabel == null
            ? query
            : '$query color:"$colorLabel"';
        final hits = await _smart.search(
          combinedQuery,
          domain: SmartSearchDomain.general,
        );
        items = hits.map((e) => e.item).toList(growable: false);
      }
      if (!mounted) return;
      setState(() {
        _results = items;
        _searching = false;
        _searchStatus = items.isEmpty
            ? 'No indexed photo matched all selected filters.'
            : '${items.length} local result${items.length == 1 ? '' : 's'}';
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
    if (_aiIndexing) return;
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
    if (_aiIndexing) return;
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
    if (_aiIndexing) return;
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
                : 'Full index pass finished: ${result.processed} processed, ${result.failed} failed.');
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

  Future<void> _toggleBackgroundIndex(bool enabled) async {
    setState(() => _backgroundEnabled = enabled);
    await _smart.setBackgroundEnabled(enabled);
  }

  Future<void> _toggleArabicOcr(bool enabled) async {
    setState(() => _arabicOcrEnabled = enabled);
    await AppPrefs.instance.setArabicOcrEnabled(enabled);
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
    _speech.cancel();
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
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: kIosGroupedBg,
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              const IosLargeTitle(
                title: 'Smart Search',
                subtitle:
                    'Offline multi-filter search • image & voice prototypes',
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: IosSearchField(
                  controller: _controller,
                  hint: _hintForMethod,
                  listening: _voice == VoiceState.recording,
                  onMic: _toggleRecording,

                  onChanged: (value) {
                    if (_method == SearchMethod.voice) {
                      _searchDebounce?.cancel();

                      final text = value.trim();

                      if (text.isEmpty) {
                        setState(() {
                          _results = [];
                          _searching = false;
                          _searchStatus =
                              'Type or speak a description to search photos.';
                        });
                        return;
                      }

                      _searchDebounce = Timer(
                        const Duration(milliseconds: 700),
                        () {
                          _runSemanticTextSearch(text);
                        },
                      );

                      return;
                    }

                    _onQueryChanged(value);
                  },

                  onSubmitted: (value) async {
                    if (_method == SearchMethod.voice) {
                      _searchDebounce?.cancel();
                      await _runSemanticTextSearch(value);
                      return;
                    }

                    await _runIndexedSearch();
                  },
                ),
              ),

              const IosSectionHeader('Add current term as'),
              _buildMethodRow(),
              if (_filters.isNotEmpty || _pickedColor != null)
                _buildActiveFilters(),

              // ── Query language (NOT the app language) ────────
              const IosSectionHeader('Query language'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: IosSegmented<QueryLang>(
                  value: _lang,
                  segments: const {
                    QueryLang.arabic: 'العربية',
                    QueryLang.english: 'English',
                  },
                  onChanged: (l) => setState(() => _lang = l),
                ),
              ),

              // ── Scope ────────────────────────────────────────
              const IosSectionHeader('Search in'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: IosSegmented<SearchScope>(
                  value: _scope,
                  segments: const {
                    SearchScope.photos: 'Photos',
                    SearchScope.videos: 'Videos',
                    SearchScope.all: 'All',
                  },
                  onChanged: (scope) {
                    setState(() => _scope = scope);
                    _runIndexedSearch();
                  },
                ),
              ),

              // ── Mode ─────────────────────────────────────────
              const IosSectionHeader('Search mode'),
              IosCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IosSegmented<SearchMode>(
                      value: _mode,
                      segments: const {
                        SearchMode.general: 'General',
                        SearchMode.precise: 'Precise',
                      },
                      onChanged: (mode) {
                        setState(() => _mode = mode);
                        _runIndexedSearch();
                      },
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _mode == SearchMode.general
                          ? 'Broader results — includes near matches'
                          : 'Narrow, more detailed results',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),

              if (_method == SearchMethod.color) _buildColorPicker(),
              if (_method == SearchMethod.image) _buildImagePicker(),
              if (_method == SearchMethod.voice) _buildVoicePanel(),

              const IosSectionHeader('Offline AI index'),
              _buildAiIndexCard(),

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
        return 'Tap the mic to speak…';
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
      SearchMethod.voice: (Icons.mic_none_rounded, 'Voice'),
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
                  color: active ? AppColors.navyDeep : kIosSeparator,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    color: active ? AppColors.mintAccent : AppColors.navyDeep,
                    size: 24,
                  ),
                  const SizedBox(height: 7),
                  Text(
                    label,
                    style: TextStyle(
                      color: active ? Colors.white : AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
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
            label: 'Image similarity UI prototype — model not connected yet',
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
          'Voice search',
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
                    label: const Text('Search photos with this text'),
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
                            : 'Speak a short search phrase. You can edit the transcript before searching.',
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
                  'Indexed ${s.indexedImages}/${s.totalImages}  •  Failed ${s.failedImages}\n'
                  'Faces ${s.detectedFaces}  •  People ${s.people}  •  Arabic OCR ${s.arabicOcrImages}',
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
                label: const Text('Index all'),
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
                'Runs in small Android slices; low battery blocks background only',
            showDivider: true,
            trailing: IosSwitch(
              value: _backgroundEnabled,
              onChanged: _toggleBackgroundIndex,
            ),
          ),
          IosRow(
            icon: Icons.translate_rounded,
            iconBg: AppColors.skyBlue,
            title: 'Arabic OCR',
            subtitle:
                'Offline Arabic OCR; manual/20-photo batches always run it when enabled',
            showDivider: false,
            trailing: IosSwitch(
              value: _arabicOcrEnabled,
              onChanged: _toggleArabicOcr,
            ),
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
              child: Image(
                image: AssetEntityImageProvider(
                  item.asset,
                  isOriginal: false,
                  thumbnailSize: const ThumbnailSize.square(200),
                ),
                fit: BoxFit.cover,
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
