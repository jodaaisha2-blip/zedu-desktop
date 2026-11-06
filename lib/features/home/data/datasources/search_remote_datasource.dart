import 'dart:async';

import 'package:zedu/core/core.dart';

import '../models/search_result_model.dart';

/// Performs organisation-wide message search on the backend.
abstract class SearchRemoteDataSource {
  /// Flattened message hits for [query] inside the organisation [orgId],
  /// ordered as the backend returns them.
  Future<List<SearchResultModel>> searchMessages({
    required String orgId,
    required String query,
  });
}

class SearchRemoteDataSourceImpl implements SearchRemoteDataSource {
  final ApiBaseService apiBaseService;

  SearchRemoteDataSourceImpl({required this.apiBaseService});

  @override
  Future<List<SearchResultModel>> searchMessages({
    required String orgId,
    required String query,
  }) async {
    final response = await apiBaseService.get<Map<String, dynamic>>(
      path: '/search/organisation/$orgId',
      queryParameters: {'query': query},
    );
    final groups = response.data['data'] as List?;
    if (groups == null) return [];
    return flattenSearchGroups(groups);
  }

  /// The backend returns `{user, channel, messages}` groups; the panel wants
  /// one hit per message bearing that group's sender and channel.
  static List<SearchResultModel> flattenSearchGroups(List groups) {
    final hits = <SearchResultModel>[];
    for (final group in groups) {
      if (group is! Map<String, dynamic>) continue;
      final user = asMap(group['user']);
      final channel = asMap(group['channel']);
      final messages = group['messages'];
      if (messages is! List) continue;
      for (final message in messages) {
        if (message is! Map<String, dynamic>) continue;
        hits.add(
          SearchResultModel.fromJson({
            ...message,
            'user_name': user['user_name'],
            'avatar_url': user['avatar_url'],
            'channel_id': channel['channel_id'],
            'channel_name': channel['channel_name'],
          }),
        );
      }
    }
    return hits;
  }
}

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  return {};
}

/// Default data-source backed by the shared API client.
final searchRemoteDataSourceProvider = Provider<SearchRemoteDataSource>(
  (ref) =>
      SearchRemoteDataSourceImpl(apiBaseService: locator<ApiBaseService>()),
);
