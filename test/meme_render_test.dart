import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/meme_directive.dart';
import 'package:yiji/ui/chat_screen.dart';

/// **端到端**验证"AI 发的表情包能不能显示出来"。
///
/// 用户的原话:"ai能读图,但是压根发不了图——这个问题从来都没解决好过!"
/// 之前那几条测试只覆盖到"挑到了哪张图",**没有一条真的把图画出来**,
/// 所以渲染这一环坏了多久都没人知道。这一条补的就是这一环:
/// 从库里真实的 caption 出发 → 走完指令解析/挑图/写进消息/解析引用,
/// 最后**真的把它渲染成一张图**,并断言没有出现"图不在了"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Meme> library;

  setUpAll(() async {
    // 用**打包进去的那份索引**,不是手写的假数据:
    // 假数据测不出路径写错、图缺失这类真问题。
    final raw = await rootBundle.loadString('assets/memes/index.json');
    library = MemeLibrary.parseIndex(jsonDecode(raw));
    // widget 测试里 rootBundle 取索引会卡住,所以把解析好的这份直接给图库用,
    // 让"回退到内置图"那条路有真实的库可查。
    MemeLibrary.primeForTest(MemeLibrary.fromIndex(library));
  });

  test('库里每条图都能在安装包里找到', () async {
    expect(library, isNotEmpty);
    for (final meme in library) {
      // 内置图的包内路径形如 assets/memes/happy/xxx.webp。
      await expectLater(
        rootBundle.load('assets/${meme.assetPath}'),
        completes,
        reason: '索引里的 ${meme.file} 在安装包里找不到',
      );
    }
  });

  testWidgets('AI 用真实 caption 挑图,能渲染成图而不是"图不在了"', (tester) async {
    final memes = MemeLibrary.fromIndex(library);
    // 挑几条真实 caption 逐个走一遍——不只测一条,免得恰好那条是好路径。
    final samples = [
      memes.memes.first,
      memes.memes[memes.memes.length ~/ 2],
      memes.memes.last,
    ];

    for (final sample in samples) {
      // 模型按提示词"原样抄一条"。
      final directive = stripMemeDirective(
        '好耶。\n[表情: ${sample.caption}]',
      );
      final picked = memes.pickByCaption(directive.emotion);
      expect(picked, isNotNull, reason: 'caption「${sample.caption}」应当能挑到图');

      // 落库的正文长这样。
      final content = '${directive.text}\n\n${memeLineFor(picked!.assetPath)}';
      // 渲染时再解析回引用。
      final parsed = ChatImage.parse(content.split('\n').last);
      expect(parsed, isNotNull, reason: '写进消息的那行应当能被解析回图片');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatBubbleProbe(text: content, isUser: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('图不在了'),
        findsNothing,
        reason: 'caption「${sample.caption}」渲染成了"图不在了"'
            '(引用是 ${parsed!.ref})',
      );
      expect(
        find.byType(Image),
        findsWidgets,
        reason: 'caption「${sample.caption}」没有渲染出任何图片',
      );
    }
  });

  test('带说明文字的图片行也能解析回引用', () {
    // 模型回看历史时给出的格式是 `![图] <引用> | <说明>`;
    // 说明必须被容忍,不能当成引用的一部分(否则加载必然失败)。
    final parsed = ChatImage.parse('![图] asset:memes/happy/x.webp | 摸着肚子笑');
    expect(parsed, isNotNull);
    expect(parsed!.ref, 'asset:memes/happy/x.webp');
  });

  test('模型自己缩写的路径被判为无效,而不是渲染成破图', () {
    // 它有时会写 `asset:memes/angry/...webp`——那不是真实路径。
    expect(ChatImage.parse('![图] asset:memes/angry/...webp'), isNull);
    expect(ChatImage.parse('![图] `asset:memes/happy/1.webp`'), isNotNull);
  });

  test('老消息里丢掉的图,能按文件名取回安装包内的同一张', () async {
    // 用户看到的"图不在了"就是这个:以前内置表情包会被抄一份到私有目录、
    // 消息里记那个文件名;那份副本被清掉之后,消息就永久坏了,
    // 而同一张图明明在安装包里。按文件名回查一次图库就能救回来。
    //
    // 这里不套 widget:在 fake-async 的测试时钟下,文件与资源的异步读取
    // 会被卡住,测出来的失败是测试环境的、不是功能的。
    final sample = library.first;
    final fileName = sample.file.split('/').last;
    // 指向一个空目录:磁盘上查不到,只能走回退。
    ChatImages.directoryOverride =
        Directory.systemTemp.createTempSync('yiji_meme_render');
    addTearDown(() => ChatImages.directoryOverride = null);

    expect(await ChatImages.file(fileName), isNull, reason: '前提:磁盘上没有它');

    final bytes = await ChatImages.bytesOf(ChatImage(ref: fileName));
    expect(
      bytes,
      isNotNull,
      reason: '「$fileName」应当能按文件名从安装包里取回同一张图',
    );
    // 而且必须是**同一张**:和直接按 asset 读出来的字节一致。
    expect(bytes, equals(await _assetBytes(sample.assetPath)));
  });
}

/// 直接读包内的一张图。
Future<Uint8List> _assetBytes(String assetPath) async {
  final data = await rootBundle.load('assets/$assetPath');
  return data.buffer.asUint8List();
}
