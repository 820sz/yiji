import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yiji/ai/search_service.dart';

/// 联网搜索的解析与上下文拼装。
///
/// 响应结构不是猜的:是拿真实 key 打了一次 `anthropic/v1/messages` 抓回来存成
/// 夹具的(见 build/search_response.json)。字段名一个都不能写错——
/// 写错了整次搜索就白花,用户看到的是"搜了但什么都没说"。
void main() {
  /// 一份最小但结构完整的搜索响应,字段与实测一致。
  Map<String, Object?> responseWith({
    List<Map<String, Object?>> sources = const [],
    String text = '',
  }) =>
      {
        'id': 'msg_1',
        'type': 'message',
        'role': 'assistant',
        'content': [
          // 思考块:解析时必须跳过。
          {'type': 'thinking', 'thinking': '用户想搜点什么。', 'signature': 'sig'},
          {
            'type': 'server_tool_use',
            'id': 'call_1',
            'name': 'web_search',
            'input': {'query': '今天的科技新闻'},
            'caller': {'type': 'direct'},
          },
          {
            'type': 'web_search_tool_result',
            'tool_use_id': 'call_1',
            'content': sources,
          },
          if (text.isNotEmpty) {'type': 'text', 'text': text},
        ],
      };

  Map<String, Object?> source({
    required String url,
    required String title,
    String? age,
  }) =>
      {
        'type': 'web_search_result',
        'title': title,
        'url': url,
        'encrypted_content': 'xxx',
        'page_age': age,
      };

  group('解析搜索响应', () {
    test('按块类型取来源,不去正文里抠 URL', () {
      final outcome = SearchService.parseSearchResponse(
        responseWith(
          sources: [
            source(
              url: 'https://example.com/a',
              title: '第一条',
              age: '2026-05-18',
            ),
            source(url: 'https://example.com/b', title: '第二条'),
          ],
          text: '整理稿',
        ),
        query: '今天的科技新闻',
      );

      expect(outcome.sources, hasLength(2));
      expect(outcome.sources.first.title, '第一条');
      expect(outcome.sources.first.url, 'https://example.com/a');
      expect(outcome.sources.first.age, '2026-05-18');
      expect(outcome.sources.last.age, isNull);
      expect(outcome.summary, '整理稿');
      expect(outcome.query, '今天的科技新闻');
    });

    test('重复 URL 只留一条', () {
      // 多轮搜索会把同一条结果带回来好几次,不去重的话上下文里全是重复项。
      final outcome = SearchService.parseSearchResponse(
        responseWith(
          sources: [
            source(url: 'https://example.com/a', title: '第一次'),
            source(url: 'https://example.com/a', title: '第二次'),
          ],
        ),
        query: 'q',
      );
      expect(outcome.sources, hasLength(1));
      expect(outcome.sources.single.title, '第一次');
    });

    test('没有 url 的条目丢掉', () {
      final outcome = SearchService.parseSearchResponse(
        responseWith(
          sources: [
            {'type': 'web_search_result', 'title': '没有链接'},
            source(url: 'https://example.com/a', title: '有链接'),
          ],
        ),
        query: 'q',
      );
      expect(outcome.sources, hasLength(1));
    });

    test('只有标题没有正文时标题兜底成 url', () {
      final outcome = SearchService.parseSearchResponse(
        responseWith(
          sources: [
            {'type': 'web_search_result', 'url': 'https://example.com/a'},
          ],
        ),
        query: 'q',
      );
      expect(outcome.sources.single.title, 'https://example.com/a');
    });

    test('thinking 块不会混进整理稿', () {
      final outcome = SearchService.parseSearchResponse(
        responseWith(text: '这是整理稿'),
        query: 'q',
      );
      expect(outcome.summary, '这是整理稿');
      expect(outcome.summary.contains('用户想搜点什么'), isFalse);
    });

    test('结构不对时给空结果,而不是抛异常', () {
      final outcome = SearchService.parseSearchResponse(
        {'content': 'not a list'},
        query: 'q',
      );
      expect(outcome.isEmpty, isTrue);
    });
  });

  group('拼进聊天上下文', () {
    test('来源和整理稿都给到,不等于只给链接', () {
      // 只给 URL 的话模型读不到网页,收到一堆链接只会回"你可以看看这些"。
      final outcome = SearchOutcome(
        query: '今天的科技新闻',
        sources: const [
          SearchSource(
            title: '某新闻',
            url: 'https://example.com/a',
            age: '2026-05-18',
          ),
        ],
        summary: '今天发布了某样东西。',
      );
      final text = SearchService.formatForContext(outcome);

      expect(text, contains('今天的科技新闻'));
      expect(text, contains('https://example.com/a'));
      expect(text, contains('今天发布了某样东西。'));
      // 要明确要求它别拿旧记忆混充搜索结果。
      expect(text, contains('不要拿记忆里的东西混进去'));
    });

    test('整理稿超长会截断,不让长对话迅速膨胀', () {
      final outcome = SearchOutcome(
        query: 'q',
        sources: const [],
        summary: '字' * 5000,
      );
      final text = SearchService.formatForContext(outcome, maxSummary: 100);
      // 100 字的正文 + 说明文字,总量要明显小于原文。
      expect(text.length, lessThan(1000));
      expect(text, contains('…'));
    });

    test('来源最多给 8 条', () {
      final outcome = SearchOutcome(
        query: 'q',
        sources: [
          for (var i = 0; i < 20; i++)
            SearchSource(title: '第$i条', url: 'https://example.com/$i'),
        ],
        summary: '',
      );
      final text = SearchService.formatForContext(outcome);
      expect(text, contains('第7条'));
      expect(text.contains('第8条'), isFalse);
    });
  });

  group('失败提示', () {
    test('明确说"没搜到",而不是静默退回', () {
      // 用户选的是"要明确告诉他"。静默退回他会分不清这个回答
      // 来自网络还是模型的旧知识。
      final notice = SearchService.failureNotice(
        const SearchException('API key 不对或没有联网搜索权限'),
      );
      expect(notice, contains('没搜到'));
      expect(notice, contains('模型自己的知识'));
      expect(notice, contains('API key'));
    });
  });

  group('请求构造', () {
    test('用 x-api-key 和 anthropic-version,不是 Bearer', () async {
      // 这个端点的鉴权方式和聊天那边不一样;写成 Bearer 会 401。
      final client = _CapturingClient();
      final service = SearchService(httpClient: client);
      addTearDown(service.dispose);

      await service.search(apiKey: 'sk-test', topic: '今天的新闻');

      expect(client.headers['x-api-key'], 'sk-test');
      expect(client.headers['anthropic-version'], '2023-06-01');
      expect(client.headers.containsKey('Authorization'), isFalse);
    });

    test('打到 /anthropic/v1/messages,并带上原生搜索工具', () async {
      final client = _CapturingClient();
      final service = SearchService(httpClient: client);
      addTearDown(service.dispose);

      await service.search(apiKey: 'sk-test', topic: '今天的新闻');

      expect(
        client.url.toString(),
        'https://api.deepseek.com/anthropic/v1/messages',
      );
      final tools = client.body['tools'];
      expect(tools, isA<List>());
      final tool = (tools as List).single as Map;
      expect(tool['type'], 'web_search_20250305');
      expect(tool['name'], 'web_search');
      // 搜索用的模型与聊天不同,不能混。
      expect(client.body['model'], 'deepseek-v4-flash');
    });

    test('没填 key 时在发请求之前就报错', () async {
      final client = _CapturingClient();
      final service = SearchService(httpClient: client);
      addTearDown(service.dispose);

      await expectLater(
        service.search(apiKey: '   ', topic: 'q'),
        throwsA(isA<SearchException>()),
      );
      expect(client.calls, 0, reason: '不该发出请求');
    });

    test('401 翻译成"key 不对或没有搜索权限"', () async {
      final service = SearchService(
        httpClient: _CapturingClient(status: 401, rawBody: '{}'),
      );
      addTearDown(service.dispose);

      await expectLater(
        service.search(apiKey: 'sk-test', topic: 'q'),
        throwsA(
          isA<SearchException>().having(
            (e) => e.message,
            'message',
            contains('联网搜索权限'),
          ),
        ),
      );
    });
  });
}

/// 记下请求、按脚本回答的假客户端。
class _CapturingClient extends http.BaseClient {
  _CapturingClient({this.status = 200, this.rawBody});

  final int status;
  final String? rawBody;

  int calls = 0;
  Uri? url;
  Map<String, String> headers = {};
  Map<String, Object?> body = {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    url = request.url;
    headers = request.headers;
    if (request is http.Request) {
      body = jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
    }
    final payload = rawBody ??
        jsonEncode({
          'content': [
            {
              'type': 'web_search_tool_result',
              'content': [
                {
                  'type': 'web_search_result',
                  'title': '某新闻',
                  'url': 'https://example.com/a',
                },
              ],
            },
            {'type': 'text', 'text': '整理稿'},
          ],
        });
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(payload)]),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}
