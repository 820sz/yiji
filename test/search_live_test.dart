import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/ai/search_service.dart';

/// 真实接口验证:联网搜索这条路真的通,而且搜到的东西真的进了聊天上下文。
///
/// 需要显式开启:
/// ```
/// $env:DEEPSEEK_API_KEY="sk-..."; $env:SEARCH_LIVE="1"
/// flutter test test/search_live_test.dart
/// ```
void main() {
  // **不能**调 TestWidgetsFlutterBinding.ensureInitialized():
  // 它会装上 HttpOverrides,让**所有**真实 HTTP 请求直接返回 400
  // (空响应体)。那看起来跟"限流"一模一样,排查时会往完全错误的方向走。
  // 需要 SharedPreferences 的那条用例自己装 mock 初始值即可。

  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final enabled = Platform.environment['SEARCH_LIVE'] == '1';

  if (apiKey.trim().isEmpty || !enabled) {
    test('跳过真实联网搜索验证', () {
      expect(enabled && apiKey.isNotEmpty, isFalse);
    }, skip: '需要同时设置 DEEPSEEK_API_KEY 与 SEARCH_LIVE=1');
    return;
  }

  test('搜得到东西,而且带来源', () async {
    final service = SearchService();
    addTearDown(service.dispose);

    final outcome = await service.search(
      apiKey: apiKey,
      topic: 'Flutter 最新版本发布说明',
    );

    // ignore: avoid_print
    print('=== 来源 ${outcome.sources.length} 条,整理稿 ${outcome.summary.length} 字');
    if (outcome.sources.isNotEmpty) {
      // ignore: avoid_print
      print('=== 第一条 ${outcome.sources.first.title} → ${outcome.sources.first.url}');
    }

    expect(outcome.isEmpty, isFalse, reason: '应该搜到东西');
    expect(outcome.sources, isNotEmpty, reason: '应该带结构化来源');
    expect(
      outcome.sources.first.url,
      startsWith('http'),
      reason: '来源必须是真实 URL',
    );
    expect(
      outcome.summary.trim(),
      isNotEmpty,
      reason: '整理稿是内容本体,空的就等于白搜',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('搜到的东西能拼成可用的上下文', () async {
    // 端到端只走到"拼上下文"这一步就够:再往后要走 AppState,而它会去问
    // package_info_plus 要版本号,那需要 widget 绑定——而绑定会把真实
    // HTTP 全变成 400。为了一个断言把整条链路拖进绑定不划算,所以这里
    // 直接验证**真实搜索结果 → 提示词文本**这一段。
    final service = SearchService();
    addTearDown(service.dispose);

    final outcome = await service.search(
      apiKey: apiKey,
      topic: 'Flutter 最新版本有哪些变化?',
    );
    expect(outcome.isEmpty, isFalse);

    final context = SearchService.formatForContext(outcome);
    // ignore: avoid_print
    print('=== 上下文 ${context.length} 字');

    // 真实来源的 URL 必须出现在上下文里。
    expect(context, contains(outcome.sources.first.url));
    // 整理稿的实质内容也要在(而不是只剩一堆链接)。
    expect(context, contains(outcome.summary.substring(0, 40)));
    // 并且明确要求它别拿旧记忆混充搜索结果。
    expect(context, contains('不要拿记忆里的东西混进去'));

    // 真实来源必须是可点的链接。
    for (final source in outcome.sources) {
      expect(source.url, startsWith('http'));
      expect(source.title.trim(), isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
