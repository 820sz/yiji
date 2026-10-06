import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/data/chat_attachment.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/state/app_state.dart';

import 'support/fake_store.dart';

/// **AI 要真的能看到用户发的表情包**。
///
/// 用户的原话:"用户发的表情包,ai 看不到"。根因是历史消息只带文字
/// `![图] asset:...`,只有当轮消息带多模态图片——一翻页 AI 就只剩一句路径。
/// 而它自己也只能承认:"我是读的文字描述,不是在看图"。
///
/// 这一组盯的就是:历史里的图真的被读出来、真的作为多模态发过去了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStore store;
  late Directory tempDir;

  setUp(() {
    store = FakeStore();
    SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
    // 图片要落盘,给一个真目录(测试环境没有 path_provider 通道)。
    tempDir = Directory.systemTemp.createTempSync('yiji_meme_test');
    // pin 而不是 override:pin 会把目录**固定下来**,让同步查询立刻可用。
    // 只 override 的话异步目录查询在 widget 测试里不返回,
    // 「把历史里的图读出来发给模型」这条链就断了。
    ChatImages.pinDirectoryForTest(tempDir);
  });

  tearDown(() {
    ChatImages.directoryOverride = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppState> boot(_CapturingAi ai) async {
    final state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: ai),
    );
    await state.bootstrap();
    return state;
  }

  /// 从最近一次请求里取出第 [index] 条消息。
  List<Map<String, Object?>> messagesOf(_CapturingAi ai) {
    final raw = ai.lastBody?['messages'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) item.cast<String, Object?>(),
    ];
  }

  /// 一条消息里图片部分的 url 列表。
  List<String> imageUrls(Map<String, Object?> message) {
    final content = message['content'];
    if (content is! List) return const [];
    return [
      for (final part in content)
        if (part is Map && part['type'] == 'image_url')
          ((part['image_url'] as Map?)?['url'] as String?) ?? '',
    ].where((url) => url.isNotEmpty).toList();
  }

  test('用户在历史里发过的图,会作为多模态重新发给 AI', () async {
    final ai = _CapturingAi();
    final state = await boot(ai);

    // 第一轮:发一张图(模拟用户发了张表情包)。
    final png = Uint8List.fromList(_png);
    await for (final _ in state.sendChat(
      '这张怎么样',
      attachments: [
        ChatAttachment(
          name: 'cat.png',
          isImage: true,
          imageBytes: png,
          sizeBytes: png.length,
        ),
      ],
    )) {
      // 消费掉。
    }
    await state.commitAssistantMessage();

    // 第一轮本身带图,这是本来就有的行为。
    final first = messagesOf(ai);
    expect(
      first.any((m) => imageUrls(m).isNotEmpty),
      isTrue,
      reason: '当轮就应该带图',
    );

    // 第二轮:再发一句话,不带附件。**历史里那张图必须还在**——
    // 这就是用户报的"AI 看不到",以前这里只剩一行路径文字。
    await for (final _ in state.sendChat('那你觉得呢')) {
      // 消费掉。
    }
    await state.commitAssistantMessage();

    final second = messagesOf(ai);
    final userWithImage =
        second.where((m) => m['role'] == 'user' && imageUrls(m).isNotEmpty);
    expect(
      userWithImage,
      isNotEmpty,
      reason: '历史里的图必须仍然作为多模态发过去,否则 AI 只能看到一句路径',
    );
    final url = imageUrls(userWithImage.first).first;
    expect(url, startsWith('data:image/'));
    // 而且真的是那张图的字节,不是一个空占位。
    final base64Part = url.split(',').last;
    expect(base64Decode(base64Part), png);
  });

  test('发给模型的正文里不再需要"我看不到图"的说明', () async {
    // 说明(竖线后面那句)现在只是补充信息,不是"代替图片"的替代品。
    // 这条盯住:说明还在,但图也在。
    final ai = _CapturingAi();
    final state = await boot(ai);

    final png = Uint8List.fromList(_png);
    await for (final _ in state.sendChat(
      '哈哈',
      attachments: [
        ChatAttachment(
          name: '表情包',
          isImage: true,
          imageBytes: png,
          memeCaption: '摸着圆滚滚肚子，笑眯眯喊吃饱饱',
          sizeBytes: png.length,
        ),
      ],
    )) {
      // 消费掉。
    }
    await state.commitAssistantMessage();

    final withCaption = messagesOf(ai).where(
      (m) => '${m['content']}'.contains('摸着圆滚滚肚子'),
    );
    expect(withCaption, isNotEmpty, reason: 'caption 仍然要带上,它是情绪线索');
    expect(
      messagesOf(ai).any((m) => imageUrls(m).isNotEmpty),
      isTrue,
      reason: '同时图也必须真的发过去',
    );
  });
}

/// 记下最后一次请求体的假客户端。
class _CapturingAi extends http.BaseClient {
  Map<String, Object?>? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      lastBody = jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
    }
    final body = 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '好的。'},
            }
          ],
        })}\n\ndata: [DONE]\n\n';
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(body)]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

/// 一张最小的合法 PNG(1×1),用来当"用户发的图"。
const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
