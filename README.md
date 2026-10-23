# wechat-ipad-kit

> 微信 iPad 协议 · 可复现部署工具包
> **把「拿到协议包却跑不起来」的五个坑，变成一条命令。**

[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)]()
[![Docker](https://img.shields.io/badge/docker-required-2496ED?logo=docker&logoColor=white)]()
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## 这个项目解决什么

社区里有不少微信 iPad 协议实现（服务端、sidecar、客户端……），
但**几乎都只提供「外壳」，不含可运行的内核**——很多项目的 README 明确写着
「本仓库不包含协议内核，需自行准备外部协议服务」。

于是每个人都卡在同一串问题上：

| 坑 | 典型报错 | 为什么难 |
|---|---|---|
| ① Docker Hub 被墙 | `403 Forbidden` / `502` | 换加速器只是碰运气 |
| ② GLIBC 版本过低 | `GLIBC_2.38 not found` | 内核是闭源预编译的，你没法重编 |
| ③ 动态库加载失败 | `Failed to load library: libv08.so` | **静默失败**：服务照常启动，只有登录永远不成功 |
| ④ 路由前缀找不到 | 文档路径全部 `404` | 文档不带前缀，实际带 |
| ⑤ 扫码后登录不完成 | 手机说「已通过」，服务器却全空 | **必须显式调一次确认接口**，而多数实现是自动的 |

**本项目把 ①~⑤ 全部自动化**，你只需 `bash run.sh`。

---

## 它不是什么

为避免误解，先说清楚边界：

- ❌ **不包含协议内核**——不分发 `libv08.so` 等闭源二进制，需你自备协议源码
- ❌ **不是又一个协议实现**——不重复造轮子，而是让现成的包真正跑起来
- ❌ **不规避风控**——个人微信自动化始终有封号风险，本项目不做任何承诺
- ❌ **不提供微信官方授权**——请自行评估合规性

---

## 快速开始

### 环境要求

- macOS（Docker Desktop 或 Rancher Desktop）或 Linux x86_64（Ubuntu 22.04 / 24.04）
- macOS 上默认用本机 Go + Zig 交叉编译 Linux/amd64 程序；请安装 Go 和 Zig（`brew install zig`）
- Apple Silicon 运行时仍需要 Docker 支持 `linux/amd64` 仿真；本机 Rancher Desktop QEMU 已验证可以运行交叉编译后的服务
- Docker Engine 必须已启动；Redis 会作为 Docker 容器启动
- 服务端协议方案**不需要** Windows、微信客户端或图形界面
- 约 3GB 磁盘、1GB 内存

### 一条命令

```bash
git clone https://github.com/<you>/wechat-ipad-kit.git
cd wechat-ipad-kit
bash run.sh
```

脚本会依次：

```
[1/5] 下载 Ubuntu 24.04 rootfs  → docker import   （绕开 Docker Hub）
[2/5] 拉取协议源码                                 （走加速代理）
[3/5] 注入版本号 + 编译 Linux/amd64                  （macOS 本机交叉编译 / Linux 容器编译）
[4/5] 启动服务 → 出二维码 → 你扫码 → 自动确认登录    （解决 CheckQR）
[5/5] 健康检查                                     （判据：Uin/Wxid/Sessionkey）
```

跑完你会得到 `.state/qr.png`，用微信扫码并在手机上点【确认登录】。

### 分步执行

```bash
bash scripts/01-get-base-image.sh   # 准备基础镜像
bash scripts/02-fetch-source.sh     # 获取协议源码
bash scripts/03-build.sh            # 编译
bash scripts/04-login.sh            # 扫码登录
bash scripts/05-verify.sh           # 健康检查
```

中途失败可从指定步骤继续：

```bash
bash run.sh --from 3
```

只做检查：

```bash
bash run.sh --check
```

---

## 配置项

全部通过环境变量覆盖，无需改脚本：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `WECHAT_VER` | `0x18005020` | 客户端版本号（≈8.0.80）。被拒就调高，如 `0x18005620` |
| `SRC_DIR` | `$PWD/wechat860-src` | 协议源码目录；自备源码时指向它 |
| `SOURCE_URL` | Ipad860 main.zip | 源码下载地址 |
| `HOST_PORT` | `8058` | 服务端口 |
| `REDIS_DB` | `2` | 登录态存放的 Redis 库号 |
| `CONTAINER` | `wechat-ipad` | 容器名 |
| `DOCKER_PLATFORM` | `linux/amd64` | 协议服务容器平台；Apple Silicon 通过 Docker 仿真运行 |
| `BUILD_MODE` | `auto` | `auto`、`host-cross`（macOS + Zig）或 `docker` |
| `ZIG_BIN` | `zig` | Zig 可执行文件路径；本机交叉编译时使用 |
| `DOCKER_NETWORK` | `wechat-ipad-net` | 协议服务与 Redis 共用的 Docker 网络 |
| `BASE_IMAGE` | `ubuntu24:latest` | 基础镜像标签 |
| `BUILDER_IMAGE` | `wechat-ipad-builder:latest` | 编译环境镜像标签 |

例：

```bash
WECHAT_VER=0x18005620 bash run.sh --from 3
```

---

## 斗地主机器人

`bot/` 将 `doudizhu-master` 的斗地主规则接入当前 iPad 协议服务：复用已登录会话，通过本机 HTTP API 同步群消息和发送文本，不会再创建 Wechaty 登录或 Docker 容器。

启动前确认 `bash scripts/05-verify.sh` 显示已登录，然后将输出的 Wxid 设置给机器人：

```bash
cd bot && nvm use && cd ..
WECHAT_WXID=wxid_你的账号 npm --prefix bot start
```

若服务端地址或路由前缀不同，可设置 `IPAD_API_URL`（默认 `http://127.0.0.1:8058`）和 `IPAD_API_PREFIX`（默认读取 `.state/prefix.txt`，缺省为 `/api`）。`WECHAT_BOT_NAME` 可手动指定群内机器人的昵称，`BOT_POLL_INTERVAL_MS` 可调整消息同步间隔（默认 1500 毫秒）。Node.js 需要 20 或更新版本。

机器人启动后，在已加入机器人的群聊中 @它发送“斗地主”创建游戏；其他玩家 @它发送“上桌”，随后按群内提示抢地主和出牌。机器人需要能够向玩家私聊，以发送手牌。请将协议服务 API 保持在本机回环地址，不要直接暴露到公网。

游戏胜率和摸鱼记录保存在 `bot/data/`，不会覆盖下载目录原项目中的记录文件。

---

## 登录成功的判据

**不要**用「Redis 里有没有 key」判断——取二维码时就会写占位记录。
必须三个字段同时满足：

```
Uin        ≠ 0
Wxid       非空
Sessionkey 非 null
```

`bash scripts/05-verify.sh` 会自动校验并明确告诉你结果。

成功时 `LoginCheckQR` 返回：

```json
{"Code":0,"Success":true,"Message":"登录成功",
 "Data":{"baseResponse":{"ret":0,"errMsg":{"string":"Everything is ok"}}}}
```

---

## 常见问题

完整排错手册见 **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**，
技术备忘见 **[docs/PROTOCOL-NOTES.md](docs/PROTOCOL-NOTES.md)**。

几个最高频的：

<details>
<summary><b>手机显示「已通过」，但服务器登录态是空的</b></summary>

这个实现的登录确认**不是自动的**，扫码后必须显式调用一次：

```bash
UUID=$(cat .state/uuid.txt)
curl -X POST "http://127.0.0.1:8058/api/Login/LoginCheckQR?uuid=$UUID" \
     -H 'Content-Type: application/json' -d '{}'
```

`04-login.sh` 已自动执行。详见排错手册第 5 节。
</details>

<details>
<summary><b>微信返回 -106「你的应用版本过低」</b></summary>

版本号太旧。调高后重新编译：

```bash
WECHAT_VER=0x18005620 bash scripts/03-build.sh
```

实测 `8.0.62` 被拒，`8.0.80` 通过。详见排错手册第 6 节。
</details>

<details>
<summary><b>docker pull 失败 / 镜像源 403</b></summary>

本项目**不走 Registry**——直接下载 Ubuntu 官方 rootfs 再 `docker import`。
详见排错手册第 1 节。
</details>

<details>
<summary><b>服务起来了但登录从来不成功</b></summary>

先查动态库：

```bash
docker logs wechat-ipad 2>&1 | grep -i "Failed to load library"
```

这是静默失败，服务看起来完全正常。详见排错手册第 3 节。
</details>

---

## 目录结构

```
wechat-ipad-kit/
├── run.sh                      # 一键入口
├── scripts/
│   ├── lib/common.sh           # 公共函数（日志/下载/版本比较）
│   ├── 01-get-base-image.sh    # ① 绕开 Docker Hub
│   ├── 02-fetch-source.sh      # ② 获取源码
│   ├── 03-build.sh             # ③ 版本号注入 + Linux/amd64 编译
│   ├── 04-login.sh             # ④ 扫码 + 显式确认登录
│   └── 05-verify.sh            # ⑤ 健康检查
├── docs/
│   ├── TROUBLESHOOTING.md      # 排错手册（8 类问题）
│   └── PROTOCOL-NOTES.md       # 协议技术备忘
└── .state/                     # 运行时状态（二维码/uuid/前缀），已 gitignore
```

---

## 原理简述

**为什么用 Ubuntu 24.04 容器？**
协议内核是闭源预编译的，需要 GLIBC ≥ 2.38。用 Ubuntu 24.04 容器运行可以满足依赖，
也不需要改动 macOS 宿主。

**为什么要改版本号？**
微信服务端校验客户端版本，过低直接拒绝（`-106`）。
改版本号后从头编译，产物即携带新版本号。

**为什么 macOS 上用 Zig 交叉编译？**
Go 工具链在 Apple Silicon 的 QEMU 容器中可能崩溃。macOS 本机用 Go + Zig 生成 Linux/amd64
程序，运行时再放进 Ubuntu 24.04 容器；Linux 主机仍使用原来的容器内编译流程。

**为什么不用 docker pull？**
国内对 Docker Hub 及多数加速器访问不稳定，且部分加速器对
`library/*` 命名空间返回 403。直接取官方 rootfs 更可靠、可缓存、可离线。

---

## 免责声明

1. **本项目仅用于技术研究与学习。** 请遵守微信软件许可协议及当地法律法规。
2. **个人微信自动化存在封号风险**，风险由使用者自行承担。**强烈建议使用小号。**
3. 本项目**不包含、不分发**任何协议内核或闭源二进制，仅提供部署与排错工具。
4. 使用者需自行准备合法的协议实现，并自行评估合规性。
5. 作者不对因使用本项目造成的任何损失承担责任。

---

## 贡献

欢迎提交 issue / PR，尤其是：

- 新协议实现的适配（换 `SOURCE_URL` 即可尝试）
- 其他发行版 / 架构的验证结果
- 排错手册的新条目

提 issue 时请附 `bash run.sh --check` 的输出，
并**打码** `Wxid` / `Uin` / `Sessionkey` 等敏感信息。

---

## 致谢

本工具包的部署路径在 [meteor-nb/Ipad860](https://github.com/meteor-nb/Ipad860)
上验证通过。感谢社区中所有公开协议实现的作者。

相关项目：

- [wechat2ipad/wechat-ipad-protocol](https://github.com/wechat2ipad/wechat-ipad-protocol)
- [xiaoguiwucan/lightagent-ipad](https://github.com/xiaoguiwucan/lightagent-ipad)
- [yangsbo/PadChat-SDK](https://github.com/yangsbo/PadChat-SDK)

---

## License

[MIT](LICENSE)
