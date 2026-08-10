# TokenFleet Web

无构建依赖的 TokenFleet 管理端与匿名社群榜。浏览器直接加载语义化 HTML、CSS
和 ES modules，由 TokenFleet Server 同源托管；正式部署必须使用 HTTPS。

## 页面与本地预览

```bash
cd web
python3 -m http.server 4310
```

- 管理员后台：<http://127.0.0.1:4310/>
- 隔离演示：<http://127.0.0.1:4310/?demo=1#/overview>
- 匿名社群榜演示：<http://127.0.0.1:4310/?demo=1#/rank>
- 安全接入说明页：生产环境使用 `/join#code=<短期单次码>`；不要把码放在
  query 参数中。
- 批次自助页：生产环境使用 `/join/batch#invite=<批次令牌>`；query/path 形态只
  擦除、不接受。

生产环境由 Server 的 SPA fallback 支持直接刷新 `/rank`、`/rank/p/{public_id}`
、`/join` 和 `/join/batch`。`index.html` 的静态资源使用根绝对路径，避免公开深链白屏。

## 身份与接入

- 只有管理员使用组织标识、邮箱和密码登录后台；短期会话令牌只写当前标签页
  `sessionStorage`，不写 Cookie 或 `localStorage`，401/403 后立即清除。
- 社群参赛者没有邮箱、密码或 Web session。管理员创建最多 50 人、最长 24 小时
  且可关闭的受限批次；成员填写唯一昵称并明确同意公开后，各自得到 60 分钟单次码。
- 批次令牌只存于 fragment/闭包内存，个人设备码只存于响应闭包；两者均不进入
  DOM、storage、日志或历史，成员主动点击后才写剪贴板。
- `/join` 在其他页面逻辑工作前读取并立刻从地址栏清除 fragment；原始码不进入
  DOM、storage、日志或 query，离开页面后清空内存。成员主动点击后才写剪贴板。
- 同一参赛者的第二台设备使用新的单次码；设备 secret 与管理员 session 完全独立。

## 管理与公开边界

管理员可以新建/禁用参赛者、生成设备码、管理设备、查看多设备明细、配置公开
参与开关和版本化价格。匿名 `/rank` 与公开个人页仅展示管理员显式开启者的：

- 昵称、排名和四类 Token；
- 工具、模型和日趋势；
- 仅来自显式 `public_estimate=true` 价格版本的 API 等价估算。

未定价永远显示“未定价”，不按零。公开响应和页面不含邮箱、组织 slug、内部
用户/设备 ID、设备详情、IP、城市、小时、会话、消息、prompt、代码或路径。
混合时区只显示通用口径提示，不公开具体设备时区。Token 不代表绩效。

分享海报在浏览器本地生成，包含 Top 10、可选的榜外本人、筛选口径和同源 HTTPS
二维码；不把鉴权信息带进图片或链接。演示页面和演示海报都有醒目、不可去除的
假数据标识。

## 测试

```bash
cd web
npm test
python3 tests/community_browser.py
```

`community_browser.py` 自己启动临时 SPA fallback，检查 1440/820/390px、直接深链、
个人/批次接入码清理、匿名 claim、管理员批次流程、分享 PNG 和二维码。完整管理员/API 联调由仓库根目录
门禁执行：

```bash
python3 script/verify_tokenfleet_web.py
TOKENFLEET_ALLOW_MUTATING_E2E=YES \
TOKENFLEET_E2E_CONFIRM_BASE_URL='http://127.0.0.1:4311' \
python3 script/verify_tokenfleet_live_web.py
```

后两条写入型验收只能指向明确确认的可丢弃实例；失败日志不得输出页面正文、
管理员 session、一次性码或设备 secret。
