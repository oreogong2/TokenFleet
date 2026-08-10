# TokenFleet 阿里云单机部署

这是当前邀请制社群的标准部署：一台 Ubuntu 服务器运行一个 TokenFleet
进程和 PostgreSQL 17；Nginx 是唯一公网入口；Let's Encrypt 证书由 Certbot
申请并自动续期。应用端口只绑定 `127.0.0.1`，数据库不映射到宿主机或公网。

## 1. 需要同事提供什么

- 一台全新的阿里云轻量应用服务器或 ECS，建议 Ubuntu 24.04、2 核 4G；
- 公网 IPv4；
- 一个现有主域名下的二级域名，例如 `rank.example.com`；
- 把该二级域名的 A 记录指向服务器公网 IPv4；
- 安全组仅向公网开放 `80/443`，`22` 只允许公司固定 IP；不要开放
  `18080`、`5432`；
- 一个接收证书到期通知的运维邮箱。

不要在聊天、工单或 Git 中发送服务器密码、数据库密码、JWT secret、成员接入码。
服务器权限通过临时 SSH 公钥交付；上线完成后撤销临时权限。

## 2. 服务器一次性准备

在目标 Ubuntu 服务器安装 Docker Engine、Docker Compose v2、Nginx、Certbot
及其 Nginx 插件。使用阿里云镜像或 Docker 官方仓库均可，安装后应满足：

```bash
docker compose version
nginx -v
certbot --version
```

把经过复核的固定 commit 放在 `/opt/tokenfleet`。生产环境不要直接运行不确定的
分支，也不要在服务器上修改源码。

## 3. 生成生产配置

以下命令只在服务器本机生成随机数据库密码和 JWT secret，不会打印它们：

```bash
cd /opt/tokenfleet
python3 deploy/prepare_env.py \
  --output deploy/.env \
  --domain rank.example.com \
  --org-slug opc-community
```

把示例域名和社群标识替换为最终值。`deploy/.env` 权限固定为 `0600`，已被
Git 忽略；不要复制到其他机器或备份进公开仓库。

## 4. 启动应用和数据库

```bash
cd /opt/tokenfleet
./deploy/tokenfleet.sh doctor
./deploy/tokenfleet.sh up
./deploy/tokenfleet.sh create-admin 'OPC 社群' admin@example.com
```

最后一条命令会在终端无回显地询问管理员密码。密码至少 12 位，不写入环境模板。
服务使用单 worker，符合当前进程内登录/公开读取限流的发布边界。

## 5. 配置 Nginx 与免费证书

先确认 DNS 已解析到这台服务器，且安全组允许 80/443：

```bash
cd /opt/tokenfleet
sudo ./deploy/install_nginx_certbot.sh \
  --email ops@example.com \
  --expected-ip 203.0.113.10
```

替换邮箱和公网 IPv4。脚本会：

1. 校验 DNS 与服务器 IPv4；
2. 校验 TokenFleet 本机 readiness；
3. 安装只代理到 `127.0.0.1` 的 Nginx 站点；
4. 覆盖外部伪造的 `X-Forwarded-For`，并增加网关限流；
5. 用 Certbot 申请 Let's Encrypt 证书、强制 HTTPS；
6. 启用自动续期并真实执行一次 `certbot renew --dry-run`。

成功后访问：

```text
https://rank.example.com/rank
```

如果目标主机已经运行其他网站，不使用上面的 `certbot --nginx` 路径。复用该主机
已有的 Certbot 账号和 `/opt/certbot`，执行：

```bash
sudo ./deploy/install_nginx_certbot_alibaba.sh \
  --expected-ip <server-public-ip> \
  --reuse-existing-account
```

该脚本使用 webroot 流程：先安装只提供 ACME challenge 的 HTTP 配置，签发成功后
才原子切换到独立 HTTPS 配置；不会让 Certbot 改写主机上其他网站的 Nginx 文件，
也不会读取或输出既有 Certbot 账号邮箱。

## 6. 每日数据库备份

先手动验证一次：

```bash
cd /opt/tokenfleet
sudo TOKENFLEET_BACKUP_DIR=/var/backups/tokenfleet \
  ./deploy/backup_postgres.sh
```

再安装每日定时任务：

```bash
cd /opt/tokenfleet
sudo ./deploy/install_backup_timer.sh
sudo systemctl start tokenfleet-backup.service
sudo systemctl status tokenfleet-backup.service --no-pager
```

默认每天备份、保留至少 14 天，每份备份都执行 PostgreSQL 归档结构校验并生成
SHA-256。服务器同盘备份不能替代异机备份：至少再配置阿里云快照，稳定后把加密
备份同步到独立 OSS bucket。

## 7. 上线验收

```bash
curl -fsS https://rank.example.com/healthz
curl -fsS https://rank.example.com/readyz
curl -fsS 'https://rank.example.com/api/v1/public/leaderboard?period=today&metric=tokens'
sudo certbot renew --dry-run
./deploy/tokenfleet.sh status
```

还要人工完成：管理员登录、创建一名测试参赛者、Mac 测试设备登记、首次上传、
排行榜展示、设备禁用、重新登记。测试账号完成后关闭公开或禁用，不把真实接入码
写进验收报告。

## 8. 升级和回滚

升级前先备份，再切换到经过复核的固定 commit：

```bash
cd /opt/tokenfleet
sudo TOKENFLEET_BACKUP_DIR=/var/backups/tokenfleet \
  ./deploy/backup_postgres.sh
git checkout --detach <verified-commit-sha>
./deploy/tokenfleet.sh up
```

代码启动失败时切回上一固定 commit，再执行 `tokenfleet.sh up`。不要未经恢复演练
直接降级数据库迁移；需要恢复数据时按 `docs/TOKENFLEET_OPERATIONS.md` 在副本库
先演练，禁止直接覆盖生产数据库。

## 9. 当前成本边界

- 二级域名与阿里云免费 DNS：通常无新增费用；
- Let's Encrypt + Certbot：证书费用为零；
- 主要成本：一台 2 核 4G 服务器、可选云盘/快照和超额流量；
- 当前单机方案适合早期社群。要做多实例或更高 SLA 时，必须先增加共享限流、
  独立数据库和外部备份，不能直接横向启动多个 App worker。
