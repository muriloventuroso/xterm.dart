import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:xterm/frontend/char_size.dart';
import 'package:xterm/mouse/position.dart';
import 'package:xterm/mouse/selection.dart';
import 'package:xterm/terminal/terminal.dart';

class SearchPosition {
  int startCol = 0;
  int startRow = 0;

  SearchPosition(this.startCol, this.startRow);
}

class SearchResult {
  String term;
  int col;
  int row;

  SearchResult(this.term, this.col, this.row);
}

class SearchOptions {
  bool regex;
  bool wholeWord;
  bool caseSensitive;
  bool incremental;

  SearchOptions(
      this.regex, this.wholeWord, this.caseSensitive, this.incremental);
}

const String NON_WORD_CHARACTER = " ~!@#\$%^&*()+`-=[]{}|\;:\"',./<>?";
const LINES_CACHE_TIME_TO_LIVE = 15 * 1000; // 15 secs

class SearchTerminal {
  final Terminal terminal;
  final ScrollController scrollController;
  final CellSize cellSize;
  List<String> _linesCache = [];
  Timer? _linesCacheTimeout;
  ValueNotifier<int> cursorMoveListener;
  ValueNotifier<int> resizeListener;

  SearchTerminal(this.terminal, this.scrollController, this.cellSize,
      this.cursorMoveListener, this.resizeListener);

  void _initLinesCache() {
    if (this._linesCache.isEmpty) {
      _linesCache = List<String>.filled(terminal.buffer.lines.length, "");
      cursorMoveListener.addListener(_destroyLinesCache);
      resizeListener.addListener(_destroyLinesCache);
    }
    _linesCacheTimeout?.cancel();

    _linesCacheTimeout =
        Timer.periodic(Duration(seconds: LINES_CACHE_TIME_TO_LIVE), (timer) {
      _destroyLinesCache();
    });
  }

  void _destroyLinesCache() {
    _linesCache = [];

    _linesCacheTimeout?.cancel();
    _linesCacheTimeout = null;

    cursorMoveListener.removeListener(_destroyLinesCache);
    resizeListener.removeListener(_destroyLinesCache);
  }

  bool _isWholeWord(int searchIndex, String line, String term) {
    if (searchIndex == 0) {
      return true;
    }
    if (NON_WORD_CHARACTER.contains(line[searchIndex - 1])) {
      return true;
    }
    if (searchIndex + term.length == line.length) {
      return true;
    }
    if (NON_WORD_CHARACTER.contains(line[searchIndex + term.length])) {
      return true;
    }
    return false;
  }

  bool findNext(String term, SearchOptions searchOptions) {
    if (term.isEmpty) {
      terminal.selection?.clear();
      terminal.refresh();
      return false;
    }

    int startRow = 0;
    int startCol = 0;
    Selection? currentSelection;

    if (terminal.selection != null && !terminal.selection!.isEmpty) {
      var incremental = searchOptions.incremental;
      currentSelection = terminal.selection;
      startRow =
          incremental ? currentSelection!.start!.y : currentSelection!.end!.y;
      startCol =
          incremental ? currentSelection.start!.x : currentSelection.end!.x;
    }

    _initLinesCache();

    var searchPosition = SearchPosition(startCol, startRow);

    // Search startRow
    var result = _findInLine(term, searchPosition, searchOptions, false);

    // Search from startRow + 1 to end
    if (result == null) {
      for (var y = startRow + 1; y < terminal.buffer.lines.length; y++) {
        searchPosition.startRow = y;
        searchPosition.startCol = 0;
        // If the current line is wrapped line, increase index of column to ignore the previous scan
        // Otherwise, reset beginning column index to zero with set new unwrapped line index
        result = _findInLine(term, searchPosition, searchOptions, false);
        if (result != null) {
          break;
        }
      }
    }

    // If we hit the bottom and didn't search from the very top wrap back up
    if (result == null && startRow != 0) {
      for (var y = 0; y < startRow; y++) {
        searchPosition.startRow = y;
        searchPosition.startCol = 0;
        result = _findInLine(term, searchPosition, searchOptions, false);
        if (result != null) {
          break;
        }
      }
    }

    // If there is only one result, wrap back and return selection if it exists.
    if (result == null && currentSelection != null) {
      searchPosition.startRow = currentSelection.start!.y;
      searchPosition.startCol = 0;
      result = _findInLine(term, searchPosition, searchOptions, false);
    }

    return _selectResult(result);
  }

  bool findPrevious(String term, SearchOptions searchOptions) {
    if (term.isEmpty) {
      terminal.selection!.clear();
      terminal.refresh();
      return false;
    }

    bool isReverseSearch = true;
    int startRow = terminal.buffer.lines.length;
    int startCol = terminal.viewWidth;
    bool incremental = searchOptions.incremental;
    Selection? currentSelection;
    if (!terminal.selection!.isEmpty) {
      currentSelection = terminal.selection;
      // Start from selection start if there is a selection
      startRow = currentSelection!.start!.y;
      startCol = currentSelection.start!.x;
    }
    SearchResult? result;

    _initLinesCache();

    var searchPosition = SearchPosition(startCol, startRow);

    if (incremental) {
      result = _findInLine(term, searchPosition, searchOptions, false);
      var isOldResultHighlighted =
          result != null && result.row == startRow && result.col == startCol;
      if (!isOldResultHighlighted) {
        if (currentSelection != null) {
          searchPosition.startRow = currentSelection.end!.y;
          searchPosition.startCol = currentSelection.end!.x;
        }
        result = _findInLine(term, searchPosition, searchOptions, true);
      }
    } else {
      result =
          _findInLine(term, searchPosition, searchOptions, isReverseSearch);
    }

    // Search from startRow - 1 to top
    if (result == null) {
      searchPosition.startCol =
          [searchPosition.startCol, terminal.viewWidth].reduce(max);
      for (var y = startRow - 1; y >= 0; y--) {
        searchPosition.startRow = y;
        result =
            _findInLine(term, searchPosition, searchOptions, isReverseSearch);
        if (result != null) {
          break;
        }
      }
    }
    // If we hit the top and didn't search from the very bottom wrap back down
    if (result == null && startRow != terminal.buffer.lines.length) {
      for (var y = terminal.buffer.lines.length - 1; y >= 0; y--) {
        searchPosition.startRow = y;
        result =
            _findInLine(term, searchPosition, searchOptions, isReverseSearch);
        if (result != null) {
          break;
        }
      }
    }

    if (result == null && currentSelection != null) {
      return true;
    }
    return _selectResult(result);
  }

  SearchResult? _findInLine(String term, SearchPosition searchPosition,
      SearchOptions searchOptions, bool isReverseSearch) {
    int row = searchPosition.startRow;
    int col = searchPosition.startCol;

    if (row >= terminal.buffer.lines.length) {
      return null;
    }

    // Ignore wrapped lines, only consider on unwrapped line (first row of command string).
    if (terminal.buffer.lines.length > row) {
      var firstLine = terminal.buffer.lines[row];
      if (firstLine.isWrapped) {
        if (isReverseSearch) {
          searchPosition.startCol += terminal.viewWidth;
          return null;
        }

        // This will iterate until we find the line start.
        // When we find it, we will search using the calculated start column.
        searchPosition.startRow--;
        searchPosition.startCol += terminal.viewWidth;
        return _findInLine(
            term, searchPosition, searchOptions, isReverseSearch);
      }
    }

    var stringLine = _linesCache.isNotEmpty ? _linesCache[row] : null;
    if (stringLine == null || stringLine == "") {
      stringLine = _translateBufferLineToStringWithWrap(row, true);
      _linesCache[row] = stringLine;
    }

    String searchTerm = searchOptions.caseSensitive ? term : term.toLowerCase();
    String searchStringLine =
        searchOptions.caseSensitive ? stringLine : stringLine.toLowerCase();
    int resultIndex = -1;

    if (searchOptions.regex) {
      RegExp searchRegex = new RegExp(searchTerm);
      if (isReverseSearch) {
        // This loop will get the resultIndex of the _last_ regex match in the range 0..col
        // TODO: Testar
        for (var foundTerm
            in searchRegex.allMatches(searchStringLine.substring(0, col))) {
          resultIndex = foundTerm.start;
          var newTerm = foundTerm.group(0);
          if (newTerm != null) {
            term = newTerm;
          }
        }
      } else {
        var foundTerm =
            searchRegex.allMatches(searchStringLine.substring(col)).toList();
        if (foundTerm.isNotEmpty) {
          resultIndex = col + foundTerm[0].start;
          var newTerm = foundTerm[0].group(0);
          if (newTerm != null) {
            term = newTerm;
          }
        }
      }
    } else {
      if (isReverseSearch) {
        if (col - searchTerm.length > 0 && searchStringLine.length > 0) {
          if (col >= searchStringLine.length) {
            col = searchStringLine.length - 1;
          }
          resultIndex =
              searchStringLine.substring(0, col).lastIndexOf(searchTerm);
        }
      } else {
        resultIndex = searchStringLine.indexOf(searchTerm, col);
      }
    }

    if (resultIndex >= 0) {
      // Adjust the row number and search index if needed since a "line" of text can span multiple rows
      if (resultIndex >= terminal.viewWidth) {
        row += (resultIndex / terminal.viewWidth).floor();
        resultIndex = resultIndex % terminal.viewWidth;
      }
      if (searchOptions.wholeWord &&
          !_isWholeWord(resultIndex, searchStringLine, term)) {
        return null;
      }

      if (terminal.buffer.lines.length > row) {
        var line = terminal.buffer.lines[row];
        for (var i = 0; i < resultIndex; i++) {
          var cell = line.cellGetContent(i);
          if (cell == 0) {
            break;
          }

          var char = String.fromCharCode(cell);
          if (char.length > 1) {
            resultIndex -= char.length - 1;
          }

          var charWidth = line.cellGetWidth(i);
          if (charWidth == 0) {
            resultIndex++;
          }
        }
      }

      return SearchResult(term, resultIndex, row);
    }
    return null;
  }

  String _translateBufferLineToStringWithWrap(int lineIndex, bool trimRight) {
    String lineString = "";
    bool lineWrapsToNext = false;

    do {
      if (terminal.buffer.lines.length > lineIndex + 1) {
        if (terminal.buffer.lines.length < lineIndex + 2) {
          lineWrapsToNext = false;
        } else {
          var nextLine = terminal.buffer.lines[lineIndex + 1];
          lineWrapsToNext = nextLine.isWrapped;
        }
      }
      if (terminal.buffer.lines.length > lineIndex) {
        var line = terminal.buffer.lines[lineIndex];
        lineString += line.toString();
        lineIndex++;
      } else {
        break;
      }
    } while (lineWrapsToNext);

    return lineString;
  }

  bool _selectResult(SearchResult? result) {
    if (result == null) {
      terminal.selection!.clear();
      terminal.refresh();
      return false;
    }
    terminal.selection!.init(Position(result.col, result.row));
    terminal.selection!
        .update(Position(result.col + result.term.length - 1, result.row));
    terminal.refresh();
    // If it is not in the viewport then we scroll else it just gets selected
    int startView = scrollController.position.pixels.toInt();
    int endView =
        (startView + terminal.viewHeight * cellSize.cellHeight).toInt();

    if (result.row * cellSize.cellHeight >= endView ||
        result.row * cellSize.cellHeight < startView) {
      scrollController.jumpTo(result.row * cellSize.cellHeight);
    }
    return true;
  }
}
