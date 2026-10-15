import 'dart:convert';
import 'dart:io';
import 'package:xuefo/main.dart';

void main() {
  final json = jsonDecode(File('/tmp/d8863_j16.json').readAsStringSync()) as Map;
  final html = (json['results'] as List).first as String;
  final lines = parseScriptureHtml(html);
  for (final line in lines) {
    final id = line.linehead ?? '';
    if (id.contains('0582b0') || id.contains('0583a0')) {
      print('${line.linehead} | notes=${line.inlineNotes.length} | ${line.text}');
      for (final n in line.inlineNotes) {
        print('  note off=${n.offset} len=${n.length} text=${line.text.substring(n.offset, n.offset+n.length)}');
      }
    }
  }
}
