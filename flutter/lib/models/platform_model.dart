import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/consts.dart';
import 'native_model.dart' if (dart.library.html) 'web_model.dart';
import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';

final platformFFI = PlatformFFI.instance;
final localeName = PlatformFFI.localeName;

RustdeskImpl get bind => platformFFI.ffiBind;

String ffiGetByName(String name, [String arg = '']) {
  return PlatformFFI.getByName(name, arg);
}

void ffiSetByName(String name, [String value = '']) {
  PlatformFFI.setByName(name, value);
}

bool isTabletLayoutMode([BuildContext? context]) {
  final opt = bind.mainGetLocalOption(key: kOptionMobileKeyboardLayoutMode);
  if (opt == 'phone') return false;
  if (opt == 'tablet') return true;
  try {
    if (context != null) {
      final media = MediaQuery.of(context);
      if ((media.size.width * media.devicePixelRatio) >= 2560) return true;
      return media.size.shortestSide >= 600;
    }
    final media = MediaQueryData.fromView(ui.window);
    if ((media.size.width * media.devicePixelRatio) >= 2560) return true;
    return media.size.shortestSide >= 600;
  } catch (_) {
    return false;
  }
}

