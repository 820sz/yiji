# 忆记 — 项目状态唯一事实源

> 安卓个人提升助手。把"记任务 → 写总结 → 交给 AI 帮你看"这条流程收进一个 app。
> 当前版本 **v0.5.0**。仓库 <https://github.com/820sz/yiji>

## 一、需求摘要

**目标用户**:xi283 本人(大三,四川,写作 + 健身 + 英语 + 家教,每天记任务、每周写总结)。

**核心存在物**:

| # | 用户看到什么 |
|---|---|
| 1 | 打开 app 就是今天的任务;点文字进编辑、点右边圆圈打钩 |
| 2 | 粘贴多行文本一次加完(行首 `-` `1.` `☑` 自动剥掉) |
| 3 | 长按进多选(颜色/删除/排序),右侧把手拖拽排序 |
| 4 | 日历月视图,点某天就地增删改;每天按完成度显示勾/半勾/叉 |
| 5 | 任务可设**系统通知提醒** |
| 6 | 进度推进条:可有目标值(进度条)也可没有(纯推进条);AI 从已完成任务自动量化推进 |
| 7 | 聊天:多会话侧边栏、思考强度与思考过程、流式、可传图片文件、带头像 |
| 8 | 周报/月报一键出稿,可复制分享 |
| 9 | 内置更新(从 GitHub Releases) |

**non-goals(明确不做)**:
1. 不做账号、不做云同步(纯本地)
2. 不读取手机里的原子笔记(安卓沙箱读不到别的 app 私有数据)

## 二、技术路线

| 项 | 选择 |
|---|---|
| 框架 | Flutter 3.44.7 + Dart 3.12.2 |
| 存储 | sqflite(SQLite),schema **v3** |
| AI | DeepSeek API,OpenAI 兼容格式;`thinking` + `reasoning_effort` |
| 结构化输出 | `response_format: json_object`(官方提示有概率返回空,已做一次重试) |
| 通知 | flutter_local_notifications + timezone |
| 更新 | GitHub Releases 公开仓库,无需 token |

**环境**:Android SDK 36 / JDK 21(Android Studio JBR)/ JAVA_HOME 已写入用户环境变量。

## 三、数据模型(schema v3)

```sql
tasks(id, day, text, done, completed_at, sort_order, created_at, color)
journals(id, day UNIQUE, text, updated_at)
conversations(id, title, created_at, updated_at)
messages(id, conversation_id, role, content, reasoning, created_at)
goals(id, title, unit, target /* 可空 */, period, direction, color, active, start_day, end_day, created_at)
progress_entries(id, goal_id, amount, day, note, task_id, source, created_at)
reminders(id, task_id, day, at, note, created_at)
```

**三条设计原则**:

1. **报告不落库**。周报/月报是对 tasks + journals 的投影,随时现算。
2. **目标当前值不落库**。由 progress_entries 按周期求和得出,不会出现"总数和明细对不上"。
3. **消息必须挂在会话下**。否则每次请求都拼进全部历史,AI 会提起你在这个对话里从没说过的事。

## 四、AI 的分工

| 角色 | 负责什么 | 为什么 |
|---|---|---|
| AI | **读懂**灵活表述("码字2k""码了2千字"是同一件事),并量化推进 | 只有模型能做语义匹配 |
| 用户 | **确认**建议后计入 | 进度条是判断自己有没有推进的依据,被猜错的数字污染比多看一眼糟糕得多 |
| 手动 | 随时可加/改/删进度 | AI 只是省事,不是唯一入口 |

匹配提示词里区分两种推进:**写了数量的按数量算;没写数量但"做一次就等于一个单位"的算 1**
(「健身(胸+三头)」→ 力量训练 +1 次)。同时**不许编造数字**。

## 五、v0.5.0:修掉的两个设计错误

### 1. AI"无中生有记忆"

用户反馈 AI 主动提起他从没在那个对话里说过的事,还照着提示词把谎圆下去。
根因在 `app_state.dart`:发请求时把**全局所有历史**拼进了上下文,
而消息表根本没有"会话"概念。**AI 不是编的,是我喂给它的。**

修法:v3 加会话维度,只发本会话历史;老数据归进"以前的对话"会话;
加会话侧边栏(否则历史等于被藏起来)。

### 2. 进度条是死的

三个原因叠加:

- 目标**必须有数字才建得出来**,「读这本书」这种没法预先量化的目标进不去
- `current` 是**全部历史的总和,从不按周期清零**——"每周 5 次"累积到 12 次后永远满着
- 提示词写着"没有具体数量的一律跳过",把「健身」这种挡在门外

修法:`target` 可空(没目标值就画纯推进条,对数增长)、当前值只统计本周期、
单位可留空、提示词支持"做一次算一个单位"。

## 六、测试与验证

| 命令 | 覆盖 | 结果 |
|---|---|---|
| `flutter analyze` | 静态检查 | **0 issue** |
| `flutter test` | 界面 / 会话 / 提醒 / 附件 / 更新器 / AI 客户端 | **122 passed** |
| `tool/sqltest` | SQL 数据层、周报聚合、v1→v3 迁移 | **65 passed** |
| `flutter test test/ai_live_test.dart` | 真实 API 行为 | 无 key,**跳过** |

合计 **187 个测试**。

### 真实 API 测试(待用户配 key 后跑)

```sh
$env:DEEPSEEK_API_KEY="sk-..."; flutter test test/ai_live_test.dart
```

覆盖只能靠真模型验的事:常规与灵活写法都算得出数量、
**"做一次算一个单位"的要算进去**(「健身」→力量训练 +1)、
**没有数字又不属于"做一次"的不许硬凑**、思考模式确实返回 `reasoning_content`、
周报确实按三个小标题出稿。没配 key 时整组跳过——**跳过不等于通过**。

### 数据层测试为什么在 `tool/sqltest` 独立包

桌面版 SQLite 会触发 Dart **native assets 编译**,而它在安卓打包时会失败并中断构建。
把这份依赖挪出 app 包后,构建链才干净。
`tool/sqltest/pubspec.yaml` 里指向 app 用了**绝对路径**:相对路径 `..` 被 pub 解析到了 `tool\`。

## 七、构建期踩到的坑

1. **pub 缓存与项目不同盘**导致 Kotlin 增量编译崩溃 → 已在 `gradle.properties` 关掉
   `kotlin.incremental`。
2. **`sqlite3` 触发 native assets** → 挪进独立测试包。
3. **`install_plugin` 停更、缺 AGP 8 的 `namespace`** → 弃用,自己在 MainActivity 写了安装逻辑。
4. **`flutter_local_notifications` 需要 core library desugaring** → 在 `build.gradle.kts` 打开
   并加 `desugar_jdk_libs`。
5. **`response.body` 中文乱码**(GitHub 不带 charset,http 包退回 Latin-1)→ 自己按 UTF-8 解
   `bodyBytes`。
6. **`.gitignore` 的 `/build/` 只匹配根目录** → 改成全局模式。

## 八、测试挖出来的真 bug(都已修)

| bug | 后果 |
|---|---|
| `SettingsScreen.initState` 里读 `AppScope` | **一开 app 就抛异常**(IndexedStack 启动时构建全部页签) |
| `_TaskEditorPage.initState` 里读 `AppScope` | 同上,打不开编辑页 |
| 带背景色的 `Container` 包 `ListTile` | 打钩水波纹永远看不见(框架断言) |
| 多行输入框放进 `Column` | 布局溢出(键盘弹起时更严重) |
| `TextEditingController` 提前 dispose | 弹层关闭动画期间报 used after disposed |
| 报告页在构建作用域里 `setState` | dirty widget in the wrong build scope |
| 思考强度面板 / 目标表单 | 矮屏上溢出 |
| **周报把"没完成的事"划掉** | 判断写反,**红绿验证过** |
| **`bootstrap()` 只读消息不读会话列表** | 重开 app 后历史对话像丢了,**红绿验证过** |
| 启动时不重排提醒 | 手机重启后提醒不再响 |
| `FilePicker.pickFiles` 没有 try/catch | 抛异常时静默冒泡,表现为"点了没反应" |

## 九、决策记录

| 日期 | 决策 | 理由 |
|---|---|---|
| 09-14 | 用 Flutter | 用户要原生 app;本机环境已备 |
| 09-14 | 报告不落库,按需重算 | 避免"报告和打卡数据不一致" |
| 09-14 | 用户自填 API key,存本机 | 不做服务端 |
| 09-25 | AI 只出建议,**用户确认后**才计入进度 | 进度条不该被猜错的数字污染 |
| 09-25 | 目标当前值不落库,由条目求和 | 避免总数与明细对不上 |
| 09-25 | 改名「忆记」,包名 `com.xi283.yiji` | 用户觉得「日拱」意义不明 |
| 09-26 | 界面文案一律短句,不放教学式说明 | 用户明确反馈那是内部提示词 |
| 09-26 | AI 头像跟随所配模型 | 配的是 DeepSeek 就该看到 DeepSeek |
| 09-28 | **消息按会话隔离** | 见第五节 |
| 09-28 | **目标值可空、当前值按周期统计** | 见第五节 |
| 09-28 | 打钩保留"点圆圈"快捷 | 一天几十次的动作,不给它加绕路 |
| 09-28 | 「待办」改名「任务」 | 用户要减少催促感 |
| 09-28 | `install_plugin` 弃用,自己写原生安装 | 停更依赖直接让构建失败 |

## 十、断点快照

**已发布**:v0.7.0(release tag `v7`),交付物 `桌面\忆记-v0.7.0.apk`(55.1MB),
与 GitHub release 资产字节一致(57,776,533 字节)。

版本线:

| 版本 | tag | 内容 |
| --- | --- | --- |
| 0.5.0 | `v5` | 会话隔离、进度按周期统计 |
| 0.6.0 | `v6` | 流式下载+进度条+重试;AI 量化改成通用语义(删掉提示词里的领域举例)、打钩自动同步、单位自动补全 |
| 0.7.0 | `v7` | 全软件 review 后修的一批 bug:附件真的发得出去、深色报告页可读、左滑删除不报错、总结不串台、提醒随任务删除/改期、目标值可清空、命中区 44px、DST 日期、controller 生命周期 |

**下一步(用户侧)**:
- 装机后重点验四件事:**附件能不能发出去**(v0.7.0 修的真 bug)、
  **AI 会不会把完成的任务算进推进条**、**自动更新的进度条与断线重试**、
  **深色模式下报告页读不读得清**
- 配好 key 后跑 `flutter test test/ai_live_test.dart`,把模型行为这条也验掉
  (没有 `DEEPSEEK_API_KEY` 时该测试自动跳过,提示词的实际效果目前只能靠用户实机反馈)

**发新版本**:`pwsh -File tool/release.ps1 -Version 0.7.1 -VersionCode 8`
(自动改版本、检查、测试、打包、推送、发 release)

**已知缺口**:
- 自动更新"下载 → 唤起安装器 → 装上"只有真机能验;v6 起加了流式进度、断线重试(3 次)、
  双地址退路与卡死超时,但下载链路的真实表现仍需实机确认
- 包是 debug 签名的:换正式签名后必须卸载重装(会丢数据)
- 提醒是非精确调度(`inexactAllowWhileIdle`),系统可能推迟几分钟
- 本机网络对 GitHub 的 HTTP/2 不通(`git push` 报 "Failed to connect ... port 443"),
  已把 `http.version=HTTP/1.1` 写进仓库配置
- 无法在本机验真实模型行为(没有 API key),涉及 AI 的判断只能由用户实机验证

### review 发现但**没修**的(低优先,已记录)

| 项 | 为什么先放着 |
| --- | --- |
| `progress_entries(task_id)` 缺索引、`goals()` 的全表 SUM 被丢弃、`refreshGoals` 每目标一次区间查询 | 现在的数据量(单机、几百条)完全无感;要加索引就得再动一次 schema 迁移,不值得冒这个险 |
| 排序模式下拖拽不出屏幕(内层 ReorderableListView 无滚动空间) | 要重构成"单个 ReorderableListView + 分界作 header",改动面大,得单独一版 |
| 逐天报告把"还没到期的任务"算进未完成,拉低完成率 | 涉及报告口径的定义,需要先定清楚想要哪种,再改 |
| 月报的小标题仍写「本周完成」 | 纯文案,顺手改不如和上面那条一起定 |
| `wipe()` 无事务且无人调用 | 死代码,没有被界面接上 |
| 局部刷新:流式期间整页仍会重建(`streamTick` 只覆盖了气泡本身) | 已消除"回答完成时的高度突变",进一步的逐帧优化收益有限 |
| 破坏性操作(删对话/删目标)没有二次确认 | 交互取向问题,想先问用户是否要加确认 |

