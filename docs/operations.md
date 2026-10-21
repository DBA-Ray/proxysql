# 部署、维护与恢复说明

## 环境与依赖

控制端需要 Linux、Ansible Core 2.12 或以上及 `community.proxysql` collection：

```bash
ansible-galaxy collection install -r requirements.yml
```

目标端需要 root 权限和 systemd，支持 RedHat 系、Ubuntu 的包管理流程。
MySQL 客户端必须提供 `mysql`、`mysqldump`、`mysql_config_editor`；仅安装 MariaDB 客户端
不能保证支持 login-path。Debian 用户需要预先配置 Oracle MySQL 客户端源。
Python 驱动由目标机提供，旧 CentOS 7 使用 MySQL-python，新 Python 环境使用 PyMySQL。
`vars/main.yml` 的 RedHat 包列表按 CentOS 7 编写，其他大版本需要覆盖为对应包名。
flock 来自 util-linux，timeout/stat/GNU sort/tail 来自 coreutils，curl 用于告警，zstd 用于压缩。

将匹配系统和 CPU 架构的包放入 `files/`，设置 `proxysql_package` 和
`proxysql_upgrade_package`。Role 校验文件存在及 deb/rpm 后缀；架构、动态库依赖和
版本升级兼容性仍需在相同系统的测试机验证。安装包不会自动下载或选择最新版本。

## 配置与执行

变量及注释位于 `defaults/main.yml`。密码由 `vars/secrets.yml` 载入，建议用 Ansible Vault
加密该文件。生产环境需要覆盖账号、地址和 webhook 默认值。
管理员及监控密码不能含 `:` 或 `;`，因为它们是 ProxySQL 管理凭据的分隔符。
脚本中的密码和 webhook 值按 shell 字面量转义，文件权限为 root 专用的 0700。

传统主从需要 `mysql_group` 对应的 inventory 组以及其中的 `primary_host`；地址优先取
`ansible_host`，其次 ansible_ssh_host、网络 facts、inventory 名称。跨主机使用 facts 时
需要提前收集。以 `dba_ray.proxysql` 安装本 Role 后，可运行示例：

```bash
ansible-playbook -i inventory.yml tests/deploy.yml \
  -e deploy_hosts=proxysql_dev1 -e env=dev1
```

必须显式提供 deploy_hosts，因为 playbook 的 hosts 表达式求值时 Role 默认变量还未加载。
示例逐台运行，任一节点失败即停止。`whether_with_mysql: true` 只跳过客户端安装，
不跳过依赖要求，需要事先装好三个 MySQL 客户端命令。
`whether_uninstall` 默认关闭；开启会生成外部冷备、卸载并删除 datadir，不适合日常更新。
数据目录和恢复目录必须使用无空格的规范绝对路径，不能指向根目录、系统目录或包含 `..`。

首次安装创建数据库；重复执行使用已有管理员密码，不会将已有数据库重置为默认密码。
已有 `proxysql.db` 时，ProxySQL 从数据库加载配置，修改 cnf 不会自动更新所有运行变量、
规则和监控组。Role 只通过管理模块更新明确管理的账号、密码和传统主从的主节点。
其他配置需通过管理 SQL 执行对应 LOAD/SAVE；端口或 datadir 的变更需要单独安排迁移。
不要用 `--initial` 重建数据库来应用普通配置变更。

### 固定主库的账号

在 group_vars 或 Vault 中设置 `proxysql_primary_users`，每项包含基础用户名和密码。
原用户名继续读写分离，Role 额外创建同密码的 `<username>_single` 用户并固定走主库。
默认列表已经为 root、业务用户和 audit 创建对应的 `_single` 账号：

```yaml
proxysql_primary_users:
  - { username: report_writer, password: "{{ vault_report_writer_password }}" }
  - { username: billing_writer, password: "{{ vault_billing_writer_password }}" }
```

Role 会把原用户和 `_single` 用户都加入 `mysql_users`；后者默认 hostgroup 为
`writer_hostgroup`，并生成高优先级用户名规则。`_single` 用户的 SELECT、UPDATE、事务和其他
请求都固定发送到主库，不会被通用 SELECT 规则改道。基础账号名只能包含字母、数字和下划线，
不能本身以 `_single` 结尾，也不能使用 admin、监控账号或 `global`；
密码不能包含 `:` 或 `;`。规则 ID 从 `primary_user_rule_start` 开始，默认预留 10 至 99，
不要让自定义规则占用这一段。删除列表中的账号不会自动删除 ProxySQL 中原有账号，需通过
管理模块显式设置 `state: absent`，避免误删仍在使用的凭据。

## 升级与恢复

```bash
ansible-playbook -i inventory.yml tests/upgrade.yml \
  -e deploy_hosts=proxysql_dev1 -e proxysql_upgrade_package=your-package.deb
```

升级前校验安装包和现有管理连接；随后停止原本运行的 keepalived，再停止 ProxySQL。
数据库、存在的 WAL/SHM 和配置会冷备到 `upgrade_backup_root` 加随机后缀的外部目录。
包管理器原地升级，不先卸载，也不依赖可能不存在的 `.rpmsave`。
升级后更新维护脚本，检查认证 SQL 和至少一个 ONLINE writer，再恢复原先运行的 keepalived。
ONLINE 只是 ProxySQL 当前监控状态，不能代替真实业务读写验收。

失败后不恢复 VIP，并尝试停止 ProxySQL，其余节点停止滚动升级。报错会给出恢复目录。
不会盲目降级或覆盖数据库，因为新版本可能迁移了数据库格式。
人工恢复需要先隔离流量并确保服务停止，安装原版本包，再从同一次冷备恢复数据库及其 WAL，
恢复配置、属主和权限，不要混用不同时间的数据库与 WAL。启动后验证管理连接、后端及
业务读写，最后恢复 keepalived。冷备目录按运维策略人工归档和清理。

## 备份、压缩与日志

默认由 root cron 每 8 小时备份 main 配置库，成功后才清理旧备份；SQL dump 不包含业务数据，
也不等同于升级前整套冷备。先写临时文件，检查命令状态和文件非空，再原子重命名。
dump 失败删除不完整文件；最终重命名失败保留临时文件供排查。

digest 落盘只临时修改 runtime 开关，然后恢复原值，不保存其他 ADMIN 变量。
正常退出及 TERM/INT 会尝试恢复；SIGKILL 或掉电无法执行清理，需要人工检查运行时开关。
备份和 GR 脚本分别持有 flock 锁；并发运行跳过，锁路径不可用则返回环境错误，不静默回退。
SQL 默认硬超时 30 秒，dump 默认 300 秒，可调整 admin_query_timeout、backup_dump_timeout。
保留天数必须为正整数；digest_flush_wait 和 alert_retry 允许设为 0。

先生成配置备份，再压缩旧事件日志。始终跳过编号最大的日志；单线程压缩、校验、确认源文件
未变化后，才发布压缩包并删除原文件。保留原日志时间，按事件时间清理压缩文件。
未压缩日志、当前日志和无关文件不会被保留策略删除；压缩持续失败时需要关注磁盘空间。
主日志和两个维护日志均配置轮转，目标机需启用发行版的 logrotate cron/timer。
大小上限只在 logrotate 实际运行时检查。

返回码：0 为成功、无需调整或持锁跳过，1 为操作失败，2 为环境异常；
信号终止可能返回 130/143 等标准信号码。详细信息见 backup.log、auto_adjust.log 和系统日志。

## GR 自动路由与告警

开启 enable_group_replication 后生成 GR 配置并每分钟检查路由，group_replication_active
默认 1，人工设为 0 时脚本保持不变。按 hostname + port 统计节点，避免 writer/reader 重复计数。
不可用节点达到半数或没有独立在线读副本时允许 writer 承担读请求，副本恢复后关闭此选项。
人工策略 writer_is_also_reader=2 保持不变。

仅调整指定组；修改后读取 runtime 验证，成功后才发送通知。查询失败、结果异常、全部离线
或没有在线 writer 时不修改配置，也不关闭监控、调度器和查询规则，以便节点恢复后继续检测。
持续故障每次 cron 都会记日志并告警。脚本不是选主工具，不负责恢复失去仲裁的 MySQL 集群。

公共 notify.sh 支持钉钉和企业微信，URL 可带或不带 https://，HTTP 错误、缺少成功码或
非零 errcode 均按失败有限重试。message_type=none 关闭通知；通知失败不会撤销已经成功的路由调整。

## 验证范围

```bash
bash tests/test_helpers.sh
ansible-playbook -i inventory.yml tests/deploy.yml \
  -e deploy_hosts=proxysql_dev1 --syntax-check
```

离线测试使用临时文件和模拟命令，覆盖备份失败、digest 恢复、日志保护、告警重试、
GR 故障分支及锁错误，不连接真实服务器或 webhook。测试只替换 shell 模板中的 fixture
参数，不代替实际 Ansible 渲染、模块检查和系统集成测试。
上线前需在相同版本的 Linux 测试机验收首次部署、重复执行、真实备份恢复、成功/失败升级、
读写与事务、锁定读及后端故障切换。离线测试通过不能证明实际部署环境已经稳定运行。
