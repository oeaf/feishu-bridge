# 飞书机器人桥接：零 Token 保活方案（详细版）

> 给别人直接照着装的版本。核心就一句话：**平时一个 Token 也不花，脚本自己看心跳、自己拉起来；只有脚本修不好、且持续 10 分钟没恢复时，才叫一次 Agent。**
>
> 适用：中国飞书（open.feishu.cn）企业自建应用机器人，私聊文字 / 图片 / 视频 / 文件双向收发。国际版 Lark 需先验证 API 域名，不可直接套用。
> 本方案已在本机实测跑通：机器人常驻在线，VM 回收、进程崩溃后均自动恢复。

---

## 一、一句话原理

```
飞书用户发消息
  → 飞书长连接 WS 推送 im.message.receive_v1
  → bridge_daemon.py（常驻进程）收消息、下载附件，写入 queue/inbox/*.json
  → inbox 脚本每 15 秒扫一次队列：没消息就静默（0 Token），有消息才唤醒一次 Agent 处理
  → Agent 处理完写 queue/outbox/<message_id>-reply.json
  → daemon 每 2 秒扫 outbox，用 tenant_access_token 发回飞书
```

**没有定时重启，没有轮询调模型。** 所有“检查”都是纯 bash 脚本读本地文件，不经过大模型，所以不花 Token。

---

## 二、架构：三层分工

| 层 | 是什么 | 谁在跑 | 死了怎么办 |
|---|---|---|---|
| 1. Daemon 子进程 | `bridge/bridge_daemon.py`：收飞书 WS 消息、下载入站附件、发 outbox 回复、每 15 秒写一次心跳 | 被 supervisor 拉起 | supervisor 5 秒内发现，退避重启 |
| 2. Supervisor 父进程 | `bridge/supervisor.py`：只做一件事——看住 daemon，死了就拉起来；Secret 只放它自己内存里，通过管道喂给子进程，绝不写日志 | `bridge/start_bridge.sh` 拉起 | 第 3 层 health 脚本拉起 |
| 3. 健康钩子（纯脚本） | `feishu_health.sh`：每 60 秒读一次心跳文件，陈旧才动手 | 系统 hooks / cron 每 60 秒触发一次 | 脚本自己先修，修不好才唤醒 Agent |

文件布局（运行目录以 `~/workspace/feishu-bridge` 为例，换成自己的路径即可）：

```
feishu-bridge/
├── bridge/
│   ├── bridge_daemon.py      # 收发消息 + 心跳 + 附件下载
│   ├── supervisor.py         # 保活父进程
│   ├── start_bridge.sh       # 幂等启动脚本（唯一入口）
│   ├── validate_credentials.py
│   └── backfill_message.py   # 补取旧消息附件（只用于排错，不替代真实验收）
├── config.json               # 非密钥配置：app_id、白名单、api_host
├── credentials.json          # 0600 权限，只有 app_id + app_secret（见第五节二选一）
├── queue/inbox/              # 收到、待处理的消息
├── queue/outbox/             # 待发送的回复
├── queue/processed/          # 已处理的消息
├── queue/incoming_attachments/<message_id>/  # 下载好的入站附件
├── state/heartbeat.json              # daemon 心跳（每 15 秒更新）
├── state/supervisor_heartbeat.json   # supervisor 心跳（每 5 秒更新）
├── state/daemon_child.json           # 当前 daemon 子进程 pid
└── logs/daemon.log / supervisor.log
```

---

## 三、是怎么拉起来的：四条拉起链

### 链 1：正常启动（人手动，只做一次）

```bash
~/workspace/feishu-bridge/bridge/start_bridge.sh
```

`start_bridge.sh` 是**唯一启动入口**，人、health 脚本、重启恢复都走它。它是幂等的：

```bash
#!/usr/bin/env bash
# Idempotent Feishu bridge starter.
set -u
BASE="$HOME/workspace/feishu-bridge"
LOG="$BASE/logs/supervisor_stdout.log"
mkdir -p "$BASE/logs" "$BASE/state" "$BASE/queue/inbox" "$BASE/queue/outbox" "$BASE/queue/processed"

# 已经在跑就什么都不做，直接返回
if pgrep -f "bridge/supervisor.py" >/dev/null 2>&1; then
  echo "already_running"
  exit 0
fi

if [ ! -f "$BASE/credentials.json" ]; then
  echo "missing_credentials_file"
  exit 2
fi

nohup setsid "$BASE/.venv/bin/python" -u "$BASE/bridge/supervisor.py" \
  --credentials-file "$BASE/credentials.json" >>"$LOG" 2>&1 &
echo "started pid=$!"
```

要点：先 `pgrep` 查重，**绝不允许同时跑两套 supervisor / 两个 daemon**（同一机器人只能有一个消费者，否则消息会重复入队、回复会重复发）。

### 链 2：Daemon 崩了 → Supervisor 拉起（5 秒内，0 Token）

`supervisor.py` 的主循环：

- 每 5 秒检查一次子进程是否还活着，同时刷新 `state/supervisor_heartbeat.json`；
- 子进程退出就记一次 `restart_count`，按退避重启：**3 秒 → 6 秒 → 12 秒 → 24 秒 → 48 秒 → 60 秒封顶**；
- 如果上一次子进程活了超过 300 秒，退避重置回 3 秒（说明不是刚起就崩的死循环）；
- 每次拉起新子进程都把新 pid 写进 `state/daemon_child.json`，Secret 通过 stdin 管道喂给子进程，不经过命令行参数、不写日志。

验收方法：只杀 `state/daemon_child.json` 里记的 daemon pid，**不要杀 supervisor**，看 supervisor 是否拉起新 pid、WS 是否重连。

### 链 3：Supervisor 也死了 / 整机重启 → Health 脚本拉起（60 秒内发现，0 Token）

这是“不浪费 Token”的关键。Health 检查本身是一个纯 bash 脚本，不调模型：

**触发频率：每 60 秒跑一次。每次只做一件事：读 `state/heartbeat.json` 的 `ts`，算它陈旧了多少秒。**

```text
心跳新鲜（陈旧 ≤ 120 秒）→ 静默退出，什么都不做，0 Token
心跳陈旧（陈旧 > 120 秒）→ 脚本自己跑 start_bridge.sh，然后等最多约 50 秒（10 次 × 5 秒）
  → 心跳恢复新鲜 → 静默退出，0 Token，只写一条日志
  → 仍陈旧 → 看下面“什么时候才叫 Agent”
```

脚本原文逻辑（`feishu_health.sh`，已实测的静默版）：

```bash
#!/usr/bin/env bash
set -u
source "$HATCH_HOOK_RUNTIME"
# Feishu bridge health: pure-script self-heal (zero agent tokens on success).
HB="$HOME/workspace/feishu-bridge/state/heartbeat.json"
STARTER="$HOME/workspace/feishu-bridge/bridge/start_bridge.sh"
DRY=0
[[ "${HATCH_HOOK_DRY_RUN:-0}" == "1" ]] && DRY=1

age_now() {  # 读心跳 ts，算陈旧秒数；文件不存在或读不出按无限陈旧算
  local now ts
  now="$(date +%s)"
  ts=0
  if [[ -f "$HB" ]]; then
    ts="$(python3 -c 'import json,sys
try: print(int(json.load(open(sys.argv[1])).get("ts",0)))
except Exception: print(0)' "$HB" 2>/dev/null || echo 0)"
  fi
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  if [[ "$ts" -gt 0 ]]; then echo $((now - ts)); else echo 999999; fi
}

NOW="$(date +%s)"
AGE="$(age_now)"

# 1. 心跳新鲜：清掉告警状态，静默退出
if [[ "$AGE" -le 120 ]]; then
  state_set '{"alerted_at":0,"first_stale_at":0,"heal_attempts":0}'
  silent "feishu bridge heartbeat fresh" "{\"age_seconds\":$AGE}"
fi

# 2. 心跳陈旧：先记 first_stale_at（第一次发现陈旧的时间），再跑启动脚本自愈
STARTER_OUT="$(timeout 30 bash "$STARTER" 2>&1 || true)"
# starter 只会回三种：already_running / started / missing_credentials
# 等最多 50 秒，看心跳是否恢复新鲜；恢复了就静默退出、清掉状态

# 3. 仍没恢复：只有两种情况才唤醒 Agent
#    (a) starter 报 missing_credentials（缺凭证文件，等也修不好）
#    (b) 从第一次发现陈旧起已满 10 分钟（STALE_FOR >= 600 秒）
#    且 30 分钟内只唤醒一次（alerted_at 节流，避免反复刷屏）
```

**注意：health 脚本只在 `local_file` 凭证模式下能自愈。** 如果用 `memory_only` 模式（Secret 只在内存，重启后必须人补发），脚本修不好，只能通知人补发 Secret——不要让脚本去找、去猜凭证。

### 链 4：脚本修不好 → 才唤醒 Agent（最多 30 分钟一次）

同时满足才叫人 / 叫 Agent：

- 心跳持续陈旧满 **10 分钟**，或凭证文件缺失；
- 且距离上次叫过不满 30 分钟时不再重复叫。

Agent 被唤醒后只做：复查心跳和日志 → 跑一次 `start_bridge.sh` → 等 20 秒复查 → 成功就只在摘要里记一笔，**不要再向用户发“飞书通道刚自动恢复了”这种例行播报**；失败才把脱敏的飞书错误 code/msg 报给用户。不要向飞书发测试消息，不要动白名单。

---

## 四、每多长时间检查 / 拉起一次：时间表

**先说结论：没有“每 X 分钟重启一次”这种定时重启。拉起是事件驱动的——只有出故障时才拉，平时只检查、不动手。**

| 动作 | 频率 | 花 Token 吗 | 说明 |
|---|---|---|---|
| Daemon 写心跳 | 每 **15 秒** | 否 | `state/heartbeat.json` 的 `ts` |
| Supervisor 查子进程 + 写心跳 | 每 **5 秒** | 否 | `state/supervisor_heartbeat.json` |
| Supervisor 重启崩掉的 daemon | 出故障时立即，退避 3→60 秒 | 否 | 活超 300 秒后退避重置为 3 秒 |
| Daemon 扫 outbox 发回复 | 每 **2 秒** | 否 | 有回复文件才发 |
| Inbox 脚本扫队列 | 每 **15 秒** | 空队列时否 | 见下节 |
| Health 脚本读心跳 | 每 **60 秒** | 健康时否 | 陈旧 ≤120 秒算健康 |
| Health 脚本判定“陈旧” | 心跳陈旧 **>120 秒** | 否 | 不是每 60 秒都动手 |
| Health 脚本自愈等待 | 最多约 **50 秒** | 否 | 10 次 × 5 秒轮询 |
| 唤醒 Agent 的门槛 | 持续陈旧满 **10 分钟**，或缺凭证 | **只有这时才花** | 且 30 分钟内最多叫一次 |
| 整机 / VM 回收后恢复 | 下一次 health 检查（60 秒内）发现并自愈 | 否 | 本机实测 VM 约每 2 小时回收一次，均由脚本自动恢复，无需人工干预 |

所以日常开销是：**每分钟 1 次纯脚本读文件 + 每 15 秒 1 次纯脚本扫空队列 = 0 Token**。只有真的有人在飞书发消息、或桥真的连续 10 分钟修不好时，才会产生一次 Agent 调用。

---

## 五、消息是怎么不花 Token 等到人的：Inbox 脚本

`feishu_inbox.sh`（每 15 秒跑一次，纯脚本）：

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"
INBOX="$HOME/workspace/feishu-bridge/queue/inbox"

# 只看本地目录，不联网、不读密钥
if [[ ! -d "$INBOX" ]]; then
  silent "feishu inbox directory not present yet" "{}"
  exit 0
fi

shopt -s nullglob
files=("$INBOX"/*.json)
if [[ ${#files[@]} -eq 0 ]]; then
  silent "no new feishu messages" "{}"   # 空队列：静默，0 Token
  exit 0
fi

# 有消息才唤醒：只传文件名和条数，不把消息正文塞进唤醒 payload
# Agent 被唤醒后自己读 inbox 文件处理
first="${files[0]}"
count="${#files[@]}"
payload="$(python3 - "$first_name" "$count" <<'PY'
import json, sys
print(json.dumps({"first_file": sys.argv[1], "count": int(sys.argv[2])}, ensure_ascii=False))
PY
)"
wake "new Feishu message(s) waiting in bridge inbox" "$payload"
```

Agent（worker）被唤醒后的合同：

1. 按时间顺序读 `queue/inbox/*.json`（含 message_id、chat_id、sender_open_id、text、attachments 附件本地路径）；
2. 文字 + 附件一起当作用户消息处理；附件已由 daemon 下载到 `queue/incoming_attachments/<message_id>/`，直接读本地文件分析，不用再调飞书下载；
3. 每个消息写一个回复文件 `queue/outbox/<message_id>-reply.json`：`{"chat_id": ..., "reply_to_message_id": ..., "text": ...}`，要回附件就加 `"attachments": [{"type":"file"|"image"|"video", "path": ...}]`；
4. 写完把 inbox 文件移到 `queue/processed/`；写失败就留在 inbox，下次 15 秒轮询会重试；
5. **边界**：付款、对外发信 / 发布、删除、重要设置等，不凭飞书一句“确认”就执行，回复里请用户回主界面确认。只做约定的轻量工作。

---

## 六、凭证模式：二选一，动手前必须先定

只需要一对凭证：**App ID（`cli_` 开头，可明文）和 App Secret（秘密）**。

| 模式 | 做法 | 优点 | 代价 |
|---|---|---|---|
| `local_file`（本机用的就是这个） | `credentials.json` 放运行目录，权限 `chmod 600`，supervisor 用 `--credentials-file` 自读 | 整机重启 / 进程全死后脚本能自己拉起来，不用人补 Secret | Secret 落盘了，只适用于应用所有者明确接受、机器人低风险的场景；文件必须进 `.gitignore`，绝不进 git、不进聊天、不进日志 |
| `memory_only`（优先推荐给别人） | Secret 只经 stdin 一次性喂给 supervisor，只放内存；不生成 `credentials.json` | Secret 不落盘 | supervisor 或整机重启后必须由所有者重新发一次 Secret 才能启动；health 脚本此时只能通知人，不能自愈 |

**铁律：**

- Secret 只复制一次，立刻跑 `validate_credentials.py` 校验（成功只报 code / 过期时间，不输出 Secret 或完整 token）；失败立即停掉所有自动重试，报准确的飞书 code/msg，请所有者单独一行重发。禁止凭记忆转写、禁止从聊天记录回捞、禁止边猜边重启。
- Secret 不得写进 `SKILL.md`、模板、代码、日志、记忆、命令参数、systemd unit、环境文件。
- `config.json` 只放非密钥字段：`app_id`、`allowed_open_ids`（白名单，回填验证过的用户 open_id）、`allowed_chat_ids`、`api_host`。

---

## 七、飞书后台清单（应用所有者做，Agent 不要假装已开通）

1. 创建企业自建应用，拿到 App ID + App Secret；
2. 添加应用能力：**机器人**；
3. 开权限（以接口实际返回的 `missing_scopes` 为准）：
   - 收单聊消息：`im:message.p2p_msg:readonly`
   - 以机器人身份发消息：`im:message:send_as_bot`
   - 出站附件：`im:resource:upload`（或 `im:resource`）
   - 入站附件下载实测现有私聊只读权限组合即可；若资源接口报缺权限，再补 `im:message:readonly` 并重新发布后复测；
   - 群聊才加：`im:message.group_at_msg:readonly`（未 @ 不入队，@ 后才入队并回复，两项都要真发消息验证）；
4. 事件与回调：订阅方式选「**使用长连接接收事件**」，添加事件 `im.message.receive_v1`（**不用 Webhook，不用公网域名 / 回调地址**，这是选长连接的原因）；
5. 创建版本并发布（公司租户可能需管理员审核）；
6. 在飞书里能找到该机器人并可私聊。

---

## 八、给别人装：部署步骤

```bash
# 1. 复制模板（只复制 *.example，不生成真实 credentials.json，不覆盖已有 config.json）
bin/install_template.sh [目标目录] [--install-deps]
# 默认目标：~/workspace/feishu-bridge

# 2. 配 config.json（只填非秘密字段）
cp config.example.json config.json
# 填 app_id、空的白名单等；api_host 填 open.feishu.cn

# 3. 凭证二选一（见第六节）
# local_file: 从 credentials.example.json 建 credentials.json，填一对值后 chmod 600
# memory_only: 不要生成这个文件

# 4. 装依赖并编译检查
# 向虚拟环境安装 requirements.txt，确认 import lark_oapi 成功
# 全部桥接 Python 做一次编译检查

# 5. 校验凭证成功后才启动
python bridge/validate_credentials.py   # 只看脱敏结果
bridge/start_bridge.sh                  # local_file 模式
# memory_only 模式：由启动脚本从 stdin 喂 supervisor

# 6. 看进程、双心跳、WS 连通证据
# supervisor_heartbeat.json 与 heartbeat.json 的 ts 都新鲜、pid 对得上
# WS 地址带 ticket，只报“已连上”，不准摘抄地址和 key

# 7. 注册两个钩子（Muse 环境；其他 Agent 用等价 cron / systemd 替换，合同相同）
# feishu-inbox：每 15 秒，脚本 feishu_inbox.sh
# feishu-health：每 60 秒，脚本 feishu_health.sh（静默自愈版）
# 先 dry-run：空队列 silent、放假 inbox 应 wake、健康时 silent；确认无误再 enable
# 不要用 live run 代替 dry-run 做首次验证，live wake 会真的启动 worker
```

非 Muse 环境的等价替换：

- inbox：cron 每 15 秒（或 systemd timer）跑等价脚本，有新文件才启动一次 worker；
- health：cron 每 1 分钟跑等价脚本，心跳陈旧 >120 秒就跑 `start_bridge.sh`、等 50 秒复查，持续 10 分钟未恢复或缺凭证才发告警；
- 合同不变：**检查用脚本、处理用 Agent、平时 0 Token**。

---

## 九、验收：没有证据不打勾

| 关 | 怎么验 | 通过标准 |
|---|---|---|
| 文字端到端 | 用户在飞书私聊发约定测试语 | daemon 入队时间、worker 写 outbox 时间、daemon 发送 code 0、用户飞书端亲眼确认，四段都对上；再把验证过的 open_id / chat_id 回填白名单后复验一条 |
| 出站附件 | 先生成 txt / png / mp4 三个小样再逐个发 | 普通文件按 file、图片按 image、mp4 按 media（mp4 错用 file 会报 230055）；用户分别确认能打开图片、能播放视频 |
| 入站附件 | 用户从飞书新发一张图片 + 一个小视频 | daemon 日志显示对应 type 与 attachments 数量且 `attachment_errors=0`；inbox JSON 带本地附件路径；文件真实落在 `queue/incoming_attachments/<message_id>/`；worker 能读到并回复成功。`backfill_message.py` 补取旧消息只证明下载链可用，不能替代真实新入站验收 |
| 保活 | 只杀 `daemon_child.json` 记的 daemon pid | supervisor 退避后拉起新进程（pid 变化、WS 重连）。不要杀 supervisor 来验子进程保活 |
| 整机恢复 | 模拟重启 / 等 VM 回收后看 health 机制 | 心跳新鲜时 dry-run 安静；陈旧时脚本自愈分支走通并恢复；`memory_only` 模式只通知人补 Secret |
| 群聊 | 只有用户要求时才做 | 未 @ 不入队、@ 后入队并回复，两项都要真发消息验证；没测过就明说未测 |

---

## 十、排错表（只报脱敏事实）

| 现象 | 原因 / 查法 |
|---|---|
| 飞书报 `99991672` | 缺权限：补后台权限并发布新版本 |
| 飞书报 `10014` / `1000040345` | 凭证无效：停重试，请所有者单独一行重发 Secret |
| 飞书报 `230055` | MP4 错用了 file 消息，改 media |
| 用户发了视频却毫无反应，daemon 日志有 `inbox ignored empty/non-text` | 跑的是旧版纯文字入站 daemon，必须升级 daemon，不是让用户重发 |
| `SSL: WRONG_VERSION_NUMBER` | 分开查 REST 与 WS 及代理发现 |
| 旧的 `last_send_error.json` | 先看修改时间再下结论，别拿旧错当新错 |
| 心跳陈旧但 supervisor 还在 | 看 `logs/supervisor.log` 和 `daemon.log` 最近几行（脱敏），不要输出 WS 地址票据、token 或凭证值 |

---

## 十一、边界与红线

- 飞书侧只做：文字聊天、收图片 / 视频 / 文件供 Agent 分析、约定的轻量编辑、回传成品附件。
- 做不了 / 不许在飞书做的：浏览器画面、浏览器接管、主界面的结构化审批、安全录入卡、钱包确认；付款、对外发信 / 发布、重要删除、高价值账号设置，不许只凭飞书一句“确认”就执行，回主界面完成。
- 同一机器人只能有一套消费者：先审计目标目录是否已有 supervisor / daemon / hooks / cron 在跑、有无未处理队列，旧桥活着时不要再启第二套。
- 不要把这份文档里的占位符当成真实凭证填进去；真实 App Secret 只走第六节的流程给一次。

---

## 附：本机实测状态（2026-11-19 核查）

- 机器人：四蛋（中国飞书私聊）；凭证模式 `local_file`，`credentials.json` 0600；
- 进程：supervisor 与 daemon 均在运行，心跳新鲜（daemon 每 15 秒、supervisor 每 5 秒）；
- 钩子：`feishu-inbox` 每 15 秒、`feishu-health` 每 60 秒，均已启用；health 为静默自愈版，恢复成功不播报，持续 10 分钟修不好或缺凭证才唤醒；
- 群聊未通（缺会话读取权限），只做私聊。
