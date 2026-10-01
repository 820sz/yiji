import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yiji/ai/ai_client.dart';

/// 一个按脚本回答的假 HTTP 客户端,用来验证流式解析和错误翻译。
///
/// 不联网:流式协议的正确性靠"把服务端可能吐出的字节序列喂进来"来验证,
/// 而不是靠真的调用一次 API。
class _FakeClient extends http.BaseClient {
  _FakeClient({required this.status, required this.body, this.chunks});

  final int status;
  final String body;

  /// 指定时按这些片段依次发送,用来模拟 TCP 分包。
  final List<List<int>>? chunks;

  http.BaseRequest? lastRequest;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    if (request is http.Request) {
      lastBody = utf8.decode(request.bodyBytes);
    }
    final bytes = chunks ?? [utf8.encode(body)];
    return http.StreamedResponse(
      Stream.fromIterable(bytes),
      status,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

/// 拼一段 SSE 文本。
String _sse(List<String> contents) {
  final lines = contents.map(
    (c) => 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': c},
            }
          ],
        })}',
  );
  return '${lines.join('\n\n')}\n\ndata: [DONE]\n\n';
}

const _config = AiConfig(apiKey: 'sk-test');

/// 只取最终回答那部分文本;思考过程不影响这些断言的意图。
List<String> _content(List<AiChunk> chunks) =>
    chunks.where((c) => !c.isReasoning).map((c) => c.text).toList();

void main() {
  group('请求构造', () {
    test('默认地址和模型按官方文档走', () {
      expect(AiConfig.defaultBaseUrl, 'https://api.deepseek.com');
      expect(AiConfig.defaultModel, 'deepseek-flash');
    });

    test('地址末尾多写的斜杠会被容忍', () async {
      final fake = _FakeClient(status: 200, body: _sse(['好']));
      final client = AiClient(httpClient: fake);

      await client
          .streamChat(
            config: _config.copyWith(baseUrl: 'https://api.deepseek.com///'),
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(fake.lastRequest!.url.toString(), 'https://api.deepseek.com/chat/completions');
    });

    test('带上 Bearer key 和 stream 标志', () async {
      final fake = _FakeClient(status: 200, body: _sse(['好']));
      final client = AiClient(httpClient: fake);

      await client
          .streamChat(
            config: _config,
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(fake.lastRequest!.headers['Authorization'], 'Bearer sk-test');
      final sent = jsonDecode(fake.lastBody!) as Map<String, Object?>;
      expect(sent['model'], 'deepseek-flash');
      expect(sent['stream'], isTrue);
      expect((sent['messages']! as List).length, 1);
    });

    test('思考模式开启时传 thinking 与 reasoning_effort', () async {
      final fake = _FakeClient(status: 200, body: _sse(['好']));
      final client = AiClient(httpClient: fake);

      await client
          .streamChat(
            config: _config.copyWith(thinking: ThinkingLevel.max),
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      final sent = jsonDecode(fake.lastBody!) as Map<String, Object?>;
      expect(sent['thinking'], {'type': 'enabled'});
      expect(sent['reasoning_effort'], 'max');
      // 思考模式下 temperature 不生效,不该发出去假装它有效。
      expect(sent.containsKey('temperature'), isFalse);
    });

    test('关掉思考时不传 reasoning_effort,并且带上 temperature', () async {
      final fake = _FakeClient(status: 200, body: _sse(['好']));
      final client = AiClient(httpClient: fake);

      await client
          .streamChat(
            config: _config.copyWith(thinking: ThinkingLevel.off),
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      final sent = jsonDecode(fake.lastBody!) as Map<String, Object?>;
      expect(sent['thinking'], {'type': 'disabled'});
      expect(sent.containsKey('reasoning_effort'), isFalse);
      expect(sent['temperature'], 0.7);
    });

    test('要求 JSON 时带上 response_format', () async {
      final fake = _FakeClient(status: 200, body: _sse(['{}']));
      final client = AiClient(httpClient: fake);

      await client
          .streamChat(
            config: _config,
            jsonMode: true,
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      final sent = jsonDecode(fake.lastBody!) as Map<String, Object?>;
      expect(sent['response_format'], {'type': 'json_object'});
    });

    test('思考强度档位映射到真实的 effort 值', () {
      expect(ThinkingLevel.off.effort, isNull);
      expect(ThinkingLevel.low.effort, 'low');
      expect(ThinkingLevel.high.effort, 'high');
      expect(ThinkingLevel.max.effort, 'max');
      expect(ThinkingLevel.off.enabled, isFalse);
      expect(ThinkingLevel.high.enabled, isTrue);
    });

    test('key 两端空格会被去掉', () async {
      final fake = _FakeClient(status: 200, body: _sse(['好']));
      final client = AiClient(httpClient: fake);

      await client
          .streamChat(
            config: _config.copyWith(apiKey: '  sk-padded  '),
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(fake.lastRequest!.headers['Authorization'], 'Bearer sk-padded');
    });
  });

  group('流式解析', () {
    test('按顺序吐出每个增量', () async {
      final fake = _FakeClient(status: 200, body: _sse(['进度', '方面', '：还行']));
      final client = AiClient(httpClient: fake);

      final chunks = await client
          .streamChat(
            config: _config,
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(_content(chunks), ['进度', '方面', '：还行']);
      expect(_content(chunks).join(), '进度方面：还行');
    });

    test('思考内容与最终回答被分流到不同的分片类型', () async {
      final body = 'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'reasoning_content': '先看他这周的数据'},
              }
            ],
          })}\n\n'
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '这周你码了 5k。'},
              }
            ],
          })}\n\n'
          'data: [DONE]\n\n';
      final fake = _FakeClient(status: 200, body: body);
      final client = AiClient(httpClient: fake);

      final chunks = await client
          .streamChat(
            config: _config,
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(chunks, hasLength(2));
      expect(chunks[0].isReasoning, isTrue);
      expect(chunks[0].text, '先看他这周的数据');
      expect(chunks[1].isReasoning, isFalse);
      expect(chunks[1].text, '这周你码了 5k。');
    });

    test('中文字符被 TCP 拆到两个分片也不会乱码', () async {
      final full = utf8.encode(_sse(['今天读了12页']));
      // 从第 60 个字节处硬切开,切点落在多字节汉字中间。
      final fake = _FakeClient(
        status: 200,
        body: '',
        chunks: [full.sublist(0, 60), full.sublist(60)],
      );
      final client = AiClient(httpClient: fake);

      final chunks = await client
          .streamChat(
            config: _config,
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(_content(chunks).join(), '今天读了12页');
    });

    test('忽略 [DONE] 和没有增量内容的分片', () async {
      final body = 'data: ${jsonEncode({
            'choices': [
              {'delta': {'content': '一'}},
            ],
          })}\n\n'
          'data: ${jsonEncode({
            'choices': [
              {'finish_reason': 'stop'},
            ],
          })}\n\n'
          'data: [DONE]\n\n';
      final fake = _FakeClient(status: 200, body: body);
      final client = AiClient(httpClient: fake);

      final chunks = await client
          .streamChat(
            config: _config,
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(_content(chunks), ['一']);
    });

    test('空回复不报错,只是没有任何增量', () async {
      final fake = _FakeClient(status: 200, body: 'data: [DONE]\n\n');
      final client = AiClient(httpClient: fake);

      final chunks = await client
          .streamChat(
            config: _config,
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(chunks, isEmpty);
    });

    test('流中间的数组或裸值不会把整条流打断', () async {
      // 有些网关会在流里插一条非对象的 data 帧(心跳、指标之类)。
      // 以前直接 `as Map<String, Object?>` 会抛 TypeError——那是 Error,
      // 接 FormatException 的 catch 拦不住,整次回答会以一句看不懂的话失败。
      final body = 'data: [{"heartbeat":true}]\n\n'
          'data: 42\n\n'
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '正文照常'},
              }
            ],
          })}\n\n'
          'data: [DONE]\n\n';
      final fake = _FakeClient(status: 200, body: body);
      final client = AiClient(httpClient: fake);

      final chunks = await client
          .streamChat(
            config: _config,
            history: [
              AiMessage.user('hi'),
            ],
          )
          .toList();

      expect(_content(chunks), ['正文照常']);
    });
  });

  group('错误处理', () {
    test('没填 key 时在发请求之前就报错', () async {
      final fake = _FakeClient(status: 200, body: '');
      final client = AiClient(httpClient: fake);

      expect(
        () => client
            .streamChat(
              config: _config.copyWith(apiKey: '  '),
              history: [
                AiMessage.user('hi'),
              ],
            )
            .toList(),
        throwsA(isA<AiException>()),
      );
      expect(fake.lastRequest, isNull);
    });

    test('401 翻译成 key 有问题', () async {
      final fake = _FakeClient(status: 401, body: '{"error":{"message":"bad key"}}');
      final client = AiClient(httpClient: fake);

      await expectLater(
        client
            .streamChat(
              config: _config,
              history: [
                AiMessage.user('hi'),
              ],
            )
            .toList(),
        throwsA(
          isA<AiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('API key 不对')),
        ),
      );
    });

    test('402 提示余额不足', () async {
      final fake = _FakeClient(status: 402, body: '{}');
      final client = AiClient(httpClient: fake);

      await expectLater(
        client
            .streamChat(
              config: _config,
              history: [
                AiMessage.user('hi'),
              ],
            )
            .toList(),
        throwsA(isA<AiException>().having((e) => e.message, 'message', contains('余额不足'))),
      );
    });

    test('非 JSON 的错误响应也能给出可读提示', () async {
      final fake = _FakeClient(status: 502, body: '<html>Bad Gateway</html>');
      final client = AiClient(httpClient: fake);

      await expectLater(
        client
            .streamChat(
              config: _config,
              history: [
                AiMessage.user('hi'),
              ],
            )
            .toList(),
        throwsA(
          isA<AiException>()
              .having((e) => e.statusCode, 'statusCode', 502)
              .having((e) => e.message, 'message', contains('服务器出问题了')),
        ),
      );
    });
  });
}
