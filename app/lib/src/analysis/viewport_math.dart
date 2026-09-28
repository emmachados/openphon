import 'analysis_controller.dart';

/// Pixel-x of time [t] within a viewport painted at [width] px.
double timeToX(double t, TimeViewport vp, double width) =>
    (t - vp.t0) / vp.span * width;

/// Time at pixel-x [x] within a viewport painted at [width] px.
double xToTime(double x, TimeViewport vp, double width) =>
    vp.t0 + (x / width) * vp.span;
