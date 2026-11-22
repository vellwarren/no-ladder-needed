# 让你的自建 App 不再需要梯子

> 从注册域名，到用 Cloudflare 改造「手机 App → 海外 VPS 后端」的连接链路。

很多自建 App 都是同一种结构：后端放在海外 VPS，前端是自己手机上的 App。服务明明正常，换一个 Wi‑Fi 或运营商却可能突然发不出消息、图片一直转圈，甚至完全连不上。

这篇教程把原来的直连链路：

```text
手机 App ─────────────→ 海外 VPS IP
```

改成：

```text
手机 App → Cloudflare 域名 → VPS 上的 Caddy → 后端服务
```

改完后，App 不再直接请求 VPS IP，而是请求一个开启 Cloudflare 代理的 HTTPS 域名。我们的实际体验是：原先经常无法建立连接的网络恢复了可用，大部分情况下响应也很快。

## 开始前先看

这篇教程适合你，如果：

- 你有一台正在运行后端的海外 VPS；
- 你有一个 iOS、Android 或其他手机客户端；
- App 目前通过 IP、`sslip.io` 或其他直连地址访问 VPS；
- 某些国内运营商或 Wi‑Fi 经常无法请求后端，但 VPS 本身没有宕机。

你需要准备：

- 一台能 SSH 登录的 VPS；
- 后端在 VPS 上监听的本地端口，例如 `127.0.0.1:3000`；
- 一个能返回 `200` 的健康检查接口，例如 `/healthz`；
- 修改并重新构建 App 的能力；
- 一个域名。域名本身通常需要按年付费，Cloudflare DNS、代理和 Origin CA 在本教程所需范围内可使用免费套餐。

> [!IMPORTANT]
> 本方案主要解决部分网络无法直接访问海外 VPS、连接成功率随缘的问题。实际速度仍受运营商到 Cloudflare 节点的路由影响，无法保证任何网络环境下都绝对稳定；但根据我们的实测，改造后大部分时间连接很快，可用性也明显提升。

## 先记下四个值

全文用下面的占位值演示，请替换成你自己的：

| 名称 | 示例 | 你的值 |
| --- | --- | --- |
| 根域名 | `example.com` | 购买的域名 |
| API 子域名 | `api.example.com` | App 最终访问的地址 |
| VPS 公网 IPv4 | `203.0.113.10` | 服务器 IP |
| 后端本地地址 | `127.0.0.1:3000` | 后端监听地址 |

不要把真实 IP、私钥或 Token 提交到公开仓库。

## 第一步：买一个域名（约 15 分钟）

域名是后面所有配置的地基。自用不必追求品牌感，容易记住、续费价格能接受即可。本教程默认使用 `.com`；其他后缀并非一定不可用，但首年价格、续费价格和历史信誉可能不同，付款前请同时检查注册价与续费价。

### 路线 A：直接在 Cloudflare 购买

1. 打开 [Cloudflare Dashboard](https://dash.cloudflare.com/)，注册并验证账号邮箱。
2. 进入 **Domain Registration / Register Domains**。
3. 搜索想要的名字，选择可注册的域名并结账。
4. WHOIS 联系信息使用真实、可联系的信息；中文信息请按页面要求填写为 ASCII/拼音。
5. 检查价格、注册年限与自动续费设置，再完成支付。

Cloudflare Registrar 当前支持多种付款方式，包括常见银行卡、PayPal、Apple Pay、Google Pay 和 UnionPay；你实际能看到的选项以结账页面和所在地区为准，不再是“必须有 Visa”。Cloudflare 购买的域名会自动使用 Cloudflare Nameserver，无需手动改 NS。

注册后留意 ICANN 验证邮件。若要求验证，请及时点击；联系邮箱长期未验证可能导致域名被暂停解析。域名页面显示 **Active** 后即可继续。

### 路线 B：在 Porkbun 用支付宝购买

Porkbun 官方列出的付款方式包含 Alipay。购买完成后：

1. 在 Cloudflare 选择 **Add a domain / Onboard a domain**。
2. 输入刚购买的域名，选择 Free 套餐。
3. Cloudflare 会分配两个 Nameserver 地址。
4. 回到 Porkbun 的域名管理页面，把原来的 Nameserver 替换为 Cloudflare 给出的两个地址。
5. 等待 Cloudflare 将域名状态更新为 **Active**。

如果这个域名之前开启过 DNSSEC，修改 Nameserver 前先在原注册商关闭 DNSSEC；Cloudflare 激活后再重新开启。

## 第二步：确认后端只在本机可用

先 SSH 登录 VPS，确认后端确实在运行。把端口换成你自己的：

```bash
curl -i http://127.0.0.1:3000/healthz
```

理想结果是 HTTP `200`。如果本机请求都失败，先修复后端；Cloudflare 和域名无法修复已经宕机的服务。

如果后端直接监听 `0.0.0.0:3000`，建议改为 `127.0.0.1:3000`，只让 Caddy 对公网提供入口。

## 第三步：添加 DNS 记录

在 Cloudflare 中进入你的域名，然后打开 **DNS → Records → Add record**：

| 字段 | 填写内容 |
| --- | --- |
| Type | `A` |
| Name | `api` |
| IPv4 address | VPS 公网 IPv4 |
| Proxy status | `Proxied`（橙色云朵） |
| TTL | `Auto` |

保存后，`api.example.com` 就会经过 Cloudflare。橙云必须打开；灰云 `DNS only` 只负责解析，App 仍然会直接连接 VPS。

刚添加时后面的 HTTPS 尚未配置完成，短暂看到 525/526 属于正常的施工状态。完成下面几步后再做最终测试。

> 如果 VPS 只有 IPv4，就只添加 A 记录。不要为了“看起来完整”添加一个并不存在的 AAAA 记录。

## 第四步：安装 Caddy

如果 VPS 已经有 Nginx、Traefik 或其他反向代理，可以沿用它，不必同时安装 Caddy。下面以 Ubuntu/Debian + Caddy 为例。

按照 [Caddy 官方安装文档](https://caddyserver.com/docs/install#debian-ubuntu-raspbian)安装稳定版：

```bash
sudo apt install --yes debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
```

官方软件包会创建并启动 `caddy` systemd 服务。确认服务存在：

```bash
systemctl status caddy --no-pager
```

## 第五步：创建 Origin CA 证书并配置 Caddy

我们实际使用的是 **Cloudflare Origin CA 证书**，不需要创建一个永久有效、能编辑 DNS 的 API Token。

1. 进入 **SSL/TLS → Origin Server → Origin Certificates**。
2. 点击 **Create Certificate**。
3. 选择让 Cloudflare 生成私钥和 CSR。
4. Hostnames 至少包含 `api.example.com`。
5. 选择 PEM 格式和有效期，然后创建。
6. 分别复制 **Origin Certificate** 和 **Private Key**。

私钥只显示一次。它只能保存在服务器上的受限文件中，不要发给别人、放进 App、截图公开或提交 Git。

在 VPS 上准备目录：

```bash
sudo install -d -m 0750 -o root -g caddy /etc/caddy/certs
```

用你熟悉的服务器编辑器创建两个文件：

```text
/etc/caddy/certs/cloudflare-origin.pem
/etc/caddy/certs/cloudflare-origin.key
```

第一个文件粘贴 Origin Certificate，第二个粘贴 Private Key。然后收紧权限：

```bash
sudo chown root:caddy /etc/caddy/certs/cloudflare-origin.pem /etc/caddy/certs/cloudflare-origin.key
sudo chmod 0640 /etc/caddy/certs/cloudflare-origin.pem /etc/caddy/certs/cloudflare-origin.key
```

> [!WARNING]
> Origin CA 证书只被 Cloudflare 信任。以后若关闭橙云、暂停 Cloudflare 或让客户端直接访问源站，浏览器出现证书不受信任是预期行为。

编辑 `/etc/caddy/Caddyfile`：

```caddyfile
api.example.com {
    tls /etc/caddy/certs/cloudflare-origin.pem /etc/caddy/certs/cloudflare-origin.key

    encode zstd gzip

    reverse_proxy 127.0.0.1:3000 {
        flush_interval -1

        transport http {
            response_header_timeout 10m
        }
    }
}
```

- `api.example.com` 换成你的 API 子域名；
- `127.0.0.1:3000` 换成你的后端本地地址；
- `flush_interval -1` 适合聊天 App 的 SSE/流式回复；
- 较长的 `response_header_timeout` 避免模型生成较慢时由 Caddy 提前终止等待。

仓库里也提供了可直接复制的 [Caddyfile 示例](examples/Caddyfile)。

检查配置并平滑重载：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo systemctl status caddy --no-pager
```

若 VPS 开启了 UFW，确保 TCP 80/443 可进入：

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status
```

不要开放后端自身的 `3000` 端口给公网。

## 第六步：启用端到端严格 HTTPS

回到 Cloudflare：

1. 打开 **SSL/TLS → Overview**。
2. 将加密模式设为 **Full (strict)**。
3. 确认 `api` 的 DNS 记录仍为橙云状态。

不要选择 Flexible。Full (strict) 会同时加密并验证“手机 → Cloudflare”和“Cloudflare → VPS”两段链路。

## 第七步：先测试域名，再修改 App

在电脑上测试：

```bash
curl -i https://api.example.com/healthz
```

你应当看到：

- HTTP 状态为 `200`；
- 响应头通常包含 `server: cloudflare`；
- 响应头通常包含 `cf-ray`。

再确认域名没有直接暴露 VPS IP：

```bash
dig +short api.example.com
```

开启橙云后，这里通常返回 Cloudflare 的 Anycast 地址，而不是你的 VPS IP。

## 第八步：把 App 的 Base URL 换成新域名

真正需要分享的 App 代码通常只有一行。不要改接口路径，只替换公共 Base URL。

### iOS / Swift

```swift
enum APIConfig {
    static let productionBaseURL = URL(string: "https://api.example.com")!
}
```

### Android / Kotlin

```kotlin
object ApiConfig {
    const val BASE_URL = "https://api.example.com/"
}
```

### JavaScript / TypeScript

```ts
export const API_BASE_URL = "https://api.example.com";
```

如果 App 把旧地址存进了 UserDefaults、SharedPreferences、Keychain 或本地数据库，还要在升级时迁移或清除旧值；否则你虽然改了源码，已安装的 App 仍可能继续访问旧地址。

重新构建并安装 App 后，依次测试：

- Wi‑Fi；
- 手机流量；
- 你最容易出问题的运营商；
- 文字请求；
- 图片上传；
- 语音上传或 STT；
- SSE/流式回复。

## 验收清单

- [ ] 域名状态为 Active
- [ ] `api` A 记录指向正确 VPS IP
- [ ] DNS 记录为 Proxied 橙云
- [ ] Origin Certificate 和 Private Key 只存在于 VPS
- [ ] Caddy 配置验证通过并正常运行
- [ ] Cloudflare SSL/TLS 为 Full (strict)
- [ ] `https://api.example.com/healthz` 返回 200
- [ ] App 已不再使用 IP 或旧直连域名
- [ ] Wi‑Fi 和手机流量都测试过
- [ ] 没有把 Token、私钥或数据库密钥提交到 Git

## 常见错误

### 521 / 522

Cloudflare 无法正常连接源站。检查：

- VPS 和 Caddy 是否运行；
- DNS 里的 VPS IP 是否正确；
- TCP 443 是否被防火墙拦截；
- VPS 是否错误屏蔽了 Cloudflare 地址；
- 源站是否过载。

### 525

Cloudflare 与源站 TLS 握手失败。检查 Caddy 是否加载了证书和私钥、443 是否确实由 Caddy 监听。

### 526

Full (strict) 无法验证源站证书。检查证书是否过期、域名是否包含在证书 SAN 中，以及 Caddy 配置的证书是否对应当前域名。

### 域名能打开，但 App 仍访问旧地址

检查 App 是否有运行时配置、远程配置或本地持久化的 Base URL。删除重装能帮助定位，但正式版本最好提供迁移逻辑。

### 普通文字很快，图片或语音很慢

域名生效不等于每一类请求都一样快。图片和音频更大，也更容易暴露上传链路问题。对照 VPS 日志确认请求是“迟迟没有到达服务器”，还是“到达后处理很慢”。

### 偶尔仍然断流

Cloudflare 改善的是可达性和多数情况下的连接质量，不是运营商专线。手机到 Cloudflare 的链路仍可能波动，尤其是长时间 SSE 连接。

生产 App 最好再加三层兜底：

1. 发送请求使用唯一 request ID，避免断线重试产生重复消息；
2. SSE 中断后自动重新拉取历史，把后端已经生成的回复补回来；
3. 持续离线时显示明确状态，网络恢复后再同步。

## 这套方案做了什么，又没做什么

它解决或改善：

- 某些运营商无法从源头请求到 VPS；
- App 直接依赖裸 IP 或临时域名；
- HTTPS 和证书管理混乱；
- 源站 IP 直接暴露给普通 DNS 查询；
- 同一个后端在不同网络下可用性差异巨大。

它不保证：

- 所有运营商到 Cloudflare 永不绕路；
- 免费 Cloudflare 在中国大陆拥有专线级体验；
- VPS、数据库或上游模型服务永不宕机；
- App 不再需要断线恢复、幂等和超时设计。

## 安全提醒

- 不要把 Cloudflare API Token、Origin Private Key、SSH 私钥或数据库 Service Key 放进 App。
- 不要把密钥提交到 Git，即使仓库暂时是私有的。
- App 内只应出现公共 API 域名；真正的秘密保留在 VPS 环境变量中。
- 不要为了省事把 SSL/TLS 设为 Flexible。
- 不要给 API 域名配置“Cache Everything”。聊天、鉴权和个性化接口通常不应被公共缓存。
- 给 Cloudflare 账号、域名注册商和 VPS 开启双重验证。
- 记录 Origin CA 证书到期日；Cloudflare 官方说明不会为它发送到期通知。

## 官方资料

- [Cloudflare：注册新域名](https://developers.cloudflare.com/registrar/get-started/register-domain/)
- [Cloudflare：支持的付款方式](https://developers.cloudflare.com/billing/understand/faq/)
- [Porkbun：付款方式（包含 Alipay）](https://porkbun.com/support/payment_options)
- [Cloudflare：接入域名并修改 Nameserver](https://developers.cloudflare.com/fundamentals/manage-domains/add-site/)
- [Cloudflare：Proxied 橙云与 DNS only 的区别](https://developers.cloudflare.com/dns/proxy-status/)
- [Cloudflare：创建并安装 Origin CA 证书](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
- [Cloudflare：Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
- [Caddy：官方安装](https://caddyserver.com/docs/install)
- [Caddy：reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Cloudflare：522 排查](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-522/)

Cloudflare 页面名称会随版本调整；如果按钮位置与截图或文字不同，以官方文档和当前 Dashboard 为准。

## 许可证

本仓库采用 [PolyForm Noncommercial License 1.0.0](LICENSE.md)：允许个人学习、研究、实验、兴趣项目以及符合许可证定义的非商业组织使用、修改和分发；商业用途不在授权范围内。
