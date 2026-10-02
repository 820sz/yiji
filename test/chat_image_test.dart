import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/ai/prompts.dart';
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

    test('给的清单里每一条都能原样定位回那张图', () async {
      // 这条路是"AI 发的图和它说的话配得上"的保证:提示词把清单摆给模型,
      // 模型抄一条回来,这里必须能精确找到那一张。清单里任何一条对不上,
      // 用户看到的就是随机一张图。
      final library = await MemeLibrary.load();
      expect(library.memes, isNotEmpty);

      for (final meme in library.memes) {
        final picked = library.pickByCaption(meme.caption);
        expect(
          picked?.file,
          meme.file,
          reason: '描述「${meme.caption}」应当定位回 ${meme.file}',
        );
      }
    });

    test('抄描述时少个标点也能对上', () async {
      // 模型抄写不保证标点完全一致,归一化之后要能容忍。
      final library = await MemeLibrary.load();
      final meme = library.memes.firstWhere((m) => m.caption.length > 6);
      final sloppy = '${meme.caption.replaceAll('，', '')}。';
      expect(library.pickByCaption(sloppy)?.file, meme.file);
    });

    test('清单不是空的,而且每个情绪都露了面', () async {
      // 清单为空的话提示词里就没有可选内容,模型只能自己编——那就退回老问题了。
      final library = await MemeLibrary.load();
      final catalog = library.catalogPrompt();
      expect(catalog.trim(), isNotEmpty);
      for (final tag in library.tags) {
        expect(catalog, contains('【$tag】'), reason: '清单里应当有「$tag」这一节');
      }
      // 每个情绪下至少列出一条真实描述。
      final firstOfTag = library.byTag(library.tags.first).first.caption;
      expect(catalog, contains(firstOfTag));
    });

    test('编出来的描述不会空手而归,至少给同情绪的', () async {
      // 模型偶尔还是会自己编(尤其老对话里的历史指令)。这种时候宁愿给一张
      // 同情绪的,也不要什么都不发——它已经跟用户说"这个给你"了。
      final library = await MemeLibrary.load();
      final picked = library.pickByCaption('完全没有的一句话啊哈哈', tag: 'happy');
      expect(picked, isNotNull);
    });

    test('提示词里摆的清单和挑图用的是同一份描述', () async {
      // 这条是"配得上图"的**闭环**:提示词给模型的清单必须来自同一批
      // caption,挑图也必须拿同一批 caption 去比对。任何一边换了措辞
      // (比如提示词里给编号、挑图时按关键词搜),闭环就断了,
      // 用户看到的就是随机一张图。
      final library = await MemeLibrary.load();
      final catalog = library.catalogPrompt();
      final hint = memeHintPrompt(catalog);

      // 提示词里确实带着清单。
      for (final meme in library.memes.take(3)) {
        expect(hint, contains(meme.caption), reason: '清单应当包含「${meme.caption}」');
      }
      // 清单里出现的每一条描述,都能定位回一张图。
      final lines = catalog
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('【'))
          .toList();
      expect(lines, isNotEmpty);
      for (final caption in lines) {
        expect(
          library.pickByCaption(caption),
          isNotNull,
          reason: '清单里这一行定位不到图:「$caption」',
        );
      }
    });

    test('图库为空时不给提示词,免得白占上下文', () {
      // 没有素材却允许它发,模型会写一行永远挑不到图的指令。
      expect(memeHintPrompt(''), isEmpty);
      expect(memeHintPrompt('   '), isEmpty);
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
