import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daw_project_manager/generated/l10n/app_localizations.dart';
import 'package:daw_project_manager/ui/dialogs/bulk_tags_dialog.dart';
import 'package:daw_project_manager/utils/localization_delegates.dart';

/// #109 — tagging many projects at once from the bulk-actions bar. The dialog
/// only reports what was picked; the dashboard does the writing.
void main() {
  late List<BulkTagChange?> results;

  setUp(() => results = []);

  Future<void> pump(
    WidgetTester tester, {
    int projectCount = 3,
    List<String> suggestions = const [],
    List<String> removable = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                results.add(await showBulkTagsDialog(
                  context,
                  projectCount: projectCount,
                  suggestions: suggestions,
                  removable: removable,
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('says how many projects it will tag', (tester) async {
    await pump(tester, projectCount: 3);

    expect(find.text('Tag 3 projects'), findsOneWidget);
  });

  testWidgets('typing a tag and pressing Enter asks to add it', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const ValueKey('tag-input')), 'trap');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(results.single!.tags, ['trap']);
    expect(results.single!.add, isTrue);
  });

  testWidgets('the × on a tag asks to remove it', (tester) async {
    await pump(tester, removable: ['trap', 'house']);

    await tester.tap(find.byTooltip('Remove tag "house"'));
    await tester.pumpAndSettle();

    expect(results.single!.tags, ['house']);
    expect(results.single!.add, isFalse);
  });

  testWidgets('says so when the selection has no tags to remove', (
    tester,
  ) async {
    await pump(tester);

    expect(
      find.text('None of the selected projects has a tag yet.'),
      findsOneWidget,
    );
  });

  testWidgets('cancel returns nothing', (tester) async {
    await pump(tester, removable: ['trap']);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(results, [null]);
  });

  testWidgets('ticking library tags and applying adds them all', (tester) async {
    await pump(tester, suggestions: ['Previous Version', 'Approved Master', 'Mix']);

    // Nothing ticked: nothing to apply.
    final apply = find.byKey(const ValueKey('bulk-add-apply'));
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('bulk-add-Previous Version')));
    await tester.tap(find.byKey(const ValueKey('bulk-add-Mix')));
    await tester.pumpAndSettle();
    await tester.tap(apply);
    await tester.pumpAndSettle();

    expect(results.single!.add, isTrue);
    expect(results.single!.tags, ['Previous Version', 'Mix']);
  });

  testWidgets('a typed tag is added together with the ticked ones', (tester) async {
    await pump(tester, suggestions: ['Mix']);

    await tester.tap(find.byKey(const ValueKey('bulk-add-Mix')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tag-input')), 'Brand new');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(results.single!.tags, ['Mix', 'Brand new']);
  });
}
