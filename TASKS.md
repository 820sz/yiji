# 本轮任务看板(v0.8.0)—— 全部完成

用户一次性提了 8 项。这份文件是**唯一进度源**。
共享任务板上对应 task-1 … task-8,**八项全部 completed**。

约定:每项必须有**命令证据**(测试输出、analyze 结果、APK 校验),不写"应该可以"。

---

## 状态总览(全部完成)

| # | 任务 | 共享任务 | 状态 | 证据 |
|---|---|---|---|---|
| 1 | 任务左滑=完成、右滑=删除(带撤回) | task-1 | ✅ | `任务卡片的手势` 4 条用例:左滑→done、右滑→删除+撤回、长按多选 |
| 2 | 长按拖拽排序 | task-2 | ✅ | 同组第 4 条:排序模式按住 700ms 分段拖动 → 顺序落库 |
| 3 | 任务可标"没做好",AI 读到 | task-4 | ✅ | sqltest 67 全绿(含 v3→v4 迁移,红/绿验证);报告单列 △ |
| 4 | 替换混乱的系统时间选择器 | task-3 | ✅ | 自建滚轮 + zh_CN 本地化;两处调用已换 |
| 5 | AI 主动建议补充新目标(多选) | task-5 | ✅ | `AI 建议补充新目标` 5 条用例全绿 |
| 6 | 聊天:丝滑 + 图片 + 表情包 + 每会话头像 | task-6 | ✅ | `chat_image_test` 15 条 + 会话测试 3 条(表情包/头像/不硬塞) |
| 7 | 我的页身份卡片可编辑 + 打磨 | task-7 | ✅ | `我的页` 新增 4 条:改名、改签名、换背景、换头像 |
| 8 | 表情包素材接进 APK | task-8 | ✅ | APK 内 108 张 webp + index.json,共 3.58 MB(字节级校验) |

**最终验证**
- `flutter analyze`:**No issues found**
- 顶层测试:**189 条全绿**(`flutter test`)
- 数据层测试:**67 条全绿**(`tool/sqltest` 里的 `flutter test`)
- 发布:release tag `v8`,资产 64,061,203 字节,`HEAD` 200;桌面 APK 与它**字节一致**
- APK 内容校验:9 条新文案在 `libapp.so` 里;`assets/flutter_assets/assets/memes/` 下 109 个条目

---

## 这一轮踩到的坑(下次别再踩)

1. **Flutter 资源声明不支持通配符。** 写 `assets/memes/**` 会让 `flutter test`
   直接崩(`Illegal character in path: **`);只写 `assets/memes/` 又**不含子目录**。
   必须逐个 tag 目录列出来。
2. **不要用 PowerShell 的 `-replace` / `Set-Content` 改 Dart 源码**:会把 UTF-8
   中文写成乱码。这一轮因此毁过两次文件(已从 git 恢复)。要么用编辑工具,
   要么用 .NET 的 `File.WriteAllText(path, text, UTF8Encoding($false))`。
3. **schema 迁移要一步一个版本。** v2→v4 的链路上,`createConversationTableV3`
   必须建 **v3 当时的样子**(不含后来加的列),否则 v4 的 `ALTER` 会撞
   `duplicate column name`。用 `v2 升级到 v3` 那条测试做红/绿验证。
4. **拖动识别器要等长按超时。** 测试里按住 700ms 再分段移动才认;
   按太短就只是一次普通轻触。
5. **测试替身漏字段会伪装成产品 bug。** `FakeStore.conversations()` 重建对象时
   漏了 `avatar`,于是"每个对话独立头像"看起来永远是坏的,而生产实现没问题。
   改测试替身时要比着模型逐字段核对。

---

## 需求原文 → 实现位置(便于回溯)

| 用户原话 | 位置 |
|---|---|
| 任务左滑应该是"完成" | `lib/ui/today_screen.dart` 的 `_TaskRow.confirmDismiss` |
| 支持长按拖住进行排序 | 同文件 `_DragToReorder` + 表头「调整顺序」按钮 |
| 增加"未完成"标记,AI 读取 | `TaskOutcome`(models.dart)、编辑页「完成情况」、`report_service.dart` |
| 日历的闹钟提示的时钟界面混乱 | `lib/ui/time_sheet.dart` |
| AI 识别后智能补充任务 | `goal_matcher.dart` 的 `newGoals` + `progress_screen.dart` 的审阅面板 |
| 上传的图片要显示图片 | `chat_screen.dart` 的 `splitMessageParts` 与 `_MessageImage` |
| 增加表情包插件 | `assets/memes/` + `meme_directive.dart` + `meme_sheet.dart` |
| 对话侧边栏"头像+标题"、每聊天头像 | `chat_sidebar.dart`、`conversations.avatar` |
| 用户名片没法编辑 | `lib/ui/identity_card.dart`(四个独立编辑入口) |


---

## 状态总览

| # | 任务 | 共享任务 | 状态 | 证据 |
|---|---|---|---|---|
| 1 | 任务左滑=完成、右滑=删除(带撤回) | task-1 | 🟡 代码完成,缺自动化测试 | 手动路径已通;测试待补 |
| 2 | 长按拖拽排序 | task-2 | 🟡 已接进排序模式,缺测试 | — |
| 3 | 任务可标"没做好",AI 读到 | task-4 | ✅ 完成 | sqltest 67 全绿(含 v3→v4 迁移红/绿);报告里单列"△" |
| 4 | 替换混乱的系统时间选择器 | task-3 | ✅ 完成 | 顶层 177 测试全绿;两处调用已换;zh_CN 本地化 |
| 5 | AI 主动建议补充新目标(多选) | task-5 | ✅ 完成 | goal_match_test 5 条新用例全绿 |
| 6 | 聊天:丝滑 + 图片显示 + 表情包 + 每会话头像 | task-6 | 🟡 代码全部完成,缺自动化测试 | chat_image_test 15 条全绿;表情包图库可从 assets 读出 |
| 7 | 我的页身份卡片可编辑 + 打磨 | task-7 | ⬜ 未开始 | — |
| 8 | 表情包素材接进 APK | task-8 | 🟡 已声明 assets 且 109 个文件已进 git,待装机校验 APK | — |

图例:⬜ 未开始 / 🟡 进行中 / ✅ 完成并验证

**当前测试总数:顶层 177 条全绿,`tool/sqltest` 67 条全绿,`flutter analyze` 无问题。**

### 2026-10-01 进度(第二批)

- **AI 建议补充新目标**(task-5)完成:模型回包里新增 `newGoals`,
  审阅面板分两组(加进度 / 新建目标),确认后建目标并把这次已完成的量一起记进去。
  目标值不填——他做这件事之前并没定过要推进到多少,硬填一个数是替他做决定。
  顺手修了一个真 bug:`_autoSyncProgress` 原本在"一条目标都没有"时直接返回,
  而**那正是最该问"要不要建第一条"的时刻**,等于让新用户永远看不到这个功能。
- **"没做好"标记**(task-4)完成:编辑页「完成情况」选择条 + 列表小标;
  `aiContext` 单独列一块、`plainReport` 用 △ 标出来。
  schema v4 加了 `tasks.outcome`,迁移测试覆盖 v3→v4。
- **时刻选择器**(task-3)完成并接进任务编辑页与日历弹层。
- **聊天 4 项**(task-6)代码完成:图片在气泡里渲染成图(不再是文件名)、
  表情包图库接进 UI(AI 可自动发、用户可手挑)、每会话独立头像、
  流式期间不再整页重建(只重绘正在长的那条)。

### 打算怎么验剩下的

- task-1 / task-2 / task-6 的自动化测试:左滑完成、右滑删除+撤回、
  排序模式拖动落库、图片渲染、表情包插入、每会话头像。
- task-7:身份卡片的换图/改名入口。
- task-8:发版后字节级校验 APK 里有 `assets/memes/index.json`。


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
