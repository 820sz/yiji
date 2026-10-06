import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/main.dart';
import 'package:yiji/state/app_state.dart';
import 'package:yiji/ui/chat_screen.dart';

import 'support/fake_store.dart';

/// 流式输出在**界面上**必须真的长出来。
///
/// 用户报过"闪烁没了,但流式输出也没了":去掉每次分片 setState 整页之后,
/// 列表里那个"正在生成"的槽位就再也没插入过——正文要等整段收完才冒出来。
/// 状态层的行为由 stream_state_test.dart 盯着,这里盯渲染结果。
void main() {
  late FakeStore store;
  late _ChunkedAi ai;

  Future<AppState> pumpApp(WidgetTester tester, {bool autoRelease = true}) async {
    SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
    ai = _ChunkedAi(autoRelease: autoRelease);
    final state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: ai),
    );
    await tester.pumpWidget(YijiApp(state: state, enableSplash: false));
    await tester.pumpAndSettle();
    return state;
  }

  setUp(() => store = FakeStore());

  testWidgets('分片到达时气泡逐段变长,收完落库成正式消息', (tester) async {
    final state = await pumpApp(tester);
    await tester.tap(find.text('聊天').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '说点什么'), '讲个长点的故事');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    // 流式槽位必须出现在列表里,而且内容就是收全的那段正文。
    expect(
      find.textContaining('从前有座山'),
      findsWidgets,
      reason: '流式正文应当显示在气泡里,而不是等落库才出现',
    );
    // 思考过程也要在(它是单独一块)。文案按参考样式改成了「已深度思考」。
    expect(find.textContaining(ReasoningPanel.doneLabel), findsOneWidget);
    // 完成后是正式消息,不再是"正在生成"。
    expect(state.streaming, isFalse);
    expect(state.chat.last.content, contains('从前有座山'));
  });

  testWidgets('生成过程中不是转圈等待,而是逐字出现', (tester) async {
    // 这条区分"流式"和"转圈":假客户端**等测试放行**才吐下一段,
    // 于是"第一段已经显示、第二段还没到"成为一个确定的瞬间,
    // 而不是赌某次 pump 恰好落在中间。
    await pumpApp(tester, autoRelease: false);
    await tester.tap(find.text('聊天').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '说点什么'), '讲个故事');
    await tester.tap(find.byIcon(Icons.arrow_upward));

    // 放行到第一段正文:此刻应当只看到"从前"。
    // 用固定次数的 pump 而不是 pumpAndSettle:流还挂在"等放行"上,
    // pumpAndSettle 会一直等它结束,直接超时。
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('从前'),
      findsWidgets,
      reason: '第一段到了就该显示,而不是等整段收完',
    );
    expect(
      find.textContaining('有座山'),
      findsNothing,
      reason: '第二段还没放行,不该提前出现',
    );

    // 放行第二段:同一块气泡接着往下长。
    ai.release();
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('从前有座山'),
      findsWidgets,
      reason: '第二段到了应该接在同一个气泡里继续长',
    );

    // 剩下的全放行。这里不用 pumpAndSettle:门控流在测试里不容易
    // 收敛到"完全静止",固定 pump 几次足够让落库发生。
    ai.releaseAll();
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(find.textContaining('从前有座山山里'), findsWidgets);
  });
}

/// 分帧吐字、并且**由测试逐帧放行**的假客户端。
///
/// 用"等放行"而不是定时器:定时器在 flutter_test 的假时钟里不好对齐,
/// 观察到的是哪一帧全凭运气。放行式让"第一段已经显示、第二段还没到"
/// 这个瞬间成为确定的事实。
class _ChunkedAi extends http.BaseClient {
  _ChunkedAi({this.autoRelease = true});

  /// true:不等放行,一次把全部内容吐完(给不关心中间态的用例)。
  /// false:由测试逐帧放行,好观察确定的中间态。
  final bool autoRelease;

  static const _pieces = ['从前', '有座山', '山里', '有座庙'];

  final _gate = StreamController<void>();
  late final Stream<List<int>> _frames = _build();

  /// 放行下一段正文。
  ///
  /// 用"每次换一个 Completer"而不是 `_gate.stream.first`:后者会把
  /// **单订阅流**消费掉,第二次 await 直接抛错,表现为后面的分片再也发不出来。
  Completer<void>? _pending;

  void release() {
    final pending = _pending;
    _pending = null;
    pending?.complete();
  }

  /// 放行全部剩余内容,让流正常收尾。
  void releaseAll() {
    for (var i = 0; i < _pieces.length + 4; i++) {
      release();
    }
    unawaited(_gate.close());
  }

  Stream<List<int>> _build() async* {
    yield _sse({'reasoning_content': '他好像想听故事。'});
    yield _sse({'content': _pieces.first});
    for (final piece in _pieces.skip(1)) {
      if (!autoRelease) {
        final wait = Completer<void>();
        _pending = wait;
        await wait.future;
      }
      yield _sse({'content': piece});
    }
    yield utf8.encode('data: [DONE]\n\n');
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      _frames,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  /// 造一帧 SSE。传进来的**就是** delta 本身,不要再套一层 `delta`——
  /// 套成 `choices[0].delta.delta` 的话内容解析不出来,一片都收不到,
  /// 看上去像"流坏了"(踩过一次)。
  static List<int> _sse(Map<String, Object?> delta) => utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {'delta': delta},
          ],
        })}\n\n',
      );
}
