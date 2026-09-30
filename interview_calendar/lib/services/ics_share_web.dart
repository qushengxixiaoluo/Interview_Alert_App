import 'dart:convert';
import 'package:share_plus/share_plus.dart';

/// 浏览器：不能用 path_provider（web 不支持临时目录），
/// 直接把内容以字节形式交给分享 API。
/// 浏览器会走 Web Share API；不支持时 share_plus 会退化成下载文件。
Future<String> shareIcsFile(String content, String filename, String shareText) async {
  final bytes = utf8.encode(content);

  await Share.shareXFiles(
    [
      XFile.fromData(
        bytes,
        name: filename,
        mimeType: 'text/calendar',
      ),
    ],
    text: shareText,
  );
  return '已调起分享（浏览器若不支持分享，会直接下载 $filename）';
}
