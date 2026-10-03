import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 探针:**聊天用的模型到底能不能看图**。
///
/// 这决定表情包功能怎么做。如果能看图,正确做法是直接把图当多模态发过去,
/// 让模型自己看——而不是我之前那套"把图描述成文字喂给它"的绕路,
/// 用户已经明确骂过这个思路了(他说得对:AI 有识图能力,没必要绕)。
void main() {
  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  if (apiKey.trim().isEmpty) {
    test('跳过', () {}, skip: '没有 key');
    return;
  }

  // 一张"红圆里套蓝方块"的图:模型看得到就会说出来。
  final bytes = File('build/vision_probe.png').readAsBytesSync();
  final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';

  Future<void> probe(String model, {required bool asArray}) async {
    final content = asArray
        ? [
            {'type': 'text', 'text': '这张图里有什么形状和颜色?一句话答。'},
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            },
          ]
        : '这张图里有什么形状和颜色?一句话答。';

    final response = await http.post(
      Uri.parse('https://api.deepseek.com/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: utf8.encode(jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': content},
        ],
        'stream': false,
        'max_tokens': 200,
      })),
    );
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final short = text.length > 300 ? text.substring(0, 300) : text;
    // ignore: avoid_print
    print('=== [$model ${asArray ? "多模态" : "纯文本"}] ${response.statusCode} $short');
  }

  test('三类模型逐个试', () async {
    for (final model in ['deepseek-flash', 'deepseek-v4-flash', 'deepseek-vl']) {
      await probe(model, asArray: true);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
