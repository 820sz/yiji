import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 记录一条**能力事实**:聊天用的模型是能看图的。
///
/// 这一条不需要"跑通"才有价值——它存在的意义是留下证据,防止以后再有人
/// (包括我)按"模型不能识图"去设计功能。上一轮就是没验证这个假设,
/// 做出了"把图描述成文字喂给模型"的绕路方案,用户直接骂回来了,而且是对的。
///
/// 它默认跳过,因为每次跑都要花钱;需要时手动开:
/// ```
/// $env:DEEPSEEK_API_KEY="sk-..."; $env:VISION_LIVE="1"
/// flutter test test/vision_probe_test.dart
/// ```
///
/// 探针用的图在 `build/vision_probe.png`(红圆里套蓝方块),
/// 跑之前先生成:
/// ```
/// python -c "from PIL import Image,ImageDraw; i=Image.new('RGB',(256,256),'white'); d=ImageDraw.Draw(i); d.ellipse([40,40,216,216],fill='red'); d.rectangle([100,100,156,156],fill='blue'); i.save('build/vision_probe.png')"
/// ```
void main() {
  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final enabled = Platform.environment['VISION_LIVE'] == '1';

  if (apiKey.trim().isEmpty || !enabled) {
    test('跳过识图能力验证', () {
      expect(enabled && apiKey.isNotEmpty, isFalse);
    }, skip: '需要同时设置 DEEPSEEK_API_KEY 与 VISION_LIVE=1');
    return;
  }

  test('聊天模型能看图', () async {
    final file = File('build/vision_probe.png');
    expect(file.existsSync(), isTrue, reason: '先按文件头的命令生成探针图');

    final dataUrl =
        'data:image/png;base64,${base64Encode(file.readAsBytesSync())}';

    final response = await http.post(
      Uri.parse('https://api.deepseek.com/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: utf8.encode(jsonEncode({
        'model': 'deepseek-flash',
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '这张图里有什么形状和颜色?一句话答。'},
              {
                'type': 'image_url',
                'image_url': {'url': dataUrl},
              },
            ],
          },
        ],
        'stream': false,
        'max_tokens': 200,
      })),
    );

    expect(response.statusCode, 200, reason: '多模态请求应当被接受');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    final choices = decoded['choices'] as List;
    final message = (choices.first as Map)['message'] as Map;
    final answer = '${message['content']}';
    // ignore: avoid_print
    print('=== 模型看图说 → $answer');

    // 不抠具体措辞(模型每次说法不同),只要求它说出了图里真实存在的元素。
    expect(
      answer.contains('红') || answer.contains('red'),
      isTrue,
      reason: '它应该看到那个红色圆形;实际回答:$answer',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
