import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/meme_directive.dart';

import 'package:yiji/ui/chat_screen.dart';

/// 聊天里的图片、表情包,以及和它们的解析。
///
/// 这一组盯两件事:
/// 1. 用户发的图要**画出来**,不能把 `![图] 文件名` 当文字显示;
/// 2. 模型要表情包的那行指令不能被用户看到,但图要真的发出来。
void main() {
  // 读 asset 要走平台层,测试里需要先初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('消息正文的切分', () {
    test('纯文字还是一段文字', () {
      final parts = splitMessageParts('今天读了 30 页');
      expect(parts, hasLength(1));
      expect(parts.single.image, isNull);
      expect(parts.single.text.trim(), '今天读了 30 页');
    });

    test('图片行被识别成图片,而不是文字', () {
      final parts = splitMessageParts('这张图\n![图] asset:memes/happy/1.webp');
      expect(parts, hasLength(2));
      expect(parts.first.image, isNull);
      expect(parts.first.text.trim(), '这张图');
      expect(parts.last.image, isNotNull);
      expect(parts.last.image!.isAsset, isTrue);
      expect(parts.last.image!.assetPath, 'memes/happy/1.webp');
    });

    test('本地图片记的是文件名', () {
      final parts = splitMessageParts('![图] 1788274332831.png');
      expect(parts.single.image!.isAsset, isFalse);
      expect(parts.single.image!.fileName, '1788274332831.png');
    });

    test('没有图片行时不会凭空多出一段', () {
      expect(splitMessageParts(''), isEmpty);
      expect(splitMessageParts('\n\n'), isEmpty);
    });
  });

  group('模型要表情包的指令', () {
    test('整行被摘掉,情绪和描述都解析出来', () {
      final result = stripMemeDirective('好耶,那我也替你高兴。\n[表情: 开心 | 蹦起来比心]');
      expect(result.text, '好耶,那我也替你高兴。');
      expect(result.emotion, '开心');
      expect(result.query, '蹦起来比心');
      expect(result.hasMeme, isTrue);
    });

    test('只收到半个标记时不会把半截指令显示出来', () {
      // 流式是一段段到的,标记随时可能被切在中间。
      final result = stripMemeDirective('正文写完了\n[表情: 开');
      expect(result.text, '正文写完了');
      expect(result.hasMeme, isFalse);
    });

    test('没有收完的正文不会被误删', () {
      final result = stripMemeDirective('他问我要不要吃[饭');
      // `[` 后面不是"表情",所以整句照常显示。
      expect(result.text, contains('吃'));
    });

    test('只说情绪不给描述也能挑图', () {
      final result = stripMemeDirective('行吧。\n[表情: 无语]');
      expect(result.emotion, '无语');
      expect(result.query, '');
      expect(result.hasMeme, isTrue);
    });

    test('中英文冒号都认', () {
      expect(stripMemeDirective('嗯\n[表情:开心|笑]').emotion, '开心');
      expect(stripMemeDirective('嗯\n[表情: 开心|笑]').emotion, '开心');
    });
  });

  group('表情包图库', () {
    test('索引能从打包资源里读出来', () async {
      final library = await MemeLibrary.load();
      expect(
        library.memes,
        isNotEmpty,
        reason: 'assets/memes/index.json 没打进包,或者 pubspec 的 assets 漏了子目录',
      );
      // 图库要覆盖足够多的情绪,不然"接梗"经常挑不到贴题的。
      expect(library.tags.length, greaterThanOrEqualTo(5));
    });

    test('中文情绪词能对上图库标签', () async {
      final library = await MemeLibrary.load();
      expect(library.tagForEmotion('开心'), 'happy');
      expect(library.tagForEmotion('无语'), 'sad');
      expect(library.tagForEmotion('困'), 'sleep');
      // 认不出时返回 null,由调用方退回全库搜索。
      expect(library.tagForEmotion('某种不存在的情绪'), isNull);
    });

    test('同一句话挑到同一张图', () async {
      final library = await MemeLibrary.load();
      final first = library.pick(tag: 'happy', query: '开心', seed: 42);
      final second = library.pick(tag: 'happy', query: '开心', seed: 42);
      expect(first, isNotNull);
      expect(first!.file, second!.file);
    });

    test('按描述能挑到贴题的那张', () async {
      final library = await MemeLibrary.load();
      // 用图库里真实存在的关键词来找,验证检索这条路是通的。
      final sample = library.memes.firstWhere(
        (m) => m.keywords.trim().isNotEmpty,
        orElse: () => library.memes.first,
      );
      final keyword = sample.keywords.split(' ').first;
      final picked = library.pick(query: keyword);
      expect(picked, isNotNull);
      expect(
        picked!.haystack.any((h) => h.contains(keyword) || keyword.contains(h)),
        isTrue,
        reason: '按关键词「$keyword」应该挑到含它的那张',
      );
    });
  });

  group('图片在气泡里', () {
    testWidgets('图片消息画的是图,不是文件名', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatBubbleProbe(
              text: '看看这个\n![图] asset:memes/happy/1.webp',
            ),
          ),
        ),
      );
      await tester.pump();

      // 关键:不能再出现 `![图] ...` 这种原始文本。
      expect(find.textContaining('![图]'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('文件不在了也不会崩,给一个占位', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatBubbleProbe(text: '![图] 这个文件不存在.png'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
