# 忆记(com.xi283.yiji)— 工作交接

> 写给下一个接手的人(或下一个会话的 agent)。
> **这份文件是唯一现状源。** 里面每一条都标注了"怎么确认",不要凭叙述推断。
> 最后更新:2026-10-07,版本 **1.1.11+23**,HEAD `37c3dbd`。

---

## 0. 先读这一段:前面几任犯的错,别重复

这个项目在同一个 bug 上烧过整整两个会话,反复"修好"又反复坏。教训按重要性排:

1. **不要在没有真实数据的情况下改代码。** "AI 发的图显示图不在了"修了 5 轮,
   前 4 轮都在猜(猜历史不带图、猜文件丢了、猜引用格式)。**先想办法让程序自己
   把数据吐出来,再动手。** 用户截图里那行诊断就是那个转折点。
2. **"跑一堆测试全绿"不等于修好。** 两类假验证反复出现:
   - **测试数据规模和真实不符**:下载那个 bug,测试用 4KB 假数据,真实包 62MB;
   - **测试绕过了真实路径**:为了验"图能不能画出来",自己挑一步
     (`rootBundle` 读字节 + `imageCodec` 解码)来断言,全绿,而用户照样看到破图。
     **要验渲染就真的构建组件去渲染**,不能自己挑一步。
3. **改动要能被"红 → 绿 → 撤掉修复再变红"证明。**
4. **不要用返回键(pop)通道去做页签切换。** 曾经在根路由加 `PopScope(canPop:false)`,
   一次性弄坏了侧边栏、所有弹层的"点空白处关闭"、以及聊天页滑动。这个坑很贵。
5. **测试里的日期不要写死。** 窗口按"今天所在那周"算,写死日期会集体烂掉。
6. **(新)探针也有样本量问题。** `meme_format_probe_test` 打了 6 次真接口,
   **0 次复现**"模型自己写图片标记"——但用户截图证明它会发生。概率性行为
   要用**结构性**的修法兜住(落库前归一化),不能靠"多跑几次看看"。
7. **(新)一条消息里的证据要看**位置**:界面把图片画在正文**上方**,
   所以"破图在文字上面"并不说明模型把它写在前面。这个误判过一次。
8. **(新,最贵的一条)你给模型看的任何"格式",它都会当成"动作"照抄。**
   为了让模型看懂"他发的图",历史里的图片行被换成 `[他发的图: 描述]`;
   结果模型要发图时就照抄了一行 `[我发的图: 描述]`——那只是一行文字,
   用户什么图都收不到。**教训有两层**:
   - 模型侧的措辞要写成**旁白**(括号陈述),不要写成看起来可执行的标记;
   - 光改措辞不够,**解析层必须把可能的仿写也认下来**(见 §6.5),
     否则下一次它换个写法,用户又看到"AI 说发了图但没有图"。

---

## 1. 项目速览

| 项 | 值 |
|---|---|
| 项目目录 | `D:\Projects\yiji` |
| 仓库 | https://github.com/820sz/yiji(**公开**,默认分支 `master`) |
| 包名 | `com.xi283.yiji`,应用名「忆记」 |
| 技术栈 | Flutter 3.44.7 / Dart 3.12.2;SQLite(sqflite)schema **v6**;shared_preferences |
| 版本 | `1.1.11+23`(`pubspec.yaml`) |
| 最新发布 | tag `v23`(1.1.11);上两个 `v22`(1.1.10)、`v21`(1.1.9) |
| 构建 | `$env:JAVA_HOME='C:\Program Files\Android\Android Studio\jbr'; flutter build apk --release` |
| AI | DeepSeek(OpenAI 兼容):`https://api.deepseek.com/chat/completions`;模型 `deepseek-flash` / `deepseek-v4-pro` / `deepseek-v4-flash` |
| API key | 在 gitignored 的 `.env` 里(第 9 行 `DEEPSEEK_API_KEY=`);`gh auth token` 可用(发布要用) |

**大文件预警**(改之前有心理准备):
`chat_screen.dart` 2700 行 / `app_state.dart` 1970 行 /
`progress_screen.dart` 1785 行 / `report_screen.dart` 851 行。

**版本库的一处历史遗留**:1.1.9 的源码当时**没提交**,一直挂在工作区,
只有 APK 发出去了。2d3341b 已经把它一起落库。

---

## 2. 怎么验证(照抄即可)

```powershell
cd D:\Projects\yiji

flutter analyze            # 必须 0 issue
flutter test               # 顶层测试
cd tool\sqltest; flutter test; cd ..\..   # 数据层(真实 SQLite,另一个 pubspec)
```

**当前基线(2026-10-07,已确认)**:`flutter analyze` 无问题;
顶层 **305 条通过 / 8 条跳过**(跳过的是需要真实 API 的,设计如此);
数据层 **78 条通过**。

真实 API 测试默认跳过,手动开(会花钱):
```powershell
# .env 里的 key 要自己读出来塞进环境变量(注意 .env 是 UTF-8,用 ReadAllText)
$t=[IO.File]::ReadAllText('D:\Projects\yiji\.env'); $l=($t -split "`r?`n" | ? { $_ -match '^\s*DEEPSEEK_API_KEY\s*=' })[0]
$env:DEEPSEEK_API_KEY = ($l -split '=',2)[1].Trim()

flutter test test/ai_live_test.dart
$env:MEME_LIVE="1";    flutter test test/meme_live_test.dart
$env:MEME_PROBE="1";   flutter test test/meme_format_probe_test.dart   # 模型会不会自己写图片标记
$env:SEARCH_LIVE="1";  flutter test test/search_live_test.dart
$env:VISION_LIVE="1";  flutter test test/vision_probe_test.dart
$env:DATE_LIVE="1";    flutter test test/date_context_live_test.dart
$env:UPDATE_LIVE="1";  flutter test test/update_live_test.dart         # 下载 62MB,慢
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
Copy-Item build\app\outputs\flutter-apk\app-release.apk build\yiji-1.1.10.apk

# 2) 核对版本号(必须,忘 bump 会让用户白装)
& 'C:\Users\xi283\AppData\Local\Android\Sdk\build-tools\36.0.0\aapt2.exe' dump badging build\yiji-1.1.10.apk | Select-String 'package:'

# 3) 推送代码(可能被重置,重试几次)
git -c http.version=HTTP/1.1 push origin master
git tag -f v22; git -c http.version=HTTP/1.1 push -f origin v22

# 4) 用 API 建 release(tag 用 v<versionCode>),body 用 tool\release_notes.md
#    POST https://api.github.com/repos/820sz/yiji/releases
#    Header: Authorization: token <gh auth token>;  $tok = gh auth token
#    Body: {"tag_name":"v22","name":"忆记 v1.1.10","body":"<release notes>"}

# 5) 上传 APK
#    POST https://uploads.github.com/repos/820sz/yiji/releases/<id>/assets?name=yiji-1.1.10.apk
#    Content-Type: application/vnd.android.package-archive
#    --data-binary @build\yiji-1.1.10.apk

# 6) 确认 app 能看到(它查的就是这个接口)
curl -s -H "User-Agent: yiji" https://api.github.com/repos/820sz/yiji/releases/latest
```

**tag 约定**:`v<versionCode>`(如 versionCode 22 → `v22`)。
**发布说明**写在 `tool/release_notes.md`,release body 用它的内容。
注意 app 内那个更新弹层只显示「摘要 + 最多 5 条要点」:`-` 开头的是要点,
开头第一段是摘要,所以那份说明要按这个格式写,不要写成大段散文。
**app 内更新**的下载源已在代码里配了 5 个 GitHub 中转(见 `kGithubMirrors`)。

---

## 4. 硬约束(违反会出事)

1. **绝不要用 PowerShell 的 `-replace` / `Set-Content` / 文本管道改写 Dart 源码或
   JSON** —— UTF-8 会被按 GBK 处理,中文全变乱码,而且**会静默写坏**。
   只用 `read` / `edit` / `write` 工具。(踩过两次。)
   顺带:`[IO.File]::ReadAllText` 这类 .NET 静态调用用**绝对路径**,
   它不认 PowerShell 的当前位置。
2. **不要用 `taskkill` / `Stop-Process` / `pkill` 杀 node 或本机服务**(用户铁律)。
3. **改数据库**:`dbVersion` 必须 +1,迁移只能**新增**;`tool/sqltest` 要加迁移测试。
4. **每次发版必须 bump `pubspec.yaml` 的 version**。
5. **测试里不要依赖真实时钟/平台通道**:
   - `TestWidgetsFlutterBinding` 下**所有真实 HTTP 会返回 400 空体**;
   - widget 测试跑在**假时钟**里:真实文件/资源 I/O **不会自己完成**,
     要 `await tester.runAsync(() => Future.delayed(...))` 来回放真实时间才能走完 I/O 链;
   - `MemeLibrary.load()` 在 widget 测试里可能永不返回 → 用
     `MemeLibrary.primeForTest(...)` 塞一份进去,别等它;
   - 要用真目录时 `ChatImages.pinDirectoryForTest(dir)`(它**必须真的建出
     `chat_images/` 子目录**,否则 `save` 静默失败)。

---

## 5. 用户列的问题:状态

### 5.1 2026-10-06(第一轮三条,已发布在 1.1.10)

| # | 问题 | 状态 | 说明 |
|---|---|---|---|
| 1 | 表情包反反复复修不好,"怀疑录入的图有问题,推倒重来" | ✅ 根因已定死并修掉 | 见 §6.1。**图库没问题**(108 索引 ↔ 108 文件),是模型自己写了一行图片标记 |
| 2 | 聊天滑动屏闪、掉帧、卡帧(有图时明显) | ✅ 根因已定位并修 | 见 §6.2:每帧重新解码 |
| 3 | 思考过程 UI 改成参考图的样子(浅蓝底 + 鲸鱼 + 时间) | ✅ | `ReasoningPanel`:「深度求索中,用时 X」/「已深度思考,用时 X」 |

### 5.2 2026-10-06 深夜(第二轮三条,已发布在 1.1.11)

| # | 问题 | 状态 | 说明 |
|---|---|---|---|
| 1 | 自己添加的图在表情包库里显示不出来(发出去正常),AI 也调不到 | ✅ | 见 §6.4:面板用 `Image.asset` 画私有目录的图 + AI 那份清单没刷新 |
| 2 | "AI 发表情包还是有问题"(截图里 AI 写 `[我发的图: 描述]`,没有图) | ✅ | 见 §6.5:模型照抄了模型侧的措辞,解析层以前不认 |
| 3 | 思考完毕、回复吐出来时掉帧闪烁 | ⚠️ 部分 | 见 §6.6:落库空档 + 自动收起动画两处已修;真机手感待用户确认 |

用户还说过"问题一大堆不止我说的那些",**问过两次**,他给的就是上面这些。
下次接手时仍值得再确认一遍还有没有别的。

---

## 6. 这一轮的技术结论

### 6.1 ✅ 「图不在了」的根因(已结案)

**证据**:用户截图里的占位框写着

```
引用:瘫成一团趴在鲸鱼抱枕上,眼都睁不开
磁盘上没这个文件,图库里也没有同名的内置图
```

**那不是路径,是 `assets/memes/index.json` 里某一条的 caption 原文**
(`daily/1785381947299.webp`)。

而程序自己写进消息的图片行**只有两种形态**:内联 dataURL,或 `asset:memes/...`
(见 `Meme.messageRef`)。**两者都不可能是 caption** ⇒ 那一行是**模型自己写的**:
提示词里给它看过 `![图] <引用> | <描述>` 这个格式(用来说明"你收到的图长什么样"),
它自己想发图时就照着写了一行 `![图] <一句描述>`。渲染层只认引用,查不到,显示成破图。

前几轮全都在修"引用为什么查不到"——修错了对象。

**为什么不定成"模型偶尔不听话"就完了**:那是概率行为,拦不住。所以按结构修:

1. `lib/data/image_lines.dart`(**这一轮新增的核心**):
   - `normalizeImageLines`:落库前把图片行归一化成自包含 dataURL;
     **认不出来的整行删掉**——历史里不再出现画不出来的图片行;
   - `projectForModel`:给模型看的历史里,图片行换成 `[他发的图:<描述>]` /
     `[我发的图:<描述>]`(不带标记、不带 base64);
   - `inlineRefFor`:引用 → dataURL,全程 3 秒超时(别把落库挂住)。
2. `ChatImage.parse`:**一句描述能反查回那张图**(`MemeLibrary.matchByCaption`,
   结果带缓存)。所以**已经坏掉的老消息也会重新画出来**。
3. `ChatImages.bytesOf` 的兜底改成 `MemeLibrary.findByRef`(文件名/短 id/描述都认)。
4. 提示词:明文规定发图只走 `[表情: ...]`,并**删掉原来那个 `![图] ...` 举例**
   ——那个例子本身就是模仿源。

**怎么自己复核**:`test/image_lines_test.dart`(单元 + 真实渲染)、
`test/conversation_test.dart` 里"模型自己写的那行 ![图] 不会留在消息里"、
`test/meme_format_probe_test.dart`(真接口探针,6 次里 0 次复现,样本量有限)。

### 6.2 ✅ 滑动卡帧闪烁:每帧重新解码

`ChatImage.inlineBytes` 每次调用都 `base64Decode` 出一个**新的 `Uint8List`**,
而 `Image.memory` 认图的键是**字节对象的身份** ⇒ 气泡每重建一次,Flutter 都当成
"另一张新图":重新解码、重新走一遍加载态。滚动时一屏几张图,就是掉帧 + 闪。

修法:`inlineBytes` 按引用串缓存(上限 60 条,FIFO);所有缩略图加 `cacheWidth`
按**显示尺寸**解码(表情包只画 140 宽就别解 1080,相册照片同理)。
用例:`image_lines_test.dart` 里断言两次调用返回**同一个实例**。

### 6.3 思考过程那一栏

参考用户给的 DS 样式:`ReasoningPanel` 现在是一块浅蓝底(深色模式低明度蓝)、
左边一枚鲸鱼(`WhaleMark`,在 `ai_avatar.dart`)、一行蓝字:
进行中「深度求索中,用时 X 分 Y 秒」,完成后「已深度思考,用时 X 秒」。
用时**不挂定时器**(流式分片本来就在重建,一个每秒唤醒的定时器会让
`pumpAndSettle` 永远不收敛);历史消息没有记录时只说状态,不编数字。
窄屏会超宽,已经改成 `Expanded` + 省略号(这条是截图预览时当场发现的)。

### 6.4 ✅ 用户自己加的表情包:三个独立的坑(1.1.11)

1. **面板里显示成破图**(发出去却正常):`meme_sheet.dart` 对每一张都走
   `Image.asset('assets/${meme.assetPath}')`,而用户加的图**不在安装包里**,
   只有文件名对得上 → 破图图标。改成 `_UserMemeThumb`:从私有目录读字节,
   走 `ChatImages.cachedMemeBytes`(带缓存,免得滚动时重复读盘/重复解码)。
2. **AI 挑不到**:提示词里那份候选清单是 `AppState._memeCatalog`,**启动时算一次的
   另一份拷贝**,和图库缓存不是一回事。用户加完图只刷新了图库,模型手里的清单
   还是旧的 → 它根本不知道有新图。修法:`AppState.refreshMemeCatalog()`,
   面板加完图后调用。
3. **清单每类只列 6 张**(`catalogPrompt(perTag: 6)`):用户自添加的全落在 `mine`
   这一类,加到第 7 张之后前面几张就从候选里消失。改成**用户那批一张都不截**。

顺带修掉一个同源的小洞:用户自添加的表情包有字节、没引用,走的是"落盘拿引用"
那条分支,而那条分支**把 `memeCaption` 丢了** → 消息里只剩一个文件名,模型少了
一条情绪线索。已补上。

### 6.5 ✅ 模型照抄了模型侧的措辞(1.1.11)

用户截图里 AI 的回复末尾是 `[我发的图:抱着胳膊撅嘴赌气,理直气壮说没吃饱]`,
**图没有出来**。那不是路径也不是指令——它是 1.1.10 给模型看的历史投影格式
(`[我发的图: 描述]`),模型看多了就当成"发图的方式"照抄了下来。

两处一起改才算修住:
- `projectForModel` 改成**括号旁白**:`（他发了一张图: 描述）` /
  `（你上一轮回了一张图: 描述）`——读起来是叙述,不像可执行的标记;
- `meme_directive.stripMemeDirective` **也认仿写**:`[我发的图: …]` /
  `[他发的图: …]`(必须紧跟冒号)一律按"要这张图"处理,描述走同一条挑图链路。
  所以就算模型下次还这么写,图也会真的发出来,而且那一行不会显示给用户。

**这是这个项目最值得记住的一条**:模型侧的措辞不是"说明文字",是"示范动作"。
改措辞时必须同时在解析层兜住仿写。

### 6.6 ⚠️ 回复吐出来时的掉帧闪烁(1.1.11 修了两处,待真机确认)

- **落库空档**:`commitAssistantMessage` 以前一进函数就把流式正文清掉,而挑图、
  读字节(资源/base64)、写库全是异步的——那几百毫秒里**整条回答不在屏幕上**,
  然后才蹦出来。现在正文留到正式消息进列表才收(`_finishStreaming`,
  并且用 `raw` 比对,免得把期间新开的一轮抹掉)。
  用例:`test/stream_state_test.dart` 的「落库期间"正在生成"的那一份不能先消失」。
- **自动收起的动画**:思考结束自动收起正好发生在正文开始长的那一刻,两个动画
  叠在一起就是掉帧。自动收起改成**一帧收完**(`_instantCollapse`),用户手动
  点开/收起仍然带动画。
- **贴底滚动**:流式时每个分片都会排一次 `jumpTo`,同一帧里连着好几次。
  现在合并成每帧一次(`_bottomPending`)。
- 还没做的:真机 profile。如果用户还说卡,下一步是 `flutter run --profile` +
  DevTools 的 frame chart,看是 layout 还是 raster,别再猜。

---

## 7. 还没解决的 / 需要接手人做的

### 7.1 ⚠️ 内置更新:真机仍未验证
v1.1.3 之后没在真机点过更新。风险点:5 个中转源随时可能失效(`kGithubMirrors`);
62MB 包 + 慢网络,超时设在 5 分钟,偏紧可调。有 `test/update_live_test.dart`
(需要 `UPDATE_LIVE=1`)可以真的跑一次下载。

### 7.2 老消息里那些坏引用
引用指向不存在的文件、也没有描述可查的那些,**仍然显示带诊断的占位**——
它们没救了(信息本来就不在)。有描述的现在能画出来。用户还没表态是否要清理。

### 7.3 用户可能还有未列的问题
问过一次,他给的是三条(都做完了)。下次交接时再确认一遍。

---

## 8. 关键实现位置(找东西用)

| 想改什么 | 去哪 |
|---|---|
| 聊天页(气泡/滚动/输入区/思考块) | `lib/ui/chat_screen.dart` |
| 聊天状态(发送/落库/挑图/历史带图) | `lib/state/app_state.dart`(`sendChat` / `commitAssistantMessage` / `_pickMeme`) |
| **图片行怎么解析/归一化/给模型看** | `lib/data/image_lines.dart` |
| 图片存储与解析(引用、data URL、目录、图库) | `lib/data/chat_images.dart` |
| 表情包挑图(闭集选择) | `lib/data/meme_directive.dart` + `MemeLibrary`(在 `chat_images.dart`) |
| 表情包面板 + 添加入口 | `lib/ui/meme_sheet.dart` |
| AI 头像 / 鲸鱼标志 | `lib/ui/ai_avatar.dart` |
| 进度页 + AI 同步 + 范围选择 + 重置 | `lib/ui/progress_screen.dart` |
| 周报/月报 | `lib/ui/report_screen.dart` |
| 日历 + 状态曲线 + 当月想法 | `lib/ui/calendar_screen.dart` + `lib/ui/status_curve.dart` |
| 今日想法(照片/分享) | `lib/ui/today_screen.dart` + `lib/ui/task_sheets.dart` |
| 提示词 | `lib/ai/prompts.dart` |
| 内置更新 | `lib/update/app_updater.dart` + `lib/update/apk_installer.dart` + `android/.../MainActivity.kt` |
| 数据库与迁移 | `lib/data/database.dart` + `lib/data/sqlite_record_store.dart` |

---

## 9. 前面几任没做好的地方(供参考)

- 反复在同一个 bug 上"猜-改-发版",没有先拿到数据。
- 一次改动牵动多条链(改渲染 → 坏了侧边栏;改滚动 → 锁死列表)。**改之前先想清楚
  这条链上还有谁依赖它。**
- 为了"让测试通过"而调整断言,而不是先确认实现是否正确。
- (这一轮的补充)修完没有把根因写清楚,于是下一个接手的人只能从"引用查不到"
  这个错误的方向重新开始。**结论要落在文件里,不要只落在对话里。**
