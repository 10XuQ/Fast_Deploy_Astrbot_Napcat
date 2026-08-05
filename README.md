# AstrBot + NapCat 一键部署脚本

面向国内网络环境的 QQ 机器人一键搭建脚本。无需 Docker、纯 Shell 实现，在一台 Debian/Ubuntu 服务器上执行一行命令，即可自动完成 **AstrBot**（机器人框架，对接各大 AI 模型）与 **NapCat**（QQ 协议端）的安装、配置、启动与守护。

- 作者：须知Ntk（[GitHub](https://github.com/10XuQ)）（[Bilibili](https://space.bilibili.com/392332353)）
- 脚本 & README由 DeepSeek v4 flash 0731 编写

## 特性

- **零 Docker**：全程 Shell 脚本，不引入容器，对服务器几乎无额外负担
- **国内网络优化**：PyPI 走清华镜像源、GitHub 下载自动走加速代理（失败自动回退直连）、uv 下载 Python 解释器也走加速
- **一键部署两大件**：
  - AstrBot：官方推荐的 uv/CLI 方式安装（从软件源安装，无需 git clone 源码），自动初始化数据目录
  - NapCat：AppImage 便携版（自带 QQ + NapCat，一个文件零污染），自动补装 Electron/QQ 运行库、自动处理 FUSE/root 沙箱等运行问题
- **交互式引导**：欢迎 Banner + 系统概览（发行版/内存/磁盘/已安装状态），可交互选择安装组件
- **防重复部署**：自动检测已安装组件，默认跳过，避免重复安装破坏环境
- **进度动画**：安装等待时显示单行动画 + 秒数，失败自动回显日志尾部
- **网络日志透明**：所有下载请求带超时/重试/分阶段耗时统计，卡住一眼可定位
- **守护体系**：崩溃自动拉起（30 秒检测）、systemd 开机自启、`bot` 状态面板、每周一 10:00 自动重启
- **保姆级收尾**：自动提取 AstrBot 初始密码、读取 NapCat WebUI token、引导输入 QQ 号自动生成 onebot11 配置（含 16 位随机 token）
- **配套清零脚本**：一条命令回滚所有部署痕迹，方便反复测试

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Debian 10+ / Ubuntu 20+（基于 apt，其他发行版请用官方脚本） |
| 架构 | x86_64 (amd64) / aarch64 (arm64) |
| 权限 | root 或 sudo |
| 内存 | 建议 2G 以上 |
| 网络 | 需能访问 GitHub（脚本已做国内加速，但 NapCat 登录 QQ 仍需正常网络） |

## 快速开始

```bash
# 1. 上传或下载 deploy.sh 到服务器（当前目录）
# 2. 执行（交互引导模式）
bash deploy.sh
```

按照提示选择要安装的组件（1=全部，2=仅 AstrBot，3=仅 NapCat，4=退出），等待安装完成即可。

### 命令行参数

```bash
bash deploy.sh --astrbot-only     # 只装 AstrBot
bash deploy.sh --napcat-only      # 只装 NapCat
bash deploy.sh --source           # AstrBot 改用 git clone 源码方式安装
bash deploy.sh --napcat-installer # NapCat 改用官方一键脚本方式安装
bash deploy.sh -h                 # 查看帮助
```

## 部署完成后

### 访问地址

| 服务 | 地址 | 说明 |
| --- | --- | --- |
| AstrBot 管理面板 | `http://服务器IP:6185` | 首次登录用启动日志中的随机初始密码，登录后请立即修改 |
| NapCat WebUI | `http://服务器IP:6099` | 登录密钥 token 部署时已打印，请妥善保管 |

> 云服务器请手动在控制台/安全组放行端口 **6185、6099**。

### 端口说明

- `6185`：AstrBot 管理面板（WebUI）
- `6099`：NapCat WebUI
- `6199`：AstrBot 反向 WebSocket 端口（NapCat 与 AstrBot 内部通信，无需对外放行）

### 连接 NapCat 与 AstrBot

部署结束时会引导输入机器人 QQ 号，并自动生成 NapCat 的 `onebot11_<QQ号>.json`（反向 WebSocket 客户端配置，已写入 16 位随机 token）。然后在 AstrBot 面板中：

1. 机器人 → 创建机器人 → **OneBot v11**
2. 反向 WebSocket 主机地址填 `0.0.0.0`，端口填 `6199`
3. 反向 WebSocket Token 填部署时打印的同一串 token
4. 保存后 AstrBot 控制台出现 `aiocqhttp(OneBot v11) 适配器已连接` 即成功

## 守护体系

安装完成后会自动部署守护体系（`setup_guardian`）：

- **崩溃自愈**：守护脚本每 30 秒检测，AstrBot/NapCat 意外退出自动重启
- **开机自启**：通过 systemd 服务 `astrbot-guardian.service` 托管
- **定时重启**：每周一 10:00 自动重启两个服务（防内存泄漏/卡死，已去重不会重复重启）
- **状态面板与别名**（写入 `~/.bashrc`）：

```bash
bot          # 查看 AstrBot/NapCat 运行状态、系统资源
botlog       # 跟踪守护日志 (tail -f /var/log/astrbot/guardian.log)
botscreen    # 进入 screen 会话 (astrbot / napcat)
botrestart   # 重启守护服务
```

部署时会询问是否启用守护体系与 4G swap（可选）。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `deploy.sh` | 主部署脚本 |
| `clean_all.sh` | 清零脚本，回滚所有部署痕迹 |

部署后在服务器上生成的关键文件：

| 路径 | 说明 |
| --- | --- |
| `/root/astrbot-data/` | AstrBot 数据目录（配置/插件/日志） |
| `/root/NapCat.AppImage` | NapCat 便携版本体 |
| `/root/astrbot-guardian.sh` | 守护脚本 |
| `/etc/systemd/system/astrbot-guardian.service` | 守护 systemd 服务 |
| `/root/bot-status.sh` | 状态面板 |
| NapCat 配置目录（自动探测） | 含 `webui.json`（WebUI token）、`onebot11_<QQ号>.json`（连接配置） |

## 清零脚本

想完全回滚部署、恢复服务器原样，或重复测试：

```bash
bash clean_all.sh            # 交互确认后全部清除
bash clean_all.sh --force    # 跳过确认直接清除
```

## 常见问题

**Q1：AstrBot 初始密码没看到 / 忘了怎么办？**

```bash
cd ~/astrbot-data && astrbot run --reset-password
```

会重新生成初始密码并打印在启动日志中。

**Q2：AstrBot 面板打不开？**

确认 `6185` 端口已在安全组放行；若仍不行，编辑 `~/astrbot-data/data/cmd_config.json`，将 `dashboard.host` 改为 `0.0.0.0` 后重启。

**Q3：NapCat 连不上 AstrBot（适配器一直未连接）？**

检查三点：onebot11 配置里的反向 WS URL 是否为 `ws://<服务器IP>:6199/ws`；两边的 token 是否完全一致；`6199` 端口是否可达。

**Q4：下载超时/失败？**

脚本头部可更换加速源：编辑 `deploy.sh` 中的 `GH_PROXY`（当前 `https://gh-proxy.com/`），失效时可换 `https://ghfast.top/`，或留空 `GH_PROXY=""` 改直连。

**Q5：显示"检测到已部署，是否跳过"？**

这是防重复部署机制。选择跳过（默认）不会动现有环境；选择 n 会重新安装。

## 开源许可

本项目基于 **MIT License** 开源（见 [LICENSE](LICENSE)），可自由使用、修改、商用，仅需保留版权声明。

## 免责声明

- 遵守 Astrbot & NapCat 使用条款
- 脚本仅供学习交流使用

