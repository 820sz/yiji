import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/update/release_notes.dart';

/// 更新公告的排版。
///
/// 用户反馈过公告"内容不够清晰、排版混乱、不够简洁"。根因是把 release 的
/// markdown 原文直接倒进弹层:满屏 `##`、`**`、`-`,一次十几条。
/// 这里把"整理成摘要 + 最多 5 条要点"这件事锁住。
void main() {
  test('去掉 markdown 记号', () {
    final result = parseReleaseNotes('''
# 忆记 v0.9.0

这一版修了几件事。

## 任务

- **左滑**改成「完成」,不再是 `删除`
- 支持[拖拽排序](https://example.com)
''');
    expect(result.summary, '这一版修了几件事。');
    for (final bullet in result.bullets) {
      expect(bullet.contains('**'), isFalse, reason: '不该留粗体记号:$bullet');
      expect(bullet.contains('`'), isFalse, reason: '不该留反引号:$bullet');
      expect(bullet.contains(']('), isFalse, reason: '不该留 markdown 链接:$bullet');
    }
    expect(result.bullets.any((b) => b.contains('左滑')), isTrue);
    expect(result.bullets.any((b) => b.contains('拖拽排序')), isTrue);
  });

  test('最多给 5 条,优先留修 bug 的', () {
    final result = parseReleaseNotes('''
开头一句话。

- 新增了 10 个主题
- 新增了深色模式的皮肤
- 支持自定义字体
- 修掉了点勾没反应的问题
- 修掉了通知不响的问题
- 新增了更多表情包分类
- 支持导入导出全部数据
''');
    expect(result.bullets, hasLength(5));
    // 修 bug 的那些必须留下来:用户装更新时最想知道"我遇到的问题解决了没"。
    expect(
      result.bullets.any((b) => b.contains('点勾没反应')),
      isTrue,
      reason: '实际保留:${result.bullets}',
    );
    expect(result.bullets.any((b) => b.contains('通知不响')), isTrue);
  });

  test('条目少时原样保留,并且维持原文顺序', () {
    final result = parseReleaseNotes('''
摘要。

- 第一条
- 第二条
''');
    expect(result.bullets, ['第一条', '第二条']);
  });

  test('空说明不会炸', () {
    final result = parseReleaseNotes('');
    expect(result.isEmpty, isTrue);
  });

  test('没有摘要时只给要点,不会凭空造一句', () {
    final result = parseReleaseNotes('- 只有一条要点');
    expect(result.summary, isEmpty);
    expect(result.bullets, ['只有一条要点']);
  });

  test('分隔线和多余空行不会变成条目', () {
    final result = parseReleaseNotes('摘要\n\n---\n\n- 一条\n\n\n- 两条');
    expect(result.bullets, ['一条', '两条']);
  });
}
