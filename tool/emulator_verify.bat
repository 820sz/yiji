@echo off
REM 用计划任务启动,脱离 dsh 作业的进程树,不会被连带回收。
set JAVA_HOME=C:\Program Files\Android\Android Studio\jbr
set SDK=%LOCALAPPDATA%\Android\Sdk
set EMU=%SDK%\emulator\emulator.exe
set ADB=%SDK%\platform-tools\adb.exe
set APK=D:\Projects\yiji\build\app\outputs\flutter-apk\app-debug.apk
set LOG=D:\Projects\emu_verify.log

echo ==== start %DATE% %TIME% ==== > "%LOG%"
start "" /B "%EMU%" -avd yiji_test -no-window -no-snapshot -no-boot-anim -gpu swiftshader_indirect -no-audio >> "%LOG%" 2>&1

echo waiting for boot... >> "%LOG%"
"%ADB%" wait-for-device >> "%LOG%" 2>&1
for /L %%i in (1,1,60) do (
  for /f "tokens=*" %%b in ('"%ADB%" shell getprop sys.boot_completed 2^>nul') do (
    if "%%b"=="1" goto booted
  )
  timeout /t 5 /nobreak > nul
)
echo BOOT TIMEOUT >> "%LOG%"
goto :eof

:booted
echo BOOTED >> "%LOG%"
"%ADB%" install -r "%APK%" >> "%LOG%" 2>&1
"%ADB%" shell am start -n com.xi283.yiji/.MainActivity >> "%LOG%" 2>&1
timeout /t 12 /nobreak > nul
"%ADB%" shell screencap -p /sdcard/shot1.png >> "%LOG%" 2>&1
"%ADB%" pull /sdcard/shot1.png D:\Projects\shot1.png >> "%LOG%" 2>&1
echo DONE >> "%LOG%"
