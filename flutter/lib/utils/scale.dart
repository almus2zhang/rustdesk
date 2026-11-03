import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:uuid/uuid.dart';

/// Clamp custom scale percent to supported bounds.
/// Keep this in sync with the slider's minimum in the desktop toolbar UI.
///
/// This function exists to ensure consistent clamping behavior across the app
/// and to provide a single point of reference for the valid scale range.
int clampCustomScalePercent(int percent) {
  return percent.clamp(kScaleCustomMinPercent, kScaleCustomMaxPercent);
}

/// Parse a string percent and clamp. Defaults to 100 when invalid.
int parseCustomScalePercent(String? s, {int defaultPercent = 100}) {
  final parsed = int.tryParse(s ?? '') ?? defaultPercent;
  return clampCustomScalePercent(parsed);
}

/// Convert a percent value to scale factor after clamping.
double percentToScale(int percent) => clampCustomScalePercent(percent) / 100.0;

/// Fetch, parse and clamp the custom scale percent for a session.
Future<int> getSessionCustomScalePercent(UuidValue sessionId, {String? peerId}) async {
  var opt = await bind.sessionGetFlutterOption(
      sessionId: sessionId, k: kCustomScalePercentKey);
  if ((opt == null || opt.isEmpty) && peerId != null && peerId.isNotEmpty) {
    opt = bind.mainGetPeerOptionSync(id: peerId, key: kCustomScalePercentKey);
    if (opt.isNotEmpty) {
      await bind.sessionSetFlutterOption(
          sessionId: sessionId, k: kCustomScalePercentKey, v: opt);
    }
  }
  return parseCustomScalePercent(opt);
}

/// Fetch and compute the custom scale factor for a session.
Future<double> getSessionCustomScale(UuidValue sessionId, {String? peerId}) async {
  final p = await getSessionCustomScalePercent(sessionId, peerId: peerId);
  return percentToScale(p);
}
