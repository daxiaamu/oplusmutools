# Bat Conhost Packer

把 `.bat`、资源目录和 `.ico` 打包成单文件 `.exe`。运行时释放到系统 `%TEMP%`，强制使用传统 Windows 控制台 `conhost.exe`，并通过临时快捷方式让任务栏显示自定义图标。

## 用法

```powershell
powershell -ExecutionPolicy Bypass -File .\Pack-BatConhostExe.ps1 `
  -Bat "D:\path\toolbox.bat" `
  -Icon "D:\path\icon.ico" `
  -ResourceDir "D:\path\resources" `
  -Out "D:\path\toolbox.exe" `
  -Name "一加全能工具箱"
```

默认输出 32 位 PE，可在 32 位和 64 位 Windows 上运行。

## 特性

- 输出 exe 是原生 Win32 程序，不需要 .NET 运行时。
- 默认 `-Arch x86`，生成 32 位 PE。
- 支持把 bat 和资源目录压缩进 exe。
- 运行时释放到 `%TEMP%\BatConhost_<进程ID>\`。
- bat 的工作目录会设置为释放后的临时目录。
- 保留资源目录结构，包括空目录。
- 程序退出后自动删除 `%TEMP%` 下的临时释放目录。
- `-DebugKeep` 调试模式会使用 `cmd /k` 并保留临时目录，方便排查问题。
- 运行链路是 `exe -> conhost.exe -> cmd.exe -> bat`。
- 通过 `STARTF_TITLEISLINKNAME` 让 `conhost` 使用临时 `.lnk` 的图标，便于任务栏区分。

## 参数

- `-Bat`：主 bat 文件。
- `-Icon`：exe 和任务栏使用的 ico 图标。
- `-ResourceDir`：资源目录。目录内文件会递归打包，路径会按相对 bat 所在目录保留。
- `-Out`：输出 exe 路径。
- `-Name`：显示名称。
- `-Arch`：`x86`、`x64` 或 `auto`。默认 `x86`。
- `-DebugKeep`：调试用，窗口停留并保留临时释放目录。
- `-MarkerArg`：如果旧 bat 仍保留自启动 conhost 的标记参数，可用这个参数传入，例如 `__CONHOST__`。

## 依赖

打包机器需要 MinGW-w64。生成 32 位 exe 时，需要 32 位 MinGW 工具链，例如：

```text
D:\msys64\mingw32\bin\g++.exe
```

最终打包出来的 exe 不需要 MinGW，也不需要 .NET。
