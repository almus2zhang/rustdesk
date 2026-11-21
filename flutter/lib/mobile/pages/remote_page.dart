import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse_widgets.dart';
import 'package:flutter_hbb/mobile/widgets/gesture_help.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/remote_input.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../utils/image.dart';
import '../widgets/dialog.dart';
import '../widgets/custom_scale_widget.dart';

final initText = '1' * 1024;

// Workaround for Android (default input method, Microsoft SwiftKey keyboard) when using physical keyboard.
// When connecting a physical keyboard, `KeyEvent.physicalKey.usbHidUsage` are wrong is using Microsoft SwiftKey keyboard.
// https://github.com/flutter/flutter/issues/159384
// https://github.com/flutter/flutter/issues/159383
void _disableAndroidSoftKeyboard({bool? isKeyboardVisible}) {
  if (isAndroid) {
    if (isKeyboardVisible != true) {
      // `enable_soft_keyboard` will be set to `true` when clicking the keyboard icon, in `openKeyboard()`.
      gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }
}

final RxBool _autoPopupKeyboardOnText = false.obs;
final RxString _keyboardPopupMode = 'tap'.obs;
final RxDouble _keyboardCursorMargin = 30.0.obs;
final RxString _keyboardDismissMode = 'any'.obs;
final RxInt _keyboardPopupDelayMs = 200.obs;

class RemotePage extends StatefulWidget {
  RemotePage(
      {Key? key,
      required this.id,
      this.password,
      this.isSharedPassword,
      this.forceRelay,
      this.isUsbDisplay = false,
      this.isSecondaryDisplay = false,
      this.isMobileMode = false})
      : super(key: key);

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final bool isUsbDisplay;
  final bool isSecondaryDisplay;
  final bool isMobileMode;

  @override
  State<RemotePage> createState() => _RemotePageState(id);
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  bool get isSecondary =>
      widget.isUsbDisplay || widget.isSecondaryDisplay || widget.isMobileMode;

  void _sendPhysicalResolutionToServer(
      {bool forcePhysical = false, String? forcedOrientation}) {
    _secondaryDisplayRequested = true;
    sendPhysicalResolutionToServer(
      peerId: widget.id,
      sessionId: gFFI.sessionId,
      forcePhysical: forcePhysical,
      forcedOrientation: forcedOrientation,
    );
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (isSecondary) {
      final orientation = MediaQuery.maybeOf(context)?.orientation;
      if (orientation != null && orientation != _currentOrientation) {
        _currentOrientation = orientation;
        _isControlBarVertical.value = orientation == Orientation.landscape;
        final savedOrientation = bind.mainGetPeerOptionSync(
            id: widget.id, key: 'custom-display-orientation');
        if (savedOrientation.isEmpty || savedOrientation == 'auto') {
          _sendPhysicalResolutionToServer();
        }
      }
    }
    if (_showEdit || keyboardVisibilityController.isVisible) {
      Timer(const Duration(milliseconds: 50), () {
        if (mounted) _adjustCanvasForTextCursor();
      });
    }
  }

  Timer? _timer;
  final RxBool _showBar = false.obs;
  final RxBool _keyHelpCollapsed =
      (bind.mainGetLocalOption(key: 'key_help_tools_collapsed') == 'Y').obs;
  final RxBool _isControlBarVertical = false.obs;
  bool _isControlBarVerticalInit = false;
  Timer? _collapseLongPressTimer;
  bool _isCollapseLongPressed = false;
  bool _showGestureHelp = false;

  int? _anchorPointerId;
  final RxBool _isAnchorActive = false.obs;
  int? _actionPointerId;
  Offset _actionDownPos = Offset.zero;
  DateTime _actionDownTime = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _actionLastPos = Offset.zero;
  bool _actionHasMoved = false;
  double _actionScrollAccX = 0.0;
  double _actionScrollAccY = 0.0;

  Rect _getLeftAnchorZoneRect(Size size) {
    final bottom = gFFI.ffiModel.anchorZoneBottom.value;
    final height = gFFI.ffiModel.anchorZoneHeight.value;
    final width = gFFI.ffiModel.anchorZoneWidth.value;

    final clampedHeight = height.clamp(40.0, size.height * 0.6);
    final clampedWidth = width.clamp(40.0, size.width * 0.5);
    final clampedBottom = bottom.clamp(0.0, size.height - clampedHeight);
    final top = size.height - clampedBottom - clampedHeight;

    return Rect.fromLTWH(0, top, clampedWidth, clampedHeight);
  }

  Widget _buildAnchorZoneAdjustOverlay(Size size) {
    return Obx(() {
      if (!gFFI.ffiModel.isAdjustingAnchorZone.value) {
        return const SizedBox.shrink();
      }
      final anchorRect = _getLeftAnchorZoneRect(size);
      final bottom = gFFI.ffiModel.anchorZoneBottom.value;
      final height = gFFI.ffiModel.anchorZoneHeight.value;
      final width = gFFI.ffiModel.anchorZoneWidth.value;

      return Positioned.fill(
        child: Stack(
          children: [
            // Dark dim background to highlight the adjustment zone
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(
                  color: const Color(0x33000000),
                ),
              ),
            ),

            // Top control bar - [完成保存] is placed FIRST so it's always visible even on narrow screens
            Positioned(
              top: 40,
              left: 10,
              right: 10,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xE6212121),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x4D000000),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                    border:
                        Border.all(color: const Color(0x40FFFFFF), width: 1),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // 1. Save & Done button placed first!
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00C853),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.check, size: 18),
                        label: Text(
                          localeName.startsWith('zh') ? '完成保存' : 'Save & Done',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        onPressed: () {
                          gFFI.ffiModel.saveAnchorZoneOptions();
                          gFFI.ffiModel.isAdjustingAnchorZone.value = false;
                          BotToast.showText(
                            text: localeName.startsWith('zh')
                                ? '手势区位置已保存'
                                : 'Zone position saved',
                          );
                        },
                      ),

                      // 2. Reset button
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white70,
                          backgroundColor: const Color(0x33FFFFFF),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.restore, size: 16),
                        label: Text(
                          localeName.startsWith('zh')
                              ? '重置(80-180)'
                              : 'Reset(80-180)',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () {
                          gFFI.ffiModel.resetAnchorZoneOptions();
                          BotToast.showText(
                            text: localeName.startsWith('zh')
                                ? '已重置为默认值 (距底80-180, 宽100)'
                                : 'Reset to default (80-180, W:100)',
                          );
                        },
                      ),

                      // 3. Status text info
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0x22FFFFFF),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.tune,
                                color: Colors.amberAccent, size: 16),
                            const SizedBox(width: 4),
                            Text(
                              localeName.startsWith('zh')
                                  ? '距底: ${bottom.toInt()}  ${width.toInt()}x${height.toInt()}'
                                  : 'Bottom: ${bottom.toInt()}  ${width.toInt()}x${height.toInt()}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Quick Done floating button pinned right above the anchor box
            Positioned(
              left: anchorRect.left,
              top: (anchorRect.top - 36.0 > 10.0)
                  ? (anchorRect.top - 36.0)
                  : (anchorRect.bottom + 8.0),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00C853),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  elevation: 4,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.check, size: 16),
                label: Text(
                  localeName.startsWith('zh') ? '完成' : 'Done',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold),
                ),
                onPressed: () {
                  gFFI.ffiModel.saveAnchorZoneOptions();
                  gFFI.ffiModel.isAdjustingAnchorZone.value = false;
                  BotToast.showText(
                    text: localeName.startsWith('zh')
                        ? '手势区位置已保存'
                        : 'Zone position saved',
                  );
                },
              ),
            ),

            // The draggable & resizable anchor box
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) {
                  final newBottom =
                      (gFFI.ffiModel.anchorZoneBottom.value - details.delta.dy)
                          .clamp(0.0, size.height - height);
                  gFFI.ffiModel.anchorZoneBottom.value = newBottom;
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0x660071FF),
                    borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(12)),
                    border: Border.all(color: Colors.amberAccent, width: 2.5),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      // Center drag label
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.open_with,
                                color: Colors.white, size: 22),
                            const SizedBox(height: 2),
                            Text(
                              localeName.startsWith('zh')
                                  ? '按住上下拖动'
                                  : 'Drag Vertically',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '距底: ${bottom.toInt()}px',
                              style: const TextStyle(
                                color: Colors.amberAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Top-Right resize handle
                      Positioned(
                        top: 0,
                        right: 0,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (details) {
                            final newWidth =
                                (gFFI.ffiModel.anchorZoneWidth.value +
                                        details.delta.dx)
                                    .clamp(50.0, 300.0);
                            final newHeight =
                                (gFFI.ffiModel.anchorZoneHeight.value -
                                        details.delta.dy)
                                    .clamp(50.0, 300.0);
                            gFFI.ffiModel.anchorZoneWidth.value = newWidth;
                            gFFI.ffiModel.anchorZoneHeight.value = newHeight;
                          },
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              color: Colors.amberAccent,
                              borderRadius: BorderRadius.only(
                                topRight: Radius.circular(10),
                                bottomLeft: Radius.circular(8),
                              ),
                            ),
                            child: const Icon(
                              Icons.aspect_ratio,
                              color: Colors.black87,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  void _resetLeftAnchorState() {
    _anchorPointerId = null;
    _actionPointerId = null;
    _isAnchorActive.value = false;
    _actionHasMoved = false;
    _actionScrollAccX = 0.0;
    _actionScrollAccY = 0.0;
  }

  Offset? _pointerDownPos;
  DateTime? _pointerDownTime;
  bool _pointerMoved = false;
  bool _pointerIsDown = false;
  bool _pendingTapForText = false;
  Timer? _pendingTapTimer;

  void _toggleControlBarOrientation() {
    _isControlBarVertical.value = !_isControlBarVertical.value;
    BotToast.showText(
      text: localeName.startsWith('zh')
          ? (_isControlBarVertical.value ? '控制栏已切换为纵向' : '控制栏已切换为横向')
          : (_isControlBarVertical.value
              ? 'Control bar: Vertical'
              : 'Control bar: Horizontal'),
    );
    if (mounted) setState(() {});
  }

  String _value = '';
  Orientation? _currentOrientation;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;

  final _blockableOverlayState = BlockableOverlayState();
  StreamSubscription? _displaysSubscription;
  StreamSubscription? _piIsSetSubscription;
  bool _hasAutoSwitchedDisplay = false;
  bool _firstImageReceived = false;
  int _initialDisplayCount = 0;
  bool _secondaryDisplayRequested = false;

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false; // use soft keyboard
  bool _isStartMenuPushed = false;
  final Map<String, MemoryImage> _appIconMemoryCache = {};
  StreamSubscription? _textCursorSubscription;
  Timer? _textCursorPopupTimer;

  InputModel get inputModel => gFFI.inputModel;
  SessionID get sessionId => gFFI.sessionId;

  final TextEditingController _textController =
      TextEditingController(text: initText);

  Offset? _fabPortraitPos;
  Offset? _fabLandscapePos;
  bool _isFabDragging = false;
  Offset _fabDragFingerStart = Offset.zero;
  Offset _fabDragInitPos = Offset.zero;

  Offset _getFabPosition(
      Orientation orientation, Size size, EdgeInsets padding) {
    if (orientation == Orientation.landscape) {
      if (_fabLandscapePos != null) return _fabLandscapePos!;
      final saved = bind.getLocalFlutterOption(k: 'float_ctrl_l_pos');
      if (saved.isNotEmpty) {
        try {
          final parts = saved.split(',');
          if (parts.length == 2) {
            final x = double.parse(parts[0]);
            final y = double.parse(parts[1]);
            final maxX = max(8.0, size.width - 48.0 - 8.0);
            final maxY = max(8.0, size.height - 48.0 - 8.0);
            _fabLandscapePos = Offset(x.clamp(8.0, maxX), y.clamp(8.0, maxY));
            return _fabLandscapePos!;
          }
        } catch (_) {}
      }
      final defaultX =
          max(8.0, size.width - 48.0 - max(16.0, padding.right + 12.0));
      final defaultY =
          max(8.0, size.height - 48.0 - max(16.0, padding.bottom + 12.0));
      _fabLandscapePos = Offset(defaultX, defaultY);
      return _fabLandscapePos!;
    } else {
      if (_fabPortraitPos != null) return _fabPortraitPos!;
      final saved = bind.getLocalFlutterOption(k: 'float_ctrl_p_pos');
      if (saved.isNotEmpty) {
        try {
          final parts = saved.split(',');
          if (parts.length == 2) {
            final x = double.parse(parts[0]);
            final y = double.parse(parts[1]);
            final maxX = max(8.0, size.width - 48.0 - 8.0);
            final maxY = max(8.0, size.height - 48.0 - 8.0);
            _fabPortraitPos = Offset(x.clamp(8.0, maxX), y.clamp(8.0, maxY));
            return _fabPortraitPos!;
          }
        } catch (_) {}
      }
      final defaultX =
          max(8.0, size.width - 48.0 - max(16.0, padding.right + 12.0));
      final defaultY =
          max(8.0, size.height - 48.0 - max(16.0, padding.bottom + 12.0));
      _fabPortraitPos = Offset(defaultX, defaultY);
      return _fabPortraitPos!;
    }
  }

  void _updateFabPosition(Orientation orientation, Offset newPos, Size size) {
    final maxX = max(8.0, size.width - 48.0 - 8.0);
    final maxY = max(8.0, size.height - 48.0 - 8.0);
    final clamped =
        Offset(newPos.dx.clamp(8.0, maxX), newPos.dy.clamp(8.0, maxY));
    if (orientation == Orientation.landscape) {
      _fabLandscapePos = clamped;
    } else {
      _fabPortraitPos = clamped;
    }
  }

  void _saveFabPosition(Orientation orientation) {
    final pos = orientation == Orientation.landscape
        ? _fabLandscapePos
        : _fabPortraitPos;
    if (pos == null) return;
    final key = orientation == Orientation.landscape
        ? 'float_ctrl_l_pos'
        : 'float_ctrl_p_pos';
    bind.setLocalFlutterOption(k: key, v: '${pos.dx},${pos.dy}');
  }

  _RemotePageState(String id) {
    initSharedStates(id);
    gFFI.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;
    gFFI.dialogManager.loadMobileActionsOverlayVisible();
  }

  @override
  void initState() {
    _showBar.value = false;
    if (widget.isMobileMode) {
      if (!gFFI.ffiModel.touchMode) {
        gFFI.ffiModel.toggleTouchMode();
      }
      gFFI.ffiModel.touchPanMode.value = 'scroll';
      bind.mainSetLocalOption(key: 'touch_pan_mode', value: 'scroll');
      bind.mainSetPeerOptionSync(
          id: widget.id, key: 'custom-display-orientation', value: 'portrait');
    } else if (isSecondary && !gFFI.ffiModel.touchMode) {
      gFFI.ffiModel.toggleTouchMode();
    }
    // Set 120 FPS for USB secondary display to minimize sampling/VSync latency, 60 FPS for others
    final savedFps =
        bind.mainGetPeerOptionSync(id: widget.id, key: 'custom-fps');
    final defaultFps = isSecondary ? '120' : '60';
    final fpsVal = int.tryParse(savedFps.isNotEmpty ? savedFps : defaultFps) ??
        (isSecondary ? 120 : 60);
    if (savedFps.isEmpty) {
      bind.mainSetPeerOptionSync(
          id: widget.id, key: 'custom-fps', value: defaultFps);
    }
    bind.sessionSetCustomFps(sessionId: sessionId, fps: fpsVal);
    final savedQuality =
        bind.mainGetPeerOptionSync(id: widget.id, key: 'image-quality');
    if (savedQuality.isEmpty) {
      bind.mainSetPeerOptionSync(
          id: widget.id, key: 'image-quality', value: 'balanced');
    }
    final savedViewStyle =
        bind.mainGetPeerOptionSync(id: widget.id, key: 'view_style');
    if (savedViewStyle.isNotEmpty) {
      bind.sessionSetViewStyle(sessionId: sessionId, value: savedViewStyle);
    }

    if (isSecondary) {
      final savedCodec =
          bind.mainGetPeerOptionSync(id: widget.id, key: 'codec-preference');
      final savedI444 = bind.mainGetPeerOptionSync(id: widget.id, key: 'i444');
      if (savedCodec.isEmpty) {
        bind.mainSetPeerOptionSync(
            id: widget.id, key: 'codec-preference', value: 'h264');
      }
      if (savedI444.isEmpty || savedI444 == 'N') {
        bind.mainSetPeerOptionSync(id: widget.id, key: 'i444', value: '');
      }

      _displaysSubscription = gFFI.ffiModel.pi.displays.listen((displays) {
        _checkAndAutoSwitchUsbDisplay(displays);
      });
    }
    _piIsSetSubscription = gFFI.ffiModel.pi.isSet.listen((isSet) {
      if (isSet) {
        bind.sessionPeerOption(
          sessionId: sessionId,
          name: 'get_window_list',
          value: '',
        );
      }
    });
    super.initState();
    gFFI.ffiModel.updateEventListener(sessionId, widget.id);
    gFFI.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(
          isAndroid ? SystemUiMode.immersiveSticky : SystemUiMode.manual,
          overlays: []);
      gFFI.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    WakelockManager.enable(_uniqueKey);
    _physicalFocusNode.requestFocus();
    gFFI.inputModel.listenToMouse(true);
    _autoPopupKeyboardOnText.value =
        bind.mainGetLocalOption(key: 'auto_popup_keyboard_on_text') == 'true';
    _keyboardPopupMode.value =
        bind.mainGetLocalOption(key: 'keyboard_popup_mode');
    if (_keyboardPopupMode.value.isEmpty) {
      _keyboardPopupMode.value = 'tap';
    }
    _keyboardCursorMargin.value = (double.tryParse(
            bind.mainGetLocalOption(key: 'keyboard_cursor_margin')) ??
        30.0);
    _keyboardDismissMode.value =
        bind.mainGetLocalOption(key: 'keyboard_dismiss_mode');
    if (_keyboardDismissMode.value.isEmpty) {
      _keyboardDismissMode.value = 'any';
    }
    _keyboardPopupDelayMs.value = (int.tryParse(
            bind.mainGetLocalOption(key: 'keyboard_popup_delay_ms')) ??
        200);
    _textCursorSubscription = gFFI.cursorModel.isTextCursor.listen((isText) {
      _textCursorPopupTimer?.cancel();
      if (isText && _autoPopupKeyboardOnText.value) {
        if (_keyboardPopupMode.value == 'tap') {
          // 点击才弹出模式：严格仅当用户刚刚完成了一次有效点击，且当前没有在滑动/按住屏幕
          if (_pendingTapForText && !_pointerIsDown) {
            _pendingTapForText = false;
            _pendingTapTimer?.cancel();
            if (!_showEdit && !keyboardVisibilityController.isVisible) {
              openKeyboard();
            } else {
              _adjustCanvasForTextCursor();
            }
          }
        } else {
          // 自动弹出模式
          final delayMs = _keyboardPopupDelayMs.value;
          if (delayMs <= 0) {
            if (!_showEdit && !keyboardVisibilityController.isVisible) {
              openKeyboard();
            } else {
              _adjustCanvasForTextCursor();
            }
          } else {
            _textCursorPopupTimer = Timer(Duration(milliseconds: delayMs), () {
              if (mounted &&
                  gFFI.cursorModel.isTextCursor.value &&
                  _autoPopupKeyboardOnText.value) {
                if (!_showEdit && !keyboardVisibilityController.isVisible) {
                  openKeyboard();
                } else {
                  _adjustCanvasForTextCursor();
                }
              }
            });
          }
        }
      }
    });
    gFFI.qualityMonitorModel.checkShowQualityMonitor(sessionId);
    keyboardSubscription =
        keyboardVisibilityController.onChange.listen(onSoftKeyboardChanged);
    gFFI.chatModel
        .changeCurrentKey(MessageKey(widget.id, ChatModel.clientModeID));
    _blockableOverlayState.applyFfi(gFFI);
    gFFI.imageModel.addCallbackOnFirstImage((String peerId) {
      gFFI.dialogManager.dismissAll();
      if (isSecondary) {
        _firstImageReceived = true;
        _initialDisplayCount = gFFI.ffiModel.pi.displays.length;
        // Only request the virtual display here. The host creates it after
        // receiving this message, and the resulting display-list change
        // triggers the switch via the standard sessionSwitchDisplay path.
        _sendPhysicalResolutionToServer();
        // USB plugs the monitor in before login, so there may be no further
        // displays event. Apply the remembered choice immediately as well.
        _checkAndAutoSwitchUsbDisplay(gFFI.ffiModel.pi.displays);
      }
      gFFI.recordingModel
          .updateStatus(bind.sessionGetIsRecording(sessionId: gFFI.sessionId));
      if (gFFI.recordingModel.start) {
        showToast(translate('Automatically record outgoing sessions'));
      }
      _disableAndroidSoftKeyboard(
          isKeyboardVisible: keyboardVisibilityController.isVisible);
    });
    WidgetsBinding.instance.addObserver(this);
    if (isAndroid) {
      gFFI.invokeMethod("start_foreground");
    }
  }

  @override
  Future<void> dispose() async {
    _resetLeftAnchorState();
    _displaysSubscription?.cancel();
    _piIsSetSubscription?.cancel();
    _textCursorSubscription?.cancel();
    _textCursorPopupTimer?.cancel();
    _pendingTapTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // https://github.com/flutter/flutter/issues/64935
    super.dispose();
    gFFI.dialogManager.hideMobileActionsOverlay(store: false);
    gFFI.inputModel.listenToMouse(false);
    gFFI.imageModel.disposeImage();
    gFFI.cursorModel.disposeImages();
    await gFFI.invokeMethod("enable_soft_keyboard", true);
    _mobileFocusNode.dispose();
    _physicalFocusNode.dispose();
    await gFFI.close();
    if (isAndroid && !gFFI.serverModel.isStart) {
      await gFFI.invokeMethod("stop_service");
    }
    _timer?.cancel();
    _collapseLongPressTimer?.cancel();
    _iosKeyboardWorkaroundTimer?.cancel();
    SystemChrome.setPreferredOrientations([]);
    gFFI.dialogManager.dismissAll();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    WakelockManager.disable(_uniqueKey);
    await keyboardSubscription.cancel();
    removeSharedStates(widget.id);
    // `on_voice_call_closed` should be called when the connection is ended.
    // The inner logic of `on_voice_call_closed` will check if the voice call is active.
    // Only one client is considered here for now.
    gFFI.chatModel.onVoiceCallClosed("End connetion");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      trySyncClipboard();
    }
  }

  // For client side
  // When swithing from other app to this app, try to sync clipboard.
  void trySyncClipboard() {
    gFFI.invokeMethod("try_sync_clipboard");
  }

  // to-do: It should be better to use transparent color instead of the bgColor.
  // But for now, the transparent color will cause the canvas to be white.
  // I'm sure that the white color is caused by the Overlay widget in BlockableOverlay.
  // But I don't know why and how to fix it.
  Widget emptyOverlay(Color bgColor) => BlockableOverlay(
        /// the Overlay key will be set with _blockableOverlayState in BlockableOverlay
        /// see override build() in [BlockableOverlay]
        state: _blockableOverlayState,
        underlying: Container(
          color: bgColor,
        ),
      );

  void onSoftKeyboardChanged(bool visible) {
    if (!visible) {
      _isStartMenuPushed = false;
      SystemChrome.setEnabledSystemUIMode(
          isAndroid ? SystemUiMode.immersiveSticky : SystemUiMode.manual,
          overlays: []);
      // [pi.version.isNotEmpty] -> check ready or not, avoid login without soft-keyboard
      if (gFFI.chatModel.chatWindowOverlayEntry == null &&
          gFFI.ffiModel.pi.version.isNotEmpty) {
        gFFI.invokeMethod("enable_soft_keyboard", false);
      }

      _showEdit = false;
      _mobileFocusNode.unfocus();
      if (isAndroid) {
        Timer(const Duration(milliseconds: 50), () {
          if (mounted) _physicalFocusNode.requestFocus();
        });
      }
      gFFI.canvasModel.restoreMobileOffsetAfterSoftKeyboard();

      // Workaround for iOS: physical keyboard input fails after virtual keyboard is hidden
      // https://github.com/flutter/flutter/issues/39900
      // https://github.com/rustdesk/rustdesk/discussions/11843#discussioncomment-13499698 - Virtual keyboard issue
      if (isIOS) {
        _iosKeyboardWorkaroundTimer?.cancel();
        _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 100), () {
          if (!mounted) return;
          _physicalFocusNode.unfocus();
          _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 50), () {
            if (!mounted) return;
            _physicalFocusNode.requestFocus();
          });
        });
      }
    } else {
      _iosKeyboardWorkaroundTimer?.cancel();
      _iosKeyboardWorkaroundTimer = null;
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(
            isAndroid ? SystemUiMode.immersiveSticky : SystemUiMode.manual,
            overlays: isAndroid ? [] : SystemUiOverlay.values);
        _mobileFocusNode.requestFocus();
      });
      if (_isStartMenuPushed) {
        _pushCanvasAboveKeyboardWhenVisible();
      }
      Timer(const Duration(milliseconds: 150), () {
        if (mounted) {
          if (_isStartMenuPushed) {
            _pushCanvasAboveKeyboardWhenVisible();
          } else {
            _adjustCanvasForTextCursor();
          }
        }
      });
      Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          if (_isStartMenuPushed) {
            _pushCanvasAboveKeyboardWhenVisible();
          } else {
            _adjustCanvasForTextCursor();
          }
        }
      });
      Timer(const Duration(milliseconds: 500), () {
        if (mounted && _isStartMenuPushed) {
          _pushCanvasAboveKeyboardWhenVisible();
        }
      });
    }
    // update for Scaffold
    setState(() {});
    gFFI.canvasModel.updateViewStyle();
  }

  void _handleIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    var i = newValue.length - 1;
    for (; i >= 0 && newValue[i] != '1'; --i) {}
    var j = oldValue.length - 1;
    for (; j >= 0 && oldValue[j] != '1'; --j) {}
    if (i < j) j = i;
    var subNewValue = newValue.substring(j + 1);
    var subOldValue = oldValue.substring(j + 1);

    // get common prefix of subNewValue and subOldValue
    var common = 0;
    for (;
        common < subOldValue.length &&
            common < subNewValue.length &&
            subNewValue[common] == subOldValue[common];
        ++common) {}

    // get newStr from subNewValue
    var newStr = "";
    if (subNewValue.length > common) {
      newStr = subNewValue.substring(common);
    }

    // Set the value to the old value and early return if is still composing. (1 && 2)
    // 1. The composing range is valid
    // 2. The new string is shorter than the composing range.
    if (_textController.value.isComposingRangeValid) {
      final composingLength = _textController.value.composing.end -
          _textController.value.composing.start;
      if (composingLength > newStr.length) {
        _value = oldValue;
        return;
      }
    }

    // Delete the different part in the old value.
    for (i = 0; i < subOldValue.length - common; ++i) {
      inputModel.inputKey('VK_BACK');
    }

    // Input the new string.
    if (newStr.length > 1) {
      bind.sessionInputString(sessionId: sessionId, value: newStr);
    } else {
      inputChar(newStr);
    }
  }

  void _handleNonIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    if (oldValue.isNotEmpty &&
        newValue.isNotEmpty &&
        oldValue[0] == '1' &&
        newValue[0] != '1') {
      // clipboard
      oldValue = '';
    }
    if (newValue.length == oldValue.length) {
      // ?
    } else if (newValue.length < oldValue.length) {
      final char = 'VK_BACK';
      inputModel.inputKey(char);
    } else {
      final content = newValue.substring(oldValue.length);
      if (content.length > 1) {
        if (oldValue != '' &&
            content.length == 2 &&
            (content == '""' ||
                content == '()' ||
                content == '[]' ||
                content == '<>' ||
                content == "{}" ||
                content == '”“' ||
                content == '《》' ||
                content == '（）' ||
                content == '【】')) {
          // can not only input content[0], because when input ], [ are also auo insert, which cause ] never be input
          bind.sessionInputString(sessionId: sessionId, value: content);
          openKeyboard();
          return;
        }
        bind.sessionInputString(sessionId: sessionId, value: content);
      } else {
        inputChar(content);
      }
    }
  }

  // handle mobile virtual keyboard
  void handleSoftKeyboardInput(String newValue) {
    if (isIOS) {
      _handleIOSSoftKeyboardInput(newValue);
    } else {
      _handleNonIOSSoftKeyboardInput(newValue);
    }
  }

  void inputChar(String char) {
    if (char == '\n') {
      char = 'VK_RETURN';
    } else if (char == ' ') {
      char = 'VK_SPACE';
    }
    inputModel.inputKey(char);
  }

  void _closeSoftKeyboard() {
    _showEdit = false;
    gFFI.invokeMethod("enable_soft_keyboard", false);
    _mobileFocusNode.unfocus();
    if (isAndroid) {
      _physicalFocusNode.requestFocus();
    }
    gFFI.canvasModel.restoreMobileOffsetAfterSoftKeyboard();
    if (mounted) setState(() {});
  }

  void _adjustCanvasForTextCursor([double? forcedKeyboardHeight]) {
    if (!_autoPopupKeyboardOnText.value) return;
    if (!isTabletLayoutMode(context)) return;
    if (!gFFI.cursorModel.isTextCursor.value) return;

    final media = MediaQuery.of(context);
    final viewInsetsBottom = forcedKeyboardHeight ?? media.viewInsets.bottom;

    // 悬浮小键盘时（viewInsets.bottom <= 0，没有挤占底部窗口），完全不挪动画布
    if (viewInsetsBottom <= 0) return;

    final margin = _keyboardCursorMargin.value;
    final screenH = media.size.height;
    final keyboardTop = screenH - viewInsetsBottom;

    gFFI.canvasModel.adjustForKeyboardAboveCursor(
      keyboardTop: keyboardTop,
      margin: margin,
    );
  }

  void _pushCanvasAboveKeyboardWhenVisible() {
    void tryPush() {
      if (!mounted) return;
      final media = MediaQuery.of(context);
      double kbHeight = media.viewInsets.bottom;
      if (kbHeight <= 0) {
        kbHeight = media.size.height * 0.38;
      }
      if (kbHeight > 50) {
        if (_isStartMenuPushed) {
          gFFI.canvasModel.pushCanvasToRemoteBottomLeft(kbHeight);
        } else {
          gFFI.canvasModel.pushCanvasAboveKeyboard(kbHeight, alignLeft: true);
        }
      }
    }

    for (final delay in [100, 200, 350, 500, 700]) {
      Timer(Duration(milliseconds: delay), tryPush);
    }
  }

  void openKeyboard() {
    gFFI.canvasModel.saveMobileOffsetBeforeSoftKeyboard();
    gFFI.invokeMethod("enable_soft_keyboard", true);
    // destroy first, so that our _value trick can work
    _value = initText;
    _textController.text = _value;
    setState(() => _showEdit = false);
    _timer?.cancel();
    _timer = Timer(kMobileDelaySoftKeyboard, () {
      // show now, and sleep a while to requestFocus to
      // make sure edit ready, so that keyboard won't show/hide/show/hide happen
      setState(() => _showEdit = true);
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(
            isAndroid ? SystemUiMode.immersiveSticky : SystemUiMode.manual,
            overlays: isAndroid ? [] : SystemUiOverlay.values);
        _mobileFocusNode.requestFocus();
      });
    });
  }

  void _checkAndAutoSwitchUsbDisplay(List<Display> displays) {
    // Only a secondary-display session restores a display choice. A normal
    // remote-control connection must never be moved off the primary monitor.
    if (!isSecondary) return;
    if (displays.isEmpty) return;
    // Never switch before the first frame: the loading dialog is dismissed and
    // the toolbar is driven by that callback, so an early switch leaves the
    // page black with no controls.
    if (!_firstImageReceived) return;
    if (_hasAutoSwitchedDisplay) return;

    // Only switch if a new virtual monitor has actually been added and enumerated
    // (display count increased beyond initial physical display count).
    // If the host has multiple physical monitors, we must NOT switch prematurely
    // while displays.length <= _initialDisplayCount.
    // For reused monitors (where count does not increase), the host explicitly
    // sends follow_current_display to select the exact display index.
    final hasNewDisplay = displays.length > _initialDisplayCount;
    if (!hasNewDisplay) {
      return;
    }

    _hasAutoSwitchedDisplay = true;

    final saved =
        bind.mainGetPeerOptionSync(id: widget.id, key: 'usb_selected_display');
    // '0' means the user last stayed on the primary monitor. An empty value
    // means no choice has been made yet; a secondary-display session then
    // defaults to the virtual monitor (appended last by Windows).
    final stayOnPrimary = saved == '0';
    final targetIndex = stayOnPrimary ? 0 : displays.length - 1;

    if (targetIndex != gFFI.ffiModel.pi.currentDisplay) {
      debugPrint('Restoring remembered display choice: $targetIndex '
          '(saved "$saved", ${displays.length} displays)');
      openMonitorInTheSameTab(targetIndex, gFFI, gFFI.ffiModel.pi);
      BotToast.showText(
        text: 'Restored remembered display (Screen ${targetIndex + 1})',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = isTabletLayoutMode(context);

    return WillPopScope(
      onWillPop: () async {
        clientClose(sessionId, gFFI);
        return false;
      },
      child: Scaffold(
          extendBody: true,
          extendBodyBehindAppBar: true,
          resizeToAvoidBottomInset: (isAndroid && isTablet) ? false : true,
          floatingActionButtonLocation: null,
          floatingActionButton: null,
          bottomNavigationBar: Obx(() => Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  gFFI.ffiModel.pi.isSet.isTrue &&
                          gFFI.ffiModel.waitForFirstImage.isTrue
                      ? emptyOverlay(MyTheme.canvasColor)
                      : () {
                          gFFI.ffiModel.tryShowAndroidActionsOverlay();
                          return const Offstage();
                        }(),
                  _showGestureHelp ? getGestureHelp() : const Offstage(),
                  gFFI.ffiModel.pi.isSet.isFalse
                      ? emptyOverlay(MyTheme.canvasColor)
                      : const Offstage(),
                ],
              )),
          body: Obx(
            () => getRawPointerAndKeyBody(Overlay(
              initialEntries: [
                OverlayEntry(builder: (context) {
                  return Container(
                    color: kColorCanvas,
                    child: isWebDesktop
                        ? getBodyForDesktopWithListener()
                        : SafeArea(
                            left: !isAndroid,
                            right: !isAndroid,
                            top: !isAndroid,
                            bottom: !isAndroid,
                            child:
                                OrientationBuilder(builder: (ctx, orientation) {
                              if (_currentOrientation != orientation) {
                                Timer(const Duration(milliseconds: 200), () {
                                  gFFI.dialogManager
                                      .resetMobileActionsOverlay(ffi: gFFI);
                                  _currentOrientation = orientation;
                                  _isControlBarVertical.value =
                                      orientation == Orientation.landscape;
                                  gFFI.canvasModel.updateViewStyle();
                                });
                              }
                              return Container(
                                color: MyTheme.canvasColor,
                                child: getBodyForMobile(),
                              );
                            }),
                          ),
                  );
                })
              ],
            )),
          )),
    );
  }

  Widget getRawPointerAndKeyBody(Widget child) {
    final ffiModel = Provider.of<FfiModel>(context);
    return RawPointerMouseRegion(
      cursor: ffiModel.keyboard ? SystemMouseCursors.none : MouseCursor.defer,
      inputModel: inputModel,
      // Disable RawKeyFocusScope before the connecting is established.
      // The "Delete" key on the soft keyboard may be grabbed when inputting the password dialog.
      child: gFFI.ffiModel.pi.isSet.isTrue
          ? RawKeyFocusScope(
              focusNode: _physicalFocusNode,
              inputModel: inputModel,
              child: child)
          : child,
    );
  }

  Widget _buildFloatingControlBar(
      Orientation orientation, Size size, EdgeInsets padding, Offset fabPos) {
    if (!_isControlBarVerticalInit) {
      _isControlBarVertical.value = orientation == Orientation.landscape;
      _isControlBarVerticalInit = true;
    }
    final bool isBarVertical = _isControlBarVertical.value;
    final ffiModel = Provider.of<FfiModel>(context);

    Widget buildBtn(
        {required Widget icon,
        required VoidCallback? onPressed,
        VoidCallback? onLongPress,
        Color? backgroundColor,
        BorderRadius? borderRadius,
        String? tooltip}) {
      Widget btn = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        onLongPress: onLongPress,
        child: Container(
          width: 38,
          height: 38,
          decoration: backgroundColor != null
              ? BoxDecoration(
                  color: backgroundColor,
                  borderRadius: borderRadius ?? BorderRadius.circular(19),
                  border: Border.all(
                    color: Colors.white24,
                    width: 0.8,
                  ),
                )
              : null,
          alignment: Alignment.center,
          child: icon,
        ),
      );
      if (tooltip != null) {
        return Tooltip(message: tooltip, child: btn);
      }
      return btn;
    }

    final featureButtons = <Widget>[
      // 1. Disconnect / Close
      buildBtn(
        icon: const Icon(Icons.clear, color: Colors.white, size: 20),
        tooltip: translate('Close'),
        onPressed: () {
          clientClose(sessionId, gFFI);
        },
      ),
      // 2. Display / Monitor
      Obx(() => buildBtn(
            icon: Icon(
              Icons.tv,
              color: gFFI.qualityMonitorModel.isFastCap.value
                  ? const Color(0xFF00E676)
                  : Colors.white,
              size: 20,
            ),
            tooltip: translate('Display'),
            onPressed: () {
              setState(() => _showEdit = false);
              showOptions(context, widget.id, gFFI.dialogManager);
            },
          )),
      // 3. Soft Keyboard
      if (!isWebDesktop && !ffiModel.viewOnly && ffiModel.keyboard)
        buildBtn(
          icon: const Icon(Icons.keyboard, color: Colors.white, size: 20),
          tooltip: translate('Keyboard'),
          onPressed: openKeyboard,
          onLongPress: () async {
            final cur = !_autoPopupKeyboardOnText.value;
            _autoPopupKeyboardOnText.value = cur;
            await bind.mainSetLocalOption(
              key: 'auto_popup_keyboard_on_text',
              value: cur ? 'true' : 'false',
            );
            BotToast.showText(
              text: localeName.startsWith('zh')
                  ? (cur ? '已开启光标变为文本时自动弹出软键盘' : '已关闭文本光标自动弹出软键盘')
                  : (cur
                      ? 'Auto keyboard on text cursor enabled'
                      : 'Auto keyboard on text cursor disabled'),
            );
          },
        ),
      // 3.1 Shortcut Keys (Key Help Tools) toggle
      if (!isWebDesktop && !ffiModel.viewOnly && ffiModel.keyboard)
        Obx(() => buildBtn(
              icon: Icon(
                Icons.keyboard_command_key,
                color: !_keyHelpCollapsed.value ? Colors.white : Colors.white70,
                size: 20,
              ),
              backgroundColor: !_keyHelpCollapsed.value
                  ? const Color(0xFF0071FF) // 展开时高亮蓝色底色
                  : const Color(0x604A5568), // 收起时暗灰色底色
              borderRadius: BorderRadius.circular(19),
              tooltip: localeName.startsWith('zh')
                  ? (!_keyHelpCollapsed.value
                      ? '快捷按键 (已展开，点击收起)'
                      : '快捷按键 (点击展开)')
                  : (!_keyHelpCollapsed.value
                      ? 'Shortcut Keys (Active)'
                      : 'Shortcut Keys'),
              onPressed: () {
                _keyHelpCollapsed.value = !_keyHelpCollapsed.value;
                bind.mainSetLocalOption(
                  key: 'key_help_tools_collapsed',
                  value: _keyHelpCollapsed.value ? 'Y' : 'N',
                );
                if (mounted) setState(() {});
              },
            )),
      // 4. Input Method Picker (Android)
      if (isAndroid && !isWebDesktop && !ffiModel.viewOnly && ffiModel.keyboard)
        buildBtn(
          icon: const Icon(Icons.language, color: Colors.white, size: 20),
          tooltip: translate('Input Method'),
          onPressed: () => gFFI.invokeMethod("show_input_method_picker", null),
        ),
      // Peer Android Actions
      if (gFFI.ffiModel.isPeerAndroid &&
          !isWebDesktop &&
          !ffiModel.viewOnly &&
          ffiModel.keyboard)
        buildBtn(
          icon: const Icon(Icons.build, color: Colors.white, size: 20),
          tooltip: 'Android Actions',
          onPressed: () =>
              gFFI.dialogManager.toggleMobileActionsOverlay(ffi: gFFI),
        ),
      // 5. Mouse Mode button (selected: blue, unselected: grey)
      if (!isWebDesktop && !ffiModel.viewOnly && ffiModel.keyboard)
        buildBtn(
          icon: Icon(
            Icons.mouse,
            color: !ffiModel.touchMode ? Colors.white : Colors.white70,
            size: 20,
          ),
          backgroundColor: !ffiModel.touchMode
              ? const Color(0xFF0071FF)
              : const Color(0x604A5568),
          borderRadius: BorderRadius.circular(19),
          tooltip: !ffiModel.touchMode
              ? (localeName.startsWith('zh')
                  ? '鼠标模式 (点击打开菜单，长按开关左侧手势区)'
                  : 'Mouse Mode (Tap for menu, long press to toggle left zone)')
              : (localeName.startsWith('zh')
                  ? '鼠标模式 (点击切换)'
                  : 'Mouse Mode (Tap to select)'),
          onPressed: () {
            if (ffiModel.touchMode) {
              ffiModel.toggleTouchMode();
              bind.mainSetLocalOption(key: kOptionTouchMode, value: 'N');
              BotToast.showText(
                text: localeName.startsWith('zh')
                    ? '已切换到鼠标模式'
                    : 'Switched to Mouse Mode',
              );
              if (mounted) setState(() {});
            } else {
              setState(() => _showGestureHelp = !_showGestureHelp);
            }
          },
          onLongPress: () {
            ffiModel.toggleLeftAnchorZone();
            BotToast.showText(
              text: ffiModel.leftAnchorZone.value
                  ? (localeName.startsWith('zh')
                      ? '左侧手势区: 已开启'
                      : 'Left Gesture Zone: Enabled')
                  : (localeName.startsWith('zh')
                      ? '左侧手势区: 已关闭'
                      : 'Left Gesture Zone: Disabled'),
            );
            if (mounted) setState(() {});
          },
        ),
      // 6. Touch Mode button (selected: blue, unselected: grey)
      if (!isWebDesktop && !ffiModel.viewOnly && ffiModel.keyboard)
        buildBtn(
          icon: Icon(
            Icons.touch_app,
            color: ffiModel.touchMode ? Colors.white : Colors.white70,
            size: 20,
          ),
          backgroundColor: ffiModel.touchMode
              ? const Color(0xFF0071FF) // 选中底色为蓝色
              : const Color(0x604A5568), // 未选中底色为灰色
          borderRadius: BorderRadius.circular(19),
          tooltip: ffiModel.touchMode
              ? (localeName.startsWith('zh')
                  ? '触屏模式 (已选中，点击打开说明与设置)'
                  : 'Touch Mode (Selected, tap for menu)')
              : (localeName.startsWith('zh')
                  ? '触屏模式 (点击切换)'
                  : 'Touch Mode (Tap to select)'),
          onPressed: () {
            if (!ffiModel.touchMode) {
              ffiModel.toggleTouchMode();
              bind.mainSetLocalOption(key: kOptionTouchMode, value: 'Y');
              BotToast.showText(
                text: localeName.startsWith('zh')
                    ? '已切换至触屏模式'
                    : 'Switched to Touch Mode',
              );
              if (mounted) setState(() {});
            } else {
              setState(() => _showGestureHelp = !_showGestureHelp);
            }
          },
        ),
      // 5.0 Mobile Mode quick app switcher
      if (widget.isMobileMode &&
          !isWebDesktop &&
          !ffiModel.viewOnly &&
          ffiModel.keyboard)
        buildBtn(
          icon: const Icon(
            Icons.dashboard_customize,
            color: Colors.greenAccent,
            size: 20,
          ),
          tooltip: localeName.startsWith('zh')
              ? '手机模式: 选择程序并在虚拟屏全屏'
              : 'Mobile Mode: Select App & Maximize',
          onPressed: () async {
            await bind.sessionPeerOption(
                sessionId: gFFI.sessionId, name: 'get_window_list', value: '');
          },
        ),
      // 5.1 One-Finger Move quick toggle (when enabled in gesture settings)
      if (ffiModel.showTouchPanInToolbar.value &&
          !isWebDesktop &&
          !ffiModel.viewOnly &&
          ffiModel.keyboard)
        buildBtn(
          icon: Icon(
            ffiModel.touchPanMode.value == 'scroll'
                ? Icons.swap_vert
                : Icons.text_fields,
            color: Colors.white,
            size: 20,
          ),
          tooltip: ffiModel.touchPanMode.value == 'scroll'
              ? (localeName.startsWith('zh')
                  ? '单指移动: 滚动屏幕 (点击切换为选择文字)'
                  : 'One-Finger: Scroll (Tap for select)')
              : (localeName.startsWith('zh')
                  ? '单指移动: 选择文字 (点击切换为滚动屏幕)'
                  : 'One-Finger: Select (Tap for scroll)'),
          onPressed: () {
            ffiModel.toggleTouchPanMode();
            BotToast.showText(
              text: ffiModel.touchPanMode.value == 'scroll'
                  ? (localeName.startsWith('zh')
                      ? '单指移动: 滚动屏幕 (跟手滑动)'
                      : 'One-Finger: Scroll Screen')
                  : (localeName.startsWith('zh')
                      ? '单指移动: 选择文字 (拖拽划词)'
                      : 'One-Finger: Select Text'),
            );
            if (mounted) setState(() {});
          },
        ),
      // 5.2 Two-Finger Zoom quick toggle (when enabled in gesture settings)
      if (ffiModel.showTouchZoomInToolbar.value &&
          !isWebDesktop &&
          !ffiModel.viewOnly &&
          ffiModel.keyboard)
        buildBtn(
          icon: Icon(
            ffiModel.touchZoomMode.value == 'remote'
                ? Icons.zoom_in
                : Icons.zoom_out_map,
            color: Colors.white,
            size: 20,
          ),
          tooltip: ffiModel.touchZoomMode.value == 'remote'
              ? (localeName.startsWith('zh')
                  ? '双指缩放: 远程缩放 (点击切换为缩放画布)'
                  : 'Pinch: Remote Zoom (Tap for canvas)')
              : (localeName.startsWith('zh')
                  ? '双指缩放: 缩放画布 (点击切换为远程缩放)'
                  : 'Pinch: Canvas Zoom (Tap for remote)'),
          onPressed: () {
            ffiModel.toggleTouchZoomMode();
            BotToast.showText(
              text: ffiModel.touchZoomMode.value == 'canvas'
                  ? (localeName.startsWith('zh')
                      ? '双指缩放: 缩放画布'
                      : 'Two-Finger: Canvas Zoom')
                  : (localeName.startsWith('zh')
                      ? '双指缩放: 远程缩放 (以手机中点缩放应用)'
                      : 'Two-Finger: Remote Zoom'),
            );
            if (mounted) setState(() {});
          },
        ),
      // 7. More Actions
      buildBtn(
        icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
        tooltip: translate('Actions'),
        onPressed: () {
          setState(() => _showEdit = false);
          showActions(widget.id);
        },
      ),
    ];

    final totalCount = featureButtons.length + 1; // including collapse button
    final double neededLength = totalCount * 38.0 + 8.0;

    final double barWidth = isBarVertical
        ? 48.0
        : min(neededLength, size.width - padding.left - padding.right - 16.0);
    final double barHeight = isBarVertical
        ? min(neededLength, size.height - padding.top - padding.bottom - 16.0)
        : 48.0;

    bool collapseAtStart;
    IconData collapseIcon;
    double barX;
    double barY;

    if (isBarVertical) {
      barX = fabPos.dx;
      if (fabPos.dy > size.height / 2) {
        // More space above -> expands UPWARDS
        // [收起箭头] placed at BOTTOM (end of list) so it stays exactly at fabPos.dy!
        collapseAtStart = false;
        collapseIcon = Icons.expand_more;
        barY = fabPos.dy + 48.0 - barHeight;
      } else {
        // More space below -> expands DOWNWARDS
        // [收起箭头] placed at TOP (start of list) so it stays exactly at fabPos.dy!
        collapseAtStart = true;
        collapseIcon = Icons.expand_less;
        barY = fabPos.dy;
      }
    } else {
      barY = fabPos.dy;
      if (fabPos.dx > size.width / 2) {
        // More space to the left -> expands LEFTWARDS
        // [收起箭头] placed at RIGHT (end of list) so it stays exactly at fabPos.dx!
        collapseAtStart = false;
        collapseIcon = Icons.chevron_right;
        barX = fabPos.dx + 48.0 - barWidth;
      } else {
        // More space to the right -> expands RIGHTWARDS
        // [收起箭头] placed at LEFT (start of list) so it stays exactly at fabPos.dx!
        collapseAtStart = true;
        collapseIcon = Icons.chevron_left;
        barX = fabPos.dx;
      }
    }

    final collapseBtn = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _fabDragFingerStart = event.position;
        _fabDragInitPos = fabPos;
        _isFabDragging = false;
        _isCollapseLongPressed = false;
        _collapseLongPressTimer?.cancel();
        _collapseLongPressTimer = Timer(const Duration(milliseconds: 500), () {
          if (!_isFabDragging) {
            _isCollapseLongPressed = true;
            HapticFeedback.mediumImpact();
            _toggleControlBarOrientation();
          }
        });
      },
      onPointerMove: (event) {
        final delta = event.position - _fabDragFingerStart;
        if (!_isFabDragging && delta.distance > 4.0) {
          _isFabDragging = true;
          _collapseLongPressTimer?.cancel();
        }
        if (_isFabDragging) {
          setState(() {
            _updateFabPosition(
              orientation,
              _fabDragInitPos + delta,
              size,
            );
          });
        }
      },
      onPointerUp: (event) {
        _collapseLongPressTimer?.cancel();
        if (_isCollapseLongPressed) {
          _isCollapseLongPressed = false;
          return;
        }
        if (_isFabDragging) {
          _saveFabPosition(orientation);
          _isFabDragging = false;
        } else {
          _showBar.value = false;
          if (mounted) setState(() {});
        }
      },
      onPointerCancel: (event) {
        _collapseLongPressTimer?.cancel();
        if (_isFabDragging) {
          _saveFabPosition(orientation);
          _isFabDragging = false;
        }
      },
      child: Tooltip(
        message: translate('Collapse') +
            (localeName.startsWith('zh')
                ? ' (长按切换控制栏横竖方向)'
                : ' (Long press to toggle toolbar orientation)'),
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          child: Icon(collapseIcon, color: Colors.white, size: 22),
        ),
      ),
    );

    final buttons = <Widget>[];
    if (collapseAtStart) {
      buttons.add(collapseBtn);
      buttons.addAll(featureButtons);
    } else {
      buttons.addAll(featureButtons);
      buttons.add(collapseBtn);
    }

    // Clamp strictly within safe area
    final minLeft = padding.left + 8.0;
    final maxLeft = max(minLeft, size.width - padding.right - barWidth - 8.0);
    final minTop = padding.top + 8.0;
    final maxTop = max(minTop, size.height - padding.bottom - barHeight - 8.0);

    final clampedX = barX.clamp(minLeft, maxLeft);
    final clampedY = barY.clamp(minTop, maxTop);

    return Positioned(
      left: clampedX,
      top: clampedY,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // Prevent taps on toolbar from falling through to canvas
        child: Material(
          color: Colors.transparent,
          elevation: 8.0,
          borderRadius: BorderRadius.circular(24.0),
          child: Container(
            width: isBarVertical ? barWidth : null,
            height: isBarVertical ? null : barHeight,
            constraints: BoxConstraints(
              maxWidth: barWidth,
              maxHeight: barHeight,
            ),
            decoration: BoxDecoration(
              color: const Color(0xC80071FF), // 半透明蓝色质感
              borderRadius: BorderRadius.circular(24.0),
              border: Border.all(
                color: const Color(0x60FFFFFF),
                width: 1.0,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 8.0,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            padding: EdgeInsets.symmetric(
              horizontal: 4.0,
              vertical: isBarVertical ? 4.0 : 2.0,
            ),
            child: SingleChildScrollView(
              scrollDirection: isBarVertical ? Axis.vertical : Axis.horizontal,
              child: isBarVertical
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: buttons,
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: buttons,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  bool get showCursorPaint =>
      !gFFI.ffiModel.isPeerAndroid &&
      !gFFI.canvasModel.cursorEmbedded &&
      !gFFI.inputModel.relativeMouseMode.value;

  Widget _buildKeyHelpTools(bool isTablet, bool keyboardIsVisible) {
    return Obx(() => KeyHelpTools(
        isTablet: isTablet,
        showBar: _showBar.value,
        keyboardIsVisible: keyboardIsVisible,
        showGestureHelp: _showGestureHelp,
        collapsed: _keyHelpCollapsed.value,
        onCollapseToggle: (val) {
          _keyHelpCollapsed.value = val;
          bind.mainSetLocalOption(
            key: 'key_help_tools_collapsed',
            value: val ? 'Y' : 'N',
          );
        }));
  }

  Widget getBodyForMobile() {
    return Obx(() {
      final keyboardIsVisible =
          _showEdit || keyboardVisibilityController.isVisible;
      final isTablet = isTabletLayoutMode(context);
      final showKeyboardHideFab = isTablet && keyboardIsVisible;
      final showActionButton = !keyboardIsVisible || isTablet;
      final orientation = MediaQuery.of(context).orientation;
      final padding = MediaQuery.of(context).padding;
      final size = MediaQuery.of(context).size;

      final paints = <Widget>[
        Positioned.fill(
          child: RawTouchGestureDetectorRegion(
            ffi: gFFI,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                _pointerIsDown = true;
                _pointerDownPos = event.position;
                _pointerDownTime = DateTime.now();
                _pointerMoved = false;
                _pendingTapForText = false;
                _pendingTapTimer?.cancel();

                final isText = gFFI.cursorModel.isTextCursor.value;
                final isKeyboardVisible =
                    _showEdit || keyboardVisibilityController.isVisible;

                if (_keyboardDismissMode.value == 'any') {
                  // 触摸/按下即收回软键盘
                  if (isKeyboardVisible && !isText) {
                    _closeSoftKeyboard();
                  } else if (_showEdit && isText) {
                    _mobileFocusNode.requestFocus();
                  }
                } else {
                  if (_showEdit && isText) {
                    _mobileFocusNode.requestFocus();
                  }
                }
              },
              onPointerMove: (event) {
                if (_pointerDownPos != null) {
                  final dist = (event.position - _pointerDownPos!).distance;
                  // 划过移动超过 8px 即视为滑动，杜绝误判为点击，并取消所有待触发文本弹出
                  if (dist > 8.0) {
                    _pointerMoved = true;
                    _pendingTapForText = false;
                    _pendingTapTimer?.cancel();
                  }
                }
              },
              onPointerUp: (event) {
                final durationMs = DateTime.now()
                    .difference(_pointerDownTime ?? DateTime.now())
                    .inMilliseconds;
                final dist = _pointerDownPos != null
                    ? (event.position - _pointerDownPos!).distance
                    : 999.0;
                // 严格点击判定：位移小于 8px 且触摸时长小于 350ms，划过时绝不误判
                final bool isTap =
                    !_pointerMoved && dist < 8.0 && durationMs < 350;
                _pointerIsDown = false;

                if (isTap) {
                  final isText = gFFI.cursorModel.isTextCursor.value;
                  final isKeyboardVisible =
                      _showEdit || keyboardVisibilityController.isVisible;

                  if (_autoPopupKeyboardOnText.value) {
                    if (isText) {
                      // 光标已经是文本光标，用户在此处点击直接弹出
                      if (!isKeyboardVisible) {
                        openKeyboard();
                      } else if (_showEdit) {
                        _mobileFocusNode.requestFocus();
                      }
                    } else if (_keyboardPopupMode.value == 'tap') {
                      // 光标尚不是文本光标，用户点击输入框后等待远端光标切换为文本（400ms窗口）
                      _pendingTapForText = true;
                      _pendingTapTimer?.cancel();
                      _pendingTapTimer =
                          Timer(const Duration(milliseconds: 400), () {
                        _pendingTapForText = false;
                      });
                    }
                  }

                  if (_keyboardDismissMode.value == 'tap') {
                    if (isKeyboardVisible && !isText) {
                      _closeSoftKeyboard();
                    }
                  }
                } else {
                  _pendingTapForText = false;
                  _pendingTapTimer?.cancel();
                }

                _pointerDownPos = null;
                _pointerDownTime = null;
                _pointerMoved = false;
              },
              onPointerCancel: (event) {
                _pointerIsDown = false;
                _pointerDownPos = null;
                _pointerDownTime = null;
                _pointerMoved = false;
                _pendingTapForText = false;
                _pendingTapTimer?.cancel();
              },
              child: Container(
                color: Colors.transparent,
                child: Stack(
                  children: [
                    SizedBox.expand(
                      child: ImagePaint(ffiModel: gFFI.ffiModel),
                    ),
                    if (showCursorPaint) CursorPaint(widget.id),
                    if (gFFI.ffiModel.touchMode)
                      FloatingMouse(
                        ffi: gFFI,
                      )
                    else
                      FloatingMouseWidgets(
                        ffi: gFFI,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ...() {
          final anchorRect = _getLeftAnchorZoneRect(size);
          final isAnchorEnabled =
              !gFFI.ffiModel.touchMode && gFFI.ffiModel.leftAnchorZone.value;

          if (!isAnchorEnabled && _isAnchorActive.value) {
            _resetLeftAnchorState();
          }

          if (!isAnchorEnabled) return <Widget>[];

          return <Widget>[
            // 1. Full-screen Action Interceptor Layer (only active when anchor finger is held down)
            Positioned.fill(
              child: Obx(
                () => _isAnchorActive.value
                    ? Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) {
                          if (event.pointer == _anchorPointerId) return;
                          _actionPointerId = event.pointer;
                          _actionDownPos = event.position;
                          _actionDownTime = DateTime.now();
                          _actionLastPos = event.position;
                          _actionHasMoved = false;
                          _actionScrollAccX = 0.0;
                          _actionScrollAccY = 0.0;
                        },
                        onPointerMove: (event) async {
                          if (event.pointer != _actionPointerId) return;
                          final dist =
                              (event.position - _actionDownPos).distance;
                          if (!_actionHasMoved && dist > 6.0) {
                            _actionHasMoved = true;
                          }
                          if (_actionHasMoved) {
                            final delta = event.position - _actionLastPos;
                            _actionLastPos = event.position;
                            _actionScrollAccX += delta.dx;
                            _actionScrollAccY += delta.dy;

                            const double threshold = 8.0;
                            int scrollX = 0;
                            int scrollY = 0;

                            if (_actionScrollAccX.abs() >= threshold) {
                              scrollX =
                                  (_actionScrollAccX / threshold).truncate();
                              _actionScrollAccX -= scrollX * threshold;
                            }
                            if (_actionScrollAccY.abs() >= threshold) {
                              scrollY =
                                  (_actionScrollAccY / threshold).truncate();
                              _actionScrollAccY -= scrollY * threshold;
                            }

                            if (scrollX != 0 || scrollY != 0) {
                              await bind.sessionSendMouse(
                                sessionId: gFFI.sessionId,
                                msg: json.encode(gFFI.inputModel.modify({
                                  'id': gFFI.inputModel.id,
                                  'type': 'wheel',
                                  'x': scrollX.toString(),
                                  'y': scrollY.toString(),
                                })),
                              );
                            }
                          }
                        },
                        onPointerUp: (event) async {
                          if (event.pointer == _actionPointerId) {
                            final duration = DateTime.now()
                                .difference(_actionDownTime)
                                .inMilliseconds;
                            final dist =
                                (event.position - _actionDownPos).distance;
                            final bool isTap = !_actionHasMoved &&
                                dist < 8.0 &&
                                duration < 500;
                            _actionPointerId = null;

                            if (isTap && _isAnchorActive.value) {
                              // Direct left click at tapped position
                              await gFFI.cursorModel
                                  .move(event.position.dx, event.position.dy);
                              await gFFI.inputModel.tap(MouseButtons.left);
                            }
                          }
                        },
                        onPointerCancel: (event) {
                          if (event.pointer == _actionPointerId) {
                            _actionPointerId = null;
                          }
                        },
                        child: const SizedBox.expand(),
                      )
                    : const SizedBox.shrink(),
              ),
            ),

            // 2. Anchor Zone Touch Receiver (bottom-left area)
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  if (_anchorPointerId == null) {
                    _anchorPointerId = event.pointer;
                    _isAnchorActive.value = true;
                  } else if (_actionPointerId == null &&
                      event.pointer != _anchorPointerId) {
                    _actionPointerId = event.pointer;
                    _actionDownPos = event.position;
                    _actionDownTime = DateTime.now();
                    _actionLastPos = event.position;
                    _actionHasMoved = false;
                    _actionScrollAccX = 0.0;
                    _actionScrollAccY = 0.0;
                  }
                },
                onPointerMove: (event) async {
                  if (event.pointer == _actionPointerId) {
                    final dist = (event.position - _actionDownPos).distance;
                    if (!_actionHasMoved && dist > 6.0) {
                      _actionHasMoved = true;
                    }
                    if (_actionHasMoved) {
                      final delta = event.position - _actionLastPos;
                      _actionLastPos = event.position;
                      _actionScrollAccX += delta.dx;
                      _actionScrollAccY += delta.dy;

                      const double threshold = 8.0;
                      int scrollX = 0;
                      int scrollY = 0;

                      if (_actionScrollAccX.abs() >= threshold) {
                        scrollX = (_actionScrollAccX / threshold).truncate();
                        _actionScrollAccX -= scrollX * threshold;
                      }
                      if (_actionScrollAccY.abs() >= threshold) {
                        scrollY = (_actionScrollAccY / threshold).truncate();
                        _actionScrollAccY -= scrollY * threshold;
                      }

                      if (scrollX != 0 || scrollY != 0) {
                        await bind.sessionSendMouse(
                          sessionId: gFFI.sessionId,
                          msg: json.encode(gFFI.inputModel.modify({
                            'id': gFFI.inputModel.id,
                            'type': 'wheel',
                            'x': scrollX.toString(),
                            'y': scrollY.toString(),
                          })),
                        );
                      }
                    }
                  }
                },
                onPointerUp: (event) async {
                  if (event.pointer == _anchorPointerId) {
                    _anchorPointerId = null;
                    _actionPointerId = null;
                    _isAnchorActive.value = false;
                  } else if (event.pointer == _actionPointerId) {
                    final duration = DateTime.now()
                        .difference(_actionDownTime)
                        .inMilliseconds;
                    final dist = (event.position - _actionDownPos).distance;
                    final bool isTap =
                        !_actionHasMoved && dist < 8.0 && duration < 500;
                    _actionPointerId = null;
                    if (isTap && _isAnchorActive.value) {
                      await gFFI.cursorModel
                          .move(event.position.dx, event.position.dy);
                      await gFFI.inputModel.tap(MouseButtons.left);
                    }
                  }
                },
                onPointerCancel: (event) {
                  if (event.pointer == _anchorPointerId) {
                    _anchorPointerId = null;
                    _actionPointerId = null;
                    _isAnchorActive.value = false;
                  } else if (event.pointer == _actionPointerId) {
                    _actionPointerId = null;
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),

            // 3. Visual 30% translucent grey mask
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: Obx(
                () => _isAnchorActive.value
                    ? IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0x4D808080),
                            borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(12),
                            ),
                            border: Border.all(
                              color: const Color(0x40FFFFFF),
                              width: 1.2,
                            ),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.touch_app,
                                  color: Color(0x99FFFFFF),
                                  size: 20,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  localeName.startsWith('zh')
                                      ? '滑动: 滚轮\n点击: 原位左键'
                                      : 'Pan: Scroll\nTap: Left Click',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Color(0xCCFFFFFF),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    height: 1.15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            )
          ];
        }(),
        _buildAnchorZoneAdjustOverlay(size),
        Positioned(
          top: 10,
          right: 10,
          child: QualityMonitor(gFFI.qualityMonitorModel),
        ),
        _buildKeyHelpTools(isTablet, keyboardIsVisible),
        () {
          if (!_showEdit) {
            return const SizedBox.shrink();
          }
          final cm = gFFI.cursorModel;
          final canvas = gFFI.canvasModel;
          final s = canvas.scale;
          final adjust = canvas.getAdjustY();
          final curX = (cm.x - cm.hotx) * s + canvas.x;
          final curY = (cm.y - cm.hoty) * s + canvas.y + adjust;
          final posX = curX.clamp(0.0, max(0.0, size.width - 24.0)).toDouble();
          final posY = curY.clamp(0.0, max(0.0, size.height - 24.0)).toDouble();
          return Positioned(
            left: posX,
            top: posY,
            width: 24.0,
            height: 24.0,
            child: Opacity(
              opacity: 0.0,
              child: TextFormField(
                textInputAction: TextInputAction.newline,
                autocorrect: true,
                enableSuggestions: true,
                autofocus: true,
                focusNode: _mobileFocusNode,
                maxLines: null,
                controller: _textController,
                keyboardType: TextInputType.multiline,
                onChanged: handleSoftKeyboardInput,
              ).workaroundFreezeLinuxMint(),
            ),
          );
        }(),
      ];
      final topPadding = padding.top;
      final leftPadding = padding.left;
      final escTop = max(10.0, isAndroid ? topPadding + 4.0 : 10.0);
      final escLeft = max(10.0, leftPadding + 4.0);
      paints.add(Positioned(
        top: escTop,
        left: escLeft,
        child: Obx(() => gFFI.canvasModel.showEscKey.value
            ? _buildFloatingEscKeyContent()
            : const SizedBox.shrink()),
      ));
      final isSingleApp =
          gFFI.canvasModel.isSingleAppMode || widget.isMobileMode;
      if (isSingleApp && !keyboardIsVisible) {
        paints.add(Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: gFFI.canvasModel.singleAppDockHeight,
          child: _buildSingleAppDockBar(context),
        ));
      }
      if (_showBar.value && gFFI.ffiModel.pi.displays.isNotEmpty) {
        final fabPos = _getFabPosition(orientation, size, padding);
        paints
            .add(_buildFloatingControlBar(orientation, size, padding, fabPos));
      }
      if (!_showBar.value && showActionButton) {
        final fabPos = _getFabPosition(orientation, size, padding);
        paints.add(Positioned(
          left: fabPos.dx,
          top: fabPos.dy,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              _fabDragFingerStart = event.position;
              _fabDragInitPos = fabPos;
              _isFabDragging = false;
            },
            onPointerMove: (event) {
              final delta = event.position - _fabDragFingerStart;
              if (!_isFabDragging && delta.distance > 4.0) {
                _isFabDragging = true;
              }
              if (_isFabDragging) {
                setState(() {
                  _updateFabPosition(
                    orientation,
                    _fabDragInitPos + delta,
                    size,
                  );
                });
              }
            },
            onPointerUp: (event) {
              if (_isFabDragging) {
                _saveFabPosition(orientation);
                _isFabDragging = false;
              } else {
                // Instant tap response with zero arena timeout!
                if (showKeyboardHideFab) {
                  _closeSoftKeyboard();
                } else if (_showGestureHelp) {
                  _showGestureHelp = false;
                } else {
                  _showBar.value = true;
                }
                if (mounted) setState(() {});
              }
            },
            onPointerCancel: (event) {
              if (_isFabDragging) {
                _saveFabPosition(orientation);
                _isFabDragging = false;
              }
            },
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0x990071FF), // 半透明蓝色展开按钮
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0x70FFFFFF),
                  width: 1.2,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: (showKeyboardHideFab || _showGestureHelp)
                  ? const Icon(Icons.expand_more, color: Colors.white, size: 24)
                  : (_showBar.value
                      ? const Icon(Icons.close, color: Colors.white, size: 24)
                      : _buildHamburgerIcon(
                          gFFI.qualityMonitorModel.isFastCap.value)),
            ),
          ),
        ));
      }
      return Container(
        color: MyTheme.canvasColor,
        child: Stack(children: paints),
      );
    });
  }

  Widget _buildSingleAppDockBar(BuildContext context) {
    return Obx(() {
      final list = gFFI.canvasModel.appWindowList.value;
      final currentHwnd = gFFI.canvasModel.currentSelectedHwnd;

      return Container(
        height: gFFI.canvasModel.singleAppDockHeight,
        decoration: BoxDecoration(
          color: const Color(0xEE161D28),
          border: const Border(
            top: BorderSide(color: Color(0x33FFFFFF), width: 0.8),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Left Windows Start Button (with soft keyboard trigger)
            IconButton(
              padding: const EdgeInsets.all(6),
              icon: const Icon(
                Icons.grid_view_rounded,
                color: Colors.cyanAccent,
                size: 20,
              ),
              tooltip: localeName.startsWith('zh')
                  ? 'Windows 开始菜单 (呼出软键盘)'
                  : 'Start Menu (Open Keyboard)',
              onPressed: () {
                gFFI.inputModel.inputKey('Meta', press: true);
                _isStartMenuPushed = true;
                openKeyboard();
                _pushCanvasAboveKeyboardWhenVisible();
              },
            ),
            // Horizontal scrollable app list
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: TextButton.icon(
                        icon: const Icon(Icons.refresh,
                            size: 15, color: Colors.white70),
                        label: Text(
                          localeName.startsWith('zh')
                              ? '点击刷新程序列表'
                              : 'Refresh App List',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white70),
                        ),
                        onPressed: () {
                          bind.sessionPeerOption(
                            sessionId: gFFI.sessionId,
                            name: 'get_window_list',
                            value: '',
                          );
                        },
                      ),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: list.length,
                      itemBuilder: (ctx, idx) {
                        final item = list[idx];
                        final title = item['title']?.toString() ?? '';
                        final name = item['name']?.toString() ?? '';
                        final hwnd =
                            int.tryParse(item['hwnd']?.toString() ?? '0') ?? 0;
                        final isSelected = currentHwnd == hwnd;

                        final displayName = name.replaceAll(
                            RegExp(r'\.exe$', caseSensitive: false), '');
                        final iconData = _resolveAppIcon(name, title);
                        final iconColor = _resolveAppColor(name);

                        final iconBase64 = item['icon']?.toString() ?? '';
                        Widget appIconWidget;
                        if (iconBase64.isNotEmpty) {
                          try {
                            final imageProvider = _appIconMemoryCache.putIfAbsent(
                              iconBase64,
                              () => MemoryImage(base64Decode(iconBase64)),
                            );
                            appIconWidget = ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image(
                                image: imageProvider,
                                width: 26,
                                height: 26,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (ctx, err, stack) => Icon(iconData,
                                    color: isSelected
                                        ? Colors.cyanAccent
                                        : iconColor,
                                    size: 20),
                              ),
                            );
                          } catch (_) {
                            appIconWidget = Icon(iconData,
                                color:
                                    isSelected ? Colors.cyanAccent : iconColor,
                                size: 20);
                          }
                        } else {
                          appIconWidget = Icon(iconData,
                              color: isSelected ? Colors.cyanAccent : iconColor,
                              size: 20);
                        }

                        return Tooltip(
                          message: title.isNotEmpty
                              ? '$title ($displayName)'
                              : displayName,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (gFFI.canvasModel.currentSelectedHwnd == hwnd) {
                                return;
                              }
                              gFFI.canvasModel.currentSelectedHwnd = hwnd;
                              gFFI.canvasModel.currentSelectedAppName = name;
                              gFFI.canvasModel.loadAppCrop(name);

                              final directMode = bind.mainGetLocalOption(
                                      key: 'direct_window_capture') !=
                                  'N';
                              final modeStr = directMode ? 'direct' : 'crop';

                              final dims = gFFI.canvasModel
                                  .calculateRemoteWindowTargetSize();
                              final targetW = dims['targetW'] ?? 700;
                              final targetH = dims['targetH'] ?? 1300;

                              int phoneW = 1260;
                              int phoneH = 2800;
                              if (WidgetsBinding.instance.platformDispatcher.views.isNotEmpty) {
                                final view = WidgetsBinding.instance.platformDispatcher.views.first;
                                phoneW = view.physicalSize.width.round();
                                phoneH = view.physicalSize.height.round();
                              }

                              gFFI.ffiModel.pi
                                  .platformAdditions['selected_window'] = hwnd;
                              gFFI.ffiModel.touchMode = true;
                              gFFI.canvasModel.isSingleAppMode = true;

                              bind.sessionPeerOption(
                                sessionId: gFFI.sessionId,
                                name: 'select_window',
                                value: '$hwnd:$modeStr:$targetW:$targetH:$phoneW:$phoneH',
                              );
                              bind.sessionPeerOption(
                                sessionId: gFFI.sessionId,
                                name: 'is_single_app_mode',
                                value: 'Y',
                              );
                              gFFI.canvasModel.updateViewStyle(force: true);
                              BotToast.showText(
                                text: localeName.startsWith('zh')
                                    ? '已切至: $displayName (${targetW}x$targetH)'
                                    : 'Switched to $displayName (${targetW}x$targetH)',
                              );
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 36,
                              height: 36,
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 3, vertical: 2),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0x3D00E5FF)
                                    : const Color(0x1FFFFFFF),
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: isSelected
                                      ? Colors.cyanAccent
                                      : const Color(0x33FFFFFF),
                                  width: isSelected ? 1.4 : 0.6,
                                ),
                                boxShadow: isSelected
                                    ? [
                                        BoxShadow(
                                          color: Colors.cyanAccent.withOpacity(0.35),
                                          blurRadius: 5,
                                          offset: const Offset(0, 1),
                                        )
                                      ]
                                    : [
                                        const BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 2,
                                          offset: Offset(0, 1),
                                        )
                                      ],
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  appIconWidget,
                                  if (isSelected)
                                    Positioned(
                                      bottom: 1,
                                      child: Container(
                                        width: 4,
                                        height: 4,
                                        decoration: const BoxDecoration(
                                          color: Colors.cyanAccent,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            // Right compact action menu
            PopupMenuButton<String>(
              icon:
                  const Icon(Icons.more_vert, color: Colors.white70, size: 20),
              tooltip: localeName.startsWith('zh') ? '更多选项' : 'More Options',
              color: const Color(0xEE1E2633),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0x33FFFFFF), width: 0.8),
              ),
              onSelected: (val) async {
                if (val == 'refresh') {
                  bind.sessionPeerOption(
                    sessionId: gFFI.sessionId,
                    name: 'get_window_list',
                    value: '',
                  );
                  BotToast.showText(
                    text: localeName.startsWith('zh')
                        ? '正在刷新程序列表...'
                        : 'Refreshing apps...',
                  );
                } else if (val == 'tune') {
                  _showSingleAppAdjustSheet(context);
                } else if (val == 'exit') {
                  await bind.sessionPeerOption(
                    sessionId: gFFI.sessionId,
                    name: 'select_window',
                    value: '0',
                  );
                  gFFI.ffiModel.pi.platformAdditions['selected_window'] = 0;
                  gFFI.canvasModel.isSingleAppMode = false;
                  await bind.sessionPeerOption(
                    sessionId: gFFI.sessionId,
                    name: 'is_single_app_mode',
                    value: 'N',
                  );
                  await gFFI.canvasModel.updateViewStyle(force: true);
                  BotToast.showText(
                    text: localeName.startsWith('zh')
                        ? '已退出单程序模式'
                        : 'Exited single app mode',
                  );
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'refresh',
                  child: Row(
                    children: [
                      const Icon(Icons.refresh,
                          color: Colors.cyanAccent, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        localeName.startsWith('zh') ? '刷新程序列表' : 'Refresh Apps',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'tune',
                  child: Row(
                    children: [
                      const Icon(Icons.tune,
                          color: Colors.amberAccent, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        localeName.startsWith('zh')
                            ? '视口与裁剪微调'
                            : 'Edge Crop & Viewport',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const PopupMenuDivider(height: 1),
                PopupMenuItem(
                  value: 'exit',
                  child: Row(
                    children: [
                      const Icon(Icons.fullscreen,
                          color: Colors.redAccent, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        localeName.startsWith('zh')
                            ? '退出单程序 (全屏桌面)'
                            : 'Exit Single App (Desktop)',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }

  IconData _resolveAppIcon(String name, String title) {
    final lower = (name + title).toLowerCase();
    if (lower.contains('wechat') || lower.contains('weixin')) {
      return Icons.chat_bubble_rounded;
    }
    if (lower.contains('code') ||
        lower.contains('studio') ||
        lower.contains('idea') ||
        lower.contains('pycharm')) {
      return Icons.code_rounded;
    }
    if (lower.contains('chrome') ||
        lower.contains('edge') ||
        lower.contains('firefox') ||
        lower.contains('browser')) {
      return Icons.public_rounded;
    }
    if (lower.contains('explorer') || lower.contains('file')) {
      return Icons.folder_rounded;
    }
    if (lower.contains('term') ||
        lower.contains('cmd') ||
        lower.contains('powershell') ||
        lower.contains('wt')) {
      return Icons.terminal_rounded;
    }
    if (lower.contains('qq')) {
      return Icons.forum_rounded;
    }
    if (lower.contains('music') ||
        lower.contains('spotify') ||
        lower.contains('cloudmusic')) {
      return Icons.music_note_rounded;
    }
    if (lower.contains('word') ||
        lower.contains('excel') ||
        lower.contains('powerpnt') ||
        lower.contains('wps')) {
      return Icons.description_rounded;
    }
    return Icons.laptop_chromebook_rounded;
  }

  Color _resolveAppColor(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('wechat') || lower.contains('weixin')) {
      return const Color(0xFF07C160);
    }
    if (lower.contains('code')) {
      return const Color(0xFF007ACC);
    }
    if (lower.contains('chrome') || lower.contains('edge')) {
      return const Color(0xFF4285F4);
    }
    if (lower.contains('qq')) {
      return const Color(0xFF12B7F5);
    }
    return Colors.white70;
  }

  void _showSingleAppAdjustSheet(BuildContext context) async {
    final cm = gFFI.canvasModel;
    final appName = cm.currentSelectedAppName;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: const Color(0xFF1E2430),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final cropL = cm.appCropLeft;
            final cropT = cm.appCropTop;
            final cropR = cm.appCropRight;
            final cropB = cm.appCropBottom;

            Widget buildCropRow(String label, IconData icon, int val,
                ValueChanged<int> onChanged) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: Colors.cyanAccent),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 72,
                      child: Text(
                        label,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline,
                          size: 20, color: Colors.white70),
                      onPressed: () {
                        final n = max(0, val - 1);
                        onChanged(n);
                      },
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '$val px',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Colors.cyanAccent,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline,
                          size: 20, color: Colors.white70),
                      onPressed: () {
                        final n = min(300, val + 1);
                        onChanged(n);
                      },
                    ),
                    Expanded(
                      child: Slider(
                        value: val.toDouble().clamp(0.0, 300.0),
                        min: 0,
                        max: 300,
                        divisions: 300,
                        activeColor: Colors.cyanAccent,
                        inactiveColor: Colors.white24,
                        onChanged: (v) {
                          onChanged(v.round());
                        },
                      ),
                    ),
                  ],
                ),
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      children: [
                        const Icon(Icons.tune,
                            color: Colors.amberAccent, size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                localeName.startsWith('zh')
                                    ? '单程序微调与目标放大倍率'
                                    : 'Single App Scale & Crop',
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white),
                              ),
                              Text(
                                appName.isEmpty
                                    ? (localeName.startsWith('zh')
                                        ? '全局/默认'
                                        : 'Global Default')
                                    : (localeName.startsWith('zh')
                                        ? '程序: $appName (独立记忆)'
                                        : 'App: $appName (Per-App Memory)'),
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white24),

                    // Phone resolution & remote window size calculation
                    Text(
                      localeName.startsWith('zh')
                          ? '目标放大倍率 (全屏自动匹配)'
                          : 'Target Scale Factor (Fullscreen Auto-Fit)',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.cyanAccent),
                    ),
                    const SizedBox(height: 6),
                    // Auto-detected physical phone resolution & viewport card
                    Builder(builder: (context) {
                      final currentScale = cm.singleAppScaleOverride;
                      final dims = cm.calculateRemoteWindowTargetSize(
                          scaleOverride: currentScale);
                      final phoneW = dims['phoneW'] ?? 1260;
                      final phoneH = dims['phoneH'] ?? 2800;
                      final viewW = dims['viewW'] ?? 1260;
                      final viewH = dims['viewH'] ?? 2600;
                      final dockPx = dims['dockPx'] ?? 200;
                      final effectiveW = dims['effectiveW'] ?? 630;
                      final effectiveH = dims['effectiveH'] ?? 1300;
                      final targetW = dims['targetW'] ?? 700;
                      final targetH = dims['targetH'] ?? 1300;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0x1A00E5FF),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: const Color(0x3300E5FF), width: 0.8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.smartphone_rounded,
                                        color: Colors.cyanAccent, size: 16),
                                    const SizedBox(width: 6),
                                    Text(
                                      localeName.startsWith('zh')
                                          ? '手机物理屏幕: ${phoneW}x$phoneH'
                                          : 'Device Screen: ${phoneW}x$phoneH',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  localeName.startsWith('zh')
                                      ? '扣除底栏(${dockPx}px)可用视口: ${viewW}x$viewH'
                                      : 'Viewport (less dock ${dockPx}px): ${viewW}x$viewH',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Quick preset buttons for scale
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final s in [
                                1.0,
                                1.25,
                                1.5,
                                1.75,
                                2.0,
                                2.25,
                                2.5,
                                3.0
                              ]) ...[
                                InkWell(
                                  onTap: () async {
                                    setSheetState(() {
                                      cm.singleAppScaleOverride = s;
                                    });
                                    await cm.syncCurrentAppWindowSize(
                                        scaleOverride: s);
                                    await cm.updateViewStyle(force: true);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: (currentScale - s).abs() < 0.03
                                          ? Colors.cyanAccent
                                          : const Color(0x33FFFFFF),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: (currentScale - s).abs() < 0.03
                                            ? Colors.cyanAccent
                                            : Colors.white24,
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Text(
                                      '${s}x',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: (currentScale - s).abs() < 0.03
                                            ? Colors.black
                                            : Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Stepper for custom fine-tune scale
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline,
                                    color: Colors.cyanAccent, size: 22),
                                onPressed: () async {
                                  final newS =
                                      (currentScale - 0.1).clamp(0.8, 4.0);
                                  final roundedS =
                                      (newS * 10).round() / 10.0;
                                  setSheetState(() {
                                    cm.singleAppScaleOverride = roundedS;
                                  });
                                  await cm.syncCurrentAppWindowSize(
                                      scaleOverride: roundedS);
                                  await cm.updateViewStyle(force: true);
                                },
                              ),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 5),
                                  decoration: BoxDecoration(
                                    color: const Color(0x22FFFFFF),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '当前放大: ${currentScale.toStringAsFixed(1)}x',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.amberAccent),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline,
                                    color: Colors.cyanAccent, size: 22),
                                onPressed: () async {
                                  final newS =
                                      (currentScale + 0.1).clamp(0.8, 4.0);
                                  final roundedS =
                                      (newS * 10).round() / 10.0;
                                  setSheetState(() {
                                    cm.singleAppScaleOverride = roundedS;
                                  });
                                  await cm.syncCurrentAppWindowSize(
                                      scaleOverride: roundedS);
                                  await cm.updateViewStyle(force: true);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          // Formula explanation card
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0x1AFFFFFF),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '• 视口折算: ${viewW}x${viewH} ÷ ${currentScale.toStringAsFixed(1)}x = ${effectiveW}x${effectiveH}',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.white70),
                                ),
                                Text(
                                  '• 加上裁切(左+${cropL} 右+${cropR} 上+${cropT} 下+${cropB}) ➔ 远端设为 ${targetW}x${targetH}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.cyanAccent),
                                ),
                                Text(
                                  '• 裁切后为 ${effectiveW}x${effectiveH}，放大 ${currentScale.toStringAsFixed(1)}x 刚好铺满！',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.white60),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Action button to resize remote window
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0071FF),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              icon: const Icon(Icons.aspect_ratio, size: 18),
                              label: Text(
                                localeName.startsWith('zh')
                                    ? '🚀 同步调整远端窗口 (${targetW}x$targetH)'
                                    : 'Sync Remote Window (${targetW}x$targetH)',
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold),
                              ),
                              onPressed: () async {
                                await cm.syncCurrentAppWindowSize();
                                await cm.updateViewStyle(force: true);
                                BotToast.showText(
                                  text: localeName.startsWith('zh')
                                      ? '已同步调整远端窗口为: ${targetW}x$targetH (放大 ${currentScale.toStringAsFixed(1)}x)'
                                      : 'Resized remote window to ${targetW}x$targetH (${currentScale.toStringAsFixed(1)}x)',
                                );
                              },
                            ),
                          ),
                        ],
                      );
                    }),
                    const Divider(color: Colors.white24, height: 24),

                    // Edge crop sliders
                    Text(
                      localeName.startsWith('zh')
                          ? '四边微调裁剪 (实时生效并按程序记忆)'
                          : '4-Edge Crop (Live Preview & Per-App Memory)',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.cyanAccent),
                    ),
                    const SizedBox(height: 4),
                    buildCropRow(
                      localeName.startsWith('zh') ? '左边裁剪' : 'Left',
                      Icons.border_left,
                      cropL,
                      (n) async {
                        setSheetState(() {});
                        cm.saveAppCrop(appName, n, cropT, cropR, cropB);
                        await cm.syncCurrentAppWindowSize(customCropL: n);
                        await cm.updateViewStyle(force: true);
                      },
                    ),
                    buildCropRow(
                      localeName.startsWith('zh') ? '上边裁剪' : 'Top',
                      Icons.border_top,
                      cropT,
                      (n) async {
                        setSheetState(() {});
                        cm.saveAppCrop(appName, cropL, n, cropR, cropB);
                        await cm.syncCurrentAppWindowSize(customCropT: n);
                        await cm.updateViewStyle(force: true);
                      },
                    ),
                    buildCropRow(
                      localeName.startsWith('zh') ? '右边裁剪' : 'Right',
                      Icons.border_right,
                      cropR,
                      (n) async {
                        setSheetState(() {});
                        cm.saveAppCrop(appName, cropL, cropT, n, cropB);
                        await cm.syncCurrentAppWindowSize(customCropR: n);
                        await cm.updateViewStyle(force: true);
                      },
                    ),
                    buildCropRow(
                      localeName.startsWith('zh') ? '下边裁剪' : 'Bottom',
                      Icons.border_bottom,
                      cropB,
                      (n) async {
                        setSheetState(() {});
                        cm.saveAppCrop(appName, cropL, cropT, cropR, n);
                        await cm.syncCurrentAppWindowSize(customCropB: n);
                        await cm.updateViewStyle(force: true);
                      },
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        localeName.startsWith('zh')
                            ? '允许双指缩放画布'
                            : 'Allow Pinch Zoom Canvas',
                        style:
                            const TextStyle(fontSize: 13, color: Colors.white),
                      ),
                      subtitle: Text(
                        localeName.startsWith('zh')
                            ? '默认关闭，触屏操作时防止手势误触画面收缩'
                            : 'Disabled by default to avoid accidental zooming',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                      ),
                      value: cm.allowSingleAppZoom,
                      activeColor: Colors.cyanAccent,
                      onChanged: (val) {
                        cm.allowSingleAppZoom = val;
                        setSheetState(() {});
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.restart_alt,
                              size: 16, color: Colors.white70),
                          label: Text(
                            localeName.startsWith('zh') ? '重置微调' : 'Reset Crop',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                          ),
                          onPressed: () async {
                            cm.saveAppCrop(appName, 0, 0, 0, 0);
                            await cm.syncCurrentAppWindowSize(
                              customCropL: 0,
                              customCropT: 0,
                              customCropR: 0,
                              customCropB: 0,
                            );
                            await cm.updateViewStyle(force: true);
                            setSheetState(() {});
                          },
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.cyanAccent,
                            foregroundColor: Colors.black,
                          ),
                          child: Text(
                            localeName.startsWith('zh') ? '完成' : 'Done',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (isAndroid) {
      await gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }

  bool _isCurrentDisplayVdd() {
    final pi = gFFI.ffiModel.pi;
    if (pi.displays.isEmpty) return false;
    final cur = pi.currentDisplay;
    final vddName = pi.platformAdditions['vdd_display_name'] as String?;
    if (vddName != null && vddName.isNotEmpty) {
      if (cur >= 0 && cur < pi.displays.length) {
        return cur == pi.displays.length - 1 || cur != 0;
      }
      return true;
    }
    if (cur >= 0 && cur < pi.displays.length) {
      return pi.displays[cur].isVirtualDisplayResolution;
    }
    return false;
  }

  Widget _buildHamburgerIcon(bool isVdd) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 17,
            height: 2.2,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          const SizedBox(height: 3.2),
          Container(
            width: 17,
            height: 2.2,
            decoration: BoxDecoration(
              color: isVdd ? const Color(0xFF00E676) : Colors.white,
              borderRadius: BorderRadius.circular(1.5),
              boxShadow: isVdd
                  ? const [
                      BoxShadow(
                        color: Color(0xCC00E676),
                        blurRadius: 4,
                        spreadRadius: 0.8,
                      )
                    ]
                  : null,
            ),
          ),
          const SizedBox(height: 3.2),
          Container(
            width: 17,
            height: 2.2,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingEscKeyContent() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          gFFI.inputModel.inputKey('VK_ESCAPE');
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xBB000000),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24, width: 1.0),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Center(
            child: Text(
              'Esc',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget getBodyForDesktopWithListener() {
    final ffiModel = Provider.of<FfiModel>(context);
    var paints = <Widget>[ImagePaint(ffiModel: ffiModel)];
    if (showCursorPaint) {
      final cursor = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: 'show-remote-cursor');
      if (ffiModel.keyboard || cursor) {
        paints.add(CursorPaint(widget.id));
      }
    }
    return Container(
        color: MyTheme.canvasColor, child: Stack(children: paints));
  }

  List<TTextMenu> _getMobileActionMenus() {
    if (gFFI.ffiModel.pi.platform != kPeerPlatformAndroid ||
        !gFFI.ffiModel.keyboard) {
      return [];
    }
    final enabled = versionCmp(gFFI.ffiModel.pi.version, '1.2.7') >= 0;
    if (!enabled) return [];
    return [
      TTextMenu(
        child: Text(translate('Back')),
        onPressed: () => gFFI.inputModel.onMobileBack(),
      ),
      TTextMenu(
        child: Text(translate('Home')),
        onPressed: () => gFFI.inputModel.onMobileHome(),
      ),
      TTextMenu(
        child: Text(translate('Apps')),
        onPressed: () => gFFI.inputModel.onMobileApps(),
      ),
      TTextMenu(
        child: Text(translate('Volume up')),
        onPressed: () => gFFI.inputModel.onMobileVolumeUp(),
      ),
      TTextMenu(
        child: Text(translate('Volume down')),
        onPressed: () => gFFI.inputModel.onMobileVolumeDown(),
      ),
      TTextMenu(
        child: Text(translate('Power')),
        onPressed: () => gFFI.inputModel.onMobilePower(),
      ),
    ];
  }

  void showActions(String id) async {
    final size = MediaQuery.of(context).size;
    final x = 120.0;
    final y = size.height;
    final mobileActionMenus = _getMobileActionMenus();
    final menus = toolbarControls(context, id, gFFI);
    final chatMenus = !isWeb
        ? [
            TTextMenu(
              child: Text(translate('Chat')),
              trailingIcon: Transform.scale(
                scale: (isDesktop || isWebDesktop) ? 0.8 : 1,
                child: IgnorePointer(
                  child: IconButton(
                    onPressed: null,
                    icon: Icon(Icons.chat_outlined, color: MyTheme.accent),
                  ),
                ),
              ),
              onPressed: () => isAndroid
                  ? showChatOptions(widget.id)
                  : onPressedTextChat(widget.id),
            )
          ]
        : <TTextMenu>[];

    final allMenus = [
      ...mobileActionMenus,
      ...chatMenus,
      ...menus,
    ];

    final List<PopupMenuEntry<int>> more = [];
    int idx = 0;
    if (mobileActionMenus.isNotEmpty) {
      for (final m in mobileActionMenus) {
        more.add(PopupMenuItem<int>(child: m.getChild(), value: idx++));
      }
      more.add(const PopupMenuDivider());
    }
    if (chatMenus.isNotEmpty) {
      for (final m in chatMenus) {
        more.add(PopupMenuItem<int>(child: m.getChild(), value: idx++));
      }
      more.add(const PopupMenuDivider());
    }
    for (final m in menus) {
      more.add(PopupMenuItem<int>(child: m.getChild(), value: idx++));
    }

    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(x, y, x, y),
      items: more,
      elevation: 8,
    );
    if (selected != null && selected >= 0 && selected < allMenus.length) {
      allMenus[selected].onPressed?.call();
    }
  }

  onPressedTextChat(String id) {
    gFFI.chatModel.changeCurrentKey(MessageKey(id, ChatModel.clientModeID));
    gFFI.chatModel.toggleChatOverlay();
  }

  showChatOptions(String id) async {
    onPressVoiceCall() => bind.sessionRequestVoiceCall(sessionId: sessionId);
    onPressEndVoiceCall() => bind.sessionCloseVoiceCall(sessionId: sessionId);

    makeTextMenu(String label, Widget icon, VoidCallback onPressed,
            {TextStyle? labelStyle}) =>
        TTextMenu(
          child: Text(translate(label), style: labelStyle),
          trailingIcon: Transform.scale(
            scale: (isDesktop || isWebDesktop) ? 0.8 : 1,
            child: IgnorePointer(
              child: IconButton(
                onPressed: null,
                icon: icon,
              ),
            ),
          ),
          onPressed: onPressed,
        );

    final isInVoice = [
      VoiceCallStatus.waitingForResponse,
      VoiceCallStatus.connected
    ].contains(gFFI.chatModel.voiceCallStatus.value);
    final menus = [
      makeTextMenu('Text chat', Icon(Icons.message, color: MyTheme.accent),
          () => onPressedTextChat(widget.id)),
      isInVoice
          ? makeTextMenu(
              'End voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter:
                    ColorFilter.mode(Colors.redAccent, BlendMode.srcIn),
              ),
              onPressEndVoiceCall,
              labelStyle: TextStyle(color: Colors.redAccent))
          : makeTextMenu(
              'Voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter: ColorFilter.mode(MyTheme.accent, BlendMode.srcIn),
              ),
              onPressVoiceCall),
    ];

    final menuItems = menus
        .asMap()
        .entries
        .map((e) => PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
        .toList();
    Future.delayed(Duration.zero, () async {
      final size = MediaQuery.of(context).size;
      final x = 120.0;
      final y = size.height;
      var index = await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(x, y, x, y),
        items: menuItems,
        elevation: 8,
      );
      if (index != null && index < menus.length) {
        menus[index].onPressed?.call();
      }
    });
  }

  /// aka changeTouchMode
  BottomAppBar getGestureHelp() {
    return BottomAppBar(
        child: SingleChildScrollView(
            controller: ScrollController(),
            padding: EdgeInsets.symmetric(vertical: 10),
            child: GestureHelp(
              touchMode: gFFI.ffiModel.touchMode,
              onClose: () => setState(() => _showGestureHelp = false),
              onTouchModeChange: (t) {
                if (gFFI.ffiModel.touchMode != t) {
                  gFFI.ffiModel.toggleTouchMode();
                  final v = gFFI.ffiModel.touchMode ? 'Y' : 'N';
                  bind.mainSetLocalOption(key: kOptionTouchMode, value: v);
                }
              },
              virtualMouseMode: gFFI.ffiModel.virtualMouseMode,
              inputModel: gFFI.inputModel,
            )));
  }

  // * Currently mobile does not enable map mode
  // void changePhysicalKeyboardInputMode() async {
  //   var current = await bind.sessionGetKeyboardMode(id: widget.id) ?? "legacy";
  //   gFFI.dialogManager.show((setState, close) {
  //     void setMode(String? v) async {
  //       await bind.sessionSetKeyboardMode(id: widget.id, value: v ?? "");
  //       setState(() => current = v ?? '');
  //       Future.delayed(Duration(milliseconds: 300), close);
  //     }
  //
  //     return CustomAlertDialog(
  //         title: Text(translate('Physical Keyboard Input Mode')),
  //         content: Column(mainAxisSize: MainAxisSize.min, children: [
  //           getRadio('Legacy mode', 'legacy', current, setMode),
  //           getRadio('Map mode', 'map', current, setMode),
  //         ]));
  //   }, clickMaskDismiss: true);
  // }
}

class KeyHelpTools extends StatefulWidget {
  final bool isTablet;
  final bool showBar;
  final bool keyboardIsVisible;
  final bool showGestureHelp;
  final bool embedded;
  final bool? collapsed;
  final ValueChanged<bool>? onCollapseToggle;
  final ValueChanged<bool>? onExpandToggle;

  KeyHelpTools({
    this.isTablet = false,
    this.showBar = true,
    required this.keyboardIsVisible,
    required this.showGestureHelp,
    this.embedded = false,
    this.collapsed,
    this.onCollapseToggle,
    this.onExpandToggle,
  });

  @override
  State<KeyHelpTools> createState() => _KeyHelpToolsState();
}

class _KeyHelpToolsState extends State<KeyHelpTools> {
  var _fn = false;
  late bool _collapsed;
  final _key = GlobalKey();

  // Collapsed floating button position
  Offset _collapsedPos = Offset.zero;
  bool _isCollapsedPosInit = false;
  Offset _preSavedCollapsedPos = Offset.zero;
  bool _isCollapsedDragging = false;
  Offset _collapsedDragStartPos = Offset.zero;

  // Expanded floating panel position
  Offset? _panelPos;
  bool _isPanelDragging = false;
  Offset _panelDragStartFinger = Offset.zero;
  Offset _panelDragStartPos = Offset.zero;

  Orientation? _previousOrientation;

  @override
  void didUpdateWidget(KeyHelpTools oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.collapsed != null && widget.collapsed != oldWidget.collapsed) {
      _collapsed = widget.collapsed!;
    }
  }

  @override
  void initState() {
    super.initState();
    _collapsed = widget.collapsed ??
        (bind.mainGetLocalOption(key: 'key_help_tools_collapsed') == 'Y');
    if (widget.onExpandToggle != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onExpandToggle!(_fn);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final currentOrientation = MediaQuery.of(context).orientation;
        _previousOrientation = currentOrientation;
        _loadPositions(currentOrientation);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentOrientation = MediaQuery.of(context).orientation;
    if (_previousOrientation == null ||
        _previousOrientation != currentOrientation) {
      _previousOrientation = currentOrientation;
      _loadPositions(currentOrientation);
    }
  }

  @override
  void dispose() {
    _trySaveCollapsedPos();
    _savePanelPos();
    super.dispose();
  }

  String _getCollapsedPosKey(Orientation ori) {
    final strOri = ori == Orientation.landscape ? 'l' : 'p';
    return 'kht-$strOri-pos';
  }

  String _getPanelPosKey(Orientation ori) {
    final strOri = ori == Orientation.landscape ? 'l' : 'p';
    return 'kht-panel-$strOri-pos';
  }

  static Offset? _loadOffset(String s) {
    if (s.isEmpty) return null;
    try {
      final parts = s.split(',');
      if (parts.length == 2) {
        return Offset(double.parse(parts[0]), double.parse(parts[1]));
      }
      final m = jsonDecode(s);
      return Offset((m['x'] as num).toDouble(), (m['y'] as num).toDouble());
    } catch (_) {
      return null;
    }
  }

  void _loadPositions(Orientation ori) {
    final cs = bind.getLocalFlutterOption(k: _getCollapsedPosKey(ori));
    final cp = _loadOffset(cs);
    if (cp != null) {
      _collapsedPos = cp;
      _preSavedCollapsedPos = cp;
      _isCollapsedPosInit = true;
    } else {
      final size = MediaQuery.of(context).size;
      _collapsedPos = Offset(max(0.0, size.width - 64 - 10), 10);
      _isCollapsedPosInit = true;
    }

    final ps = bind.getLocalFlutterOption(k: _getPanelPosKey(ori));
    _panelPos = _loadOffset(ps);
    setState(() {});
  }

  void _trySaveCollapsedPos() {
    if (_previousOrientation == null) return;
    if ((_collapsedPos - _preSavedCollapsedPos).distanceSquared < 0.1) return;
    bind.setLocalFlutterOption(
      k: _getCollapsedPosKey(_previousOrientation!),
      v: '${_collapsedPos.dx},${_collapsedPos.dy}',
    );
    _preSavedCollapsedPos = _collapsedPos;
  }

  void _savePanelPos() {
    if (_previousOrientation == null || _panelPos == null) return;
    bind.setLocalFlutterOption(
      k: _getPanelPosKey(_previousOrientation!),
      v: '${_panelPos!.dx},${_panelPos!.dy}',
    );
  }

  InputModel get inputModel => gFFI.inputModel;

  void _sendWinShiftArrow(bool left) {
    final oldWin = inputModel.command;
    final oldShift = inputModel.shift;
    inputModel.command = true;
    inputModel.shift = true;
    inputModel.inputKey(left ? 'VK_LEFT' : 'VK_RIGHT');
    inputModel.command = oldWin;
    inputModel.shift = oldShift;
  }

  Widget _moveToScreenIcon(bool left) {
    return Stack(
      alignment: Alignment.center,
      children: [
        const Icon(Icons.web_asset, size: 18, color: Colors.white70),
        Positioned(
          left: left ? 1 : null,
          right: left ? null : 1,
          child: Icon(
            left ? Icons.arrow_back_ios : Icons.arrow_forward_ios,
            size: 10,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _comboKeyChild(IconData icon, String sub) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.white),
        Text(
          sub,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 8,
            height: 1.0,
          ),
        ),
      ],
    );
  }

  Widget _buildKeycap({
    required double width,
    required double height,
    String? label,
    IconData? icon,
    Widget? customChild,
    required VoidCallback onTap,
    bool active = false,
    bool isDragHandle = false,
    Offset curPanelPos = Offset.zero,
    Size screenSize = Size.zero,
    double panelW = 0,
    double panelH = 0,
    String? tooltip,
  }) {
    final itemBody = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: active ? const Color(0xFF1976D2) : const Color(0x38FFFFFF),
        borderRadius: BorderRadius.circular(4.0),
        border: Border.all(
          color: active ? Colors.lightBlueAccent : Colors.white24,
          width: 0.5,
        ),
      ),
      child: Center(
        child: customChild ??
            (icon != null
                ? Icon(icon, size: 17, color: Colors.white)
                : Text(
                    translate(label ?? ''),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: (label?.length ?? 0) > 3 ? 10 : 12,
                      fontWeight: FontWeight.w600,
                    ),
                  )),
      ),
    );

    Widget result;
    if (isDragHandle) {
      result = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _panelDragStartFinger = event.position;
          _panelDragStartPos = curPanelPos;
          _isPanelDragging = false;
        },
        onPointerMove: (event) {
          final delta = event.position - _panelDragStartFinger;
          if (!_isPanelDragging && delta.distance > 4.0) {
            _isPanelDragging = true;
          }
          if (_isPanelDragging) {
            final newPos = Offset(
              (_panelDragStartPos.dx + delta.dx)
                  .clamp(0.0, max(0.0, screenSize.width - panelW)),
              (_panelDragStartPos.dy + delta.dy)
                  .clamp(0.0, max(0.0, screenSize.height - panelH)),
            );
            setState(() {
              _panelPos = newPos;
            });
          }
        },
        onPointerUp: (event) {
          if (_isPanelDragging) {
            _savePanelPos();
            _isPanelDragging = false;
          } else {
            onTap();
          }
        },
        onPointerCancel: (_) {
          if (_isPanelDragging) _savePanelPos();
          _isPanelDragging = false;
        },
        child: itemBody,
      );
    } else {
      result = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(4.0),
          onTap: onTap,
          child: itemBody,
        ),
      );
    }

    if (tooltip != null && tooltip.isNotEmpty) {
      return Tooltip(message: tooltip, child: result);
    }
    return result;
  }

  void _updateRect() {
    RenderObject? renderObject = _key.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      final size = renderObject.size;
      Offset pos = renderObject.localToGlobal(Offset.zero);
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
        Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
        widget.keyboardIsVisible,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.embedded && _collapsed) {
      gFFI.cursorModel
          .keyHelpToolsVisibilityChanged(null, widget.keyboardIsVisible);
      return const SizedBox.shrink();
    }

    final size = MediaQuery.of(context).size;
    final isMac = gFFI.ffiModel.pi.platform == kPeerPlatformMacOS;
    final ctrlLabel = isMac ? 'Cmd' : 'Ctrl';

    const gap = 2.0;
    final isNarrow = size.width < (14 * 36.0 + 13 * gap + 24.0);
    final cols = isNarrow ? 7 : 14;
    final itemW = isNarrow
        ? ((min(size.width - 20.0, 420.0) - (cols - 1) * gap) / cols)
            .clamp(34.0, 48.0)
        : 36.0;
    const itemH = 34.0;
    final totalGridW = cols * itemW + (cols - 1) * gap;
    final rowsCount = isNarrow ? 4 : 2;
    final fnRowsCount = _fn ? 2 : 0;
    final ctrlRowsCount = inputModel.ctrl ? 3 : 0;
    final totalRows = rowsCount + fnRowsCount + ctrlRowsCount;
    final totalGridH = totalRows * itemH + (totalRows - 1) * gap;
    final totalPanelW = totalGridW + 12.0;
    final totalPanelH = totalGridH + 24.0;

    final defaultPos = Offset(
      max(0.0, (size.width - totalPanelW) / 2),
      max(0.0, size.height - totalPanelH - 65.0),
    );
    final curPos = _panelPos != null
        ? Offset(
            _panelPos!.dx.clamp(0.0, max(0.0, size.width - totalPanelW)),
            _panelPos!.dy.clamp(0.0, max(0.0, size.height - totalPanelH)),
          )
        : defaultPos;

    // Helper to build keycap passing dimensions and panel info
    Widget k({
      String? label,
      IconData? icon,
      Widget? customChild,
      required VoidCallback onTap,
      bool active = false,
      bool isDragHandle = false,
      String? tooltip,
    }) {
      return _buildKeycap(
        width: itemW,
        height: itemH,
        label: label,
        icon: icon,
        customChild: customChild,
        onTap: onTap,
        active: active,
        isDragHandle: isDragHandle,
        curPanelPos: curPos,
        screenSize: size,
        panelW: totalPanelW,
        panelH: totalPanelH,
        tooltip: tooltip,
      );
    }

    // Key definitions
    final kEsc = k(label: 'Esc', onTap: () => inputModel.inputKey('VK_ESCAPE'));
    final kHome = k(
        icon: Icons.first_page,
        tooltip: 'Home',
        onTap: () => inputModel.inputKey('VK_HOME'));
    final kUp = k(
        icon: Icons.arrow_upward,
        tooltip: 'Up',
        onTap: () => inputModel.inputKey('VK_UP'));
    final kEnd = k(
        icon: Icons.last_page,
        tooltip: 'End',
        onTap: () => inputModel.inputKey('VK_END'));
    final kCtrlS = k(
        customChild: _comboKeyChild(Icons.save_outlined, '$ctrlLabel+S'),
        tooltip: '$ctrlLabel+S',
        onTap: () => sendPrompt(isMac, 'VK_S'));
    final kCtrlC = k(
        customChild: _comboKeyChild(Icons.copy_all, '$ctrlLabel+C'),
        tooltip: '$ctrlLabel+C',
        onTap: () => sendPrompt(isMac, 'VK_C'));
    final kCtrlX = k(
        customChild: _comboKeyChild(Icons.content_cut, '$ctrlLabel+X'),
        tooltip: '$ctrlLabel+X',
        onTap: () => sendPrompt(isMac, 'VK_X'));

    final kTab = k(
        icon: Icons.keyboard_tab,
        tooltip: 'Tab',
        onTap: () => inputModel.inputKey('VK_TAB'));
    final kLeft = k(
        icon: Icons.arrow_back,
        tooltip: 'Left',
        onTap: () => inputModel.inputKey('VK_LEFT'));
    final kDown = k(
        icon: Icons.arrow_downward,
        tooltip: 'Down',
        onTap: () => inputModel.inputKey('VK_DOWN'));
    final kRight = k(
        icon: Icons.arrow_forward,
        tooltip: 'Right',
        onTap: () => inputModel.inputKey('VK_RIGHT'));
    final kEnter = k(
        icon: Icons.keyboard_return,
        tooltip: 'Enter',
        onTap: () => inputModel.inputKey('VK_ENTER'));
    final kCtrlEnter = k(
        customChild: _comboKeyChild(Icons.keyboard_return, '^Enter'),
        tooltip: '$ctrlLabel+Enter',
        onTap: () => sendPrompt(isMac, 'VK_ENTER'));
    final kCtrlV = k(
        customChild: _comboKeyChild(Icons.content_paste, '$ctrlLabel+V'),
        tooltip: '$ctrlLabel+V',
        onTap: () => sendPrompt(isMac, 'VK_V'));

    final kPgUp = k(
        icon: Icons.keyboard_double_arrow_up,
        tooltip: 'Page up',
        onTap: () => inputModel.inputKey('VK_PRIOR'));
    final kAlt = k(
        label: 'Alt',
        active: inputModel.alt,
        onTap: () => setState(() => inputModel.alt = !inputModel.alt));
    final kShift = k(
        label: 'Shift',
        active: inputModel.shift,
        onTap: () => setState(() => inputModel.shift = !inputModel.shift));
    final kIns = k(
        label: 'Ins',
        tooltip: 'Insert',
        onTap: () => inputModel.inputKey('VK_INSERT'));
    final kDel = k(
        icon: Icons.delete_outline,
        tooltip: 'Delete',
        onTap: () => inputModel.inputKey('VK_DELETE'));
    final kPrint = k(
        customChild: _comboKeyChild(Icons.camera_alt_outlined, 'Print'),
        tooltip: 'PrintScreen',
        onTap: () => inputModel.inputKey('VK_SNAPSHOT'));

    final kPgDn = k(
        icon: Icons.keyboard_double_arrow_down,
        tooltip: 'Page down',
        onTap: () => inputModel.inputKey('VK_NEXT'));
    final kCtrl = k(
        label: 'Ctrl',
        active: inputModel.ctrl,
        onTap: () => setState(() => inputModel.ctrl = !inputModel.ctrl));
    final kWin = k(
        icon: Icons.window,
        active: inputModel.command,
        tooltip: 'Win',
        onTap: () => setState(() => inputModel.command = !inputModel.command));
    final kFn = k(
        label: 'Fn',
        active: _fn,
        tooltip: 'Fn (F1-F12)',
        onTap: () => setState(() {
              _fn = !_fn;
              widget.onExpandToggle?.call(_fn);
            }));
    final kBack = k(
        icon: Icons.backspace_outlined,
        tooltip: 'Backspace',
        onTap: () => inputModel.inputKey('VK_BACK'));

    final kMoveScreenLeft = k(
      customChild: _moveToScreenIcon(true),
      tooltip: 'Win + Shift + Left',
      onTap: () => _sendWinShiftArrow(true),
    );
    final kMoveScreenRight = k(
      customChild: _moveToScreenIcon(false),
      tooltip: 'Win + Shift + Right',
      onTap: () => _sendWinShiftArrow(false),
    );

    final kHide = k(
      icon: Icons.keyboard_hide,
      tooltip: 'Hide (Drag to move)',
      isDragHandle: true,
      onTap: () {
        setState(() {
          _collapsed = true;
          widget.onCollapseToggle?.call(true);
          bind.mainSetLocalOption(key: 'key_help_tools_collapsed', value: 'Y');
        });
      },
    );

    final List<List<Widget>> gridRows;
    if (isNarrow) {
      gridRows = [
        [kEsc, kHome, kUp, kEnd, kCtrlS, kCtrlC, kCtrlX],
        [kTab, kLeft, kDown, kRight, kEnter, kCtrlEnter, kCtrlV],
        [kPgUp, kAlt, kShift, kIns, kDel, kPrint, kMoveScreenLeft],
        [kPgDn, kCtrl, kWin, kFn, kBack, kMoveScreenRight, kHide],
      ];
    } else {
      gridRows = [
        [
          kEsc,
          kHome,
          kUp,
          kEnd,
          kCtrlS,
          kCtrlC,
          kCtrlX,
          kPgUp,
          kAlt,
          kShift,
          kIns,
          kDel,
          kPrint,
          kMoveScreenLeft
        ],
        [
          kTab,
          kLeft,
          kDown,
          kRight,
          kEnter,
          kCtrlEnter,
          kCtrlV,
          kPgDn,
          kCtrl,
          kWin,
          kFn,
          kBack,
          kMoveScreenRight,
          kHide
        ],
      ];
    }

    final fnKeys = <Widget>[
      for (var i = 1; i <= 12; ++i)
        k(label: 'F$i', onTap: () => inputModel.inputKey('VK_F$i')),
    ];

    final qwertyKeyW =
        isNarrow ? ((totalGridW - 9 * gap) / 10).clamp(24.0, itemW) : itemW;
    Widget qKey(String letter) {
      return _buildKeycap(
        width: qwertyKeyW,
        height: itemH,
        label: letter,
        onTap: () => inputModel.inputKey('VK_$letter'),
        curPanelPos: curPos,
        screenSize: size,
        panelW: totalPanelW,
        panelH: totalPanelH,
      );
    }

    const qwertyRow1 = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'];
    const qwertyRow2 = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'];
    const qwertyRow3 = ['Z', 'X', 'C', 'V', 'B', 'N', 'M'];

    Future.delayed(const Duration(milliseconds: 500), () {
      _updateRect();
    });

    final isHighRes = size.width > 2560;
    final panel = Container(
      key: _key,
      width: totalPanelW,
      decoration: BoxDecoration(
        color: (isHighRes || widget.embedded)
            ? Colors.transparent
            : const Color(0xE61E1E26),
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: Colors.white24, width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 10.0,
            offset: Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 5.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.embedded)
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                _panelDragStartFinger = event.position;
                _panelDragStartPos = curPos;
                _isPanelDragging = false;
              },
              onPointerMove: (event) {
                final delta = event.position - _panelDragStartFinger;
                if (!_isPanelDragging && delta.distance > 4.0) {
                  _isPanelDragging = true;
                }
                if (_isPanelDragging) {
                  final newPos = Offset(
                    (_panelDragStartPos.dx + delta.dx)
                        .clamp(0.0, max(0.0, size.width - totalPanelW)),
                    (_panelDragStartPos.dy + delta.dy)
                        .clamp(0.0, max(0.0, size.height - totalPanelH)),
                  );
                  setState(() {
                    _panelPos = newPos;
                  });
                }
              },
              onPointerUp: (event) {
                if (_isPanelDragging) {
                  _savePanelPos();
                  _isPanelDragging = false;
                }
              },
              onPointerCancel: (_) {
                if (_isPanelDragging) _savePanelPos();
                _isPanelDragging = false;
              },
              child: Container(
                width: double.infinity,
                height: 10.0,
                alignment: Alignment.center,
                child: Container(
                  width: 32.0,
                  height: 3.0,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2.0),
                  ),
                ),
              ),
            ),
          if (!widget.embedded) const SizedBox(height: 3.0),
          for (var r = 0; r < gridRows.length; r++) ...[
            if (r > 0) const SizedBox(height: gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var c = 0; c < gridRows[r].length; c++) ...[
                  if (c > 0) const SizedBox(width: gap),
                  gridRows[r][c],
                ],
              ],
            ),
          ],
          if (inputModel.ctrl) ...[
            const SizedBox(height: gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < qwertyRow1.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  qKey(qwertyRow1[i]),
                ],
              ],
            ),
            const SizedBox(height: gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < qwertyRow2.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  qKey(qwertyRow2[i]),
                ],
              ],
            ),
            const SizedBox(height: gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < qwertyRow3.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  qKey(qwertyRow3[i]),
                ],
              ],
            ),
          ],
          if (_fn) ...[
            const SizedBox(height: gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 6; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  fnKeys[i],
                ],
              ],
            ),
            const SizedBox(height: gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 6; i < 12; i++) ...[
                  if (i > 6) const SizedBox(width: gap),
                  fnKeys[i],
                ],
              ],
            ),
          ],
        ],
      ),
    );

    if (widget.embedded) return panel;

    return Positioned(
      left: curPos.dx,
      top: curPos.dy,
      child: panel,
    );
  }
}

class ImagePaint extends StatelessWidget {
  final FfiModel ffiModel;
  ImagePaint({Key? key, required this.ffiModel}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    final c = Provider.of<CanvasModel>(context);
    var s = c.scale;
    if (s <= 0 || s.isNaN || s.isInfinite) {
      s = 1.0;
    }
    if (ffiModel.isPeerLinux) {
      final displays = ffiModel.pi.getCurDisplays();
      if (displays.isNotEmpty && displays[0].scale > 0) {
        s = s / displays[0].scale;
      }
    }
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
          image: m.image, x: c.x / s, y: (c.y + adjust) / s, scale: s),
    );
  }
}

class CursorPaint extends StatelessWidget {
  late final String id;
  CursorPaint(this.id);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<CursorModel>(context);
    final c = Provider.of<CanvasModel>(context);
    final ffiModel = Provider.of<FfiModel>(context);
    final s = c.scale;
    double hotx = m.hotx;
    double hoty = m.hoty;
    var image = m.image;
    if (image == null) {
      if (preDefaultCursor.image != null) {
        image = preDefaultCursor.image;
        hotx = preDefaultCursor.image!.width / 2;
        hoty = preDefaultCursor.image!.height / 2;
      }
    }
    if (preForbiddenCursor.image != null &&
        !ffiModel.viewOnly &&
        !ffiModel.keyboard &&
        !ShowRemoteCursorState.find(id).value) {
      image = preForbiddenCursor.image;
      hotx = preForbiddenCursor.image!.width / 2;
      hoty = preForbiddenCursor.image!.height / 2;
    }
    if (image == null) {
      return Offstage();
    }

    final minSize = 12.0;
    double mins =
        minSize / (image.width > image.height ? image.width : image.height);
    double factor = 1.0;
    if (s < mins) {
      factor = s / mins;
    }
    final s2 = s < mins ? mins : s;
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
          image: image,
          x: (m.x - hotx) * factor + c.x / s2,
          y: (m.y - hoty) * factor + (c.y + adjust) / s2,
          scale: s2),
    );
  }
}

void showOptions(
    BuildContext context, String id, OverlayDialogManager dialogManager) async {
  final isZh = localeName.startsWith('zh');
  _autoPopupKeyboardOnText.value =
      bind.mainGetLocalOption(key: 'auto_popup_keyboard_on_text') == 'true';
  _keyboardPopupMode.value =
      bind.mainGetLocalOption(key: 'keyboard_popup_mode');
  if (_keyboardPopupMode.value.isEmpty) {
    _keyboardPopupMode.value = 'tap';
  }
  _keyboardCursorMargin.value = (double.tryParse(
          bind.mainGetLocalOption(key: 'keyboard_cursor_margin')) ??
      30.0);
  _keyboardDismissMode.value =
      bind.mainGetLocalOption(key: 'keyboard_dismiss_mode');
  if (_keyboardDismissMode.value.isEmpty) {
    _keyboardDismissMode.value = 'any';
  }
  _keyboardPopupDelayMs.value =
      (int.tryParse(bind.mainGetLocalOption(key: 'keyboard_popup_delay_ms')) ??
          200);
  var displays = <Widget>[];
  final pi = gFFI.ffiModel.pi;
  final image = gFFI.ffiModel.getConnectionImageText();
  if (image != null) {
    displays.add(Padding(padding: const EdgeInsets.only(top: 8), child: image));
  }
  if (pi.displays.length > 1 && pi.currentDisplay != kAllDisplayValue) {
    final cur = pi.currentDisplay;
    final children = <Widget>[];
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    final numColorSelected = Colors.white;
    final numColorUnselected = isDarkTheme ? Colors.grey : Colors.black87;
    // We can't use `Theme.of(context).primaryColor` here, the color is:
    // - light theme: 0xff2196f3 (Colors.blue)
    // - dark theme: 0xff212121 (the canvas color?)
    final numBgSelected =
        Theme.of(context).colorScheme.primary.withOpacity(0.6);
    for (var i = 0; i < pi.displays.length; ++i) {
      children.add(InkWell(
          onTap: () {
            if (i == cur) return;
            openMonitorInTheSameTab(i, gFFI, pi);
            gFFI.dialogManager.dismissAll();
          },
          child: Ink(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).hintColor),
                  borderRadius: BorderRadius.circular(2),
                  color: i == cur ? numBgSelected : null),
              child: Center(
                  child: Text((i + 1).toString(),
                      style: TextStyle(
                          color:
                              i == cur ? numColorSelected : numColorUnselected,
                          fontWeight: FontWeight.bold))))));
    }
    displays.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: children,
        )));
  }
  if (displays.isNotEmpty) {
    displays.add(const Divider(color: MyTheme.border));
  }

  List<TRadioMenu<String>> viewStyleRadios =
      await toolbarViewStyle(context, id, gFFI);
  List<TRadioMenu<String>> imageQualityRadios =
      await toolbarImageQuality(context, id, gFFI);
  List<TRadioMenu<String>> codecRadios = await toolbarCodec(context, id, gFFI);
  List<TToggleMenu> cursorToggles = await toolbarCursor(context, id, gFFI);
  List<TToggleMenu> displayToggles =
      await toolbarDisplayToggle(context, id, gFFI);

  List<TToggleMenu> privacyModeList = [];
  // privacy mode
  final privacyModeState = PrivacyModeState.find(id);
  if ((gFFI.ffiModel.pi.features.privacyMode && gFFI.ffiModel.keyboard) ||
      privacyModeState.isNotEmpty) {
    privacyModeList = toolbarPrivacyMode(privacyModeState, context, id, gFFI);
    if (privacyModeList.length == 1) {
      displayToggles.add(privacyModeList[0]);
    }
  }

  dialogManager.show((setState, close, context) {
    final resolution = getResolutionMenu(context, gFFI, id);
    final phonePortraitMenu =
        getPhonePortraitVirtualDisplayMenu(context, gFFI, id);
    final virtualDisplayMenu = getVirtualDisplayMenu(gFFI, id);

    var viewStyle =
        (viewStyleRadios.isNotEmpty ? viewStyleRadios[0].groupValue : '').obs;
    var imageQuality =
        (imageQualityRadios.isNotEmpty ? imageQualityRadios[0].groupValue : '')
            .obs;
    var codec = (codecRadios.isNotEmpty ? codecRadios[0].groupValue : '').obs;
    final isI444Enabled = (bind.sessionGetToggleOptionSync(
                sessionId: gFFI.sessionId, arg: 'i444') ||
            bind.mainGetPeerOptionSync(id: id, key: 'i444') == 'Y')
        .obs;

    TRadioMenu<String>? findRadio(List<TRadioMenu<String>> list, String val) {
      for (final e in list) {
        if (e.value == val) return e;
      }
      return null;
    }

    Widget buildSegmentButton({
      required String text,
      required bool selected,
      bool enabled = true,
      required VoidCallback onTap,
    }) {
      final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
      final primary = Theme.of(context).colorScheme.primary;
      final numColorSelected = Colors.white;
      final numColorUnselected = isDarkTheme ? Colors.white70 : Colors.black87;
      final numColorDisabled = isDarkTheme ? Colors.white24 : Colors.black26;

      final numBgSelected = primary.withOpacity(0.85);
      final numBgUnselected = isDarkTheme
          ? Colors.white.withOpacity(0.06)
          : Colors.black.withOpacity(0.04);

      return InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(4),
        child: Ink(
          height: 34,
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? primary
                  : Theme.of(context).dividerColor.withOpacity(0.3),
            ),
            borderRadius: BorderRadius.circular(4),
            color: selected ? numBgSelected : numBgUnselected,
          ),
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: !enabled
                    ? numColorDisabled
                    : (selected ? numColorSelected : numColorUnselected),
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }

    Widget buildSectionTitle(String title) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).hintColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    final scaleButtons = [
      buildSectionTitle(translate('Scale')),
      Obx(() => Row(
            children: [
              Expanded(
                child: buildSegmentButton(
                  text: translate('Original'),
                  selected: viewStyle.value == kRemoteViewStyleOriginal,
                  onTap: () {
                    final r =
                        findRadio(viewStyleRadios, kRemoteViewStyleOriginal);
                    r?.onChanged?.call(kRemoteViewStyleOriginal);
                    viewStyle.value = kRemoteViewStyleOriginal;
                    bind.mainSetPeerOptionSync(
                        id: id,
                        key: 'view_style',
                        value: kRemoteViewStyleOriginal);
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Adaptive'),
                  selected: viewStyle.value == kRemoteViewStyleAdaptive,
                  onTap: () {
                    final r =
                        findRadio(viewStyleRadios, kRemoteViewStyleAdaptive);
                    r?.onChanged?.call(kRemoteViewStyleAdaptive);
                    viewStyle.value = kRemoteViewStyleAdaptive;
                    bind.mainSetPeerOptionSync(
                        id: id,
                        key: 'view_style',
                        value: kRemoteViewStyleAdaptive);
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Custom'),
                  selected: viewStyle.value == kRemoteViewStyleCustom,
                  onTap: () {
                    final r =
                        findRadio(viewStyleRadios, kRemoteViewStyleCustom);
                    r?.onChanged?.call(kRemoteViewStyleCustom);
                    viewStyle.value = kRemoteViewStyleCustom;
                    bind.mainSetPeerOptionSync(
                        id: id,
                        key: 'view_style',
                        value: kRemoteViewStyleCustom);
                  },
                ),
              ),
            ],
          )),
      Obx(() => viewStyle.value == kRemoteViewStyleCustom
          ? MobileCustomScaleControls(ffi: gFFI)
          : const SizedBox.shrink()),
    ];

    final qualityButtons = [
      buildSectionTitle(translate('Image Quality')),
      Obx(() => Row(
            children: [
              Expanded(
                child: buildSegmentButton(
                  text: translate('Quality'),
                  selected: imageQuality.value == kRemoteImageQualityBest,
                  onTap: () {
                    final r =
                        findRadio(imageQualityRadios, kRemoteImageQualityBest);
                    r?.onChanged?.call(kRemoteImageQualityBest);
                    imageQuality.value = kRemoteImageQualityBest;
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Balanced'),
                  selected: imageQuality.value == kRemoteImageQualityBalanced,
                  onTap: () {
                    final r = findRadio(
                        imageQualityRadios, kRemoteImageQualityBalanced);
                    r?.onChanged?.call(kRemoteImageQualityBalanced);
                    imageQuality.value = kRemoteImageQualityBalanced;
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Speed'),
                  selected: imageQuality.value == kRemoteImageQualityLow,
                  onTap: () {
                    final r =
                        findRadio(imageQualityRadios, kRemoteImageQualityLow);
                    r?.onChanged?.call(kRemoteImageQualityLow);
                    imageQuality.value = kRemoteImageQualityLow;
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Custom'),
                  selected: imageQuality.value == kRemoteImageQualityCustom,
                  onTap: () {
                    final r = findRadio(
                        imageQualityRadios, kRemoteImageQualityCustom);
                    r?.onChanged?.call(kRemoteImageQualityCustom);
                    imageQuality.value = kRemoteImageQualityCustom;
                  },
                ),
              ),
            ],
          )),
    ];

    Widget buildCodecBtn(String label, String val) {
      final r = findRadio(codecRadios, val);
      final enabled = r != null && r.onChanged != null;
      return buildSegmentButton(
        text: label,
        selected: codec.value == val,
        enabled: enabled,
        onTap: () async {
          if (enabled) {
            if (val == 'h264' || val == 'h265' || val == 'auto') {
              if (isI444Enabled.value) {
                isI444Enabled.value = false;
                await bind.sessionPeerOption(
                    sessionId: gFFI.sessionId, name: 'i444', value: '');
                bind.mainSetPeerOptionSync(id: id, key: 'i444', value: '');
              }
            }
            r.onChanged?.call(val);
            codec.value = val;
          }
        },
      );
    }

    final savedPeerFps = bind.mainGetPeerOptionSync(id: id, key: 'custom-fps');
    final currentFps = (savedPeerFps.isNotEmpty ? savedPeerFps : '60').obs;

    final fpsButtons = [
      buildSectionTitle(
          localeName.startsWith('zh') ? '帧率 (FPS)' : 'Framerate (FPS)'),
      Obx(() => Row(
            children: [
              Expanded(
                child: buildSegmentButton(
                  text: '30 FPS',
                  selected: currentFps.value == '30',
                  onTap: () async {
                    currentFps.value = '30';
                    await bind.sessionSetCustomFps(
                        sessionId: gFFI.sessionId, fps: 30);
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-fps', value: '30');
                    BotToast.showText(text: '30 FPS');
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: '60 FPS',
                  selected:
                      currentFps.value == '60' || currentFps.value.isEmpty,
                  onTap: () async {
                    currentFps.value = '60';
                    await bind.sessionSetCustomFps(
                        sessionId: gFFI.sessionId, fps: 60);
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-fps', value: '60');
                    BotToast.showText(text: '60 FPS');
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: '120 FPS',
                  selected: currentFps.value == '120',
                  onTap: () async {
                    currentFps.value = '120';
                    await bind.sessionSetCustomFps(
                        sessionId: gFFI.sessionId, fps: 120);
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-fps', value: '120');
                    BotToast.showText(text: '120 FPS');
                  },
                ),
              ),
            ],
          )),
    ];
    final rH264 = findRadio(codecRadios, 'h264');
    final rH265 = findRadio(codecRadios, 'h265');
    final isCodecCompatible = (rH264 != null && rH264.onChanged != null) ||
        (rH265 != null && rH265.onChanged != null);

    final directSurfaceButtons = isAndroid
        ? [
            buildSectionTitle(localeName.startsWith('zh')
                ? '极速硬件直通模式 (Direct Surface)'
                : 'Direct Surface Mode (Zero Latency)'),
            Obx(() {
              final isDirect = gFFI.ffiModel.isDirectSurface.value;
              final isCompatible = isCodecCompatible;
              return Row(
                children: [
                  Expanded(
                    child: buildSegmentButton(
                      text: isDirect
                          ? (localeName.startsWith('zh')
                              ? '⚡ 直通运行中 (点击退出)'
                              : '⚡ Active (Tap to Exit)')
                          : (isCompatible
                              ? (localeName.startsWith('zh')
                                  ? '⚡ 开启极速直通 (<2ms 最低延时)'
                                  : '⚡ Enable Direct Surface (<2ms)')
                              : (localeName.startsWith('zh')
                                  ? '⚡ 极速直通 (当前连接不支持H264/H265)'
                                  : '⚡ Direct Surface (Requires H264/H265)')),
                      selected: isDirect,
                      enabled: isCompatible || isDirect,
                      onTap: () async {
                        if (!isCompatible && !isDirect) {
                          BotToast.showText(
                            text: localeName.startsWith('zh')
                                ? '当前连接两端不支持H264/H265编码，无法开启极速直通模式'
                                : 'Direct Surface requires H264/H265 support',
                          );
                          return;
                        }
                        if (!isDirect) {
                          if (codec.value != 'h264' && codec.value != 'h265') {
                            final targetCodec =
                                (rH264 != null && rH264.onChanged != null)
                                    ? 'h264'
                                    : 'h265';
                            final r = findRadio(codecRadios, targetCodec);
                            r?.onChanged?.call(targetCodec);
                            codec.value = targetCodec;
                          }
                          final display = gFFI.ffiModel.pi
                              .tryGetDisplayIfNotAllDisplay(
                                  display: gFFI.ffiModel.pi.currentDisplay);
                          final w = display?.width ?? 1920;
                          final h = display?.height ?? 1080;
                          await gFFI.invokeMethod("start_direct_surface",
                              {"width": w, "height": h});
                          gFFI.ffiModel.isDirectSurface.value = true;
                          close();
                          BotToast.showText(
                            text: localeName.startsWith('zh')
                                ? '已开启极速硬件直通模式！点击右上角悬浮按钮可退出'
                                : 'Direct Surface Mode enabled! Tap top-right button to exit',
                          );
                        } else {
                          await gFFI.invokeMethod("stop_direct_surface");
                          gFFI.ffiModel.isDirectSurface.value = false;
                          BotToast.showText(
                            text: localeName.startsWith('zh')
                                ? '已退出极速硬件直通模式'
                                : 'Direct Surface Mode disabled',
                          );
                        }
                      },
                    ),
                  ),
                ],
              );
            }),
          ]
        : <Widget>[];

    final colorModeButtons = [
      buildSectionTitle(
          localeName.startsWith('zh') ? '色彩与延时模式' : 'Display Mode & Latency'),
      Obx(() {
        final is444 = isI444Enabled.value;
        return Row(
          children: [
            Expanded(
              child: buildSegmentButton(
                text: localeName.startsWith('zh')
                    ? '⚡ 低延时 (4:2:0 硬解)'
                    : '⚡ Low Latency (4:2:0)',
                selected: !is444,
                onTap: () async {
                  isI444Enabled.value = false;
                  await bind.sessionPeerOption(
                      sessionId: gFFI.sessionId, name: 'i444', value: '');
                  bind.mainSetPeerOptionSync(id: id, key: 'i444', value: '');
                  await bind.sessionPeerOption(
                      sessionId: gFFI.sessionId,
                      name: 'codec-preference',
                      value: 'auto');
                  bind.mainSetPeerOptionSync(
                      id: id, key: 'codec-preference', value: 'auto');
                  final r = findRadio(codecRadios, 'auto');
                  r?.onChanged?.call('auto');
                  codec.value = 'auto';
                  bind.sessionChangePreferCodec(sessionId: gFFI.sessionId);
                  BotToast.showText(
                    text: localeName.startsWith('zh')
                        ? '已开启低延时硬解模式 (H.264/H.265)'
                        : 'Switched to Low Latency (H.264/H.265 HW decode)',
                  );
                },
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: buildSegmentButton(
                text: localeName.startsWith('zh')
                    ? '🎨 真彩 (VP9 4:4:4)'
                    : '🎨 True Color (VP9 4:4:4)',
                selected: is444,
                onTap: () async {
                  isI444Enabled.value = true;
                  await bind.sessionPeerOption(
                      sessionId: gFFI.sessionId, name: 'i444', value: 'Y');
                  bind.mainSetPeerOptionSync(id: id, key: 'i444', value: 'Y');
                  await bind.sessionPeerOption(
                      sessionId: gFFI.sessionId,
                      name: 'codec-preference',
                      value: 'vp9');
                  bind.mainSetPeerOptionSync(
                      id: id, key: 'codec-preference', value: 'vp9');
                  final r = findRadio(codecRadios, 'vp9');
                  r?.onChanged?.call('vp9');
                  codec.value = 'vp9';
                  bind.sessionChangePreferCodec(sessionId: gFFI.sessionId);
                  BotToast.showText(
                    text: localeName.startsWith('zh')
                        ? '已开启真彩模式 (VP9 4:4:4 软解，色彩无损)'
                        : 'Switched to True Color (VP9 4:4:4)',
                  );
                },
              ),
            ),
          ],
        );
      }),
    ];

    final codecButtons = [
      buildSectionTitle(translate('Codec')),
      Obx(() => Column(
            children: [
              Row(
                children: [
                  Expanded(child: buildCodecBtn(translate('Auto'), 'auto')),
                  const SizedBox(width: 6),
                  Expanded(child: buildCodecBtn('VP8', 'vp8')),
                  const SizedBox(width: 6),
                  Expanded(child: buildCodecBtn('VP9', 'vp9')),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: buildCodecBtn('AV1', 'av1')),
                  const SizedBox(width: 6),
                  Expanded(child: buildCodecBtn('H264', 'h264')),
                  const SizedBox(width: 6),
                  Expanded(child: buildCodecBtn('H265', 'h265')),
                ],
              ),
            ],
          )),
    ];

    final resolutionButtons = [
      buildSectionTitle(translate('Resolution')),
      Row(
        children: [
          Expanded(
            child: buildSegmentButton(
              text: translate('Resolution'),
              selected: false,
              enabled: resolution != null,
              onTap: () {
                close();
                resolution?.onPressed?.call();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: buildSegmentButton(
              text: translate('Fit Phone'),
              selected: false,
              enabled: phonePortraitMenu != null,
              onTap: () {
                close();
                phonePortraitMenu?.onPressed?.call();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: buildSegmentButton(
              text: translate('Virtual Display'),
              selected: false,
              enabled: virtualDisplayMenu != null,
              onTap: () {
                close();
                virtualDisplayMenu?.onPressed?.call();
              },
            ),
          ),
        ],
      ),
    ];

    final savedOrientation =
        bind.mainGetPeerOptionSync(id: id, key: 'custom-display-orientation');
    final currentOrientation =
        (savedOrientation.isNotEmpty ? savedOrientation : 'auto').obs;

    final orientationButtons = [
      buildSectionTitle(localeName.startsWith('zh')
          ? '屏幕方向 (自动记忆)'
          : 'Orientation (Memorized)'),
      Obx(() => Row(
            children: [
              Expanded(
                child: buildSegmentButton(
                  text: localeName.startsWith('zh') ? '自动跟随' : 'Auto',
                  selected: currentOrientation.value == 'auto' ||
                      currentOrientation.value.isEmpty,
                  onTap: () async {
                    currentOrientation.value = 'auto';
                    bind.mainSetPeerOptionSync(
                        id: id,
                        key: 'custom-display-orientation',
                        value: 'auto');
                    sendPhysicalResolutionToServer(
                      peerId: id,
                      sessionId: gFFI.sessionId,
                      forcedOrientation: 'auto',
                    );
                    BotToast.showText(
                      text: localeName.startsWith('zh')
                          ? '已记忆屏幕方向: 自动跟随设备'
                          : 'Orientation: Auto follow device',
                    );
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: localeName.startsWith('zh') ? '横向' : 'Landscape',
                  selected: currentOrientation.value == 'landscape',
                  onTap: () async {
                    currentOrientation.value = 'landscape';
                    bind.mainSetPeerOptionSync(
                        id: id,
                        key: 'custom-display-orientation',
                        value: 'landscape');
                    sendPhysicalResolutionToServer(
                      peerId: id,
                      sessionId: gFFI.sessionId,
                      forcedOrientation: 'landscape',
                    );
                    BotToast.showText(
                      text: localeName.startsWith('zh')
                          ? '已记忆屏幕方向: 横向'
                          : 'Orientation memorized: Landscape',
                    );
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: localeName.startsWith('zh') ? '纵向' : 'Portrait',
                  selected: currentOrientation.value == 'portrait',
                  onTap: () async {
                    currentOrientation.value = 'portrait';
                    bind.mainSetPeerOptionSync(
                        id: id,
                        key: 'custom-display-orientation',
                        value: 'portrait');
                    sendPhysicalResolutionToServer(
                      peerId: id,
                      sessionId: gFFI.sessionId,
                      forcedOrientation: 'portrait',
                    );
                    BotToast.showText(
                      text: localeName.startsWith('zh')
                          ? '已记忆屏幕方向: 纵向'
                          : 'Orientation memorized: Portrait',
                    );
                  },
                ),
              ),
            ],
          )),
    ];

    final savedScale =
        bind.mainGetPeerOptionSync(id: id, key: 'custom-vdd-scale');
    final currentScale = (savedScale.isNotEmpty ? savedScale : '1.0').obs;

    final vddScaleButtons = [
      buildSectionTitle(localeName.startsWith('zh')
          ? 'VDD 比例缩放 (自动匹配屏幕)'
          : 'VDD Scaling (Auto Match Screen)'),
      Obx(() => Row(
            children: [
              Expanded(
                child: buildSegmentButton(
                  text: localeName.startsWith('zh') ? '1:1 原生' : '1:1 Native',
                  selected:
                      currentScale.value == '1.0' || currentScale.value.isEmpty,
                  onTap: () async {
                    currentScale.value = '1.0';
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-vdd-scale', value: '1.0');
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-resolution', value: '');
                    sendPhysicalResolutionToServer(
                      peerId: id,
                      sessionId: gFFI.sessionId,
                      forcePhysical: true,
                    );
                    BotToast.showText(
                      text: localeName.startsWith('zh')
                          ? '已切换为 1:1 原生比例点对点'
                          : 'Set to 1:1 native scale',
                    );
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text:
                      localeName.startsWith('zh') ? '1.5:1 舒适' : '1.5:1 Comfy',
                  selected: currentScale.value == '1.5',
                  onTap: () async {
                    currentScale.value = '1.5';
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-vdd-scale', value: '1.5');
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-resolution', value: '');
                    sendPhysicalResolutionToServer(
                      peerId: id,
                      sessionId: gFFI.sessionId,
                      forcePhysical: true,
                    );
                    BotToast.showText(
                      text: localeName.startsWith('zh')
                          ? '已切换为 1.5:1 舒适缩放'
                          : 'Set to 1.5:1 scale',
                    );
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: localeName.startsWith('zh') ? '2:1 大图标' : '2:1 Big UI',
                  selected: currentScale.value == '2.0',
                  onTap: () async {
                    currentScale.value = '2.0';
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-vdd-scale', value: '2.0');
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-resolution', value: '');
                    sendPhysicalResolutionToServer(
                      peerId: id,
                      sessionId: gFFI.sessionId,
                      forcePhysical: true,
                    );
                    BotToast.showText(
                      text: localeName.startsWith('zh')
                          ? '已切换为 2:1 大图标缩放'
                          : 'Set to 2:1 scale',
                    );
                  },
                ),
              ),
            ],
          )),
    ];

    final isSingleApp = gFFI.canvasModel.isSingleAppMode.obs;
    final appModeButtons = [
      buildSectionTitle(translate('Program selection')),
      Obx(() => Row(
            children: [
              Expanded(
                child: buildSegmentButton(
                  text: translate('Full Screen'),
                  selected: !isSingleApp.value,
                  onTap: () async {
                    if (isSingleApp.value) {
                      isSingleApp.value = false;
                      await bind.sessionPeerOption(
                          sessionId: gFFI.sessionId,
                          name: 'select_window',
                          value: '0');
                      gFFI.ffiModel.pi.platformAdditions['selected_window'] = 0;
                      gFFI.canvasModel.isSingleAppMode = false;
                      await bind.sessionPeerOption(
                          sessionId: gFFI.sessionId,
                          name: 'is_single_app_mode',
                          value: 'N');
                      await gFFI.canvasModel.updateViewStyle();
                    }
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Single App'),
                  selected: isSingleApp.value,
                  onTap: () async {
                    close();
                    gFFI.canvasModel.showWindowPickerModal = true;
                    await bind.sessionPeerOption(
                        sessionId: gFFI.sessionId,
                        name: 'get_window_list',
                        value: '');
                  },
                ),
              ),
            ],
          )),
      Obx(() => isSingleApp.value
          ? StatefulBuilder(
              builder: (context, setSwState) => SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  localeName.startsWith('zh')
                      ? '允许双指缩放画布'
                      : 'Allow Pinch Zoom Canvas',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  localeName.startsWith('zh')
                      ? '默认关闭，触屏操作时防止手势误触画面收缩'
                      : 'Disabled by default to avoid accidental zooming',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
                value: gFFI.canvasModel.allowSingleAppZoom,
                activeColor: MyTheme.accent,
                onChanged: (val) {
                  setSwState(() {
                    gFFI.canvasModel.allowSingleAppZoom = val;
                  });
                },
              ),
            )
          : const SizedBox.shrink()),
    ];

    final rawKbdMode =
        bind.mainGetLocalOption(key: kOptionMobileKeyboardLayoutMode);
    final kbdMode = (rawKbdMode.isEmpty ? 'auto' : rawKbdMode).obs;
    final keyboardLayoutButtons = [
      buildSectionTitle(translate('Keyboard layout')),
      Obx(() => Row(
            children: [
              Expanded(
                child: buildSegmentButton(
                  text: translate('Auto'),
                  selected: kbdMode.value == 'auto' || kbdMode.value.isEmpty,
                  onTap: () async {
                    kbdMode.value = 'auto';
                    await bind.mainSetLocalOption(
                        key: kOptionMobileKeyboardLayoutMode, value: 'auto');
                    gFFI.canvasModel.updateViewStyle();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Squeeze screen'),
                  selected: kbdMode.value == 'phone',
                  onTap: () async {
                    kbdMode.value = 'phone';
                    await bind.mainSetLocalOption(
                        key: kOptionMobileKeyboardLayoutMode, value: 'phone');
                    gFFI.canvasModel.updateViewStyle();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Float above screen'),
                  selected: kbdMode.value == 'tablet',
                  onTap: () async {
                    kbdMode.value = 'tablet';
                    await bind.mainSetLocalOption(
                        key: kOptionMobileKeyboardLayoutMode, value: 'tablet');
                    gFFI.canvasModel.updateViewStyle();
                  },
                ),
              ),
            ],
          )),
    ];

    final rxCursorToggleValues = cursorToggles.map((e) => e.value.obs).toList();
    final cursorTogglesList = cursorToggles
        .asMap()
        .entries
        .map((e) => Obx(() => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: rxCursorToggleValues[e.key].value,
            onChanged: e.value.onChanged != null
                ? (v) {
                    e.value.onChanged?.call(v);
                    if (v != null) rxCursorToggleValues[e.key].value = v;
                  }
                : null,
            title: e.value.child)))
        .toList();

    final rxToggleValues = displayToggles.map((e) => e.value.obs).toList();
    final displayTogglesList = displayToggles
        .asMap()
        .entries
        .map((e) => Obx(() => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: rxToggleValues[e.key].value,
            onChanged: e.value.onChanged != null
                ? (v) {
                    e.value.onChanged?.call(v);
                    if (v != null) rxToggleValues[e.key].value = v;
                  }
                : null,
            title: e.value.child)))
        .toList();
    final toggles = [
      ...cursorTogglesList,
      if (cursorToggles.isNotEmpty) const Divider(color: MyTheme.border),
      ...displayTogglesList,
    ];

    Widget privacyModeWidget = const Offstage();
    if (privacyModeList.length > 1) {
      privacyModeWidget = ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: Text(translate('Privacy mode')),
        onTap: () => setPrivacyModeDialog(
            dialogManager, privacyModeList, privacyModeState),
      );
    }

    return CustomAlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...displays,
          ...scaleButtons,
          const SizedBox(height: 4),
          ...qualityButtons,
          const SizedBox(height: 4),
          ...fpsButtons,
          const SizedBox(height: 4),
          ...colorModeButtons,
          if (isAndroid) ...[
            const SizedBox(height: 4),
            ...directSurfaceButtons,
          ],
          const SizedBox(height: 4),
          ...codecButtons,
          const SizedBox(height: 4),
          ...resolutionButtons,
          const SizedBox(height: 4),
          ...orientationButtons,
          const SizedBox(height: 4),
          ...vddScaleButtons,
          const SizedBox(height: 4),
          ...appModeButtons,
          const SizedBox(height: 4),
          ...keyboardLayoutButtons,
          if (isAndroid)
            Obx(() => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    isZh ? '文字输入感应弹出软键盘' : 'Auto popup keyboard on text cursor',
                    style: const TextStyle(fontSize: 14),
                  ),
                  value: _autoPopupKeyboardOnText.value,
                  onChanged: (val) async {
                    _autoPopupKeyboardOnText.value = val;
                    await bind.mainSetLocalOption(
                        key: 'auto_popup_keyboard_on_text',
                        value: val ? 'true' : 'false');
                  },
                )),
          if (isAndroid)
            Obx(() {
              if (!_autoPopupKeyboardOnText.value)
                return const SizedBox.shrink();
              final marginVal = _keyboardCursorMargin.value;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isZh ? '软键盘弹出触发方式' : 'Popup trigger',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2.0),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6.0),
                            onTap: () async {
                              _keyboardPopupMode.value = 'tap';
                              await bind.mainSetLocalOption(
                                key: 'keyboard_popup_mode',
                                value: 'tap',
                              );
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Radio<String>(
                                    value: 'tap',
                                    groupValue: _keyboardPopupMode.value,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (val) async {
                                      if (val != null) {
                                        _keyboardPopupMode.value = val;
                                        await bind.mainSetLocalOption(
                                          key: 'keyboard_popup_mode',
                                          value: val,
                                        );
                                      }
                                    },
                                  ),
                                  const SizedBox(width: 2.0),
                                  Flexible(
                                    child: Text(
                                      isZh ? '点击屏幕才弹出' : 'Tap screen',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: _keyboardPopupMode.value == 'tap'
                                            ? Colors.blue
                                            : null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6.0),
                            onTap: () async {
                              _keyboardPopupMode.value = 'auto';
                              await bind.mainSetLocalOption(
                                key: 'keyboard_popup_mode',
                                value: 'auto',
                              );
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Radio<String>(
                                    value: 'auto',
                                    groupValue: _keyboardPopupMode.value,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (val) async {
                                      if (val != null) {
                                        _keyboardPopupMode.value = val;
                                        await bind.mainSetLocalOption(
                                          key: 'keyboard_popup_mode',
                                          value: val,
                                        );
                                      }
                                    },
                                  ),
                                  const SizedBox(width: 2.0),
                                  Flexible(
                                    child: Text(
                                      isZh ? '自动弹出' : 'Automatic',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color:
                                            _keyboardPopupMode.value == 'auto'
                                                ? Colors.blue
                                                : null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4.0),
                    if (_keyboardPopupMode.value == 'auto') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isZh ? '软键盘光标安全间距' : 'Keyboard cursor margin',
                            style: const TextStyle(fontSize: 14),
                          ),
                          Text(
                            '${marginVal.round()} px',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                        ],
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.0,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7.0),
                        ),
                        child: Slider(
                          value: marginVal.clamp(0.0, 120.0),
                          min: 0.0,
                          max: 120.0,
                          divisions: 24,
                          label: '${marginVal.round()} px',
                          onChanged: (val) {
                            _keyboardCursorMargin.value = val;
                          },
                          onChangeEnd: (val) async {
                            await bind.mainSetLocalOption(
                              key: 'keyboard_cursor_margin',
                              value: val.round().toString(),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 4.0),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isZh ? '软键盘弹出延迟' : 'Popup delay',
                            style: const TextStyle(fontSize: 14),
                          ),
                          Text(
                            '${_keyboardPopupDelayMs.value} ms',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                        ],
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.0,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7.0),
                        ),
                        child: Slider(
                          value: _keyboardPopupDelayMs.value
                              .toDouble()
                              .clamp(0.0, 1000.0),
                          min: 0.0,
                          max: 1000.0,
                          divisions: 20,
                          label: '${_keyboardPopupDelayMs.value} ms',
                          onChanged: (val) {
                            _keyboardPopupDelayMs.value = val.round();
                          },
                          onChangeEnd: (val) async {
                            await bind.mainSetLocalOption(
                              key: 'keyboard_popup_delay_ms',
                              value: val.round().toString(),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 4.0),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isZh ? '非文本光标收回方式' : 'Dismiss trigger',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2.0),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6.0),
                            onTap: () async {
                              _keyboardDismissMode.value = 'any';
                              await bind.mainSetLocalOption(
                                key: 'keyboard_dismiss_mode',
                                value: 'any',
                              );
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Radio<String>(
                                    value: 'any',
                                    groupValue: _keyboardDismissMode.value,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (val) async {
                                      if (val != null) {
                                        _keyboardDismissMode.value = val;
                                        await bind.mainSetLocalOption(
                                          key: 'keyboard_dismiss_mode',
                                          value: val,
                                        );
                                      }
                                    },
                                  ),
                                  const SizedBox(width: 2.0),
                                  Flexible(
                                    child: Text(
                                      isZh ? '触摸/滑动收回' : 'Touch/Slide',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color:
                                            _keyboardDismissMode.value == 'any'
                                                ? Colors.blue
                                                : null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6.0),
                            onTap: () async {
                              _keyboardDismissMode.value = 'tap';
                              await bind.mainSetLocalOption(
                                key: 'keyboard_dismiss_mode',
                                value: 'tap',
                              );
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Radio<String>(
                                    value: 'tap',
                                    groupValue: _keyboardDismissMode.value,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (val) async {
                                      if (val != null) {
                                        _keyboardDismissMode.value = val;
                                        await bind.mainSetLocalOption(
                                          key: 'keyboard_dismiss_mode',
                                          value: val,
                                        );
                                      }
                                    },
                                  ),
                                  const SizedBox(width: 2.0),
                                  Flexible(
                                    child: Text(
                                      isZh ? '仅点击才收回' : 'Tap only',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color:
                                            _keyboardDismissMode.value == 'tap'
                                                ? Colors.blue
                                                : null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          const Divider(color: MyTheme.border),
          ...toggles,
          privacyModeWidget,
        ],
      ),
    );
  }, clickMaskDismiss: true, backDismiss: true).then((value) {
    _disableAndroidSoftKeyboard();
  });
}

Resolution _getClientResolution(BuildContext context,
    {double scale = 1.0, bool? forcePortrait}) {
  try {
    final media = MediaQuery.of(context);
    var rawW = (media.size.width * media.devicePixelRatio).round();
    var rawH = (media.size.height * media.devicePixelRatio).round();
    if (forcePortrait == true && rawW > rawH) {
      final tmp = rawW;
      rawW = rawH;
      rawH = tmp;
    } else if (forcePortrait == false && rawW < rawH) {
      final tmp = rawW;
      rawW = rawH;
      rawH = tmp;
    }
    final s = scale > 0 ? scale : 1.0;
    final w = ((rawW / s).round() ~/ 2) * 2;
    final h = ((rawH / s).round() ~/ 2) * 2;
    if (w > 0 && h > 0) {
      return Resolution(w, h);
    }
  } catch (e) {
    debugPrint('Failed to get client resolution: $e');
  }
  final s = scale > 0 ? scale : 1.0;
  return Resolution((1080 / s).round() ~/ 2 * 2, (2400 / s).round() ~/ 2 * 2);
}

Resolution _getPhonePortraitDimensions(BuildContext context,
    [double scale = 1.0]) {
  return _getClientResolution(context, scale: scale, forcePortrait: true);
}

void sendPhysicalResolutionToServer({
  required String peerId,
  required SessionID sessionId,
  bool forcePhysical = false,
  String? forcedOrientation,
}) {
  try {
    int targetW = 0;
    int targetH = 0;
    final scaleStr =
        bind.mainGetPeerOptionSync(id: peerId, key: 'custom-vdd-scale');
    final scale = double.tryParse(scaleStr) ?? 1.0;
    final s = scale > 0 ? scale : 1.0;

    if (!forcePhysical) {
      final savedRes =
          bind.mainGetPeerOptionSync(id: peerId, key: 'custom-resolution');
      if (savedRes.isNotEmpty && savedRes.contains('x')) {
        final parts = savedRes.split('x');
        targetW = int.tryParse(parts[0]) ?? 0;
        targetH = int.tryParse(parts[1]) ?? 0;
      }
    }
    if (targetW <= 0 || targetH <= 0) {
      if (WidgetsBinding.instance.platformDispatcher.views.isNotEmpty) {
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final pSize = view.physicalSize;
        if (pSize.width > 0 && pSize.height > 0) {
          targetW = ((pSize.width / s).round() ~/ 2) * 2;
          targetH = ((pSize.height / s).round() ~/ 2) * 2;
        }
      }
    }
    if (targetW <= 0 || targetH <= 0) return;

    final orientationMode = forcedOrientation ??
        bind.mainGetPeerOptionSync(
            id: peerId, key: 'custom-display-orientation');
    final minDim = min(targetW, targetH);
    final maxDim = max(targetW, targetH);

    if (orientationMode == 'landscape') {
      targetW = maxDim;
      targetH = minDim;
    } else if (orientationMode == 'portrait') {
      targetW = minDim;
      targetH = maxDim;
    } else {
      bool isPortrait = false;
      if (WidgetsBinding.instance.platformDispatcher.views.isNotEmpty) {
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        isPortrait = view.physicalSize.aspectRatio < 1.0;
      }
      if (isPortrait) {
        targetW = minDim;
        targetH = maxDim;
      } else {
        targetW = maxDim;
        targetH = minDim;
      }
    }

    debugPrint(
        "Sending secondary display resolution to server: ${targetW}x$targetH (scale: $s, orientation: $orientationMode)");
    bind.sessionPeerOption(
      sessionId: sessionId,
      name: 'secondary_display',
      value: '${targetW}x$targetH',
    );
    final pi = gFFI.ffiModel.pi;
    if (pi.displays.isNotEmpty) {
      bind.sessionChangeResolution(
        sessionId: sessionId,
        display: pi.currentDisplay,
        width: targetW,
        height: targetH,
      );
    }
  } catch (e) {
    debugPrint("Error sending secondary display resolution: $e");
  }
}

Future<void> setupPhonePortraitVirtualDisplay({
  required BuildContext context,
  required FFI ffi,
  required int targetWidth,
  required int targetHeight,
}) async {
  final isZh = localeName.startsWith('zh');
  final pi = ffi.ffiModel.pi;
  final w = (targetWidth ~/ 2) * 2;
  final h = (targetHeight ~/ 2) * 2;

  BotToast.showText(
    text: isZh ? '正在配置手机专属竖屏...' : 'Setting up phone portrait display...',
  );

  final hasVirtual =
      pi.RustDeskVirtualDisplays.isNotEmpty || pi.amyuniVirtualDisplayCount > 0;
  if (!hasVirtual) {
    if (pi.isVddIdd) {
      await bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: 0, on: true);
    } else if (pi.isRustDeskIdd) {
      await bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: 1, on: true);
    } else if (pi.isAmyuniIdd) {
      await bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: 0, on: true);
    } else {
      await bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: 0, on: true);
    }
  }

  int targetDisplayIndex = -1;
  final initialCount = pi.displays.length;
  for (var i = 0; i < 15; i++) {
    for (var d = 0; d < pi.displays.length; d++) {
      if (pi.displays[d].isVirtualDisplayResolution) {
        targetDisplayIndex = d;
        break;
      }
    }
    if (targetDisplayIndex != -1) break;
    if (pi.displays.length > 1 && pi.displays.length > initialCount) {
      targetDisplayIndex = pi.displays.length - 1;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 200));
  }

  if (targetDisplayIndex == -1) {
    targetDisplayIndex = pi.displays.isNotEmpty ? pi.displays.length - 1 : 0;
  }

  await bind.sessionChangeResolution(
    sessionId: ffi.sessionId,
    display: targetDisplayIndex,
    width: w,
    height: h,
  );
  bind.mainSetPeerOptionSync(
    id: ffi.id,
    key: 'custom-resolution',
    value: '${w}x$h',
  );
  bind.mainSetPeerOptionSync(
    id: ffi.id,
    key: 'custom-display-orientation',
    value: 'portrait',
  );

  if (pi.currentDisplay != targetDisplayIndex &&
      targetDisplayIndex < pi.displays.length) {
    openMonitorInTheSameTab(targetDisplayIndex, ffi, pi);
  }

  BotToast.showText(
    text: isZh
        ? '已切换至竖屏虚拟显示器 ($w x $h)'
        : 'Switched to portrait virtual display ($w x $h)',
  );
}

void showCustomResolutionInputDialog({
  required BuildContext context,
  required FFI ffi,
  required int initialWidth,
  required int initialHeight,
  required Function(int width, int height) onConfirm,
}) {
  final isZh = localeName.startsWith('zh');
  final widthController = TextEditingController(text: initialWidth.toString());
  final heightController =
      TextEditingController(text: initialHeight.toString());

  ffi.dialogManager.show((setState, close, ctx) {
    return CustomAlertDialog(
      title: Text(isZh ? '自定义分辨率' : 'Custom Resolution'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widthController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: isZh ? '宽度' : 'Width',
                    hintText: '1080',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('×', style: TextStyle(fontSize: 18)),
              ),
              Expanded(
                child: TextField(
                  controller: heightController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: isZh ? '高度' : 'Height',
                    hintText: '2400',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            isZh
                ? '提示: 分辨率将自动调整为偶数以适配硬件编码'
                : 'Note: Dimensions will be adjusted to even numbers.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => close(),
          child: Text(translate('Cancel')),
        ),
        ElevatedButton(
          onPressed: () {
            final w = int.tryParse(widthController.text.trim());
            final h = int.tryParse(heightController.text.trim());
            if (w == null || h == null || w <= 0 || h <= 0) {
              BotToast.showText(
                text: isZh ? '请输入有效的分辨率' : 'Please enter valid dimensions',
              );
              return;
            }
            final evenW = (w ~/ 2) * 2;
            final evenH = (h ~/ 2) * 2;
            close();
            onConfirm(evenW, evenH);
          },
          child: Text(translate('OK')),
        ),
      ],
    );
  }, clickMaskDismiss: true, backDismiss: true).then((value) {
    _disableAndroidSoftKeyboard();
  });
}

TTextMenu? getPhonePortraitVirtualDisplayMenu(
    BuildContext context, FFI ffi, String id) {
  if (!showVirtualDisplayMenu(ffi)) {
    return null;
  }
  final isZh = localeName.startsWith('zh');
  final res1x = _getPhonePortraitDimensions(context, 1.0);
  final res15x = _getPhonePortraitDimensions(context, 1.5);
  final res2x = _getPhonePortraitDimensions(context, 2.0);

  return TTextMenu(
    child: Text(isZh ? '手机专属竖屏 (虚拟屏)' : 'Phone Portrait Display'),
    onPressed: () {
      final pi = ffi.ffiModel.pi;
      final hasVirtual = pi.RustDeskVirtualDisplays.isNotEmpty ||
          pi.amyuniVirtualDisplayCount > 0;

      ffi.dialogManager.show((setState, close, ctx) {
        return CustomAlertDialog(
          title: Text(isZh ? '手机专属竖屏 (虚拟屏)' : 'Phone Portrait Display'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.stay_current_portrait),
                  title: Text(
                    isZh
                        ? '📱 匹配本机 1:1 原生 (${res1x.width}x${res1x.height})'
                        : '📱 Match phone 1:1 (${res1x.width}x${res1x.height})',
                  ),
                  onTap: () {
                    close();
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-vdd-scale', value: '1.0');
                    setupPhonePortraitVirtualDisplay(
                      context: context,
                      ffi: ffi,
                      targetWidth: res1x.width,
                      targetHeight: res1x.height,
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.zoom_in),
                  title: Text(
                    isZh
                        ? '📱 匹配本机 1.5:1 舒适 (${res15x.width}x${res15x.height})'
                        : '📱 Match phone 1.5:1 (${res15x.width}x${res15x.height})',
                  ),
                  onTap: () {
                    close();
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-vdd-scale', value: '1.5');
                    setupPhonePortraitVirtualDisplay(
                      context: context,
                      ffi: ffi,
                      targetWidth: res15x.width,
                      targetHeight: res15x.height,
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.touch_app),
                  title: Text(
                    isZh
                        ? '📱 匹配本机 2:1 大图标 (${res2x.width}x${res2x.height})'
                        : '📱 Match phone 2:1 (${res2x.width}x${res2x.height})',
                  ),
                  onTap: () {
                    close();
                    bind.mainSetPeerOptionSync(
                        id: id, key: 'custom-vdd-scale', value: '2.0');
                    setupPhonePortraitVirtualDisplay(
                      context: context,
                      ffi: ffi,
                      targetWidth: res2x.width,
                      targetHeight: res2x.height,
                    );
                  },
                ),
                const Divider(color: MyTheme.border),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    isZh
                        ? '📐 1264 x 2800 (新型超清全面屏)'
                        : '📐 1264 x 2800 (1.5K Flagship)',
                  ),
                  onTap: () {
                    close();
                    setupPhonePortraitVirtualDisplay(
                      context: context,
                      ffi: ffi,
                      targetWidth: 1264,
                      targetHeight: 2800,
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    isZh
                        ? '📐 1080 x 2400 (20:9 全面屏)'
                        : '📐 1080 x 2400 (20:9 Fullscreen)',
                  ),
                  onTap: () {
                    close();
                    setupPhonePortraitVirtualDisplay(
                      context: context,
                      ffi: ffi,
                      targetWidth: 1080,
                      targetHeight: 2400,
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    isZh
                        ? '📐 1080 x 1920 (16:9 标准竖屏)'
                        : '📐 1080 x 1920 (16:9 Standard)',
                  ),
                  onTap: () {
                    close();
                    setupPhonePortraitVirtualDisplay(
                      context: context,
                      ffi: ffi,
                      targetWidth: 1080,
                      targetHeight: 1920,
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    isZh
                        ? '⚡ 720 x 1600 (流畅省流)'
                        : '⚡ 720 x 1600 (Smooth / low bandwidth)',
                  ),
                  onTap: () {
                    close();
                    setupPhonePortraitVirtualDisplay(
                      context: context,
                      ffi: ffi,
                      targetWidth: 720,
                      targetHeight: 1600,
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.tune),
                  title: Text(
                    isZh
                        ? '✏️ 自定义竖屏分辨率...'
                        : '✏️ Custom portrait resolution...',
                  ),
                  onTap: () {
                    close();
                    showCustomResolutionInputDialog(
                      context: context,
                      ffi: ffi,
                      initialWidth: res1x.width,
                      initialHeight: res1x.height,
                      onConfirm: (w, h) {
                        setupPhonePortraitVirtualDisplay(
                          context: context,
                          ffi: ffi,
                          targetWidth: w,
                          targetHeight: h,
                        );
                      },
                    );
                  },
                ),
                if (hasVirtual) ...[
                  const Divider(color: MyTheme.border),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    leading: const Icon(Icons.tv_off),
                    title: Text(
                      isZh
                          ? '🔌 拔出虚拟屏 (恢复默认显示)'
                          : '🔌 Plug out virtual display',
                    ),
                    onTap: () async {
                      close();
                      await bind.sessionToggleVirtualDisplay(
                        sessionId: ffi.sessionId,
                        index: kAllVirtualDisplay,
                        on: false,
                      );
                      if (pi.displays.isNotEmpty && pi.currentDisplay != 0) {
                        openMonitorInTheSameTab(0, ffi, pi);
                      }
                      BotToast.showText(
                        text:
                            isZh ? '已拔出虚拟显示器' : 'Virtual displays plugged out',
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

TTextMenu? getVirtualDisplayMenu(FFI ffi, String id) {
  if (!showVirtualDisplayMenu(ffi)) {
    return null;
  }
  return TTextMenu(
    child: Text(translate("Virtual display")),
    onPressed: () {
      ffi.dialogManager.show((setState, close, context) {
        final children = getVirtualDisplayMenuChildren(ffi, id, close);
        return CustomAlertDialog(
          title: Text(translate('Virtual display')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

TTextMenu? getResolutionMenu(BuildContext context, FFI ffi, String id) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final resolutions = pi.resolutions;
  final display = pi.tryGetDisplayIfNotAllDisplay(display: pi.currentDisplay);

  final visible = ffiModel.keyboard && display != null;
  if (!visible) return null;

  final isZh = localeName.startsWith('zh');
  final isPortrait = display.height > display.width;
  final res1x =
      _getClientResolution(context, scale: 1.0, forcePortrait: isPortrait);
  final res15x =
      _getClientResolution(context, scale: 1.5, forcePortrait: isPortrait);
  final res2x =
      _getClientResolution(context, scale: 2.0, forcePortrait: isPortrait);

  return TTextMenu(
    child: Text(translate("Resolution")),
    onPressed: () {
      ffi.dialogManager.show((setState, close, ctx) {
        final children = <Widget>[
          for (var e in resolutions)
            getRadio<String>(
              Text('${e.width}x${e.height}'),
              '${e.width}x${e.height}',
              '${display.width}x${display.height}',
              (value) {
                close();
                bind.sessionChangeResolution(
                  sessionId: ffi.sessionId,
                  display: pi.currentDisplay,
                  width: e.width,
                  height: e.height,
                );
                bind.mainSetPeerOptionSync(
                  id: id,
                  key: 'custom-resolution',
                  value: '${e.width}x${e.height}',
                );
              },
            ),
          const Divider(color: MyTheme.border),
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.stay_current_portrait),
            title: Text(
              isZh
                  ? '📱 匹配本机 1:1 原生 (${res1x.width}x${res1x.height})'
                  : '📱 Match device 1:1 (${res1x.width}x${res1x.height})',
            ),
            onTap: () {
              close();
              bind.sessionChangeResolution(
                sessionId: ffi.sessionId,
                display: pi.currentDisplay,
                width: res1x.width,
                height: res1x.height,
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-vdd-scale',
                value: '1.0',
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-resolution',
                value: '${res1x.width}x${res1x.height}',
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.zoom_in),
            title: Text(
              isZh
                  ? '📱 匹配本机 1.5:1 舒适 (${res15x.width}x${res15x.height})'
                  : '📱 Match device 1.5:1 (${res15x.width}x${res15x.height})',
            ),
            onTap: () {
              close();
              bind.sessionChangeResolution(
                sessionId: ffi.sessionId,
                display: pi.currentDisplay,
                width: res15x.width,
                height: res15x.height,
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-vdd-scale',
                value: '1.5',
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-resolution',
                value: '${res15x.width}x${res15x.height}',
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.touch_app),
            title: Text(
              isZh
                  ? '📱 匹配本机 2:1 大图标 (${res2x.width}x${res2x.height})'
                  : '📱 Match device 2:1 (${res2x.width}x${res2x.height})',
            ),
            onTap: () {
              close();
              bind.sessionChangeResolution(
                sessionId: ffi.sessionId,
                display: pi.currentDisplay,
                width: res2x.width,
                height: res2x.height,
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-vdd-scale',
                value: '2.0',
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-resolution',
                value: '${res2x.width}x${res2x.height}',
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(
              isPortrait ? '📐 1264 x 2800 (新型全面屏)' : '📐 2800 x 1264 (新型全面屏)',
            ),
            onTap: () {
              close();
              final w = isPortrait ? 1264 : 2800;
              final h = isPortrait ? 2800 : 1264;
              bind.sessionChangeResolution(
                sessionId: ffi.sessionId,
                display: pi.currentDisplay,
                width: w,
                height: h,
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-resolution',
                value: '${w}x$h',
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(
              isPortrait
                  ? '📐 1080 x 2400 (20:9 全面屏)'
                  : '📐 2400 x 1080 (20:9 全面屏)',
            ),
            onTap: () {
              close();
              final w = isPortrait ? 1080 : 2400;
              final h = isPortrait ? 2400 : 1080;
              bind.sessionChangeResolution(
                sessionId: ffi.sessionId,
                display: pi.currentDisplay,
                width: w,
                height: h,
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-resolution',
                value: '${w}x$h',
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.tune),
            title: Text(
              isZh ? '✏️ 自定义分辨率...' : '✏️ Custom resolution...',
            ),
            onTap: () {
              close();
              showCustomResolutionInputDialog(
                context: context,
                ffi: ffi,
                initialWidth: res1x.width,
                initialHeight: res1x.height,
                onConfirm: (w, h) {
                  bind.sessionChangeResolution(
                    sessionId: ffi.sessionId,
                    display: pi.currentDisplay,
                    width: w,
                    height: h,
                  );
                  bind.mainSetPeerOptionSync(
                    id: id,
                    key: 'custom-resolution',
                    value: '${w}x$h',
                  );
                },
              );
            },
          ),
        ];
        return CustomAlertDialog(
          title: Text(translate('Resolution')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

void sendPrompt(bool isMac, String key) {
  final old = isMac ? gFFI.inputModel.command : gFFI.inputModel.ctrl;
  if (isMac) {
    gFFI.inputModel.command = true;
  } else {
    gFFI.inputModel.ctrl = true;
  }
  gFFI.inputModel.inputKey(key);
  if (isMac) {
    gFFI.inputModel.command = old;
  } else {
    gFFI.inputModel.ctrl = old;
  }
}

class FABLocation extends FloatingActionButtonLocation {
  FloatingActionButtonLocation location;
  double offsetX;
  double offsetY;
  FABLocation(this.location, this.offsetX, this.offsetY);

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final offset = location.getOffset(scaffoldGeometry);
    return Offset(offset.dx + offsetX, offset.dy + offsetY);
  }
}
