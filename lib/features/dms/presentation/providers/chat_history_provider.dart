import 'dart:io' show File;

import 'package:zedu/core/core.dart';
import 'package:zedu/features/features.dart';

class ChatHistoryNotifier extends ChangeNotifier {
  final String channelId;
  final Ref ref;

  List<Map<String, dynamic>> messages = [];
  bool isLoading = true;
  bool hasMore = true;
  int page = 1;

  /// Messages created at or before this time were cleared with "Clear
  /// history" and stay hidden.
  DateTime? _clearedAt;

  bool get historyCleared => _clearedAt != null;

  /// Whether the first page of history failed to load.
  bool loadFailed = false;

  /// Whether the last request for older messages failed.
  bool loadMoreFailed = false;

  String? editingMessageId;
  final Map<String, Future<void>> _saveEditChains = {};

  /// Messages whose edit is still being sent. A poll that lands meanwhile must
  /// not put the old text back over the edit.
  final Set<String> _editsInFlight = {};

  ChatHistoryNotifier(this.channelId, this.ref) {
    _loadInitial();
  }

  /// Set when the provider is disposed (it is autoDispose, so leaving the
  /// conversation disposes it). Work still awaiting the repository checks it
  /// before touching [ref] or the state again.
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  String get _currentUserId {
    final authState = ref.read(authNotifierProvider);
    return authState.user?.id ?? '';
  }

  String get currentUserName {
    final user = ref.read(authNotifierProvider).user;
    if (user == null) return 'You';
    final name = '${user.firstName} ${user.lastName}'.trim();
    return name.isNotEmpty ? name : user.username;
  }

  String? get currentUserAvatarUrl {
    final user = ref.read(authNotifierProvider).user;
    if (user == null) return null;
    return user.avatarUrl.isNotEmpty ? user.avatarUrl : user.defaultAvatarUrl;
  }

  bool isMyMessage(Map<String, dynamic> message) {
    final senderId = message['user_id'] ?? message['userId'];
    return senderId == _currentUserId || senderId == 'me';
  }

  String? get lastSentMessageContent {
    for (final msg in messages) {
      if (isMyMessage(msg) && msg['status'] != 'failed') {
        return msg['content'] as String?;
      }
    }
    return null;
  }

  String? get lastSentMessageId {
    for (final msg in messages) {
      if (isMyMessage(msg) && msg['status'] != 'failed') {
        return msg['id'] as String?;
      }
    }
    return null;
  }

  Future<void> _loadInitial() async {
    await _loadFirstPage();
    if (_disposed) return;
    // Start polling for new messages now that the initial load is done.
    _startPolling();
  }

  Future<void> _loadFirstPage() async {
    try {
      _clearedAt = await ref
          .read(dmHistoryClearStoreProvider)
          .clearedAt(channelId);
    } catch (_) {}
    if (_disposed) return;
    try {
      final repository = ref.read(dmRepositoryProvider);
      final loaded = await repository.getMessages(channelId, page: 1);
      if (_disposed) return;
      final visible = loaded.where((m) => !_isCleared(m)).toList();
      // Keep messages sent (or failing to send) while the history was missing.
      final unsent = messages.where((m) => m['status'] != null);
      messages = [...unsent, ...visible];
      hasMore =
          loaded.length >= DmRepository.pageSize &&
          visible.length == loaded.length;
      page = 1;
      loadFailed = false;
      _markSeen(loaded);
      _lastPolledIds = {
        for (final m in loaded)
          if (m['id'] != null) m['id'].toString(),
      };
    } catch (_) {
      loadFailed = true;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Loads the first page again after it failed.
  Future<void> retryLoad() async {
    if (isLoading) return;
    isLoading = true;
    loadFailed = false;
    notifyListeners();
    await _loadFirstPage();
  }

  // ── Realtime notification polling ────────────────────────────────────────────

  /// Set of message IDs we have already seen. Used to detect truly-new messages
  /// so we don't re-fire a notification on every poll cycle.
  final Set<String> _seenIds = {};

  /// The message ids the last poll (or the first load) listed. A message that
  /// was listed then and is missing now was deleted by someone else.
  Set<String> _lastPolledIds = {};

  /// Keep track of the polling timer so we can cancel it on dispose.
  // ignore: cancel_subscriptions
  dynamic _pollingTimer;

  // Record loaded IDs as "already seen" so we only notify about messages that
  // arrive AFTER they were loaded.
  void _markSeen(List<Map<String, dynamic>> loaded) {
    for (final m in loaded) {
      final id = m['id']?.toString();
      if (id != null) _seenIds.add(id);
    }
  }

  void _startPolling() {
    // Poll every 10 seconds for new messages.
    _pollingTimer = Stream<int>.periodic(const Duration(seconds: 10), (i) => i)
        .listen((_) {
          _pollForNewMessages();
        });
  }

  Future<void> _pollForNewMessages() async {
    // Until the history loads, every polled message would look new.
    if (loadFailed) return;
    try {
      final repository = ref.read(dmRepositoryProvider);
      final fresh = await repository.getMessages(channelId, page: 1);
      // Reading the user and the notification service needs a live ref.
      if (_disposed) return;

      // A message edited elsewhere keeps its id, so it is not "new": replace
      // its text in place, without a notification or a second copy.
      final changed =
          _removeDeletedElsewhere(fresh) | _applyEditedContent(fresh);

      bool hadNew = false;
      for (final msg in fresh) {
        final id = msg['id']?.toString();
        if (id == null || _seenIds.contains(id) || _isCleared(msg)) continue;

        _seenIds.add(id);
        hadNew = true;

        // Only notify for messages from other users.
        if (!isMyMessage(msg)) {
          final senderName =
              (msg['sender_name'] ?? msg['username'] ?? 'Someone').toString();
          ref
              .read(notificationServiceProvider)
              .handleIncomingMessage(msg, channelId, senderName);
        }
      }

      if (hadNew) {
        // Prepend only the genuinely new messages at the top.
        // A message just sent keeps its local id and stores the server's id as
        // thread_id, so match on both or the poll adds a second copy of it.
        final existingIds = <String?>{
          for (final m in messages) ...[
            m['id']?.toString(),
            if (m['thread_id'] != null) m['thread_id'].toString(),
          ],
        };
        final newOnly = fresh
            .where(
              (m) =>
                  !existingIds.contains(m['id']?.toString()) &&
                  !_isDeleted(m) &&
                  !_isCleared(m),
            )
            .toList();
        if (newOnly.isNotEmpty) {
          messages = [...newOnly, ...messages];
          notifyListeners();
          return;
        }
      }
      if (changed) notifyListeners();
    } catch (_) {
      // Silent — polling failures should not surface to the UI.
    }
  }

  /// Drops the loaded messages that someone else deleted, and returns whether
  /// any were. The poll only sees the newest page, and a deleted message is
  /// simply missing from it, so a message counts as deleted only when it is
  /// inside that newest window, the last poll listed it, and this one does
  /// not. An empty answer proves nothing and removes nothing, and neither does
  /// a message still sending, failed, or being edited here.
  bool _removeDeletedElsewhere(List<Map<String, dynamic>> fresh) {
    final freshIds = {
      for (final m in fresh)
        if (m['id'] != null) m['id'].toString(),
    };
    final previousIds = _lastPolledIds;
    if (fresh.isEmpty) return false;
    _lastPolledIds = freshIds;

    // Where the newest page ends in the list: older messages are not judged.
    final windowEnd = messages.indexWhere(
      (m) => m['id']?.toString() == fresh.last['id']?.toString(),
    );
    if (windowEnd < 0) return false;

    final kept = <Map<String, dynamic>>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final id = m['id']?.toString();
      final deleted =
          i <= windowEnd &&
          id != null &&
          previousIds.contains(id) &&
          !freshIds.contains(id) &&
          m['status'] == null &&
          !_editsInFlight.contains(id) &&
          editingMessageId != id;
      if (!deleted) kept.add(m);
    }
    if (kept.length == messages.length) return false;
    messages = kept;
    return true;
  }

  /// Puts the server's text and attachments on every loaded message that was
  /// changed elsewhere since it was loaded. Skips messages being edited here
  /// and messages still sending or failed, which the server has not seen, and
  /// returns whether anything changed.
  bool _applyEditedContent(List<Map<String, dynamic>> fresh) {
    final latest = <String, Map<String, dynamic>>{
      for (final m in fresh)
        if (m['id'] != null && !_isDeleted(m)) m['id'].toString(): m,
    };
    var changed = false;
    messages = messages.map((m) {
      final id = m['id']?.toString();
      if (id == null || !latest.containsKey(id)) return m;
      if (_editsInFlight.contains(id) || editingMessageId == id) return m;
      if (m['status'] != null) return m;
      final server = latest[id]!;
      final content = server['content'];
      final media = server['media'];
      final contentChanged = content != null && content != m['content'];
      // A message edited elsewhere can come back with other attachments, so
      // the file name and link shown must follow the server's.
      final mediaChanged = media is List && !_sameMedia(media, m['media']);
      if (!contentChanged && !mediaChanged) return m;
      changed = true;
      final updated = Map<String, dynamic>.from(m);
      if (contentChanged) updated['content'] = content;
      if (mediaChanged) updated['media'] = media;
      return updated;
    }).toList();
    return changed;
  }

  bool _sameMedia(List<dynamic> server, Object? local) {
    if (local is! List || local.length != server.length) return false;
    for (var i = 0; i < server.length; i++) {
      if (server[i].toString() != local[i].toString()) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    (_pollingTimer as dynamic)?.cancel();
    // Recordings kept for messages that never sent are no longer needed.
    for (final options in _sendOptions.values) {
      _deleteRecordings(options.media);
    }
    _sendOptions.clear();
    super.dispose();
  }

  Future<void> loadMore() async {
    if (isLoading || !hasMore || loadFailed) return;

    isLoading = true;
    loadMoreFailed = false;
    notifyListeners();

    try {
      final repository = ref.read(dmRepositoryProvider);
      final nextPage = page + 1;
      final newMessages = await repository.getMessages(
        channelId,
        page: nextPage,
      );
      if (_disposed) return;

      // A message that arrived since the list was loaded pushes everything
      // down, so the next page can start with a message already shown. Only
      // the ones not shown yet are added.
      final shownIds = <String>{
        for (final m in messages) ...[
          if (m['id'] != null) m['id'].toString(),
          if (m['thread_id'] != null) m['thread_id'].toString(),
        ],
      };
      final older = newMessages
          .where(
            (m) =>
                !_isDeleted(m) &&
                !_isCleared(m) &&
                !shownIds.contains(m['id']?.toString()),
          )
          .toList();
      for (final m in older) {
        final id = m['id']?.toString();
        if (id != null) _seenIds.add(id);
      }
      messages = [...messages, ...older];
      // Pages run newest first, so once a cleared message shows up every
      // older page is cleared too.
      hasMore =
          newMessages.length >= DmRepository.pageSize &&
          !newMessages.any(_isCleared);
      page = nextPage;
    } catch (e, s) {
      AppLogger.e(
        'Failed to load older messages for channel $channelId',
        tag: 'ChatHistoryNotifier',
        error: e,
        stackTrace: s,
      );
      loadMoreFailed = true;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Loads every remaining page, for views that need the whole conversation
  /// (such as its files). Waits for a load already in flight, and stops after
  /// [maxPages] pages or when a page fails, so it can't loop forever.
  Future<void> loadAll({int maxPages = 50}) async {
    for (var i = 0; i < maxPages && hasMore && !_disposed; i++) {
      while (isLoading && !_disposed) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_disposed || !hasMore) break;
      final before = page;
      await loadMore();
      if (page == before) break; // the page failed to load
    }
  }

  // What each message was sent with, so a retry sends it the same way.
  final Map<
    String,
    ({List<XFile>? media, List<dynamic>? mentions, bool isChannel})
  >
  _sendOptions = {};

  /// Makes each optimistic message id unique, even for sends in the same
  /// millisecond: the id keys [_sendOptions] and the message's later update.
  int _tempIdCounter = 0;

  /// Deletes voice recordings this app made once their message is sent. Files
  /// the user picked are never deleted.
  Future<void> _deleteRecordings(List<XFile>? files) async {
    for (final file in files ?? const <XFile>[]) {
      if (appRecordedPaths.remove(file.path)) {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
    }
  }

  Future<void> sendMessage(
    String content, {
    List<XFile>? media,
    List<dynamic>? mentions,
    bool isChannel = false,
  }) async {
    final tempId =
        'local-${DateTime.now().millisecondsSinceEpoch}-${_tempIdCounter++}';
    final optimisticMessage = {
      "id": tempId,
      "content": content,
      "channel_id": channelId,
      "user_id": _currentUserId,
      "userId": _currentUserId,
      "sender_name": currentUserName,
      "avatar_url": currentUserAvatarUrl,
      "type": "user",
      "created_at": DateTime.now().toIso8601String(),
      "status": "sending",
      "is_channel": isChannel,
      if (media != null && media.isNotEmpty)
        "media": [
          for (final file in media) {"file_name": file.name},
        ],
    };

    _sendOptions[tempId] = (
      media: media,
      mentions: mentions,
      isChannel: isChannel,
    );
    messages = [optimisticMessage, ...messages];
    notifyListeners();

    try {
      final repository = ref.read(dmRepositoryProvider);
      final threadId = await repository.sendMessage(
        channelId,
        content,
        media: media,
        mentions: mentions,
        isChannel: isChannel,
      );
      _sendOptions.remove(tempId);
      _deleteRecordings(media);
      if (_disposed) return;

      messages = messages.map((m) {
        if (m['id'] == tempId) {
          final newMsg = Map<String, dynamic>.from(m);
          newMsg.remove('status');
          newMsg['thread_id'] = threadId;
          return newMsg;
        }
        return m;
      }).toList();
    } catch (_) {
      if (_disposed) return;
      messages = messages.map((m) {
        if (m['id'] == tempId) {
          final newMsg = Map<String, dynamic>.from(m);
          newMsg['status'] = 'failed';
          return newMsg;
        }
        return m;
      }).toList();
    } finally {
      notifyListeners();
    }
  }

  Future<void> retryMessage(String messageId) async {
    final idx = messages.indexWhere((m) => m['id'] == messageId);
    if (idx == -1) return;

    final failedMsg = Map<String, dynamic>.from(messages[idx]);
    final content = failedMsg['content'] as String? ?? '';

    failedMsg['status'] = 'sending';
    messages = List<Map<String, dynamic>>.from(messages);
    messages[idx] = failedMsg;
    notifyListeners();

    try {
      final repository = ref.read(dmRepositoryProvider);
      final options = _sendOptions[messageId];
      final threadId = await repository.sendMessage(
        channelId,
        content,
        media: options?.media,
        mentions: options?.mentions,
        isChannel:
            failedMsg['is_channel'] as bool? ?? options?.isChannel ?? false,
      );
      _sendOptions.remove(messageId);
      _deleteRecordings(options?.media);
      if (_disposed) return;

      messages = messages.map((m) {
        if (m['id'] == messageId) {
          final newMsg = Map<String, dynamic>.from(m);
          newMsg.remove('status');
          newMsg['thread_id'] = threadId;
          return newMsg;
        }
        return m;
      }).toList();
    } catch (_) {
      if (_disposed) return;
      messages = messages.map((m) {
        if (m['id'] == messageId) {
          final newMsg = Map<String, dynamic>.from(m);
          newMsg['status'] = 'failed';
          return newMsg;
        }
        return m;
      }).toList();
    } finally {
      notifyListeners();
    }
  }

  static DateTime? _createdAt(Map<String, dynamic> message) =>
      DateTime.tryParse(message['created_at']?.toString() ?? '');

  bool _isCleared(Map<String, dynamic> message) {
    final clearedAt = _clearedAt;
    if (clearedAt == null) return false;
    final createdAt = _createdAt(message);
    return createdAt != null && !createdAt.isAfter(clearedAt);
  }

  /// Hides every message up to now in this conversation, on this device, and
  /// remembers it so they stay hidden after the DM is reopened.
  Future<void> clearLocalHistory() async {
    // Cut off at the newest loaded message rather than this device's clock,
    // so a clock running ahead can't hide messages sent after the clear.
    DateTime? newest;
    for (final message in messages) {
      final createdAt = _createdAt(message);
      if (createdAt != null && (newest == null || createdAt.isAfter(newest))) {
        newest = createdAt;
      }
    }
    final clearedAt = newest ?? DateTime.now();
    _clearedAt = clearedAt;
    messages = [];
    hasMore = false;
    page = 1;
    notifyListeners();

    try {
      await ref
          .read(dmHistoryClearStoreProvider)
          .markCleared(channelId, clearedAt);
    } catch (_) {
      // The messages stay hidden for this session even if saving fails.
    }
  }

  void startEditing(String messageId) {
    final msg = messages.firstWhere(
      (m) => m['id'] == messageId,
      orElse: () => <String, dynamic>{},
    );
    if (msg.isEmpty) return;

    editingMessageId = messageId;
    notifyListeners();
  }

  void cancelEditing() {
    editingMessageId = null;
    notifyListeners();
  }

  /// Ids of messages being deleted or already deleted, so polling and paging
  /// do not bring them back.
  final Set<String> _deletedIds = {};

  bool _isDeleted(Map<String, dynamic> message) =>
      _deletedIds.contains(message['id']?.toString());

  /// Removes the message right away and puts it back if the request fails.
  Future<void> deleteMessage(String messageId) async {
    final index = messages.indexWhere((m) => m['id'] == messageId);
    if (index == -1) return;

    final removed = messages[index];
    final threadId = (removed['thread_id'] ?? removed['id']).toString();
    if (editingMessageId == messageId) editingMessageId = null;
    _deletedIds.add(messageId);
    messages = [...messages]..removeAt(index);
    notifyListeners();

    try {
      final repository = ref.read(dmRepositoryProvider);
      await repository.deleteMessage(threadId: threadId, channelId: channelId);
    } catch (_) {
      if (_disposed) return;
      _deletedIds.remove(messageId);
      messages = [...messages]
        ..insert(index.clamp(0, messages.length), removed);
      notifyListeners();
    }
  }

  /// Saves an edit. Completes with false when the request failed, in which
  /// case the message already shows its previous text again.
  Future<bool> saveEdit(String messageId, String newContent) {
    final previous = _saveEditChains[messageId] ?? Future<void>.value();
    final task = previous.then((_) => _runSaveEdit(messageId, newContent));
    _saveEditChains[messageId] = task.then<void>((_) {}).catchError((_) {});
    return task;
  }

  Future<bool> _runSaveEdit(String messageId, String newContent) async {
    if (newContent.trim().isEmpty) {
      cancelEditing();
      return true;
    }

    final original = messages.firstWhere(
      (m) => m['id'] == messageId,
      orElse: () => <String, dynamic>{},
    );
    final baselineContent = original['content'] as String?;
    // The backend requires thread_id to know which message is being edited.
    final threadId = (original['thread_id'] ?? original['id'])?.toString();

    messages = messages.map((m) {
      if (m['id'] == messageId) {
        final updated = Map<String, dynamic>.from(m);
        updated['content'] = newContent;
        return updated;
      }
      return m;
    }).toList();
    if (editingMessageId == messageId) {
      editingMessageId = null;
    }
    notifyListeners();

    _editsInFlight.add(messageId);
    try {
      final repository = ref.read(dmRepositoryProvider);
      await repository.editMessage(
        channelId,
        content: newContent,
        threadId: threadId,
      );
      return true;
    } catch (_) {
      if (_disposed) return false;
      messages = messages.map((m) {
        if (m['id'] == messageId && m['content'] == newContent) {
          final reverted = Map<String, dynamic>.from(m);
          reverted['content'] = baselineContent;
          return reverted;
        }
        return m;
      }).toList();
      notifyListeners();
      return false;
    } finally {
      _editsInFlight.remove(messageId);
    }
  }
}

final chatHistoryProvider = ChangeNotifierProvider.autoDispose
    .family<ChatHistoryNotifier, String>(
      (ref, channelId) => ChatHistoryNotifier(channelId, ref),
    );
