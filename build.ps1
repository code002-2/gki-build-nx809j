# ============================================================
# build.ps1 - Windows 入口: 调用 WSL2 里的 build.sh 构建
# 用法:  .\build.ps1 [build.sh 的参数, 例如 --mirror ustc]
# ============================================================
$ErrorActionPreference = "Stop"
$srcDir = $PSScriptRoot

# 1. 检查 WSL
$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $wsl) {
    Write-Host "[错误] 未找到 wsl, 请先安装 WSL2: https://learn.microsoft.com/windows/wsl/install" -ForegroundColor Red
    exit 1
}

$distro = (& wsl -l -q) 2>$null | Out-String
if ([string]::IsNullOrWhiteSpace($distro)) {
    Write-Host "[提示] WSL 已安装但没有发行版, 请先执行:" -ForegroundColor Yellow
    Write-Host "       wsl --install -d Ubuntu-24.04" -ForegroundColor Cyan
    Write-Host "       然后重启终端再运行本脚本。"
    exit 1
}

# 2. 复制脚本到 WSL 的 ext4 文件系统(不要在 /mnt 上直接构建, 会慢 10 倍)
$wsPath = (& wsl wslpath -u $srcDir).Trim()
$remoteDir = "~/gki-build-nx809j"
$argStr = $args -join " "

Write-Host "[build] 复制脚本到 WSL2 ..." -ForegroundColor Green
& wsl bash -lc "mkdir -p $remoteDir && cp -a ${wsPath}/. ${remoteDir}/ 2>/dev/null || rsync -a --delete ${wsPath}/ ${remoteDir}/; echo '[build] 开始构建(产物在 work/out/);'

Write-Host "[build] 开始构建 ..." -ForegroundColor Green
& wsl bash -lc "cd $remoteDir && bash build.sh $argStr"
exit $LASTEXITCODE
