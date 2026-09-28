# 忆记 — 项目状态唯一事实源

> 安卓个人提升监督助手。把 xi283 现有的"原子笔记待办 + 周总结 docx + 发给 AI 聊"三段流程,
> 收进一个 app,并加上进度推进条与日历。

## 一、需求摘要

**目标用户**:xi283 本人(大三,四川,写小说 + 健身 + 英语 + 家教,每天用原子笔记记待办,每周写总结发给 AI)。

**核心存在物**:

| # | 用户看到什么 | 对应他原来的动作 |
|---|---|---|
| 1 | 打开 app 就是今天的待办,点一下打钩 | 原子笔记里手打今天 7 条 |
| 2 | 粘贴多行文本,一次变成多条待办 | 从原子笔记搬过来 |
| 3 | 长按某条进多选,底部弹出 颜色/删除/全选 | 原子笔记的多选操作栏 |
| 4 | 日历月视图,点某天就地编辑该天待办(含未来) | 无,新增能力 |
| 5 | 进度推进条:每周/每月要推进到多少,带进度条 | 无,新增能力 |
| 6 | 点一下让 AI 读本周已完成的待办,给出进度推进建议,确认后计入 | 无,新增能力 |
| 7 | 聊天有思考强度、思考过程可折叠、头像可换 | 在 Kimi 里聊 |
| 8 | 周报页一键出稿,可复制/分享 | 复制到 docx 发给 AI |
| 9 | 导出最近两周数据成文本 | 手动整理 |

**non-goals(明确不做)**:
1. 不做账号、不做云同步(纯本地,数据不出手机)
2. 不做通知/定时提醒(番茄钟、23:30 睡觉锁——独立工具,以后单独做)
3. 不读取手机里的原子笔记(安卓沙箱读不到别的 app 私有数据,已确认做不到)

## 二、技术路线(2026-09-25 核查)

| 项 | 选择 | 为什么 |
|---|---|---|
| 框架 | Flutter 3.44.7 + Dart 3.12.2 | 本机已装齐,一套代码出安卓 APK |
| 存储 | sqflite(SQLite),schema v2 | 纯本地离线优先,按周/月查询必须用 SQL |
| AI | DeepSeek API,OpenAI 兼容格式 | 用户自填 key;流式输出 |
| 模型 | `deepseek-flash`(默认)/ `deepseek-v4-pro` | 官方文档:1M 上下文,空闲时段半价 |
| 思考 | `thinking:{type}` + `reasoning_effort: low/high/max` | 思考内容走 `reasoning_content`,与 `content` 同级 |
| 结构化输出 | `response_format:{type:'json_object'}` | 官方提示有概率返回空 content,已做一次重试 |

## 三、数据模型(schema v2)

```sql
tasks(id, day, text, done, completed_at, sort_order, created_at, color)
journals(id, day UNIQUE, text, updated_at)
messages(id, role, content, reasoning, created_at)
goals(id, title, unit, target, period, direction, color, active, start_day, end_day, created_at)
progress_entries(id, goal_id, amount, day, note, task_id, source, created_at)
```

**两条设计原则**:

1. **报告不落库**。周报/月报是对 tasks + journals 的投影,随时现算。原始记录是唯一事实源。
2. **目标当前值不落库**。`goals.current` 由 `progress_entries` 求和得出,不单独存一列,
   避免"总数和明细对不上"这个最容易腐烂的地方。`progress_entries.task_id` 让"这条待办
   是否已同步过进度"可判定,所以同一条不会被重复计入。

## 四、AI 进度同步的分工(本次升级的核心决策)

| 角色 | 负责什么 | 为什么这样切 |
|---|---|---|
| AI | **读懂**"码字2k""码了2千字"是同一件事 | 只有模型能做灵活表述的语义匹配,规则匹配做不到 |
| 用户 | **确认**建议后计入 | 进度条是他判断自己有没有推进的依据,被猜错的数字污染比多看一眼更糟 |
| 手动 | 随时可加/改/删进度 | AI 只是省事,不是唯一入口 |

提示词里反复强调"**没有具体数量就跳过,不要猜**"——如果逼模型每条都给数字,
它会为了完成任务硬凑,进度条就废了。理由(`reason`)也展示给用户,让判断可核对。

## 五、界面与动效

视觉基准是 vivo 原子笔记的待办页:浅色底、大号粗体标题 + 灰色计数副标题、
实心淡彩卡片(未完成)/ 灰底删除线卡片(已完成)、多选底部操作栏。
另提供深色模式(默认关)。

动效按 animate 的判据分级:

| 交互 | 频率 | 决定 |
|---|---|---|
| 待办打钩 | 几十次/天 | 只做 140ms 缩放淡入,**不做入场动画** |
| 进度条推进 | 偶尔 | 220ms ease-out 宽度过渡 |
| 弹层/面板 | 偶尔 | 200–260ms,`ease-out` |
| 思考过程展开 | 偶尔 | 140ms 尺寸过渡 + 箭头旋转 |

打钩的勾从 `scale(0.9)` 而不是 `0` 开始;不用 `ease-in`;UI 一律不超过 300ms。

## 六、测试与验证

| 命令 | 覆盖 | 结果 |
|---|---|---|
| `flutter analyze`(根目录) | 静态检查 | 0 issue |
| `flutter test`(根目录) | 界面 77 个 | **77 passed** |
| `flutter test`(`tool/sqltest`) | SQL 数据层、周报聚合、v1→v2 迁移 55 个 | **55 passed** |
| `flutter test test/ai_live_test.dart`(需 key) | 真实 API 行为 | 无 key,本轮**跳过** |

合计 **132 个测试**,不含需要真机的部分。

### v0.3.0 打磨轮(用户实测反馈)

| 问题 | 修法 | 守护测试 |
|---|---|---|
| 标题被状态栏压住、文字互相叠 | 原生层 `setDecorFitsSystemWindows(false)` 统一声明由应用处理 insets,Flutter 侧 `SafeArea` 让开;各页头部再留 8px 下限兜底 | 4 条「顶部不被状态栏压住」 |
| 界面到处是"说明式提示" | 全部改成短提示或直接删掉(空状态、弹层 hint、我的页那段自述) | 相关文案断言同步更新 |
| AI 头像跟着软件图标 | 新增 `AiProvider`,按所配模型/地址识别厂商,默认画 DeepSeek 鲸鱼(CustomPainter 矢量) | 5 条厂商识别 + 1 条头部显示 |
| 日历里删不掉待办 | 日编辑弹层加左滑删除 | 日编辑相关用例 |
| 已完成/未完成没有分界 | 分两段渲染,中间加「已完成 N」细线标签 | 4 条分界用例(含渲染顺序) |
| 缺开屏 | `SplashGate`:图标先在场,文案 180ms 后 700ms 淡入,停一拍 260ms 淡出;文案可在「我的」自定义 | 4 条开屏用例 |
| 质感 | 新增待办入场动画(位移放在卡片内部,不推动列表);空状态/开屏/桌面图标统一用同一套品牌标记;清掉两处遗留的调试输出 | 位置类断言未受影响 |

**开屏动效为什么可以超过 300ms**:其余 UI 动效都压在 300ms 以内,但开屏是"读一句话"
而不是"操作界面",700ms 的淡入是让人看清字,快了反而像闪屏广告。这是唯一一处例外。

关键覆盖点:
- **v1→v2 迁移**:建 v1 结构的库 → 用生产侧 `AppDatabase.open()` 打开 → 验证旧待办、
  日记、聊天的内容与字段都还在。数据是唯一事实源且没有云端副本,这条路径必须真跑。
- **AI 同步的三条边界**:匹配成功→计入;逐条取消勾选→不计入;没有数字→不匹配。
- **思考过程**:分片类型分流、折叠展开、临时改强度不动全局设置。

### 为什么数据层测试在 `tool/sqltest` 独立包

桌面版 SQLite(`sqlite3`)会触发 Dart **native assets 编译**,而它在安卓 APK 构建里会失败
并中断打包。把这份依赖挪出 app 包后,app 的构建链才干净。

`tool/sqltest/pubspec.yaml` 里指向 app 用了**绝对路径**:相对路径 `..` 被 pub 解析到了
`tool\` 而不是项目根。

## 七、构建期踩到的坑(已修)

1. **pub 缓存与项目不同盘**导致 Kotlin 增量编译崩溃
   (`this and base files have different roots`)。已在 `android/gradle.properties`
   关掉 `kotlin.incremental`。
2. `sqlite3` 触发 native assets,见上。
3. 数据层测试原来手抄了一份建表语句,加了 `color` 列之后测试以"和真实运行无关的方式"
   失败。改为直接调用生产侧的 `AppDatabase.createSchema()`。

## 八、界面测试挖出来的真 bug(都已修)

1. `SettingsScreen.initState` 里读 `AppScope`——Flutter 禁止继承组件在 initState 里依赖。
   因为 `IndexedStack` 启动时构建全部页签,**一开 app 就会抛异常**。
2. 带背景色的 `Container` 包 `ListTile`,水波纹被盖住(框架断言)。
3. 新增待办弹层:多行输入框放进 `Column` 导致布局溢出。
4. 同一个弹层:`TextEditingController` 在关闭动画期间被提前 dispose。
5. 报告页切页签时在构建作用域里 `setState`。
6. 思考强度面板在矮屏上溢出 38px。

## 九、决策记录

| 日期 | 决策 | 理由 |
|---|---|---|
| 2026-09-14 | 用 Flutter 而非纯网页/PWA | 用户要原生 app,本机 Flutter 环境已备 |
| 2026-09-14 | 报告不落库,按需重算 | 避免"报告和打卡数据不一致" |
| 2026-09-14 | 用户自填 API key,存本机 | 不做服务端,不产生代管 key 的责任 |
| 2026-09-14 | 存储层抽成 `RecordStore` 接口 | 界面测试要能塞内存实现,不进 native assets |
| 2026-09-14 | 状态管理用 `ChangeNotifier` 手写 | 界面状态总量小,引库是过度设计 |
| 2026-09-25 | app 改名「忆记」,包名 `com.xi283.yiji` | 用户觉得「日拱」意义不明 |
| 2026-09-25 | AI 只出建议,用户确认后才计入进度 | 见第四节 |
| 2026-09-25 | 目标当前值不落库,由条目求和 | 见第三节 |
| 2026-09-25 | 排序菜单只做真实可用的两种 | 原子笔记的三项里"按提醒时间"这里没有对应功能,不摆点不动的按钮 |
| 2026-09-25 | 待办仍是"某天的一件事",不做任务模板复用 | 复用会让"没完成"的语义变复杂;等真实用一周看需求 |
| 2026-09-26 | app 改名与包名保持 `com.xi283.yiji`,版本号只升 versionCode | 覆盖安装能保留数据,不让用户重装丢记录 |
| 2026-09-26 | 界面文案一律短句,不放"教学式说明" | 用户明确反馈:那些是我给的提示词,不是给软件看的 |
| 2026-09-26 | AI 头像跟所配模型走,不跟软件图标 | 配的是 DeepSeek 就该看到 DeepSeek |
| 2026-09-26 | 开屏动效允许 700ms(唯一超过 300ms 的地方) | 它是"读一句话",不是"操作界面" |

## 九、断点快照

**已完成**:v0.3.0。

| 目标项 | 落地位置 | 验证 |
|---|---|---|
| 进度推进条(周/月/自定义 + AI 同步 + 手动改) | `lib/ui/progress_screen.dart`、`lib/ai/goal_matcher.dart`、`lib/data/goals.dart` | 界面 8 条 + 数据 12 条 |
| 聊天升级(强度 / 思考过程 / 流式 / 头像跟随模型) | `lib/ui/chat_screen.dart`、`lib/ui/ai_avatar.dart`、`lib/ai/ai_client.dart` | 界面 5 条 + 客户端 8 条 + 厂商识别 5 条 |
| 日历(月视图 + 点日期就地编辑/删除未来待办) | `lib/ui/calendar_screen.dart`、`lib/ui/task_sheets.dart` | 界面 4 条 |
| UI/交互/动效重做(原子笔记风格) + 顶部安全区 + 分界 + 开屏 | `lib/ui/theme.dart`、`task_card.dart`、`today_screen.dart`、`splash_screen.dart` | 界面 20 条(含 4 条安全区、4 条分界、4 条开屏) |
| 可安装 release APK | `build/app/outputs/flutter-apk/app-release.apk` | `versionName=0.3.0`,`com.xi283.yiji`,自适应图标 |

**交付物**:`桌面\忆记-v0.3.0.apk`(50.9MB)。可与 0.2.0 覆盖安装,数据保留。

**下一步(用户侧)**:
- 装到 vivo 看顶部是否还压状态栏、分界与开屏观感
- 配好 key 后跑 `flutter test test/ai_live_test.dart`,把模型行为这条也验掉
- 记满一周后看周报成稿质量(调 `prompts.dart` 的 `reportPrompt`)

**卡点**:无阻塞项。真机运行只能由用户完成(创建 AVD 需要管理员权限)。
