import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/prompts.dart';
import 'package:yiji/data/chat_images.dart';

/// 量一下"主动发表情包"的命中率,分几种说法各跑几次。
///
/// 为什么要量而不要拍脑袋:模型发不发表情包是**概率行为**,单次跑通过或失败
/// 都不能说明问题。这里跑出真实命中率,再决定产品上要不要兜底。
///
/// 需要显式开启才会跑——它要发 18 次请求、花一分钟,不该混进日常 `flutter test`:
/// ```
/// $env:DEEPSEEK_API_KEY="sk-..."; $env:MEME_RATE="1"
/// flutter test test/meme_rate_test.dart
/// ```
///
/// 注意接口有频率限制:请求之间必须留间隔,连着快发会收到**空的 400**
/// (看起来像"参数不支持",其实是限流)。
void main() {
  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final enabled = Platform.environment['MEME_RATE'] == '1';

  if (apiKey.trim().isEmpty || !enabled) {
    test('跳过表情包命中率测量', () {
      // 这不是"通过",是"这次没测"。
      expect(enabled && apiKey.isNotEmpty, isFalse);
    }, skip: '需要同时设置 DEEPSEEK_API_KEY 与 MEME_RATE=1');
    return;
  }

  final config = AiConfig(apiKey: apiKey);

  Future<String> ask(String system, String user) async {
    final client = AiClient();
    final buffer = StringBuffer();
    await for (final chunk in client.streamChat(
      config: config,
      history: [AiMessage.system(system), AiMessage.user(user)],
    )) {
      if (!chunk.isReasoning) buffer.write(chunk.text);
    }
    client.dispose();
    return buffer.toString();
  }

  test('命中率', () async {
    final library = await MemeLibrary.load();
    final system = chatSystemPrompt(
      memeHint: memeHintPrompt(library.tags.join(' / ')),
    );

    final cases = <String, String>{
      '明确要一张': '给我发个表情包乐一下',
      '庆祝': '哈哈我今天终于把那一章写完了,爽!',
      '吐槽累': '今天累死了,什么都不想干',
      '自嘲': '我又摸鱼了一整天,没救了哈哈',
      '难过': '感觉最近做什么都没劲',
      '认真问事': '帮我把这周的不足整理成三条,我要写进周报',
    };

    final tally = <String, String>{};
    for (final entry in cases.entries) {
      var hit = 0;
      const rounds = 3;
      for (var i = 0; i < rounds; i++) {
        // 间隔,避开限流。
        await Future<void>.delayed(const Duration(seconds: 4));
        final reply = await ask(system, entry.value);
        if (reply.contains('[表情')) hit++;
      }
      tally[entry.key] = '$hit/$rounds';
      // ignore: avoid_print
      print('=== 命中 ${entry.key}: $hit/$rounds');
    }
    // ignore: avoid_print
    print('=== 汇总 $tally');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
