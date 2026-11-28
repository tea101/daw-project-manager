import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v3.0.6 — the File Type column is drawn like the columns beside it: plain
/// text in the grid's own cell style, no weight or letter spacing of its own
/// (it was semibold and spaced out, and read louder than every other
/// column). Checked on the source, since the renderer needs a mounted grid.
void main() {
  test('projectFileTypeColumn sets no font weight or spacing', () {
    final source =
        File('lib/ui/widgets/project_info_columns.dart').readAsStringSync();
    final start = source.indexOf('TrinaColumn projectFileTypeColumn(');
    expect(start, isNot(-1));
    final end = source.indexOf('\nTrinaColumn ', start + 1);
    final body = source.substring(start, end == -1 ? source.length : end);
    expect(body, isNot(contains('fontWeight')));
    expect(body, isNot(contains('letterSpacing')));
    expect(body, isNot(contains('TextStyle(')));
  });
}
