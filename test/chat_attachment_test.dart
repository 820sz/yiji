import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/data/chat_attachment.dart';

/// 附件类型判定。
///
/// 这里挡的是"把压缩包当文本读成乱码发给模型"这类事:
/// 模型看到乱码会一本正经地胡说,还不如当场告诉用户这个文件读不了。
void main() {
  Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

  group('可读的文本文件', () {
    test('md / txt / json / dart 都被读成文本', () async {
      for (final name in ['笔记.md', 'readme.txt', 'data.json', 'main.dart', 'log.csv']) {
        final attachment = await ChatAttachment.fromBytes(bytes('内容'), name);
        expect(attachment, isNotNull, reason: '$name 应该能读');
        expect(attachment!.isImage, isFalse);
        expect(attachment.text, '内容');
      }
    });

    test('内容原样保留,包括换行与中文', () async {
      final attachment = await ChatAttachment.fromBytes(
        bytes('# 标题\n\n第一段\n第二段'),
        'a.md',
      );
      expect(attachment!.text, '# 标题\n\n第一段\n第二段');
    });

    test('没有扩展名的文件读不了', () async {
      expect(await ChatAttachment.fromBytes(bytes('x'), 'README'), isNull);
    });

    test('超过大小上限的文本文件读不了', () async {
      final huge = Uint8List(ChatAttachment.maxTextBytes + 1);
      expect(await ChatAttachment.fromBytes(huge, 'big.txt'), isNull);
    });
  });

  group('图片', () {
    test('常见图片格式被识别为图片', () async {
      for (final name in ['a.png', 'b.jpg', 'c.JPEG', 'd.webp', 'e.gif']) {
        final attachment = await ChatAttachment.fromBytes(bytes('fake'), name);
        expect(attachment, isNotNull, reason: '$name 应该能带');
        expect(attachment!.isImage, isTrue);
        expect(attachment.imageBytes, isNotNull);
        // 图片不做大小限制(由模型那边决定),所以 text 应该是空的。
        expect(attachment.text, isNull);
      }
    });
  });

  group('读不了的二进制', () {
    test('压缩包 / 可执行文件 / 安装包都挡掉', () async {
      for (final name in ['a.zip', 'b.apk', 'c.exe', 'd.pdf', 'e.docx', 'f.mp4']) {
        expect(
          await ChatAttachment.fromBytes(bytes('x'), name),
          isNull,
          reason: '$name 不该被当成文本读',
        );
      }
    });
  });

  group('写进聊天记录的样子', () {
    test('图片和文件分别标注', () async {
      final image = await ChatAttachment.fromBytes(bytes('x'), 'photo.png');
      final file = await ChatAttachment.fromBytes(bytes('x'), 'notes.md');
      expect(image!.describe, '[图片] photo.png');
      expect(file!.describe, '[文件] notes.md');
    });
  });
}
