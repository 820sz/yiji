import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/data/chat_images.dart';

/// 头像/图片的落盘行为。
///
/// 用户报过"调完大小形状就保存不上"。头像以前是 base64 直接进数据库一行,
/// 512×512 的 PNG 编码出来几百 KB,写起来又慢又容易失败;现在改成写文件、
/// 库里只留文件名。这一组盯的就是那条路真的能走通。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('yiji_images_test');
    ChatImages.directoryOverride = tempDir;
  });

  tearDown(() {
    ChatImages.directoryOverride = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('存了能读回来', () async {
    final png = Uint8List.fromList(_tinyPng);
    final name = await ChatImages.saveAvatar('conversation_1', png);

    expect(name, isNotNull, reason: '存头像不该失败');
    final read = await ChatImages.readAvatar(name!);
    expect(read, isNotNull);
    expect(read!.length, png.length, reason: '读回来的应当就是存进去的那些字节');
  });

  test('同一个位置换图会删掉旧文件', () async {
    // 不删旧文件的话,换十次头像就在手机上留十份垃圾。
    final first = await ChatImages.saveAvatar('conversation_1', _bytes(10));
    final second = await ChatImages.saveAvatar('conversation_1', _bytes(20));

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second, isNot(first));

    final dir = await ChatImages.avatarDir();
    final names = dir.listSync().whereType<File>().map((f) => f.path).toList();
    expect(names, hasLength(1), reason: '同一位置只该留最新那一张,实际:$names');
  });

  test('不同位置的头像互不影响', () async {
    await ChatImages.saveAvatar('conversation_1', _bytes(10));
    await ChatImages.saveAvatar('conversation_2', _bytes(20));

    final dir = await ChatImages.avatarDir();
    final names = dir.listSync().whereType<File>().toList();
    expect(names, hasLength(2));
  });

  test('读一个不存在的头像返回 null,不抛错', () async {
    expect(await ChatImages.readAvatar('根本没有这个文件.png'), isNull);
  });
}

Uint8List _bytes(int fill) => Uint8List.fromList(List.filled(64, fill));

const _tinyPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
