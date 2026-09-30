import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 桌面/移动端：先落一个临时文件，再调系统分享
Future<String> shareIcsFile(String content, String filename, String shareText) async {
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, filename));
  await file.writeAsString(content, encoding: utf8);

  await Share.shareXFiles(
    [XFile(file.path, mimeType: 'text/calendar')],
    text: shareText,
  );
  return '已调起系统分享\n文件位置：${file.path}';
}
