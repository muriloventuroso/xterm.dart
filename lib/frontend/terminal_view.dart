import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:xterm/buffer/cell.dart';
import 'package:xterm/frontend/char_size.dart';
import 'package:xterm/frontend/helpers.dart';
import 'package:xterm/frontend/input_behavior.dart';
import 'package:xterm/frontend/input_behaviors.dart';
import 'package:xterm/frontend/input_listener.dart';
import 'package:xterm/frontend/oscillator.dart';
import 'package:xterm/frontend/cache.dart';
import 'package:xterm/mouse/position.dart';
import 'package:xterm/terminal/terminal.dart';
import 'package:xterm/theme/terminal_style.dart';
import 'package:xterm/utli/hash_values.dart';

import 'mouse_listener.dart';

typedef ResizeHandler = void Function(int width, int height);

class TerminalView extends StatefulWidget {
  TerminalView({
    Key key,
    @required this.terminal,
    this.onResize,
    this.onScroll,
    this.style = const TerminalStyle(),
    FocusNode focusNode,
    this.autofocus = false,
    ScrollController scrollController,
    InputBehavior inputBehavior,
    this.useCache = true,
    this.readOnly = false
  })  : assert(terminal != null),
        focusNode = focusNode ?? FocusNode(),
        scrollController = scrollController ?? ScrollController(),
        inputBehavior = inputBehavior ?? InputBehaviors.platform,
        super(key: key ?? ValueKey(terminal));

  final Terminal terminal;
  final ResizeHandler onResize;
  final ScrollHandler onScroll;
  final FocusNode focusNode;
  final bool autofocus;
  final ScrollController scrollController;

  final TerminalStyle style;

  final InputBehavior inputBehavior;

  final bool useCache;

  final bool readOnly;

  CellSize measureCellSize() {
    final testString = 'xxxxxxxxxx' * 1000;

    final text = Text(
      testString,
      style: (style.textStyleProvider != null)
          ? style.textStyleProvider(
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
  final oscillator = Oscillator.ms(600);

  bool get focused {
    return widget.focusNode.hasFocus;
  }

  int _lastTerminalWidth;
  int _lastTerminalHeight;
  CellSize _cellSize;
  ViewportOffset _offset;
  bool _isShiftPressed;

  bool get isShiftPressed {
    if(_isShiftPressed == null){
      return false;
    }
    return _isShiftPressed;
  }

  var _minScrollExtent = 0.0;
  var _maxScrollExtent = 0.0;

  void onTerminalChange() {
    // if (_offset != null) {
    //   final currentScrollExtent =
    //       _cellSize.cellHeight * widget.terminal.buffer.scrollOffsetFromTop;

    //   if (_offset.pixels != currentScrollExtent) {
    //     _offset.correctBy(currentScrollExtent - _offset.pixels - 1);
    //   }
    // }

    if (mounted) {
      setState(() {});
    }
  }

  void onTick() {
    widget.terminal.refresh();
  }

  @override
  void initState() {
    // oscillator.start();
    // oscillator.addListener(onTick);
    _cellSize = widget.measureCellSize();
    widget.terminal.addListener(onTerminalChange);
    super.initState();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    widget.terminal.addListener(onTerminalChange);
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    // oscillator.stop();
    // oscillator.removeListener(onTick);

    widget.terminal.removeListener(onTerminalChange);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if(!widget.readOnly){
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
            onResize(constraints.maxWidth, constraints.maxHeight);
            return Scrollable(
              controller: widget.scrollController,
              viewportBuilder: (context, offset) {
                offset.applyViewportDimension(constraints.maxHeight);

                _minScrollExtent = 0.0;

                _maxScrollExtent = math.max(
                    0.0,
                    _cellSize.cellHeight * widget.terminal.buffer.height -
                        constraints.maxHeight);
                  
                // final currentScrollExtent = _cellSize.cellHeight *
                //     widget.terminal.buffer.scrollOffsetFromTop;

                // offset.correctBy(currentScrollExtent - offset.pixels - 1);

                offset.applyContentDimensions(_minScrollExtent, _maxScrollExtent);

                _offset = offset;
                _offset.addListener(onScroll);

                return buildTerminal(context);
              },
            );
          }),
        ),
      );
    }else{
      return LayoutBuilder(builder: (context, constraints) {
        onResize(constraints.maxWidth, constraints.maxHeight);
        return Scrollable(
          controller: widget.scrollController,
          viewportBuilder: (context, offset) {
            offset.applyViewportDimension(constraints.maxHeight);

            _minScrollExtent = 0.0;

            _maxScrollExtent = math.max(
                0.0,
                _cellSize.cellHeight * widget.terminal.buffer.height -
                    constraints.maxHeight);

            // final currentScrollExtent = _cellSize.cellHeight *
            //     widget.terminal.buffer.scrollOffsetFromTop;

            // offset.correctBy(currentScrollExtent - offset.pixels - 1);

            offset.applyContentDimensions(_minScrollExtent, _maxScrollExtent);

            _offset = offset;
            _offset.addListener(onScroll);

            return buildTerminal(context);
          },
        );
      });
    }
    
  }

  Widget buildTerminal(BuildContext context) {
    return MouseListener(
      onScroll: (o){
        if(widget.terminal.applicationCursorKeys){
          widget.onScroll(o);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        dragStartBehavior: DragStartBehavior.down,
        onTapDown: (detail) {
          if (widget.terminal.selection.isEmpty) {
            InputListener.of(context).requestKeyboard();
          } else if (!isShiftPressed){
            widget.terminal.selection.clear();
          }
          final pos = detail.localPosition;
          final offset = getMouseOffset(pos.dx, pos.dy);
          if (widget.terminal.selection.isEmpty && !isShiftPressed) {
            widget.terminal.mouseMode.onTap(widget.terminal, offset);
          }else{
            widget.terminal.mouseMode.onPanUpdate(widget.terminal, offset);
          }
          widget.terminal.refresh();
        },
        onPanStart: (detail) {
          final pos = detail.localPosition;
          final offset = getMouseOffset(pos.dx, pos.dy);
          widget.terminal.mouseMode.onPanStart(widget.terminal, offset);
          widget.terminal.refresh();
        },
        onPanUpdate: (detail) {
          final pos = detail.localPosition;
          final offset = getMouseOffset(pos.dx, pos.dy);
          widget.terminal.mouseMode.onPanUpdate(widget.terminal, offset);
          widget.terminal.refresh();
        },
        child: Container(
          constraints: BoxConstraints.expand(),
          color: Color(widget.terminal.theme.background.value),
          child: CustomPaint(
            painter: TerminalPainter(
              terminal: widget.terminal,
              view: widget,
              oscillator: oscillator,
              focused: focused,
              charSize: _cellSize,
            ),
          ),
        ),
      ),
    );
  }

  Position getMouseOffset(double px, double py) {
    final col = (px / _cellSize.cellWidth).floor();
    final row = (py / _cellSize.cellHeight).floor();

    final x = col;
    final y = widget.terminal.buffer.convertViewLineToRawLine(row) -
        widget.terminal.buffer.scrollOffsetFromBottom;

    return Position(x, y);
  }

  void onResize(double width, double height) {
    final termWidth = (width / _cellSize.cellWidth).floor();
    final termHeight = (height / _cellSize.cellHeight).floor();

    if (_lastTerminalWidth != termWidth || _lastTerminalHeight != termHeight) {
      _lastTerminalWidth = termWidth;
      _lastTerminalHeight = termHeight;

      // print('($termWidth, $termHeight)');

      if (widget.onResize != null) {
        widget.onResize(termWidth, termHeight);
      }

      SchedulerBinding.instance.addPostFrameCallback((_) {
        widget.terminal.resize(termWidth, termHeight);
      });

      // Future.delayed(Duration.zero).then((_) {
      //   widget.terminal.resize(termWidth, termHeight);
      // });
    }
  }

  TextEditingValue onInput(TextEditingValue value) {
    return widget.inputBehavior.onTextEdit(value, widget.terminal);
  }

  KeyEventResult onKeyStroke(FocusNode node, RawKeyEvent event) {
    var ret = widget.inputBehavior.onKeyStroke(event, widget.terminal);
    if(event.character != null || event.logicalKey == LogicalKeyboardKey.arrowDown || event.logicalKey == LogicalKeyboardKey.arrowUp){
      _offset.moveTo(_maxScrollExtent);
    }
    if(event.isShiftPressed != null){
      _isShiftPressed = event.isShiftPressed;
    }
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

  void onScroll() {
    final charOffset = (_offset.pixels / _cellSize.cellHeight).ceil();
    final offset = widget.terminal.invisibleHeight - charOffset;
    widget.terminal.buffer.setScrollOffsetFromBottom(offset);
  }
}

class TerminalPainter extends CustomPainter {
  TerminalPainter({
    this.terminal,
    this.view,
    this.oscillator,
    this.focused,
    this.charSize,
  });

  final Terminal terminal;
  final TerminalView view;
  final Oscillator oscillator;
  final bool focused;
  final CellSize charSize;

  @override
  void paint(Canvas canvas, Size size) {
    paintBackground(canvas);

    // if (oscillator.value) {
    // }

    if (terminal.showCursor) {
      paintCursor(canvas);
    }

    paintText(canvas);

    paintSelection(canvas);
  }

  void paintBackground(Canvas canvas) {
    final lines = terminal.getVisibleLines();

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final offsetY = i * charSize.cellHeight;
      final cellCount = math.min(terminal.viewWidth, line.length);

      for (var i = 0; i < cellCount; i++) {
        final cell = line.getCell(i);

        if (cell.attr == null || cell.width == 0) {
          continue;
        }

        final offsetX = i * charSize.cellWidth;
        final effectWidth = charSize.cellWidth * cell.width + 1;
        final effectHeight = charSize.cellHeight + 1;

        final bgColor =
            cell.attr.inverse ? cell.attr.fgColor : cell.attr.bgColor;

        if (bgColor == null) {
          continue;
        }

        final paint = Paint()..color = Color(bgColor.value);
        canvas.drawRect(
          Rect.fromLTWH(offsetX, offsetY, effectWidth, effectHeight),
          paint,
        );
      }
    }
  }

  void paintSelection(Canvas canvas) {
    for (var y = 0; y < terminal.viewHeight; y++) {
      final offsetY = y * charSize.cellHeight;
      final absoluteY = terminal.buffer.convertViewLineToRawLine(y) -
          terminal.buffer.scrollOffsetFromBottom;

      for (var x = 0; x < terminal.viewWidth; x++) {
        var cellCount = 0;

        while (
            terminal.selection.contains(Position(x + cellCount, absoluteY)) &&
                x + cellCount < terminal.viewWidth) {
          cellCount++;
        }

        if (cellCount == 0) {
          continue;
        }

        final offsetX = x * charSize.cellWidth;
        final effectWidth = cellCount * charSize.cellWidth;
        final effectHeight = charSize.cellHeight;

        final paint = Paint()..color = Colors.white.withOpacity(0.3);
        canvas.drawRect(
          Rect.fromLTWH(offsetX, offsetY, effectWidth, effectHeight),
          paint,
        );

        x += cellCount;
      }
    }
  }

  void paintText(Canvas canvas) {
    final lines = terminal.getVisibleLines();

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final offsetY = i * charSize.cellHeight;
      final cellCount = math.min(terminal.viewWidth, line.length);

      for (var i = 0; i < cellCount; i++) {
        final cell = line.getCell(i);

        if (cell.attr == null || cell.width == 0) {
          continue;
        }

        final offsetX = i * charSize.cellWidth;
        paintCell(canvas, cell, offsetX, offsetY);
      }
    }
  }

  void paintCell(Canvas canvas, Cell cell, double offsetX, double offsetY) {
    final attr = cell.attr;

    if (cell.codePoint == null || attr.invisible) {
      return;
    }

    final cellHash = hashValues(cell.codePoint, attr);
    var tp = textLayoutCache.getLayoutFromCache(cellHash);
    if (tp != null) {
      tp.paint(canvas, Offset(offsetX, offsetY));
      return;
    }

    final cellColor = attr.inverse
        ? attr.bgColor ?? terminal.theme.background
        : attr.fgColor ?? terminal.theme.foreground;

    var color = Color(cellColor.value);

    if (attr.faint) {
      color = color.withOpacity(0.5);
    }

    final style = (view.style.textStyleProvider != null)
        ? view.style.textStyleProvider(
            color: color,
            fontWeight: cell.attr.bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: cell.attr.italic ? FontStyle.italic : FontStyle.normal,
            fontSize: view.style.fontSize,
            decoration: cell.attr.underline
                ? TextDecoration.underline
                : TextDecoration.none,
          )
        : TextStyle(
            color: color,
            fontWeight: cell.attr.bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: cell.attr.italic ? FontStyle.italic : FontStyle.normal,
            fontSize: view.style.fontSize,
            decoration: cell.attr.underline
                ? TextDecoration.underline
                : TextDecoration.none,
            fontFamily: view.style.fontFamily[0],
            fontFamilyFallback: view.style.fontFamily);

    final span = TextSpan(
      text: String.fromCharCode(cell.codePoint),
      // text: codePointCache.getOrConstruct(cell.codePoint),
      style: style,
    );
    if(view.useCache){
      // final tp = textLayoutCache.getOrPerformLayout(span);
      tp = textLayoutCache.performAndCacheLayout(span, cellHash);
    }else{
      tp = TextPainter(text: span, textDirection: TextDirection.ltr);
      tp.layout();
    }
    

    tp.paint(canvas, Offset(offsetX, offsetY));
  }

  void paintCursor(Canvas canvas) {
    final screenCursorY = terminal.cursorY + terminal.scrollOffset;
    if (screenCursorY < 0 || screenCursorY >= terminal.viewHeight) {
      return;
    }

    final char = terminal.buffer.getCellUnderCursor();
    final width =
        char != null ? charSize.cellWidth * char.width : charSize.cellWidth;

    final offsetX = charSize.cellWidth * terminal.cursorX;
    final offsetY = charSize.cellHeight * screenCursorY;
    final paint = Paint()
      ..color = Color(terminal.theme.cursor.value)
      ..strokeWidth = focused ? 0.0 : 1.0
      ..style = focused ? PaintingStyle.fill : PaintingStyle.stroke;
    canvas.drawRect(
        Rect.fromLTWH(offsetX, offsetY, width, charSize.cellHeight), paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    // print('shouldRepaint');
    return true;
  }
}
