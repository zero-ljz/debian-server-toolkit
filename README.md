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

部分函数提供帮助信息：

```bash
bash ccc.sh deploy_postgres --help
```

更新当前脚本：

```bash
bash ccc.sh upgrade
```

`upgrade` 会从本仓库 `main` 分支下载最新的 `ccc.sh` 并替换当前脚本文件。

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
```

当前 ShellCheck 仅阻止错误级问题。脚本包含较多历史代码，警告和风格问题应在不改变既有部署行为的前提下逐步处理。
