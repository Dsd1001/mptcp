# MPTCP 聚合与定时切换交互式部署工具

发布安装包：运行 `bash scripts/package-public.sh`，输出到 `dist/`。
发布脚本采用文件白名单，扫描源码目录和压缩包，并排除本地部署报告与旧归档。
示例地址均用于文档或本机测试。自动扫描不能识别所有敏感信息，发布前仍应人工检查。

同一套脚本支持 **Edge、Relay、Landing** 三种角色。Edge 入口端口、每台 Relay 公网端口、Landing 应用监听端口、A/B 切换时间和时区均可独立配置。

新安装向导默认选择 `aggregate` 常驻聚合模式，两台或更多 Relay 同时参与同一 TCP 连接的 MPTCP 子流。`scheduled` 模式保留按时间切换 A/B 组的功能，默认香港时区 A 组 `01:00–20:00`。旧配置未写 `MODE` 时仍按定时模式处理。

## 两台 Relay 聚合

使用 `examples/aggregate-edge.conf`、`examples/aggregate-landing.conf`，或在向导中选择 `aggregate`。关键配置：

```ini
MODE=aggregate
GROUP_A=192.0.2.1,192.0.2.2
PRIMARY_A=192.0.2.1
GROUP_B=
PRIMARY_B=
RELAY_PORT=21001
RELAY_PORTS=192.0.2.1:21001,192.0.2.2:21002
LANDING_PORT=22000
SUBFLOWS=2
ADD_ADDR_ACCEPTED=2
REQUIRE_TIME_SYNC=no
```

两台 Relay 都作为正常路径参与传输，不设置 `backup` 标志；`PRIMARY_A` 只选择初始连接，不代表另一台仅供故障备用。Landing 公布所有聚合 Relay 地址，Linux 调度器根据拥塞窗口、时延和可用容量分配数据，不保证固定各 50%。低流量时可能只需一条路径。

聚合模式不需要 B 组，也不根据 `A_START/B_START` 切换；定时器只有约 60 秒的健康检查，没有日历触发。初始 Relay 故障时控制器可能更换入口并重启客户端，已有连接会中断。单连接聚合是否有效，应看接收端吞吐及同一连接的各子流字节增长，而不只是子流数量。

已在 Linux amd64/arm64 环境验证单连接多路径聚合及故障恢复。公开版本仅保留[验证范围与方法](docs/VALIDATION.md)，不包含实际部署机器的信息或原始日志。

## 交互安装

把完整安装包解压到目标 Linux 机器，进入目录运行：

```bash
sudo ./install.sh
```

菜单可选择 `install`、`reconfigure`、`plan`、`doctor`、`uninstall`。建议按 **Landing → 各台 Relay → Edge** 的顺序部署。也可以直接进入角色向导：

```bash
sudo ./install.sh install --role landing --install-deps
sudo ./install.sh install --role relay --install-deps
sudo ./install.sh install --role edge --install-deps
```

向导会询问：

- 当前机器角色、Relay 默认公网端口、Landing 应用 MPTCP 端口。
- Edge/Landing：聚合或定时模式、同时工作的 Relay IPv4、初始 Relay、逐台公网端口。
- 定时模式额外询问 B 组、时区、A/B 组开始时间。支持 `08:30` 或 `0830`，支持跨午夜。
- Edge：本地监听 IPv4 和端口、切换延迟、全组故障处理。
- Relay：本地接收地址、Landing 可达 IPv4 地址。
- Landing：可选的应用 systemd 服务名。
- 网卡、时间同步、FQ、BBR。

端口、IP、组成员和切换时间不合法时会重新提示。安装前显示计划并最终确认。依赖自动安装仅支持 Debian/Ubuntu 的 `apt-get`。

## 交互配置清单

直接运行 `sudo bash install.sh` 进入菜单，无须预先手写配置文件；需要连同 lib、bin、payload、systemd 等目录一起解压完整包。修改已有部署选择 `reconfigure`，回车保留原值。

| 类别 | 向导可设置的内容 |
| --- | --- |
| 角色 | Edge、Relay、Landing |
| 工作模式 | 多 Relay 常驻聚合，或 A/B 定时切换 |
| Edge 入口 | 监听 IPv4、TCP 端口，允许回环或公网监听 |
| Relay | 2-8 台聚合 Relay IP、初始连接 Relay、默认公网端口、逐台端口覆盖 |
| Relay 转发 | 本地接收 IPv4、Landing 可达 IPv4、Landing TCP 端口 |
| Landing | MPTCP 监听端口、实际 TCP 后端 IPv4:端口；使用本包服务端或外部原生 MPTCP 应用 |
| 定时模式 | A/B 组成员与初始 Relay、时区、两组开始时间、Edge 切换延迟 0-60 秒、是否要求时钟同步 |
| 故障处理 | 所有探针失败时是否仍尝试首选 Relay；选择 no 则保留旧目标并报错 |
| 网络设置 | 网卡名或自动检测、是否配置 FQ、是否启用 BBR |
| 可选高级设置 | endpoint ID 起点 1-247、额外子流上限 0-8、接收远端地址上限 0-8 |
| Edge 高级探测 | 单次探测超时 1-60 秒、探测次数 1-10，总探测预算不超过 180 秒 |

聚合模式的子流和远端地址上限不能低于 Relay 数量减一，向导会检查范围。
高级设置默认可跳过，重新配置时保留原值；若增加 Relay，最低子流容量会随之提高。

目前约 60 秒的健康检查周期、隧道最大连接数和 TCP 连接寿命/keepalive 等由随包 systemd 单元指定，不属于当前交互配置项。聚合分流比例由 Linux MPTCP 调度器决定，没有固定 50/50 权重选项，也没有程序内置的 90 Mbps 限速；90 Mbps 仅用于此前短时测速。

只体验向导并查看计划，不需要 root，也不改系统：

```bash
./install.sh plan --role edge
./install.sh plan --role relay
./install.sh plan --role landing
```

## 各段端口独立配置

```text
业务客户端 → Edge :10029
                  ├→ Relay A1 :21001 ─┐
                  ├→ Relay A2 :21002 ─┼→ Landing :22000（原生 MPTCP 应用）
                  └→ Relay B1 :31001 ─┘
```

Edge/Landing 配置示例，Landing 上将角色改为 `ROLE=landing`：

```ini
ROLE=edge
LISTEN_ADDRESS=0.0.0.0:10029
RELAY_PORT=21000
RELAY_PORTS=192.0.2.1:21001,192.0.2.2:21002,192.0.2.3:31001
LANDING_PORT=22000
GROUP_A=192.0.2.1,192.0.2.2
PRIMARY_A=192.0.2.1
GROUP_B=192.0.2.3
PRIMARY_B=192.0.2.3
TIMEZONE=Asia/Hong_Kong
A_START=0830
B_START=2345
```

`RELAY_PORT` 是默认公网端口；`RELAY_PORTS` 按 IP 覆盖，可为空。未覆盖的 Relay 使用默认值。每组最多 8 个 IPv4，同组不能重复、两组不能重叠，primary 必须属于对应组。旧配置未设置 `LANDING_PORT` 时会沿用 `RELAY_PORT`。

对应 Relay A1 的配置：

```ini
ROLE=relay
RELAY_LISTEN_ADDRESS=0.0.0.0
RELAY_PORT=21001
LANDING_ADDRESS=198.51.100.10
LANDING_PORT=22000
```

文档中的 `192.0.2.*`、`198.51.100.*` 是示例地址，部署时替换。Relay 使用 DNAT/MASQUERADE 转发 TCP，不终止 MPTCP。`RELAY_LISTEN_ADDRESS=0.0.0.0` 匹配所有本机目的地址；云主机有公网到私网映射时，显式地址应填写本机实际收到流量的私网地址。

## MPTCP 子流与端口映射

Landing 在聚合模式发布所有 Relay IP，定时模式发布当前组除 primary 外的 Relay IP，不在 endpoint 中设置公网端口。Edge 客户端和内核子流统一使用 `LANDING_PORT` 作为逻辑目的端口，Edge 本机 nftables OUTPUT DNAT 将它转换为对应 Relay 的公网端口。Relay 再转发到 Landing 实际应用端口。

初始连接和后续 MP_JOIN 因而经过相同映射。`active-server` 中看到的是逻辑端口，`plan` 和 `probe` 显示公网端口。Edge 客户端、MPTCP 配置和 nftables 规则必须处于同一 network namespace。

受管规则只在带归属注释的 `ip mptcp_ab_edge`、`ip mptcp_ab_relay` 两张表中。更新先执行 `nft --check`，再原子替换；遇到同名非受管表拒绝覆盖，不执行 `flush ruleset`。Edge 映射影响发往这些 Relay IP/逻辑端口的本机 TCP 流量，因此该组合应专用于隧道。

Relay 会开启 IPv4 forwarding 并配置对应转发和回程 NAT。**已有防火墙 DROP、云安全组、其他 NAT 规则仍需允许流量**，独立表中的 ACCEPT 不会绕过其他表的 DROP。已有转发规则的 Relay 可继续原配置，无须安装本工具，但各公网端口必须转发到同一 Landing 应用端口。

## Landing 和平台要求

Landing 向导默认安装本包的 MPTCP 服务端，转发到自定义 `LANDING_BACKEND=IPv4:端口`，并设置 `LANDING_SERVICE=mptcp-port-tunnel-server.service`。也可选择已有原生 MPTCP 应用模式。脚本**不会修改第三方应用的配置**。外部应用模式需要应用在 `LANDING_PORT` 上创建原生 `IPPROTO_MPTCP` listener。以端口 22000 为例：

```bash
ss -4 -H -lnM 'sport = :22000'
```

必须有监听记录。普通 TCP listener 加上 `net.mptcp.enabled=1` 不够。Landing 应用和 endpoint 必须在同一 network namespace，容器通常需要 host networking。

Edge/Landing 需要 Linux MPTCP、systemd、较新 iproute2；Relay 只需 Linux 转发和 systemd。三种角色均使用 nftables 和 jq。

包内同时包含 Linux amd64、arm64 二进制，均由本次新写的 `tunnel/` Go 源码编译，不使用历史隧道二进制。安装器自动选择架构并验证校验值及 CLI；Relay 使用内核 NAT，不需要隧道进程。重新编译：`MPTCP_GO=/path/to/go bash tunnel/build.sh`，要求 Go 1.23+。

数据链路为：普通 TCP → Edge 客户端 → Relay NAT → Landing MPTCP 服务端 → 指定 TCP 后端。客户端和服务端均拒绝普通 TCP 降级。目前支持 IPv4 TCP，不提供 UDP 或额外加密、认证；应由后端应用协议提供所需认证和加密。

Linux 6.1 不支持对 MPTCP socket 设置 `TCP_USER_TIMEOUT`，程序会记录一次提示，并继续执行应用层写入超时、空闲和连接年龄限制。应用层写入超时不等同于内核未确认数据超时。

`payload/SHA256SUMS`、`payload/SOURCE_SHA256SUMS` 和 `payload/BUILDINFO` 分别记录二进制校验值、对应源码校验值与构建工具版本。验证范围见 `docs/VALIDATION.md`。

## 非交互安装与重配

修改 `examples/edge.conf`、`examples/landing.conf`、`examples/relay.conf` 后：

```bash
./install.sh plan --config examples/edge.conf --non-interactive
sudo ./install.sh install --config examples/edge.conf --non-interactive --yes --install-deps
```

配置安装到 `/etc/mptcp-ab/config.conf`。严格使用 `KEY=VALUE`，不写引号或 shell 表达式，文件不会作为 shell 执行。

```bash
sudo ./install.sh reconfigure
sudo ./install.sh reconfigure --config ./new.conf --non-interactive --yes
```

交互重配读取已安装配置作为默认值。更改端口、Relay 或时间表时使用 `reconfigure`，让网络规则、客户端 env 和 timer 一起更新。Edge/Landing 的组、primary、端口映射、时区和时间表必须一致，各 Relay 的转发端口和目标应与之匹配。

安装前配置和 unit 备份到 `/var/lib/mptcp-ab/backups/`。文件部署不是整机快照事务；更改网络配置应安排维护窗口。

## 切换和恢复

Edge 保持当前健康 Relay，失败后依次尝试 primary 和其他组成员。每轮完成约 60 秒后检查一次；切组时 Landing 更新 endpoint，Edge 默认延迟 `0.5` 秒。两端独立计算，没有中心控制机，延迟不构成跨机同步保证。

`FAIL_OPEN=yes` 时全组故障仍尝试 primary；`no` 时保留上次目标并失败，定时服务随后重试。无显式 `--group` 的定时、启动、手动切换都会在探测和事务后重新检查时段。

Landing 修改 endpoint 前持久化事务记录。进程中断后，下次切换或清理先恢复旧 endpoint、limits 和归属状态，再执行新操作；外部 endpoint 冲突仍拒绝覆盖。已提交归属在 `landing-runtime.state`，未完成事务在 `landing-transaction/`。

```bash
sudo mptcp-abctl status
sudo mptcp-abctl doctor
sudo mptcp-abctl probe A                 # Edge
sudo mptcp-abctl probe B                 # Edge
sudo mptcp-abctl plan --group B
sudo mptcp-abctl switch                  # Edge/Landing，按当前时间
sudo mptcp-abctl switch --group B        # 仅强制本次
sudo mptcp-abctl network-plan            # 查看生成的 nftables 规则
sudo mptcp-abctl network-apply           # 应用当前角色网络规则
```

强制整条链路切组时先 Landing、后 Edge。timer 下一次会恢复时间表；持续手动锁组需先停两端 timer。Relay 持续转发，不参与 A/B 定时切换。

## 迁移、延迟启动、卸载

发现已知旧 hard-switch 服务时默认拒绝并行接管。维护窗口使用 `--migrate` 可停止同角色旧服务并清理匹配旧 endpoint，不能与 `--no-start` 合用；迁移失败不自动恢复所有旧服务。

`--no-start` 仅部署、enable unit 并应用 sysctl，不应用新网络规则、不启动 timer 或客户端。手动启用按以下顺序：

```bash
sudo systemctl restart mptcp-ab-network.service
sudo systemctl restart mptcp-ab-bootstrap.service       # Edge/Landing
sudo systemctl restart mptcp-ab-fq.service              # ENABLE_FQ=yes
sudo systemctl restart mptcp-port-tunnel-client.service # Edge
sudo systemctl restart mptcp-ab-switch.timer            # Edge/Landing
```

受管 Landing 改为其他角色不能使用 `--no-start`，必须清理 endpoint。

```bash
sudo ./install.sh uninstall
sudo ./install.sh uninstall --purge
```

卸载删除受管网络表和服务、清理 Landing endpoint，并在 limits 未被外部修改时恢复接管前值；被替换的 tunnel binary 会恢复。默认保留配置、状态和备份，`--purge` 删除这些文件。卸载不恢复实时 sysctl（包括 IPv4 forwarding）、Edge limits 和原 qdisc。

## 验证

```bash
bash tests/run.sh
expect tests/interactive.exp
```

本地测试覆盖配置、独立端口映射规则、时段、终端交互、Edge 故障转移/回滚、Landing 中断恢复、网络表归属/替换/清理及 bundled binary 校验。终端测试需要 expect，网络表模拟测试需要 jq。

模拟测试不能替代真实 Linux 验证。上线前在三种角色执行 doctor，在 Edge 探测两组，验证实际业务、`ss -M` 子流、各公网端口映射、Relay 断开恢复和跨时段切换。
