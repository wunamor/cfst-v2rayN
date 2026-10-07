param (
  [int]$TopN = 30,
  [string]$InputFile = "data\surviving_ips.txt",
  [string]$OutSub = "data\v2rayN_sub.txt",
  [string]$Domain = $env:CFST_VMESS_HOST,
  [string]$Uuid = $env:CFST_VMESS_UUID,
  [string]$Path = $env:CFST_VMESS_PATH,
  [string]$RawLinks = $env:CFST_RAW_LINKS
)

# 本脚本位于 scripts\ 子目录，项目根目录为其父级
$ProjectRoot = Split-Path -Path $PSScriptRoot -Parent

if ([string]::IsNullOrWhiteSpace($Path)) { $Path = "/" }

# 私密参数一律来自环境变量（或由 Main.ps1 载入的根目录 .env），禁止硬编码
if ([string]::IsNullOrWhiteSpace($Uuid)) {
  Write-Host "[FAIL] 未配置 CFST_VMESS_UUID：请设置环境变量，或复制 .env.example 为 .env 并填入真实值"
  exit 1
}
if ([string]::IsNullOrWhiteSpace($Domain)) {
  Write-Host "[FAIL] 未配置 CFST_VMESS_HOST：请设置环境变量，或在 .env 中填写伪装域名"
  exit 1
}

$InputPath = Join-Path -Path $ProjectRoot -ChildPath $InputFile
$OutPath = Join-Path -Path $ProjectRoot -ChildPath $OutSub

if (!(Test-Path $InputPath)) { Write-Host "[FAIL] 找不到输入文件: $InputPath"; exit 1 }

$ips = Get-Content $InputPath | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -First $TopN
$vmessList = @()

# 获取简短的时间格式，例如 0912-1405 (9月12日 14:05)
$timeStr = Get-Date -Format "MMdd-HHmm"

foreach ($ip in $ips) {
  # 别名格式：CF-时间-IP (例如: CF-0912-1405-8.35.211.52)
  $alias = "CF-$timeStr-$ip"
  $json = '{"v":"2","ps":"' + $alias + '","add":"' + $ip + '","port":"443","id":"' + $Uuid + '","aid":"0","scy":"auto","net":"ws","type":"none","host":"' + $Domain + '","path":"' + $Path + '","tls":"tls","sni":"' + $Domain + '","alpn":""}'

  $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
  $vmessList += "vmess://$base64"
}

# ---- 合入手动维护的原始链接 (CFST_RAW_LINKS) ----
# 仅按 ; 分隔（, 会被 alpn=h3,http/1.1 之类参数占用）；只校验协议头，内容原样透传
$rawList = @()
$rawRejected = 0
if (-not [string]::IsNullOrWhiteSpace($RawLinks)) {
  $parsed = $RawLinks -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  $rawList = @($parsed | Where-Object { $_ -match '^[a-zA-Z][a-zA-Z0-9+.\-]*://' })
  $rawRejected = @($parsed).Count - $rawList.Count
  if ($rawRejected -gt 0) {
    Write-Host "[WARN] CFST_RAW_LINKS 中有 $rawRejected 条缺少 scheme:// 前缀，已忽略"
  }
  foreach ($r in $rawList) {
    # 打码输出：scheme + 服务器地址 + 别名，UUID/密钥等凭据部分不落控制台
    $scheme = ($r -split '://', 2)[0]
    $hostpart = ''
    if ($r -match '@([^?#]+)') { $hostpart = $Matches[1] }
    $remark = ''
    if ($r -match '#(.+)$') { $remark = " [$($Matches[1])]" }
    Write-Host "[OK] 合入手动链接: ${scheme}://${hostpart}${remark}"
  }
}
# -------------------------------------------

$allList = @($vmessList) + @($rawList)
$finalText = $allList -join "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutPath, $finalText, $utf8NoBom)

Write-Host "[OK] 订阅生成完成：vmess 优选 $($vmessList.Count) 个 (上限 $TopN) + 手动链接 $($rawList.Count) 个，写入 $OutPath"
exit 0
