# 发一个新版本:一条命令搞定
#
# 用法(在项目根目录):
#   pwsh -File tool/release.ps1 -Version 0.4.1 -VersionCode 5 -Title "忆记 v0.4.1"
#
# 做的事:改 pubspec 版本 → 检查 → 跑测试 → 打包 → 提交推送 → 建 GitHub release。
#
# 为什么 tag 是 `v<versionCode>` 而不是 `v0.4.1`:
# 更新器要拿 versionCode 判断新旧(字符串比大小会把 0.10.0 判成比 0.9.0 旧),
# 而版本名放在 release 标题里。tag 里避免出现 `+`,因为它在下载链接里会被编码成 %2B。

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][int]$VersionCode,
    [string]$Title = "",
    [string]$NotesFile = "tool/release_notes.md",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
$repo = "820sz/yiji"
if ([string]::IsNullOrWhiteSpace($Title)) { $Title = "忆记 v$Version" }

Write-Host "=== 1/6 更新 pubspec 版本 ===" -ForegroundColor Cyan
$pubspec = "pubspec.yaml"
$content = Get-Content $pubspec -Raw
$content = $content -replace "(?m)^version: .*$", "version: $Version+$VersionCode"
[System.IO.File]::WriteAllText((Resolve-Path $pubspec), $content, (New-Object System.Text.UTF8Encoding($false)))
Select-String -Path $pubspec -Pattern "^version:" | ForEach-Object { $_.Line }

if (-not $SkipTests) {
    Write-Host "=== 2/6 静态检查 ===" -ForegroundColor Cyan
    & flutter analyze
    if ($LASTEXITCODE -ne 0) { throw "analyze 不通过,停下来" }

    Write-Host "=== 3/6 跑测试 ===" -ForegroundColor Cyan
    & flutter test
    if ($LASTEXITCODE -ne 0) { throw "app 测试不通过,停下来" }
    Push-Location "tool/sqltest"
    & flutter test
    $sqltestOk = $LASTEXITCODE -eq 0
    Pop-Location
    if (-not $sqltestOk) { throw "数据层测试不通过,停下来" }
} else {
    Write-Host "=== 2-3/6 跳过检查(指定了 -SkipTests)===" -ForegroundColor Yellow
}

Write-Host "=== 4/6 打包 ===" -ForegroundColor Cyan
& flutter build apk --release
if ($LASTEXITCODE -ne 0) { throw "构建失败" }
$apk = "build/yiji-$Version.apk"
Copy-Item "build/app/outputs/flutter-apk/app-release.apk" $apk -Force
Get-Item $apk | Select-Object Name, @{n = "MB"; e = { [math]::Round($_.Length / 1MB, 1) } }

Write-Host "=== 5/6 提交推送 ===" -ForegroundColor Cyan
git add -A
git commit -m "发布 v$Version`n`n$Title"
git push origin master

Write-Host "=== 6/6 建 release 并上传 ===" -ForegroundColor Cyan
$tag = "v$VersionCode"
# release 先建成草稿再补 asset:直接带上 asset 建,大文件上传一旦超时就只留下空 release。
gh release create $tag --repo $repo --title $Title --notes-file $NotesFile --draft
gh release upload $tag $apk --repo $repo --clobber
gh release edit $tag --repo $repo --draft=false --latest

Write-Host ""
Write-Host "完成:https://github.com/$repo/releases/tag/$tag" -ForegroundColor Green
Write-Host "已装的旧版本会在下次启动时看到这个更新。" -ForegroundColor Green
