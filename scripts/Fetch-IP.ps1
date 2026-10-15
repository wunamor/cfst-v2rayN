param (
  [string]$BaseUrl = $env:CFST_CIDR_URL,
  [string]$OutFile = "data\ip.txt",
  [int]$RetainN = 100
)

# 本脚本位于 scripts\ 子目录，项目根目录为其父级
$ProjectRoot = Split-Path -Path $PSScriptRoot -Parent

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
  Write-Host "[FAIL] 未配置 CFST_CIDR_URL：请设置环境变量，或复制 .env.example 为 .env 并填写 CIDR 源地址"
  exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$Url = $BaseUrl + "?_t=" + $Timestamp

$DataDir = Join-Path -Path $ProjectRoot -ChildPath "data"
if (-not (Test-Path -Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$OutPath = Join-Path -Path $ProjectRoot -ChildPath $OutFile

try {
  $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60

  # 剥离隐藏回车符与 BOM 残留字符
  $lines = $response.Content -split "`n" | ForEach-Object { $_.Trim([char]0xFEFF, [char]0xFFFE, [char]9, [char]10, [char]13, [char]32) } | Where-Object { ![string]::IsNullOrWhiteSpace($_) }

  # 本脚本只负责存原始列表；毒瘤网段过滤统一在 Ping-IP 阶段执行（改黑名单即时生效，无需重新拉取）
  $finalLines = $lines | Select-Object -First $RetainN

  # 防呆：结果为空则不覆盖旧缓存（源站换格式/网络返回空页时保护降级数据）
  if (@($finalLines).Count -eq 0) {
    Write-Host "[FAIL] 源站返回空列表，保留旧 ip.txt 不覆盖"
    exit 1
  }

  # 关键：使用不带 BOM 的 UTF8 编码 + LF 换行写入，否则 cfst.exe (Go) 的 net.ParseCIDR 会因 EF BB BF 报
  # "ParseCIDR err invalid CIDR address"
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($OutPath, ($finalLines -join "`n"), $utf8NoBom)

  Write-Host "[OK] IP 源库拉取成功，保留 $($finalLines.Count) 条原始数据至: $OutPath (毒瘤网段由 Ping 阶段过滤)"
  exit 0
}
catch {
  Write-Host "[FAIL] 下载失败: $($_.Exception.Message)"
  exit 1
}
