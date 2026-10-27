# Debian Server Toolkit

`ccc.sh` 是一个面向 Debian 服务器的交互式 Bash 运维脚本，集中提供系统初始化、软件安装、容器部署、反向代理、证书和监控工具等常用操作。

## 支持范围

- 主要目标系统：Debian 11、Debian 12
- 可能兼容：使用 `apt` 和 `systemd` 的 Ubuntu 版本，但目前没有完整验证
- CPU 架构：`amd64`、`arm64`；部分第三方工具仍取决于其上游是否提供对应构建
- 运行环境：Bash、`sudo`、`apt`、`systemd` 和可访问互联网的网络

脚本会读取 `/etc/os-release`，并大量使用 Debian 系的软件包名和服务路径，不支持 Alpine、CentOS、RHEL 等非 Debian 系发行版。

## 下载

```bash
wget https://raw.githubusercontent.com/zero-ljz/debian-server-toolkit/main/ccc.sh
bash ccc.sh
```

建议在执行前先检查脚本内容：

```bash
less ccc.sh
bash -n ccc.sh
```

## 使用

不带参数运行会列出当前版本中的可用函数：

```bash
bash ccc.sh
```

将函数名作为第一个参数即可执行对应操作，其余参数会原样传递给该函数：

```bash
bash ccc.sh systeminfo
bash ccc.sh install_docker
bash ccc.sh deploy_nginx 80 443
bash ccc.sh deploy_postgres 5432
bash ccc.sh create_ssl example.com
```

`create_proxy` 的第二个参数可以是本地端口或远程 HTTP/HTTPS 地址：

```bash
# 本地服务，保留请求的 Host
bash ccc.sh create_proxy proxy.example.com 1234

# 远程 HTTPS 服务，自动设置上游 Host 和 TLS SNI
bash ccc.sh create_proxy proxy.example.com https://example.com

# 也支持 HTTP 和自定义上游端口
bash ccc.sh create_proxy proxy.example.com http://example.com:8080
```

直接填写远程域名（如 `example.com`）时默认使用 HTTPS。远程地址仅支持主机名和可选端口，不支持路径、查询参数或账号密码；末尾的 `/` 会被移除，以保留原始请求路径。自定义端口会包含在上游 Host 中，TLS SNI 始终只使用主机名。

为反向代理站点开启访客访问的 HTTPS，先申请证书，再启用配置：

```bash
bash ccc.sh create_ssl proxy.example.com
bash ccc.sh enable_https proxy.example.com

# 可选：同时将 HTTP 请求以 301 跳转到 HTTPS
bash ccc.sh enable_https proxy.example.com --redirect
```

`enable_https` 修改 `/etc/nginx/conf.d/域名.conf`，适用于 `create_proxy` 生成的单个 `server` 配置。它检查 `/var/ssl/` 中的证书和私钥是否存在且非空，只取消模板中四项 TLS 配置及可选跳转块的注释；已启用的配置可重复执行，不会重复添加指令，省略 `--redirect` 也不会取消已有跳转。

修改前会保留 `.conf.bak.随机后缀` 备份，执行 `nginx -t` 通过后才重载；写入、校验或重载失败时恢复原配置。优先使用正在运行的 `nginx1` 容器，否则使用宿主机 Nginx。修改过模板结构的自定义配置可能被拒绝，需要手动处理。

`create_ssl` 使用 root 创建的私有临时目录下载 ACME 客户端，下载或签发失败立即退出。私钥及 CSR 操作统一通过 `sudo` 执行，签发结果检查有效期、域名及公钥后才替换证书，并检查、重载上述 Nginx。重载失败会恢复旧证书（首次申请则移除未成功加载的新证书），便于下次重试。重载成功后才添加每日 03:15 的检查任务，时间采用服务器时区；剩余有效期超过 30 天时，定时检查跳过申请。脚本需要保留在固定路径，路径不能含换行或 `%`。

部分函数提供帮助信息：

```bash
bash ccc.sh deploy_postgres --help
```

更新当前脚本：

```bash
bash ccc.sh upgrade
```

`upgrade` 会从本仓库 `main` 分支下载最新的 `ccc.sh`，通过非空及 Bash 语法检查后，在脚本所在目录暂存并原子替换。更新保留原文件的属主和权限；目标目录不可写或文件属主不同于当前用户时，会使用 `sudo`。下载、校验或替换失败会返回非零状态，保留原脚本，不报告更新成功。

## 数据库凭据与重复部署

`deploy_mysql`、`deploy_postgres` 在同名容器存在时退出，不覆盖原密码记录。重建容器时，会复用当前目录中的 `MYSQL_ROOT_PASSWORD.txt`、`PGSQL_ROOT_PASSWORD.txt`。只有全新数据卷且没有密码文件时才生成新密码，以仅当前用户可读写、禁止覆盖已有文件的方式保存，然后才创建数据卷和容器；首次部署失败也保留这份密码，供检查和重试。

已有 `mysql-data` 或 `postgre-data` 数据卷而缺少密码文件时，脚本会停止：必须恢复该数据库原来的密码记录，不能用新生成的密码冒充原密码。请备份密码文件，并在同一工作目录执行部署。失败的首次创建可能留下空卷，应先核实其内容，再决定如何处理；不要直接删除未知数据卷。

`create_database` 支持包含连字符的域名，对生成的数据库名使用反引号引用，并拒绝非法域名和超过数据库名称长度限制的输入。

## Gitea 持久化与旧实例迁移

`deploy_gitea` 使用 rootless 镜像，将 `/opt/gitea/data` 挂载到 `/var/lib/gitea`，将 `/opt/gitea/config` 挂载到 `/etc/gitea`。这两个目录由镜像使用的 UID/GID `1000:1000` 写入。同名 `gitea1` 容器存在时，部署会停止。

旧版本挂载的 `/data` 不是该镜像实际使用的数据目录。已有实例请先查看 `docker inspect gitea1` 中的 `Mounts`，记录 `/var/lib/gitea` 和 `/etc/gitea` 对应的卷，并备份外部数据库（如使用）。下面的步骤会停止旧实例，需要在维护时间操作；目标 `/opt/gitea/data`、`/opt/gitea/config` 应不存在或为空，已有内容时先检查并备份，不能直接混合复制：

```bash
sudo docker stop gitea1 &&
sudo install -d -m 0755 /opt/gitea/data /opt/gitea/config &&
sudo docker cp -a gitea1:/var/lib/gitea/. /opt/gitea/data/ &&
sudo docker cp -a gitea1:/etc/gitea/. /opt/gitea/config/ &&
sudo chown -R 1000:1000 /opt/gitea/data /opt/gitea/config
```

确认复制成功，检查仓库、数据库及 `app.ini`，并确认本地 `gitea/gitea:1-rootless` 仍是旧容器使用的镜像版本（迁移时避免同时升级），再执行：

```bash
sudo docker rename gitea1 gitea1-before-migration &&
bash ccc.sh deploy_gitea 3000 222
```

新实例应使用原来的端口。旧容器及其卷保留用于恢复；验证仓库、登录、SSH 和配置正常后再自行清理，验证前不要删除旧卷。复制配置时保留原文件权限，尤其是含数据库密码的 `app.ini`。

## 功能概览

| 分类 | 主要函数 |
| --- | --- |
| 系统 | `system_init`、`systeminfo`、`install_fail2ban`、`install_monitoring_tools` |
| 开发环境 | `install_python`、`install_nodejs`、`install_supervisor` |
| 服务配置 | `create_service`、`create_supervisor`、`create_proxy`、`create_ssl`、`enable_https`、`create_default_vhost` |
| 容器与数据服务 | `install_docker`、`deploy_mysql`、`deploy_redis`、`deploy_postgres`、`deploy_rabbitmq` |
| Web 与应用 | `deploy_nginx`、`deploy_wordpress`、`deploy_gitea`、`deploy_python_app`、`deploy_node_app`、`deploy_php_app` |
| 网络工具 | `install_aria2`、`install_frp`、`install_frps`、`install_gost` |
| 管理与监控 | `deploy_portainer`、`deploy_netdata`、`deploy_adminer`、`deploy_redis_commander`、`deploy_watchtower`、`deploy_filebrowser` |

以脚本不带参数输出的函数列表为准。

## 风险说明

此脚本会执行具有系统级影响的操作，不应在不了解具体函数内容的情况下直接用于生产环境。

- 多数操作使用 `sudo`，会修改 `/etc` 下的配置、systemd 服务、软件源、Swap、SSH、Nginx 和定时任务。
- 28 处交互读取设置了超时，其中部分逻辑会在约 5 秒无输入后视为继续执行。不要把交互式函数当作可无人值守运行的安全脚本。
- 部署函数可能创建或替换同名 Docker 容器、网络、数据目录和端口映射。
- Redis、RabbitMQ 等函数包含示例默认密码。公开服务前必须改为独立的强密码，并限制监听地址和防火墙规则。
- `upgrade` 会替换正在运行的脚本文件。升级前应检查新版本差异，并保留已验证版本。
- 脚本会从 GitHub 和多个第三方站点下载程序或安装脚本。生产环境应固定版本并自行验证来源和校验值。

执行前请备份相关配置和数据，并优先在临时虚拟机中验证目标函数。

## 检查

仓库的 GitHub Actions 会对每次推送和拉取请求执行：

```bash
bash -n ccc.sh
shellcheck --severity=error ccc.sh
python3 -m unittest discover -s tests -v
```

当前 ShellCheck 仅阻止错误级问题。脚本包含较多历史代码，警告和风格问题应在不改变既有部署行为的前提下逐步处理。

回归测试需要 Linux、Bash、Python 3 和 OpenSSL，使用临时目录及模拟命令检查部署和证书失败路径，不执行真实部署或访问 ACME 服务。`.gitattributes` 固定 Shell 脚本使用 LF，避免 Windows 检出后在 Linux 上出现 CRLF 语法错误。
