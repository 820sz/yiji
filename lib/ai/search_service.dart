/// 联网搜索:用 DeepSeek 自己的原生搜索,不需要第三方服务。
///
/// 为什么走 `/anthropic/v1/messages` 而不是 `/chat/completions`:
/// DeepSeek 把联网能力**只**开放给了 Anthropic 兼容的那个端点,
/// 而日常聊天用的 chat/completions 没有搜索开关。域名仍然是
/// `api.deepseek.com`——是自己的服务器、自己的模型、自己的搜索,
/// 只是填表的方式借用了 Anthropic 那套字段名。
///
/// 代价要说清楚:**一次搜索就是一个完整的模型回合**。DeepSeek 没有提供
/// 单独的检索接口(没有 `GET /search` 这种东西),搜索是在服务端由模型
/// 发起工具调用完成的,所以延迟和 token 都比普通聊天高一档。这也是
/// 这个功能默认关闭的原因。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// 搜索接口错误。
class SearchException implements Exception {
  const SearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一条搜索结果。
class SearchSource {
  const SearchSource({required this.title, required this.url, this.age});

  final String title;
  final String url;

  /// 页面的发布时间;服务端没给就是 null。
  final String? age;

  static SearchSource? fromJson(Map<String, Object?> json) {
    final url = (json['url'] as String?)?.trim() ?? '';
    if (url.isEmpty) return null;
    final title = (json['title'] as String?)?.trim() ?? '';
    final age = json['page_age'];
    return SearchSource(
      title: title.isEmpty ? url : title,
      url: url,
      age: age is String && age.trim().isNotEmpty ? age.trim() : null,
    );
  }
}

/// 一次搜索的完整结果。
class SearchOutcome {
  const SearchOutcome({
    required this.query,
    required this.sources,
    required this.summary,
  });

  /// 实际发出去的查询词。
  final String query;

  /// 去重后的来源列表。
  final List<SearchSource> sources;

  /// 搜索那一轮模型给出的整理稿。
  ///
  /// **这一份才是内容本体**。只把 URL 交给聊天模型没有意义——它读不到网页,
  /// 拿到一堆链接只会回一句"你可以看看这些"。实测这一轮的回复本身就是
  /// 一份带来源的整理稿(哪一版、什么时候发布、有哪些变化),把它喂给
  /// 聊天模型才是真的让它"知道今天的事"。
  final String summary;

  bool get isEmpty => sources.isEmpty && summary.trim().isEmpty;
}

/// 调 DeepSeek 的原生联网搜索。
///
/// [apiKey] 就是聊天用的那把 key,不需要另配。
class SearchService {
  SearchService({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// Anthropic 兼容端点。**不能**复用聊天那套 base URL:
  /// 两者路径不同,拼接会得到 404。
  static const defaultBaseUrl = 'https://api.deepseek.com/anthropic/v1';

  /// 搜索用的模型名。和聊天用的 `deepseek-flash` 是两个不同的路由。
  static const defaultModel = 'deepseek-v4-flash';

  /// 服务端最多搜几次。3 次够覆盖大多数问题,再多只是烧 token。
  static const _maxUses = 3;

  /// 把 [topic] 交给服务端搜索并整理。
  ///
  /// [context] 是聊天里他最近说的话,用来让查询词更贴题——
  /// 单独把最后一句话发过去经常会搜偏("这个怎么办"这种指代)。
  Future<SearchOutcome> search({
    required String apiKey,
    required String topic,
    String baseUrl = defaultBaseUrl,
    String model = defaultModel,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw const SearchException('还没填 API key,去「我的」里填一下');
    }
    final query = topic.trim();
    if (query.isEmpty) {
      throw const SearchException('没有什么可搜的内容');
    }

    final uri = Uri.parse('${_normalize(baseUrl)}/messages');
    final http.Response response;
    try {
      response = await _http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          // 这个端点用 x-api-key,不是聊天那边的 Authorization: Bearer。
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
        },
        body: utf8.encode(
          jsonEncode({
            'model': model,
            'max_tokens': 2048,
            'messages': [
              {
                'role': 'user',
                'content': 'Perform a web search for the query: $query',
              },
            ],
            'tools': [
              {
                'type': 'web_search_20250305',
                'name': 'web_search',
                'max_uses': _maxUses,
              },
            ],
          }),
        ),
      );
    } on Exception catch (error) {
      throw SearchException('连不上搜索服务:$error');
    }

    if (response.statusCode != 200) {
      throw SearchException(_describe(response));
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const SearchException('搜索返回的内容看不懂,先不联网了');
    }
    if (decoded is! Map) {
      throw const SearchException('搜索返回的内容看不懂,先不联网了');
    }

    return parseSearchResponse(
      decoded.cast<String, Object?>(),
      query: query,
    );
  }

  /// 解析搜索响应。
  ///
  /// 结构(实测):
  /// ```
  /// content: [
  ///   {type: thinking, ...},
  ///   {type: server_tool_use, name: web_search, input: {query}},
  ///   {type: web_search_tool_result, content: [
  ///      {type: web_search_result, title, url, encrypted_content, page_age}]},
  ///   {type: text, text: "整理稿"},
  /// ]
  /// ```
  ///
  /// 按**块类型**取,不去正文里抠 URL——服务端的结构化结果才是可信来源。
  static SearchOutcome parseSearchResponse(
    Map<String, Object?> json, {
    required String query,
  }) {
    final content = json['content'];
    final sources = <SearchSource>[];
    final seen = <String>{};
    final texts = <String>[];

    if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        final type = block['type'];
        if (type == 'text') {
          final text = block['text'];
          if (text is String && text.trim().isNotEmpty) texts.add(text.trim());
          continue;
        }
        if (type != 'web_search_tool_result') continue;
        final inner = block['content'];
        if (inner is! List) continue;
        for (final item in inner) {
          if (item is! Map) continue;
          final source = SearchSource.fromJson(item.cast<String, Object?>());
          // 按 URL 去重:同一条结果会在多轮搜索里重复出现。
          if (source == null || !seen.add(source.url)) continue;
          sources.add(source);
        }
      }
    }

    return SearchOutcome(
      query: query,
      sources: sources,
      // 多个 text 块就按顺序拼起来(中间可能夹着 thinking,那些不要)。
      summary: texts.join('\n\n'),
    );
  }

  /// 写进聊天上下文的样子。
  ///
  /// 给**来源 + 整理稿**两样,而不是只给链接:模型读不到网页,
  /// 一堆 URL 对它等于没有信息。
  ///
  /// [maxSummary] 限制整理稿长度。实测一次搜索的整理稿约 1500 字,
  /// 全塞进去每轮都要多花这些 token;截到 1200 字仍然保留关键事实,
  /// 又不至于让长对话迅速膨胀。
  static String formatForContext(
    SearchOutcome outcome, {
    int maxSummary = 1200,
  }) {
    final buffer = StringBuffer()
      ..writeln('以下是刚刚联网搜到的真实结果(查询词:${outcome.query})。');
    if (outcome.sources.isNotEmpty) {
      buffer.writeln('来源:');
      for (final source in outcome.sources.take(8)) {
        buffer.writeln(
          '- ${source.title}${source.age == null ? '' : '(${source.age})'} ${source.url}',
        );
      }
    }
    final summary = outcome.summary.trim();
    if (summary.isNotEmpty) {
      buffer.writeln('搜索结果整理:');
      buffer.writeln(
        summary.length <= maxSummary ? summary : '${summary.substring(0, maxSummary)}…',
      );
    }
    buffer.writeln(
      '请基于这些结果回答。它们比你的记忆新;如果结果不够回答这个问题,'
      '就直说没查到,不要拿记忆里的东西混进去当成搜到的。',
    );
    return buffer.toString();
  }

  /// 搜索失败时给用户看的一句话。
  ///
  /// 用户选的是"明确告诉他没搜到,而不是静默退回"——静默的话他分不清
  /// 这个回答是来自网络还是模型自己的旧知识。
  static String failureNotice(Object error) {
    final detail = error is SearchException ? error.message : '$error';
    return '这次没搜到(联网搜索失败:$detail),下面是模型自己的知识。';
  }

  static String _describe(http.Response response) {
    var detail = '';
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['error'] is Map) {
        final message = (decoded['error'] as Map)['message'];
        if (message is String) detail = message;
      }
    } on FormatException {
      // 非 JSON 的错误页没有可解析的 detail,用状态码兜底。
    }
    final hint = switch (response.statusCode) {
      401 || 403 => 'API key 不对或没有联网搜索权限',
      400 when detail.isEmpty => '搜索服务拒绝了这次请求(可能是发太快被限流)',
      429 => '请求太频繁,等一下再试',
      >= 500 => '搜索服务出问题了,过会儿再试',
      _ => '搜索失败(${response.statusCode})',
    };
    return detail.isEmpty ? hint : '$hint:$detail';
  }

  static String _normalize(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  void dispose() => _http.close();
}
