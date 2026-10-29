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

  void _sendPhysicalResolutionToServer() {
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final pSize = view.physicalSize;
      if (pSize.width <= 0 || pSize.height <= 0) return;
      final int targetW = pSize.width.round() & ~1;
      final int targetH = pSize.height.round() & ~1;
      debugPrint("Sending secondary display resolution to server: ${targetW}x$targetH");
      bind.sessionPeerOption(
        sessionId: gFFI.sessionId,
        name: 'secondary_display',
        value: '${targetW}x$targetH',
      );
    } catch (e) {
      debugPrint("Error sending secondary display resolution: $e");
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (isSecondary) {
      _sendPhysicalResolutionToServer();
    }
  }

  Timer? _timer;
  late bool _showBar;
  bool _showGestureHelp = false;
  String _value = '';
  Orientation? _currentOrientation;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;

  final _blockableOverlayState = BlockableOverlayState();
  StreamSubscription? _displaysSubscription;
  bool _hasAutoSwitchedDisplay = false;
  int _prevDisplayCount = 0;

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false; // use soft keyboard

  InputModel get inputModel => gFFI.inputModel;
  SessionID get sessionId => gFFI.sessionId;

  final TextEditingController _textController =
      TextEditingController(text: initText);
  bool _tabletToolsExpanded = true;

  bool get _isHighRes {
    final media = MediaQuery.of(context);
    return (media.size.width * media.devicePixelRatio) >= 2560;
  }

  _RemotePageState(String id) {
    initSharedStates(id);
    gFFI.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;
    gFFI.dialogManager.loadMobileActionsOverlayVisible();
  }

  @override
  void initState() {
    _showBar = isSecondary ? false : !isWebDesktop;
    if (isSecondary && !gFFI.ffiModel.touchMode) {
      gFFI.ffiModel.toggleTouchMode();
    }
    if (isSecondary) {
      final savedCodec =
          bind.mainGetPeerOptionSync(id: widget.id, key: 'codec-preference');
      final savedI444 =
          bind.mainGetPeerOptionSync(id: widget.id, key: 'i444');
      // If never configured, default to low-latency (4:2:0 auto)
      if (savedCodec.isEmpty) {
        bind.mainSetPeerOptionSync(
            id: widget.id, key: 'codec-preference', value: 'auto');
      }
      if (savedI444.isEmpty || savedI444 == 'N') {
        bind.mainSetPeerOptionSync(id: widget.id, key: 'i444', value: '');
      }
      bind.mainSetPeerOptionSync(id: widget.id, key: 'custom-fps', value: '60');
      bind.mainSetPeerOptionSync(
          id: widget.id, key: 'image-quality', value: 'best');

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
      if (isSecondary) {
        _sendPhysicalResolutionToServer();
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

  Widget _bottomWidget() {
    if (_showGestureHelp) return getGestureHelp();
    if (!_showBar || gFFI.ffiModel.pi.displays.isEmpty) return Offstage();

    if (_isHighRes) {
      final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (keyboardHeight > 0) SizedBox(height: keyboardHeight),
          Container(
            color: MyTheme.accent,
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: _tabletToolsExpanded ? 2 : 0),
            child: Row(
              children: [
                Expanded(flex: 3, child: _controlBarIcons(compact: !_tabletToolsExpanded)),
                Container(
                    width: 1,
                    height: _tabletToolsExpanded ? 30 : 20,
                    color: Colors.white24,
                    margin: const EdgeInsets.symmetric(horizontal: 6)),
                Expanded(
                    flex: 7,
                    child: KeyHelpTools(
                        isTablet: true,
                        showBar: true,
                        embedded: true,
                        keyboardIsVisible: true,
                        showGestureHelp: false,
                        onExpandToggle: (expanded) {
                          if (mounted) {
                            setState(() => _tabletToolsExpanded = expanded);
                          }
                        })),
              ],
            ),
          ),
        ],
      );
    }
    return getBottomAppBar();
  }

  void _checkAndAutoSwitchUsbDisplay(List<Display> displays) {
    if (displays.isEmpty) return;

    final currentCount = displays.length;
    // Check if a new display was dynamically added (e.g. from 1 to 2, or 2 to 3, etc.)
    final bool isNewlyAddedDisplay =
        _prevDisplayCount > 0 && currentCount > _prevDisplayCount;
    _prevDisplayCount = currentCount;

    if (currentCount > 1) {
      if (isNewlyAddedDisplay || !_hasAutoSwitchedDisplay) {
        _hasAutoSwitchedDisplay = true;
        // On Windows host, the newly plugged virtual display is appended at the end
        final targetIndex = currentCount - 1;
        if (targetIndex != gFFI.ffiModel.pi.currentDisplay) {
          debugPrint(
              "Auto-switching USB display to newly added monitor $targetIndex (total $currentCount displays)");
          openMonitorInTheSameTab(targetIndex, gFFI, gFFI.ffiModel.pi);
          BotToast.showText(
            text: localeName.startsWith('zh')
                ? '\xe5\xb7\xb2\xe8\x87\xaa\xe5\x8a\xa8\xe5\x88\x87\xe6\x8d\xa2\xe8\x87\xb3\xe6\x96\xb0\xe5\xa2\x9e\xe8\x99\x9a\xe6\x8b\x9f\xe5\x89\xaf\xe5\xb1\x8f (\xe5\xb1\x8f\xe5\xb9\x95 ${targetIndex + 1})'
                : 'Auto-switched to new secondary display (Screen ${targetIndex + 1})',
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = isTabletLayoutMode(context);
    final keyboardIsVisible =
        keyboardVisibilityController.isVisible && _showEdit;
    final showKeyboardHideFab = isTablet && keyboardIsVisible;
    final showActionButton = (!keyboardIsVisible || isTablet) &&
        (!_showBar || showKeyboardHideFab || _showGestureHelp);

    return WillPopScope(
      onWillPop: () async {
        clientClose(sessionId, gFFI);
        return false;
      },
      child: Scaffold(
          extendBody: true,
          extendBodyBehindAppBar: true,
          resizeToAvoidBottomInset: (isAndroid && isTablet) ? false : true,
          // workaround for https://github.com/rustdesk/rustdesk/issues/3131
          floatingActionButtonLocation: showKeyboardHideFab
              ? FABLocation(FloatingActionButtonLocation.endFloat, 0, -35)
              : null,
          floatingActionButton: !showActionButton
              ? null
              : FloatingActionButton(
                  mini: !showKeyboardHideFab,
                  child: Icon(
                    (showKeyboardHideFab || _showGestureHelp)
                        ? Icons.expand_more
                        : Icons.expand_less,
                    color: Colors.white,
                  ),
                  backgroundColor: MyTheme.accent,
                  onPressed: () {
                    setState(() {
                      if (showKeyboardHideFab) {
                        _showEdit = false;
                        gFFI.invokeMethod("enable_soft_keyboard", false);
                        _mobileFocusNode.unfocus();
                        _physicalFocusNode.requestFocus();
                      } else if (_showGestureHelp) {
                        _showGestureHelp = false;
                      } else {
                        _showBar = !_showBar;
                      }
                    });
                  }),
          bottomNavigationBar: Obx(() => Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  gFFI.ffiModel.pi.isSet.isTrue &&
                          gFFI.ffiModel.waitForFirstImage.isTrue
                      ? emptyOverlay(MyTheme.canvasColor)
                      : () {
                          gFFI.ffiModel.tryShowAndroidActionsOverlay();
                          return Offstage();
                        }(),
                  _bottomWidget(),
                  gFFI.ffiModel.pi.isSet.isFalse
                      ? emptyOverlay(MyTheme.canvasColor)
                      : Offstage(),
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
                                child: RawTouchGestureDetectorRegion(
                                  child: getBodyForMobile(),
                                  ffi: gFFI,
                                ),
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

  Widget _controlBarIcons({bool compact = false}) {
    final ffiModel = Provider.of<FfiModel>(context);
    final double iconSize = compact ? 18.0 : 24.0;
    final EdgeInsets padding = compact ? const EdgeInsets.all(4.0) : const EdgeInsets.all(8.0);
    final BoxConstraints constraints = compact
        ? const BoxConstraints(minWidth: 26, minHeight: 26)
        : const BoxConstraints(minWidth: 48, minHeight: 48);

    Widget buildBtn({required Widget icon, required VoidCallback? onPressed}) {
      return IconButton(
        iconSize: iconSize,
        padding: padding,
        constraints: constraints,
        color: Colors.white,
        icon: icon,
        onPressed: onPressed,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Row(
            children: <Widget>[
                  buildBtn(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      clientClose(sessionId, gFFI);
                    },
                  ),
                  buildBtn(
                    icon: const Icon(Icons.tv),
                    onPressed: () {
                      setState(() => _showEdit = false);
                      showOptions(context, widget.id, gFFI.dialogManager);
                    },
                  )
                ] +
                (isWebDesktop || ffiModel.viewOnly || !ffiModel.keyboard
                    ? []
                    : gFFI.ffiModel.isPeerAndroid
                        ? [
                            buildBtn(
                                icon: const Icon(Icons.keyboard),
                                onPressed: openKeyboard),
                            if (isAndroid)
                              buildBtn(
                                icon: const Icon(Icons.language),
                                onPressed: () => gFFI.invokeMethod(
                                    "show_input_method_picker", null),
                              ),
                            buildBtn(
                              icon: const Icon(Icons.build),
                              onPressed: () => gFFI.dialogManager
                                  .toggleMobileActionsOverlay(ffi: gFFI),
                            )
                          ]
                        : [
                            buildBtn(
                                icon: const Icon(Icons.keyboard),
                                onPressed: openKeyboard),
                            if (isAndroid)
                              buildBtn(
                                icon: const Icon(Icons.language),
                                onPressed: () => gFFI.invokeMethod(
                                    "show_input_method_picker", null),
                              ),
                            buildBtn(
                              icon: Icon(gFFI.ffiModel.touchMode
                                  ? Icons.touch_app
                                  : Icons.mouse),
                              onPressed: () => setState(
                                  () => _showGestureHelp = !_showGestureHelp),
                            ),
                          ]) +
                (isWeb
                    ? []
                    : <Widget>[
                        futureBuilder(
                            future: gFFI.invokeMethod(
                                "get_value", "KEY_IS_SUPPORT_VOICE_CALL"),
                            hasData: (isSupportVoiceCall) => buildBtn(
                                  icon: isAndroid && isSupportVoiceCall
                                      ? SvgPicture.asset('assets/chat.svg',
                                          colorFilter: ColorFilter.mode(
                                              Colors.white, BlendMode.srcIn))
                                      : const Icon(Icons.message),
                                  onPressed: () =>
                                      isAndroid && isSupportVoiceCall
                                          ? showChatOptions(widget.id)
                                          : onPressedTextChat(widget.id),
                                ))
                      ]) +
                [
                  buildBtn(
                    icon: const Icon(Icons.more_vert),
                    onPressed: () {
                      setState(() => _showEdit = false);
                      showActions(widget.id);
                    },
                  ),
                ]),
        Obx(() => buildBtn(
              icon: const Icon(Icons.expand_more),
              onPressed: gFFI.ffiModel.waitForFirstImage.isTrue
                  ? null
                  : () {
                      setState(() => _showBar = !_showBar);
                    },
            )),
      ],
    );
  }

  Widget getBottomAppBar() {
    return BottomAppBar(
      elevation: 10,
      color: MyTheme.accent,
      child: _controlBarIcons(),
    );
  }

  bool get showCursorPaint =>
      !gFFI.ffiModel.isPeerAndroid &&
      !gFFI.canvasModel.cursorEmbedded &&
      !gFFI.inputModel.relativeMouseMode.value;

  Widget _buildKeyHelpTools(bool isTablet, bool keyboardIsVisible) {
    if (isTablet && _isHighRes) {
      return const Offstage();
    }
    return KeyHelpTools(
        isTablet: isTablet,
        showBar: _showBar,
        keyboardIsVisible: keyboardIsVisible,
        showGestureHelp: _showGestureHelp);
  }

  Widget getBodyForMobile() {
    final keyboardIsVisible = _showEdit || keyboardVisibilityController.isVisible;
    final isTablet = isTabletLayoutMode(context);
    return Container(
        color: MyTheme.canvasColor,
        child: Stack(children: () {
          final paints = [
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (_showEdit) {
                  _mobileFocusNode.requestFocus();
                }
              },
              child: ImagePaint(ffiModel: gFFI.ffiModel),
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
                      // `onChanged` may be called depending on the input method if this widget is wrapped in
                      // `Focus(onKeyEvent: ..., child: ...)`
                      // For `Backspace` button in the soft keyboard:
                      // en/fr input method:
                      //      1. The button will not trigger `onKeyEvent` if the text field is not empty.
                      //      2. The button will trigger `onKeyEvent` if the text field is empty.
                      // ko/zh/ja input method: the button will trigger `onKeyEvent`
                      //                     and the event will not popup if `KeyEventResult.handled` is returned.
                      onChanged: handleSoftKeyboardInput,
                    ).workaroundFreezeLinuxMint(),
            ),
          ];
          if (showCursorPaint) {
            paints.add(CursorPaint(widget.id));
          }
          if (gFFI.ffiModel.touchMode) {
            paints.add(FloatingMouse(
              ffi: gFFI,
            ));
          } else {
            paints.add(FloatingMouseWidgets(
              ffi: gFFI,
            ));
          }
          final topPadding = MediaQuery.of(context).padding.top;
          final leftPadding = MediaQuery.of(context).padding.left;
          final escTop = max(10.0, isAndroid ? topPadding + 4.0 : 10.0);
          final escLeft = max(10.0, leftPadding + 4.0);
          paints.add(Positioned(
            top: escTop,
            left: escLeft,
            child: Obx(() => gFFI.canvasModel.showEscKey.value
                ? _buildFloatingEscKeyContent()
                : const SizedBox.shrink()),
          ));
          return paints;
        }()));
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
              onTouchModeChange: (t) {
                gFFI.ffiModel.toggleTouchMode();
                final v = gFFI.ffiModel.touchMode ? 'Y' : 'N';
                bind.mainSetLocalOption(key: kOptionTouchMode, value: v);
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
  var _more = true;
  var _fn = false;
  var _pin = false;
  late bool _collapsed;
  final _keyboardVisibilityController = KeyboardVisibilityController();
  final _key = GlobalKey();

  Offset _position = Offset.zero;
  bool _isPositionInitialized = false;
  Orientation? _previousOrientation;
  Offset _preSavedPos = Offset.zero;
  bool _isDragging = false;
  Offset _dragStartPos = Offset.zero;

  @override
  void initState() {
    super.initState();
    _collapsed =
        bind.mainGetLocalOption(key: 'key_help_tools_collapsed') == 'Y';
    if (widget.onExpandToggle != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onExpandToggle!(_more || _fn);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final currentOrientation = MediaQuery.of(context).orientation;
        _previousOrientation = currentOrientation;
        _resetPosition(currentOrientation);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentOrientation = MediaQuery.of(context).orientation;
    if (_previousOrientation == null ||
        _previousOrientation != currentOrientation) {
      _resetPosition(currentOrientation);
    }
    _previousOrientation = currentOrientation;
  }

  @override
  void dispose() {
    _trySavePosition();
    super.dispose();
  }

  String _getPositionKey(Orientation ori) {
    final strOri = ori == Orientation.landscape ? 'l' : 'p';
    return 'kht-$strOri-pos';
  }

  static Offset? _loadPositionFromString(String s) {
    if (s.isEmpty) return null;
    try {
      final m = jsonDecode(s);
      return Offset((m['x'] as num).toDouble(), (m['y'] as num).toDouble());
    } catch (e) {
      return null;
    }
  }

  void _trySavePosition() {
    if (_previousOrientation == null) return;
    if ((_position - _preSavedPos).distanceSquared < 0.1) return;
    final pos = jsonEncode({
      'x': _position.dx,
      'y': _position.dy,
    });
    bind.setLocalFlutterOption(
        k: _getPositionKey(_previousOrientation!), v: pos);
    _preSavedPos = _position;
  }

  void _restorePosition(Orientation ori) {
    final ps = bind.getLocalFlutterOption(k: _getPositionKey(ori));
    final pos = _loadPositionFromString(ps);
    if (pos == null) {
      final size = MediaQuery.of(context).size;
      _position = Offset(
        max(0.0, size.width - 64 - 10),
        10,
      );
    } else {
      _position = pos;
      _preSavedPos = pos;
    }
  }

  void _resetPosition(Orientation ori) {
    setState(() {
      _restorePosition(ori);
      _isPositionInitialized = true;
    });
  }

  void _onDragDelta(Offset delta) {
    final size = MediaQuery.of(context).size;
    Offset newPosition = _position + delta;
    const double iconW = 64;
    const double iconH = 36;
    double minX = 0;
    double minY = 0;
    double maxX = max(0.0, size.width - iconW);
    double maxY = max(0.0, size.height - iconH);
    newPosition = Offset(
      newPosition.dx.clamp(minX, maxX),
      newPosition.dy.clamp(minY, maxY),
    );
    setState(() {
      _position = newPosition;
    });
  }

  InputModel get inputModel => gFFI.inputModel;

  Widget wrap(String text, void Function() onPressed,
      {bool? active, IconData? icon}) {
    final isMultiLine = _more || _fn;
    return TextButton(
        style: TextButton.styleFrom(
          minimumSize: Size(0, 0),
          padding: EdgeInsets.symmetric(
            vertical: widget.embedded
                ? (isMultiLine ? 6.0 : 3.0)
                : 10.0,
            horizontal: widget.embedded
                ? (isMultiLine ? 8.0 : 6.0)
                : 9.75,
          ),
          //adds padding inside the button
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          //limits the touch area to the button area
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4.0),
          ),
          backgroundColor: active == true ? MyTheme.accent80 : null,
        ),
        child: icon != null
            ? Icon(icon, size: widget.embedded ? (isMultiLine ? 14 : 13) : 14, color: Colors.white)
            : Text(translate(text),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: widget.embedded ? (isMultiLine ? 11 : 10.5) : 11,
                  height: 1.1,
                )),
        onPressed: onPressed);
  }

  _updateRect() {
    RenderObject? renderObject = _key.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      Offset pos = renderObject.localToGlobal(Offset.zero);
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
          Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
          widget.keyboardIsVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.embedded && _collapsed) {
      gFFI.cursorModel
          .keyHelpToolsVisibilityChanged(null, widget.keyboardIsVisible);
      final size = MediaQuery.of(context).size;
      final curPos = _isPositionInitialized
          ? _position
          : Offset(max(0.0, size.width - 64 - 10), 10);
      return Positioned(
        left: curPos.dx,
        top: curPos.dy,
        child: Listener(
          onPointerDown: (event) {
            _dragStartPos = event.position;
            _isDragging = false;
          },
          onPointerMove: (event) {
            if (!_isDragging && (event.position - _dragStartPos).distance > 5) {
              _isDragging = true;
            }
            if (_isDragging) {
              _onDragDelta(event.delta);
            }
          },
          onPointerUp: (event) {
            if (_isDragging) {
              _trySavePosition();
            } else {
              setState(() {
                _collapsed = false;
                bind.mainSetLocalOption(
                    key: 'key_help_tools_collapsed', value: 'N');
              });
            }
            _isDragging = false;
          },
          onPointerCancel: (event) {
            if (_isDragging) {
              _trySavePosition();
            }
            _isDragging = false;
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

    final pi = gFFI.ffiModel.pi;
    final isMac = pi.platform == kPeerPlatformMacOS;
    final isWin = pi.platform == kPeerPlatformWindows;
    final isLinux = pi.platform == kPeerPlatformLinux;
    final modifiers = <Widget>[
      wrap('Ctrl ', () {
        setState(() => inputModel.ctrl = !inputModel.ctrl);
      }, active: inputModel.ctrl),
      wrap(' Alt ', () {
        setState(() => inputModel.alt = !inputModel.alt);
      }, active: inputModel.alt),
      wrap('Shift', () {
        setState(() => inputModel.shift = !inputModel.shift);
      }, active: inputModel.shift),
      wrap(isMac ? ' Cmd ' : ' Win ', () {
        setState(() => inputModel.command = !inputModel.command);
      }, active: inputModel.command),
      wrap('Tab', () {
        inputModel.inputKey('VK_TAB');
      }),
    ];
    final keys = <Widget>[
      wrap(
          ' Fn ',
          () => setState(
                () {
                  _fn = !_fn;
                  if (_fn) {
                    _more = false;
                  }
                  widget.onExpandToggle?.call(_more || _fn);
                },
              ),
          active: _fn),
      wrap(
          '',
          () => setState(
                () => _pin = !_pin,
              ),
          active: _pin,
          icon: Icons.push_pin),
      wrap(
          'Hide',
          () => setState(() {
                _collapsed = true;
                bind.mainSetLocalOption(
                    key: 'key_help_tools_collapsed', value: 'Y');
              }),
          icon: Icons.keyboard_hide),

      wrap('', () {
        inputModel.inputKey('VK_LEFT');
      }, icon: Icons.keyboard_arrow_left),
      wrap('', () {
        inputModel.inputKey('VK_UP');
      }, icon: Icons.keyboard_arrow_up),
      wrap('', () {
        inputModel.inputKey('VK_DOWN');
      }, icon: Icons.keyboard_arrow_down),
      wrap('', () {
        inputModel.inputKey('VK_RIGHT');
      }, icon: Icons.keyboard_arrow_right),
      wrap(isMac ? 'Cmd+C' : 'Ctrl+C', () {
        sendPrompt(isMac, 'VK_C');
      }),
      wrap(isMac ? 'Cmd+V' : 'Ctrl+V', () {
        sendPrompt(isMac, 'VK_V');
      }),
      wrap(isMac ? 'Cmd+S' : 'Ctrl+S', () {
        sendPrompt(isMac, 'VK_S');
      }),
      wrap(
          ' ... ',
          () => setState(
                () {
                  _more = !_more;
                  if (_more) {
                    _fn = false;
                  }
                  widget.onExpandToggle?.call(_more || _fn);
                },
              ),
          active: _more),
    ];
    final fn = <Widget>[
      SizedBox(width: 9999),
    ];
    for (var i = 1; i <= 12; ++i) {
      final name = 'F$i';
      fn.add(wrap(name, () {
        inputModel.inputKey('VK_$name');
      }));
    }
    final more = <Widget>[
      SizedBox(width: 9999),
      wrap('Esc', () {
        inputModel.inputKey('VK_ESCAPE');
      }),
      wrap('Home', () {
        inputModel.inputKey('VK_HOME');
      }),
      wrap('End', () {
        inputModel.inputKey('VK_END');
      }),
      wrap('Ins', () {
        inputModel.inputKey('VK_INSERT');
      }),
      wrap('Del', () {
        inputModel.inputKey('VK_DELETE');
      }),
      wrap('PgUp', () {
        inputModel.inputKey('VK_PRIOR');
      }),
      wrap('PgDn', () {
        inputModel.inputKey('VK_NEXT');
      }),
      // to-do: support PrtScr on Mac
      if (isWin || isLinux)
        wrap('PrtScr', () {
          inputModel.inputKey('VK_SNAPSHOT');
        }),
      if (isWin || isLinux)
        wrap('ScrollLock', () {
          inputModel.inputKey('VK_SCROLL');
        }),
      if (isWin || isLinux)
        wrap('Pause', () {
          inputModel.inputKey('VK_PAUSE');
        }),
      if (isWin || isLinux)
        // Maybe it's better to call it "Menu"
        // https://en.wikipedia.org/wiki/Menu_key
        wrap('Menu', () {
          inputModel.inputKey('Apps');
        }),
      wrap('Enter', () {
        inputModel.inputKey('VK_ENTER');
      }),
    ];
    final space = widget.embedded ? 2.0 : (size.width > 320 ? 4.0 : 2.0);
    // 500 ms is long enough for this widget to be built!
    Future.delayed(Duration(milliseconds: 500), () {
      _updateRect();
    });
    final isHighRes = size.width > 2560;
    final expandedWidget = Container(
        key: _key,
        color: (isHighRes || widget.embedded) ? Colors.transparent : Color(0xAA000000),
        padding: EdgeInsets.only(
            top: widget.embedded
                ? 1.0
                : ((isAndroid || !_keyboardVisibilityController.isVisible || isHighRes) ? 4 : 24),
            bottom: widget.embedded ? 1.0 : (isHighRes ? 4 : 8)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.embedded)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6.0, bottom: 2.0),
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _collapsed = true;
                        bind.mainSetLocalOption(
                            key: 'key_help_tools_collapsed', value: 'Y');
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0x33FFFFFF),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.keyboard_hide, size: 14, color: Colors.white70),
                          const SizedBox(width: 4),
                          Text(
                            translate('Hide'),
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Wrap(
              spacing: space,
              runSpacing: space,
              children: <Widget>[SizedBox(width: 9999)] +
                  modifiers +
                  keys +
                  (_fn ? fn : []) +
                  (_more
                      ? more
                      : [
                          wrap('Enter', () {
                            inputModel.inputKey('VK_ENTER');
                          })
                        ]),
            ),
          ],
        ));

    if (widget.embedded) {
      return expandedWidget;
    }

    if (!widget.isTablet) {
      return Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: expandedWidget,
      );
    }
    return Positioned(
      bottom: widget.showBar && gFFI.ffiModel.pi.displays.isNotEmpty ? 60 : 10,
      left: 0,
      right: 0,
      child: expandedWidget,
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
    if (ffiModel.isPeerLinux) {
      final displays = ffiModel.pi.getCurDisplays();
      if (displays.isNotEmpty) {
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
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: buildSegmentButton(
                  text: translate('Custom'),
                  selected: viewStyle.value == kRemoteViewStyleCustom,
                  onTap: () {
                    final r = findRadio(viewStyleRadios, kRemoteViewStyleCustom);
                    r?.onChanged?.call(kRemoteViewStyleCustom);
                    viewStyle.value = kRemoteViewStyleCustom;
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

    final colorModeButtons = [
      buildSectionTitle(localeName.startsWith('zh') ? '色彩与延时模式' : 'Display Mode & Latency'),
      Obx(() {
        final is444 = isI444Enabled.value;
        return Row(
          children: [
            Expanded(
              child: buildSegmentButton(
                text: localeName.startsWith('zh') ? '⚡ 低延时 (4:2:0 硬解)' : '⚡ Low Latency (4:2:0)',
                selected: !is444,
                onTap: () async {
                  isI444Enabled.value = false;
                  await bind.sessionPeerOption(
                      sessionId: gFFI.sessionId, name: 'i444', value: '');
                  bind.mainSetPeerOptionSync(id: id, key: 'i444', value: '');
                  await bind.sessionPeerOption(
                      sessionId: gFFI.sessionId, name: 'codec-preference', value: 'auto');
                  bind.mainSetPeerOptionSync(id: id, key: 'codec-preference', value: 'auto');
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
                text: localeName.startsWith('zh') ? '🎨 真彩 (VP9 4:4:4)' : '🎨 True Color (VP9 4:4:4)',
                selected: is444,
                onTap: () async {
                  isI444Enabled.value = true;
                  await bind.sessionPeerOption(
                      sessionId: gFFI.sessionId, name: 'i444', value: 'Y');
                  bind.mainSetPeerOptionSync(id: id, key: 'i444', value: 'Y');
                  await bind.sessionPeerOption(
                      sessionId: gFFI.sessionId, name: 'codec-preference', value: 'vp9');
                  bind.mainSetPeerOptionSync(id: id, key: 'codec-preference', value: 'vp9');
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
          ...colorModeButtons,
          const SizedBox(height: 4),
          ...codecButtons,
          const SizedBox(height: 4),
          ...resolutionButtons,
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
                    isZh ? '✏️ 自定义竖屏分辨率...' : '✏️ Custom portrait resolution...',
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
                        text: isZh ? '已拔出虚拟显示器' : 'Virtual displays plugged out',
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
