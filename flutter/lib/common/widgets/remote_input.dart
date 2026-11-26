import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/input_model.dart';

import './gestures.dart';

/// 单指滑动滚动到远端的灵敏度：手指移动 1px 对应多少个滚动单位。
/// 原来是 2.2，实测偏快，调到 1.6。
const double kOneFingerScrollSpeed = 1.6;

class RawKeyFocusScope extends StatelessWidget {
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final InputModel inputModel;
  final Widget child;

  RawKeyFocusScope({
    this.focusNode,
    this.onFocusChange,
    required this.inputModel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // https://github.com/flutter/flutter/issues/154053
    final useRawKeyEvents = isLinux && !isWeb;
    // FIXME: On Windows, `AltGr` will generate `Alt` and `Control` key events,
    // while `Alt` and `Control` are separated key events for en-US input method.
    return FocusScope(
        autofocus: true,
        child: Focus(
            autofocus: true,
            canRequestFocus: true,
            focusNode: focusNode,
            onFocusChange: onFocusChange,
            onKey: useRawKeyEvents
                ? (FocusNode data, RawKeyEvent event) =>
                    inputModel.handleRawKeyEvent(event)
                : null,
            onKeyEvent: useRawKeyEvents
                ? null
                : (FocusNode node, KeyEvent event) =>
                    inputModel.handleKeyEvent(event),
            child: child));
  }
}

// For virtual mouse when using the mouse mode on mobile.
// Special hold-drag mode: one finger holds a button (left/right button), another finger pans.
// This flag is to override the scale gesture to a pan gesture.
bool isSpecialHoldDragActive = false;
// Cache the last focal point to calculate deltas in special hold-drag mode.
Offset _lastSpecialHoldDragFocalPoint = Offset.zero;

class RawTouchGestureDetectorRegion extends StatefulWidget {
  final Widget child;
  final FFI ffi;
  final bool isCamera;
  late final InputModel inputModel = ffi.inputModel;
  late final FfiModel ffiModel = ffi.ffiModel;

  RawTouchGestureDetectorRegion({
    required this.child,
    required this.ffi,
    this.isCamera = false,
  });

  @override
  State<RawTouchGestureDetectorRegion> createState() =>
      _RawTouchGestureDetectorRegionState();
}

/// touchMode only:
///   LongPress -> right click
///   OneFingerPan -> start/end -> left down start/end
///   onDoubleTapDown -> move to
///   onLongPressDown => move to
///
/// mouseMode only:
///   DoubleFiner -> right click
///   HoldDrag -> left drag
enum TwoFingerModeState {
  undecided,
  scrolling,
  canvasPanZoom,
}

class _RawTouchGestureDetectorRegionState
    extends State<RawTouchGestureDetectorRegion> {
  Offset _cacheLongPressPosition = Offset(0, 0);
  // Timestamp of the last long press event.
  int _cacheLongPressPositionTs = 0;
  double _mouseScrollIntegral = 0; // mouse scroll speed controller
  double _scale = 1;

  // Workaround tap down event when two fingers are used to scale(mobile)
  TapDownDetails? _lastTapDownDetails;

  PointerDeviceKind? lastDeviceKind;

  // For touch mode, onDoubleTap
  // `onDoubleTap()` does not provide the position of the tap event.
  Offset _lastPosOfDoubleTapDown = Offset.zero;
  bool _touchModePanStarted = false;
  Offset _doubleFinerTapPosition = Offset.zero;

  // For mouse mode, we need to block the events when the cursor is in a blocked area.
  // So we need to cache the last tap down position.
  Offset? _lastTapDownPositionForMouseMode;
  // Cache global position for onTap (which lacks position info).
  Offset? _lastTapDownGlobalPosition;

  // Touch mode: snap rapid second tap within double-tap threshold to first tap's
  // position so double-click works reliably with 0ms tap delay.
  DateTime? _lastTouchTapTime;
  Offset? _lastTouchTapLocalPos;

  // Mouse mode: long press + move = left button drag; stationary long press = right click.
  bool _mouseModeLongPressActive = false;
  bool _mouseModeLongPressDragging = false;
  Offset _mouseModeLongPressOrigin = Offset.zero;
  Offset _mouseModeLongPressLastPos = Offset.zero;

  double _twoFingerScrollX = 0;
  double _twoFingerScrollY = 0;
  double _remoteScaleAccumulator = 0;
  bool _hasRemoteScaleBaseline = false;
  int _remoteScaleDirection = 0;
  DateTime _lastRemoteScaleSendTime = DateTime.fromMillisecondsSinceEpoch(0);
  double _oneFingerScrollX = 0;
  double _oneFingerScrollY = 0;
  Timer? _oneFingerInertiaTimer;
  Timer? _twoFingerInertiaTimer;
  TwoFingerModeState _twoFingerState = TwoFingerModeState.undecided;
  Offset _twoFingerTotalFocalDelta = Offset.zero;
  Timer? _twoFingerHoldTimer;
  // 单程序模式下双指手势可能是"捏合缩放"也可能是"双指滚动平移"，
  // 这次手势一旦出现过明显的两指间距变化，就按缩放处理。
  bool _twoFingerPinching = false;

  bool get _isHighRes {
    final media = MediaQuery.of(context);
    return (media.size.width * media.devicePixelRatio) >= 2560;
  }

  FFI get ffi => widget.ffi;
  FfiModel get ffiModel => widget.ffiModel;
  InputModel get inputModel => widget.inputModel;
  bool get handleTouch => (isDesktop || isWebDesktop) || ffiModel.touchMode;
  SessionID get sessionId => ffi.sessionId;

  @override
  void dispose() {
    _oneFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer?.cancel();
    _twoFingerHoldTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      child: widget.child,
      gestures: makeGestures(context),
    );
  }

  bool isNotTouchBasedDevice() {
    return !kTouchBasedDeviceKinds.contains(lastDeviceKind);
  }

  // Mobile, mouse mode.
  // Check if should block the mouse tap event (`_lastTapDownPositionForMouseMode`).
  bool shouldBlockMouseModeEvent() {
    return _lastTapDownPositionForMouseMode != null &&
        ffi.cursorModel.shouldBlock(_lastTapDownPositionForMouseMode!.dx,
            _lastTapDownPositionForMouseMode!.dy);
  }

  Offset _resolveTouchTapPosition(Offset localPos,
      {required bool updateHistory}) {
    if (!isMobile) {
      return localPos;
    }
    final now = DateTime.now();
    final lastTime = _lastTouchTapTime;
    final lastPos = _lastTouchTapLocalPos;
    if (lastTime != null &&
        lastPos != null &&
        now.difference(lastTime).inMilliseconds <= 350 &&
        (localPos - lastPos).distance <= 32.0) {
      if (updateHistory) {
        _lastTouchTapTime = now;
      }
      return lastPos;
    }
    if (updateHistory) {
      _lastTouchTapTime = now;
      _lastTouchTapLocalPos = localPos;
    }
    return localPos;
  }

  onTapDown(TapDownDetails d) async {
    _oneFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer = null;
    lastDeviceKind = d.kind;
    _lastTapDownGlobalPosition = d.globalPosition;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      final targetPos =
          _resolveTouchTapPosition(d.localPosition, updateHistory: false);
      _lastPosOfDoubleTapDown = targetPos;
      // Desktop or mobile "Touch mode"
      _lastTapDownDetails = d;
      // Move the cursor on DOWN, exactly like onDoubleTapDown does. At the
      // screen edge Android can cancel the pointer (edge gesture /
      // accidental-touch suppression) or the gesture arena can reject the
      // tap, so onTapUp never runs and the cursor stays behind. A double tap
      // "fixes" it only because its down callback already moved the cursor.
      await ffi.cursorModel.move(targetPos.dx, targetPos.dy);
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
    }
  }

  onTapUp(TapUpDetails d) async {
    _lastTapDownDetails = null;
    if (isNotTouchBasedDevice()) {
      return;
    }
    // Filter duplicate touch tap events on iOS (Magic Mouse issue).
    if (inputModel.shouldIgnoreTouchTap(d.globalPosition)) {
      return;
    }
    if (handleTouch) {
      final targetPos =
          _resolveTouchTapPosition(d.localPosition, updateHistory: true);
      // `move()` already validates and clamps the position. Gating on the
      // tap-down position as well drops taps near the border whenever the
      // finger moves a pixel between down and up.
      final isMoved = await ffi.cursorModel.move(targetPos.dx, targetPos.dy);
      if (isMoved) {
        // If pan already handled 'down', don't send it again.
        if (!_touchModePanStarted) {
          await inputModel.tapDown(MouseButtons.left);
        }
        await inputModel.tapUp(MouseButtons.left);
      }
    }
  }

  onTap() async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    // Filter duplicate touch tap events on iOS (Magic Mouse issue).
    final lastPos = _lastTapDownGlobalPosition;
    if (lastPos != null && inputModel.shouldIgnoreTouchTap(lastPos)) {
      return;
    }
    if (!handleTouch) {
      // Cannot use `_lastTapDownDetails` because Flutter calls `onTapUp` before `onTap`, clearing the cached details.
      // Using `_lastTapDownPositionForMouseMode` instead.
      if (shouldBlockMouseModeEvent()) {
        return;
      }
      // Mobile, "Mouse mode"
      await inputModel.tap(MouseButtons.left);
    }
  }

  onDoubleTapDown(TapDownDetails d) async {
    _twoFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer = null;
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
    }
  }

  onDoubleTap() async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (ffiModel.touchMode && ffi.cursorModel.lastIsBlocked) {
      return;
    }
    if (handleTouch &&
        !ffi.cursorModel.isInRemoteRect(_lastPosOfDoubleTapDown)) {
      return;
    }
    // Check if the position is in a blocked area when using the mouse mode.
    if (!handleTouch) {
      if (shouldBlockMouseModeEvent()) {
        return;
      }
    }
    await inputModel.tap(MouseButtons.left);
    await inputModel.tap(MouseButtons.left);
  }

  onLongPressDown(LongPressDownDetails d) async {
    _twoFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer = null;
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      _cacheLongPressPosition = d.localPosition;
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }
      _cacheLongPressPositionTs = DateTime.now().millisecondsSinceEpoch;
      if (ffiModel.isPeerMobile) {
        await ffi.cursorModel
            .move(_cacheLongPressPosition.dx, _cacheLongPressPosition.dy);
        await inputModel.tapDown(MouseButtons.left);
      }
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
    }
  }

  onLongPressStart(LongPressStartDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isMobile && !handleTouch) {
      if (isSpecialHoldDragActive || shouldBlockMouseModeEvent()) {
        return;
      }
      _mouseModeLongPressActive = true;
      _mouseModeLongPressDragging = false;
      _mouseModeLongPressOrigin = d.localPosition;
      _mouseModeLongPressLastPos = d.localPosition;
    }
  }

  onLongPressEnd(LongPressEndDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isMobile && !handleTouch) {
      if (!_mouseModeLongPressActive) {
        return;
      }
      _mouseModeLongPressActive = false;
      if (_mouseModeLongPressDragging) {
        _mouseModeLongPressDragging = false;
        await inputModel.sendMouse('up', MouseButtons.left);
      } else if (!shouldBlockMouseModeEvent()) {
        await inputModel.tap(MouseButtons.right);
      }
    }
  }

  onLongPressCancel() {
    if (_mouseModeLongPressDragging) {
      _mouseModeLongPressDragging = false;
      inputModel.sendMouse('up', MouseButtons.left);
    }
    _mouseModeLongPressActive = false;
  }

  onLongPressUp() async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      await inputModel.tapUp(MouseButtons.left);
    }
  }

  // for mobiles
  onLongPress() async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    // Mouse mode handles stationary right-click vs hold-drag in onLongPressEnd.
    if (isMobile && !handleTouch) {
      return;
    }
    if (!ffi.ffiModel.isPeerMobile) {
      if (handleTouch) {
        if (!ffi.cursorModel.isInRemoteRect(_cacheLongPressPosition)) {
          return;
        }
        final isMoved = await ffi.cursorModel
            .move(_cacheLongPressPosition.dx, _cacheLongPressPosition.dy);
        if (!isMoved) {
          return;
        }
      } else {
        if (shouldBlockMouseModeEvent()) {
          return;
        }
      }
      await inputModel.tap(MouseButtons.right);
    } else {
      // It's better to send a message to tell the controlled device that the long press event is triggered.
      // We're now using a `TimerTask` in `InputService.kt` to decide whether to trigger the long press event.
      // It's not accurate and it's better to use the same detection logic in the controlling side.
    }
  }

  onLongPressMoveUpdate(LongPressMoveUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isMobile && !handleTouch) {
      if (!_mouseModeLongPressActive || isSpecialHoldDragActive) {
        return;
      }
      final delta = d.localPosition - _mouseModeLongPressLastPos;
      _mouseModeLongPressLastPos = d.localPosition;
      if (!_mouseModeLongPressDragging &&
          (d.localPosition - _mouseModeLongPressOrigin).distance > 4.0) {
        _mouseModeLongPressDragging = true;
        await inputModel.sendMouse('down', MouseButtons.left);
      }
      if (_mouseModeLongPressDragging) {
        await ffi.cursorModel.updatePan(delta, d.localPosition, false);
      }
      return;
    }
    if (!ffiModel.isPeerMobile) {
      return;
    }
    if (handleTouch) {
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }
      await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    }
  }

  onDoubleFinerTapDown(TapDownDetails d) async {
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    _doubleFinerTapPosition = d.localPosition;
    // ignore for desktop and mobile
  }

  onDoubleFinerTap(TapDownDetails d) async {
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }

    // mobile mouse mode or desktop touch screen
    final isMobileMouseMode = isMobile && !ffiModel.touchMode;
    // We can't use `d.localPosition` here because it's always (0, 0) on desktop.
    final isInRemoteRect =
        ffi.cursorModel.isInRemoteRect(_doubleFinerTapPosition);
    final isDesktopInRemoteRect = (isDesktop || isWebDesktop) && isInRemoteRect;
    if (isMobileMouseMode || isDesktopInRemoteRect) {
      await inputModel.tap(MouseButtons.right);
    }
  }

  onHoldDragStart(DragStartDetails d) async {
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      if (isSpecialHoldDragActive) return;
      await inputModel.sendMouse('down', MouseButtons.left);
    }
  }

  onHoldDragUpdate(DragUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      if (isSpecialHoldDragActive) return;
      await ffi.cursorModel.updatePan(d.delta, d.localPosition, handleTouch);
    }
  }

  onHoldDragEnd(DragEndDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      await inputModel.sendMouse('up', MouseButtons.left);
    }
  }

  onOneFingerPanStart(BuildContext context, DragStartDetails d) async {
    _oneFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer = null;
    final TapDownDetails? lastTapDownDetails = _lastTapDownDetails;
    _lastTapDownDetails = null;
    lastDeviceKind = d.kind ?? lastDeviceKind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      if (lastTapDownDetails != null &&
          !ffi.cursorModel.isInRemoteRect(lastTapDownDetails.localPosition)) {
        return;
      }
      if (lastTapDownDetails != null) {
        await ffi.cursorModel.move(lastTapDownDetails.localPosition.dx,
            lastTapDownDetails.localPosition.dy);
      }
      if (ffi.cursorModel.shouldBlock(d.localPosition.dx, d.localPosition.dy)) {
        return;
      }
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }

      _oneFingerInertiaTimer?.cancel();
      _touchModePanStarted = true;
      final touchPanMode = ffiModel.touchPanMode.value;
      if (touchPanMode == 'scroll') {
        _oneFingerScrollX = 0;
        _oneFingerScrollY = 0;
        await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
        return;
      }

      if (isDesktop || isWebDesktop) {
        ffi.cursorModel.trySetRemoteWindowCoords();
      }

      // In 'select' mode (Text selection / left drag):
      // Move to initial position first, then send mouse down.
      if (DateTime.now().millisecondsSinceEpoch - _cacheLongPressPositionTs <
          500) {
        await ffi.cursorModel
            .move(_cacheLongPressPosition.dx, _cacheLongPressPosition.dy);
      } else {
        await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
      }
      // In relative mouse mode, skip mouse down - only send movement via sendMobileRelativeMouseMove
      if (!inputModel.relativeMouseMode.value) {
        await inputModel.sendMouse('down', MouseButtons.left);
      }
    } else {
      final offset = ffi.cursorModel.offset;
      final cursorX = offset.dx;
      final cursorY = offset.dy;
      final visible =
          ffi.cursorModel.getVisibleRect().inflate(1); // extend edges
      final size = MediaQueryData.fromView(View.of(context)).size;
      if (!visible.contains(Offset(cursorX, cursorY))) {
        await ffi.cursorModel.move(size.width / 2, size.height / 2);
      }
    }
  }

  onOneFingerPanUpdate(DragUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (ffi.cursorModel.shouldBlock(d.localPosition.dx, d.localPosition.dy)) {
      return;
    }
    if (handleTouch && !_touchModePanStarted) {
      return;
    }
    if (handleTouch && ffiModel.touchPanMode.value == 'scroll') {
      // Smooth & responsive follow-the-finger drag scroll:
      // kOneFingerScrollSpeed tunes how far the remote view scrolls per finger
      // pixel, non-blocking FFI dispatch.
      _oneFingerScrollX += d.delta.dx * kOneFingerScrollSpeed;
      _oneFingerScrollY += d.delta.dy * kOneFingerScrollSpeed;

      final sendX = _oneFingerScrollX.truncate();
      final sendY = _oneFingerScrollY.truncate();
      if (sendX != 0 || sendY != 0) {
        _oneFingerScrollX -= sendX;
        _oneFingerScrollY -= sendY;
        if (!widget.isCamera) {
          bind.sessionSendMouse(
              sessionId: sessionId,
              msg: json.encode(inputModel.modify({
                'id': inputModel.id,
                'type': 'trackpad',
                'x': sendX.toString(),
                'y': sendY.toString(),
              })));
        }
      }
      return;
    }
    // In relative mouse mode, send delta directly without position tracking.
    if (inputModel.relativeMouseMode.value) {
      await inputModel.sendMobileRelativeMouseMove(d.delta.dx, d.delta.dy);
    } else {
      if (handleTouch && ffiModel.touchPanMode.value == 'select') {
        // In text selection mode, track the finger coordinates directly
        // so the selection stays exactly under the finger!
        await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
      } else {
        await ffi.cursorModel.updatePan(d.delta, d.localPosition, handleTouch);
      }
    }
  }

  onOneFingerPanEnd(DragEndDetails d) async {
    _touchModePanStarted = false;
    _oneFingerInertiaTimer?.cancel();
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isDesktop || isWebDesktop) {
      ffi.cursorModel.clearRemoteWindowCoords();
    }
    if (handleTouch) {
      final touchPanMode = ffiModel.touchPanMode.value;
      if (touchPanMode == 'scroll') {
        _oneFingerScrollX = 0;
        _oneFingerScrollY = 0;
        // Inertia fling for silky smooth deceleration feel
        final vy = d.velocity.pixelsPerSecond.dy;
        final vx = d.velocity.pixelsPerSecond.dx;
        if (vy.abs() > 100 || vx.abs() > 100) {
          // 惯性初速跟随滑动灵敏度，保持拖拽与滑动的比例一致
          double curVx = vx * 0.016 * kOneFingerScrollSpeed * 0.9;
          double curVy = vy * 0.016 * kOneFingerScrollSpeed * 0.9;
          _oneFingerInertiaTimer =
              Timer.periodic(const Duration(milliseconds: 16), (timer) {
            curVx *= 0.94;
            curVy *= 0.94;
            final sendX = curVx.round();
            final sendY = curVy.round();
            if (sendX.abs() <= 0 && sendY.abs() <= 0) {
              timer.cancel();
              return;
            }
            if (!widget.isCamera) {
              bind.sessionSendMouse(
                  sessionId: sessionId,
                  msg: json.encode(inputModel.modify({
                    'id': inputModel.id,
                    'type': 'trackpad',
                    'x': sendX.toString(),
                    'y': sendY.toString(),
                  })));
            }
          });
        }
        return;
      }
      // In relative mouse mode, skip mouse up - matches the skipped mouse down in onOneFingerPanStart
      if (!inputModel.relativeMouseMode.value) {
        await inputModel.sendMouse('up', MouseButtons.left);
      }
    }
  }

  // Reset `_touchModePanStarted` if the one-finger pan gesture is cancelled
  // or rejected by the gesture arena. Without this, the flag can remain
  // stuck in the "started" state and cause issues such as the Magic Mouse
  // double-click problem on iPad with magic mouse.
  onOneFingerPanCancel() {
    final wasPanStarted = _touchModePanStarted;
    _touchModePanStarted = false;
    _oneFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer = null;
    _oneFingerScrollX = 0;
    _oneFingerScrollY = 0;
    // Android can cancel the pointer at the physical screen edge. Then
    // onOneFingerPanEnd never runs, so the left button pressed by 'select'
    // (text selection) mode stayed down forever and later taps were
    // swallowed / the cursor appeared frozen.
    if (wasPanStarted &&
        handleTouch &&
        ffiModel.touchPanMode.value == 'select' &&
        !inputModel.relativeMouseMode.value) {
      inputModel.sendMouse('up', MouseButtons.left);
    }
  }

  // scale + pan event
  onTwoFingerScaleStart(ScaleStartDetails d) async {
    _lastTapDownDetails = null;
    _twoFingerInertiaTimer?.cancel();
    _twoFingerInertiaTimer = null;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isSpecialHoldDragActive) {
      // Initialize the last focal point to calculate deltas manually.
      _lastSpecialHoldDragFocalPoint = d.focalPoint;
    }
    _scale = 1.0;
    _twoFingerState = TwoFingerModeState.undecided;
    _twoFingerTotalFocalDelta = Offset.zero;
    _twoFingerScrollX = 0;
    _twoFingerScrollY = 0;
    _twoFingerHoldTimer?.cancel();
    _twoFingerHoldTimer = null;
    _remoteScaleAccumulator = 0.0;
    _hasRemoteScaleBaseline = false;
    _remoteScaleDirection = 0;
    _twoFingerPinching = false;

    if (handleTouch && ffiModel.touchZoomMode.value == 'remote') {
      // Ctrl+wheel zooms around the cursor. Put the cursor at the pinch
      // centre (the two fingers' midpoint), not at the screen centre.
      await ffi.cursorModel.move(d.localFocalPoint.dx, d.localFocalPoint.dy);
    }
    if (ffi.canvasModel.isSingleAppMode &&
        !ffi.canvasModel.isSingleAppTempFullScreen &&
        ffiModel.touchMode &&
        !ffi.canvasModel.allowSingleAppZoom) {
      _twoFingerState = TwoFingerModeState.scrolling;
    }
  }

  onTwoFingerScaleUpdate(ScaleUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }

    // If in special drag mode, perform a pan instead of a scale.
    if (isSpecialHoldDragActive) {
      // Calculate delta manually to avoid the jumpy behavior.
      final delta = d.focalPoint - _lastSpecialHoldDragFocalPoint;
      _lastSpecialHoldDragFocalPoint = d.focalPoint;
      await ffi.cursorModel.updatePan(delta * 2.0, d.focalPoint, handleTouch);
      return;
    }

    final singleAppTwoFinger = ffi.canvasModel.isSingleAppMode &&
        !ffi.canvasModel.isSingleAppTempFullScreen &&
        ffiModel.touchMode &&
        !ffi.canvasModel.allowSingleAppZoom;
    if (singleAppTwoFinger &&
        !_twoFingerPinching &&
        (d.scale - 1).abs() > 0.06) {
      // 两指间距明显变化 → 这次手势是捏合缩放，不再当滚动处理。
      // Ctrl+滚轮以光标为中心缩放，先把光标挪到双指中点。
      _twoFingerPinching = true;
      await ffi.cursorModel.move(d.localFocalPoint.dx, d.localFocalPoint.dy);
    }
    if (singleAppTwoFinger && !_twoFingerPinching) {
      // 单程序触屏模式且未允许缩放：双指平移作为滚轮滚动，禁止缩放与拖动画布
      _twoFingerScrollX += d.focalPointDelta.dx;
      _twoFingerScrollY += d.focalPointDelta.dy;

      const double threshold = 10.0;
      int scrollX = 0;
      int scrollY = 0;

      if (_twoFingerScrollX.abs() >= threshold) {
        scrollX = (_twoFingerScrollX / threshold).truncate();
        _twoFingerScrollX -= scrollX * threshold;
      }
      if (_twoFingerScrollY.abs() >= threshold) {
        scrollY = (_twoFingerScrollY / threshold).truncate();
        _twoFingerScrollY -= scrollY * threshold;
      }

      if (scrollX != 0 || scrollY != 0) {
        if (!widget.isCamera) {
          await bind.sessionSendMouse(
              sessionId: sessionId,
              msg: json.encode(inputModel.modify({
                'id': inputModel.id,
                'type': 'wheel',
                'x': scrollX.toString(),
                'y': scrollY.toString(),
              })));
        }
      }
      return;
    }

    if (handleTouch &&
        (ffiModel.touchZoomMode.value == 'remote' ||
            (singleAppTwoFinger && _twoFingerPinching))) {
      // 1. Establish clean initial baseline on the first frame of 2-finger contact
      if (!_hasRemoteScaleBaseline) {
        _scale = d.scale;
        _remoteScaleAccumulator = 0.0;
        _remoteScaleDirection = 0;
        _hasRemoteScaleBaseline = true;
        return;
      }

      final double scaleDelta = d.scale - _scale;
      _scale = d.scale;

      // Lower sensitivity threshold (~22% finger distance change per notch)
      const double stepThreshold = 0.22;

      // Robust directional locking and anti-recoil filtering:
      // While zooming in, minor negative deltas (finger jitter or lift-off recoil)
      // are clamped so they can NEVER falsely trigger zoom out.
      // Symmetrically, while zooming out, positive recoil cannot trigger zoom in.
      if (_remoteScaleDirection == 0) {
        _remoteScaleAccumulator += scaleDelta;
        if (_remoteScaleAccumulator >= 0.06) {
          _remoteScaleDirection = 1;
        } else if (_remoteScaleAccumulator <= -0.06) {
          _remoteScaleDirection = -1;
        }
      } else if (_remoteScaleDirection == 1) {
        if (scaleDelta >= 0) {
          _remoteScaleAccumulator += scaleDelta;
        } else {
          _remoteScaleAccumulator += scaleDelta;
          if (_remoteScaleAccumulator < -stepThreshold) {
            _remoteScaleDirection = -1;
            _remoteScaleAccumulator = -stepThreshold;
          } else if (_remoteScaleAccumulator < 0) {
            _remoteScaleAccumulator = 0.0;
          }
        }
      } else if (_remoteScaleDirection == -1) {
        if (scaleDelta <= 0) {
          _remoteScaleAccumulator += scaleDelta;
        } else {
          _remoteScaleAccumulator += scaleDelta;
          if (_remoteScaleAccumulator > stepThreshold) {
            _remoteScaleDirection = 1;
            _remoteScaleAccumulator = stepThreshold;
          } else if (_remoteScaleAccumulator > 0) {
            _remoteScaleAccumulator = 0.0;
          }
        }
      }

      final now = DateTime.now();
      final elapsed = now.difference(_lastRemoteScaleSendTime).inMilliseconds;

      if (_remoteScaleAccumulator >= stepThreshold && elapsed >= 60) {
        _remoteScaleAccumulator -= stepThreshold;
        _lastRemoteScaleSendTime = now;
        if (!widget.isCamera) {
          bind.sessionSendPointer(
              sessionId: sessionId,
              msg: json.encode(
                  PointerEventToRust(kPointerEventKindTouch, 'scale', 120)
                      .toJson()));
        }
      } else if (_remoteScaleAccumulator <= -stepThreshold && elapsed >= 60) {
        _remoteScaleAccumulator += stepThreshold;
        _lastRemoteScaleSendTime = now;
        if (!widget.isCamera) {
          bind.sessionSendPointer(
              sessionId: sessionId,
              msg: json.encode(
                  PointerEventToRust(kPointerEventKindTouch, 'scale', -120)
                      .toJson()));
        }
      }
      return;
    }

    if ((isDesktop || isWebDesktop)) {
      final scale = ((d.scale - _scale) * 1000).toInt();
      _scale = d.scale;

      if (scale != 0) {
        if (widget.isCamera) return;
        await bind.sessionSendPointer(
            sessionId: sessionId,
            msg: json.encode(
                PointerEventToRust(kPointerEventKindTouch, 'scale', scale)
                    .toJson()));
      }
    } else {
      // mobile
      final twoFingerMode = bind.mainGetLocalOption(key: 'two_finger_mode');
      final isWheelMode = twoFingerMode == 'wheel';
      if (isWheelMode) {
        final double scaleDiff = (d.scale - 1.0).abs();
        if (_twoFingerState == TwoFingerModeState.undecided) {
          _twoFingerTotalFocalDelta += d.focalPointDelta;

          // 1. 双指间距变化 >= 8% -> 优先判定为本地画布缩放与拖动
          if (scaleDiff >= 0.08) {
            _twoFingerState = TwoFingerModeState.canvasPanZoom;
            _scale = d.scale;
            _twoFingerHoldTimer?.cancel();
            _twoFingerHoldTimer = null;
          }
          // 2. 双指平行同向滑动 >= 12px 且无明显捏合 -> 判定为远程滚轮
          else if (_twoFingerTotalFocalDelta.distance >= 12.0 &&
              scaleDiff < 0.05) {
            _twoFingerState = TwoFingerModeState.scrolling;
            _twoFingerHoldTimer?.cancel();
            _twoFingerHoldTimer = null;
            // 将初始判定过程中的位移无缝计入，起步不丢帧
            _twoFingerScrollX += _twoFingerTotalFocalDelta.dx;
            _twoFingerScrollY += _twoFingerTotalFocalDelta.dy;
          }
          // 3. 双指轻微开合（>= 5%）且停留超过 250ms -> 判定为画布缩放与拖动
          else if (scaleDiff >= 0.05 && _twoFingerHoldTimer == null) {
            _twoFingerHoldTimer = Timer(const Duration(milliseconds: 250), () {
              if (_twoFingerState == TwoFingerModeState.undecided) {
                _twoFingerState = TwoFingerModeState.canvasPanZoom;
              }
            });
          }
        } else if (_twoFingerState == TwoFingerModeState.scrolling &&
            scaleDiff >= 0.14) {
          // 防止起步中心点微小偏移误锁滚轮：若后续出现明显捏合/张开，无缝切回本地缩放
          _twoFingerState = TwoFingerModeState.canvasPanZoom;
          _scale = d.scale;
          _twoFingerScrollX = 0;
          _twoFingerScrollY = 0;
        }

        if (_twoFingerState == TwoFingerModeState.canvasPanZoom) {
          // 双指缩放与画布拖动模式：
          // 先收或者开，或者按着不动后，拖动画布与缩放
          if (_scale > 0 && d.scale > 0) {
            final double zoomRatio = 1.0 + (d.scale / _scale - 1.0) * 0.5;
            ffi.canvasModel.updateScale(zoomRatio, d.focalPoint);
            _scale = d.scale;
            ffi.canvasModel.panX(d.focalPointDelta.dx);
            ffi.canvasModel.panY(d.focalPointDelta.dy);
          }
        } else if (_twoFingerState == TwoFingerModeState.scrolling) {
          // 滚轮模式：严格只滚动远程内容，画面绝对不动！
          // 基础速度温和稳定，快速划过时由惯量接管
          _twoFingerScrollX += d.focalPointDelta.dx;
          _twoFingerScrollY += d.focalPointDelta.dy;

          const double threshold = 10.0;
          int scrollX = 0;
          int scrollY = 0;

          if (_twoFingerScrollX.abs() >= threshold) {
            scrollX = (_twoFingerScrollX / threshold).truncate();
            _twoFingerScrollX -= scrollX * threshold;
          }
          if (_twoFingerScrollY.abs() >= threshold) {
            scrollY = (_twoFingerScrollY / threshold).truncate();
            _twoFingerScrollY -= scrollY * threshold;
          }

          if (scrollX != 0 || scrollY != 0) {
            if (!widget.isCamera) {
              await bind.sessionSendMouse(
                  sessionId: sessionId,
                  msg: json.encode(inputModel.modify({
                    'id': inputModel.id,
                    'type': 'wheel',
                    'x': scrollX.toString(),
                    'y': scrollY.toString(),
                  })));
            }
          }
        }
      } else {
        final double zoomRatio = 1.0 + (d.scale / _scale - 1.0) * 0.5;
        ffi.canvasModel.updateScale(zoomRatio, d.focalPoint);
        _scale = d.scale;
        ffi.canvasModel.panX(d.focalPointDelta.dx);
        ffi.canvasModel.panY(d.focalPointDelta.dy);
      }
    }
  }

  onTwoFingerScaleEnd(ScaleEndDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if ((isDesktop || isWebDesktop) ||
        (handleTouch && ffiModel.touchZoomMode.value == 'remote') ||
        _twoFingerPinching) {
      if (!widget.isCamera) {
        await bind.sessionSendPointer(
            sessionId: sessionId,
            msg: json.encode(
                PointerEventToRust(kPointerEventKindTouch, 'scale', 0)
                    .toJson()));
      }
    }
    final bool wasScrolling =
        _twoFingerState == TwoFingerModeState.scrolling && !_twoFingerPinching;
    _twoFingerPinching = false;
    _scale = 1;
    _twoFingerState = TwoFingerModeState.undecided;
    _twoFingerTotalFocalDelta = Offset.zero;
    _twoFingerHoldTimer?.cancel();
    _twoFingerHoldTimer = null;
    _remoteScaleAccumulator = 0.0;
    _hasRemoteScaleBaseline = false;
    _remoteScaleDirection = 0;
    if (!isSpecialHoldDragActive) {
      await inputModel.sendMouse('up', MouseButtons.left);
    }

    if (wasScrolling) {
      final vx = d.velocity.pixelsPerSecond.dx;
      final vy = d.velocity.pixelsPerSecond.dy;
      if (vx.abs() > 120 || vy.abs() > 120) {
        double curVx = vx * 0.016;
        double curVy = vy * 0.016;
        _twoFingerInertiaTimer =
            Timer.periodic(const Duration(milliseconds: 16), (timer) {
          curVx *= 0.94;
          curVy *= 0.94;
          _twoFingerScrollX += curVx;
          _twoFingerScrollY += curVy;

          const double threshold = 10.0;
          int scrollX = 0;
          int scrollY = 0;

          if (_twoFingerScrollX.abs() >= threshold) {
            scrollX = (_twoFingerScrollX / threshold).truncate();
            _twoFingerScrollX -= scrollX * threshold;
          }
          if (_twoFingerScrollY.abs() >= threshold) {
            scrollY = (_twoFingerScrollY / threshold).truncate();
            _twoFingerScrollY -= scrollY * threshold;
          }

          if (scrollX != 0 || scrollY != 0) {
            if (!widget.isCamera) {
              bind.sessionSendMouse(
                  sessionId: sessionId,
                  msg: json.encode(inputModel.modify({
                    'id': inputModel.id,
                    'type': 'wheel',
                    'x': scrollX.toString(),
                    'y': scrollY.toString(),
                  })));
            }
          }

          if (curVx.abs() < 0.2 && curVy.abs() < 0.2) {
            timer.cancel();
            _twoFingerInertiaTimer = null;
            _twoFingerScrollX = 0;
            _twoFingerScrollY = 0;
          }
        });
      } else {
        _twoFingerScrollX = 0;
        _twoFingerScrollY = 0;
      }
    } else {
      _twoFingerScrollX = 0;
      _twoFingerScrollY = 0;
    }
  }

  get onHoldDragCancel => null;
  get onThreeFingerVerticalDragUpdate => ffi.ffiModel.isPeerAndroid
      ? null
      : (d) {
          _mouseScrollIntegral += d.delta.dy / 4;
          if (_mouseScrollIntegral > 1) {
            inputModel.scroll(1);
            _mouseScrollIntegral = 0;
          } else if (_mouseScrollIntegral < -1) {
            inputModel.scroll(-1);
            _mouseScrollIntegral = 0;
          }
        };

  makeGestures(BuildContext context) {
    // 移动端不注册双击识别器：它在手势竞技场里会让单击一直等到
    // kDoubleTapTimeout(300ms) 才胜出，点击（onTapUp 里才下发）就明显发顿。
    // 远端双击本来就是两次快速点击，去掉后每次点击立即下发，双击依然成立。
    final enableDoubleTap = isDesktop || isWebDesktop;
    // 移动端鼠标模式不再注册 HoldTapMoveGestureRecognizer（它会把每次单击 hold 住
    // 300ms 且吞掉双击的第二次抬起），改为用长按后移动实现左键拖动；
    // DoubleFinerTapGestureRecognizer 已修复为单指抬起立即放弃，因此无 300ms 延时。
    final enableHoldTapMove = !isMobile;
    final enableDoubleFingerTap = !isMobile || !ffiModel.touchMode;
    return <Type, GestureRecognizerFactory>{
      // Official
      TapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(
                    supportedDevices: kTouchBasedDeviceKinds,
                  ), (instance) {
        instance
          ..onTapDown = onTapDown
          ..onTapUp = onTapUp
          ..onTapCancel = () {
            _lastTapDownDetails = null;
          }
          ..onTap = onTap;
      }),
      if (enableDoubleTap)
        DoubleTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
                () => DoubleTapGestureRecognizer(
                      supportedDevices: kTouchBasedDeviceKinds,
                    ), (instance) {
          instance
            ..onDoubleTapDown = onDoubleTapDown
            ..onDoubleTap = onDoubleTap;
        }),
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                    duration: (isMobile && !ffiModel.touchMode)
                        ? const Duration(milliseconds: 380)
                        : null,
                    supportedDevices: kTouchBasedDeviceKinds,
                  ), (instance) {
        instance
          ..onLongPressDown = onLongPressDown
          ..onLongPressStart = onLongPressStart
          ..onLongPressUp = onLongPressUp
          ..onLongPressEnd = onLongPressEnd
          ..onLongPressCancel = onLongPressCancel
          ..onLongPress = onLongPress
          ..onLongPressMoveUpdate = onLongPressMoveUpdate;
      }),
      // Customized
      if (enableHoldTapMove)
        HoldTapMoveGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<HoldTapMoveGestureRecognizer>(
              () => HoldTapMoveGestureRecognizer(
                    supportedDevices: kTouchBasedDeviceKinds,
                  ),
              (instance) => instance
                ..onHoldDragStart = onHoldDragStart
                ..onHoldDragUpdate = onHoldDragUpdate
                ..onHoldDragCancel = onHoldDragCancel
                ..onHoldDragEnd = onHoldDragEnd),
      if (enableDoubleFingerTap)
        DoubleFinerTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleFinerTapGestureRecognizer>(
              () => DoubleFinerTapGestureRecognizer(
                    supportedDevices: kTouchBasedDeviceKinds,
                  ), (instance) {
        instance
          ..onDoubleFinerTap = onDoubleFinerTap
          ..onDoubleFinerTapDown = onDoubleFinerTapDown;
      }),
      CustomTouchGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<CustomTouchGestureRecognizer>(
              () => CustomTouchGestureRecognizer(
                    supportedDevices: kTouchBasedDeviceKinds,
                  ), (instance) {
        instance.onOneFingerPanStart =
            (DragStartDetails d) => onOneFingerPanStart(context, d);
        instance
          ..onOneFingerPanUpdate = onOneFingerPanUpdate
          ..onOneFingerPanEnd = onOneFingerPanEnd
          ..onOneFingerPanCancel = onOneFingerPanCancel
          ..onTwoFingerScaleStart = onTwoFingerScaleStart
          ..onTwoFingerScaleUpdate = onTwoFingerScaleUpdate
          ..onTwoFingerScaleEnd = onTwoFingerScaleEnd
          ..onThreeFingerVerticalDragUpdate = onThreeFingerVerticalDragUpdate;
      }),
    };
  }
}

class RawPointerMouseRegion extends StatelessWidget {
  final InputModel inputModel;
  final Widget child;
  final MouseCursor? cursor;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;
  final PointerDownEventListener? onPointerDown;
  final PointerUpEventListener? onPointerUp;

  RawPointerMouseRegion({
    this.onEnter,
    this.onExit,
    this.cursor,
    this.onPointerDown,
    this.onPointerUp,
    required this.inputModel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: inputModel.onPointHoverImage,
      onPointerDown: (evt) {
        onPointerDown?.call(evt);
        inputModel.onPointDownImage(evt);
      },
      onPointerUp: (evt) {
        onPointerUp?.call(evt);
        inputModel.onPointUpImage(evt);
      },
      onPointerMove: inputModel.onPointMoveImage,
      onPointerSignal: inputModel.onPointerSignalImage,
      onPointerPanZoomStart: inputModel.onPointerPanZoomStart,
      onPointerPanZoomUpdate: inputModel.onPointerPanZoomUpdate,
      onPointerPanZoomEnd: inputModel.onPointerPanZoomEnd,
      child: MouseRegion(
        cursor: inputModel.isViewOnly
            ? MouseCursor.defer
            : (cursor ?? MouseCursor.defer),
        onEnter: onEnter,
        onExit: onExit,
        child: child,
      ),
    );
  }
}

class CameraRawPointerMouseRegion extends StatelessWidget {
  final InputModel inputModel;
  final Widget child;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;
  final PointerDownEventListener? onPointerDown;
  final PointerUpEventListener? onPointerUp;

  CameraRawPointerMouseRegion({
    this.onEnter,
    this.onExit,
    this.onPointerDown,
    this.onPointerUp,
    required this.inputModel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: (evt) {
        final offset = evt.position;
        double x = offset.dx;
        double y = max(0.0, offset.dy);
        inputModel.handlePointerDevicePos(
            kPointerEventKindMouse, x, y, true, kMouseEventTypeDefault);
      },
      onPointerDown: (evt) {
        onPointerDown?.call(evt);
      },
      onPointerUp: (evt) {
        onPointerUp?.call(evt);
      },
      child: MouseRegion(
        cursor: MouseCursor.defer,
        onEnter: onEnter,
        onExit: onExit,
        child: child,
      ),
    );
  }
}
