import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:toggle_switch/toggle_switch.dart';
import 'package:bot_toast/bot_toast.dart';

class GestureIcons {
  static const String _family = 'gestureicons';

  GestureIcons._();

  static const IconData iconMouse = IconData(0xe65c, fontFamily: _family);
  static const IconData iconTabletTouch = IconData(0xe9ce, fontFamily: _family);
  static const IconData iconGestureFDrag =
      IconData(0xe686, fontFamily: _family);
  static const IconData iconMobileTouch = IconData(0xe9cd, fontFamily: _family);
  static const IconData iconGesturePress =
      IconData(0xe66c, fontFamily: _family);
  static const IconData iconGestureTap = IconData(0xe66f, fontFamily: _family);
  static const IconData iconGesturePinch =
      IconData(0xe66a, fontFamily: _family);
  static const IconData iconGesturePressHold =
      IconData(0xe66b, fontFamily: _family);
  static const IconData iconGestureFDragUpDown_ =
      IconData(0xe685, fontFamily: _family);
  static const IconData iconGestureFTap_ =
      IconData(0xe68e, fontFamily: _family);
  static const IconData iconGestureFSwipeRight =
      IconData(0xe68f, fontFamily: _family);
  static const IconData iconGestureFdoubleTap =
      IconData(0xe691, fontFamily: _family);
  static const IconData iconGestureFThreeFingers =
      IconData(0xe687, fontFamily: _family);
}

typedef OnTouchModeChange = void Function(bool);

class GestureHelp extends StatefulWidget {
  GestureHelp(
      {Key? key,
      required this.touchMode,
      required this.onTouchModeChange,
      required this.virtualMouseMode,
      this.inputModel,
      this.onClose})
      : super(key: key);
  final bool touchMode;
  final OnTouchModeChange onTouchModeChange;
  final VirtualMouseMode virtualMouseMode;
  final InputModel? inputModel;
  final VoidCallback? onClose;

  @override
  State<StatefulWidget> createState() =>
      _GestureHelpState(touchMode, virtualMouseMode);
}

class _GestureHelpState extends State<GestureHelp> {
  late int _selectedIndex;
  late bool _touchMode;
  late String _twoFingerMode;
  final VirtualMouseMode _virtualMouseMode;

  late String _touchPanMode;
  late String _touchZoomMode;

  _GestureHelpState(bool touchMode, VirtualMouseMode virtualMouseMode)
      : _virtualMouseMode = virtualMouseMode {
    _touchMode = touchMode;
    _selectedIndex = _touchMode ? 1 : 0;
    _twoFingerMode = bind.mainGetLocalOption(key: 'two_finger_mode');
    if (_twoFingerMode.isEmpty) {
      _twoFingerMode = 'canvas';
    }
    _touchPanMode = gFFI.ffiModel.touchPanMode.value;
    if (_touchPanMode.isEmpty) {
      _touchPanMode = 'scroll';
    }
    _touchZoomMode = gFFI.ffiModel.touchZoomMode.value;
    if (_touchZoomMode.isEmpty) {
      _touchZoomMode = 'canvas';
    }
  }

  void _toggleTouchPanMode() {
    gFFI.ffiModel.toggleTouchPanMode();
    setState(() {
      _touchPanMode = gFFI.ffiModel.touchPanMode.value;
    });
    BotToast.showText(
      text: _touchPanMode == 'scroll'
          ? (localeName.startsWith('zh')
              ? '单指移动: 滚动屏幕 (跟手滑动)'
              : 'One-Finger Move: Scroll Screen')
          : (localeName.startsWith('zh')
              ? '单指移动: 选择文字 (拖拽划词)'
              : 'One-Finger Move: Select Text'),
    );
  }

  void _toggleTouchZoomMode() {
    gFFI.ffiModel.toggleTouchZoomMode();
    setState(() {
      _touchZoomMode = gFFI.ffiModel.touchZoomMode.value;
    });
    BotToast.showText(
      text: _touchZoomMode == 'canvas'
          ? (localeName.startsWith('zh')
              ? '双指缩放: 缩放画布'
              : 'Two-Finger Zoom: Canvas Zoom')
          : (localeName.startsWith('zh')
              ? '双指缩放: 远程缩放 (以手机中点缩放应用)'
              : 'Two-Finger Zoom: Remote Zoom'),
    );
  }

  void _toggleTwoFingerMode() {
    final newMode = _twoFingerMode == 'wheel' ? 'canvas' : 'wheel';
    setState(() {
      _twoFingerMode = newMode;
      bind.mainSetLocalOption(key: 'two_finger_mode', value: newMode);
    });
  }

  /// Helper to exit relative mouse mode when certain conditions are met.
  /// This reduces code duplication across multiple UI callbacks.
  void _exitRelativeMouseModeIf(bool condition) {
    if (condition) {
      widget.inputModel?.setRelativeMouseMode(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final space = 12.0;
    var width = size.width - 2 * space;
    final minWidth = 90;
    if (size.width > minWidth + 2 * space) {
      final n = (size.width / (minWidth + 2 * space)).floor();
      width = size.width / n - 2 * space;
    }
    return Center(
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ToggleSwitch(
                            initialLabelIndex: _selectedIndex,
                            activeFgColor: Colors.white,
                            inactiveFgColor: Colors.white60,
                            activeBgColor: [MyTheme.accent],
                            inactiveBgColor: Theme.of(context).hintColor,
                            totalSwitches: 2,
                            minWidth: 130,
                            fontSize: 15,
                            iconSize: 18,
                            labels: [
                              translate("Mouse mode"),
                              translate("Touch mode")
                            ],
                            icons: [Icons.mouse, Icons.touch_app],
                            onToggle: (index) {
                              setState(() {
                                if (_selectedIndex != index) {
                                  _selectedIndex = index ?? 0;
                                  _touchMode = index == 0 ? false : true;
                                  widget.onTouchModeChange(_touchMode);
                                  // Exit relative mouse mode when switching to touch mode
                                  _exitRelativeMouseModeIf(_touchMode);
                                }
                              });
                            },
                          ),
                          if (widget.onClose != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: translate('Close'),
                              onPressed: widget.onClose,
                            ),
                          ],
                        ],
                      ),
                      if (_touchMode) ...[
                        Transform.translate(
                          offset: const Offset(-10.0, 0.0),
                          child: InkWell(
                            onTap: () {
                              gFFI.ffiModel.toggleShowTouchPanInToolbar();
                              setState(() {});
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Checkbox(
                                  value:
                                      gFFI.ffiModel.showTouchPanInToolbar.value,
                                  onChanged: (_) {
                                    gFFI.ffiModel.toggleShowTouchPanInToolbar();
                                    setState(() {});
                                  },
                                ),
                                Text(
                                  localeName.startsWith('zh')
                                      ? '单指移动：显示在控制栏'
                                      : '${translate("One-Finger Move")}: Show in toolbar',
                                ),
                              ],
                            ),
                          ),
                        ),
                        Transform.translate(
                          offset: const Offset(-10.0, -8.0),
                          child: InkWell(
                            onTap: () {
                              gFFI.ffiModel.toggleShowTouchZoomInToolbar();
                              setState(() {});
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Checkbox(
                                  value: gFFI
                                      .ffiModel.showTouchZoomInToolbar.value,
                                  onChanged: (_) {
                                    gFFI.ffiModel
                                        .toggleShowTouchZoomInToolbar();
                                    setState(() {});
                                  },
                                ),
                                Text(
                                  localeName.startsWith('zh')
                                      ? '双指缩放：显示在控制栏'
                                      : '${translate("Pinch to Zoom")}: Show in toolbar',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      Transform.translate(
                        offset: const Offset(-10.0, 0.0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Checkbox(
                              value: _virtualMouseMode.showVirtualMouse,
                              onChanged: (value) async {
                                if (value == null) return;
                                await _virtualMouseMode.toggleVirtualMouse();
                                // Exit relative mouse mode when virtual mouse is hidden
                                _exitRelativeMouseModeIf(
                                    !_virtualMouseMode.showVirtualMouse);
                                setState(() {});
                              },
                            ),
                            InkWell(
                              onTap: () async {
                                await _virtualMouseMode.toggleVirtualMouse();
                                // Exit relative mouse mode when virtual mouse is hidden
                                _exitRelativeMouseModeIf(
                                    !_virtualMouseMode.showVirtualMouse);
                                setState(() {});
                              },
                              child: Text(translate('Show virtual mouse')),
                            ),
                          ],
                        ),
                      ),
                      if (_touchMode && _virtualMouseMode.showVirtualMouse)
                        Padding(
                          // Indent "Virtual mouse size"
                          padding: const EdgeInsets.only(left: 24.0),
                          child: SizedBox(
                            width: 260,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(
                                      top: 0.0, bottom: 0),
                                  child: Text(translate('Virtual mouse size')),
                                ),
                                Transform.translate(
                                  offset: Offset(-0.0, -6.0),
                                  child: Row(
                                    children: [
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(left: 0.0),
                                        child: Text(translate('Small')),
                                      ),
                                      Expanded(
                                        child: Slider(
                                          value: _virtualMouseMode
                                              .virtualMouseScale,
                                          min: 0.8,
                                          max: 1.8,
                                          divisions: 10,
                                          onChanged: (value) {
                                            _virtualMouseMode
                                                .setVirtualMouseScale(value);
                                            setState(() {});
                                          },
                                        ),
                                      ),
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 16.0),
                                        child: Text(translate('Large')),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (!_touchMode && _virtualMouseMode.showVirtualMouse)
                        Transform.translate(
                          offset: const Offset(-10.0, -12.0),
                          child: Padding(
                              // Indent "Show virtual joystick"
                              padding: const EdgeInsets.only(left: 24.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Checkbox(
                                    value:
                                        _virtualMouseMode.showVirtualJoystick,
                                    onChanged: (value) async {
                                      if (value == null) return;
                                      await _virtualMouseMode
                                          .toggleVirtualJoystick();
                                      // Exit relative mouse mode when joystick is hidden
                                      _exitRelativeMouseModeIf(
                                          !_virtualMouseMode
                                              .showVirtualJoystick);
                                      setState(() {});
                                    },
                                  ),
                                  InkWell(
                                    onTap: () async {
                                      await _virtualMouseMode
                                          .toggleVirtualJoystick();
                                      // Exit relative mouse mode when joystick is hidden
                                      _exitRelativeMouseModeIf(
                                          !_virtualMouseMode
                                              .showVirtualJoystick);
                                      setState(() {});
                                    },
                                    child: Text(
                                        translate("Show virtual joystick")),
                                  ),
                                ],
                              )),
                        ),
                      // Relative mouse mode option - only visible when joystick is shown
                      if (!_touchMode &&
                          _virtualMouseMode.showVirtualMouse &&
                          _virtualMouseMode.showVirtualJoystick &&
                          widget.inputModel != null)
                        Obx(() => Transform.translate(
                              offset: const Offset(-10.0, -24.0),
                              child: Padding(
                                  // Indent further for 'Relative mouse mode'
                                  padding: const EdgeInsets.only(left: 48.0),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Checkbox(
                                        value: widget.inputModel!
                                            .relativeMouseMode.value,
                                        onChanged: (value) {
                                          if (value == null) return;
                                          widget.inputModel!
                                              .setRelativeMouseMode(value);
                                        },
                                      ),
                                      InkWell(
                                        onTap: () {
                                          widget.inputModel!
                                              .toggleRelativeMouseMode();
                                        },
                                        child: Text(
                                            translate('Relative mouse mode')),
                                      ),
                                    ],
                                  )),
                            )),
                      if (!_touchMode)
                        Transform.translate(
                          offset: const Offset(-10.0, -12.0),
                          child: InkWell(
                            onTap: _toggleTwoFingerMode,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Checkbox(
                                  value: _twoFingerMode == 'wheel',
                                  onChanged: (_) => _toggleTwoFingerMode(),
                                ),
                                Text(
                                  _twoFingerMode == 'wheel'
                                      ? '${translate("Two-Finger Move")}: ${translate("Mouse Wheel")} (${translate("Tap to switch")})'
                                      : '${translate("Two-Finger Move")}: ${translate("Canvas Move")} (${translate("Tap to switch")})',
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                    child: Wrap(
                  spacing: space,
                  runSpacing: 2 * space,
                  children: _touchMode
                      ? [
                          GestureInfo(
                              width,
                              GestureIcons.iconMobileTouch,
                              translate("One-Finger Tap"),
                              translate("Left Mouse")),
                          GestureInfo(
                              width,
                              GestureIcons.iconGesturePressHold,
                              translate("One-Long Tap"),
                              translate("Right Mouse")),
                          GestureInfo(
                              width,
                              _touchPanMode == 'scroll'
                                  ? Icons.swap_vert
                                  : Icons.text_fields,
                              translate("One-Finger Move"),
                              _touchPanMode == 'scroll'
                                  ? (localeName.startsWith('zh')
                                      ? '滚动屏幕\n(点击切换)'
                                      : 'Scroll Screen\n(Tap to switch)')
                                  : (localeName.startsWith('zh')
                                      ? '选择文字\n(点击切换)'
                                      : 'Select Text\n(Tap to switch)'),
                              onTap: _toggleTouchPanMode),
                          GestureInfo(
                              width,
                              GestureIcons.iconGestureFThreeFingers,
                              translate("Three-Finger vertically"),
                              translate("Mouse Wheel")),
                          GestureInfo(
                              width,
                              GestureIcons.iconGestureFDrag,
                              translate("Two-Finger Move"),
                              translate("Canvas Move")),
                          GestureInfo(
                              width,
                              _touchZoomMode == 'canvas'
                                  ? Icons.zoom_out_map
                                  : Icons.zoom_in,
                              translate("Pinch to Zoom"),
                              _touchZoomMode == 'canvas'
                                  ? (localeName.startsWith('zh')
                                      ? '缩放画布\n(点击切换)'
                                      : 'Canvas Zoom\n(Tap to switch)')
                                  : (localeName.startsWith('zh')
                                      ? '远程缩放\n(点击切换)'
                                      : 'Remote Zoom\n(Tap to switch)'),
                              onTap: _toggleTouchZoomMode),
                        ]
                      : [
                          GestureInfo(
                              width,
                              GestureIcons.iconMobileTouch,
                              translate("One-Finger Tap"),
                              translate("Left Mouse")),
                          GestureInfo(
                              width,
                              GestureIcons.iconGesturePressHold,
                              translate("One-Long Tap"),
                              translate("Right Mouse")),
                          GestureInfo(
                              width,
                              GestureIcons.iconGestureFSwipeRight,
                              translate("Double Tap & Move"),
                              translate("Mouse Drag")),
                          GestureInfo(
                              width,
                              GestureIcons.iconGestureFThreeFingers,
                              translate("Three-Finger vertically"),
                              translate("Mouse Wheel")),
                          GestureInfo(
                              width,
                              _twoFingerMode == 'wheel'
                                  ? GestureIcons.iconGestureFThreeFingers
                                  : GestureIcons.iconGestureFDrag,
                              translate("Two-Finger Move"),
                              _twoFingerMode == 'wheel'
                                  ? '${translate("Mouse Wheel")} (${translate("Tap to switch")})'
                                  : '${translate("Canvas Move")} (${translate("Tap to switch")})',
                              onTap: _toggleTwoFingerMode),
                          GestureInfo(
                              width,
                              GestureIcons.iconGesturePinch,
                              translate("Pinch to Zoom"),
                              translate("Canvas Zoom")),
                        ],
                )),
              ],
            )));
  }
}

class GestureInfo extends StatelessWidget {
  const GestureInfo(this.width, this.icon, this.fromText, this.toText,
      {Key? key, this.onTap})
      : super(key: key);

  final String fromText;
  final String toText;
  final IconData icon;
  final double width;
  final VoidCallback? onTap;

  final iconSize = 35.0;
  final iconColor = MyTheme.accent;

  @override
  Widget build(BuildContext context) {
    Widget content = Container(
        width: width,
        padding: onTap != null ? const EdgeInsets.all(4) : EdgeInsets.zero,
        decoration: onTap != null
            ? BoxDecoration(
                border: Border.all(color: MyTheme.accent.withOpacity(0.35)),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Column(
          children: [
            Icon(
              icon,
              size: iconSize,
              color: iconColor,
            ),
            SizedBox(height: 6),
            Text(fromText,
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 9, color: Theme.of(context).hintColor)),
            SizedBox(height: 3),
            Text(toText,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    color: onTap != null
                        ? MyTheme.accent
                        : Theme.of(context).textTheme.bodySmall?.color))
          ],
        ));

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: content,
      );
    }
    return content;
  }
}
