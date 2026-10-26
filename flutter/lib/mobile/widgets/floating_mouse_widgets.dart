// These floating mouse widgets are used to simulate a physical mouse
// when "mobile" -> "desktop" in mouse mode.
// This file does not contain whole mouse widgets, it only contains
// parts that help to control, such as wheel scroll and wheel button.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/remote_input.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

// Used for the wheel button and wheel scroll widgets
const double _kSpaceToHorizontalEdge = 25;
const double _wheelWidth = 50;
const double _wheelHeight = 162;
// Used for the left/right button widgets
const double _kSpaceToVerticalEdge = 15;
const double _kSpaceBetweenLeftRightButtons = 40;
const double _kLeftRightButtonWidth = 55;
const double _kLeftRightButtonHeight = 40;
const double _kBorderWidth = 1;
final Color _kDefaultBorderColor = Colors.white.withOpacity(0.7);
final Color _kDefaultColor = Colors.black.withOpacity(0.4);
final Color _kTapDownColor = Colors.blue.withOpacity(0.7);
final Color _kWidgetHighlightColor = Colors.white.withOpacity(0.9);
const int _kInputTimerIntervalMillis = 100;

class FloatingMouseWidgets extends StatefulWidget {
  final FFI ffi;
  const FloatingMouseWidgets({
    super.key,
    required this.ffi,
  });

  @override
  State<FloatingMouseWidgets> createState() => _FloatingMouseWidgetsState();
}

class _FloatingMouseWidgetsState extends State<FloatingMouseWidgets> {
  InputModel get _inputModel => widget.ffi.inputModel;
  CursorModel get _cursorModel => widget.ffi.cursorModel;
  late final VirtualMouseMode _virtualMouseMode;

  @override
  void initState() {
    super.initState();
    _virtualMouseMode = widget.ffi.ffiModel.virtualMouseMode;
    _virtualMouseMode.addListener(_onVirtualMouseModeChanged);
    _cursorModel.blockEvents = false;
    isSpecialHoldDragActive = false;
  }

  void _onVirtualMouseModeChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _virtualMouseMode.removeListener(_onVirtualMouseModeChanged);
    super.dispose();
    _cursorModel.blockEvents = false;
    isSpecialHoldDragActive = false;
  }

  @override
  Widget build(BuildContext context) {
    final virtualMouseMode = _virtualMouseMode;
    if (!virtualMouseMode.showVirtualMouse) {
      return const Offstage();
    }
    return Stack(
      children: [
        FloatingWheel(
          inputModel: _inputModel,
          cursorModel: _cursorModel,
        ),
        if (virtualMouseMode.showVirtualJoystick)
          VirtualJoystick(
            cursorModel: _cursorModel,
            inputModel: _inputModel,
          ),
        FloatingLeftRightButton(
          isLeft: true,
          inputModel: _inputModel,
          cursorModel: _cursorModel,
        ),
        FloatingLeftRightButton(
          isLeft: false,
          inputModel: _inputModel,
          cursorModel: _cursorModel,
        ),
      ],
    );
  }
}

class FloatingWheel extends StatefulWidget {
  final InputModel inputModel;
  final CursorModel cursorModel;
  const FloatingWheel(
      {super.key, required this.inputModel, required this.cursorModel});

  @override
  State<FloatingWheel> createState() => _FloatingWheelState();
}

class _FloatingWheelState extends State<FloatingWheel> {
  Offset _position = Offset.zero;
  bool _isInitialized = false;
  Rect? _lastBlockedRect;

  bool _isMidDown = false;

  Orientation? _previousOrientation;
  Offset _preSavedPos = Offset.zero;
  bool _isDragging = false;
  Offset _startPointerPos = Offset.zero;

  // Track slider state
  double _sliderThumbY = 0.0; // Current thumb offset from track center (-maxTravel to +maxTravel)
  bool _isSliderActive = false;
  Timer? _continuousScrollTimer;
  Timer? _edgeHoldTimer;
  int _edgeHoldDirection = 0; // -1: top, 1: bottom, 0: none
  bool _hasEdgeTriggered = false;

  InputModel get _inputModel => widget.inputModel;
  CursorModel get _cursorModel => widget.cursorModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final currentOrientation = MediaQuery.of(context).orientation;
      _previousOrientation = currentOrientation;
      _resetPosition(currentOrientation);
    });
  }

  String _getPositionKey(Orientation ori) {
    final strOri = ori == Orientation.landscape ? 'l' : 'p';
    return 'w$strOri-mouse-btn-pos';
  }

  static Offset? _loadPositionFromString(String s) {
    if (s.isEmpty) {
      return null;
    }
    try {
      final m = jsonDecode(s);
      return Offset((m['x'] as num).toDouble(), (m['y'] as num).toDouble());
    } catch (e) {
      debugPrintStack(label: 'Failed to load position "$s" $e');
      return null;
    }
  }

  void _trySavePosition() {
    if (_previousOrientation == null) return;
    if (((_position - _preSavedPos)).distanceSquared < 0.1) return;
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
        size.width - _wheelWidth - _kSpaceToHorizontalEdge,
        (size.height - _wheelHeight) / 2,
      );
    } else {
      _position = pos;
      _preSavedPos = pos;
    }
  }

  void _resetPosition(Orientation ori) {
    setState(() {
      _restorePosition(ori);
      _isInitialized = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateBlockedRect();
    });
  }

  void _onMoveUpdateDelta(Offset delta) {
    final size = MediaQuery.of(context).size;
    Offset newPosition = _position + delta;
    double minX = _kSpaceToHorizontalEdge;
    double minY = _kSpaceToVerticalEdge;
    double maxX = size.width - _wheelWidth - _kSpaceToHorizontalEdge;
    double maxY = size.height - _wheelHeight - _kSpaceToVerticalEdge;
    newPosition = Offset(
      newPosition.dx.clamp(minX, maxX),
      newPosition.dy.clamp(minY, maxY),
    );
    final isPositionChanged = !(isDoubleEqual(newPosition.dx, _position.dx) &&
        isDoubleEqual(newPosition.dy, _position.dy));
    setState(() {
      _position = newPosition;
    });
    if (isPositionChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateBlockedRect();
      });
    }
  }

  void _updateBlockedRect() {
    if (_lastBlockedRect != null) {
      _cursorModel.removeBlockedRect(_lastBlockedRect!);
    }
    final newRect =
        Rect.fromLTWH(_position.dx, _position.dy, _wheelWidth, _wheelHeight);
    _cursorModel.addBlockedRect(newRect);
    _lastBlockedRect = newRect;
  }

  @override
  void dispose() {
    _continuousScrollTimer?.cancel();
    _edgeHoldTimer?.cancel();
    if (_lastBlockedRect != null) {
      _cursorModel.removeBlockedRect(_lastBlockedRect!);
    }
    _trySavePosition();
    super.dispose();
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

  static const double _trackHeight = _wheelHeight; // 162
  static const double _maxTravel = (_trackHeight - 36.0) / 2; // ~63px travel

  void _onSliderPointerDown(PointerDownEvent event) {
    _edgeHoldTimer?.cancel();
    _continuousScrollTimer?.cancel();
    _hasEdgeTriggered = false;
    _edgeHoldDirection = 0;
    setState(() {
      _isSliderActive = true;
      _sliderThumbY = 0.0;
    });
  }

  void _onSliderPointerMove(PointerMoveEvent event) {
    if (!_isSliderActive) return;

    final newY = (_sliderThumbY + event.delta.dy).clamp(-_maxTravel, _maxTravel);
    setState(() {
      _sliderThumbY = newY;
    });

    _handleSliderScrolling();
  }

  void _handleSliderScrolling() {
    final ratio = _sliderThumbY / _maxTravel; // -1.0 to 1.0
    final absRatio = ratio.abs();

    // 1. Continuous scroll timer based on distance from center
    // Deadzone is small (0.04), and scrolls immediately!
    if (absRatio > 0.04) {
      final direction = ratio < 0 ? 1 : -1;
      // Scroll speed: intervals from 100ms down to 10ms (super fast and responsive)
      final intervalMs = (100 - (absRatio * 90)).clamp(10.0, 100.0).round();
      // Send immediate scroll step if timer wasn't running or when direction changed
      if (_continuousScrollTimer == null) {
        _inputModel.scroll(direction);
      }
      _continuousScrollTimer?.cancel();
      _continuousScrollTimer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) {
        _inputModel.scroll(direction);
      });
    } else {
      _continuousScrollTimer?.cancel();
      _continuousScrollTimer = null;
    }

    // 2. Edge hold detection (held at top/bottom for >= 0.5s)
    final isAtTop = ratio <= -0.92;
    final isAtBottom = ratio >= 0.92;

    if (isAtTop) {
      if (_edgeHoldDirection != -1) {
        _edgeHoldTimer?.cancel();
        _edgeHoldDirection = -1;
        _hasEdgeTriggered = false;
        _edgeHoldTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted && _isSliderActive && _edgeHoldDirection == -1) {
            _hasEdgeTriggered = true;
            BotToast.showText(
              text: localeName.startsWith('zh') ? '松开跳转至最顶部' : 'Release to jump to Top',
            );
            setState(() {});
          }
        });
      }
    } else if (isAtBottom) {
      if (_edgeHoldDirection != 1) {
        _edgeHoldTimer?.cancel();
        _edgeHoldDirection = 1;
        _hasEdgeTriggered = false;
        _edgeHoldTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted && _isSliderActive && _edgeHoldDirection == 1) {
            _hasEdgeTriggered = true;
            BotToast.showText(
              text: localeName.startsWith('zh') ? '松开跳转至最底部' : 'Release to jump to Bottom',
            );
            setState(() {});
          }
        });
      }
    } else {
      _edgeHoldTimer?.cancel();
      _edgeHoldDirection = 0;
      _hasEdgeTriggered = false;
    }
  }

  void _onSliderPointerUp(PointerUpEvent event) {
    _continuousScrollTimer?.cancel();
    _continuousScrollTimer = null;
    _edgeHoldTimer?.cancel();

    // If held at top or bottom for >= 0.5s and released at the edge:
    if (_hasEdgeTriggered) {
      if (_edgeHoldDirection == -1) {
        _inputModel.inputKey('VK_HOME');
      } else if (_edgeHoldDirection == 1) {
        _inputModel.inputKey('VK_END');
      }
    }

    setState(() {
      _isSliderActive = false;
      _sliderThumbY = 0.0; // Spring back to center
      _edgeHoldDirection = 0;
      _hasEdgeTriggered = false;
    });
  }

  void _onSliderPointerCancel(PointerCancelEvent event) {
    _continuousScrollTimer?.cancel();
    _continuousScrollTimer = null;
    _edgeHoldTimer?.cancel();
    setState(() {
      _isSliderActive = false;
      _sliderThumbY = 0.0;
      _edgeHoldDirection = 0;
      _hasEdgeTriggered = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Positioned(child: Offstage());
    }
    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: _buildWidget(context),
    );
  }

  Widget _buildWidget(BuildContext context) {
    // When idle: compact circle with up/down arrows (like Logitech middle click dot)
    // When dragged: dynamically morphs into up or down arrow
    final isUp = _sliderThumbY < -6;
    final isDown = _sliderThumbY > 6;

    return Container(
      width: _wheelWidth,
      height: _wheelHeight,
      decoration: BoxDecoration(
        color: _kDefaultColor,
        border: Border.all(
          color: _isSliderActive ? _kTapDownColor : _kDefaultBorderColor,
          width: 1.2,
        ),
        borderRadius: BorderRadius.circular(_wheelWidth * 0.5),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background track rail line and indicators
          Positioned.fill(
            child: IgnorePointer(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Icon(
                      Icons.keyboard_arrow_up,
                      size: 20,
                      color: (_hasEdgeTriggered && _edgeHoldDirection == -1)
                          ? _kTapDownColor
                          : _kDefaultBorderColor.withOpacity(0.5),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Container(
                        width: 2,
                        decoration: BoxDecoration(
                          color: _kDefaultBorderColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: (_hasEdgeTriggered && _edgeHoldDirection == 1)
                          ? _kTapDownColor
                          : _kDefaultBorderColor.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // The Logitech middle-button style dot/arrow slider
          Positioned(
            top: (_trackHeight - 34.0) / 2 + _sliderThumbY,
            child: Listener(
              onPointerDown: _onSliderPointerDown,
              onPointerMove: _onSliderPointerMove,
              onPointerUp: _onSliderPointerUp,
              onPointerCancel: _onSliderPointerCancel,
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _hasEdgeTriggered
                      ? _kTapDownColor
                      : (_isSliderActive ? Colors.blue.withOpacity(0.8) : Colors.black.withOpacity(0.6)),
                  border: Border.all(
                    color: _hasEdgeTriggered
                        ? Colors.white
                        : (_isSliderActive ? Colors.white : _kDefaultBorderColor),
                    width: 1.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    )
                  ],
                ),
                child: Center(
                  child: Builder(builder: (context) {
                    if (isUp) {
                      return const Icon(
                        Icons.keyboard_arrow_up,
                        color: Colors.white,
                        size: 24,
                      );
                    } else if (isDown) {
                      return const Icon(
                        Icons.keyboard_arrow_down,
                        color: Colors.white,
                        size: 24,
                      );
                    } else {
                      // Idle: small dot with tiny up/down arrows
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.arrow_drop_up,
                            size: 10,
                            color: Colors.white.withOpacity(0.9),
                          ),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                            ),
                          ),
                          Icon(
                            Icons.arrow_drop_down,
                            size: 10,
                            color: Colors.white.withOpacity(0.9),
                          ),
                        ],
                      );
                    }
                  }),
                ),
              ),
            ),
          ),

          // Double tap / long press on outer body to drag widget position
          Positioned(
            right: 0,
            bottom: 2,
            child: GestureDetector(
              onPanStart: (details) {
                _startPointerPos = details.globalPosition;
                _isDragging = true;
              },
              onPanUpdate: (details) {
                _onMoveUpdateDelta(details.delta);
              },
              onPanEnd: (details) {
                _trySavePosition();
                _isDragging = false;
              },
              child: Container(
                width: 20,
                height: 20,
                color: Colors.transparent,
                alignment: Alignment.center,
                child: Icon(Icons.drag_indicator, size: 12, color: _kDefaultBorderColor.withOpacity(0.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FloatingLeftRightButton extends StatefulWidget {
  final bool isLeft;
  final InputModel inputModel;
  final CursorModel cursorModel;
  const FloatingLeftRightButton(
      {super.key,
      required this.isLeft,
      required this.inputModel,
      required this.cursorModel});

  @override
  State<FloatingLeftRightButton> createState() =>
      _FloatingLeftRightButtonState();
}

class _FloatingLeftRightButtonState extends State<FloatingLeftRightButton> {
  Offset _position = Offset.zero;
  bool _isInitialized = false;
  bool _isDown = false;
  Rect? _lastBlockedRect;

  Orientation? _previousOrientation;
  Offset _preSavedPos = Offset.zero;

  // Gesture ambiguity resolution
  Timer? _tapDownTimer;
  final Duration _pressTimeout = const Duration(milliseconds: 200);
  bool _isDragging = false;

  bool get _isLeft => widget.isLeft;
  InputModel get _inputModel => widget.inputModel;
  CursorModel get _cursorModel => widget.cursorModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final currentOrientation = MediaQuery.of(context).orientation;
      _previousOrientation = currentOrientation;
      _resetPosition(currentOrientation);
    });
  }

  @override
  void dispose() {
    if (_lastBlockedRect != null) {
      _cursorModel.removeBlockedRect(_lastBlockedRect!);
    }
    _tapDownTimer?.cancel();
    _trySavePosition();
    super.dispose();
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

  double _getOffsetX(double w) {
    if (_isLeft) {
      return (w - _kLeftRightButtonWidth * 2 - _kSpaceBetweenLeftRightButtons) *
          0.5;
    } else {
      return (w + _kSpaceBetweenLeftRightButtons) * 0.5;
    }
  }

  String _getPositionKey(Orientation ori) {
    final strLeftRight = _isLeft ? 'l' : 'r';
    final strOri = ori == Orientation.landscape ? 'l' : 'p';
    return '$strLeftRight$strOri-mouse-btn-pos';
  }

  static Offset? _loadPositionFromString(String s) {
    if (s.isEmpty) {
      return null;
    }
    try {
      final m = jsonDecode(s);
      return Offset(m['x'], m['y']);
    } catch (e) {
      debugPrintStack(label: 'Failed to load position "$s" $e');
      return null;
    }
  }

  void _trySavePosition() {
    if (_previousOrientation == null) return;
    if (((_position - _preSavedPos)).distanceSquared < 0.1) return;
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
      _position = Offset(_getOffsetX(size.width),
          size.height - _kSpaceToVerticalEdge - _kLeftRightButtonHeight);
    } else {
      _position = pos;
      _preSavedPos = pos;
    }
  }

  void _resetPosition(Orientation ori) {
    setState(() {
      _restorePosition(ori);
      _isInitialized = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateBlockedRect();
    });
  }

  void _updateBlockedRect() {
    if (_lastBlockedRect != null) {
      _cursorModel.removeBlockedRect(_lastBlockedRect!);
    }
    final newRect = Rect.fromLTWH(_position.dx, _position.dy,
        _kLeftRightButtonWidth, _kLeftRightButtonHeight);
    _cursorModel.addBlockedRect(newRect);
    _lastBlockedRect = newRect;
  }

  void _onMoveUpdateDelta(Offset delta) {
    final context = this.context;
    final size = MediaQuery.of(context).size;
    Offset newPosition = _position + delta;
    double minX = _kSpaceToHorizontalEdge;
    double minY = _kSpaceToVerticalEdge;
    double maxX = size.width - _kLeftRightButtonWidth - _kSpaceToHorizontalEdge;
    double maxY = size.height - _kLeftRightButtonHeight - _kSpaceToVerticalEdge;
    newPosition = Offset(
      newPosition.dx.clamp(minX, maxX),
      newPosition.dy.clamp(minY, maxY),
    );
    final isPositionChanged = !(isDoubleEqual(newPosition.dx, _position.dx) &&
        isDoubleEqual(newPosition.dy, _position.dy));
    setState(() {
      _position = newPosition;
    });
    if (isPositionChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateBlockedRect();
      });
    }
  }

  void _onBodyPointerMoveUpdate(PointerMoveEvent event) {
    _cursorModel.blockEvents = true;
    // If move, it's a drag, not a tap.
    _isDragging = true;
    // Cancel the timer to prevent it from being recognized as a tap/hold.
    _tapDownTimer?.cancel();
    _tapDownTimer = null;
    _onMoveUpdateDelta(event.delta);
  }

  Widget _buildButtonIcon() {
    final double w = _kLeftRightButtonWidth * 0.45;
    final double h = _kLeftRightButtonHeight * 0.75;
    final double borderRadius = w * 0.5;
    final double quarterCircleRadius = borderRadius * 0.9;
    return Stack(
      children: [
        Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kLeftRightButtonWidth * 0.225),
            color: Colors.white,
          ),
        ),
        Positioned(
          left: _isLeft ? quarterCircleRadius * 0.25 : null,
          right: _isLeft ? null : quarterCircleRadius * 0.25,
          top: quarterCircleRadius * 0.25,
          child: CustomPaint(
            size: Size(quarterCircleRadius * 2, quarterCircleRadius * 2),
            painter: _QuarterCirclePainter(
              color: _kDefaultColor,
              isLeft: _isLeft,
              radius: quarterCircleRadius,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Positioned(child: Offstage());
    }
    return Positioned(
      left: _position.dx,
      top: _position.dy,
      // We can't use the GestureDetector here, because `onTapDown` may be
      // triggered sometimes when dragging.
      child: Listener(
        onPointerMove: _onBodyPointerMoveUpdate,
        onPointerDown: (event) async {
          _isDragging = false;
          setState(() {
            _isDown = true;
          });
          // Start a timer. If it fires, it's a hold.
          _tapDownTimer?.cancel();
          _tapDownTimer = Timer(_pressTimeout, () {
            isSpecialHoldDragActive = true;
            () async {
              await _cursorModel.syncCursorPosition();
              await _inputModel
                  .tapDown(_isLeft ? MouseButtons.left : MouseButtons.right);
            }();
            _tapDownTimer = null;
          });
        },
        onPointerUp: (event) {
          _cursorModel.blockEvents = false;
          setState(() {
            _isDown = false;
          });
          // If timer is active, it's a quick tap.
          if (_tapDownTimer != null) {
            _tapDownTimer!.cancel();
            _tapDownTimer = null;
            // Fire tap down and up quickly.
            _inputModel
                .tapDown(_isLeft ? MouseButtons.left : MouseButtons.right)
                .then(
                    (_) => Future.delayed(const Duration(milliseconds: 50), () {
                          _inputModel.tapUp(
                              _isLeft ? MouseButtons.left : MouseButtons.right);
                        }));
          } else {
            // If it's not a quick tap, it could be a hold or drag.
            // If it was a hold, isSpecialHoldDragActive is true.
            if (isSpecialHoldDragActive) {
              _inputModel
                  .tapUp(_isLeft ? MouseButtons.left : MouseButtons.right);
            }
          }

          if (_isDragging) {
            _trySavePosition();
          }
          isSpecialHoldDragActive = false;
        },
        onPointerCancel: (event) {
          _cursorModel.blockEvents = false;
          setState(() {
            _isDown = false;
          });
          _tapDownTimer?.cancel();
          _tapDownTimer = null;
          if (isSpecialHoldDragActive) {
            _inputModel.tapUp(_isLeft ? MouseButtons.left : MouseButtons.right);
          }
          isSpecialHoldDragActive = false;
          if (_isDragging) {
            _trySavePosition();
          }
        },
        child: Container(
          width: _kLeftRightButtonWidth,
          height: _kLeftRightButtonHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _kDefaultColor,
            border: Border.all(
                color: _isDown ? _kTapDownColor : _kDefaultBorderColor,
                width: _kBorderWidth),
            borderRadius: _isLeft
                ? BorderRadius.horizontal(
                    left: Radius.circular(_kLeftRightButtonHeight * 0.5))
                : BorderRadius.horizontal(
                    right: Radius.circular(_kLeftRightButtonHeight * 0.5)),
          ),
          child: _buildButtonIcon(),
        ),
      ),
    );
  }
}

class _QuarterCirclePainter extends CustomPainter {
  final Color color;
  final bool isLeft;
  final double radius;
  _QuarterCirclePainter(
      {required this.color, required this.isLeft, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final rect = Rect.fromLTWH(0, 0, radius * 2, radius * 2);
    if (isLeft) {
      canvas.drawArc(rect, -pi, pi / 2, true, paint);
    } else {
      canvas.drawArc(rect, -pi / 2, pi / 2, true, paint);
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

// Virtual joystick can send either absolute movement (via updatePan)
// or relative movement (via sendMobileRelativeMouseMove) depending on the
// InputModel.relativeMouseMode setting.
class VirtualJoystick extends StatefulWidget {
  final CursorModel cursorModel;
  final InputModel inputModel;

  const VirtualJoystick({
    super.key,
    required this.cursorModel,
    required this.inputModel,
  });

  @override
  State<VirtualJoystick> createState() => _VirtualJoystickState();
}

class _VirtualJoystickState extends State<VirtualJoystick> {
  Offset _position = Offset.zero;
  bool _isInitialized = false;
  Offset _offset = Offset.zero;
  final double _joystickRadius = 50.0;
  final double _thumbRadius = 20.0;
  final double _moveStep = 3.0;
  final double _speed = 1.0;

  /// Scale factor for relative mouse movement sensitivity.
  /// Higher values result in faster cursor movement on the remote machine.
  static const double _kRelativeMouseScale = 3.0;

  // One-shot timer to detect a drag gesture
  Timer? _dragStartTimer;
  // Periodic timer for continuous movement
  Timer? _continuousMoveTimer;
  Size? _lastScreenSize;
  bool _isPressed = false;

  /// Check if relative mouse mode is enabled.
  bool get _useRelativeMouse => widget.inputModel.relativeMouseMode.value;

  @override
  void initState() {
    super.initState();
    widget.cursorModel.blockEvents = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lastScreenSize = MediaQuery.of(context).size;
      _resetPosition();
    });
  }

  @override
  void dispose() {
    _stopSendEventTimer();
    widget.cursorModel.blockEvents = false;
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentScreenSize = MediaQuery.of(context).size;
    if (_lastScreenSize != null && _lastScreenSize != currentScreenSize) {
      _resetPosition();
    }
    _lastScreenSize = currentScreenSize;
  }

  void _resetPosition() {
    final size = MediaQuery.of(context).size;
    setState(() {
      _position = Offset(
        _kSpaceToHorizontalEdge + _joystickRadius,
        size.height * 0.5 + _joystickRadius * 1.5,
      );
      _isInitialized = true;
    });
  }

  Offset _offsetToPanDelta(Offset offset) {
    return Offset(
      offset.dx / _joystickRadius,
      offset.dy / _joystickRadius,
    );
  }

  /// Send movement delta to remote machine.
  /// Uses relative mouse mode if enabled, otherwise uses absolute updatePan.
  void _sendMovement(Offset delta) {
    if (_useRelativeMouse) {
      widget.inputModel.sendMobileRelativeMouseMove(
          delta.dx * _kRelativeMouseScale, delta.dy * _kRelativeMouseScale);
    } else {
      // In absolute mode, use cursorModel.updatePan which tracks position.
      widget.cursorModel.updatePan(delta, Offset.zero, false);
    }
  }

  void _stopSendEventTimer() {
    _dragStartTimer?.cancel();
    _continuousMoveTimer?.cancel();
    _dragStartTimer = null;
    _continuousMoveTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Positioned(child: Offstage());
    }
    return Positioned(
      left: _position.dx - _joystickRadius,
      top: _position.dy - _joystickRadius,
      child: GestureDetector(
        onPanStart: (details) {
          setState(() {
            _isPressed = true;
          });
          widget.cursorModel.blockEvents = true;
          _updateOffset(details.localPosition);

          // 1. Send a single, small pan event immediately for responsiveness.
          //    The movement is small for a gentle start.
          final initialDelta = _offsetToPanDelta(_offset);
          if (initialDelta.distance > 0) {
            _sendMovement(initialDelta);
          }

          // 2. Start a one-shot timer to check if the user is holding for a drag.
          _dragStartTimer?.cancel();
          _dragStartTimer = Timer(const Duration(milliseconds: 120), () {
            // 3. If the timer fires, it's a drag. Start the continuous movement timer.
            _continuousMoveTimer?.cancel();
            _continuousMoveTimer =
                periodic_immediate(const Duration(milliseconds: 20), () async {
              if (_offset != Offset.zero) {
                _sendMovement(_offsetToPanDelta(_offset) * _moveStep * _speed);
              }
            });
          });
        },
        onPanUpdate: (details) {
          _updateOffset(details.localPosition);
        },
        onPanEnd: (details) {
          setState(() {
            _offset = Offset.zero;
            _isPressed = false;
          });
          widget.cursorModel.blockEvents = false;

          // 4. Critical step: On pan end, cancel all timers.
          //    If it was a flick, this cancels the drag detection before it fires.
          //    If it was a drag, this stops the continuous movement.
          _stopSendEventTimer();
        },
        child: CustomPaint(
          size: Size(_joystickRadius * 2, _joystickRadius * 2),
          painter: _JoystickPainter(
              _offset, _joystickRadius, _thumbRadius, _isPressed),
        ),
      ),
    );
  }

  void _updateOffset(Offset localPosition) {
    final center = Offset(_joystickRadius, _joystickRadius);
    final offset = localPosition - center;
    final distance = offset.distance;

    if (distance <= _joystickRadius) {
      setState(() {
        _offset = offset;
      });
    } else {
      final clampedOffset = offset / distance * _joystickRadius;
      setState(() {
        _offset = clampedOffset;
      });
    }
  }
}

class _JoystickPainter extends CustomPainter {
  final Offset _offset;
  final double _joystickRadius;
  final double _thumbRadius;
  final bool _isPressed;

  _JoystickPainter(
      this._offset, this._joystickRadius, this._thumbRadius, this._isPressed);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final joystickColor = _kDefaultColor;
    final borderColor = _isPressed ? _kTapDownColor : _kDefaultBorderColor;
    final thumbColor = _kWidgetHighlightColor;

    final joystickPaint = Paint()
      ..color = joystickColor
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final thumbPaint = Paint()
      ..color = thumbColor
      ..style = PaintingStyle.fill;

    // Draw joystick base and border
    canvas.drawCircle(center, _joystickRadius, joystickPaint);
    canvas.drawCircle(center, _joystickRadius, borderPaint);

    // Draw thumb
    final thumbCenter = center + _offset;
    canvas.drawCircle(thumbCenter, _thumbRadius, thumbPaint);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate._offset != _offset ||
        oldDelegate._isPressed != _isPressed;
  }
}
