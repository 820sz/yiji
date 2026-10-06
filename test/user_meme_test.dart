import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/meme_directive.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/state/app_state.dart';
import 'package:yiji/ui/meme_sheet.dart';

import 'support/fake_store.dart';

/// 用户自己加的那批表情包。
///
/// 用户报的三件事都在这条链上:
/// 1. **面板里显示不出来**(发出去倒是正常)——面板统一用 `Image.asset` 画,
///    而用户加的图不在安装包里,只有文件名是对的,画出来就是破图;
/// 2. **AI 调不出来**——提示词里那份候选清单是启动时准备好的另一份拷贝,
///    加了图不刷新,新图这一整个会话都进不了模型的候选;
/// 3. 清单每类只列 6 张,加到第七张之后前面几张就"消失"了。
///
/// 还有一条同源的:模型照着历史里的写法抄一行 `[我发的图: 描述]` 当"发图",
/// 那只是一行文字,用户什么图都收不到——解析层必须也认这种写法。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
    tempDir = Directory.systemTemp.createTempSync('yiji_user_meme');
    ChatImages.pinDirectoryForTest(tempDir);
  });

  tearDown(() {
    ChatImages.directoryOverride = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 一张最小的合法 PNG(1×1),当"用户加的那张图"。
  Uint8List tinyPng() => Uint8List.fromList(_png);

  group('模型抄回来的写法也要认', () {
    test('`[我发的图: 描述]` 算"要这张图",而且不显示给用户', () {
      // 这正是用户截图里的样子:AI 说了一段话,末尾补一行方括号,
      // 然后什么图都没有。
      final directive = stripMemeDirective(
        '行吧,再给你添一碗,吃完必须去睡。\n[我发的图:抱着胳膊撅嘴赌气,理直气壮说没吃饱]',
      );
      expect(directive.hasMeme, isTrue);
      expect(directive.emotion, '抱着胳膊撅嘴赌气,理直气壮说没吃饱');
      expect(
        directive.text.contains('[我发的图'),
        isFalse,
        reason: '这一行是给系统看的,不能出现在气泡里',
      );
      expect(directive.text, contains('再给你添一碗'));
    });

    test('`[他发的图: 描述]` 同样认', () {
      final directive = stripMemeDirective('嗯。\n[他发的图:被绑电竞椅电击流泪,死死不肯招供]');
      expect(directive.hasMeme, isTrue);
      expect(directive.emotion, '被绑电竞椅电击流泪,死死不肯招供');
    });

    test('正文里提到这几个字、没有冒号的,不算指令', () {
      final directive = stripMemeDirective('我发的图你看到了吗?');
      expect(directive.hasMeme, isFalse, reason: '没有冒号就只是正文');
      expect(directive.text, '我发的图你看到了吗?');
    });

    test('原来的 `[表情: ...]` 照旧', () {
      final directive = stripMemeDirective('好耶。\n[表情: 摸着圆滚滚肚子,笑眯眯喊吃饱饱]');
      expect(directive.hasMeme, isTrue);
      expect(directive.emotion, '摸着圆滚滚肚子,笑眯眯喊吃饱饱');
    });
  });

  group('候选清单', () {
    test('用户自己加的一张都不漏', () {
      final library = MemeLibrary.fromIndex([
        const Meme(
          file: 'happy/x.webp',
          tag: 'happy',
          caption: '内置的一张',
          keywords: '',
        ),
        for (var i = 0; i < 9; i++)
          Meme(
            file: 'user_$i.png',
            tag: 'mine',
            caption: '我加的$i',
            keywords: '',
            fromUser: true,
          ),
      ]);
      final catalog = library.catalogPrompt();
      for (var i = 0; i < 9; i++) {
        expect(
          catalog.contains('我加的$i'),
          isTrue,
          reason: '第 $i 张没进候选清单,用户会以为"加了却用不上"',
        );
      }
    });

    test('内置那批仍然按每类上限截', () {
      final library = MemeLibrary.fromIndex([
        for (var i = 0; i < 20; i++)
          Meme(
            file: 'happy/$i.webp',
            tag: 'happy',
            caption: '内置$i',
            keywords: '',
          ),
      ]);
      final catalog = library.catalogPrompt();
      expect(catalog.contains('内置5'), isTrue);
      expect(catalog.contains('内置6'), isFalse, reason: '内置按 perTag 截,免得清单吃掉上千 token');
    });
  });

  group('加完图之后', () {
    test('AI 那份清单立刻跟着变', () async {
      final state = AppState(
        store: FakeStore(),
        reports: ReportService(FakeStore()),
        settings: await SettingsStore.load(),
        aiClient: AiClient(httpClient: _NoopAi()),
      );
      await state.refreshMemeCatalog();
      expect(
        state.memeCatalog.contains('瘫成一团趴在鲸鱼抱枕上'),
        isTrue,
        reason: '先把内置那批读出来,后面才说明问题',
      );

      final added = await ChatImages.addUserMeme(
        bytes: tinyPng(),
        caption: '我加的图:抱着碗不肯撒手',
      );
      expect(added, isNotNull);
      // 关键:**不重启 app**,AI 的候选里就要有它。
      await state.refreshMemeCatalog();
      expect(
        state.memeCatalog.contains('我加的图:抱着碗不肯撒手'),
        isTrue,
        reason: '不刷新的话,用户加完让 AI 用,AI 会说"我库里没有这张"',
      );
    });

    test('挑图能挑到用户加的那张,而且拿得到字节', () async {
      await ChatImages.addUserMeme(bytes: tinyPng(), caption: '抱着碗不肯撒手');
      final library = await MemeLibrary.load();
      final picked = library.pickByCaption('抱着碗不肯撒手');
      expect(picked, isNotNull);
      expect(picked!.fromUser, isTrue);
      final bytes = await ChatImages.cachedMemeBytes(picked);
      expect(bytes, isNotNull);
      expect(bytes!.isNotEmpty, isTrue);
    });
  });

  testWidgets('表情包面板里,自己加的图能画出来', (tester) async {
    // 用户报的"自己添加的图在表情包库里无法正常显示":面板对每一张都走
    // `Image.asset`,而用户那张不在安装包里 → 一张破图图标。
    //
    // 图库必须在假时钟之外准备好:widget 测试里真实资源读取不会自己完成。
    late MemeLibrary library;
    await tester.runAsync(() async {
      await ChatImages.addUserMeme(bytes: tinyPng(), caption: '抱着碗不肯撒手');
      MemeLibrary.invalidate();
      library = await MemeLibrary.load();
    });
    MemeLibrary.primeForTest(library);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMemeSheet(context),
              child: const Text('打开表情包'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开表情包'));
    // **不能用 pumpAndSettle**:面板里有转圈指示,它永远排下一帧,
    // pumpAndSettle 会一直等到超时。按固定帧数推进就够。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 切到用户自己那一类。
    final chip = find.text('mine');
    await tester.ensureVisible(chip);
    await tester.pump();
    await tester.tap(chip);
    await tester.pump();

    // 缩略图要从私有目录读字节:给真实 I/O 一点回合。
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(find.byType(Image), findsWidgets, reason: '自己加的图应当真的画出来');
  });
}

/// 不真的发请求的假客户端:这一组只关心清单和图,不关心回答。
class _NoopAi extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body =
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '好的。'},
            }
          ],
        })}\n\ndata: [DONE]\n\n';
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(body)]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

/// 一张最小的合法 PNG(1×1)。
const _png = <int>[
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
