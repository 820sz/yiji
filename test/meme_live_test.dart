import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/prompts.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/meme_directive.dart';

/// 真实接口验证:模型会不会**原样抄**清单里的一条描述。
///
/// 这一条是整个表情包功能能不能用的关键。老做法是让它自己编画面描述,
/// 编出来的句子在库里找不到对应的图,于是"发的图跟说的话配不上"或者
/// 干脆发不出来。新做法把可选清单摆给它、要求逐字抄,这里验证它真的照做。
///
/// 需要显式开启(要打真接口,还会花点时间):
/// ```
/// $env:DEEPSEEK_API_KEY="sk-..."; $env:MEME_LIVE="1"
/// flutter test test/meme_live_test.dart
/// ```
void main() {
  // **不能**调 TestWidgetsFlutterBinding.ensureInitialized():
  // 它会装上 HttpOverrides,让**所有**真实 HTTP 请求直接返回 400 且响应体为空。
  // 那看起来和"限流"一模一样——我为这个假象排查了很久,方向全错。
  //
  // 但读打包资源(rootBundle)又需要那个绑定。两边冲突的解法是**绕开 assets**:
  // 直接从磁盘读同一份 index.json,构造出图库。两边都要,就两条路各走各的。

  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final enabled = Platform.environment['MEME_LIVE'] == '1';

  if (apiKey.trim().isEmpty || !enabled) {
    test('跳过真实接口的表情包验证', () {
      expect(enabled && apiKey.isNotEmpty, isFalse);
    }, skip: '需要同时设置 DEEPSEEK_API_KEY 与 MEME_LIVE=1');
    return;
  }

  final config = AiConfig(apiKey: apiKey);

  /// 从磁盘读索引建库。
  ///
  /// 和 assets 里那份是同一个文件(仓库里 `assets/memes/index.json`),
  /// 只是绕开了 rootBundle,所以不需要 widget 绑定。
  MemeLibrary libraryFromDisk() {
    final file = File('assets/memes/index.json');
    expect(file.existsSync(), isTrue, reason: '找不到 ${file.path}');
    return MemeLibrary.fromIndex(
      MemeLibrary.parseIndex(jsonDecode(file.readAsStringSync())),
    );
  }

  Future<String> ask(String userText, String hint) async {
    final client = AiClient();
    final buffer = StringBuffer();
    await for (final chunk in client.streamChat(
      config: config,
      history: [
        AiMessage.system(chatSystemPrompt(memeHint: hint)),
        AiMessage.user(userText),
      ],
    )) {
      if (!chunk.isReasoning) buffer.write(chunk.text);
    }
    client.dispose();
    return buffer.toString();
  }

  test('庆祝的场景要抄一条清单里的原文,并且能定位到图', () async {
    final library = libraryFromDisk();
    expect(library.memes, isNotEmpty, reason: '图库没读出来,先查资源打包');
    final hint = memeHintPrompt(library.catalogPrompt());

    // 给三次机会:发不发表情包本来是概率行为,但只要发了就必须**抄得准**。
    String reply = '';
    MemeDirective? directive;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 4));
      reply = await ask('哈哈我今天终于把那一章写完了,爽!', hint);
      final parsed = stripMemeDirective(reply);
      if (parsed.hasMeme) {
        directive = parsed;
        break;
      }
    }

    // ignore: avoid_print
    print('DEBUG 回复 → ${reply.replaceAll('\n', ' ⏎ ')}');
    expect(directive, isNotNull, reason: '三次都没要表情包;最后一次回复:$reply');
    // ignore: avoid_print
    print('DEBUG 抄回来的描述 → 「${directive!.emotion}」');

    // 关键断言:抄回来的字必须能在库里精确定位到一张图。
    final picked = library.pickByCaption(directive.emotion);
    expect(picked, isNotNull, reason: '描述定位不到任何一张图');
    // ignore: avoid_print
    print('DEBUG 定位到 → ${picked!.file} / ${picked.caption}');

    // 而且要真的是**这一条**——允许标点差异,但不该落到别的图上。
    final exact = library.memes.where(
      (m) => m.caption.trim() == directive!.emotion.trim(),
    );
    // ignore: avoid_print
    print('DEBUG 是否逐字相同 → ${exact.isNotEmpty}');
    expect(
      exact.isNotEmpty || picked.caption.contains(directive.emotion) ||
          directive.emotion.contains(picked.caption),
      isTrue,
      reason: '抄回来的「${directive.emotion}」和定位到的「${picked.caption}」对不上',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('认真问事时不发图', () async {
    final library = libraryFromDisk();
    final hint = memeHintPrompt(library.catalogPrompt());
    final reply = await ask('帮我把这周的不足整理成三条,我要写进周报。', hint);
    final directive = stripMemeDirective(reply);
    // ignore: avoid_print
    print('DEBUG 认真问事 → hasMeme=${directive.hasMeme}');
    expect(directive.hasMeme, isFalse, reason: '该克制的时候别发表情包');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
