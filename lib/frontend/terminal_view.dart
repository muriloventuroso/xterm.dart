import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:xterm/frontend/char_size.dart';
import 'package:xterm/frontend/helpers.dart';
import 'package:xterm/frontend/input_behavior.dart';
import 'package:xterm/frontend/input_behaviors.dart';
import 'package:xterm/frontend/input_listener.dart';
import 'package:xterm/frontend/oscillator.dart';
import 'package:xterm/frontend/cache.dart';
import 'package:xterm/frontend/terminal_painters.dart';
import 'package:xterm/mouse/position.dart';
import 'package:xterm/terminal/terminal_ui_interaction.dart';
import 'package:xterm/theme/terminal_style.dart';

class TerminalView extends StatefulWidget {
  TerminalView({
    Key? key,
    required this.terminal,
    this.style = const TerminalStyle(),
    this.opacity = 1.0,
    FocusNode? focusNode,
    this.autofocus = false,
    ScrollController? scrollController,
    InputBehavior? inputBehavior,
    this.padding = 0.0,
  })  : focusNode = focusNode ?? FocusNode(),
        scrollController = scrollController ?? ScrollController(),
        inputBehavior = inputBehavior ?? InputBehaviors.platform,
        super(key: key ?? ValueKey(terminal));

  final TerminalUiInteraction terminal;
  final FocusNode focusNode;
  final bool autofocus;
  final ScrollController scrollController;

  final TerminalStyle style;
  final double opacity;

  final double padding;

  final InputBehavior inputBehavior;

  // get the dimensions of a rendered character
  CellSize measureCellSize() {
    final testString = 'xxxxxxxxxx' * 1000;

    final text = Text(
      testString,
      style: (style.textStyleProvider != null)
          ? style.textStyleProvider!(
              fontSize: style.fontSize,
            )
          : TextStyle(
              fontFamily: style.fontFamily[0],
              fontFamilyFallback: style.fontFamily,
              fontSize: style.fontSize,
            ),
    );

    final size = textSize(text);

    final charWidth = (size.width / testString.length);
    final charHeight = size.height;

    final cellWidth = charWidth * style.fontWidthScaleFactor;
    final cellHeight = size.height * style.fontHeightScaleFactor;

    return CellSize(
      charWidth: charWidth,
      charHeight: charHeight,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      letterSpacing: cellWidth - charWidth,
      lineSpacing: cellHeight - charHeight,
    );
  }

  @override
  _TerminalViewState createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  /// blinking cursor and blinking character
  final blinkOscillator = Oscillator.ms(600);

  bool get focused {
    return widget.focusNode.hasFocus;
  }

  bool isShiftPressed = false;
  bool isTyping = false;
  Timer? timerTyping;

  late CellSize _cellSize;
  Position? _tapPosition;

  /// Scroll position from the terminal. Not null if terminal scroll extent has
  /// been updated and needs to be syncronized to flutter side.
  double? _pendingTerminalScrollExtent;

  void onTerminalChange() {
    _pendingTerminalScrollExtent =
        _cellSize.cellHeight * widget.terminal.scrollOffsetFromTop;

    if (mounted) {
      setState(() {});
    }
  }

  // listen to oscillator to update mouse blink etc.
  // void onTick() {
  //   widget.terminal.refresh();
  // }

  @override
  void initState() {
    blinkOscillator.start();
    // oscillator.addListener(onTick);

    // measureCellSize is expensive so we cache the result.
    _cellSize = widget.measureCellSize();

    widget.terminal.addListener(onTerminalChange);

    super.initState();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    oldWidget.terminal.removeListener(onTerminalChange);
    widget.terminal.addListener(onTerminalChange);
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    blinkOscillator.stop();
    // oscillator.removeListener(onTick);

    widget.terminal.removeListener(onTerminalChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InputListener(
      listenKeyStroke: widget.inputBehavior.acceptKeyStroke,
      onKeyStroke: onKeyStroke,
      onTextInput: onInput,
      onAction: onAction,
      onFocus: onFocus,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      initEditingState: widget.inputBehavior.initEditingState,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: LayoutBuilder(builder: (context, constraints) {
          onSize(constraints.maxWidth - widget.padding * 2,
              constraints.maxHeight - widget.padding * 2);
          // use flutter's Scrollable to manage scrolling to better integrate
          // with widgets such as Scrollbar.
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              onScroll(notification.metrics.pixels);
              return false;
            },
            child: Scrollable(
              controller: widget.scrollController,
              viewportBuilder: (context, offset) {
                final position = widget.scrollController.position;

                /// use [_EmptyScrollActivity] to suppress unexpected behaviors
                /// that come from [applyViewportDimension].
                if (position is ScrollActivityDelegate) {
                  position.beginActivity(
                    _EmptyScrollActivity(position as ScrollActivityDelegate),
                  );
                }

                final viewPortHeight =
                    constraints.maxHeight - widget.padding * 2;

                // set viewport height.
                offset.applyViewportDimension(viewPortHeight);

                if (widget.terminal.isReady) {
                  final minScrollExtent = 0.0;

                  final maxScrollExtent = math.max(
                      0.0,
                      _cellSize.cellHeight *
                          (widget.terminal.bufferHeight -
                              widget.terminal.terminalHeight));

                  // set how much the terminal can scroll
                  offset.applyContentDimensions(
                      minScrollExtent, maxScrollExtent);

                  // synchronize pending terminal scroll extent to ScrollController
                  if (_pendingTerminalScrollExtent != null) {
                    position.correctPixels(_pendingTerminalScrollExtent!);
                    _pendingTerminalScrollExtent = null;
                  }
                }

                return buildTerminal(context);
              },
            ),
          );
        }),
      ),
    );
  }

  Widget buildTerminal(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      dragStartBehavior: DragStartBehavior.down,
      onDoubleTapDown: (detail) {
        final pos = detail.localPosition;
        _tapPosition = getMouseOffset(pos.dx, pos.dy);
      },
      onTapDown: (detail) {
        final pos = detail.localPosition;
        _tapPosition = getMouseOffset(pos.dx, pos.dy);
        if (isShiftPressed && _tapPosition != null) {
          widget.terminal.onPanUpdate(_tapPosition as Position);
        } else {
          widget.terminal.clearSelection();
        }
        widget.terminal.refresh();
      },
      onDoubleTap: () {
        if (_tapPosition != null) {
          widget.terminal.onMouseDoubleTap(_tapPosition!);
          widget.terminal.refresh();
        }
      },
      onTap: () {
        if (widget.terminal.selection?.isEmpty ?? true) {
          InputListener.of(context)!.requestKeyboard();
        }
        if (_tapPosition != null) {
          widget.terminal.onMouseTap(_tapPosition!);
          widget.terminal.refresh();
        }
      },
      onPanStart: (detail) {
        final pos = detail.localPosition;
        final offset = getMouseOffset(pos.dx, pos.dy);
        widget.terminal.onPanStart(offset);
        widget.terminal.refresh();
      },
      onPanUpdate: (detail) {
        final pos = detail.localPosition;
        final offset = getMouseOffset(pos.dx, pos.dy);
        widget.terminal.onPanUpdate(offset);
        widget.terminal.refresh();
      },
      child: Container(
        constraints: BoxConstraints.expand(),
        child: Padding(
          padding: EdgeInsets.all(widget.padding),
          child: Stack(
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: TerminalPainter(
                    terminal: widget.terminal,
                    style: widget.style,
                    charSize: _cellSize,
                    textLayoutCache: textLayoutCache,
                  ),
                ),
              ),
              Positioned(
                child: CursorView(
                  terminal: widget.terminal,
                  cellSize: _cellSize,
                  focusNode: widget.focusNode,
                  blinkOscillator: blinkOscillator,
                ),
                width: _cellSize.cellWidth,
                height: _cellSize.cellHeight,
                left: _getCursorOffset().dx,
                top: _getCursorOffset().dy,
              ),
            ],
          ),
        ),
        color:
            Color(widget.terminal.backgroundColor).withOpacity(widget.opacity),
      ),
    );
  }

  Offset _getCursorOffset() {
    final screenCursorY = widget.terminal.cursorY;
    final offsetX = _cellSize.cellWidth * widget.terminal.cursorX;
    final offsetY = _cellSize.cellHeight * screenCursorY;

    return Offset(offsetX, offsetY);
  }

  /// Get global cell position from mouse position.
  Position getMouseOffset(double px, double py) {
    final col = ((px - widget.padding) / _cellSize.cellWidth).floor();
    final row = ((py - widget.padding) / _cellSize.cellHeight).floor();

    final x = col;
    final y = widget.terminal.convertViewLineToRawLine(row) -
        widget.terminal.scrollOffsetFromBottom;

    return Position(x, y);
  }

  int? _lastTerminalWidth;
  int? _lastTerminalHeight;

  void onSize(double width, double height) {
    if (!widget.terminal.isReady) {
      return;
    }
    final termWidth = (width / _cellSize.cellWidth).floor();
    final termHeight = (height / _cellSize.cellHeight).floor();

    if (_lastTerminalWidth == termWidth && _lastTerminalHeight == termHeight) {
      return;
    }

    _lastTerminalWidth = termWidth;
    _lastTerminalHeight = termHeight;

    widget.terminal.resize(
      termWidth,
      termHeight,
      (termWidth * _cellSize.cellWidth).floor(),
      (termHeight * _cellSize.cellHeight).floor(),
    );
  }

  TextEditingValue? onInput(TextEditingValue value) {
    if (!isTyping) {
      isTyping = true;
      blinkOscillator.pause();
      if (timerTyping != null) {
        timerTyping!.cancel();
      }
      timerTyping = Timer(Duration(milliseconds: 300), () {
        isTyping = false;
        blinkOscillator.resume();
      });
    }
    return widget.inputBehavior.onTextEdit(value, widget.terminal);
  }

  KeyEventResult onKeyStroke(FocusNode node, RawKeyEvent event) {
    // TODO: find a way to stop scrolling immediately after key stroke.
    if (!isTyping) {
      isTyping = true;
      blinkOscillator.pause();
      if (timerTyping != null) {
        timerTyping!.cancel();
      }
      timerTyping = Timer(Duration(milliseconds: 300), () {
        isTyping = false;
        blinkOscillator.resume();
      });
    }
    if (event is RawKeyDownEvent && event.isShiftPressed) {
      isShiftPressed = event.isShiftPressed;
    }
    if (event is RawKeyUpEvent && !event.isShiftPressed) {
      isShiftPressed = event.isShiftPressed;
    }

    var ret = widget.inputBehavior.onKeyStroke(event, widget.terminal);
    return ret;
  }

  void onFocus(bool focused) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      widget.terminal.refresh();
    });
  }

  void onAction(TextInputAction action) {
    widget.inputBehavior.onAction(action, widget.terminal);
  }

  // synchronize flutter scroll offset to terminal
  void onScroll(double offset) {
    final topOffset = (offset / _cellSize.cellHeight).ceil();
    final bottomOffset = widget.terminal.invisibleHeight - topOffset;
    widget.terminal.setScrollOffsetFromBottom(bottomOffset);
  }
}

class CursorView extends StatefulWidget {
  final CellSize cellSize;
  final TerminalUiInteraction terminal;
  final FocusNode? focusNode;
  final Oscillator blinkOscillator;
  CursorView({
    required this.terminal,
    required this.cellSize,
    required this.focusNode,
    required this.blinkOscillator,
  });

  @override
  State<StatefulWidget> createState() => _CursorViewState();
}

class _CursorViewState extends State<CursorView> {
  bool get focused {
    return widget.focusNode?.hasFocus ?? false;
  }

  var _isOscillatorCallbackRegistered = false;

  @override
  void initState() {
    _isOscillatorCallbackRegistered = true;
    widget.blinkOscillator.addListener(onOscillatorTick);

    widget.terminal.addListener(onTerminalChange);

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: CursorPainter(
        visible: _isCursorVisible(),
        focused: focused,
        charSize: widget.cellSize,
        blinkVisible: widget.blinkOscillator.value,
        cursorColor: widget.terminal.cursorColor,
      ),
    );
  }

  bool _isCursorVisible() {
    final screenCursorY =
        widget.terminal.cursorY + widget.terminal.scrollOffsetFromBottom;

    if (screenCursorY < 0 || screenCursorY >= widget.terminal.terminalHeight) {
      return false;
    }
    return widget.terminal.showCursor;
  }

  @override
  void dispose() {
    widget.terminal.removeListener(onTerminalChange);
    widget.blinkOscillator.removeListener(onOscillatorTick);

    super.dispose();
  }

  void onTerminalChange() {
    if (!mounted) {
      return;
    }

    setState(() {
      if (_isCursorVisible() /*&& widget.terminal.blinkingCursor*/ && focused) {
        if (!_isOscillatorCallbackRegistered) {
          _isOscillatorCallbackRegistered = true;
          widget.blinkOscillator.addListener(onOscillatorTick);
        }
      } else {
        if (_isOscillatorCallbackRegistered) {
          _isOscillatorCallbackRegistered = false;
          widget.blinkOscillator.removeListener(onOscillatorTick);
        }
      }
    });
  }

  void onOscillatorTick() {
    setState(() {});
  }
}

/// A scroll activity that does nothing. Used to suppress unexpected behaviors
/// from [Scrollable] during viewport building process.
class _EmptyScrollActivity extends IdleScrollActivity {
  _EmptyScrollActivity(ScrollActivityDelegate delegate) : super(delegate);

  @override
  void applyNewDimensions() {}

  /// set [isScrolling] to ture to prevent flutter from calling the old scroll
  /// activity.
  @override
  final isScrolling = true;

  void dispatchScrollStartNotification(
      ScrollMetrics metrics, BuildContext? context) {}

  void dispatchScrollUpdateNotification(
      ScrollMetrics metrics, BuildContext context, double scrollDelta) {}

  void dispatchOverscrollNotification(
      ScrollMetrics metrics, BuildContext context, double overscroll) {}

  void dispatchScrollEndNotification(
      ScrollMetrics metrics, BuildContext context) {}
}
