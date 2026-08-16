import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/media_item.dart';

/// تحتاج الـ AssetEntity مباشرة.
class SelectionState {
  final bool active;
  final Map<String, MediaItem> selected; // id -> item

  const SelectionState({
    this.active = false,
    this.selected = const {},
  });

  int get count => selected.length;
  bool isSelected(String id) => selected.containsKey(id);
  List<MediaItem> get items => selected.values.toList();
}

class SelectionController extends StateNotifier<SelectionState> {
  SelectionController() : super(const SelectionState());

  /// دخول وضع التحديد مع أول عنصر (عادةً عبر ضغطة مطوّلة).
  void enter(MediaItem item) {
    state = SelectionState(active: true, selected: {item.id: item});
  }

  /// إضافة/إزالة عنصر. لو القائمة فضيت نخرج من وضع التحديد.
  void toggle(MediaItem item) {
    final map = Map<String, MediaItem>.from(state.selected);
    if (map.remove(item.id) == null) {
      map[item.id] = item;
    }
    state = SelectionState(active: map.isNotEmpty, selected: map);
  }

  void selectAll(List<MediaItem> items) {
    state = SelectionState(
      active: true,
      selected: {for (final it in items) it.id: it},
    );
  }

  /// خروج كامل من وضع التحديد.
  void clear() => state = const SelectionState();
}

final selectionProvider =
    StateNotifierProvider<SelectionController, SelectionState>(
  (ref) => SelectionController(),
);
