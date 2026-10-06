import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/meme_directive.dart';
import 'package:yiji/ui/chat_screen.dart';

/// **走真实渲染路径**的关键用例。
///
/// 我之前写过一版"108 张全验":用 `rootBundle` 读字节 + `instantiateImageCodec`
/// 解码。那两条全绿,而用户的图照样坏——因为**它们验的不是应用里那条路**:
/// 我绕过了 `ChatBubbleProbe → splitMessageParts → ChatImage.parse →
/// _MessageImage → _AssetImage`,自己挑了一步来断言。看起来覆盖面很大,
/// 实际上等于什么都没验。
///
/// 这一组只做一件事:**让气泡真的渲染**,然后断言没有出现「图不在了」。
/// 这才是用户看到的那个结果。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Meme> library;

  setUpAll(() async {
    final raw = await rootBundle.loadString('assets/memes/index.json');
    library = MemeLibrary.parseIndex(jsonDecode(raw));
    // 渲染失败时会走"按文件名回查图库"那条抢救路,它会去 load 图库。
    // 测试环境里 rootBundle 读索引会卡住,所以先把图库塞进去。
    MemeLibrary.primeForTest(MemeLibrary.fromIndex(library));
    // 目录查询背后的平台通道在 widget 测试里不响应,固定成真目录,
    // 否则磁盘那条路会永远停在转圈上。
    ChatImages.pinDirectoryForTest(
      Directory.systemTemp.createTempSync('yiji_render_all'),
    );
  });

  tearDownAll(() {
    ChatImages.directoryOverride = null;
  });

  /// 渲染一行内容,返回是否落到了「图不在了」。
  Future<bool> rendersBroken(WidgetTester tester, String content) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatBubbleProbe(text: content, isUser: false)),
      ),
    );
    // 真图会异步解码;坏图会走抢救。给足帧数再看结果。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    return find.text('图不在了').evaluate().isNotEmpty;
  }

  testWidgets('图库里每一张都能画出来,一张都不许"图不在了"', (tester) async {
    // 全库过一遍——但这次走的是**渲染**,不是我自己挑的一步。
    final broken = <String>[];
    for (final meme in library) {
      final line = memeLineFor(meme.messageRef);
      if (await rendersBroken(tester, line)) {
        broken.add('${meme.file}(引用 $line)');
      }
    }
    expect(
      broken,
      isEmpty,
      reason: '有 ${broken.length} 张在真实渲染里坏了:\n'
          '${broken.take(10).join('\n')}',
    );
  });

  testWidgets('AI 写出的整段消息(正文 + 图)能画出来', (tester) async {
    // 用户实际看到的是"一段正文 + 一行图"。分开测不够,合起来也得能画。
    final sample = library.first;
    final content = '好耶,那我也替你高兴。\n\n${memeLineFor(sample.messageRef)}';
    expect(await rendersBroken(tester, content), isFalse);
    expect(find.textContaining('那我也替你高兴'), findsOneWidget);
  });

  test('引用只有文件名时:查磁盘、查图库,拿不到就明确返回空', () async {
    // 不套 widget:widget 测试里目录查询背后的平台通道不响应,
    // 测出来的"失败"是测试环境的性质,不是功能问题。
    // 这里直接验底层契约——渲染层依赖的就是它。
    final missing = ChatImage.parse('![图] user_999999.png');
    expect(missing, isNotNull);
    expect(missing!.isAsset, isFalse, reason: '没有 asset: 前缀就该走磁盘那条路');
    expect(missing.fileName, 'user_999999.png');
    expect(
      await ChatImages.bytesOf(missing),
      isNull,
      reason: '磁盘和图库都没有时应当明确返回空,让渲染层给占位',
    );
  });

  testWidgets('内联(自包含)的图一定能画出来,不依赖任何查找', (tester) async {
    // **这是"AI 发的图永远画得出来"的保证**:字节就在消息里,
    // 没有路径可查错、没有文件可丢。
    final sample = library.first;
    final data = await rootBundle.load('assets/${sample.assetPath}');
    final bytes = data.buffer.asUint8List();
    final line =
        '![图] data:image/webp;base64,${base64Encode(bytes)}';

    final parsed = ChatImage.parse(line);
    expect(parsed, isNotNull);
    expect(parsed!.isInline, isTrue);
    expect(parsed.inlineBytes, isNotNull);
    expect(parsed.inlineBytes!.length, bytes.length);

    // 而且真的画得出来(走气泡渲染)。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubbleProbe(text: line, isUser: false),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('图不在了'), findsNothing);
    expect(
      find.byType(Image).evaluate().isNotEmpty ||
          find.byType(RawImage).evaluate().isNotEmpty,
      isTrue,
      reason: '内联图片应当直接画出来',
    );
  });

  test('内置引用的 fileName 是纯文件名,不是带前缀的整串', () {
    // 用户截图里的诊断写着:
    //   按文件名「asset:memes/daily/1786535328169.webp」在磁盘和内制图库里都没找到
    // 这就是 `fileName` 直接返回整串 ref 造成的——拿它当文件名当然找不到。
    final image = ChatImage.parse('![图] asset:memes/daily/x.webp');
    expect(image, isNotNull);
    expect(image!.isAsset, isTrue);
    expect(image.fileName, 'x.webp');
    expect(image.fileName.contains(':'), isFalse);
    expect(image.fileName.contains('/'), isFalse);
  });
}
