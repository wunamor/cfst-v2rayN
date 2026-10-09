$Count = 30  # 统一配置：ping 生成结果并导入 v2rayN 的 IP 个数

# 载入根目录 .env（不进版本库）：每行 KEY=VALUE，注入当前进程环境变量
# 优先级：已存在的环境变量 > .env（便于临时覆盖，如测试降级逻辑）
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
  Get-Content $envFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
      $key, $value = $line -split '=', 2
      $key = $key.Trim()
      if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($key))) {
        Set-Item -Path ("Env:" + $key) -Value $value.Trim()
      }
    }
  }
}

function Test-CacheFile([string]$path) {
  (Test-Path $path) -and (@(Get-Content $path -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count -gt 0)
}
function Get-CacheAge([string]$path) { (Get-Item $path).LastWriteTime.ToString("yyyy-MM-dd HH:mm") }

$ipTxt = Join-Path $PSScriptRoot "data\ip.txt"
$survTxt = Join-Path $PSScriptRoot "data\surviving_ips.txt"

Write-Host "[RUN] 开始执行 Cloudflare 优选 IP 自动化流程，目标保留 $Count 个优选 IP..."
Write-Host "=================================================="

Write-Host "[1/3] 拉取并清洗 CF IP 段..."
$fetchOk = $true
try {
  & (Join-Path $PSScriptRoot "scripts\Fetch-IP.ps1") -OutFile "data\ip.txt"
  if ($LASTEXITCODE -ne 0) { $fetchOk = $false }
} catch { $fetchOk = $false }
if (-not $fetchOk) {
  if (Test-CacheFile $ipTxt) {
    Write-Host "[WARN] 拉取失败，降级使用缓存 ip.txt (更新于 $(Get-CacheAge $ipTxt))，继续后续流程"
  } else {
    Write-Host "[ABORT] 拉取失败，且无可用缓存 ip.txt，终止"
    exit 1
  }
}

Write-Host ""
Write-Host "[2/3] Ping 测速，按延迟保留前 $Count 个存活 IP..."
$pingOk = $true
try {
  & (Join-Path $PSScriptRoot "scripts\Ping-IP.ps1") -TargetCount $Count -IpFile "data\ip.txt" -OutCsv "data\result.csv" -OutRawIp "data\surviving_ips.txt"
  if ($LASTEXITCODE -ne 0) { $pingOk = $false }
} catch { $pingOk = $false }
if (-not $pingOk) {
  if (Test-CacheFile $survTxt) {
    Write-Host "[WARN] 测速失败，降级使用缓存存活列表 (更新于 $(Get-CacheAge $survTxt))，继续生成订阅"
  } else {
    Write-Host "[ABORT] 测速失败，且无可用缓存存活列表，终止"
    exit 1
  }
}

Write-Host ""
Write-Host "[3/3] 生成 v2rayN 订阅 (最多导入 $Count 个节点)..."
try {
  & (Join-Path $PSScriptRoot "scripts\Gen-Sub.ps1") -TopN $Count -InputFile "data\surviving_ips.txt" -OutSub "data\v2rayN_sub.txt"
  if ($LASTEXITCODE -ne 0) { throw "退出码 $LASTEXITCODE" }
} catch {
  Write-Host "[ABORT] Gen-Sub 阶段失败（多为 .env 配置问题，此步无降级空间）: $_"
  exit 1
}

Write-Host ""
Write-Host "[DONE] 全部流程执行完成！订阅文件: $PSScriptRoot\data\v2rayN_sub.txt"
exit 0
