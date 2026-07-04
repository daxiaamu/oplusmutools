param(
    [Parameter(Mandatory=$true)]
    [string]$Bat,

    [Parameter(Mandatory=$true)]
    [string]$Icon,

    [Parameter(Mandatory=$true)]
    [string]$Out,

    [string]$Name = "BatConhostApp",

    [string]$ResourceDir,

    [ValidateSet("x86", "x64", "auto")]
    [string]$Arch = "x86",

    [string]$MarkerArg = "",

    [switch]$DebugKeep,

    [switch]$KeepBuild
)

$ErrorActionPreference = "Stop"

function Resolve-Tool($name, [switch]$Required) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $knownDirs = @(
        "D:\msys64\mingw32\bin",
        "C:\msys64\mingw32\bin",
        "D:\msys64\mingw64\bin",
        "C:\msys64\mingw64\bin"
    )
    foreach ($dir in $knownDirs) {
        $candidate = Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    if ($Required) {
        throw "Cannot find $name. Please install MinGW-w64 or add it to PATH."
    }
    return $null
}

function Escape-CppWideString([string]$text) {
    return $text.Replace([string][char]92, "\\").Replace([string][char]34, '\"')
}

function Escape-RcString([string]$text) {
    return $text.Replace([string][char]92, "\\").Replace([string][char]34, '""')
}

function Get-AsciiToken([string]$text) {
    $token = ($text -replace '[^A-Za-z0-9]', '')
    if (-not $token) { $token = "App" }
    return $token
}

function Get-RelativePathCompat([string]$BaseDir, [string]$FullPath) {
    $base = [System.IO.Path]::GetFullPath($BaseDir)
    $path = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = New-Object System.Uri($base)
    $pathUri = New-Object System.Uri($path)
    $relativeUri = $baseUri.MakeRelativeUri($pathUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', '\')
}

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Test-HasNonAscii([string]$Text) {
    return [regex]::IsMatch($Text, '[^\x00-\x7F]')
}

function New-AsciiTempRoot {
    $temp = [System.IO.Path]::GetTempPath().TrimEnd('\')
    if (-not (Test-HasNonAscii $temp)) {
        return [pscustomobject]@{ Root = $temp; Drive = $null }
    }

    foreach ($letter in 'Z','Y','X','W','V','U','T','S','R','Q','P') {
        $drive = "$letter`:"
        if (-not (Test-Path "$drive\")) {
            & subst.exe $drive $temp | Out-Null
            if ($LASTEXITCODE -eq 0 -and (Test-Path "$drive\")) {
                return [pscustomobject]@{ Root = "$drive\"; Drive = $drive }
            }
        }
    }

    return [pscustomobject]@{ Root = $temp; Drive = $null }
}

function New-Cabinet([string]$BuildRoot, [array]$Files) {
    $makecab = Get-Command makecab.exe -ErrorAction SilentlyContinue
    if (-not $makecab) {
        throw "Cannot find makecab.exe."
    }

    $ddf = Join-Path $BuildRoot "payload.ddf"
    $lines = @(
        ".OPTION EXPLICIT",
        ".Set Cabinet=ON",
        ".Set Compress=ON",
        ".Set CompressionType=LZX",
        ".Set CompressionMemory=21",
        ".Set MaxDiskSize=0",
        ".Set CabinetNameTemplate=payload.cab",
        ".Set DiskDirectoryTemplate=.",
        ".Set RptFileName=NUL",
        ".Set InfFileName=NUL"
    )

    foreach ($file in $Files) {
        $src = $file.Source.Replace('"', '""')
        $dst = $file.Dest.Replace('"', '""')
        $lines += '"' + $src + '" "' + $dst + '"'
    }

    Write-Utf8NoBom $ddf ($lines -join "`r`n")
    Push-Location $BuildRoot
    try {
        & $makecab.Source /F payload.ddf | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $BuildRoot "payload.cab"))) {
            throw "makecab failed."
        }
    }
    finally {
        Pop-Location
    }
}

if ($Arch -eq "x86") {
    $gpp = Resolve-Tool "i686-w64-mingw32-g++.exe"
    $windres = Resolve-Tool "windres.exe"
    if (-not $gpp) {
        $candidate = "D:\msys64\mingw32\bin\g++.exe"
        if (Test-Path -LiteralPath $candidate) { $gpp = $candidate }
    }
    if (-not $windres) {
        $candidate = "D:\mingw64\bin\windres.exe"
        if (Test-Path -LiteralPath $candidate) { $windres = $candidate }
    }
    if (-not $windres) {
        $candidate = "D:\msys64\mingw32\bin\windres.exe"
        if (Test-Path -LiteralPath $candidate) { $windres = $candidate }
    }
    if (-not $gpp -or -not $windres) {
        throw "x86 output requires 32-bit MinGW g++ and windres, for example D:\msys64\mingw32\bin\g++.exe and windres.exe."
    }
} elseif ($Arch -eq "x64") {
    $gpp = Resolve-Tool "g++.exe" -Required
    $windres = Resolve-Tool "windres.exe" -Required
} else {
    $gpp = Resolve-Tool "i686-w64-mingw32-g++.exe"
    $windres = Resolve-Tool "i686-w64-mingw32-windres.exe"
    if (-not $gpp -or -not $windres) {
        $gpp = Resolve-Tool "g++.exe" -Required
        $windres = Resolve-Tool "windres.exe" -Required
    }
}

$batPath = (Resolve-Path -LiteralPath $Bat).Path
$iconPath = (Resolve-Path -LiteralPath $Icon).Path
$resourceRoot = if ($ResourceDir) { (Resolve-Path -LiteralPath $ResourceDir).Path } else { Split-Path -Parent $batPath }
$relativeRoot = Split-Path -Parent $batPath
$outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$template = Join-Path $root "runtime_template.cpp"

if (-not (Test-Path -LiteralPath $template)) {
    throw "Missing runtime_template.cpp."
}

$asciiTemp = New-AsciiTempRoot
$buildRoot = Join-Path $asciiTemp.Root ("bat-conhost-packer-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $buildRoot | Out-Null

try {
    $payloadName = "payload.cmd"
    $appId = "daxiaamu.batconhost." + (Get-AsciiToken $Name)
    $rcName = Escape-RcString $Name
    $rcFileName = Escape-RcString ([System.IO.Path]::GetFileName($outPath))

    Copy-Item -LiteralPath $iconPath -Destination (Join-Path $buildRoot "app.ico") -Force

    $cabFiles = @()
    $payloadDirs = @()
    $staging = Join-Path $buildRoot "stage"
    New-Item -ItemType Directory -Path $staging | Out-Null
    $stagedBat = Join-Path $staging "payload.cmd"
    Copy-Item -LiteralPath $batPath -Destination $stagedBat -Force
    $cabFiles += [pscustomobject]@{ Source = $stagedBat; Dest = $payloadName }

    Get-ChildItem -LiteralPath $resourceRoot -Recurse -Directory | ForEach-Object {
        $relativeDir = Get-RelativePathCompat $relativeRoot $_.FullName
        if ($relativeDir.StartsWith("..")) {
            throw "Resource directory escaped resource root: $($_.FullName)"
        }
        $payloadDirs += $relativeDir
    }

    Get-ChildItem -LiteralPath $resourceRoot -Recurse -File | ForEach-Object {
        if ($_.FullName -ieq $batPath) { return }
        if ($_.FullName -ieq $outPath) { return }
        if ($_.Extension -ieq ".lnk") { return }

        $relative = Get-RelativePathCompat $relativeRoot $_.FullName
        if ($relative.StartsWith("..")) {
            throw "Resource path escaped resource root: $($_.FullName)"
        }

        $destName = "file_" + ([Guid]::NewGuid().ToString("N")) + ".bin"
        $stagedFile = Join-Path $staging $destName
        Copy-Item -LiteralPath $_.FullName -Destination $stagedFile -Force
        $cabFiles += [pscustomobject]@{ Source = $stagedFile; Dest = $relative }
    }
    New-Cabinet $buildRoot $cabFiles

    $source = Get-Content -LiteralPath $template -Raw -Encoding UTF8
    $source = $source.Replace("{{APP_ID}}", (Escape-CppWideString $appId))
    $source = $source.Replace("{{DISPLAY_NAME}}", (Escape-CppWideString $Name))
    $source = $source.Replace("{{PAYLOAD_NAME}}", (Escape-CppWideString $payloadName))
    $source = $source.Replace("{{MARKER_ARG}}", (Escape-CppWideString $MarkerArg))
    $source = $source.Replace("{{CMD_SWITCH}}", $(if ($DebugKeep) { "/k" } else { "/c" }))
    $source = $source.Replace("{{KEEP_EXTRACTED}}", $(if ($DebugKeep) { "1" } else { "0" }))
    $payloadDirRows = ($payloadDirs | Sort-Object | ForEach-Object {
        '    L"' + (Escape-CppWideString $_) + '",'
    }) -join "`r`n"
    $source = $source.Replace("{{PAYLOAD_DIRS}}", $payloadDirRows)
    Write-Utf8NoBom (Join-Path $buildRoot "runtime.cpp") $source

    @"
101 ICON "app.ico"
201 RCDATA "payload.cab"

1 VERSIONINFO
FILEVERSION 1,0,0,0
PRODUCTVERSION 1,0,0,0
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "080404B0"
        BEGIN
            VALUE "FileDescription", "$rcName"
            VALUE "FileVersion", "1.0.0.0"
            VALUE "InternalName", "$rcName"
            VALUE "OriginalFilename", "$rcFileName"
            VALUE "ProductName", "$rcName"
            VALUE "ProductVersion", "1.0.0.0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0804, 1200
    END
END
"@ | ForEach-Object { Write-Utf8NoBom (Join-Path $buildRoot "runtime.rc") $_ }

    Push-Location $buildRoot
    $oldPath = $env:Path
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    try {
        $toolDirs = @(
            (Split-Path -Parent $gpp),
            (Split-Path -Parent $windres)
        ) | Select-Object -Unique
        $env:Path = (($toolDirs + $env:Path) -join [System.IO.Path]::PathSeparator)
        $env:TEMP = $buildRoot
        $env:TMP = $buildRoot

        if ($Arch -eq "x86") {
            & $windres --codepage=65001 -F pe-i386 -O coff -i runtime.rc -o runtime.res
        } else {
            & $windres --codepage=65001 -O coff -i runtime.rc -o runtime.res
        }
        if ($LASTEXITCODE -ne 0) { throw "windres failed." }

        $outDir = Split-Path -Parent $outPath
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir | Out-Null
        }

        $builtExe = Join-Path $buildRoot "packed.exe"
        & $gpp -std=c++17 -O2 -finput-charset=UTF-8 -municode -mwindows -static -static-libgcc -static-libstdc++ `
            runtime.cpp runtime.res `
            -lole32 -lshell32 -lsetupapi -luuid -o $builtExe
        if ($LASTEXITCODE -ne 0) { throw "g++ failed." }

        Copy-Item -LiteralPath $builtExe -Destination $outPath -Force
    }
    finally {
        $env:Path = $oldPath
        $env:TEMP = $oldTemp
        $env:TMP = $oldTmp
        Pop-Location
    }

    Get-Item -LiteralPath $outPath
}
finally {
    if ($KeepBuild) {
        Write-Host "Build directory kept: $buildRoot"
    } else {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($asciiTemp.Drive) {
        & subst.exe $asciiTemp.Drive /D | Out-Null
    }
}
