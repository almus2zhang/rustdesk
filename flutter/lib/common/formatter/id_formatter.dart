import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IDTextEditingController extends TextEditingController {
  IDTextEditingController({String? text}) : super(text: text);

  String get id => trimID(value.text);

  set id(String newID) => text = formatID(newID);
}

class IDTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) {
      return newValue.copyWith(text: '');
    } else if (newValue.text.compareTo(oldValue.text) == 0) {
      return newValue;
    } else {
      int selectionIndexFromTheRight =
          newValue.text.length - newValue.selection.extentOffset;
      String newID = formatID(newValue.text);
      return TextEditingValue(
        text: newID,
        selection: TextSelection.collapsed(
          offset: newID.length - selectionIndexFromTheRight,
        ),
        // https://github.com/flutter/flutter/issues/78066#issuecomment-797869906
        composing: newValue.composing,
      );
    }
  }
}

String formatID(String id) {
  String id2 = id.replaceAll(' ', '');
  final lower = id2.toLowerCase();
  if (lower.startsWith('302:') || lower.startsWith('302：') ||
      lower.startsWith('301:') || lower.startsWith('301：') ||
      lower.startsWith('http://') || lower.startsWith('http：//') ||
      lower.startsWith('https://') || lower.startsWith('https：//')) return id;
  String suffix = '';
  if (id2.endsWith(r'\r') || id2.endsWith(r'/r')) {
    suffix = id2.substring(id2.length - 2, id2.length);
    id2 = id2.substring(0, id2.length - 2);
  }
  if (int.tryParse(id2) == null) return id;
  String newID = '';
  if (id2.length <= 3) {
    newID = id2;
  } else {
    var n = id2.length;
    var a = n % 3 != 0 ? n % 3 : 3;
    newID = id2.substring(0, a);
    for (var i = a; i < n; i += 3) {
      newID += " ${id2.substring(i, i + 3)}";
    }
  }
  return newID + suffix;
}

String trimID(String id) {
  var s = id.replaceAll(' ', '');
  if (s.startsWith('302：')) {
    s = '302:${s.substring(4)}';
  } else if (s.startsWith('301：')) {
    s = '301:${s.substring(4)}';
  } else if (s.toLowerCase().startsWith('http：//')) {
    s = 'http://${s.substring(7)}';
  } else if (s.toLowerCase().startsWith('https：//')) {
    s = 'https://${s.substring(8)}';
  }
  return s;
}
