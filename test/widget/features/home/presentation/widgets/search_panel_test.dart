import 'package:zedu/core/core.dart';
import 'package:zedu/features/features.dart';

import '../../../../../helpers/helpers.dart';

class FakeSearchRemote implements SearchRemoteDataSource {
  FakeSearchRemote({this.hits, this.failure});

  final List<SearchResultModel>? hits;
  final ApiFailure? failure;

  @override
  Future<List<SearchResultModel>> searchMessages({
    required String orgId,
    required String query,
  }) async {
    final failure = this.failure;
    if (failure != null) throw failure;
    if (query.trim().isEmpty) return const [];
    return hits ?? const <SearchResultModel>[];
  }
}

Widget _scope(Widget child, SearchRemoteDataSource remote) {
  return ProviderScope(
    overrides: [
      currentOrgIdProvider.overrideWithValue('org-1'),
      searchRemoteDataSourceProvider.overrideWithValue(remote),
    ],
    child: buildTestMaterialApp(Scaffold(body: child)),
  );
}

SearchPanel _panel() => SearchPanel(onClose: () {});

void main() {
  testWidgets('disposes its search controller when removed', (tester) async {
    await tester.pumpWidget(
      ProviderScope(child: buildTestMaterialApp(Scaffold(body: _panel()))),
    );

    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    void listener() {}
    controller.addListener(listener);
    controller.removeListener(listener);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(() => controller.addListener(listener), throwsFlutterError);
  });

  testWidgets('renders backend hits instead of fabricated placeholders', (
    tester,
  ) async {
    final remote = FakeSearchRemote(
      hits: [
        const SearchResultModel(
          id: 'm1',
          content: 'shipping the release notes',
          channelId: 'c1',
          channelName: 'general',
          senderName: 'Ada Lovelace',
        ),
      ],
    );
    await tester.pumpWidget(_scope(_panel(), remote));
    await tester.enterText(find.byType(TextField), 'release');
    // Outlive the debounce timer and the fake fetch.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('shipping the release notes'), findsOneWidget);
    expect(find.textContaining('Ada Lovelace'), findsOneWidget);
    expect(find.textContaining('Found message matching'), findsNothing);
    expect(find.textContaining('Another result for'), findsNothing);
  });

  testWidgets('shows the failure instead of fake results', (tester) async {
    final remote = FakeSearchRemote(
      failure: const ApiFailure(message: 'workspace search is down'),
    );
    await tester.pumpWidget(_scope(_panel(), remote));
    await tester.enterText(find.byType(TextField), 'anything');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('workspace search is down'), findsOneWidget);
    expect(find.textContaining('Found message matching'), findsNothing);
  });

  testWidgets('empty query returns to the idle prompt', (tester) async {
    final remote = FakeSearchRemote();
    await tester.pumpWidget(_scope(_panel(), remote));
    await tester.enterText(find.byType(TextField), 'Hey');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Enter a search term'), findsOneWidget);
  });
}
