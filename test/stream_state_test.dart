import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/state/app_state.dart';

import 'support/fake_store.dart';

/// 状态层的流式行为(不涉及渲染,所以不装 widget 绑定)。
///
/// 单独一个文件、只用普通 `test`:上一版放在 testWidgets 文件里,
/// TestWidgetsFlutterBinding 会接管定时器,假客户端的分片一片都到不了,
/// 让人误以为"流坏了"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('分片逐个到达,并且第一个分片就让流式槽位可见', () async {
    SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
    final ai = _ChunkedAi();
    final state = AppState(
      store: FakeStore(),
      reports: ReportService(FakeStore()),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: ai),
    );
    await state.bootstrap();

    final received = <String>[];
    bool? slotVisibleAtFirstChunk;
    final tickCounts = <int>[];

    await for (final chunk in state.sendChat('讲个长点的故事')) {
      received.add(chunk.text);
      if (received.length == 1) {
        // 第一个分片到达时,"正在生成"这个开关必须是开的——列表靠它决定
        // 插不插入流式槽位。这是"闪烁没了但流式也没了"那个 bug 的判据。
        slotVisibleAtFirstChunk = state.streaming;
      }
      tickCounts.add(state.streamTick.value);
    }

    // ignore: avoid_print
    print('DEBUG 分片=$received 首片时可见=$slotVisibleAtFirstChunk tick=$tickCounts');

    expect(received.length, greaterThan(2), reason: '假客户端分 5 帧吐');
    expect(
      slotVisibleAtFirstChunk,
      isTrue,
      reason: '第一个分片到达时流式槽位就必须可见,否则正文一个字都显示不出来',
    );
    // 每次分片都要推进 tick,正在长的那块才会重绘。
    expect(tickCounts.toSet().length, received.length, reason: 'tick 应当逐个递增');
  });

  test('落库期间"正在生成"的那一份不能先消失', () async {
    // 用户报的"ai 说完之后回复吐出来时闪一下"。
    //
    // 以前 commitAssistantMessage 一进函数就把流式正文清掉,而挑图、读字节、
    // 写库全是异步的——从清掉到正式消息进列表之间那几百毫秒里,这条回答
    // **整个不在屏幕上**,然后才蹦出来。现在正文要留到落库完成再收。
    SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
    final state = AppState(
      store: FakeStore(),
      reports: ReportService(FakeStore()),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: _ChunkedAi()),
    );
    await state.bootstrap();

    await for (final _ in state.sendChat('讲个故事')) {}
    expect(state.streaming, isTrue, reason: '分片收完了,但还没落库');

    final committing = state.commitAssistantMessage();
    // 还没 await:这一刻它刚进函数,正文必须还在屏幕上。
    expect(
      state.streaming,
      isTrue,
      reason: '清得太早,这条回答会先消失几百毫秒再蹦出来(闪)',
    );
    expect(state.streamingAnswer, isNotEmpty);

    await committing;
    expect(state.streaming, isFalse, reason: '落库完了才收掉流式那一份');
    expect(state.chat.last.content, contains('从前'));
  });
}

/// 分帧吐字的假客户端。
class _ChunkedAi extends http.BaseClient {
  static const _pieces = ['从前', '有座山', '山里', '有座庙'];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final frames = <List<int>>[
      _sse({'reasoning_content': '他好像想听故事。'}),
      for (final piece in _pieces) _sse({'content': piece}),
      utf8.encode('data: [DONE]\n\n'),
    ];

    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(frames),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  /// 造一帧 SSE。注意传进来的**就是** delta 本身,不要再套一层 `delta`——
  /// 套成 `choices[0].delta.delta` 的话,客户端解析不到内容、一片都收不到,
  /// 看上去像"流坏了"(踩过一次)。
  static List<int> _sse(Map<String, Object?> delta) => utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {'delta': delta},
          ],
        })}\n\n',
      );
}
