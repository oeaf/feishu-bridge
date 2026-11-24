# 飞书应用机器人 ↔ Agent 桥接模板

这是已在 Muse 本地环境实测过的桥接模板。不要直接把真实凭证写进这份模板目录分发；部署时复制到运行目录（默认 `~/workspace/feishu-bridge/`）后再填本机配置。

## 链路

```text
飞书用户私聊/群 @ 机器人
  -> 飞书长连接推送 im.message.receive_v1
  -> bridge/bridge_daemon.py（去重、白名单、入站附件下载、出站附件发送、心跳）
  -> queue/incoming_attachments/<message_id>/（入站附件本地文件）
  -> queue/inbox/*.json（text + message_type + attachments 本地路径）
  -> Agent 唤醒/轮询处理器（读 inbox 与本地附件，生成 outbox）
  -> queue/outbox/*.json
  -> bridge_daemon 按 chat_id 发回飞书
```

监护层：

```text
start_bridge.sh -> bridge/supervisor.py -> bridge/bridge_daemon.py（子进程）
                         ^                         |
                         +--- 子进程退出后退避重启---+
```

健康层：心跳超过阈值时由 hooks/feishu_health.sh 唤醒运维 Agent，后者只运行 `start_bridge.sh` 并脱敏核验。

## 目录

- `bridge/bridge_daemon.py`：长连接收消息（文字/图片/文件/音频/视频）、入站附件下载到 `queue/incoming_attachments/`、outbox 文字/附件发送、断线重连、断线后自动补收（重连钩子 + 启动补收，按 message_id 去重）、心跳。
- `bridge/backfill_message.py`：按 message_id 补取已送达消息的入站附件；默认只下载校验，加 `--enqueue` 才入队。
- `bridge/supervisor.py`：子进程保活；从 stdin 或 `--credentials-file` 取凭证，只在内存持有并经管道喂给子进程。
- `bridge/start_bridge.sh`：幂等一键启动；已运行则不重复启动。
- `bridge/validate_credentials.py`：从运行目录 `credentials.json` 换 token，只输出 code/msg/expire。
- `bridge/scan_create_app.py`：官方一键扫码创建应用（`lark.register_app`）——出二维码、所有者飞书扫码确认后自动把凭证写 `credentials.json`（0600）、回填 `config.json` 的 app_id/域名与扫码人白名单，并做一次 token 校验。已有非空凭证时拒绝覆盖。
- `bridge/file_queue.py`：文件队列与 message_id 持久去重。
- `bridge/generate_test_files.py`：生成 txt/png/mp4 验收文件。
- `hooks/feishu_inbox.sh`：inbox 非空时唤醒处理 Agent 的检测脚本（Muse hooks 运行时专用）。
- `hooks/feishu_health.sh`：心跳陈旧时唤醒运维 Agent 的检测脚本（Muse hooks 运行时专用）。
- `hooks/prompts.md`：两个 hook 的工作者提示词模板，注册前替换占位符。
- `config.example.json`：非秘密配置模板。
- `credentials.example.json`：仅键名模板，真实文件须 0600 并加入 .gitignore。
- `CHECKLIST.md`：从 0 到验收的操作清单。

## 接口约定

### inbox（每条消息一个文件）

```json
{
  "message_id": "om_...",
  "chat_id": "oc_...",
  "chat_type": "p2p",
  "sender_open_id": "ou_...",
  "message_type": "media",
  "text": "用户文字",
  "attachments": [
    {
      "type": "video",
      "path": "queue/incoming_attachments/om_.../01-....mp4",
      "file_name": "....mp4",
      "mime_type": "video/mp4",
      "size_bytes": 0,
      "duration": 0
    }
  ],
  "attachment_errors": [],
  "unsupported_reason": "",
  "create_time": "..."
}
```

### outbox（每条待发一个文件）

```json
{
  "chat_id": "oc_...",
  "reply_to_message_id": "om_...",
  "text": "回复文字",
  "attachments": [
    {"type": "file", "path": "test_files/feishu_attachment_test.txt"},
    {"type": "image", "path": "test_files/feishu_attachment_test.png"},
    {"type": "video", "path": "test_files/feishu_attachment_test.mp4"}
  ]
}
```

`path` 相对桥接运行目录或用绝对路径。文字和附件可同文件；daemon 逐个处理并只把飞书 code/msg 写进脱敏日志。

## 快速开通（扫码创建）

装好依赖后，在运行目录跑 `.venv/bin/python bridge/scan_create_app.py --name "<机器人名>"`，终端会出二维码；所有者用飞书 App 扫码确认，应用、凭证与白名单自动落好，省去手动建应用与抄 Secret。手动建应用的老流程仍保留，见 `CHECKLIST.md` 第 1B 节。扫码的原理、addons 权限清单与边界见上层 `references/full-guide.md` 第 3b 节。

## 先读主 skill

完整开通顺序、权限矩阵、凭证门禁、验收、排错和停止方法，以上层 `SKILL.md` 与 `references/full-guide.md` 为准。本 README 只作模板导航。
