import 'dart:collection';

import 'package:xterm/terminal/terminal.dart';

// bool _isOscTerminator(int codePoint) {
//   final terminator = {0x07, 0x00};
//   // final terminator = {0x07, 0x5c};
//   return terminator.contains(codePoint);
// }

List<String> _parseOsc(Queue<int> queue, Set<int> terminators) {
  final params = <String>[];
  final param = StringBuffer();

  var readOffset = 0;

  while (true) {
    if(queue.length <= readOffset){
      return null;
    }
    final char = queue.elementAt(readOffset++);

    if (terminators.contains(char)) {
      params.add(param.toString());
      break;
    }

    const semicolon = 59;
    if (char == semicolon) {
      params.add(param.toString());
      param.clear();
      continue;
    }

    param.writeCharCode(char);
  }

  for(var i = 0; i < readOffset; i++){
    queue.removeFirst();
  }

  return params;
}

bool oscHandler(Queue<int> queue, Terminal terminal) {
  final params = _parseOsc(queue, terminal.platform.oscTerminators);

  if (params == null) {
    return false;
  }

  terminal.debug.onOsc(params);

  if (params.isEmpty) {
    terminal.debug.onError('osc with no params');
    return true;
  }

  if (params.length < 2) {
    return true;
  }

  final ps = params[0];
  final pt = params[1];

  switch (ps) {
    case '0':
    case '2':
      terminal.onTitleChange(pt);
      break;
    case '1':
      terminal.onIconChange(pt);
      break;
    default:
      terminal.debug.onError('unknown osc ps: $ps');
  }

  return true;
}