import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v3.0.6 — the dashboard's selection action bar (Hide, Change Phase, Tags,
/// Create Release, Archive selected…) scrolls sideways in a narrow window
/// instead of running off its edge. Checked on the source: the bar lives
/// deep in the dashboard, which needs a full library to mount; the closest
/// automated check is that its buttons sit in a horizontal scroll view.
void main() {
  test('the selection action bar\'s buttons are in a horizontal scroll view',
      () {
    final source = File('lib/ui/dashboard_page.dart').readAsStringSync();
    final bar = source.indexOf('// Selection action bar');
    expect(bar, isNot(-1));
    final scroll = source.indexOf("ValueKey('selectionActionBarScroll')", bar);
    expect(scroll, isNot(-1));
    final region = source.substring(bar, scroll + 200);
    expect(region, contains('Flexible('));
    expect(region, contains('scrollDirection: Axis.horizontal'));
  });
}
