import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/meme_directive.dart';

/// **把库里每一条 caption 逐条跑完整链路**,找出哪几条过不去。
///
/// 用户的观察是关键:"用户发特定表情包,AI 回复必不出图;有些发得出、有些发不出"
/// ——"必"说明这是**确定性的**,不是渲染偶发失败。那么库里就该有某些条目
/// 在"模型抄描述 → 定位到图"这一步必然失败。
///
/// 这一条把 108 条**全部**过一遍,而不是抽查三条。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Meme> library;

  setUpAll(() async {
    final raw = await rootBundle.loadString('assets/memes/index.json');
    library = MemeLibrary.parseIndex(jsonDecode(raw));
  });

  test('108 条 caption 逐条走完"模型抄描述 → 定位到图"', () async {
    final memes = MemeLibrary.fromIndex(library);
    final failures = <String>[];

    for (final meme in library) {
      // 模型按提示词把描述原样抄回来。
      final directive = stripMemeDirective('好。\n[表情: ${meme.caption}]');
      if (directive.emotion.isEmpty) {
        failures.add('${meme.file}: 指令里没解析出描述');
        continue;
      }
      final picked = memes.pickByCaption(directive.emotion);
      if (picked == null) {
        failures.add('${meme.file}: 挑不到图(caption「${meme.caption}」)');
        continue;
      }
      // **必须挑回它自己**:挑到别的图就是"图跟话配不上"。
      if (picked.file != meme.file) {
        failures.add(
          '${meme.file}: 挑成了 ${picked.file}'
          '(caption「${meme.caption}」→「${picked.caption}」)',
        );
        continue;
      }
      // 写进消息后要能解析回同一个引用。
      final line = memeLineFor(picked.messageRef);
      final parsed = ChatImage.parse(line);
      if (parsed == null) {
        failures.add('${meme.file}: 写出的行解析不回来($line)');
        continue;
      }
      if (parsed.ref != picked.messageRef) {
        failures.add('${meme.file}: 引用变形(${parsed.ref} != ${picked.messageRef})');
        continue;
      }
      // 而且那份资源必须真的在包里。
      try {
        await rootBundle.load('assets/${picked.assetPath}');
      } catch (_) {
        failures.add('${meme.file}: 资源不在包里(${picked.assetPath})');
      }
    }

    expect(
      failures,
      isEmpty,
      reason: '有 ${failures.length} 条过不去:\n${failures.join('\n')}',
    );
  });

  test('库里每条 caption 都不含会破坏指令的行内标记', () {
    // 指令是 `[表情: <caption>]`。caption 里若出现 `]`、`|`、换行,
    // 解析就会截断或走错分支——而这些都是模型"原样抄"回来的确定输入。
    final problems = <String>[];
    for (final meme in library) {
      final caption = meme.caption;
      if (caption.contains(']')) problems.add('${meme.file}: caption 含 ]');
      if (caption.contains('[')) problems.add('${meme.file}: caption 含 [');
      if (caption.contains('|')) problems.add('${meme.file}: caption 含 |');
      if (caption.contains('\n')) problems.add('${meme.file}: caption 含换行');
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
