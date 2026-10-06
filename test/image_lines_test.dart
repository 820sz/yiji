import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/image_lines.dart';
import 'package:yiji/ui/chat_screen.dart';

/// 「图不在了」这一条链路。
///
/// 用户截图里那个占位框写的是:
/// ```
/// 引用:瘫成一团趴在鲸鱼抱枕上,眼都睁不开
/// 磁盘上没这个文件,图库里也没有同名的内置图
/// ```
/// 那不是一条路径,而是一句**描述**——模型照着提示词里那个 `![图] ...` 的格式,
/// 自己写了一行 `![图] <清单里的描述>`。渲染层只认引用,于是把它当成一张
/// 找不到的图。
///
/// 这一组盯三件事:
/// 1. 落库时模型自己写的图片行会被归一化(能认出来的变成自包含字节,
///    认不出来的整行不留),所以这种行再也不该出现在消息里;
/// 2. 就算它出现了(老消息),渲染层也要能按描述把图找回来,而不是显示破图;
/// 3. 给模型看的历史是**投影**:不带 `![图]` 标记、不带内联字节。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Meme> builtin;
  late Directory temp;

  /// 用户截图里那一张,描述逐字来自 assets/memes/index.json。
  const victimCaption = '瘫成一团趴在鲸鱼抱枕上，眼都睁不开';
  const victimFile = 'daily/1785381947299.webp';

  setUpAll(() async {
    final raw = await rootBundle.loadString('assets/memes/index.json');
    builtin = MemeLibrary.parseIndex(jsonDecode(raw));
    MemeLibrary.primeForTest(MemeLibrary.fromIndex(builtin));
    temp = Directory.systemTemp.createTempSync('yiji_image_lines');
    ChatImages.pinDirectoryForTest(temp);
  });

  tearDownAll(() {
    ChatImages.directoryOverride = null;
  });

  test('图库里确实有那张图(前提没变,下面的用例才有意义)', () {
    final hit = builtin.where((m) => m.caption == victimCaption);
    expect(hit, hasLength(1), reason: '换过索引就要同步改这个用例');
    expect(hit.first.file, victimFile);
  });

  group('按描述反查图', () {
    test('一句描述能定位到那张图', () {
      final library = MemeLibrary.fromIndex(builtin);
      final found = library.findByRef(victimCaption);
      expect(found, isNotNull, reason: '描述必须能反查到图,否则老消息永远修不回来');
      expect(found!.file, victimFile);
    });

    test('库里没有的描述返回 null,不随机塞一张', () {
      // 这是它和 pickByCaption 的区别:反查只认对得上的,
      // 随便给一张图和"配不上图"是同一类毛病,用户更莫名其妙。
      final library = MemeLibrary.fromIndex(builtin);
      expect(library.findByRef('这句话不在图库清单里的任何一行上'), isNull);
    });

    test('短描述不会因为"被包含"就错误命中', () {
      final library = MemeLibrary.fromIndex(builtin);
      // 「大肥鱼」这类短词在图库里被好几条 caption 含着一部分,
      // 但那是关键词级别的巧合,不该定到某一张图上去。
      expect(library.findByRef('大肥鱼'), isNull);
    });

    test('asset 引用、文件名、短 id 都能反查到', () {
      final library = MemeLibrary.fromIndex(builtin);
      expect(library.findByRef('asset:memes/$victimFile')?.file, victimFile);
      expect(library.findByRef(victimFile)?.file, victimFile);
      expect(library.findByRef('1785381947299')?.file, victimFile);
    });
  });

  group('落库前归一化图片行', () {
    test('描述当引用写出来的那一行,会被换成自包含的字节', () async {
      final text = '今天又瘫了。\n\n![图] $victimCaption';
      final normalized = await normalizeImageLines(text);
      expect(normalized, contains('data:image/'));
      expect(
        normalized,
        isNot(contains('![图] $victimCaption')),
        reason: '留着这行就是用户截图里那个「图不在了」',
      );
      // 正文一个字都不能丢。
      expect(normalized, contains('今天又瘫了。'));
    });

    test('认不出来的引用整行删掉,不留悬空图片行', () async {
      final normalized = await normalizeImageLines('正文\n![图] 完全不存在的引用串');
      expect(normalized, '正文');
      expect(normalized.contains('![图]'), isFalse);
    });

    test('本来就自包含的行原样保留', () async {
      final bytes = Uint8List.fromList(List<int>.filled(64, 7));
      final line = '![图] data:image/png;base64,${base64Encode(bytes)}';
      expect(await normalizeImageLines(line), line);
    });

    test('没有图片行的正文不会被改动', () async {
      const text = '第一行\n第二行';
      expect(await normalizeImageLines(text), text);
    });
  });

  group('给模型看的历史投影', () {
    test('内联字节不进上下文,标记也不进', () {
      final bytes = Uint8List.fromList(List<int>.filled(64, 7));
      final stored = '确实惨。\n\n![图] data:image/png;base64,${base64Encode(bytes)}';
      final projected = projectForModel(stored, isUser: false);
      expect(projected, contains('确实惨。'));
      expect(projected, contains('（你上一轮回了一张图）'));
      expect(projected.contains('data:image'), isFalse, reason: '几十 KB 的 base64 会挤爆上下文');
      expect(projected.contains('![图]'), isFalse, reason: '模型照这个格式模仿,就是那个 bug');
    });

    test('用户发的表情包,描述要留给模型', () {
      const stored = '哈哈哈\n![图] asset:memes/$victimFile | 瘫成一团趴在鲸鱼抱枕上，眼都睁不开';
      final projected = projectForModel(stored, isUser: true);
      expect(projected, contains('（他发了一张图:瘫成一团趴在鲸鱼抱枕上，眼都睁不开）'));
      expect(projected.contains('asset:'), isFalse);
      // 用括号陈述而不是方括号:方括号那种写法模型会当成"发图的方式"照抄。
      expect(
        projected.contains('[我发的图'),
        isFalse,
        reason: '方括号会被模型照抄成一行文字,用户什么都收不到',
      );
    });

    test('没有图的消息原样返回', () {
      expect(projectForModel('就聊聊天', isUser: true), '就聊聊天');
    });
  });

  group('渲染', () {
    /// 渲染一段正文,返回有没有落到「图不在了」。
    ///
    /// **必须 `runAsync`**:这条路径要真去查磁盘、读打包资源,而 widget 测试
    /// 默认跑在假时钟里,真实 I/O 不会自己完成——不放开真实时间,看到的是
    /// "一直转圈",那是测试环境的性质,不是功能好坏。
    /// 每放开一小段真实时间就泵一帧:链上每一步都要各自的 I/O 回合。
    Future<bool> rendersBroken(WidgetTester tester, String text) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatBubbleProbe(text: text, isUser: false)),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      return find.text('图不在了').evaluate().isNotEmpty;
    }

    testWidgets('老消息里那一行「![图] 描述」现在能画出图来', (tester) async {
      // **走真实渲染路径**:用户看到的就是这个结果。
      expect(
        await rendersBroken(tester, '今天又瘫了。\n\n![图] $victimCaption'),
        isFalse,
        reason: '按描述反查得到那张图,就不该再显示破图占位',
      );
      expect(
        find.byType(Image).evaluate().isNotEmpty,
        isTrue,
        reason: '应当真的画出一张图',
      );
      // 占位框里那句诊断也不该出现。
      expect(find.textContaining('引用:'), findsNothing);
    });

    testWidgets('彻底认不出的引用还是给占位,不假装画出来了', (tester) async {
      expect(await rendersBroken(tester, '![图] 一个谁都不认识的引用'), isTrue);
    });
  });

  group('渲染开销', () {
    test('同一条引用只解码一次', () async {
      // `Image.memory` 认图的键是字节对象的身份,而 base64 解码每次都会造一个
      // 新的 Uint8List。不缓存的话气泡每重建一次就要重新解码一张图——
      // 用户说的"聊天记录里有表情包时一划就卡帧闪烁"就是这条路径。
      ChatImage.clearDecodedCache();
      final bytes = Uint8List.fromList(List<int>.filled(128, 3));
      final image = ChatImage(
        ref: 'data:image/png;base64,${base64Encode(bytes)}',
      );
      final first = image.inlineBytes;
      final second = image.inlineBytes;
      expect(first, isNotNull);
      expect(
        identical(first, second),
        isTrue,
        reason: '每帧重新解码会让 Image 认成另一张图,滚动时就是卡帧 + 闪',
      );
    });

    test('缓存条数封顶', () async {
      ChatImage.clearDecodedCache();
      for (var i = 0; i < ChatImage.decodedLimit + 10; i++) {
        // 每条的字节能解出不同的引用串,保证是各自独立的缓存项。
        final bytes = Uint8List.fromList(List<int>.filled(8, i % 251));
        ChatImage(ref: 'data:image/png;base64,${base64Encode(bytes)}')
            .inlineBytes;
      }
      expect(
        ChatImage.decodedCacheLength,
        lessThanOrEqualTo(ChatImage.decodedLimit),
      );
    });
  });
}
