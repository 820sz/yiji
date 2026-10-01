# 本轮任务看板(v0.8.0)

用户一次性提了 8 项。这份文件是**唯一进度源**,每完成一项就改状态并写上证据。
共享任务板上对应 task-1 … task-8。

约定:每项必须有**命令证据**(测试输出、analyze 结果、APK 校验),不写"应该可以"。

---

## 状态总览

| # | 任务 | 共享任务 | 状态 | 证据 |
|---|---|---|---|---|
| 1 | 任务左滑=完成、右滑=删除(带撤回) | task-1 | 🟡 代码已改,缺测试 | — |
| 2 | 长按拖拽排序 | task-2 | 🟡 已改:排序模式下按住即可拖 | — |
| 3 | 任务可标"未完成",AI 读到 | task-4 | ✅ 代码完成(缺 app 测试) | sqltest 67 通过(含 v3→v4 迁移,红/绿验证) |
| 4 | 替换混乱的系统时间选择器 | task-3 | ✅ 完成 | `flutter test` 157 通过;两处调用已换;接入 zh_CN 本地化 |
| 5 | AI 主动建议补充新目标(多选) | task-5 | ⬜ 未开始 | — |
| 6 | 聊天:丝滑 + 图片显示 + 表情包 + 每会话头像 | task-6 | 🟡 数据层已通(落盘/引用/解析/头像列),UI 未接 | — |
| 7 | 我的页身份卡片可编辑 + 打磨 | task-7 | ⬜ 未开始 | — |
| 8 | 表情包素材接进 APK | task-8 | 🟡 素材 3.58MB 已就绪,assets 已声明 | — |

图例:⬜ 未开始 / 🟡 进行中 / ✅ 完成并验证

### 2026-10-01 进度

- **schema v4 已上线**:`tasks.outcome`(none/done/fell)+ `conversations.avatar`。
  - 踩到的坑:`v2→v4` 的升级链上,`createConversationTableV3` 必须建**v3 当时的样子**
    (不含 avatar),否则 v4 那步 ALTER 会撞 `duplicate column name`。
    已用 `v2 升级到 v3` 测试做红/绿验证。
- **"没做好"标记**:入口在任务编辑页的「完成情况」选择条(不是长按菜单——
  长按已经被拖动和多选占满了);列表上显示一个「没做好」小标;
  `aiContext` / `plainReport` 都会把它单独列出来,周报的「不足」有素材了。
- **左滑完成 / 右滑删除**:都在 `confirmDismiss` 里落库(避免 Dismissible 断言),
  右滑删除带 SnackBar 撤回(`AppState.restoreTask`)。
- **长按拖动 vs 长按多选**:两者都是长按,只能留一个。结论——长按保持"进多选"
  (既有行为),拖动放在**排序模式**里(表头新增「调整顺序」按钮,
  进去之后整张卡片按住即拖,不用够右边的小把手)。
- **时刻选择器**:`lib/ui/time_sheet.dart` 已接进任务编辑页与日历弹层;
  测试里 `TimePickerDialog` 的断言换成自建面板的文案。
- **本地化**:接入 `flutter_localizations`,系统组件文案变中文。
- **Flutter 资源声明不支持通配符**:写 `assets/memes/**` 会让 `flutter test` 直接崩
  (`Illegal character in path: **`)。必须逐个 tag 目录列出来,见 pubspec.yaml。

---

## 已完成的前置工作

- **表情包素材**:`D:\Projects\yiji\assets\memes\`,108 张 WebP,3.58 MB
  (源库 92.2 MB,压缩比 25.9×;512px/q80;索引 `index.json` 108 条,UTF-8 无 BOM)
  - 标签用 DB 的语义标注:angry 27 / happy 29 / daily 16 / sad 13 / confused 12 /
    shy 5 / surprised 3 / sleep 2 / work 1
  - 7 个 GIF 取首帧转静态 WebP(Flutter 的 `Image.asset` 不播动图)
  - 重跑脚本:`tool/pack_memes.py`

## 已就位、等接线的代码

- `lib/ui/time_sheet.dart` — 自建 24 小时时刻选择器(左小时右分钟滚动吸附)✅ 已接线
- `lib/data/chat_images.dart` — `ChatImage` / `Meme` / `MemeLibrary` / `ChatImages`
- `lib/data/meme_directive.dart` — 解析模型回复末尾的 `[表情: 情绪 | 描述]`
- `lib/ai/prompts.dart` — `chatSystemPrompt(memeHint:)` 与 `memeHintPrompt(tags)`
- `lib/state/app_state.dart` — `restoreTask()`(撤回删除)、`setTaskOutcome()`、
  图片落盘与 `![图]` 引用、`visibleStreamingAnswer`(流式时裁掉表情包指令)、
  `_pickMeme()`、`saveConversationAvatar()` / `currentConversationAvatar`

---

## 每项的验证方式(先写下来,免得事后找借口)

1. **左滑/右滑**
   - widget 测试:左滑 → `task.done == true`;右滑 → 任务消失 + 出现「撤回」;
     点撤回 → 任务回来。
   - 反向验证:把方向改回去,测试必须变红。
2. **长按拖拽**
   - widget 测试:长按第 2 条并拖到第 1 条位置 → `reorderTasks` 落库顺序变化。
3. **"未完成"标记**
   - `tool/sqltest` 加 v3→v4 迁移测试:老库升级后任务/日记/聊天/目标全在,
     且新列默认为空。
   - app 测试:标记后周报的"不足"里能读到这条。
4. **时间选择器**
   - widget 测试:打开 → 滚到 09:30 → 确定 → 提醒落库为 `09:30`。
   - 反向验证:把 `parseHhMm` 改错,测试必须变红。
5. **AI 建议补充目标**
   - `goal_match_test`:模型回包里带 `newGoal` → 面板列出 → 确认后目标被创建
     且推进量同步;未确认则不建。
6. **聊天**
   - 图片:发一条带图的对话 → 气泡里出现 `Image` 组件(不是文件名文本)。
   - 表情包:模型回 `[表情: 开心 | 比心]` → 消息落库后正文不含这一行,
     且多出一条 `![图] asset:memes/...`。
   - 每会话头像:两个会话设不同头像 → 切换后头部头像不同。
7. **身份卡片**
   - widget 测试:点背景 → 出现换图入口;点名字 → 能改称呼。
8. **素材进包**
   - `flutter test` 里有断言 `MemeLibrary.load()` 条目数 > 0;
   - 发版后字节级检查 APK 内含 `assets/memes/index.json`。

---

## 铁律(这一轮踩过的坑)

- **不要用 PowerShell 的 `-replace`/`Set-Content` 改 Dart 源码**:会把 UTF-8 中文写成乱码
  (已经毁过一次 `test/goal_match_test.dart`)。要么用编辑工具,要么用 .NET 的
  `File.WriteAllText(path, text, UTF8Encoding($false))`。
- 改完每项都跑:`flutter analyze`(必须 0 issue)+ `flutter test`(必须全绿)。
- 关键修复做**红→绿**:先改坏确认测试抓得住,再改回来。
- pwsh 里相对路径按工作区解析,`D:\Projects\yiji` 的命令一律写绝对路径或用
  `Set-Location 'D:\Projects\yiji'` 开头。
