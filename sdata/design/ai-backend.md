# AI 后端（Python）设计 – 仅限 Quickshell 前端

> 状态：**设计（v0）**
>
> 目标：将聊天状态、存储和 API 协议复杂性移出 Quickshell/QML。
> Quickshell 变成一个仅渲染事件和发送用户输入的薄 UI 客户端。
>
> v0 的主要提供商：**OpenAI（官方 Python SDK）**。
>
> 本设计旨在匹配 dots-hyprland 的安装器和打包模型：
> - 使用 `uv` 通过 `install-python-packages()` 在 `~/.local/state/quickshell/.venv` 创建 Python 虚拟环境。
> - 我们将 `openai` SDK 安装到同一个虚拟环境中（由安装器完成）。

**更新（2026-01）：** 后端由 **Quickshell 启动和管理**，而非 systemd，以最小化系统占用。
后端脚本位于 **`.config/quickshell/ii/ai/`** 下。

---

## 1. 需求

### 1.1 功能性

- Quickshell（QS）仅负责：
  - 显示聊天列表 / 消息列表
  - 发送用户输入
  - 显示流式助手输出
  - 允许 **停止/取消**

- 后端负责：
  - 聊天/会话/消息持久化
  - 通过 SDK 调用提供商 API
  - 流式标准化为稳定协议
  - 请求取消
  - （未来可选）工具执行和批准

### 1.2 非功能性

- 最小化新的运行时依赖：
  - 使用 dots-hyprland 现有的 **Python 虚拟环境**。
  - 初始阶段避免添加 Web 框架（v0 不使用 FastAPI/Flask）。

- 仅限本地暴露：
  - 绑定到 `127.0.0.1`
  - 需要本地令牌

- 向后兼容性：
  - 后端必须是可选的；当后端未运行时，QS 应显示错误。

---

## 2. 打包 / 仓库中的位置

### 2.1 点文件附带的文件

后端脚本必须放在 Quickshell 配置下，以便 Quickshell 在不接触系统服务的情况下启动/管理它们：

- `dots/.config/quickshell/ii/ai/`
  - `server.py`（入口）
  - `ii_ai_backend/`（包）
  - `README.md`（运行时故障排除）

可选（v1+）：
- `dots/.config/quickshell/ii/ai/config.json`（默认值；也可存储在 QS 配置中）

### 2.2 运行时目录（由后端创建）

- 数据库：`$XDG_DATA_HOME/illogical-impulse/ai-backend/db.sqlite3`
- 日志：`$XDG_STATE_HOME/illogical-impulse/ai-backend/log.txt`
- 缓存：`$XDG_CACHE_HOME/illogical-impulse/ai-backend/`

---

## 3. 进程模型 / 后台管理

后端由 Quickshell（QS）管理以最小化系统占用：

- QS 通过点文件虚拟环境 Python 启动 `server.py`：
  - `~/.local/state/quickshell/.venv/bin/python`（或 `$ILLOGICAL_IMPULSE_VIRTUAL_ENV/bin/python`）
- QS 跟踪：
  - 后端进程 PID / 运行状态
  - 选定端口
  - 每会话认证令牌
- QS 负责：
  - 按需启动后端（当 AI UI 打开或第一条消息发送时）
  - QS 退出时停止后端（尽力而为）
  - 重启崩溃的后端（可选）

手动调试运行（仅限开发者）：

- `python server.py --port 32123 --log-level debug`

---

## 4. 认证与密钥

### 4.1 本地令牌（临时；由 QS 注入）

为避免持久化密钥文件和“系统污染”，QS 在后端启动时生成随机令牌并将其作为环境变量注入。

- 后端读取：`II_AI_BACKEND_TOKEN`（环境变量）
- QS 发送：`Authorization: Bearer <token>`

v0 中令牌**不存储在磁盘上**。

### 4.2 提供商密钥

OpenAI API 密钥来源顺序（v0）：

1) QS 环境中的 `OPENAI_API_KEY`（推荐）
2) （未来可选）QS 密钥环集成

后端从其环境（继承自 QS）读取 `OPENAI_API_KEY`。

---

## 5. 协议：HTTP + SSE（稳定合约）

### 5.1 为什么选择 SSE

- 天然适合令牌流式传输。
- QS 端已处理基于行的流式传输。
- 通过单独的 HTTP 调用轻松取消。

### 5.2 端点（v0）

#### 健康检查
- `GET /v1/health`
  - 返回 `{"ok":true,"version":"0.x","provider":"openai"}`

#### 聊天 CRUD
- `POST /v1/chats`
  - 请求体：`{ "title": "optional" }`
  - 返回：`{ "chat_id": "uuid" }`

- `GET /v1/chats`
  - 返回聊天列表（id/标题/更新时间）

- `GET /v1/chats/{chat_id}`
  - 返回聊天 + 消息（v0 可返回全部）

#### 流式生成
- `POST /v1/chats/{chat_id}/messages:stream`
  - 请求体：
    ```json
    {
      "input": "text",
      "model": "gpt-4.1-mini",
      "temperature": 0.7,
      "system": "optional override",
      "attachments": []
    }
    ```
  - 返回 `text/event-stream`

#### 取消
- `POST /v1/requests/{request_id}/cancel`
  - 返回 `{ "ok": true }`

### 5.3 SSE 事件类型

后端仅发出以下事件类型：

- `event: meta`
  - 数据：`{ "request_id":"...", "chat_id":"...", "model":"..." }`

- `event: delta`
  - 数据：`{ "text":"..." }`

- `event: error`
  - 数据：`{ "code":"...", "message":"...", "retryable": false }`

- `event: done`
  - 数据：`{ "reason":"end|stop|error", "usage": {"input":0,"output":0,"total":0} }`

规则：
- `delta.text` 是**仅用户可见内容**（无 `<think>` 标记）。
- 如果我们将来支持推理显示，应添加 `event: reasoning_delta` 而不是混合使用。

---

## 6. 存储模型

使用 sqlite3（标准库）以保证可靠性和并发性。

### 6.1 表

- `chats(chat_id TEXT PRIMARY KEY, title TEXT, created_at INT, updated_at INT, settings_json TEXT)`
- `messages(message_id TEXT PRIMARY KEY, chat_id TEXT, role TEXT, content TEXT, created_at INT, meta_json TEXT)`
- `requests(request_id TEXT PRIMARY KEY, chat_id TEXT, status TEXT, created_at INT, finished_at INT, meta_json TEXT)`

### 6.2 消息角色

存储标准化角色：
- `user`
- `assistant`
- `system`（可选）

QS 不存储消息。

---

## 7. 取消 / 停止语义

后端维护内存中的请求注册表：

- `request_id -> { cancel_flag, state }`

流式循环频繁检查 `cancel_flag`：

- 如果已取消：
  - 停止发送 delta
  - 发送 `done(reason="stop")`
  - 在数据库中标记请求为已完成

QS 使用 `meta` 事件中的 `request_id` 来取消。

---

## 8. 工具调用（未来 v1）

v0：无工具调用（仅聊天）。

v1 选项：

- 后端执行的工具：
  - 协议统一性最安全
  - 需要严格的允许列表 + 批准流程

- QS 执行的工具：
  - 后端发出 `tool_call`
  - QS 执行并返回结果
  - 仍将存储保留在后端

建议：
- 一旦批准 UX 就绪，为简化起见，将工具执行保留在后端。

---

## 9. QS 集成合约

QS 应：

- 启动时：
  - 调用 `/v1/health`，如果无法访问则显示“后端离线”横幅

- 发送时：
  - 确保 `chat_id` 存在（如需要则创建）
  - 调用 `/messages:stream`
  - 将 `delta.text` 追加到当前助手气泡
  - 存储 `meta` 中的 `request_id` 以启用停止

- 停止时：
  - `POST /v1/requests/{request_id}/cancel`

QS 不应：
- 自动恢复请求
- 进行消息持久化
- 实现提供商特定的协议解析

---

## 10. 实施步骤（检查清单）

1) 在 `dots/.config/quickshell/ii/ai/` 中交付后端骨架。
2) 实现 `GET /health` 和最小聊天存储 + 列表。
3) 使用 OpenAI SDK + SSE 实现流式端点。
4) 实现取消端点。
5) 添加 QS 端后端监管器：
  - 按需启动后端进程
  - 选择/跟踪端口
  - 注入临时 `II_AI_BACKEND_TOKEN`
  - 调用后端端点
6) 将 QS AI UI/服务切换为调用后端而非直接提供商。

---

## 开放问题（编码前必须决定）

- 端口：固定 `32123` 还是由 QS 每会话选择（临时空闲端口）？
- 存储：sqlite3（推荐）还是 JSON？
- v0 工具调用：禁用（推荐）还是启用？
