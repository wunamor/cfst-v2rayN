# CFST - Cloudflare 优选 IP 自动化订阅系统

完全本地化、免干预的 Cloudflare 优选 IP 自动化流程，为 v2rayN 提供持续更新的本地订阅。

```
拉取远程 CIDR → 剔除不可用网段 → TCP Ping 测速 → 组装明文 vmess 订阅 → 本地 HTTP 服务供 v2rayN 定时拉取
```

## 目录结构

```
CFST/
├── Main.ps1            # 主控脚本（唯一入口，串行调度三个子模块）
├── Start-Server.vbs    # 静默启动本地 HTTP 订阅服务
├── cfst.exe            # CloudflareSpeedTest（第三方，需自行下载，不入库）
├── .env                # 私密配置（不入库，见下方"配置"）
├── .env.example        # 配置模板
├── scripts/
│   ├── Fetch-IP.ps1    # 拉取 + 清洗 CIDR 网段 → data\ip.txt
│   ├── Ping-IP.ps1     # TCP Ping 测速，按延迟取 Top N → data\surviving_ips.txt
│   └── Gen-Sub.ps1     # 生成明文 vmess 订阅 → data\v2rayN_sub.txt
├── data/               # 运行产物（不入库）
└── temp/               # 临时文件（不入库）
```

## 依赖

- Windows + PowerShell 5.1 及以上（`.ps1` 源文件必须保存为**带 BOM 的 UTF-8**，否则中文乱码）
- [Python 3](https://www.python.org/)（仅本地 HTTP 守护需要）
- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest/releases)：下载 `cfst.exe` 放到项目根目录
- [v2rayN](https://github.com/2dust/v2rayN)

## 配置（环境变量）

所有私密信息一律通过环境变量注入，**禁止硬编码进脚本**。本地开发时复制模板：

```powershell
Copy-Item .env.example .env
# 编辑 .env 填入真实值；.env 已被 .gitignore 排除，不会入库
```

| 环境变量 | 说明 | 示例 |
| --- | --- | --- |
| `CFST_VMESS_UUID` | VMess 用户 ID（**私密**） | `xxxxxxxx-xxxx-...` |
| `CFST_VMESS_HOST` | 伪装域名（SNI / Host，**私密**） | `node.example.com` |
| `CFST_CIDR_URL` | CIDR 网段源地址 | `https://.../CF-CIDR.txt` |
| `CFST_HTTP_PORT` | 本地订阅服务端口（默认 22222） | `22222` |
| `CFST_VMESS_PATH` | VMess WebSocket 路径，须与源站一致（默认 `/`） | `/rs233` |
| `CFST_SKIP_CLEAN` | `1` 跳过毒瘤网段清洗（试水用；TCP Ping 无法识别 WARP 死段，慎用） | `0` |
| `CFST_RAW_LINKS` | 手动维护的节点原始链接（`vmess://`、`vless://` 等，`;` 分隔多条），原样合入订阅；协议头校验，内容透传 | `vless://...` |

### 安全注意

- `CFST_RAW_LINKS`、`CFST_VMESS_UUID` 等链接/ID 即节点凭据：**只允许存在于 `.env`**（已被 gitignore），任何脚本、README、日志、截图都不得出现完整值；`Gen-Sub.ps1` 的控制台输出已做脱敏（仅显示协议/服务器/别名）。
- 订阅文件 `data\v2rayN_sub.txt` 是含凭据的明文，`data/` 整个目录不入库。
- `Start-Server.vbs` 的 HTTP 服务**强制 `--bind 127.0.0.1`**：订阅明文仅本机 v2rayN 可拉取，局域网其他设备/访客无法获取凭据。确有需要让手机等设备订阅时，自行评估风险再改绑定。

读取优先级：系统/用户环境变量 > `Main.ps1` 启动时自动载入的根目录 `.env`。缺关键变量时脚本会 `[FAIL]` 退出并提示，不会静默使用假值。

## 使用

### 1. 生成订阅

```powershell
powershell -ExecutionPolicy Bypass -File .\Main.ps1
```

全程无人值守（cfst.exe 结尾的"按回车"已通过 stdin 管道自动跳过），默认按延迟保留并导入前 30 个 IP，数量可在 `Main.ps1` 顶部 `$Count` 修改。

### 2. 启动本地订阅服务

双击 `Start-Server.vbs`（静默后台，无窗口）。HTTP 根即 `data\` 目录。

### 3. v2rayN 订阅

订阅地址：`http://127.0.0.1:22222/v2rayN_sub.txt`，在 v2rayN 中启用**定时更新订阅**即可获得持续优选。

### 4.（可选）定时自动重新测速

```powershell
# 每 6 小时重测一次：任务在笔记本上跑，人到哪、就以哪的网络出测速基准自动换血
schtasks /Create /SC HOURLY /MO 6 /TN "CFST-Update" ^
  /TR "powershell -ExecutionPolicy Bypass -File \"<项目根目录>\Main.ps1\"" /F
```

## 源站部署（sing-box 双配置）

推荐源站同一台机器上**两份配置并存**（233boy sing-box 脚本里分别执行两次 `1) 添加配置`）：

| 配置 | 脚本选项 | 角色 | 走 Cloudflare | 需要域名 |
| --- | --- | --- | --- | --- |
| 主力 | `10) VMess-WS-TLS` | 供 CFST 优选出 30 个 CF IP 节点 | ✅ 必须橙云 | 需要 |
| 保底 | `18) VLESS-REALITY` | 直连单点，整条链接进 `CFST_RAW_LINKS` | ❌ 完全不碰 CF | 不需要 |

### 配置一：10) VMess-WS-TLS（CFST 主力）

CFST 订阅里的 vmess 节点固定 `net:ws / port:443 / path:/ / tls / SNI=Host=CFST_VMESS_HOST`，源站必须逐一对齐：

1. Cloudflare 后台：域名 A 记录 → 源站 IP，并开启**橙云**代理
2. 脚本 `1) 添加配置` → 选 `10) VMess-WS-TLS`，按提示填：
   - 域名 = `.env` 的 `CFST_VMESS_HOST`
   - UUID = `.env` 的 `CFST_VMESS_UUID`（若脚本自动生成了新的，把生成值填回 `.env`）
   - WebSocket path **必须改成 `/`**（脚本默认随机路径，漏改必连不上）
   - 端口 = `443`
3. **为什么脚本要你"关闭 Cloudflare 代理"**：只是签发 Let's Encrypt 证书时，ACME 校验需要域名直接解析到源站（橙云会拦截校验）。这是**瞬时步骤**——证书签完必须**立刻切回橙云**，否则 CFST 优选 IP 全部失效。CF SSL/TLS 模式设为 **Full (strict)**。证书后续自动续期走 HTTP-01（80 端口），可以穿透橙云，不必反复切灰。
4. 免切云替代方案：Cloudflare 后台 → SSL/TLS → Origin Server 签发 **Origin Certificate**（15 年有效），源站手动配置该证书，全程保持橙云、无续期烦恼。
5. ⚠️ **脚本警告"端口 (80 或 443) 已经被占用，Caddy 将使用非标准端口"时必须 Ctrl+C 中止**：Cloudflare 免费计划只回源固定端口（443/8443/2096/2083/2082/2052/2053/8080），非标准端口（如 1732）= 橙云链路必死，且 ACME 也签不到证书。两种处置：占用者是脚本自己的 Reality 配置 → `2) 更改配置` 把它挪去别的端口（如 39999）再重试；占用者是**你自己的建站服务（1Panel/OpenResty/nginx，不可动）** → 放弃 Caddy 自动 TLS，改用下面的 no-auto-tls 反代变体。
6. ⚠️ 订阅全灭时先看 CF 返回码：`502` = CF 已连上源站但应答不是 VMess-WS（端口被占/path 不对/SSL 模式错）；`521/522/523` = 源站没监听或 A 记录指错 IP；`525/526` = SSL 模式与源站证书不匹配。

验证：浏览器访问 `https://<域名>/` 返回源站的 4xx 页面，说明 CF → 源站链路已通。

### 配置一变体：443 被 1Panel/OpenResty 占用 → no-auto-tls 反代模式

sing-box 完全不碰 443，TLS 与转发交给已有建站层，链路为：

```
v2rayN → CF边缘(橙云:443) → OpenResty(443, TLS终结) → 127.0.0.1:<内部端口> → sing-box(VMess-WS, 无TLS)
```

1. VPS 执行 `sing-box no-auto-tls` → 协议选 **VMess-WS-TLS**
   - ⚠️ `no-auto-tls` 是**命令行参数**，不是主菜单里的选项——从主菜单选 10 会走 Caddy 抢 443 并让你切灰云（那是另一条路）
   - 此模式下脚本会**按 UUID 自动生成随机 path**（不问你要），端口也自动分配，都在结尾 INFO 里
2. 记下 `no-auto-tls INFO` 里的**端口 / 路径 / UUID**（忘了随时 `sing-box info tls` 复查）；`ss -tlnp | grep <端口>` 确认监听地址
3. **判定 1Panel OpenResty 容器的网络模式**（决定代理目标怎么填）：
   ```bash
   docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}' <openresty容器名>
   ```
   - 输出 `host` → 容器共享宿主机网络栈，目标直接填 `http://127.0.0.1:<端口>`（**三个数字别少**，`127.0.0.0` 这种笔误 = 502，实测踩过）
   - 输出 bridge 网络名 → 容器的 `127.0.0.1` 不是宿主机，需把 sing-box 的 `listen` 改为 `0.0.0.0` 后用 docker 网关 IP 作目标
4. 1Panel 创建**反向代理网站**：主域名 = `CFST_VMESS_HOST`，目标 `http://127.0.0.1:<端口>`，HTTP 版本 1.1，**开启 WebSocket**。配置落盘位置（宿主机路径，容器为挂载）：vhost 在 `/opt/1panel/www/conf.d/<域名>.conf`（主 conf 只有 `include`，**proxy_pass 实际在** `/opt/1panel/www/sites/<域名>/proxy/*.conf`），日志在 `.../log/error.log`。手工核对 location 应有：
   ```nginx
   proxy_http_version 1.1;
   proxy_set_header Upgrade $http_upgrade;
   proxy_set_header Connection "upgrade";
   proxy_set_header Host $host;
   proxy_read_timeout 300s;
   ```
5. path 若非 `/`：本地 `.env` 设 `CFST_VMESS_PATH=<INFO里的原值>`（逐字复制，别手敲），OpenResty 的 location 用同一路径
6. 给该网站签发 Let's Encrypt 证书（推荐 **DNS 验证 / CF API**，橙云全程不动），CF SSL/TLS 模式 = **Full (strict)**，A 记录保持**橙云**
7. 本地 `.env` 填入服务器 UUID → 跑 `Main.ps1`

此模式下订阅内容不变（wss/443/sni=域名）——TLS 由 CF 与 OpenResty 两端负责，sing-box 不碰证书。

### 配置二：18) VLESS-REALITY（保底单点）

- 脚本再 `1) 添加配置` → 选 `18) VLESS-REALITY`，SNI 伪装与端口随意（如 `aws.amazon.com` / `443`），**全程不需要也不应该开 CF 代理**——Reality 是直连 TLS 握手，挂橙云反而废掉
- 输出的 `vless://` 整条链接填入 `.env` 的 `CFST_RAW_LINKS`（多条用 `;` 分隔）。Gen-Sub 每次生成订阅都会原样合入尾部，控制台只打码显示协议/服务器/别名

### 部署完的本地同步

1. 两份配置的"权威值"回填 `.env`：配置一的 UUID → `CFST_VMESS_UUID`（留空时 `Main.ps1` 会在第 3 步 `[FAIL]` 中止，防止静默产出死订阅）；配置二的链接 → `CFST_RAW_LINKS`
2. 跑 `Main.ps1`，v2rayN 更新订阅后验证：预期 30 个走 CF 的 vmess 优选 + 保底 reality 若干
3. 若优选节点全灭而 reality 正常：查源站链路三要素——域名是否橙云、证书是否过期、path 是否 `/`。reality 不受 CFST 测速和源站域名影响，作为兜底存在，这正是双配置的意义

## 订阅保鲜与故障隔离

**CF 边缘 IP 是易耗品**：任意播 IP 会被中间网络轮动黑洞/封锁，而订阅是 cfst 测速那一刻的快照。典型症状——同一域名、同一 path、同一 UUID 的节点里，**有的通有的不通**：这几乎总是个别 IP 到期，不是网络封了 CF 段，更不是源站坏了。

### 保鲜策略

- 换网络（家 ↔ 校园 ↔ 热点）后重跑一次 `Main.ps1`（约 40 秒），不同出口的最优 IP 集不同
- 或挂上面的 6 小时计划任务，让订阅始终跟随当前网络换血
- v2rayN 端配合"真连接延迟"批量测试 + 按延迟排序，秒级挑活节点

### 三级隔离诊断（节点半死/全死时按序排查）

| 级别 | 动作 | 判读 |
|---|---|---|
| ① IP 层 | `Test-NetConnection <不通节点IP> -Port 443`，再对照一个通的节点 | 不通=TCP 超时 且 同订阅有节点通 → 单 IP 阵亡，重跑 `Main.ps1` 即愈 |
| ② 链路层 | `curl.exe -sk -D - -o NUL -m 10 --resolve <域名>:443:<通的CF IP> -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" https://<域名><path>` | `101 Switching Protocols`=全链路健康；`502` 且 `Server: openresty`=源站段坏（CF 返回的 502 是 HTML，源站透传的 502 常为 text）；`52x`=回源断/证书不匹配 |
| ③ 源站层 | VPS 上 `tail -n 20 <站点error.log>` | `connect() failed (111) upstream:"http://..."`=反代目标地址/端口笔误；`SSL_do_handshake failed ... upstream https`=目标填成了 https；无日志=server_name 没命中该站点 |

### 升级触发条件

只有当 cfst 在某网络下**存活率崩盘**（220 个候选活不到 5 个）才说明该网络真在封 CF 段，按序考虑：非 443 的 CF 支持端口（8443/2053/2087/2096，需同步改 Gen-Sub 端口与 cfst `-tp`）→ CF IPv6 段（`CFST_CIDR_URL` 换 v6 源）→ 纯靠 Reality 保底直连。

## 排查提示

- **开着代理会不会影响优选测速？**
  - `cfst.exe` 用 Go 裸 TCP 直连 IP:443，**不读取**系统代理 / PAC / `HTTP_PROXY`——v2rayN 的规则模式、全局模式（系统代理）均**不影响**测速结果。
  - 唯一会污染结果的是 **TUN 模式 / 透明代理虚拟网卡**（v2rayN TUN、Clash 虚拟网卡等）：它在路由层劫持所有流量，测速延迟会变成"到代理服务器的延迟"。`Ping-IP.ps1` 已内置代理守卫：检测到默认路由落在 TUN 类网卡时直接 `[ABORT]`，避免无人值守产出失真订阅；确知无碍可加 `-AllowTransparentProxy` 强制继续。日常挂机建议：让 v2rayN 保持**PAC/规则模式**而非 TUN 模式。
  - Fetch 步骤（下载 CIDR 文本列表）会走系统代理，属正常现象，不影响测速。
- `ParseCIDR err invalid CIDR address: <正常IP>`：文件被写入 UTF-8 **BOM**（`EF BB BF`），Go 把它当成了 IP 的一部分。所有 `data\` 下供 cfst.exe / v2rayN 消费的文件必须无 BOM；用 `certutil -encodehex data\ip.txt out.txt` 检查首三字节。
- 控制台中文乱码：`.ps1` 源文件缺少 BOM，PowerShell 5.1 按 GBK 解码所致，与上一条相反——**源码要带 BOM，数据不要**。
- 更多工程约定见 [AGENTS.md](AGENTS.md)。

## License

本仓库脚本遵循原项目习惯自便用；`cfst.exe` 版权归 [XIU2](https://github.com/XIU2/CloudflareSpeedTest) 所有。
