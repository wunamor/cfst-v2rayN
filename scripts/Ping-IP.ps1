param (
  [int]$TargetCount = 30,
  [string]$IpFile = "data\ip.txt",
  [string]$OutCsv = "data\result.csv",
  [string]$OutRawIp = "data\surviving_ips.txt",
  [switch]$AllowTransparentProxy
)

# 本脚本位于 scripts\ 子目录，项目根目录（含 cfst.exe 与 data\）为其父级
$ProjectRoot = Split-Path -Path $PSScriptRoot -Parent

$exePath = Join-Path -Path $ProjectRoot -ChildPath "cfst.exe"
$ipFilePath = Join-Path -Path $ProjectRoot -ChildPath $IpFile
$csvPath = Join-Path -Path $ProjectRoot -ChildPath $OutCsv
$rawIpPath = Join-Path -Path $ProjectRoot -ChildPath $OutRawIp

if (!(Test-Path $ipFilePath)) { Write-Host "[FAIL] 找不到 IP 源文件: $ipFilePath"; exit 1 }

# ---------------- 代理守卫 ----------------
# cfst.exe 为 Go 裸 TCP 直连，系统代理/PAC/HTTP_PROXY 均不影响其测速；
# 但 TUN 模式（v2rayN TUN / Clash 虚拟网卡等）在路由层劫持全部流量，
# 测速包会被送进代理隧道，优选结果失真，且无人值守时会静默产出垃圾订阅。
$defRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
  Sort-Object RouteMetric | Select-Object -First 1
if ($defRoute) {
  $adapter = Get-NetAdapter -InterfaceIndex $defRoute.ifIndex -ErrorAction SilentlyContinue
  $isTun = ($adapter.InterfaceDescription -match 'wintun|utun|tap' -or $adapter.Name -match 'tun')
  if ($isTun) {
    if ($AllowTransparentProxy) {
      Write-Host "[WARN] 默认路由经虚拟网卡 [$($adapter.Name)]，测速结果可能失真（已指定 -AllowTransparentProxy，继续执行）"
    }
    else {
      Write-Host "[ABORT] 检测到 TUN/透明代理：默认路由走虚拟网卡 [$($adapter.Name)]"
      Write-Host "        cfst 的 TCP 测速流量会被代理劫持，优选结果不真实。请任选其一："
      Write-Host "        1. 关闭 v2rayN/Clash 的 TUN 模式，改用 PAC/规则模式（裸 TCP 测速不受系统代理影响）"
      Write-Host "        2. 测速期间临时退出全局代理客户端"
      Write-Host "        3. 确知影响可接受时追加 -AllowTransparentProxy 强制继续"
      exit 1
    }
  }
}

# 系统代理仅提示（不影响 cfst），Fetch 阶段走代理下载 CIDR 属正常现象
$ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($ie.ProxyEnable -eq 1) {
  Write-Host "[INFO] 系统代理已开启 ($($ie.ProxyServer))，不影响 cfst 裸 TCP 测速，继续执行"
}
# ------------------------------------------

if (Test-Path $csvPath) { Remove-Item $csvPath -Force }
if (Test-Path $rawIpPath) { Remove-Item $rawIpPath -Force }

# 通过管道向 stdin 喂入空行，自动满足 cfst.exe 结尾的“按下回车键退出”，无需人工干预
# & 调用为同步串行：本行结束后才会继续往下执行
'' | & $exePath -f $ipFilePath -tp 443 -dd -tl 300 -dn $TargetCount -o $csvPath

if (!(Test-Path $csvPath)) {
  Write-Host "[FAIL] 测速执行失败，未生成 $OutCsv (cfst 退出码: $LASTEXITCODE)"
  exit 1
}

$csvData = Get-Content $csvPath | Select-Object -Skip 1 | Where-Object { $_.Trim() } | ConvertFrom-Csv -Header "IP", "Sent", "Recv", "Loss", "Ping", "Speed"
$currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if ($csvData) {
  # 按延迟升序排序，仅保留前 $TargetCount 个优选 IP 写入存活列表
  $topNodes = $csvData | Sort-Object { [double]$_.Ping } | Select-Object -First $TargetCount

  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllLines($rawIpPath, @($topNodes | ForEach-Object { $_.IP }), $utf8NoBom)

  Write-Host "[OK] [$currentTime] 测速完成，按延迟排序后保留前 $($topNodes.Count) 个优选节点 (上限 $TargetCount)："
  foreach ($node in $topNodes) {
    Write-Host "  -> IP: $($node.IP) | 延迟: $($node.Ping) ms"
  }
}
else {
  Write-Host "[FAIL] [$currentTime] 没有测出任何符合条件的 IP。"
  exit 1
}

exit 0
