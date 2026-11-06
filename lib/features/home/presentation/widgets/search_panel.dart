import 'package:zedu/core/core.dart';
import 'package:zedu/features/features.dart';

class SearchPanel extends ConsumerStatefulWidget {
  final VoidCallback onClose;

  const SearchPanel({super.key, required this.onClose});

  @override
  ConsumerState<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends ConsumerState<SearchPanel> {
  final TextEditingController _searchController = TextEditingController();
  bool _submitted = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    _submitted = false;
    ref.read(searchControllerProvider.notifier).submit(text);
  }

  /// Renders one backend hit at the message level.
  String _formatTimestamp(DateTime? createdAt) {
    if (createdAt == null) return '';
    final now = DateTime.now();
    final local = createdAt.toLocal();
    final difference = now.difference(local);
    if (difference < const Duration(minutes: 1)) return 'just now';
    if (difference < const Duration(hours: 1)) {
      return '${difference.inMinutes}m ago';
    }
    if (difference < const Duration(hours: 24)) {
      return '${difference.inHours}h ago';
    }
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return 'today';
    }
    final months = const [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[local.month - 1]} ${local.day}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final search = ref.watch(searchControllerProvider);

    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(left: BorderSide(color: colors.divider)),
      ),
      child: Column(
        children: [
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.divider)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Search',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onClose,
                  icon: Icon(Icons.close, color: colors.textHint),
                  splashRadius: 20,
                  tooltip: 'Close search',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search messages...',
                hintStyle: TextStyle(color: colors.textHint),
                prefixIcon: Icon(Icons.search, color: colors.textHint),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.primary),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
              onChanged: _onTextChanged,
              onSubmitted: (text) {
                _submitted = true;
                ref.read(searchControllerProvider.notifier).submit(text);
              },
            ),
          ),
          Expanded(child: _buildBody(search, colors)),
        ],
      ),
    );
  }

  Widget _buildBody(SearchState search, AppPalette colors) {
    if (search.results.isEmpty &&
        _searchController.text.isNotEmpty &&
        _submitted) {
      return Center(
        child: Text(
          'No results found',
          style: TextStyle(color: colors.textHint),
        ),
      );
    }

    switch (search.status) {
      case SearchStatus.idle:
        return Center(
          child: Text(
            _searchController.text.isEmpty
                ? 'Enter a search term'
                : 'No results found',
            style: TextStyle(color: colors.textHint),
          ),
        );
      case SearchStatus.loading:
        return Center(child: CircularProgressIndicator(color: colors.primary));
      case SearchStatus.error:
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: colors.error, size: 32),
              const SizedBox(height: 12),
              Text(
                search.error?.message ?? 'Search failed. Try again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.error, fontSize: 13),
              ),
            ],
          ),
        );
      case SearchStatus.ready:
        final results = search.results;
        if (results.isEmpty) {
          return Center(
            child: Text(
              'No results found',
              style: TextStyle(color: colors.textHint),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: results.length,
          separatorBuilder: (context, index) => Divider(color: colors.divider),
          itemBuilder: (context, index) {
            final hit = results[index];
            return MessageBubble(
              author: hit.senderName.isEmpty ? 'Unknown user' : hit.senderName,
              text: hit.content,
              timestamp: _formatTimestamp(hit.createdAt),
            );
          },
        );
    }
  }
}
