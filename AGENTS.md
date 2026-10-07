# CFST 项目上下文（Cloudflare 优选 IP 自动化订阅系统）

## 项目目标
完全本地化、免干预的 Cloudflare 优选 IP 自动化流程：拉取远程 CIDR -> 剔除不可用网段 -> TCP Ping 测速 -> 组装明文 vmess 订阅 -> 本地 HTTP 服务供 v2rayN 定时拉取。全程无人值守，不允许任何需要"按下回车键"的人工交互点。

## 核心模块
目录结构：根目录仅保留 `Main.ps1`、`cfst.exe`、`Start-Server.vbs`、`AGENTS.md`；子脚本统一放 `scripts\`；数据统一放 `data\`。子脚本内部一律用 `$ProjectRoot = Split-Path $PSScriptRoot -Parent` 定位根目录（勿直接用 `$PSScriptRoot` 拼 data/cfst.exe 路径）。
- **Main.ps1**: 主控脚本（根目录），串行调度 `scripts\` 下三个子模块。`$Count = 30` 在文件顶部统一配置"ping 生成结果并导入 v2rayN 的 IP 个数"。子脚本失败时按 `$LASTEXITCODE` 中止。
- **scripts\Fetch-IP.ps1**: CIDR 源地址读环境变量 `CFST_CIDR_URL`（未配置则 `[FAIL] exit 1`），带时间戳击穿 CDN 缓存拉取 CM 的 `CF-CIDR.txt`，用正则 `^(162\.159\.|162\.158\.|108\.162\.|172\.66\.)` 清洗毒瘤网段，保留前 N 条写入 `data\ip.txt`。清洗可用 `-SkipClean` 开关或 `CFST_SKIP_CLEAN=1` 跳过（跳过时打 `[WARN]` 并列放行条数；注意：即使 CM 维护的优选列表也含 162.159/108.162/172.66 死段，且 cfst 的 TCP Ping 无法识别其"端口开放但跑不了业务"，跳过清洗默认不推荐）。
- **scripts\Ping-IP.ps1**: 调用根目录的 `cfst.exe -tp 443 -dd -tl 300 -dn $TargetCount` 测速；开头有 TUN 代理守卫（见历史 Bug #4）；读取 result.csv 后按延迟升序排序，**只保留前 TargetCount 个**写入 `data\surviving_ips.txt`。
- **scripts\Gen-Sub.ps1**: 读取存活 IP（`-TopN` 上限 30），VMess UUID、伪装域名与 WS 路径读环境变量 `CFST_VMESS_UUID` / `CFST_VMESS_HOST` / `CFST_VMESS_PATH`（默认 `/`），拼接 vmess JSON，内层 Base64，外层明文（每行一个 `vmess://...`）无 BOM 写入 `data\v2rayN_sub.txt`。另支持 `CFST_RAW_LINKS`（`;` 分隔的原始 `vless://`/`vmess://` 等链接）：按 `;` 拆分（逗号留给 alpn 参数），仅校验 `scheme://` 前缀后原样透传合入订阅尾部；控制台输出必须脱敏（只打印 protocol/host/别名，绝不回显 UUID/pbk，注意 PowerShell 里 `$scheme://` 会被误解析成 `${scheme}:` 作用域，要用 `${scheme}`）。
- **本地 HTTP 守护**: `Start-Server.vbs` 静默运行 `cmd /c cd /d <根目录>\data && python -m http.server $CFST_HTTP_PORT --bind 127.0.0.1`（端口默认 22222，**只绑回环**避免订阅明文凭据泄露到局域网），v2rayN 订阅 `http://127.0.0.1:22222/v2rayN_sub.txt`。VBS 用自身所在目录推导根目录，禁止写死绝对路径。

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
4. **代理（TUN 模式）污染优选测速**
   - 分析：`cfst.exe` 用 Go 裸 TCP 直连 `IP:443`，**不读取**系统代理 / PAC / `HTTP_PROXY` 环境变量，因此 v2rayN 的规则模式、全局模式（系统代理）都不影响测速。唯一例外是 **TUN/透明代理虚拟网卡**（v2rayN TUN、Clash TUN 等），它在路由层劫持全部流量，使测得的"延迟"实为到代理服务器的延迟，无人值守时会静默产出失真订阅。
   - 修法：`Ping-IP.ps1` 开头有"代理守卫"——检查默认路由 `0.0.0.0/0` 所在网卡是否为 TUN 类（`InterfaceDescription`/`Name` 匹配 `wintun|utun|tap|tun`），命中即 `[ABORT] exit 1`；确知无碍可加 `-AllowTransparentProxy` 强制继续。系统代理仅打 `[INFO]` 提示不拦截。日常挂机建议 v2rayN 用 PAC/规则模式而非 TUN 模式。Fetch 步骤走系统代理下载 CIDR 文本属正常，不影响测速。

## 工程约定
- **禁止硬编码私密数据**：VMess UUID、伪装域名、CIDR 源地址、HTTP 端口一律读环境变量（`CFST_VMESS_UUID` / `CFST_VMESS_HOST` / `CFST_CIDR_URL` / `CFST_HTTP_PORT`）。本地私密值放根目录 `.env`（已被 `.gitignore` 排除），`.env.example` 为入库模板；Main.ps1 启动时自动把 `.env` 注入进程环境变量，子脚本读 `$env:` 默认值。缺关键变量时 `[FAIL] exit 1`，禁止静默回退到假值。
- 参数约定：数量类参数（`$TargetCount` / `$TopN`，默认 30）放在各脚本 `param()` 块**第一位**，并在 Main.ps1 顶部以 `$Count` 统一下发。
- 子脚本成功路径显式 `exit 0`、失败路径 `exit 1`，Main 依据 `$LASTEXITCODE` 串行中止。
- `cfst.exe` 为第三方二进制，不入库（`.gitignore` 已排除），README 中说明从 XIU2/CloudflareSpeedTest releases 下载。
- **凭据不落地**：节点 UUID、Reality pbk、`CFST_RAW_LINKS` 链接、服务器 IP 等只存 `.env` 与 `data\`（均 gitignore）；日志/控制台/文档只允许出现打码形式；HTTP 服务必须 `--bind 127.0.0.1`。
- **源站双配置架构**：主力 = sing-box `10) VMess-WS-TLS`（与 Gen-Sub 生成的 `ws/443/tls/SNI=Host=CFST_VMESS_HOST/path=CFST_VMESS_PATH(默认/)` 逐一对齐，域名必须 CF 橙云）；保底 = `18) VLESS-REALITY`（直连协议，完全不碰 CF，链接填入 `CFST_RAW_LINKS`）。脚本提示"关闭 CF 代理"仅发生在 Let's Encrypt 签证书瞬间，签完必须切回橙云 + SSL 模式 Full(strict)，续期走 HTTP-01 可穿透橙云；嫌续期麻烦可用 CF Origin Certificate（15 年，免切云）。**端口铁律**：CF 免费计划只回源固定端口（443/8443/2096/2083 等），脚本警告 80/443 被占并改用非标准端口（如 1732）时必须中止。占用者是脚本自己的 Reality → 挪端口重试；占用者是用户自有建站服务（本机实况：1Panel/OpenResty 占 443 不可动）→ 用 `sing-box no-auto-tls` 添加 VMess-WS-TLS：sing-box 只听内部端口（无 TLS），由 OpenResty 建反代网站把该域名的 path 流量 `proxy_pass` 到 127.0.0.1:内部端口（必须带 Upgrade/Connection 头），TLS 由 CF+OpenResty 两端负责；内部端口/路径用 `sing-box info tls` 查。排障：CF 返回 502=源站应答非 VMess（反代没指对/path 不匹配/SSL 模式错）；521/522/523=源站未监听或 A 记录指错 IP；525/526=证书与 SSL 模式不匹配。详见 README「源站部署」。
- **UUID 防呆**：`.env` 的 `CFST_VMESS_UUID` 留空 = 故意的。源站重建换 UUID 期间让 `Main.ps1` 在 Gen-Sub 步骤 `[FAIL]` 中止，而不是拿旧 UUID 静默生成全灭订阅；禁止为跑通填假值。
- 临时/调试文件一律放 `temp\opencode\`，不得散落在项目根目录。
- 排查编码问题的标准手段：`certutil -encodehex <file> <out>` 查看首字节。
