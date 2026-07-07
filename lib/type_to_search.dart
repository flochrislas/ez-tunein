import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared "type-to-search" filter behaviour for a page: the query string, a
/// visible flag, the text field + focus nodes, and the keystroke handling that
/// opens the filter on the first printable character. The host page supplies its
/// own search-bar widget (they differ) and reacts to query changes by overriding
/// [onQueryChanged] — this removes the ~90 lines that were duplicated (and
/// hand-synced) between the player and the track-list pages.
///
/// Usage: `with TypeToSearch<MyPage>`, wire `onKeyEvent: onPageKey` on a page
/// [Focus] holding [pageFocus], call [openSearch]/[closeSearch]/[setQuery], and
/// call [disposeSearch] from the State's dispose.
mixin TypeToSearch<W extends StatefulWidget> on State<W> {
  String query = '';
  bool searching = false;
  final searchController = TextEditingController();
  final searchFocus = FocusNode(); // the search TextField
  // Holds keyboard focus when not searching so we can catch the first keystroke.
  final pageFocus = FocusNode();

  /// Called after [query] changes (open-with-seed, close, or edit) so the page
  /// can do adjacent work — e.g. re-filter a list or reset a paging window.
  void onQueryChanged() {}

  /// Open the search bar, optionally seeding it with the first typed character,
  /// and move keyboard focus into the field.
  void openSearch({String? seed}) {
    setState(() {
      searching = true;
      if (seed != null) {
        searchController.text = seed;
        searchController.selection =
            TextSelection.collapsed(offset: seed.length);
        query = seed;
      }
    });
    if (seed != null) onQueryChanged();
    searchFocus.requestFocus();
  }

  /// Clear the query and dismiss the search bar, returning focus to the page so
  /// the next keystroke can re-open it.
  void closeSearch() {
    setState(() {
      searching = false;
      query = '';
      searchController.clear();
    });
    onQueryChanged();
    pageFocus.requestFocus();
  }

  /// Update the live query from the search field's onChanged.
  void setQuery(String value) {
    setState(() => query = value);
    onQueryChanged();
  }

  // First keystroke handler: when not already searching, a printable character
  // (with no Ctrl/Alt/Meta held) opens the search bar seeded with that char.
  KeyEventResult onPageKey(FocusNode _, KeyEvent event) {
    if (searching || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final ch = event.character;
    // A single printable, non-control character (filters out Enter, Tab, etc.).
    if (ch == null || ch.length != 1 || ch.codeUnitAt(0) < 0x20) {
      return KeyEventResult.ignored;
    }
    openSearch(seed: ch);
    return KeyEventResult.handled;
  }

  /// Dispose the controller + focus nodes. Call from the State's dispose.
  void disposeSearch() {
    searchController.dispose();
    searchFocus.dispose();
    pageFocus.dispose();
  }
}
