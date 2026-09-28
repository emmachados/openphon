import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/ui/analysis/analysis_view.dart';

void main() {
  test('selection edge slop widens for fingers only', () {
    expect(selectionEdgeSlopFor(PointerDeviceKind.touch), 24.0);
    expect(selectionEdgeSlopFor(PointerDeviceKind.mouse), 12.0);
    expect(selectionEdgeSlopFor(PointerDeviceKind.stylus), 12.0);
    expect(selectionEdgeSlopFor(null), 12.0);
  });
}
