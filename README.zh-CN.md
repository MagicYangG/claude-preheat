# claude-preheat

[English](README.md) | **简体中文** | [日本語](README.ja.md) | [한국어](README.ko.md)

https://github.com/user-attachments/assets/b0614c1a-fe78-4464-a11e-aaeb1794829e

针对在 Windows 或 macOS 上使用 Claude Code CLI 的 Claude 订阅用户，本工具提供可视化的窗口额度定时预热：5 小时额度窗口由额度空窗期的第一条消息锚定，定时发出一条极小的 ping 就能把窗口抢先锚在你规定的时刻，让你真正开展工作时可以横跨两个 5 小时额度窗口。具体包含：

1. 以周为维度，窗口额度定时预热
2. 一次性窗口额度定时预热
3. **Codex（beta）**：同样的预热也能给 OpenAI Codex 用，见 [Codex (beta)](#codex-beta)

## 可视化控制面板

本机地址：`localhost:7878`（中/英双语，页头一键切换）

模块：实时额度条（5 小时 + 周限，含精确重置时刻——跑一次 `preheat statusline on` 即可喂入）/ 每周重置时刻编辑器（写入 `schedule.json` 并直接生效）/ 一次性预热 / 近 7 天窗口利用率小结（由 `preheat learn` 驱动）/ 页顶 Claude | Codex 切换（Codex 为 beta）

![控制台](docs/panel.zh-CN.png)

## 快速开始

**环境要求**：Windows 10/11 或 macOS 13+（macOS 安装见 [macOS 指南](docs/MAC-BETA.md)）；已安装并登录 [Claude Code CLI](https://code.claude.com/docs)；Claude 订阅用户；PowerShell 7（pwsh）；无需管理员权限；只预热 Codex（beta）的话不需要 Claude Code 和 Claude 订阅，见 [Codex (beta)](#codex-beta)

**推荐安装方式：把下面这段直接粘给 Claude Code（或其它 AI 编程工具），让它替你装好：**

```text
克隆 https://github.com/MagicYangG/claude-preheat 并完成安装：
1. git clone 后，在仓库目录里运行 install.ps1
2. 问我每周希望窗口重置的时刻，写进 schedule.json
   （reset 填目标重置时刻，预热时刻自动 = reset 减 5 小时）
3. 运行 ./test.ps1，确认全部用例通过
4. 运行 preheat apply，把 preheat status 的输出结果给我看
除 install.ps1 和 preheat apply 创建的内容外，不要注册或改动任何东西。
```

装完在浏览器打开 `http://localhost:7878`，用可视化控制面板操作。

**手动安装有三步**：`git clone` → `./install.ps1` → 新开终端跑 `preheat apply`。全部命令见文末[命令参考](#命令参考)。

## 注意事项

1. **需要安装 Claude Code CLI**（只用 Codex 可不装）：预热就是通过 CLI 发出的一条极小 headless 提示词
2. **一次 ping 的成本**：一条极短的 `haiku` 提示词——算上 Claude Code 自身的系统提示词，大约 4 万 input tokens（按 API 价格约 $0.04）。它会同时计入 5 小时窗口和周窗口，所以预热便宜但不是免费的。ping 到已激活的窗口不会移动锚点。若**定时**预热落进了仍在运行的窗口，会补排一次跟进预热，定在该窗口到期的那一分钟（当天就是两次 ping）——每个窗口最多一次，下一次定时预热先到时不补；在 `schedule.json` 里加 `"chase": false` 可关闭。面板里你没排过的一次性任务就是这种跟进预热。周窗口不由本工具管理。
3. **睡眠中唤醒**：定时任务要把电脑从睡眠中叫醒，须在当前电源计划里启用唤醒定时器——关着时 `preheat status` 会给出警告（此为 Windows 机制；launchd 无法唤醒睡眠中的 Mac，详见 [macOS 指南](docs/MAC-BETA.md)）。跟进预热不会唤醒睡眠中的电脑：那一分钟机器睡着就直接跳过。
4. **额度窗口是账号级的**：claude.ai、Claude 桌面端与 Claude Code 的用量共享同一个池子，预热锚定的是整个账号的窗口——CLI 只是点火针
5. **预热什么时候能点火、什么时候不能（Windows）**：任务只在你登录时运行（锁屏没问题；注销状态下会跳过这次点火）。现在也支持在电池供电下运行。如果你是在这次改动之前安装的，请再跑一遍 `preheat apply`，让已注册的任务应用新设置。
6. **`preheat apply` 之后不要移动或重命名仓库目录**：计划任务、launchd plist 和配置文件里的函数都写死了绝对路径。如果确实挪动了，请重新运行 `install.ps1` 和 `preheat apply`——`preheat status` 会标出脚本路径已不存在的任务。

## Codex (beta)

Codex 支持目前是 beta。同一套 `schedule.json`、面板和计划任务，也能给 OpenAI Codex 的 5 小时窗口做预热；两边各排各的，互不影响。内测说明和怎么贴回证据见 [Codex beta 指南](docs/CODEX-BETA.md)。

**要求**：已安装 [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) 或 Codex 桌面端，并用 ChatGPT 账号登录（API key 登录没有 5 小时窗，不会 ping）。Plus 等有 5 小时窗的套餐可用；Free / Go / Pro 读不到 5 小时窗时直接跳过、不花额度（Go 实测只有 30 天窗）；其他套餐读不到时照样 ping、会花额度。只预热 Codex 不需要 Claude Code 和 Claude 订阅。

**启用**：可以直接让 AI 编程工具帮你配（说一句「把 Codex 预热设成工作日 15:00 重置」），也可以打开面板，切到页顶的 Codex 标签，选好时刻后应用（只动 Codex 一边）。手改的话，在仓库目录的 `schedule.json`（install.ps1 生成）里加一个 `codex` 键，和现有的 `rules`、`proxy` 同级（上一项末尾补逗号；预热时刻同样 = reset − 5h）：

```json
"codex": { "rules": [ { "days": ["Mon", "Tue", "Wed", "Thu", "Fri"], "reset": "15:00" } ], "chase": true }
```
然后跑 `preheat apply -Provider codex`。只用 Codex 的话，把顶层 `rules` 设为 `[]`，或者一直带 `-Provider codex`；否则普通 `preheat apply` 会去找 claude，找不到就报错。

**检查**：跑 `preheat status -Codex`（只读，不花额度），能看到套餐、5 小时窗和已注册的 `ClaudePreheat-Codex-*` 任务就行；想马上试一次用 `preheat +2m -Codex`。

**每次点火**（定时发 ping 的那一刻）：
1. 先免费读一次额度；窗口在跑就不发 ping，只在它到期后约 2 分钟补一次跟进预热（同 `chase` 规则）
2. 空窗才发一条极小的 ping；读额度本身失败（网络、代理、超时）时也照发
3. 连续 2 次 ping 后窗口还是没起来，之后的点火停发 ping 并通知一次，直到你再跑 `preheat apply`

**成本**：每次 Codex ping 都花真实额度，5 小时额度和周额度都算；只有读额度是免费的。

**注意**：
1. 只装桌面端也能用：每次点火都现找 codex 可执行文件。找不到时，Windows 上设用户级环境变量 `PREHEAT_CODEX_EXE` 指向它的完整路径；macOS 上把 codex 所在目录加进你跑 `preheat apply` 的那个终端的 PATH
2. 改过 `CODEX_HOME` 的话，在设着它的终端里跑一次 `preheat apply`，它会写进 `codex.home`；`proxy` 两边共用；两边都排时，Windows 一晚可能被唤醒两次
3. 退出：`preheat off -Codex` 只删 Codex 任务，但只要 `codex` 段还在，下次普通 `preheat apply` 会重新注册；要彻底关掉就删掉 `codex` 段（没有这一段 = Codex 关闭）

## 接续（relay）去哪了？

v0.2.0 曾内置跨额度自动续跑（relay）。Claude Code v2.1.234 起 CLI 原生支持撞限自动续跑（默认开启，见 `/config` 的 "Continue automatically at usage limit"），relay 遂于 v0.3.0 退役；最后一个含 relay 的版本保留在 [v0.2.0](https://github.com/MagicYangG/claude-preheat/releases/tag/v0.2.0) 标签。原生功能不做的事——在你坐下之前把窗口提前启动——正是 preheat 做的事。

## 命令参考

推荐使用可视化控制面板。若要使用终端命令操作，可参照下文。

```powershell
preheat apply           # 按 schedule.json 注册每周预热任务（改表后重跑即生效）
preheat status          # 本机活动 + 排定任务 + 最近记录
preheat reset 20:00     # 一次性：让窗口在 20:00 重置（自动 15:00 预热）
preheat at 15:00        # 一次性：15:00 预热
preheat +2h             # 一次性：2 小时后预热
preheat learn           # 按最近 30 天作息给出排期建议 + 窗口利用率报告（learn auto 一键写入并生效）
                         # （统计的是你自己发的消息节奏；preheat 的 ping 不计入其中）
preheat statusline on   # 透传接入 statusline，让精确重置时刻喂入面板额度条（纯透传；off 还原）
preheat off             # 移除全部预热任务
preheat status -Codex   # 现场读一次 Codex 额度：账号、套餐、5 小时窗和周窗、重置时刻有没有被推后、最近几次点火
preheat report -Codex   # 输出脱敏后的 Codex 点火证据，贴进 issue 用
preheat apply -Provider codex  # 只装 Codex 一边（不带参数 = 两边一起）
preheat at 10:00 -Codex # 一次性 Codex 预热；reset / +2h 同样加 -Codex
preheat off -Codex      # 只移除 Codex 预热任务（不带 -Codex = 两边都移除）
claude-panel            # 打开本地可视化控制面板
```

`schedule.json` 里 `reset` 填**目标重置时刻**，预热时刻自动 = reset − 5h；`proxy` 留空表示不经代理。

## 卸载

```powershell
preheat off             # 移除全部预热任务
preheat statusline off  # 还原原始 statusline（若开启过透传）
```

然后删除 PowerShell 配置文件（`$PROFILE.CurrentUserAllHosts`）里 `# >>> claude-preheat functions >>>` 到
`# <<< claude-preheat functions <<<` 之间几行（旧版安装的标记可能是
`claude-limit-relay`），再删除本仓库目录。

Codex 的运行文件（`state-ratelimits-codex.json`、`firepit-codex/`、`.fire-codex.lock`）都在仓库目录里，随目录一起删掉；设过 `PREHEAT_CODEX_EXE` 的话也把它删掉。preheat 不碰 Codex 自己的登录。
