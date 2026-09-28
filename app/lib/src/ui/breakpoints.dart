import 'package:flutter/widgets.dart';

/// Material 3 window class boundary between compact (phone) and
/// expanded (tablet/desktop) layouts. All adaptive decisions in the app go
/// through this one predicate so the breakpoint is defined exactly once.
const double kExpandedMinWidth = 840;

bool isExpanded(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kExpandedMinWidth;
