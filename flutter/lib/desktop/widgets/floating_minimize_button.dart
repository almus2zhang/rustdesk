import 'dart:math';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../models/platform_model.dart';

class FloatingMinimizeButton extends StatefulWidget {
  final int windowId;

  const FloatingMinimizeButton({
    Key? key,
    required this.windowId,
  }) : super(key: key);

  @override
  State<FloatingMinimizeButton> createState() => _FloatingMinimizeButtonState();
}

class _FloatingMinimizeButtonState extends State<FloatingMinimizeButton> {
  Offset? _position;
  bool _isDragging = false;
  Offset _dragStartFinger = Offset.zero;
  Offset _dragStartPos = Offset.zero;
  bool _isHovered = false;

  static const double _btnSize = 36.0;
  static const String _posKey = 'float_min_btn_pos';

  @override
  void initState() {
    super.initState();
    _loadPosition();
  }

  void _loadPosition() {
    final saved = bind.getLocalFlutterOption(k: _posKey);
    if (saved.isNotEmpty) {
      try {
        final parts = saved.split(',');
        if (parts.length == 2) {
          _position = Offset(double.parse(parts[0]), double.parse(parts[1]));
        }
      } catch (_) {}
    }
  }

  void _savePosition(Offset pos) {
    bind.setLocalFlutterOption(k: _posKey, v: '${pos.dx},${pos.dy}');
  }

  void _handleMinimize() async {
    try {
      await WindowController.fromWindowId(widget.windowId).minimize();
    } catch (_) {
      try {
        await windowManager.minimize();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    // This widget is a direct child of the remote page Stack, so it MUST
    // return a Positioned at its root. Wrapping it in LayoutBuilder (which
    // creates its own RenderObject) detached the Positioned from the Stack:
    // the opaque Listener then expanded over the whole window and covered
    // the remote screen with the button's translucent background, blocking
    // every input event.
    final size = MediaQuery.of(context).size;
    final defaultPos = Offset(
      max(8.0, size.width - _btnSize - 20.0),
      max(8.0, 70.0),
    );

    final curPos = _position != null
        ? Offset(
            _position!.dx.clamp(0.0, max(0.0, size.width - _btnSize)),
            _position!.dy.clamp(0.0, max(0.0, size.height - _btnSize)),
          )
        : defaultPos;

    final isZh = localeName.startsWith('zh');
    final tooltipMsg = isZh ? '最小化窗口 (可拖动位置)' : 'Minimize (Drag to move)';

    // Explicit width/height keep the button 36x36 even if the parent ever
    // hands down tight full-window constraints again.
    return Positioned(
      left: curPos.dx,
      top: curPos.dy,
      width: _btnSize,
      height: _btnSize,
      child: Tooltip(
        message: tooltipMsg,
        waitDuration: const Duration(milliseconds: 500),
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: SystemMouseCursors.click,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              _dragStartFinger = event.position;
              _dragStartPos = curPos;
              _isDragging = false;
            },
            onPointerMove: (event) {
              final delta = event.position - _dragStartFinger;
              if (!_isDragging && delta.distance > 4.0) {
                _isDragging = true;
              }
              if (_isDragging) {
                final newPos = Offset(
                  (_dragStartPos.dx + delta.dx)
                      .clamp(0.0, max(0.0, size.width - _btnSize)),
                  (_dragStartPos.dy + delta.dy)
                      .clamp(0.0, max(0.0, size.height - _btnSize)),
                );
                setState(() {
                  _position = newPos;
                });
              }
            },
            onPointerUp: (event) {
              if (_isDragging) {
                if (_position != null) {
                  _savePosition(_position!);
                }
                _isDragging = false;
              } else {
                _handleMinimize();
              }
            },
            onPointerCancel: (_) {
              if (_isDragging && _position != null) {
                _savePosition(_position!);
              }
              _isDragging = false;
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _btnSize,
              height: _btnSize,
              decoration: BoxDecoration(
                color: _isHovered
                    ? const Color(0xB3000000) // 70% opacity on hover
                    : const Color(0x66000000), // 40% semi-transparent
                shape: BoxShape.circle,
                border: Border.all(
                  color: _isHovered ? Colors.white70 : Colors.white24,
                  width: 1.0,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 4.0,
                    offset: Offset(0, 1.5),
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  Icons.horizontal_rule,
                  color: _isHovered ? Colors.white : Colors.white70,
                  size: 18,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
