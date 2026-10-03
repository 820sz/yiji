import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/core/day.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/main.dart';
import 'package:yiji/state/app_state.dart';

import 'support/fake_store.dart';

/// 「今日想法」的两件事:配照片、分享给 AI。
///
/// 用户原话:
/// - "'今日想法'支持补充照片,就像我给你截的软件的图一样
///   (同样,分享给 ai 时连照片一并一起)"
/// - "'今日想法'点进去后,右上角需增加'分享给ai'的功能,点击后,用户可跳转至聊天功能,
///   自选分享的 ai 聊天对象,并且把该想法以一个附件的形式悬挂在打字框上方,
///   然后补充需求,进行聊天"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStore store;
  late AppState state;
  late Directory tempDir;

  final today = todayKey();

  setUp(() {
    store = FakeStore();
    SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
    // 照片要落盘,而测试环境没有 path_provider 通道。
    tempDir = Directory.systemTemp.createTempSync('yiji_journal_test');
    ChatImages.directoryOverride = tempDir;
  });

  tearDown(() {
    ChatImages.directoryOverride = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: _StubAi()),
    );
    await tester.pumpWidget(YijiApp(state: state, enableSplash: false));
    await tester.pumpAndSettle();
  }

  /// 只造状态、不渲染界面:给纯状态层的用例用。
  ///
  /// 不渲染就不用管 widget 绑定和动画,这些用例本来也只关心
  /// "存进去的东西读出来对不对"。
  Future<void> bootState() async {
    state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: _StubAi()),
    );
    await state.bootstrap();
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  group('想法能配照片', () {
    test('加了照片之后,日记不会因为没写字而被当成空的删掉', () async {
      // 这条是**语义**问题:"只有空白字符的日记等同没写"这条规矩在有了照片
      // 之后就不成立了——一条纯配图的日记是完整的一条日记。
      await bootState();
      final ok = await state.addJournalPhoto(Uint8List.fromList(_png));
      expect(ok, isTrue);

      final journal = await store.journalOfDay(today);
      expect(journal, isNotNull, reason: '配了图的日记不该被当成空日记删掉');
      expect(journal!.photoRefs, hasLength(1));
    });

    test('照片存的是文件名,不是 base64', () async {
      // 进库的只能是短文件名;base64 会让每条日记膨胀几百 KB。
      await bootState();
      await state.addJournalPhoto(Uint8List.fromList(_png));

      final journal = await store.journalOfDay(today);
      final ref = journal!.photoRefs.single;
      expect(ref.contains('base64'), isFalse);
      expect(ref.length, lessThan(80), reason: '库里应当只存文件名,实际:$ref');
    });

    test('能去掉某一张照片', () async {
      await bootState();
      await state.addJournalPhoto(Uint8List.fromList(_png));
      await state.addJournalPhoto(Uint8List.fromList(_png));

      var journal = await store.journalOfDay(today);
      expect(journal!.photoRefs, hasLength(2));

      await state.removeJournalPhoto(journal.photoRefs.first);
      journal = await store.journalOfDay(today);
      expect(journal!.photoRefs, hasLength(1));
    });

    test('只改文字不会把已有照片抹掉', () async {
      // photoRefs 传 null 的语义就是"不动照片"。默认值写错的话,
      // 用户改一次文字就丢一次图。
      await bootState();
      await state.addJournalPhoto(Uint8List.fromList(_png));

      await state.saveJournal('今天想法变了');
      final journal = await store.journalOfDay(today);
      expect(journal!.text, '今天想法变了');
      expect(journal.photoRefs, hasLength(1), reason: '改文字不该顺手删照片');
    });
  });

  group('分享给 AI', () {
    test('暂存的想法能被取走一次,而且只取一次', () async {
      await bootState();
      expect(state.hasPendingShare, isFalse);

      state.stageJournalShare(text: '今天想通了一件事');
      expect(state.hasPendingShare, isTrue);

      final first = state.takePendingShare();
      expect(first!.text, '今天想通了一件事');
      // 取走之后就没有了,免得聊天页每次重建都重复挂一遍。
      expect(state.hasPendingShare, isFalse);
      expect(state.takePendingShare(), isNull);
    });

    test('分享会带上照片', () async {
      // 用户明确要求"分享给 ai 时连照片一并一起"。
      await bootState();
      state.stageJournalShare(
        text: '配了图的想法',
        photos: const ['a.png', 'b.png'],
      );

      final share = state.takePendingShare();
      expect(share!.photos, ['a.png', 'b.png']);
    });

    testWidgets('分享之后附件挂在输入框上方,不会自动发出去', (tester) async {
      // 用户要的流程是"悬挂在打字框上方,然后补充需求,进行聊天"——
      // 所以绝对不能自动发送。
      await pumpApp(tester);
      await openTab(tester, '聊天');

      state.stageJournalShare(text: '今天读《人物》想通了情节的作用');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('想通了情节的作用'),
        findsWidgets,
        reason: '想法应当作为附件显示在输入框上方',
      );
      // 关键:没有自动发送 —— 会话里不该多出任何消息。
      expect(state.chat, isEmpty, reason: '分享只挂附件,发不发由用户决定');
    });
  });
}

/// 不发网络请求的假客户端。
class _StubAi extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body =
        'data: {"choices":[{"delta":{"content":"好的。"}}]}\n\ndata: [DONE]\n\n';
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(body)]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

/// 一张最小的合法 PNG(1×1)。
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
