# 忆记(com.xi283.yiji)— 工作交接

> 写给下一个接手的人(或下一个会话的 agent)。
> **这份文件是唯一现状源。** 里面每一条都标注了"怎么确认",不要凭叙述推断。
> 最后更新:2026-10-05,版本 **1.1.9+21**,HEAD `1b19763`。

---

## 0. 先读这一段:上一任 agent 犯的错,别重复

上一任在这上面烧掉了整整两个会话,反复"修好"又反复坏。教训按重要性排:

1. **不要在没有真实数据的情况下改代码。** "AI 发的图显示图不在了"修了 5 轮,
   前 4 轮都在猜(猜历史不带图、猜文件丢了、猜引用格式)。真实根因直到
   用户截图里那行诊断出现才确定。**先想办法让程序自己把数据吐出来,再动手。**
2. **"跑一堆测试全绿"不等于修好。** 有两类假验证反复出现:
   - **测试数据规模和真实不符**:下载那个 bug,测试用 4KB 假数据,真实包 62MB;
     假数据既小于拦截页量级又不像 APK,真实路径上两个致命问题一个都测不到。
   - **测试绕过了真实路径**:为了验"图能不能画出来",曾经自己挑了一步
     (`rootBundle` 读字节 + `imageCodec` 解码)来断言,全绿,而用户照样看到破图。
     **要验渲染就真的构建组件去渲染**,不能自己挑一步。
3. **改动要能被"红 → 绿 → 撤掉修复再变红"证明。** 这是唯一能证明测试真的抓得住的
   办法。上一任有几条测试即使把修复撤掉也照样绿(说明它测的不是那个 bug)。
4. **不要用返回键(pop)通道去做页签切换。** 曾经在根路由加 `PopScope(canPop:false)`,
   结果关侧边栏的 `Navigator.maybePop()` 被它拦下,一次性弄坏了侧边栏、
   所有弹层的"点空白处关闭"、以及聊天页滑动。**这个坑很贵,已经踩过。**
5. **测试里的日期不要写死。** `goal_match_test` 有几条写死 `2026-09-29`,
   而窗口按"今天所在那周"算——日期一走出版本就集体烂掉(实际发生过,9 条一起红)。

---

## 1. 项目速览

| 项 | 值 |
|---|---|
| 项目目录 | `D:\Projects\yiji` |
| 仓库 | https://github.com/820sz/yiji(**公开**,默认分支 `master`) |
| 包名 | `com.xi283.yiji`,应用名「忆记」 |
| 技术栈 | Flutter 3.44.7 / Dart 3.12.2;SQLite(sqflite)schema **v6**;shared_preferences |
| 当前版本 | `1.1.9+21`(`pubspec.yaml`) |
| 最新发布 | tag `v21`,https://github.com/820sz/yiji/releases/tag/v21 |
| 构建 | `$env:JAVA_HOME='C:\Program Files\Android\Android Studio\jbr'; flutter build apk --release` |
| AI | DeepSeek(OpenAI 兼容):`https://api.deepseek.com/chat/completions`;模型 `deepseek-flash` / `deepseek-v4-pro` / `deepseek-v4-flash` |
| API key | 在 gitignored 的 `.env` 里(用户自己的 key,有额度) |

**大文件预警**(改之前有心理准备):
`chat_screen.dart` 2585 行 / `app_state.dart` 1920 行 /
`progress_screen.dart` 1785 行 / `report_screen.dart` 851 行。

---

## 2. 怎么验证(照抄即可)

```powershell
cd D:\Projects\yiji

# 静态检查,必须 0 issue
flutter analyze

# 顶层测试(28 个测试文件)
flutter test

# 数据层测试(真实 SQLite,另一个 pubspec)
cd tool\sqltest; flutter test; cd ..\..
```

**当前基线(2026-10-05,已确认)**:`flutter analyze` 无问题;
顶层 **276 条通过 / 7 条跳过**(跳过的是需要真实 API 的,设计如此);
数据层 **78 条通过**。

真实 API 测试默认跳过,手动开(会花钱):
```powershell
$env:DEEPSEEK_API_KEY="sk-..."; flutter test test/ai_live_test.dart
$env:MEME_LIVE="1";    flutter test test/meme_live_test.dart
$env:SEARCH_LIVE="1";  flutter test test/search_live_test.dart
$env:VISION_LIVE="1";  flutter test test/vision_probe_test.dart   # 证明模型能识图
$env:DATE_LIVE="1";    flutter test test/date_context_live_test.dart
$env:UPDATE_LIVE="1";  flutter test test/update_live_test.dart    # 下载 62MB,慢
```

---

## 3. 发布流程(网络有坑,按这个顺序)

**大陆网络现状**:`github.com` **经常连不上**;`api.github.com` 和
`uploads.github.com` 通常能通。所以**不要用 `gh release create`**(它走 github.com),
用 API 直传:

```powershell
cd D:\Projects\yiji

# 1) 版本号 +1(pubspec.yaml),构建
$env:JAVA_HOME='C:\Program Files\Android\Android Studio\jbr'
flutter build apk --release
Copy-Item build\app\outputs\flutter-apk\app-release.apk build\yiji-1.1.9.apk

# 2) 核对版本号(必须,忘 bump 会让用户白装)
& 'C:\Users\xi283\AppData\Local\Android\Sdk\build-tools\36.0.0\aapt2.exe' dump badging build\yiji-1.1.9.apk | Select-String 'package:'

# 3) 推送代码(可能被重置,重试几次)
git -c http.version=HTTP/1.1 push origin master
git tag -f v21; git -c http.version=HTTP/1.1 push -f origin v21

# 4) 用 API 建 release(见 tool/ 里已有脚本痕迹;tag 用 v<versionCode>)
#    POST https://api.github.com/repos/820sz/yiji/releases
#    Header: Authorization: token <gh auth token>
#    Body: {"tag_name":"v21","name":"忆记 v1.1.9","body":"<release notes>"}

# 5) 上传 APK
#    POST https://uploads.github.com/repos/820sz/yiji/releases/<id>/assets?name=yiji-1.1.9.apk
#    Content-Type: application/vnd.android.package-archive
#    --data-binary @build\yiji-1.1.9.apk

# 6) 确认 app 能看到(它查的就是这个接口)
curl -s -H "User-Agent: yiji" https://api.github.com/repos/820sz/yiji/releases/latest
```

**tag 约定**:`v<versionCode>`(如 versionCode 21 → `v21`)。
**发布说明**写在 `tool/release_notes.md`,release body 用它的内容。
**app 内更新**的下载源已在代码里配了 5 个 GitHub 中转(见 `kGithubMirrors`)。

---

## 4. 硬约束(违反会出事)

1. **绝不要用 PowerShell 的 `-replace` / `Set-Content` / 文本管道改写 Dart 源码或
   JSON** —— UTF-8 会被按 GBK 处理,中文全变乱码,而且**会静默写坏**
   (`\r\n` 会变成字面量、引号会丢)。只用 `read` / `edit` / `write` 工具。
   *这条已经踩过两次:一次把测试文件的注释写成字面 `\r\n`,一次让 JSON 校验假通过。*
2. **不要用 `taskkill` / `Stop-Process` / `pkill` 杀 node 或本机服务**(用户铁律)。
3. **改数据库**:`dbVersion` 必须 +1,迁移只能**新增**;`tool/sqltest` 要加迁移测试。
4. **每次发版必须 bump `pubspec.yaml` 的 version**(忘 bump = 用户白装)。
5. **测试里不要依赖真实时钟/平台通道**:
   - `TestWidgetsFlutterBinding` 下**所有真实 HTTP 会返回 400 空体**(看起来像限流,别被骗);
   - widget 测试里 `rootBundle.loadString` 可能**永远不返回**(不报错也不完成);
   - `path_provider` 通道不响应 → 目录查询挂住。要用 `ChatImages.pinDirectoryForTest(dir)`
     注入真目录(注意:它**必须真的建出 `chat_images/` 子目录**,否则 `save` 静默失败)。

---

## 5. 这一轮用户列的问题:状态

用户的 7+8 组需求。**标注"✅ 已验证"的都有测试;没标的请自己确认。**

### 5.1 聊天 / 表情包(用户最不满的一块)

| 问题 | 状态 | 说明 |
|---|---|---|
| AI 要看得到用户发的图 | ✅ 有测试 | `meme_vision_test.dart`:历史里的图会重新读出来作为多模态发过去 |
| AI 主动发图能渲染出来 | ⚠️ **不确定** | 见下方 §6.1,这是**最需要接手人验证**的一条 |
| 用户自添加表情包 | ✅ | 表情包面板标题栏「+」→ 选图 → 裁方 → **手填描述**(描述必填,AI 靠它挑图) |
| 表情包面板 | ✅ | `lib/ui/meme_sheet.dart` |
| 聊天栏锁死最底层 | ✅ 有红绿验证 | `chat_interaction_test.dart` → "发完之后列表还能往上翻,不会被拽回底部" |
| 切对话跳任务页 | ✅ 有测试 | 同上文件,"切换对话:留在聊天页,不跳到任务页" |
| 点思考过程乱串 | ✅ 有测试 | 同上,"点思考过程:展开收起,不改动整页布局" |
| 列表卡帧 | ⚠️ 部分 | 已把 `SelectionArea` 移进条目、加深度判断;真机手感未确认 |
| 思考区固定高度+自动收起 | ✅ | `ReasoningPanel`,`ChatMetrics.reasoningMaxHeight = 170` |

### 5.2 其他各页

| 问题 | 状态 |
|---|---|
| 进度:AI 重复计算 / 无日期概念 | ✅ 待办带日期 + 声明"列表里都是没算过的";`date_context_live_test.dart` 真实接口验证 |
| 进度:自选范围 + 今天 | ✅ 弹层有「今天」+「自选起止日期」 |
| 进度:手动重置(重置进度 / 重设任务) | ✅ 进度页「重置」菜单;两个契约各有测试 |
| 日历:显示当月感想 | ✅ 默认折叠,可展开(用户要求"默认折叠收起") |
| 日历:✓ 标记太小 | ✅ 12 → 17 |
| 日历:月份切换动画 | ✅ `AnimatedSwitcher` |
| 日历:删想法 | ✅ 列表项删除按钮 + 长按 |
| 日历底部:状态曲线 | ✅ `lib/ui/status_curve.dart`;纵轴固定 0~100%,没安排的那天断开 |
| 周报/月报:流式思考 + 自行打字调整需求 | ✅ 思考块 + 成稿区输入框 |
| 今日想法:配照片 | ✅ schema v6,`journals.photos` |
| 今日想法:分享给 AI | ✅ 选对话 → 附件悬在输入框上方,**不自动发** |
| 个人名片放大 | ✅ 头像 58→68 |
| 退出动画 + 自定义语录 | ✅ `lib/ui/farewell.dart`;入口在「我的 → 退出忆记」 |
| 内置更新 | ⚠️ 不确定 | v1.1.3 改成并发竞速 + 写盘 + 5 分钟预算;此后没有再真机验证过 |

---

## 6. 未解决 / 需要接手人做的

### 6.1 ⚠️ AI 主动发的那张图,仍然可能显示「图不在了」(最高优先)

**用户最后一次反馈(1.1.7)**:AI 回复里的图仍是「图不在了」,诊断框给出:

```
引用:asset:memes/sad/1786034599038.webp
按文件名「1786034599038.webp」在磁盘和内置图库里都没找到
```

**已经查清的事实(不要重复查)**:
- 仓库里 `assets/memes/index.json` 是 **108 条**,磁盘上 **108 个文件**,一一对应,无缺失。
- APK 里也是 108 个文件 + 108 条索引,严丝合缝。
- 用户机器上两套 dsh 图库(`.dsh\meme-packs\dafeiyu-desktop`、插件内置包)**都没有**
  这些 id。
- `loadUserMemes()` 会**过滤掉文件不存在的条目**,所以设备上的库也不该有这些坏引用。

**结论**:这几个引用**在任何数据源里都不存在**。上一任没能解释它们从哪来。

**1.1.9 已经做的规避**(不能确认是否解决,因为用户还没反馈):
AI 挑到表情包后,把**字节直接以 data URL 写进消息**(`_memeLineFor` in `app_state.dart`,
`ChatImage.isInline` / `inlineBytes` in `chat_images.dart`)。这样渲染**不需要查任何路径**,
"找不到"从结构上不可能。

**接手人要做**:
1. 让用户装 1.1.9,再让 AI 发一次图,**确认是否还出现「图不在了」**。
2. 如果**还有**:占位框会显示引用和原因,而且**点一下能复制**。拿到那串字符串,
   就能确定是"内联没生效"还是"退回了引用"。
3. 顺带查清:如果 AI 消息里出现的是 `asset:memes/...` 且文件不存在,
   那 `_pickMeme` 返回的 `Meme` 就是从某个**非内置**来源来的——
   在 `_pickMeme` 里加一行日志打印 `library.memes.length` 和 `meme.fromUser`
   就能定性。**别再靠推理。**

### 6.2 内置更新:真机未验证

v1.1.3 之后没在真机点过更新。风险点:
- 5 个中转源随时可能失效(`kGithubMirrors`),要重测;
- 62MB 包 + 慢网络,超时设在 5 分钟,偏紧可调;
- 有一条 `test/update_live_test.dart`(需要 `UPDATE_LIVE=1`)可以真的跑一次下载。

### 6.3 用户明确说过"问题不止我说的那些"

用户原话:"我上一轮都说了,问题一大堆不止我说的那些"。**没有逐条追问过**。
接手时应该主动问一次完整清单,而不是只做文档里这批。

### 6.4 历史坏消息

老消息里那些引用指向不存在的文件,内联也追溯不了,会继续显示带诊断的占位。
**新发的图不会坏。** 这是已知取舍,用户尚未表态是否要清理。

---

## 7. 关键实现位置(找东西用)

| 想改什么 | 去哪 |
|---|---|
| 聊天页(气泡/滚动/输入区/思考块) | `lib/ui/chat_screen.dart` |
| 聊天状态(发送/落库/挑图/历史带图) | `lib/state/app_state.dart`(`sendChat` / `commitAssistantMessage` / `_pickMeme`) |
| 图片存储与解析(引用、data URL、目录) | `lib/data/chat_images.dart` |
| 表情包挑图(闭集选择) | `lib/data/meme_directive.dart` + `MemeLibrary`(在 `chat_images.dart`) |
| 表情包面板 + 添加入口 | `lib/ui/meme_sheet.dart` |
| 进度页 + AI 同步 + 范围选择 + 重置 | `lib/ui/progress_screen.dart` |
| 周报/月报 | `lib/ui/report_screen.dart` |
| 日历 + 状态曲线 + 当月想法 | `lib/ui/calendar_screen.dart` + `lib/ui/status_curve.dart` |
| 今日想法(照片/分享) | `lib/ui/today_screen.dart` + `lib/ui/task_sheets.dart` |
| 名片 | `lib/ui/identity_card.dart` |
| 退出语录 | `lib/ui/farewell.dart` + `lib/ai/settings_store.dart` |
| 提示词 | `lib/ai/prompts.dart` |
| 内置更新 | `lib/update/app_updater.dart` + `lib/update/apk_installer.dart` + `android/.../MainActivity.kt` |
| 数据库与迁移 | `lib/data/database.dart` + `lib/data/sqlite_record_store.dart` |
| 任务看板(上一任的备忘) | `TASKS.md` |

---

## 8. 上一任没做好的地方(供参考,不必照抄)

- 反复在同一个 bug 上"猜-改-发版",没有先拿到数据。
- 一次改动牵动多条链(改渲染 → 坏了侧边栏;改滚动 → 锁死列表)。
  **改之前先想清楚这条链上还有谁依赖它。**
- 为了"让测试通过"而调整断言,而不是先确认实现是否正确
  (曾在没搞清为什么的情况下把断言从 `data:image/` 放宽成 `![图]`)。
  放宽之前要能说清**为什么**原来的断言不成立。
