import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/data/chat_attachment.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/main.dart';
import 'package:yiji/state/app_state.dart';
import 'package:yiji/ui/chat_screen.dart';

import 'support/fake_store.dart';

/// 聊天页的**交互回归**。
///
/// 用户的原话:"聊天功能直接彻底烂完了…连点切换聊天对话,现在竟然都切换不了,
/// 直接跳转'任务页'"。这一组把四条症状各锁一条,先变红再修。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStore store;
  late AppState state;

  setUp(() {
    store = FakeStore();
    presetChunks = null;
    presetReply = null;
    replyDelay = null;
    SharedPreferences.setMockInitialValues({
      'ai_api_key': 'sk-test',
      'ai_model': 'deepseek-flash',
    });
    // 表情包面板会去读图库;widget 测试里 rootBundle 读不出索引,
    // 面板就会一直转圈,`pumpAndSettle` 永远不收敛。喂一份进去。
    MemeLibrary.primeForTest(
      MemeLibrary.fromIndex(const [
        Meme(
          file: 'happy/x.webp',
          tag: 'happy',
          caption: '摸着圆滚滚肚子,笑眯眯喊吃饱饱',
          keywords: '开心 吃饱',
        ),
      ]),
    );
  });

  Future<void> pumpApp(WidgetTester tester) async {
    state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: _FakeAi()),
    );
    await tester.pumpWidget(YijiApp(state: state, enableSplash: false));
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('切换对话:留在聊天页,不跳到任务页', (tester) async {
    // 根因(已定位):关闭侧边栏走的是 `Navigator.maybePop()`,
    // 而 HomeShell 上那层 PopScope 把这个 pop 当成了"返回键",
    // 于是 setState(_index = 0) —— 用户看到的就是"点对话跳到任务页"。
    await store.createConversation(title: '第一个对话');
    await store.createConversation(title: '第二个对话');
    await pumpApp(tester);
    await openTab(tester, '聊天');

    // 打开侧边栏。
    await tester.tap(find.byTooltip('全部对话'));
    await tester.pumpAndSettle();
    expect(find.text('第一个对话'), findsWidgets, reason: '侧边栏应当能打开');

    // 点一条对话切换。
    await tester.tap(find.text('第二个对话').first);
    await tester.pumpAndSettle();

    // 必须留在聊天页——编辑器还在、底部导航仍选中「聊天」。
    expect(
      find.widgetWithText(TextField, '说点什么'),
      findsOneWidget,
      reason: '切换对话后应当还在聊天页',
    );
  });

  testWidgets('发消息后消息进列表,而且列表不卡死', (tester) async {
    await pumpApp(tester);
    await openTab(tester, '聊天');

    await tester.enterText(find.widgetWithText(TextField, '说点什么'), '在吗');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(find.text('在吗'), findsOneWidget);
    // 列表没卡死:还能继续操作(再发一条)。
    await tester.enterText(find.widgetWithText(TextField, '说点什么'), '再来');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.text('再来'), findsOneWidget);
  });

  testWidgets('点思考过程:展开收起,不改动整页布局', (tester) async {
    // 用户说"点思考过程直接乱串屏幕"。这里盯的是:点开之后
    // **其他消息的位置不动**——动了就说明面板撑破了布局。
    presetChunks = [
      const AiChunk.reasoning('先看他这周的记录,再决定怎么回。'),
      const AiChunk.content('这周你码了 5k。'),
    ];
    await pumpApp(tester);
    await openTab(tester, '聊天');

    await tester.enterText(find.widgetWithText(TextField, '说点什么'), '最近怎么样');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    // 记下正文气泡的位置。
    final before = tester.getTopLeft(find.text('这周你码了 5k。'));

    await tester.tap(find.textContaining(ReasoningPanel.doneLabel));
    await tester.pumpAndSettle();
    expect(find.text('先看他这周的记录,再决定怎么回。'), findsOneWidget);

    // 思考块在正文**上方**展开,正文应当往下移动,而不是跑到别处。
    final after = tester.getTopLeft(find.text('这周你码了 5k。'));
    expect(
      after.dx,
      before.dx,
      reason: '展开思考不该让正文横向移位(用户看到的"乱串")',
    );
    expect(
      after.dy,
      greaterThanOrEqualTo(before.dy),
      reason: '思考块在正文上方,正文只该往下走',
    );

    // 收起之后回到原位。
    await tester.tap(find.textContaining(ReasoningPanel.doneLabel));
    await tester.pumpAndSettle();
    final restored = tester.getTopLeft(find.text('这周你码了 5k。'));
    expect(restored.dy, closeTo(before.dy, 1.0));
  });

  testWidgets('窄屏上思考过程那一栏不溢出', (tester) async {
    // 参考样式那一行字会比较长(「已深度思考,用时 2 分 52 秒」),
    // 加上左边的鲸鱼和右边的箭头,窄屏上很容易挤爆 Row。
    // Flutter 会把 overflow 当成测试失败报出来,所以这条只要跑通就是在守线。
    tester.view.physicalSize = const Size(1080, 1600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReasoningPanel(
            text: '先看他这周的记录,再决定怎么回。',
            dark: false,
            elapsed: const Duration(minutes: 2, seconds: 52),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining(ReasoningPanel.doneLabel),
      findsOneWidget,
      reason: '标题应当在窄屏上也能显示出来(可以省略,但不能溢出)',
    );
  });

  testWidgets('用户发的图会真的发给模型(多模态)', (tester) async {
    // 用户说"ai 又看不到我的表情包了"。这条盯的是请求体里到底有没有图片。
    final ai = _FakeAi();
    state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: ai),
    );
    await tester.pumpWidget(YijiApp(state: state, enableSplash: false));
    await tester.pumpAndSettle();
    await openTab(tester, '聊天');

    // 造一张内置表情包附件(和点面板选一张等价:只有 asset 引用、没有字节)。
    await for (final _ in state.sendChat(
      '哈哈',
      attachments: [
        ChatAttachment.meme(
          assetPath: 'memes/happy/1785559277205.webp',
          caption: '摸着圆滚滚肚子,笑眯眯喊吃饱饱',
          tag: 'happy',
        ),
      ],
    )) {
      // 消费流。
    }
    await state.commitAssistantMessage();

    final messages = ai.lastBody!['messages'] as List;
    // 取出所有多模态图片部分的 url。
    final urls = <String>[
      for (final m in messages)
        if (m is Map && m['content'] is List)
          for (final part in (m['content'] as List))
            if (part is Map && part['type'] == 'image_url')
              '${(part['image_url'] as Map?)?['url']}',
    ];
    expect(
      urls,
      isNotEmpty,
      reason: '用户发的表情包必须以多模态图片的形式发给模型,而不是只有一行路径文字',
    );
    expect(urls.first, startsWith('data:image/'));
    expect(urls.first.length, greaterThan(200), reason: '应当真的带上图的字节');
  });

  testWidgets('发完之后列表还能往上翻,不会被拽回底部', (tester) async {
    // **这是"聊天栏锁死在最底层"的回归测试。**
    // 上一轮我让程序化的 jumpTo 也能重置"跟底"状态,形成死循环:
    // 贴底 → 位置在底部 → 状态变回该跟底 → 再贴底。用户怎么划都被拽回去。全部塞进**同一个**对话,
    // 而且要在 openTab 之前:app 打开时会挑一个有效会话。
    final conversationId = await store.createConversation(title: '长对话');
    for (var i = 0; i < 40; i++) {
      await store.addMessage(conversationId, 'user', '第 $i 条消息');
    }
    await pumpApp(tester);
    await openTab(tester, '聊天');
    await tester.pumpAndSettle();

    // 先确认列表确实有得滚(否则这条测试什么也证明不了)。
    final list = find.byType(Scrollable).first;
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(
      controller.position.maxScrollExtent,
      greaterThan(100),
      reason: '测试前提:列表要足够长,能滚',
    );

    // 发一条,触发"贴底"那条逻辑。
    await tester.enterText(find.widgetWithText(TextField, '说点什么'), '再来一条');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final atBottom = controller.position.pixels;

    // 往上滑一段:**按住不放**,同时让内容继续变长(流式输出就是这样的)。
    // 只滑一下是测不出来的——必须让"内容还在长"这个条件成立,
    // 因为那个死循环正是靠"变长 → 贴底"这一步把用户拽回去的。
    final gesture = await tester.startGesture(
      tester.getCenter(list),
    );
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();

    // 手指还按着的时候,来了一条新消息(等价于流式分片到达)。
    for (var i = 0; i < 5; i++) {
      await store.addMessage(conversationId, 'assistant', '流式 $i');
      await tester.pump();
    }

    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      controller.position.pixels,
      lessThan(atBottom - 50),
      reason: '往上翻的时候内容还在长,位置不该被拽回底部'
          '(在底部时 $atBottom,现在 ${controller.position.pixels})',
    );
  });

  testWidgets('弹层点空白处能关掉,而且不会跳到别的页签', (tester) async {
    // 同一个根因的连带伤害:根路由上的 PopScope 把所有"程序化 pop"都当成
    // 返回键,于是弹层点空白处关不掉、反而先跳回任务页。
    // 这一条盯的就是那个通道是干净的。
    await pumpApp(tester);
    await openTab(tester, '聊天');

    await tester.tap(find.byTooltip('发表情包'));
    await tester.pumpAndSettle();
    expect(find.text('表情包'), findsWidgets, reason: '表情包面板应当能打开');

    // 点面板外的区域关掉它。
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();

    // 关掉了,而且人还在聊天页。
    expect(
      find.widgetWithText(TextField, '说点什么'),
      findsOneWidget,
      reason: '关掉弹层后应当还在聊天页',
    );
  });
}

/// 记下最后一次请求体的假客户端。
class _FakeAi extends http.BaseClient {
  Map<String, Object?>? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      lastBody =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
    }
    // 按 presetChunks 逐段吐,支持"先思考再正文"这种真实顺序。
    final payloads = presetChunks ?? [AiChunk.content('好的。')];
    final body = '${payloads.map(
      (chunk) => 'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  if (chunk.isReasoning) 'reasoning_content': chunk.text,
                  if (!chunk.isReasoning) 'content': chunk.text,
                },
              }
            ],
          })}',
    ).join('\n\n')}\n\ndata: [DONE]\n\n';
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(body)]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

/// 这几个是 app_test 里的跨用例全局量,这里留同名占位便于对照阅读。
List<AiChunk>? presetChunks;
String? presetReply;
Duration? replyDelay;
