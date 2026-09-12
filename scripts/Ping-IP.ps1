param (
  [int]$TargetCount = 30,
  [string]$IpFile = "data\ip.txt",
  [string]$OutCsv = "data\result.csv",
  [string]$OutRawIp = "data\surviving_ips.txt"
)

# 本脚本位于 scripts\ 子目录，项目根目录（含 cfst.exe 与 data\）为其父级
$ProjectRoot = Split-Path -Path $PSScriptRoot -Parent

$exePath = Join-Path -Path $ProjectRoot -ChildPath "cfst.exe"
$ipFilePath = Join-Path -Path $ProjectRoot -ChildPath $IpFile
$csvPath = Join-Path -Path $ProjectRoot -ChildPath $OutCsv
$rawIpPath = Join-Path -Path $ProjectRoot -ChildPath $OutRawIp

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
