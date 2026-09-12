$Count = 30  # 统一配置：ping 生成结果并导入 v2rayN 的 IP 个数

# 载入根目录 .env（不进版本库）：每行 KEY=VALUE，注入当前进程环境变量
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
  Get-Content $envFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
      $key, $value = $line -split '=', 2
      Set-Item -Path ("Env:" + $key.Trim()) -Value $value.Trim()
    }
  }
}

Write-Host "[RUN] 开始执行 Cloudflare 优选 IP 自动化流程，目标保留 $Count 个优选 IP..."
Write-Host "=================================================="

Write-Host "[1/3] 拉取并清洗 CF IP 段..."
& (Join-Path $PSScriptRoot "scripts\Fetch-IP.ps1") -OutFile "data\ip.txt"
if ($LASTEXITCODE -ne 0) { Write-Host "[ABORT] Fetch-IP 阶段失败"; exit 1 }

Write-Host ""
Write-Host "[2/3] Ping 测速，按延迟保留前 $Count 个存活 IP..."
& (Join-Path $PSScriptRoot "scripts\Ping-IP.ps1") -TargetCount $Count -IpFile "data\ip.txt" -OutCsv "data\result.csv" -OutRawIp "data\surviving_ips.txt"
if ($LASTEXITCODE -ne 0) { Write-Host "[ABORT] Ping-IP 阶段失败"; exit 1 }

Write-Host ""
Write-Host "[3/3] 生成 v2rayN 订阅 (最多导入 $Count 个节点)..."
& (Join-Path $PSScriptRoot "scripts\Gen-Sub.ps1") -TopN $Count -InputFile "data\surviving_ips.txt" -OutSub "data\v2rayN_sub.txt"
if ($LASTEXITCODE -ne 0) { Write-Host "[ABORT] Gen-Sub 阶段失败"; exit 1 }

Write-Host ""
Write-Host "[DONE] 全部流程执行完成！订阅文件: $PSScriptRoot\data\v2rayN_sub.txt"
exit 0
