# CFST 项目上下文（Cloudflare 优选 IP 自动化订阅系统）

## 项目目标
完全本地化、免干预的 Cloudflare 优选 IP 自动化流程：拉取远程 CIDR -> 剔除不可用网段 -> TCP Ping 测速 -> 组装明文 vmess 订阅 -> 本地 HTTP 服务供 v2rayN 定时拉取。全程无人值守，不允许任何需要"按下回车键"的人工交互点。

## 核心模块
目录结构：根目录仅保留 `Main.ps1`、`cfst.exe`、`Start-Server.vbs`、`AGENTS.md`；子脚本统一放 `scripts\`；数据统一放 `data\`。子脚本内部一律用 `$ProjectRoot = Split-Path $PSScriptRoot -Parent` 定位根目录（勿直接用 `$PSScriptRoot` 拼 data/cfst.exe 路径）。
- **Main.ps1**: 主控脚本（根目录），串行调度 `scripts\` 下三个子模块。`$Count = 30` 在文件顶部统一配置"ping 生成结果并导入 v2rayN 的 IP 个数"。子脚本失败时按 `$LASTEXITCODE` 中止。
- **scripts\Fetch-IP.ps1**: CIDR 源地址读环境变量 `CFST_CIDR_URL`（未配置则 `[FAIL] exit 1`），带时间戳击穿 CDN 缓存拉取 CM 的 `CF-CIDR.txt`，用正则 `^(162\.159\.|162\.158\.|108\.162\.|172\.66\.)` 清洗毒瘤网段，保留前 N 条写入 `data\ip.txt`。
- **scripts\Ping-IP.ps1**: 调用根目录的 `cfst.exe -tp 443 -dd -tl 300 -dn $TargetCount` 测速；读取 result.csv 后按延迟升序排序，**只保留前 TargetCount 个**写入 `data\surviving_ips.txt`。
- **scripts\Gen-Sub.ps1**: 读取存活 IP（`-TopN` 上限 30），VMess UUID 与伪装域名读环境变量 `CFST_VMESS_UUID` / `CFST_VMESS_HOST`，拼接 vmess JSON，内层 Base64，外层明文（每行一个 `vmess://...`）无 BOM 写入 `data\v2rayN_sub.txt`。
- **本地 HTTP 守护**: `Start-Server.vbs` 静默运行 `cmd /c cd /d <根目录>\data && python -m http.server $CFST_HTTP_PORT`（端口默认 22222，HTTP 根即 data），v2rayN 订阅 `http://127.0.0.1:22222/v2rayN_sub.txt`。VBS 用自身所在目录推导根目录，禁止写死绝对路径。

## 已解决的历史 Bug（勿回退）
1. **`ParseCIDR err invalid CIDR address: 8.35.211.0/24`**
   - 根因：PowerShell 的 `Out-File -Encoding utf8`、`[System.IO.File]::WriteAllText($p, $s, [Text.Encoding]::UTF8)` 以及 `New-Item` 默认都会写入 **UTF-8 BOM (EF BB BF)**。Go 的 `net.ParseCIDR` 把 BOM 当作 IP 的一部分，报错的其实是"隐形 BOM + 正常 IP"。
   - 修法：**所有供 cfst.exe / v2rayN 消费的 data 文件，一律用无 BOM 编码器写入**：
     ```powershell
     $utf8NoBom = New-Object System.Text.UTF8Encoding $false
     [System.IO.File]::WriteAllText($path, ($lines -join "`n"), $utf8NoBom)
     ```
   - 验证：`certutil -encodehex data\ip.txt` 首三字节不得是 `ef bb bf`。
2. **cfst.exe 执行完要求"按下回车键"，阻塞 Main 后续步骤**
   - 根因：cfst.exe v2.3.5 结尾固定调用 `fmt.Scanln` 等待回车；`Start-Process -NoNewWindow` 会继承控制台 stdin，照样卡住。
   - 修法：`'' | & $exePath ...` —— 用管道向子进程 stdin 喂一个空行，Scanln 立即返回，进程退出；`&` 本身同步等待，保证串行（cfst 完成后才走后续逻辑）。**不要用 `Start-Process -Wait`，也不要用 `ReadToEnd()`（输出重定向会死锁）**。
3. **控制台中文乱码**
   - 根因：`.ps1` 源文件被保存为"无 BOM 的 UTF-8"，Windows PowerShell 5.1 会按 ANSI(GBK) 解码源码导致乱码。
   - 修法：**所有 `.ps1` 源文件必须保存为"带 BOM 的 UTF-8"**（与 data 数据文件相反！脚本源码要 BOM，输出数据不要 BOM）；脚本内的输出信息避免使用 emoji（GBK 码页下必花屏），统一改用 `[OK]` / `[FAIL]` / `[RUN]` / `[DONE]` / `[ABORT]` 标记。

## 工程约定
- **禁止硬编码私密数据**：VMess UUID、伪装域名、CIDR 源地址、HTTP 端口一律读环境变量（`CFST_VMESS_UUID` / `CFST_VMESS_HOST` / `CFST_CIDR_URL` / `CFST_HTTP_PORT`）。本地私密值放根目录 `.env`（已被 `.gitignore` 排除），`.env.example` 为入库模板；Main.ps1 启动时自动把 `.env` 注入进程环境变量，子脚本读 `$env:` 默认值。缺关键变量时 `[FAIL] exit 1`，禁止静默回退到假值。
- 参数约定：数量类参数（`$TargetCount` / `$TopN`，默认 30）放在各脚本 `param()` 块**第一位**，并在 Main.ps1 顶部以 `$Count` 统一下发。
- 子脚本成功路径显式 `exit 0`、失败路径 `exit 1`，Main 依据 `$LASTEXITCODE` 串行中止。
- `cfst.exe` 为第三方二进制，不入库（`.gitignore` 已排除），README 中说明从 XIU2/CloudflareSpeedTest releases 下载。
- 临时/调试文件一律放 `temp\opencode\`，不得散落在项目根目录。
- 排查编码问题的标准手段：`certutil -encodehex <file> <out>` 查看首字节。
