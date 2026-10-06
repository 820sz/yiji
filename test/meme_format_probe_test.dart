import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/prompts.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/meme_directive.dart';

/// 探针:**模型会不会自己写一行 `![图] ...`**。
///
/// 用户报的「图不在了」里,占位框显示的引用是**一句描述**(caption),
/// 不是路径。按渲染代码反推,只有一种可能:模型在正文里自己写了一行
/// `![图] <描述>`,而那行会被渲染层当成图片引用来解析。
///
/// 这个探针不猜,直接打真接口,把模型的裸回复打出来数一数。
///
/// ```
/// $env:DEEPSEEK_API_KEY="sk-..."; $env:MEME_PROBE="1"
/// flutter test test/meme_format_probe_test.dart
/// ```
void main() {
  // 不能装 TestWidgetsFlutterBinding:它会让真实 HTTP 全部返回 400 空体。
  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final enabled = Platform.environment['MEME_PROBE'] == '1';

  if (apiKey.trim().isEmpty || !enabled) {
    test('跳过格式探针', () {
      expect(enabled && apiKey.isNotEmpty, isFalse);
    }, skip: '需要同时设置 DEEPSEEK_API_KEY 与 MEME_PROBE=1');
    return;
  }

  final config = AiConfig(apiKey: apiKey);
  final library = MemeLibrary.fromIndex(
    MemeLibrary.parseIndex(
      jsonDecode(File('assets/memes/index.json').readAsStringSync()),
    ),
  );
  final hint = memeHintPrompt(library.catalogPrompt());

  /// 打印用:截断,免得模型真抄了 base64 就把日志刷爆。
  String clip(String text, [int max = 400]) => text.length <= max
      ? text
      : '${text.substring(0, max)}…(共 ${text.length} 字符)';

  Future<String> ask(List<AiMessage> history) async {
    final client = AiClient();
    final buffer = StringBuffer();
    await for (final chunk in client.streamChat(
      config: config,
      history: history,
    )) {
      if (!chunk.isReasoning) buffer.write(chunk.text);
    }
    client.dispose();
    return buffer.toString();
  }

  /// 一条"用户发的表情包"消息长什么样。
  ///
  /// 和落库格式一致:正文在前,图片行在后(`sendChat` 里就是 `[正文, describe]`
  /// 用换行拼起来的)。
  String userMemeMessage(String text, Meme meme) =>
      '$text\n![图] asset:${meme.assetPath} | ${meme.caption}';

  test('场景一:用户刚发过表情包,模型会不会跟着写 ![图] 行', () async {
    final sample = library.memes.firstWhere((m) => m.tag == 'sad');
    var wroteImageLine = 0;
    var wroteDirective = 0;

    for (var i = 0; i < 4; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(seconds: 3));
      final reply = await ask([
        AiMessage.system(chatSystemPrompt(memeHint: hint)),
        AiMessage.user(
          userMemeMessage('哈哈哈哈这也太惨了 我今天啥也没干成,瘫了一天', sample),
        ),
      ]);
      final hasImageLine = reply.contains(ChatImage.marker);
      final parsed = stripMemeDirective(reply);
      if (hasImageLine) wroteImageLine++;
      if (parsed.hasMeme) wroteDirective++;
      // ignore: avoid_print
      print(
        'PROBE[$i] 写了![图]行=$hasImageLine 有[表情]指令=${parsed.hasMeme}\n'
        '  裸回复 → ${clip(reply).replaceAll('\n', ' ⏎ ')}',
      );
    }
    // ignore: avoid_print
    print('PROBE 汇总:4 次里自己写 ![图] 行 $wroteImageLine 次,'
        '走 [表情:] 指令 $wroteDirective 次');
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('场景二:历史里 AI 上一轮的图是内联 base64,会不会被照样模仿', () async {
    // 挑一张**磁盘上最小**的内置图当"上一轮 AI 发的那张",避免探针把上下文撑爆。
    Meme previous = library.memes.first;
    var smallestSize = 1 << 30;
    for (final meme in library.memes) {
      final file = File('assets/${meme.assetPath}');
      if (!file.existsSync()) continue;
      final size = file.lengthSync();
      if (size < smallestSize) {
        smallestSize = size;
        previous = meme;
      }
    }
    final bytes = File('assets/${previous.assetPath}').readAsBytesSync();
    final inline = '![图] data:image/webp;base64,${base64Encode(bytes)}';
    // ignore: avoid_print
    print('PROBE 上一轮 AI 消息里内联了 ${inline.length} 字符');

    final sample = library.memes.firstWhere((m) => m.tag == 'sad');
    for (var i = 0; i < 2; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(seconds: 3));
      final reply = await ask([
        AiMessage.system(chatSystemPrompt(memeHint: hint)),
        AiMessage.user(userMemeMessage('我今天啥也没干成,瘫了一天', sample)),
        AiMessage.assistant('确实惨。\n$inline'),
        AiMessage.user('你说我明天还能爬起来吗'),
      ]);
      // ignore: avoid_print
      print(
        'PROBE2[$i] 写了![图]行=${reply.contains(ChatImage.marker)} '
        '有[表情]指令=${stripMemeDirective(reply).hasMeme}\n'
        '  裸回复 → ${clip(reply).replaceAll('\n', ' ⏎ ')}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
