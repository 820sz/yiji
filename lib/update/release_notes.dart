/// 把 GitHub release 正文整理成"能一眼看懂"的更新说明。
///
/// 用户反馈过发布的更新公告"不够清晰、排版混乱、不够简洁"。原因是直接把
/// release 的 markdown 原文塞进弹层:里面全是 `##`、`**`、`-` 这些符号,
/// 而且一次列十几条,读的人抓不到重点。
///
/// 这里做三件事:
/// 1. 从正文里挑出**最值得先看的几条**(有"修"「问题」的优先),最多 5 条;
/// 2. 去掉 markdown 记号,换成中文标点和缩进;
/// 3. 保留"这一版最要紧的一句话",作为标题下的摘要。
library;

/// 整理结果。
class UpdateHighlights {
  const UpdateHighlights({required this.summary, required this.bullets});

  /// 一句话摘要;取不到时为空串。
  final String summary;

  /// 要展示的条目(已去掉 markdown 记号),最多 5 条。
  final List<String> bullets;

  bool get isEmpty => summary.isEmpty && bullets.isEmpty;
}

/// 解析 release 正文。
UpdateHighlights parseReleaseNotes(String notes) {
  final lines = notes.split(RegExp(r'\r?\n'));
  final summary = <String>[];
  final bullets = <String>[];
  final sections = <String>[];

  for (final raw in lines) {
    var line = raw.trim();
    if (line.isEmpty) continue;

    // 标题行:当成"这一段讲什么",只在需要时用来补摘要。
    if (line.startsWith('#')) {
      sections.add(_stripMarks(line.replaceAll(RegExp(r'^#+\s*'), '')));
      continue;
    }
    // 分隔线没有信息量。
    if (RegExp(r'^[-*_]{3,}$').hasMatch(line)) continue;

    final isBullet = line.startsWith('- ') ||
        line.startsWith('* ') ||
        RegExp(r'^\d+[.、)]\s').hasMatch(line);
    line = _stripMarks(line.replaceFirst(RegExp(r'^([-*]|\d+[.、)])\s*'), ''));

    if (line.isEmpty) continue;
    if (isBullet) {
      bullets.add(line);
    } else {
      summary.add(line);
    }
  }

  return UpdateHighlights(
    // 摘要就用正文开头那句完整的话,不再自己改写——改写过一次的话
    // 万一和实际改动不符,比没有摘要更糟。
    summary: summary.isEmpty ? '' : summary.first,
    bullets: _pickTop(bullets, limit: 5),
  );
}

/// 挑最值得先看的几条。
///
/// 排序规则是刻意的:**修 bug / 问题**优先于新功能。用户装更新时最想知道的是
/// "我遇到的问题解决了没",而不是又多了什么新东西。
List<String> _pickTop(List<String> all, {required int limit}) {
  if (all.length <= limit) return all;

  int weight(String line) {
    var score = 0;
    for (final keyword in ['修', '问题', '不再', '没法', '错误', '崩溃', '闪']) {
      if (line.contains(keyword)) score -= 2;
    }
    for (final keyword in ['新增', '支持', '可以']) {
      if (line.contains(keyword)) score += 1;
    }
    return score;
  }

  final ranked = [...all]..sort((a, b) => weight(a).compareTo(weight(b)));
  final top = ranked.take(limit).toList();
  // 挑完之后按原文顺序还原,读起来才是连贯的。
  final picked = <String>[];
  for (final line in all) {
    if (top.contains(line)) picked.add(line);
  }
  return picked;
}

/// 去掉 markdown 的行内记号:粗体、代码、链接。
///
/// 用 [replaceAllMapped] 而不是 `replaceAll`:`replaceAll` 的替换串**不支持
/// `$1` 反向引用**——它会把 `$1` 当普通字符原样写进去,于是说明里出现
/// 「$1改成「完成」」这种东西。这个错被测试当场抓到了。
String _stripMarks(String text) {
  var out = text;
  out = out.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!);
  out = out.replaceAllMapped(RegExp(r'`(.+?)`'), (m) => m.group(1)!);
  // 链接保留文字、去掉地址。
  out = out.replaceAllMapped(
    RegExp(r'\[(.+?)\]\((.+?)\)'),
    (m) => m.group(1)!,
  );
  out = out.replaceAll('*', '');
  return out.trim();
}
