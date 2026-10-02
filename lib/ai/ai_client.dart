import 'dart:convert';

import 'package:http/http.dart' as http;

/// 思考强度。
///
/// 官方在传参层面还接受 minimal/medium/xhigh/ultra,但它们会被映射到
/// low/high/max 三档,所以这里只暴露三个真实档位,避免给出"看起来能调、
/// 其实没有区别"的选项。
enum ThinkingLevel {
  off('不思考', '最快,适合闲聊'),
  low('轻', '想一下再答'),
  high('中', '默认档'),
  max('深', '慢,适合要它认真拆解的问题');

  const ThinkingLevel(this.label, this.hint);

  final String label;
  final String hint;

  /// 传给 `reasoning_effort` 的值;关闭思考时不传这个参数。
  String? get effort => switch (this) {
        ThinkingLevel.off => null,
        ThinkingLevel.low => 'low',
        ThinkingLevel.high => 'high',
        ThinkingLevel.max => 'max',
      };

  bool get enabled => this != ThinkingLevel.off;

  static ThinkingLevel fromKey(String? key) {
    for (final level in ThinkingLevel.values) {
      if (level.name == key) return level;
    }
    return ThinkingLevel.high;
  }
}

/// 一次 AI 调用的目标配置。
///
/// 用户自填,所以模型名和地址都不是硬编码常量,而是可改的设置项——
/// 官方换模型名时不需要重新发版。
class AiConfig {
  const AiConfig({
    required this.apiKey,
    this.baseUrl = defaultBaseUrl,
    this.model = defaultModel,
    this.temperature = 0.7,
    this.thinking = ThinkingLevel.high,
  });

  static const defaultBaseUrl = 'https://api.deepseek.com';
  static const defaultModel = 'deepseek-flash';

  /// 可选模型。`deepseek-flash` 空闲时段更便宜,适合整周数据这种长输入。
  static const knownModels = ['deepseek-flash', 'deepseek-v4-pro'];

  final String apiKey;
  final String baseUrl;
  final String model;
  final double temperature;

  /// 聊天与生成总结用的思考强度。
  final ThinkingLevel thinking;

  bool get isUsable => apiKey.trim().isNotEmpty;

  AiConfig copyWith({
    String? apiKey,
    String? baseUrl,
    String? model,
    double? temperature,
    ThinkingLevel? thinking,
  }) {
    return AiConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      thinking: thinking ?? this.thinking,
    );
  }
}

/// 出错的统一类型,界面直接展示 [message] 即可。
class AiException implements Exception {
  AiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 流式回复里的一片内容。
///
/// 思考过程和最终回答走同一个流:界面要按到达顺序交错显示,
/// 所以不能拆成两个 Stream 让调用方自己对齐。
class AiChunk {
  const AiChunk.reasoning(this.text) : isReasoning = true;
  const AiChunk.content(this.text) : isReasoning = false;

  final String text;
  final bool isReasoning;
}

/// 一条对话消息。
///
/// 做成类型而不是裸 `Map<String, String>`,是因为带图片的消息 content 是**数组**
/// 而不是字符串;用 Map 表达就得让每个调用方自己拼那段结构,早晚拼错。
class AiMessage {
  const AiMessage.system(this.text) : role = 'system', images = const [];

  const AiMessage.user(this.text, {this.images = const []}) : role = 'user';

  const AiMessage.assistant(this.text) : role = 'assistant', images = const [];

  final String role;
  final String text;

  /// 附带的图片,已是 data URL 形式。只有 user 消息用得上。
  final List<String> images;

  /// 转成请求体里的一项。
  ///
  /// 没有图片时 content 直接是字符串——绝大多数请求都是这样,
  /// 不因为支持了图片就让每一轮都变成数组格式。
  Map<String, Object?> toJson() {
    if (images.isEmpty) return {'role': role, 'content': text};
    return {
      'role': role,
      'content': [
        {'type': 'text', 'text': text},
        for (final image in images)
          {
            'type': 'image_url',
            'image_url': {'url': image},
          },
      ],
    };
  }
}

/// 与 OpenAI 兼容格式的对话接口通信,支持流式输出与思考过程。
///
/// [httpClient] 可注入,便于测试替换成不起网络的假客户端。
class AiClient {
  AiClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// 发一次对话请求,按到达顺序吐出思考过程与回答的增量。
  ///
  /// [history] 是完整消息列表(含 system),最后一条应是本次用户输入。
  /// 流结束时正常收尾;HTTP 非 200 时抛 [AiException],不做静默重试——
  /// 错了要让用户看到,而不是假装在思考。
  Stream<AiChunk> streamChat({
    required AiConfig config,
    required List<AiMessage> history,
    bool jsonMode = false,
  }) async* {
    if (!config.isUsable) {
      throw AiException('还没填 API key,去设置里填一下');
    }

    final uri = Uri.parse('${_normalizedBase(config.baseUrl)}/chat/completions');
    final request = http.Request('POST', uri)
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey.trim()}',
      })
      ..bodyBytes = utf8.encode(
        jsonEncode({
          'model': config.model,
          'messages': [for (final message in history) message.toJson()],
          'stream': true,
          // 思考模式下 temperature 不生效,官方明确说明该参数会被忽略,
          // 所以只在关闭思考时才带上,避免传一个"看起来在起作用"的值。
          if (!config.thinking.enabled) 'temperature': config.temperature,
          'thinking': {'type': config.thinking.enabled ? 'enabled' : 'disabled'},
          if (config.thinking.effort != null) 'reasoning_effort': config.thinking.effort,
          if (jsonMode) 'response_format': {'type': 'json_object'},
        }),
      );

    // 撞上限流窗口时自动重试。
    //
    // 这个接口在请求密集时会进入一段窗口:**所有**请求都返回 400、响应体为空,
    // 连"只有一句 user"的最简请求也一样,等几十秒自己恢复(实测:连续成功
    // 12 次之后进入窗口,再等 30 秒左右恢复)。
    //
    // 用户感知到的是"聊着着突然全都不行了",而他什么都没做错。所以这里
    // 退避重试,而不是把这个窗口原样丢给他看。
    var response = await _sendOnce(request);
    var body = response.statusCode == 200
        ? ''
        : await response.stream.bytesToString();

    for (var attempt = 0;
        attempt < _throttleRetries && _isThrottleWindow(response.statusCode, body);
        attempt++) {
      await Future<void>.delayed(_throttleBackoff * (attempt + 1));
      response = await _sendOnce(request);
      body = response.statusCode == 200
          ? ''
          : await response.stream.bytesToString();
    }

    if (response.statusCode != 200) {
      throw AiException(
        _describeError(response.statusCode, body),
        statusCode: response.statusCode,
      );
    }

    // SSE:每行形如 `data: {...}`,流以 `data: [DONE]` 结束。
    // 用 utf8.decoder 而非 response.stream.transform(utf8.decoder) 的默认分块,
    // 是为了让被 TCP 分到两个 chunk 里的多字节汉字不会被截断。
    final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;

      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException {
        // 半行 JSON 说明服务端分包了,跳过这一片,后续分片会补上。
        continue;
      }
      // 只认对象。某些网关会在流中间插一条数组或裸值(心跳之类),
      // 直接 `as Map` 会抛 TypeError——那是 Error 不是 Exception,
      // 接 FormatException 的 catch 拦不住,整条流会以一句看不懂的话断掉。
      if (decoded is! Map) continue;
      final chunk = decoded.cast<String, Object?>();

      final delta = _extractDelta(chunk);
      if (delta == null) continue;
      if (delta.reasoning.isNotEmpty) yield AiChunk.reasoning(delta.reasoning);
      if (delta.content.isNotEmpty) yield AiChunk.content(delta.content);
    }
  }

  /// 一次性拿完整回答(需要 JSON 或要整段解析时用)。
  ///
  /// 官方文档提示 JSON 模式下有概率返回空 content,所以空回复会重试一次;
  /// 第二次仍为空才抛错。失败要说得清楚,而不是把空串交给上层去猜。
  Future<String> complete({
    required AiConfig config,
    required List<AiMessage> history,
    bool jsonMode = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final buffer = StringBuffer();
      await for (final chunk in streamChat(
        config: config,
        history: history,
        jsonMode: jsonMode,
      )) {
        if (!chunk.isReasoning) buffer.write(chunk.text);
      }
      final text = buffer.toString().trim();
      if (text.isNotEmpty) return text;
    }
    throw AiException('模型返回了空内容,再试一次通常就好了');
  }

  /// 从流式分片里取增量文本;取不到返回 null(如最后一帧只有结束原因)。
  static ({String reasoning, String content})? _extractDelta(
    Map<String, Object?> chunk,
  ) {
    final choices = chunk['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final delta = first['delta'];
    if (delta is! Map) return null;

    final content = delta['content'];
    final reasoning = delta['reasoning_content'];
    if (content is! String && reasoning is! String) return null;
    return (
      reasoning: reasoning is String ? reasoning : '',
      content: content is String ? content : '',
    );
  }

  /// 把服务端错误翻译成用户看得懂的一句话。
  static String _describeError(int status, String body) {
    String? detail;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final message = (decoded['error'] as Map)['message'];
        if (message is String) detail = message;
      }
    } on FormatException {
      // 非 JSON 错误页(如网关 502)没有可解析的 detail,用状态码兜底。
    }

    final hint = switch (status) {
      // 400 且**响应体是空的**,不是参数问题:这个接口在被限流时会这样回。
      // 之前一律报"模型不支持当前参数",查了半天才发现是发太快了。
      400 when detail == null && body.trim().isEmpty =>
        '请求被拒了(接口没给原因)。最常见的原因是发得太快被限流,'
            '等十几秒再试;如果一直这样,再检查模型名和接口地址',
      400 => '请求被拒绝,可能是这个模型不支持当前参数',
      401 => 'API key 不对或已失效',
      402 => '账户余额不足',
      429 => '请求太频繁,等一下再试',
      >= 500 => '服务器出问题了,过会儿再试',
      _ => '请求失败($status)',
    };
    return detail == null ? hint : '$hint:$detail';
  }

  /// 限流窗口的重试参数。
  ///
  /// 3 次 × (5s、10s、15s) 共 30 秒:实测这个窗口大约 30 秒就恢复,
  /// 再等下去用户会觉得界面卡死,而重试太密又只是白刷失败。
  static const _throttleRetries = 3;
  static const _throttleBackoff = Duration(seconds: 5);

  /// 发一次请求。连不上时抛 [AiException]。
  Future<http.StreamedResponse> _sendOnce(http.BaseRequest request) async {
    try {
      return await _http.send(request);
    } on Exception catch (error) {
      throw AiException('连不上服务器,检查一下网络: $error');
    }
  }

  /// 这个响应是不是"限流窗口"。
  ///
  /// 判据是 **400 + 空响应体**:正常的参数错误会带一句说明,只有限流窗口
  /// 才是空体。不能把普通 400 也重试——那是真的参数或模型名不对,
  /// 重试三次只会让用户多等 30 秒才看到错误。
  static bool _isThrottleWindow(int status, String body) =>
      status == 400 && body.trim().isEmpty;

  static String _normalizedBase(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  void dispose() => _http.close();
}
