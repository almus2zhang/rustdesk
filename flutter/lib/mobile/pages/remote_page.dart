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

class RemotePage extends StatefulWidget {
  RemotePage(
      {Key? key,
      required this.id,
      this.password,
      this.isSharedPassword,
      this.forceRelay,
      this.isUsbDisplay = false,
      this.isSecondaryDisplay = false})
      : super(key: key);

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final bool isUsbDisplay;
  final bool isSecondaryDisplay;

  @override
  State<RemotePage> createState() => _RemotePageState(id);
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  bool get isSecondary =>
      widget.isUsbDisplay ||
      widget.isSecondaryDisplay ||
      widget.id.startsWith("127.0.0.1");

  void _sendPhysicalResolutionToServer(
      {bool forcePhysical = false, String? forcedOrientation}) {
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
        final savedOrientation = bind.mainGetPeerOptionSync(
            id: widget.id, key: 'custom-display-orientation');
        if (savedOrientation.isEmpty || savedOrientation == 'auto') {
          _sendPhysicalResolutionToServer();
        }
      }
    }
  }

  Timer? _timer;
  final RxBool _showBar = false.obs;
  bool _showGestureHelp = false;
  String _value = '';
  Orientation? _currentOrientation;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;

  final _blockableOverlayState = BlockableOverlayState();
  StreamSubscription? _displaysSubscription;
  bool _hasAutoSwitchedDisplay = false;
  bool _firstImageReceived = false;
  int _initialDisplayCount = 0;

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false; // use soft keyboard

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
    if (isSecondary && !gFFI.ffiModel.touchMode) {
      gFFI.ffiModel.toggleTouchMode();
    }
    // Set 120 FPS for USB secondary display to minimize sampling/VSync latency, 60 FPS for others
    final savedFps =
        bind.mainGetPeerOptionSync(id: widget.id, key: 'custom-fps');
    final defaultFps = isSecondary ? '120' : '60';
    final fpsVal = int.tryParse(savedFps.isNotEmpty ? savedFps : defaultFps) ?? (isSecondary ? 120 : 60);
    if (savedFps.isEmpty) {
      bind.mainSetPeerOptionSync(id: widget.id, key: 'custom-fps', value: defaultFps);
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
      _initUsbSurface();
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
    _displaysSubscription?.cancel();
    _destroyUsbSurface();
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
    _iosKeyboardWorkaroundTimer?.cancel();
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

  void openKeyboard() {
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

  Future<void> _initUsbSurface() async {
    if (!isAndroid) return;
    try {
      final dm = await const MethodChannel('com.carriez.flutter_hbb/service')
          .invokeMethod('get_screen_metrics');
      final w = (dm is Map && dm['width'] is int) ? dm['width'] as int : 1920;
      final h = (dm is Map && dm['height'] is int) ? dm['height'] as int : 1080;
      final res = await const MethodChannel('com.carriez.flutter_hbb/service')
          .invokeMethod('create_usb_surface', {
        'width': w,
        'height': h,
      });
      if (res is int && res >= 0) {
        debugPrint('Direct USB Surface Texture created with id: $res, ${w}x$h');
        gFFI.imageModel.usbTextureId = res;
      }
    } catch (e) {
      debugPrint('Failed to create USB surface texture: $e');
    }
  }

  Future<void> _destroyUsbSurface() async {
    if (!isAndroid) return;
    try {
      gFFI.imageModel.usbTextureId = null;
      await const MethodChannel('com.carriez.flutter_hbb/service')
          .invokeMethod('destroy_usb_surface');
    } catch (e) {
      debugPrint('Failed to destroy USB surface texture: $e');
    }
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

    // USB plugs the monitor in before login, so it is already in the first
    // frame. A WiFi invite adds it afterwards: wait for that display-list
    // change, otherwise a host with several physical monitors would be
    // switched to the wrong one.
    final usbPrePlugged = widget.id.startsWith("127.0.0.1");
    final virtualDisplayReady = displays.length >= 2 &&
        (usbPrePlugged || displays.length > _initialDisplayCount);
    if (!virtualDisplayReady) return;

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
    final bool isLandscape = orientation == Orientation.landscape;
    final ffiModel = Provider.of<FfiModel>(context);

    Widget buildBtn(
        {required Widget icon,
        required VoidCallback? onPressed,
        Color? backgroundColor,
        BorderRadius? borderRadius,
        String? tooltip}) {
      Widget btn = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
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
      buildBtn(
        icon: const Icon(Icons.tv, color: Colors.white, size: 20),
        tooltip: translate('Display'),
        onPressed: () {
          setState(() => _showEdit = false);
          showOptions(context, widget.id, gFFI.dialogManager);
        },
      ),
      // 3. Soft Keyboard
      if (!isWebDesktop && !ffiModel.viewOnly && ffiModel.keyboard)
        buildBtn(
          icon: const Icon(Icons.keyboard, color: Colors.white, size: 20),
          tooltip: translate('Keyboard'),
          onPressed: openKeyboard,
        ),
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
              ? const Color(0xFF0071FF) // 选中底色为蓝色
              : const Color(0x604A5568), // 未选中底色为灰色
          borderRadius: BorderRadius.circular(19),
          tooltip: !ffiModel.touchMode
              ? (localeName.startsWith('zh')
                  ? '鼠标模式 (已选中，点击打开说明与设置)'
                  : 'Mouse Mode (Selected, tap for menu)')
              : (localeName.startsWith('zh')
                  ? '鼠标模式 (点击切换)'
                  : 'Mouse Mode (Tap to select)'),
          onPressed: () {
            if (ffiModel.touchMode) {
              ffiModel.toggleTouchMode();
              bind.mainSetLocalOption(key: kOptionTouchMode, value: 'N');
              BotToast.showText(
                text: localeName.startsWith('zh')
                    ? '已切换至鼠标模式'
                    : 'Switched to Mouse Mode',
              );
              if (mounted) setState(() {});
            } else {
              setState(() => _showGestureHelp = !_showGestureHelp);
            }
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
      // 6. Chat
      if (!isWeb)
        buildBtn(
          icon: isAndroid
              ? SvgPicture.asset(
                  'assets/chat.svg',
                  width: 20,
                  height: 20,
                  colorFilter:
                      const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                )
              : const Icon(Icons.message, color: Colors.white, size: 20),
          tooltip: translate('Chat'),
          onPressed: () => isAndroid
              ? showChatOptions(widget.id)
              : onPressedTextChat(widget.id),
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

    final double barWidth = isLandscape
        ? 48.0
        : min(neededLength, size.width - padding.left - padding.right - 16.0);
    final double barHeight = isLandscape
        ? min(neededLength, size.height - padding.top - padding.bottom - 16.0)
        : 48.0;

    bool collapseAtStart;
    IconData collapseIcon;
    double barX;
    double barY;

    if (isLandscape) {
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
          _showBar.value = false;
          if (mounted) setState(() {});
        }
      },
      onPointerCancel: (event) {
        if (_isFabDragging) {
          _saveFabPosition(orientation);
          _isFabDragging = false;
        }
      },
      child: Tooltip(
        message: translate('Collapse'),
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
            width: isLandscape ? barWidth : null,
            height: isLandscape ? null : barHeight,
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
              vertical: isLandscape ? 4.0 : 2.0,
            ),
            child: SingleChildScrollView(
              scrollDirection: isLandscape ? Axis.vertical : Axis.horizontal,
              child: isLandscape
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
    return KeyHelpTools(
        isTablet: isTablet,
        showBar: _showBar.value,
        keyboardIsVisible: keyboardIsVisible,
        showGestureHelp: _showGestureHelp);
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
            child: Container(
              color: Colors.transparent,
              child: Stack(
                children: [
                  Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      if (_showEdit) {
                        _mobileFocusNode.requestFocus();
                      }
                    },
                    child: SizedBox.expand(
                      child: ImagePaint(ffiModel: gFFI.ffiModel),
                    ),
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
        Positioned(
          top: 10,
          right: 10,
          child: QualityMonitor(gFFI.qualityMonitorModel),
        ),
        _buildKeyHelpTools(isTablet, keyboardIsVisible),
        SizedBox(
          width: 0,
          height: 0,
          child: !_showEdit
              ? Container()
              : TextFormField(
                  textInputAction: TextInputAction.newline,
                  autocorrect: true,
                  enableSuggestions: true,
                  autofocus: true,
                  focusNode: _mobileFocusNode,
                  maxLines: null,
                  controller: _textController,
                  // trick way to make backspace work always
                  keyboardType: TextInputType.multiline,
                  onChanged: handleSoftKeyboardInput,
                ).workaroundFreezeLinuxMint(),
        ),
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
                  _showEdit = false;
                  gFFI.invokeMethod("enable_soft_keyboard", false);
                  _mobileFocusNode.unfocus();
                  _physicalFocusNode.requestFocus();
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
              child: Icon(
                (showKeyboardHideFab || _showGestureHelp)
                    ? Icons.expand_more
                    : (_showBar.value ? Icons.close : Icons.menu),
                color: Colors.white,
                size: 24,
              ),
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

    final List<PopupMenuEntry<int>> more = [
      ...mobileActionMenus
          .asMap()
          .entries
          .map((e) =>
              PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
          .toList(),
      if (mobileActionMenus.isNotEmpty) PopupMenuDivider(),
      ...menus
          .asMap()
          .entries
          .map((e) => PopupMenuItem<int>(
              child: e.value.getChild(),
              value: e.key + mobileActionMenus.length))
          .toList(),
    ];
    () async {
      var index = await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(x, y, x, y),
        items: more,
        elevation: 8,
      );
      if (index != null) {
        if (index < mobileActionMenus.length) {
          mobileActionMenus[index].onPressed?.call();
        } else if (index < mobileActionMenus.length + more.length) {
          menus[index - mobileActionMenus.length].onPressed?.call();
        }
      }
    }();
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
  final ValueChanged<bool>? onExpandToggle;

  KeyHelpTools({
    this.isTablet = false,
    this.showBar = true,
    required this.keyboardIsVisible,
    required this.showGestureHelp,
    this.embedded = false,
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
  void initState() {
    super.initState();
    _collapsed =
        bind.mainGetLocalOption(key: 'key_help_tools_collapsed') == 'Y';
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
        color: active
            ? const Color(0xFF1976D2)
            : const Color(0x38FFFFFF),
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
      final size = MediaQuery.of(context).size;
      final curPos = _isCollapsedPosInit
          ? _collapsedPos
          : Offset(max(0.0, size.width - 64 - 10), 10);
      return Positioned(
        left: curPos.dx,
        top: curPos.dy,
        child: Listener(
          onPointerDown: (event) {
            _collapsedDragStartPos = event.position;
            _isCollapsedDragging = false;
          },
          onPointerMove: (event) {
            if (!_isCollapsedDragging &&
                (event.position - _collapsedDragStartPos).distance > 5) {
              _isCollapsedDragging = true;
            }
            if (_isCollapsedDragging) {
              final newPos = Offset(
                (_collapsedPos.dx + event.delta.dx)
                    .clamp(0.0, max(0.0, size.width - 64)),
                (_collapsedPos.dy + event.delta.dy)
                    .clamp(0.0, max(0.0, size.height - 36)),
              );
              setState(() {
                _collapsedPos = newPos;
              });
            }
          },
          onPointerUp: (event) {
            if (!_isCollapsedDragging) {
              setState(() {
                _collapsed = false;
                bind.mainSetLocalOption(
                    key: 'key_help_tools_collapsed', value: 'N');
              });
            } else {
              _trySaveCollapsedPos();
            }
            _isCollapsedDragging = false;
          },
          onPointerCancel: (_) {
            if (_isCollapsedDragging) _trySaveCollapsedPos();
            _isCollapsedDragging = false;
          },
          child: Material(
            color: const Color(0xBB000000),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.keyboard_outlined, size: 16, color: Colors.white),
                  SizedBox(width: 4),
                  Icon(Icons.expand_more, size: 14, color: Colors.white70),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;
    final isMac = gFFI.ffiModel.pi.platform == kPeerPlatformMacOS;
    final ctrlLabel = isMac ? 'Cmd' : 'Ctrl';

    const gap = 2.0;
    final isNarrow = size.width < (14 * 36.0 + 13 * gap + 24.0);
    final cols = isNarrow ? 7 : 14;
    final itemW = isNarrow
        ? ((min(size.width - 20.0, 420.0) - (cols - 1) * gap) / cols).clamp(34.0, 48.0)
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
    final kHome = k(icon: Icons.first_page, tooltip: 'Home', onTap: () => inputModel.inputKey('VK_HOME'));
    final kUp = k(icon: Icons.arrow_upward, tooltip: 'Up', onTap: () => inputModel.inputKey('VK_UP'));
    final kEnd = k(icon: Icons.last_page, tooltip: 'End', onTap: () => inputModel.inputKey('VK_END'));
    final kCtrlS = k(customChild: _comboKeyChild(Icons.save_outlined, '$ctrlLabel+S'), tooltip: '$ctrlLabel+S', onTap: () => sendPrompt(isMac, 'VK_S'));
    final kCtrlC = k(customChild: _comboKeyChild(Icons.copy_all, '$ctrlLabel+C'), tooltip: '$ctrlLabel+C', onTap: () => sendPrompt(isMac, 'VK_C'));
    final kCtrlX = k(customChild: _comboKeyChild(Icons.content_cut, '$ctrlLabel+X'), tooltip: '$ctrlLabel+X', onTap: () => sendPrompt(isMac, 'VK_X'));

    final kTab = k(icon: Icons.keyboard_tab, tooltip: 'Tab', onTap: () => inputModel.inputKey('VK_TAB'));
    final kLeft = k(icon: Icons.arrow_back, tooltip: 'Left', onTap: () => inputModel.inputKey('VK_LEFT'));
    final kDown = k(icon: Icons.arrow_downward, tooltip: 'Down', onTap: () => inputModel.inputKey('VK_DOWN'));
    final kRight = k(icon: Icons.arrow_forward, tooltip: 'Right', onTap: () => inputModel.inputKey('VK_RIGHT'));
    final kEnter = k(icon: Icons.keyboard_return, tooltip: 'Enter', onTap: () => inputModel.inputKey('VK_ENTER'));
    final kCtrlEnter = k(customChild: _comboKeyChild(Icons.keyboard_return, '^Enter'), tooltip: '$ctrlLabel+Enter', onTap: () => sendPrompt(isMac, 'VK_ENTER'));
    final kCtrlV = k(customChild: _comboKeyChild(Icons.content_paste, '$ctrlLabel+V'), tooltip: '$ctrlLabel+V', onTap: () => sendPrompt(isMac, 'VK_V'));

    final kPgUp = k(icon: Icons.keyboard_double_arrow_up, tooltip: 'Page up', onTap: () => inputModel.inputKey('VK_PRIOR'));
    final kAlt = k(label: 'Alt', active: inputModel.alt, onTap: () => setState(() => inputModel.alt = !inputModel.alt));
    final kShift = k(label: 'Shift', active: inputModel.shift, onTap: () => setState(() => inputModel.shift = !inputModel.shift));
    final kIns = k(label: 'Ins', tooltip: 'Insert', onTap: () => inputModel.inputKey('VK_INSERT'));
    final kDel = k(icon: Icons.delete_outline, tooltip: 'Delete', onTap: () => inputModel.inputKey('VK_DELETE'));
    final kPrint = k(customChild: _comboKeyChild(Icons.camera_alt_outlined, 'Print'), tooltip: 'PrintScreen', onTap: () => inputModel.inputKey('VK_SNAPSHOT'));

    final kPgDn = k(icon: Icons.keyboard_double_arrow_down, tooltip: 'Page down', onTap: () => inputModel.inputKey('VK_NEXT'));
    final kCtrl = k(label: 'Ctrl', active: inputModel.ctrl, onTap: () => setState(() => inputModel.ctrl = !inputModel.ctrl));
    final kWin = k(icon: Icons.window, active: inputModel.command, tooltip: 'Win', onTap: () => setState(() => inputModel.command = !inputModel.command));
    final kFn = k(label: 'Fn', active: _fn, tooltip: 'Fn (F1-F12)', onTap: () => setState(() {
      _fn = !_fn;
      widget.onExpandToggle?.call(_fn);
    }));
    final kBack = k(icon: Icons.backspace_outlined, tooltip: 'Backspace', onTap: () => inputModel.inputKey('VK_BACK'));

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
        [kEsc, kHome, kUp, kEnd, kCtrlS, kCtrlC, kCtrlX, kPgUp, kAlt, kShift, kIns, kDel, kPrint, kMoveScreenLeft],
        [kTab, kLeft, kDown, kRight, kEnter, kCtrlEnter, kCtrlV, kPgDn, kCtrl, kWin, kFn, kBack, kMoveScreenRight, kHide],
      ];
    }

    final fnKeys = <Widget>[
      for (var i = 1; i <= 12; ++i)
        k(label: 'F$i', onTap: () => inputModel.inputKey('VK_F$i')),
    ];

    final qwertyKeyW = isNarrow
        ? ((totalGridW - 9 * gap) / 10).clamp(24.0, itemW)
        : itemW;
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
    final usbTextureId = m.usbTextureId;
    if (usbTextureId != null && usbTextureId >= 0) {
      final rect = ffiModel.pi.getDisplayRect(0);
      final w = (rect != null && rect.width > 0) ? rect.width : 1920.0;
      final h = (rect != null && rect.height > 0) ? rect.height : 1080.0;
      return Transform.translate(
        offset: Offset(c.x, c.y + adjust),
        child: Transform.scale(
          scale: s,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: w,
            height: h,
            child: Texture(textureId: usbTextureId),
          ),
        ),
      );
    }

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
                    await bind.sessionPeerOption(
                        sessionId: gFFI.sessionId,
                        name: 'get_window_list',
                        value: '');
                  },
                ),
              ),
            ],
          )),
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
          const SizedBox(height: 4),
          ...codecButtons,
          const SizedBox(height: 4),
          ...resolutionButtons,
          const SizedBox(height: 4),
          ...orientationButtons,
          const SizedBox(height: 4),
          ...appModeButtons,
          const SizedBox(height: 4),
          ...keyboardLayoutButtons,
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

Resolution _getPhonePortraitDimensions(BuildContext context) {
  try {
    final media = MediaQuery.of(context);
    var rawW = (media.size.width * media.devicePixelRatio).round();
    var rawH = (media.size.height * media.devicePixelRatio).round();
    if (rawW > rawH) {
      final tmp = rawW;
      rawW = rawH;
      rawH = tmp;
    }
    final w = (rawW ~/ 2) * 2;
    final h = (rawH ~/ 2) * 2;
    if (w > 0 && h > 0) {
      return Resolution(w, h);
    }
  } catch (e) {
    debugPrint('Failed to get phone portrait dimensions: $e');
  }
  return Resolution(1080, 2400);
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
          targetW = pSize.width.round() & ~1;
          targetH = pSize.height.round() & ~1;
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
        "Sending secondary display resolution to server: ${targetW}x$targetH (orientation: $orientationMode)");
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
    if (pi.isRustDeskIdd) {
      await bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: 1, on: true);
    } else if (pi.isAmyuniIdd) {
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
  final phoneRes = _getPhonePortraitDimensions(context);

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
                        ? '📱 匹配本机屏幕 (${phoneRes.width}x${phoneRes.height})'
                        : '📱 Match phone screen (${phoneRes.width}x${phoneRes.height})',
                  ),
                  onTap: () {
                    close();
                    setupPhonePortraitVirtualDisplay(
                      context: context,
                      ffi: ffi,
                      targetWidth: phoneRes.width,
                      targetHeight: phoneRes.height,
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
                      initialWidth: phoneRes.width,
                      initialHeight: phoneRes.height,
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
  final phoneRes = _getPhonePortraitDimensions(context);

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
                  ? '📱 匹配手机屏幕 (${phoneRes.width}x${phoneRes.height})'
                  : '📱 Match phone screen (${phoneRes.width}x${phoneRes.height})',
            ),
            onTap: () {
              close();
              bind.sessionChangeResolution(
                sessionId: ffi.sessionId,
                display: pi.currentDisplay,
                width: phoneRes.width,
                height: phoneRes.height,
              );
              bind.mainSetPeerOptionSync(
                id: id,
                key: 'custom-resolution',
                value: '${phoneRes.width}x${phoneRes.height}',
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
                initialWidth: phoneRes.width,
                initialHeight: phoneRes.height,
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
