import 'dart:async';

import 'package:zedu/core/core.dart';
import 'package:zedu/features/features.dart';

/// Phases of the global search panel content.
enum SearchStatus { idle, loading, ready, error }

/// What the search panel renders for the latest query.
class SearchState {
  const SearchState.idle()
    : status = SearchStatus.idle,
      results = const [],
      error = null;

  const SearchState.loading()
    : status = SearchStatus.loading,
      results = const [],
      error = null;

  const SearchState.ready(this.results)
    : status = SearchStatus.ready,
      error = null;

  const SearchState.error(this.error)
    : status = SearchStatus.error,
      results = const [];

  final SearchStatus status;
  final List<SearchResultModel> results;
  final ApiFailure? error;
}

/// Debounced controller that queries the organisation search endpoint.
class SearchController extends Notifier<SearchState> {
  Timer? _debounce;

  @override
  SearchState build() {
    ref.onDispose(_cancelDebounce);
    return const SearchState.idle();
  }

  void _cancelDebounce() {
    _debounce?.cancel();
    _debounce = null;
  }

  /// Schedules a search for the given text, coalescing bursts of keystrokes.
  void submit(String query) {
    _debounce?.cancel();
    final text = query.trim();

    if (text.isEmpty) {
      state = const SearchState.idle();
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 500), () {
      state = const SearchState.loading();
      _runSearch(text);
    });
  }

  Future<void> _runSearch(String text) async {
    final orgId = ref.read(currentOrgIdProvider);
    final remote = ref.read(searchRemoteDataSourceProvider);

    try {
      final hits = await remote.searchMessages(orgId: orgId, query: text);
      // Ignore an older request finishing after a newer one.
      if (state.status == SearchStatus.loading) {
        state = SearchState.ready(hits);
      }
    } on ApiFailure catch (failure) {
      if (state.status == SearchStatus.loading) {
        state = SearchState.error(failure);
      }
    } catch (unexpected) {
      if (state.status == SearchStatus.loading) {
        state = SearchState.error(ApiFailure(message: unexpected.toString()));
      }
    }
  }
}

final searchControllerProvider =
    NotifierProvider<SearchController, SearchState>(SearchController.new);
