pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common.functions as CF
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.services.ai

/**
 * Basic service to handle LLM chats. Supports Google's and OpenAI's API formats.
 * Supports Gemini and OpenAI models.
 * Limitations:
 * - For now functions only work with Gemini API format
 */
Singleton {
    id: root

    // When the QML engine reloads, singletons get torn down. Guard async callbacks
    // (Process stdout/onExited/Timers) so we don't do work while shutting down.
    property bool _destroying: false

    property Component aiMessageComponent: AiMessageData {}
    property Component aiModelComponent: AiModel {}
    property Component openaiApiStrategy: OpenAiApiStrategy {}
    readonly property string interfaceRole: "interface"

    signal responseFinished()
    // Emitted after a chat history has been loaded from backend into messageIDs/messageByID.
    signal messagesLoaded()

    property string systemPrompt: {
        let prompt = Config.options?.ai?.systemPrompt ?? "";
        for (let key in root.promptSubstitutions) {
            // prompt = prompt.replaceAll(key, root.promptSubstitutions[key]);
            // QML/JS doesn't support replaceAll, so use split/join
            prompt = prompt.split(key).join(root.promptSubstitutions[key]);
        }
        return prompt;
    }
    // property var messages: []
    property var messageIDs: []
    property var messageByID: ({})

    // UI state
    // NOTE: Must be a QML object with NOTIFYable properties.
    // tokenCount is the *session-level* counter shown in UI (committed + current in-flight request).
    property QtObject tokenCount: QtObject {
        property int input: -1
        property int output: -1
        property int total: -1
    }

    // Per-request usage for the currently running request (or last finished request).
    // Used by the context window indicator.
    property QtObject requestTokenCount: QtObject {
        property int input: -1
        property int output: -1
        property int total: -1
        property bool estimated: false
    }

    // In-flight cumulative usage for the *current generation*, which may include multiple
    // upstream requests (e.g. tool_calls -> continuation chains).
    // This is what we add to session totals and persist on the assistant message.
    property QtObject inFlightTokenCount: QtObject {
        property int input: -1
        property int output: -1
        property int total: -1
        property bool estimated: false
    }

    // Committed session totals (sum of finished requests in this chat).
    property QtObject _committedTokenCount: QtObject {
        // -1 means "unknown" (no persisted usage yet).
        property int input: -1
        property int output: -1
        property int total: -1
    }

    function _recomputeTokenDisplay() {
        // Display cumulative session totals; while generating, include the current request usage too
        // so the counter updates live during reasoning/tool phases.
        const committedKnown = root._committedTokenCount.total >= 0;
        const inFlightKnown = root.isGenerating && root.inFlightTokenCount.total >= 0 && !requester._usageCommitted;

        // If we have no usage at all (fresh chat / provider hasn't returned anything yet), keep UI as unknown.
        if (!committedKnown && !inFlightKnown) {
            root.tokenCount.input = -1;
            root.tokenCount.output = -1;
            root.tokenCount.total = -1;
            return;
        }

        const committedI = committedKnown ? Math.max(0, root._committedTokenCount.input) : 0;
        const committedO = committedKnown ? Math.max(0, root._committedTokenCount.output) : 0;
        const committedT = committedKnown ? Math.max(0, root._committedTokenCount.total) : 0;

        const addI = inFlightKnown ? Math.max(0, root.inFlightTokenCount.input) : 0;
        const addO = inFlightKnown ? Math.max(0, root.inFlightTokenCount.output) : 0;
        const addT = inFlightKnown ? Math.max(0, root.inFlightTokenCount.total) : 0;

        root.tokenCount.input = committedI + addI;
        root.tokenCount.output = committedO + addO;
        root.tokenCount.total = committedT + addT;
    }
    property real temperature: Persistent.states?.ai?.temperature ?? 1.0

    // OpenAI-compatible provider settings (for the Python backend and/or custom providers).
    // Base URL is not sensitive; API key is stored in the keyring.
    property string openaiBaseUrl: Persistent.states?.ai?.openaiBaseUrl ?? ""
    readonly property string openaiApiKey: KeyringStorage.keyringData?.ai?.openaiApiKey ?? ""
    readonly property bool currentModelHasApiKey: (root.openaiApiKey ?? "").trim().length > 0

    // Local backend (OpenAI-compatible proxy) managed by systemd.
    // QS only checks health status; lifecycle is handled externally.
    property string backendHost: "127.0.0.1"
    property int backendPort: 15333
    readonly property string backendBaseUrl: `http://localhost:${backendPort}`
    readonly property string backendChatCompletionsUrl: `${backendBaseUrl}/v1/chat/completions`
    readonly property string backendHealthUrl: `${backendBaseUrl}/v1/health`
    readonly property string backendChatsUrl: `${backendBaseUrl}/v1/chats`
    readonly property string backendMessagesUrl: `${backendBaseUrl}/v1/messages`
    readonly property string backendCurrentUrl: `${backendBaseUrl}/v1/current`
    property bool backendReady: false
    property bool _backendHealthInFlight: false

    // Current chat state (synced with backend)
    property int currentChatId: -1
    property string currentChatName: ""
    property var chatList: []
    // If chat list refresh is requested while apiProc is busy, queue it.
    property bool _chatListRefreshQueued: false
    // Stop / Abort
    property bool _stopRequested: false
    property string _stopReason: ""
    property bool _requestQueued: false
    readonly property bool isGenerating: requester.running || commandExecutionProc.running

    // Undo stack for deleted messages
    property var _deletedMessagesStack: []
    readonly property bool canUndoDelete: _deletedMessagesStack.length > 0

    Timer {
        id: finishStopTimer
        interval: 0
        repeat: false
        onTriggered: root._finishStopIfIdle()
    }

    Timer {
        id: queuedRequestTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (root._destroying) return;
            if (!root._stopRequested && root._requestQueued) {
                root._requestQueued = false;
                requester.makeRequest();
            }
        }
    }

    function stopGenerating(reason = "user") {
        root._stopRequested = true;
        root._stopReason = reason ?? "";
        root._requestQueued = false;

        // Stop streaming request + any pending command execution.
        if (requester.running) requester.running = false;
        if (commandExecutionProc.running) commandExecutionProc.running = false;

        // Avoid Qt.callLater closures during reload; a Timer is safely cancelled on destruction.
        finishStopTimer.restart();
    }

    function _finishStopIfIdle() {
        if (requester.running || commandExecutionProc.running) return;
        if (!root._stopRequested) return;
        root._stopRequested = false;
        root._stopReason = "";
    }

    // Local backend health check (backend is managed by systemd)
    Timer {
        id: backendHealthTimer
        interval: 150
        repeat: false
        onTriggered: root._runBackendHealthCheck()
    }

    Process {
        id: backendHealthProc
        stdout: SplitParser {
            onRead: data => {
                if (root._destroying) return;
                root._backendHealthInFlight = false;
                try {
                    if (!data || data.length === 0) return;
                    const j = JSON.parse(data);
                    root.backendReady = (typeof j?.upstream_base_url === "string");
                } catch (e) {
                    root.backendReady = false;
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (root._destroying) return;
            root._backendHealthInFlight = false;
            // Backend is managed externally; just report status.
            if (!root.backendReady) {
                console.log("[Ai] Backend health check failed. Ensure ii-ai-backend.service is running.");
            }
        }
    }

    function _runBackendHealthCheck() {
        if (root._backendHealthInFlight) return;
        root._backendHealthInFlight = true;
        backendHealthProc.command = ["curl", "-s", "--max-time", "1", root.backendHealthUrl];
        backendHealthProc.running = true;
    }

    function ensureBackendRunning() {
        // Backend is managed by systemd. We only check health.
        backendHealthTimer.restart();
    }

    function restartBackend() {
        // Backend is managed by systemd. Notify user to restart manually.
        root.addMessage(
            Translation.tr("Backend is managed by systemd. Run: systemctl --user restart ii-ai-backend"),
            root.interfaceRole
        );
        // Re-check health after a delay.
        root.backendReady = false;
        backendHealthTimer.interval = 500;
        backendHealthTimer.restart();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Backend API: Chat/Message CRUD
    // ─────────────────────────────────────────────────────────────────────────

    Process {
        id: apiProc
        property string operation: ""
        property var callback: null
        property string _buffer: ""

        stdout: SplitParser {
            onRead: data => {
                if (root._destroying) return;
                apiProc._buffer += data;
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (root._destroying) return;
            try {
                if (exitCode === 0 && apiProc._buffer.length > 0) {
                    const result = JSON.parse(apiProc._buffer);
                    if (apiProc.callback) apiProc.callback(result, null);
                } else {
                    if (apiProc.callback) apiProc.callback(null, `Exit code: ${exitCode}`);
                }
            } catch (e) {
                console.log("[Ai] API parse error:", e, apiProc._buffer);
                if (apiProc.callback) apiProc.callback(null, e.toString());
            }
            apiProc._buffer = "";
            apiProc.callback = null;
            apiProc.operation = "";

            // Run a queued chat list refresh after any API call completes.
            if (root._chatListRefreshQueued) {
                root._chatListRefreshQueued = false;
                Qt.callLater(() => {
                    if (root._destroying) return;
                    root.refreshChatList();
                });
            }
        }
    }

    // Dedicated API process for chat/session switching.
    // The main apiProc is often busy (saving messages, refreshing lists), and _apiGet() will skip
    // requests when busy. Chat switching must remain responsive, so we isolate it.
    Process {
        id: chatApiProc
        property var callback: null
        property string _buffer: ""
        // Single-slot queue for GET requests triggered while this proc is still "running".
        // This commonly happens when chaining a second GET from inside onExited callbacks.
        property string _queuedUrl: ""
        property var _queuedCallback: null

        stdout: SplitParser {
            onRead: data => {
                if (root._destroying) return;
                chatApiProc._buffer += data;
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (root._destroying) return;
            try {
                if (exitCode === 0 && chatApiProc._buffer.length > 0) {
                    const result = JSON.parse(chatApiProc._buffer);
                    if (chatApiProc.callback) chatApiProc.callback(result, null);
                } else {
                    if (chatApiProc.callback) chatApiProc.callback(null, `Exit code: ${exitCode}`);
                }
            } catch (e) {
                console.log("[Ai] Chat API parse error:", e, chatApiProc._buffer);
                if (chatApiProc.callback) chatApiProc.callback(null, e.toString());
            }
            chatApiProc._buffer = "";
            chatApiProc.callback = null;

            // Drain queued request (if any). Only one slot is kept; latest wins.
            const queuedUrl = chatApiProc._queuedUrl;
            const queuedCb = chatApiProc._queuedCallback;
            chatApiProc._queuedUrl = "";
            chatApiProc._queuedCallback = null;
            if (queuedUrl && queuedUrl.length > 0 && queuedCb) {
                chatApiProc._buffer = "";
                chatApiProc.callback = queuedCb;
                chatApiProc.command = ["curl", "-s", "--max-time", "8", queuedUrl];
                chatApiProc.running = true;
            }
        }
    }

    function _chatApiGet(url, callback) {
        if (chatApiProc.running) {
            // Do not drop chat/session switching requests; keep the latest queued.
            chatApiProc._queuedUrl = url;
            chatApiProc._queuedCallback = callback;
            console.log("[Ai] Chat API busy, queued GET:", url);
            return;
        }
        chatApiProc._buffer = "";
        chatApiProc.callback = callback;
        chatApiProc.command = ["curl", "-s", "--max-time", "8", url];
        chatApiProc.running = true;
    }

    function _apiGet(url, callback) {
        if (apiProc.running) {
            console.log("[Ai] API busy, skipping GET:", url);
            return;
        }
        apiProc._buffer = "";
        apiProc.callback = callback;
        apiProc.command = ["curl", "-s", "--max-time", "5", url];
        apiProc.running = true;
    }

    function _apiPost(url, data, callback) {
        if (apiProc.running) {
            console.log("[Ai] API busy, skipping POST:", url);
            return;
        }
        apiProc._buffer = "";
        apiProc.callback = callback;
        const jsonData = JSON.stringify(data);
        apiProc.command = ["curl", "-s", "--max-time", "5", "-X", "POST",
                          "-H", "Content-Type: application/json",
                          "-d", jsonData, url];
        apiProc.running = true;
    }

    function _apiPut(url, data, callback) {
        if (apiProc.running) {
            console.log("[Ai] API busy, skipping PUT:", url);
            return;
        }
        apiProc._buffer = "";
        apiProc.callback = callback;
        const jsonData = JSON.stringify(data);
        apiProc.command = ["curl", "-s", "--max-time", "5", "-X", "PUT",
                          "-H", "Content-Type: application/json",
                          "-d", jsonData, url];
        apiProc.running = true;
    }

    function _apiDelete(url, callback) {
        if (apiProc.running) {
            console.log("[Ai] API busy, skipping DELETE:", url);
            return;
        }
        apiProc._buffer = "";
        apiProc.callback = callback;
        apiProc.command = ["curl", "-s", "--max-time", "5", "-X", "DELETE", url];
        apiProc.running = true;
    }

    // Load current chat (most recent) from backend
    function loadCurrentChat() {
        _apiGet(root.backendCurrentUrl, (result, err) => {
            if (root._destroying) return;
            if (err) {
                console.log("[Ai] Failed to load current chat:", err);
                return;
            }
            if (!result || typeof result.id !== "number") {
                console.log("[Ai] Invalid current chat response");
                return;
            }
            root.currentChatId = result.id;
            root.currentChatName = result.name || "";
            root._loadMessagesFromBackend(result.messages || []);

            // Keep chat list in sync so UI can render immediately.
            root.refreshChatList();
        });
    }

    // Load messages from a backend response array
    function _loadMessagesFromBackend(messages) {
        root.clearMessages(false); // Don't clear backend when loading from it

        const ctxLimit = (root.models?.[root.currentModelId]?.context_length ?? 0);

        // Recompute committed session totals from persisted per-message usage.
        let sumI = 0;
        let sumO = 0;
        let sumT = 0;
        let anyUsage = false;
        let lastUsage = null;

        for (const msg of messages) {
            // Backward-compat: older DB rows may only have function_call/function_response.
            // Reconstruct a minimal toolCalls array so tool blocks can render after reload.
            let toolCalls = msg.tool_calls || msg.toolCalls || [];
            if ((!toolCalls || toolCalls.length === 0) && (msg.function_call || msg.function_response)) {
                const fc = msg.function_call;
                const legacyId = (typeof fc === "object" && fc && fc.id) ? fc.id : "legacy";
                const legacyName = msg.function_name || ((typeof fc === "object" && fc && fc.name) ? fc.name : "tool");
                const legacyArgs = (typeof fc === "object" && fc && fc.args) ? fc.args : (typeof fc === "object" && fc && fc.arguments) ? fc.arguments : {};
                const legacyOut = msg.function_response || "";
                toolCalls = [{
                    id: legacyId,
                    name: legacyName,
                    args: legacyArgs,
                    status: "completed",
                    result: legacyOut.length > 0 ? { success: true, output: legacyOut } : null
                }];
            }
            const aiMessage = aiMessageComponent.createObject(root, {
                "backendId": msg.id || -1,  // Store the backend ID
                "role": msg.role,
                "content": msg.content || msg.raw_content || "",
                "rawContent": msg.raw_content || msg.content || "",
                "model": msg.model || "",
                "thinking": msg.thinking || false,
                "done": msg.done !== false,
                "annotations": msg.annotations || [],
                "annotationSources": msg.annotation_sources || [],
                "functionName": msg.function_name || "",
                "functionCall": msg.function_call || undefined,
                "functionResponse": msg.function_response || "",
                // Persisted tool calls (multi-tool support)
                "toolCalls": toolCalls,

                // Persisted usage (per request)
                "usagePromptTokens": (typeof msg.usage_prompt_tokens === "number") ? msg.usage_prompt_tokens : -1,
                "usageCompletionTokens": (typeof msg.usage_completion_tokens === "number") ? msg.usage_completion_tokens : -1,
                "usageTotalTokens": (typeof msg.usage_total_tokens === "number") ? msg.usage_total_tokens : -1,
                "usageEstimated": !!msg.usage_estimated,
            });
            // Use backend message ID as the local ID
            const id = msg.id ? msg.id.toString() : root.idForMessage(aiMessage);
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = aiMessage;

            if (aiMessage.usageTotalTokens >= 0) {
                anyUsage = true;
                sumI += Math.max(0, aiMessage.usagePromptTokens);
                sumO += Math.max(0, aiMessage.usageCompletionTokens);
                sumT += Math.max(0, aiMessage.usageTotalTokens);
                lastUsage = aiMessage;
            }
        }

        if (anyUsage) {
            root._committedTokenCount.input = sumI;
            root._committedTokenCount.output = sumO;
            root._committedTokenCount.total = sumT;
        } else {
            root._committedTokenCount.input = -1;
            root._committedTokenCount.output = -1;
            root._committedTokenCount.total = -1;
        }

        if (lastUsage) {
            // On cold start, persisted usage fields can be misleading (e.g. cumulative totals).
            // Treat values that exceed the model context window as invalid for the "context window" UI.
            const p = lastUsage.usagePromptTokens;
            const c = lastUsage.usageCompletionTokens;
            const t = lastUsage.usageTotalTokens;
            const promptValid = (typeof p === "number") && p >= 0 && (ctxLimit <= 0 || p <= ctxLimit);
            const completionValid = (typeof c === "number") && c >= 0;
            const totalValid = (typeof t === "number") && t >= 0;

            if (promptValid) {
                root.requestTokenCount.input = p;
                root.requestTokenCount.output = completionValid ? c : -1;
                root.requestTokenCount.total = totalValid ? t : -1;
                root.requestTokenCount.estimated = !!lastUsage.usageEstimated;
            } else {
                root.requestTokenCount.input = -1;
                root.requestTokenCount.output = -1;
                root.requestTokenCount.total = -1;
                root.requestTokenCount.estimated = false;
            }
        } else {
            root.requestTokenCount.input = -1;
            root.requestTokenCount.output = -1;
            root.requestTokenCount.total = -1;
            root.requestTokenCount.estimated = false;
        }

        root._recomputeTokenDisplay();

        // Notify UI so it can jump to bottom after layout settles.
        root.messagesLoaded();
    }

    // Save a message to the backend (returns backend ID via callback)
    function _saveMessageToBackend(messageData, aiMessageRef = null) {
        if (root.currentChatId < 0) return;
        const url = `${root.backendMessagesUrl}/${root.currentChatId}`;
        _apiPost(url, messageData, (result, err) => {
            if (err) {
                console.log("[Ai] Failed to save message:", err);
                return;
            }
            // Update the message with the backend ID if reference is provided
            if (aiMessageRef && result && result.id) {
                aiMessageRef.backendId = result.id;
            }
        });
    }

    // Delete a message from the backend by its backend ID
    function _deleteMessageFromBackend(backendId) {
        if (backendId < 0) return;
        const url = `${root.backendBaseUrl}/v1/messages/${backendId}`;
        _apiDelete(url, (result, err) => {
            if (err) console.log("[Ai] Failed to delete message from backend:", err);
        });
    }

    // Create a new chat
    function createNewChat(name = "", quiet = false) {
        _apiPost(root.backendChatsUrl, { name: name || "" }, (result, err) => {
            if (root._destroying) return;
            if (err) {
                if (!quiet) root.addMessage(Translation.tr("Failed to create chat: %1").arg(err), root.interfaceRole);
                return;
            }
            root.currentChatId = result.id;
            root.currentChatName = result.name || "";
            root.clearMessages(false); // New chat is already empty
            if (!quiet) root.addMessage(Translation.tr("Created new chat: %1").arg(result.name || `#${result.id}`), root.interfaceRole);
            refreshChatList();
        });
    }

    // Rename current chat
    function renameCurrentChat(newName, quiet = false) {
        if (root.currentChatId < 0) {
            if (!quiet) root.addMessage(Translation.tr("No active chat to rename"), root.interfaceRole);
            return;
        }
        renameChatById(root.currentChatId, newName, quiet);
    }

    // Rename a chat by id.
    function renameChatById(chatId, newName, quiet = false) {
        const cid = Number(chatId);
        if (!isFinite(cid) || cid < 0) {
            if (!quiet) root.addMessage(Translation.tr("Invalid chat id"), root.interfaceRole);
            return;
        }
        const url = `${root.backendChatsUrl}/${cid}`;
        _apiPut(url, { name: newName }, (result, err) => {
            if (root._destroying) return;
            if (err) {
                if (!quiet) root.addMessage(Translation.tr("Failed to rename chat: %1").arg(err), root.interfaceRole);
                return;
            }
            if (cid === root.currentChatId) root.currentChatName = newName;
            if (!quiet) root.addMessage(Translation.tr("Chat renamed to: %1").arg(newName), root.interfaceRole);
            refreshChatList();
        });
    }

    // Load a specific chat by ID
    function loadChatById(chatId, quiet = false) {
        const cid = Number(chatId);
        if (!isFinite(cid) || cid < 0) {
            if (!quiet) root.addMessage(Translation.tr("Invalid chat id"), root.interfaceRole);
            return;
        }

        // Optimistically update current chat selection immediately.
        root.currentChatId = cid;
        const known = (root.chatList || []).find(c => Number(c?.id) === cid);
        root.currentChatName = known?.name || "";

        const url = `${root.backendMessagesUrl}/${cid}`;
        _chatApiGet(url, (messages, err) => {
            if (root._destroying) return;
            if (err) {
                if (!quiet) root.addMessage(Translation.tr("Failed to load chat: %1").arg(err), root.interfaceRole);
                return;
            }

            root._loadMessagesFromBackend(messages || []);

            // Do not inject UI status messages into persisted chats unless explicitly requested.
            if (!quiet) root.addMessage(Translation.tr("Loaded chat: %1").arg(root.currentChatName || `#${cid}`), root.interfaceRole);

            root.refreshChatList();

            // Fetch authoritative chat name/info *after* this request fully unwinds.
            Qt.callLater(() => {
                if (root._destroying) return;
                _chatApiGet(`${root.backendChatsUrl}/${cid}`, (chatInfo, err2) => {
                    if (root._destroying) return;
                    if (err2) return;
                    root.currentChatName = chatInfo?.name || "";
                    root.refreshChatList();
                });
            });
        });
    }

    // Delete a chat by id.
    // If the deleted chat is the current one, we will load the most recent chat afterward.
    function deleteChatById(chatId, quiet = false) {
        const cid = Number(chatId);
        if (!isFinite(cid) || cid < 0) {
            if (!quiet) root.addMessage(Translation.tr("Invalid chat id"), root.interfaceRole);
            return;
        }
        const url = `${root.backendChatsUrl}/${cid}`;
        const wasCurrent = (cid === root.currentChatId);
        const oldName = wasCurrent ? (root.currentChatName || `#${cid}`) : `#${cid}`;
        _apiDelete(url, (result, err) => {
            if (root._destroying) return;
            if (err) {
                if (!quiet) root.addMessage(Translation.tr("Failed to delete chat: %1").arg(err), root.interfaceRole);
                return;
            }

            if (!quiet) root.addMessage(Translation.tr("Deleted chat: %1").arg(oldName), root.interfaceRole);

            if (wasCurrent) {
                root.currentChatId = -1;
                root.currentChatName = "";
                root.clearMessages(false);
            }

            refreshChatList();
            if (wasCurrent) loadCurrentChat();
        });
    }

    // Delete current chat
    function deleteCurrentChat(quiet = false) {
        if (root.currentChatId < 0) {
            if (!quiet) root.addMessage(Translation.tr("No active chat to delete"), root.interfaceRole);
            return;
        }
        deleteChatById(root.currentChatId, quiet);
    }

    // Refresh chat list
    function refreshChatList() {
        if (apiProc.running) {
            // Avoid spamming; just ensure one refresh happens after current op.
            root._chatListRefreshQueued = true;
            return;
        }
        _apiGet(root.backendChatsUrl, (result, err) => {
            if (root._destroying) return;
            if (err) {
                console.log("[Ai] Failed to refresh chat list:", err);
                return;
            }
            root.chatList = result || [];
        });
    }

    // Clear current chat messages (keep the chat, delete messages)
    function clearCurrentChatOnBackend() {
        if (root.currentChatId < 0) return;
        const url = `${root.backendBaseUrl}/v1/clear/${root.currentChatId}`;
        _apiPost(url, {}, (result, err) => {
            if (err) console.log("[Ai] Failed to clear chat on backend:", err);
        });
    }

    function requestOrQueue() {
        if (root._stopRequested) return;
        if (requester.running) {
            root._requestQueued = true;
            return;
        }
        requester.makeRequest();
    }

    // Used by explicit user actions (Send / Regenerate). Internal tool-call chaining should
    // keep respecting stopRequested.
    function requestFromUserAction() {
        root._stopRequested = false;
        root._stopReason = "";
        root.requestOrQueue();
    }

    // Note: Local storage removed. Chat history is stored in the backend.

    // Debug: log each request payload sent to the server (no auth header / no API key).
    property var requestLog: ([])
    property int requestLogLimit: 100

    function clearRequestLog() {
        root.requestLog = [];
    }

    function logRequest(entry) {
        try {
            const ts = Date.now();
            const e = Object.assign({
                id: ts.toString(36) + Math.random().toString(36).slice(2, 8),
                ts,
            }, entry || {});

            if (e.payload !== undefined && e.payloadPretty === undefined) {
                e.payloadPretty = JSON.stringify(e.payload, null, 2);
            }

            const next = (root.requestLog || []).slice(-Math.max(0, root.requestLogLimit - 1));
            next.push(e);
            root.requestLog = next;
        } catch (err) {
            console.error("[Ai] Failed to log request:", err);
        }
    }

    function idForMessage(message) {
        // Generate a unique ID using timestamp and random value
        return Date.now().toString(36) + Math.random().toString(36).substr(2, 8);
    }

    function safeModelName(modelName) {
        return modelName.replace(/:/g, "_").replace(/ /g, "-").replace(/\//g, "-")
    }

    property list<var> defaultPrompts: []
    property list<var> userPrompts: []
    property list<var> promptFiles: [...defaultPrompts, ...userPrompts]
    property list<var> savedChats: []

    property var promptSubstitutions: {
        "{DISTRO}": SystemInfo.distroName,
        "{DATETIME}": `${DateTime.time}, ${DateTime.collapsedCalendarFormat}`,
        "{WINDOWCLASS}": ToplevelManager.activeToplevel?.appId ?? "Unknown",
        "{DE}": `${SystemInfo.desktopEnvironment} (${SystemInfo.windowingSystem})` 
    }

    // Note: Tool definitions are now managed by the backend (server.py).
    // The backend automatically injects tools and handles execution.
    // Frontend only displays tool execution events and results.
    property string currentTool: "functions"  // Kept for UI compatibility
    property list<var> availableTools: ["functions", "none"]
    property var toolDescriptions: {
        "functions": Translation.tr("Commands, edit configs, search.\nTakes an extra turn to switch to search mode if that's needed"),
        "search": Translation.tr("Gives the model search capabilities (immediately)"),
        "none": Translation.tr("Disable tools")
    }

    // Backend-only MVP:
    // - Quickshell only talks to the local backend.
    // - Provider selection / Base URL / API key are handled by API settings and injected into the backend.
    property var models: (Config.options.policies.ai === 0) ? {} : {
        "deepseek-reasoner": aiModelComponent.createObject(this, {
            "name": "DeepSeek Reasoner",
            "icon": "deepseek-symbolic",
            "description": Translation.tr("Local backend | Uses your API settings"),
            "homepage": "https://api-docs.deepseek.com",
            "endpoint": root.backendChatCompletionsUrl,
            "model": "deepseek-reasoner",
            "context_length": 128000,
            "requires_key": true,
            "api_format": "openai",
        }),
        "deepseek-chat": aiModelComponent.createObject(this, {
            "name": "DeepSeek Chat",
            "icon": "deepseek-symbolic",
            "description": Translation.tr("Local backend | Uses your API settings"),
            "homepage": "https://api-docs.deepseek.com",
            "endpoint": root.backendChatCompletionsUrl,
            "model": "deepseek-chat",
            "context_length": 128000,
            "requires_key": true,
            "api_format": "openai",
        }),
    }
    property var modelList: Object.keys(root.models)
    property var currentModelId: {
        const saved = Persistent.states?.ai?.model;
        return (saved && root.models && root.models[saved]) ? saved : (modelList[0] ?? "deepseek-reasoner");
    }

    // Single strategy: OpenAI-style (consuming the backend's OpenAI-compatible endpoint).
    property ApiStrategy currentApiStrategy: openaiApiStrategy.createObject(this)

    property string requestScriptFilePath: "/tmp/quickshell/ai/request.sh"
    property string pendingFilePath: ""

    Component.onCompleted: {
        setModel(currentModelId, false, false); // Do necessary setup for model
        // Load current chat from backend after a short delay to ensure backend is ready
        loadCurrentChatTimer.restart();
    }

    Timer {
        id: loadCurrentChatTimer
        interval: 500
        repeat: false
        onTriggered: root.loadCurrentChat()
    }

    function guessModelLogo(model) {
        if (model.includes("llama")) return "ollama-symbolic";
        if (model.includes("gemma")) return "google-gemini-symbolic";
        if (model.includes("deepseek")) return "deepseek-symbolic";
        if (/^phi\d*:/i.test(model)) return "microsoft-symbolic";
        return "ollama-symbolic";
    }

    function guessModelName(model) {
        const replaced = model.replace(/-/g, ' ').replace(/:/g, ' ');
        let words = replaced.split(' ');
        words[words.length - 1] = words[words.length - 1].replace(/(\d+)b$/, (_, num) => `${num}B`)
        words = words.map((word) => {
            return (word.charAt(0).toUpperCase() + word.slice(1))
        });
        if (words[words.length - 1] === "Latest") words.pop();
        else words[words.length - 1] = `(${words[words.length - 1]})`; // Surround the last word with square brackets
        const result = words.join(' ');
        return result;
    }

    function addModel(modelName, data) {
        root.models[modelName] = aiModelComponent.createObject(this, data);

        // Keep modelList in sync so /model can select custom models
        root.modelList = Object.keys(root.models);
    }



    Process {
        id: getDefaultPrompts
        running: true
        command: ["ls", "-1", Directories.defaultAiPrompts]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root._destroying) return;
                if (text.length === 0) return;
                root.defaultPrompts = text.split("\n")
                    .filter(fileName => fileName.endsWith(".md") || fileName.endsWith(".txt"))
                    .map(fileName => `${Directories.defaultAiPrompts}/${fileName}`)
            }
        }
    }

    Process {
        id: getUserPrompts
        running: true
        command: ["ls", "-1", Directories.userAiPrompts]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root._destroying) return;
                if (text.length === 0) return;
                root.userPrompts = text.split("\n")
                    .filter(fileName => fileName.endsWith(".md") || fileName.endsWith(".txt"))
                    .map(fileName => `${Directories.userAiPrompts}/${fileName}`)
            }
        }
    }

    Process {
        id: getSavedChats
        running: true
        command: ["ls", "-1", Directories.aiChats]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root._destroying) return;
                if (text.length === 0) return;
                root.savedChats = text.split("\n")
                    .filter(fileName => fileName.endsWith(".json"))
                    .map(fileName => `${Directories.aiChats}/${fileName}`)
            }
        }
    }

    FileView {
        id: promptLoader
        watchChanges: false;
        onLoadedChanged: {
            if (root._destroying) return;
            if (!promptLoader.loaded) return;
            Config.options.ai.systemPrompt = promptLoader.text();
            root.addMessage(Translation.tr("Loaded the following system prompt\n\n---\n\n%1").arg(Config.options.ai.systemPrompt), root.interfaceRole);
        }
    }

    function printPrompt() {
        root.addMessage(Translation.tr("The current system prompt is\n\n---\n\n%1").arg(Config.options.ai.systemPrompt), root.interfaceRole);
    }

    function loadPrompt(filePath) {
        promptLoader.path = "" // Unload
        promptLoader.path = filePath; // Load
        promptLoader.reload();
    }

    function addMessage(message, role, saveToBackend = true) {
        if (message.length === 0) return;
        const aiMessage = aiMessageComponent.createObject(root, {
            "role": role,
            "content": message,
            "rawContent": message,
            "thinking": false,
            "done": true,
        });
        const id = idForMessage(aiMessage);
        root.messageIDs = [...root.messageIDs, id];
        root.messageByID[id] = aiMessage;

        // Save to backend (skip interface messages)
        if (saveToBackend && role !== root.interfaceRole) {
            root._saveMessageToBackend({
                role: role,
                content: message,
                rawContent: message,
                done: true,
            }, aiMessage);
        }
    }

    function removeMessage(index, saveForUndo = true, deleteFromBackend = true) {
        if (index < 0 || index >= messageIDs.length) return;
        const id = root.messageIDs[index];
        const message = root.messageByID[id];
        
        // Save to undo stack if requested
        if (saveForUndo && message) {
            root._deletedMessagesStack = [...root._deletedMessagesStack, {
                index: index,
                id: id,
                message: message,
                backendId: message.backendId,
            }];
        }
        
        // Delete from backend if it has a backend ID
        if (deleteFromBackend && message && message.backendId >= 0) {
            root._deleteMessageFromBackend(message.backendId);
        }
        
        root.messageIDs.splice(index, 1);
        root.messageIDs = [...root.messageIDs];
        delete root.messageByID[id];
    }

    function undoLastDelete() {
        if (root._deletedMessagesStack.length === 0) return false;
        
        // Pop the last deleted message
        const deleted = root._deletedMessagesStack[root._deletedMessagesStack.length - 1];
        root._deletedMessagesStack = root._deletedMessagesStack.slice(0, -1);
        
        if (!deleted || !deleted.message) return false;
        
        // Restore the message locally
        const insertIndex = Math.min(deleted.index, root.messageIDs.length);
        root.messageIDs.splice(insertIndex, 0, deleted.id);
        root.messageIDs = [...root.messageIDs];
        root.messageByID[deleted.id] = deleted.message;
        
        // Re-save to backend (will get a new backend ID)
        if (deleted.message.role !== root.interfaceRole) {
            root._saveMessageToBackend({
                role: deleted.message.role,
                content: deleted.message.content,
                rawContent: deleted.message.rawContent,
                model: deleted.message.model,
                done: deleted.message.done,
                functionName: deleted.message.functionName,
                functionCall: deleted.message.functionCall,
                functionResponse: deleted.message.functionResponse,
                toolCalls: deleted.message.toolCalls,
            }, deleted.message);
        }
        
        return true;
    }

    function clearUndoStack() {
        root._deletedMessagesStack = [];
    }

    function addApiKeyAdvice(model) {
        root.addMessage(
            Translation.tr("Missing API key. Open API settings (gear icon) and set Base URL + API key, or use /key YOUR_API_KEY."),
            Ai.interfaceRole
        );
    }

    function getModel() {
        const m = models[currentModelId] ?? models[modelList[0]];
        if (m) return m;
        return {
            name: Translation.tr("AI disabled"),
            description: "",
            api_format: "openai",
            endpoint: "",
            model: "",
            requires_key: false,
        };
    }

    function setModel(modelId, feedback = true, setPersistentState = true) {
        if (!modelId) modelId = ""
        modelId = modelId.toLowerCase()
        if (modelList.indexOf(modelId) !== -1) {
            const model = models[modelId]
            // See if policy prevents online models
            if (Config.options.policies.ai === 2 && !model.endpoint.includes("localhost")) {
                root.addMessage(
                    Translation.tr("Online models disallowed\n\nControlled by `policies.ai` config option"),
                    root.interfaceRole
                );
                return;
            }
            if (setPersistentState) Persistent.states.ai.model = modelId;
            if (feedback) root.addMessage(Translation.tr("Model set to %1").arg(model.name), root.interfaceRole);

            // If this model goes through the local backend, ensure it's running.
            try {
                if ((model.endpoint ?? "").includes("localhost") && (model.endpoint ?? "").includes("/v1/chat/completions")) {
                    root.ensureBackendRunning();
                }
            } catch (e) {
                // ignore
            }
            if (model.requires_key && (root.openaiApiKey ?? "").trim().length === 0) {
                root.addApiKeyAdvice(model)
            }
        } else {
            if (feedback) root.addMessage(Translation.tr("Invalid model. Supported: \n```\n") + modelList.join("\n```\n```\n"), Ai.interfaceRole) + "\n```"
        }
    }

    function setTool(tool) {
        const fmt = getModel()?.api_format || "openai";
        if (!root.tools[fmt] || !(tool in root.tools[fmt])) {
            root.addMessage(Translation.tr("Invalid tool. Supported tools:\n- %1").arg(root.availableTools.join("\n- ")), root.interfaceRole);
            return false;
        }
        Config.options.ai.tool = tool;
        return true;
    }
    
    function getTemperature() {
        return root.temperature;
    }

    function setTemperature(value) {
        if (value == NaN || value < 0 || value > 2) {
            root.addMessage(Translation.tr("Temperature must be between 0 and 2"), Ai.interfaceRole);
            return;
        }
        Persistent.states.ai.temperature = value;
        root.temperature = value;
        root.addMessage(Translation.tr("Temperature set to %1").arg(value), Ai.interfaceRole);
    }

    function setApiKey(key) {
        const v = (key ?? "").trim();
        if (v.length === 0) {
            root.addApiKeyAdvice(getModel());
            return;
        }
        root.setOpenAiApiKey(v, true);
        // Backend is managed by systemd. User should restart it to pick up new credentials.
        root.addMessage(
            Translation.tr("API key saved. Run `systemctl --user restart ii-ai-backend` to apply."),
            root.interfaceRole
        );
    }

    function printApiKey() {
        const model = getModel();
        const key = (root.openaiApiKey ?? "").trim();
        if (key.length > 0) {
            root.addMessage(Translation.tr("API key:\n\n```txt\n%1\n```").arg(key), Ai.interfaceRole);
        } else {
            root.addMessage(Translation.tr("No API key set for %1").arg(model?.name ?? Translation.tr("current model")), Ai.interfaceRole);
        }
    }

    function getOpenAiBaseUrl() {
        return (root.openaiBaseUrl ?? "").trim();
    }

    function setOpenAiBaseUrl(url, feedback = false) {
        const v = (url ?? "").trim();
        root.openaiBaseUrl = v;
        Persistent.states.ai.openaiBaseUrl = v;
        if (feedback) {
            root.addMessage(
                v.length > 0
                    ? Translation.tr("OpenAI Base URL set to: %1").arg(v)
                    : Translation.tr("OpenAI Base URL cleared (provider default will be used)"),
                Ai.interfaceRole
            );
        }
    }

    function getOpenAiApiKey() {
        // Ensure keyring is loaded if caller wants to read.
        if (!KeyringStorage.loaded) KeyringStorage.fetchKeyringData();
        return (root.openaiApiKey ?? "").trim();
    }

    function setOpenAiApiKey(key, feedback = false) {
        const v = (key ?? "").trim();
        KeyringStorage.setNestedField(["ai", "openaiApiKey"], v);
        if (feedback) {
            root.addMessage(
                v.length > 0
                    ? Translation.tr("OpenAI API key saved")
                    : Translation.tr("OpenAI API key cleared"),
                Ai.interfaceRole
            );
        }
    }

    function printTemperature() {
        root.addMessage(Translation.tr("Temperature: %1").arg(root.temperature), Ai.interfaceRole);
    }

    function clearMessages(clearBackend = true) {
        root.messageIDs = [];
        root.messageByID = ({});
        root.requestTokenCount.input = -1;
        root.requestTokenCount.output = -1;
        root.requestTokenCount.total = -1;
        root.requestTokenCount.estimated = false;

        root.inFlightTokenCount.input = -1;
        root.inFlightTokenCount.output = -1;
        root.inFlightTokenCount.total = -1;
        root.inFlightTokenCount.estimated = false;

        root._committedTokenCount.input = -1;
        root._committedTokenCount.output = -1;
        root._committedTokenCount.total = -1;
        root._recomputeTokenDisplay();
        
        // Clear undo stack to prevent memory buildup
        root._deletedMessagesStack = [];

        // Also clear on backend
        if (clearBackend) {
            root.clearCurrentChatOnBackend();
        }
    }

    FileView {
        id: requesterScriptFile
    }

    Process {
        id: requester
        property list<string> baseCommand: ["bash"]
        property AiMessageData message
        property ApiStrategy currentStrategy
        property bool _usageEstimated: false
        property bool _usageCommitted: false
        property var _usageByRequestId: ({})

        function markDone() {
            if (root._destroying) return;
            // Record wall-clock duration for UI summaries.
            if ((requester.message?.startedAtMs ?? -1) < 0) {
                requester.message.startedAtMs = Date.now();
            }
            if ((requester.message?.finishedAtMs ?? -1) < 0) {
                requester.message.finishedAtMs = Date.now();
            }
            requester.message.done = true;
            if (root.postResponseHook) {
                root.postResponseHook();
                root.postResponseHook = null; // Reset hook after use
            }

            // Persist per-request usage so session totals can be computed across reloads.
            const usageObj = {
                prompt_tokens: root.inFlightTokenCount.input,
                completion_tokens: root.inFlightTokenCount.output,
                total_tokens: root.inFlightTokenCount.total,
                estimated: root.inFlightTokenCount.estimated || requester._usageEstimated,
            };

            // Save assistant message to backend
            root._saveMessageToBackend({
                role: requester.message.role,
                content: requester.message.content,
                rawContent: requester.message.rawContent,
                model: requester.message.model,
                done: true,
                annotations: requester.message.annotations,
                annotationSources: requester.message.annotationSources,
                functionName: requester.message.functionName,
                functionCall: requester.message.functionCall,
                functionResponse: requester.message.functionResponse,
                toolCalls: requester.message.toolCalls,
                usage: usageObj,
            }, requester.message);

            // Update message object (for immediate UI access)
            requester.message.usagePromptTokens = root.inFlightTokenCount.input;
            requester.message.usageCompletionTokens = root.inFlightTokenCount.output;
            // Persist the cumulative usage for this assistant message.
            requester.message.usageTotalTokens = root.inFlightTokenCount.total;
            requester.message.usageEstimated = root.inFlightTokenCount.estimated || requester._usageEstimated;

            // Commit session totals once.
            if (!requester._usageCommitted && root.inFlightTokenCount.total >= 0) {
                // If session totals were unknown (no persisted usage yet), start from 0.
                if (root._committedTokenCount.total < 0) {
                    root._committedTokenCount.input = 0;
                    root._committedTokenCount.output = 0;
                    root._committedTokenCount.total = 0;
                }
                root._committedTokenCount.input += Math.max(0, root.inFlightTokenCount.input);
                root._committedTokenCount.output += Math.max(0, root.inFlightTokenCount.output);
                root._committedTokenCount.total += Math.max(0, root.inFlightTokenCount.total);
                requester._usageCommitted = true;
            }
            root._recomputeTokenDisplay();

            root.responseFinished()
        }

        function makeRequest() {
            if (root._destroying) return;
            if (requester.running) {
                root._requestQueued = true;
                return;
            }

            // Starting a new request cancels any previous stop state.
            root._stopRequested = false;
            root._stopReason = "";
            const model = models[currentModelId];
            if (!model) {
                root.addMessage(Translation.tr("No model selected (or AI disabled)."), root.interfaceRole);
                return;
            }
            if (model.requires_key && (root.openaiApiKey ?? "").trim().length === 0) {
                root.addApiKeyAdvice(model);
                return;
            }

            // Fetch API keys if needed
            if (model?.requires_key && !KeyringStorage.loaded) KeyringStorage.fetchKeyringData();
            
            requester.currentStrategy = root.currentApiStrategy;
            requester.currentStrategy.reset(); // Reset strategy state

            // Reset per-request usage for this run.
            root.requestTokenCount.input = -1;
            root.requestTokenCount.output = -1;
            root.requestTokenCount.total = -1;
            root.requestTokenCount.estimated = false;

            root.inFlightTokenCount.input = -1;
            root.inFlightTokenCount.output = -1;
            root.inFlightTokenCount.total = -1;
            root.inFlightTokenCount.estimated = false;
            requester._usageEstimated = false;
            requester._usageCommitted = false;
            requester._usageByRequestId = ({})
            root._recomputeTokenDisplay();

            /* Build endpoint, request data */
            const endpoint = root.currentApiStrategy.buildEndpoint(model);
            const messageArray = root.messageIDs.map(id => root.messageByID[id]);
            const filteredMessageArray = messageArray.filter(message => message.role !== Ai.interfaceRole);
            // Tools are now injected by the backend; pass empty array
            const data = root.currentApiStrategy.buildRequestData(model, filteredMessageArray, root.systemPrompt, root.temperature, [], root.pendingFilePath);
            // console.log("[Ai] Request data: ", JSON.stringify(data, null, 2));

            // Debug log (sanitized): capture the exact payload we are sending.
            root.logRequest({
                modelId: currentModelId,
                modelName: model?.name ?? currentModelId,
                apiFormat: model?.api_format ?? "",
                endpoint: endpoint,
                tool: root.currentTool,
                temperature: root.temperature,
                hasAttachedFile: !!(root.pendingFilePath && root.pendingFilePath.length > 0),
                payload: data,
            });

            let requestHeaders = {
                "Content-Type": "application/json",
            }
            
            /* Create local message object */
            requester.message = root.aiMessageComponent.createObject(root, {
                "role": "assistant",
                "model": currentModelId,
                "content": "",
                "rawContent": "",
                "thinking": true,
                "done": false,
                "startedAtMs": Date.now(),
                "finishedAtMs": -1,
            });
            const id = idForMessage(requester.message);
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = requester.message;

            /* Build header string for curl */ 
            let headerString = Object.entries(requestHeaders)
                .filter(([k, v]) => v && v.length > 0)
                .map(([k, v]) => `-H '${k}: ${v}'`)
                .join(' ');

            // console.log("Request headers: ", JSON.stringify(requestHeaders));
            // console.log("Header string: ", headerString);

            // Backend handles provider authentication; frontend never sends provider API keys.
            const authHeader = "";
            
            /* Script shebang */
            const scriptShebang = "#!/usr/bin/env bash\n";

            /* Create extra setup when there's an attached file */
            let scriptFileSetupContent = ""
            if (root.pendingFilePath && root.pendingFilePath.length > 0) {
                requester.message.localFilePath = root.pendingFilePath;
                scriptFileSetupContent = requester.currentStrategy.buildScriptFileSetup(root.pendingFilePath);
                root.pendingFilePath = ""
            }

            /* Create command string */
            let scriptRequestContent = ""
            // Use stdbuf to force line buffering on curl's stdout.
            // --no-buffer and -N disable curl's output buffering, but bash may still buffer.
            scriptRequestContent += `stdbuf -oL curl --no-buffer -N -s "${endpoint}"`
                + ` ${headerString}`
                + (authHeader ? ` ${authHeader}` : "")
                + ` --data '${CF.StringUtils.shellSingleQuoteEscape(JSON.stringify(data))}'`
                + "\n"
            
            /* Send the request */
            const scriptContent = requester.currentStrategy.finalizeScriptContent(scriptShebang + scriptFileSetupContent + scriptRequestContent)
            const shellScriptPath = CF.FileUtils.trimFileProtocol(root.requestScriptFilePath)
            requesterScriptFile.path = Qt.resolvedUrl(shellScriptPath)
            requesterScriptFile.setText(scriptContent)
            requester.command = baseCommand.concat([shellScriptPath]);
            requester.running = true
        }

        stdout: SplitParser {
            onRead: data => {
                if (root._destroying) return;
                if (data.length === 0) return;
                if (root._stopRequested) return;
                if (requester.message.thinking) requester.message.thinking = false;

                // Handle response line
                try {
                    const result = requester.currentStrategy.parseResponseLine(data, requester.message);

                    // Handle backend tool execution event (tool is being run by backend)
                    if (result.toolExecution) {
                        const te = result.toolExecution;
                        // Support parallel tool calls - add to toolCalls array
                        const newToolCall = {
                            id: te.id,
                            name: te.name,
                            args: te.args,
                            status: "executing",
                            result: null
                        };
                        // Check if this tool call already exists (by id)
                        const existingIdx = requester.message.toolCalls.findIndex(tc => tc.id === te.id);
                        if (existingIdx >= 0) {
                            // Update existing
                            const updated = [...requester.message.toolCalls];
                            updated[existingIdx] = newToolCall;
                            requester.message.toolCalls = updated;
                        } else {
                            // Add new tool call
                            requester.message.toolCalls = [...requester.message.toolCalls, newToolCall];
                            // Insert a placeholder in content to mark tool position for rich display
                            const toolMarker = `\n<!-- tool:${te.id} -->\n`;
                            requester.message.content += toolMarker;
                            requester.message.rawContent += toolMarker;
                        }
                        // Legacy: also set single functionCall for backward compatibility
                        if (!requester.message.functionName) {
                            requester.message.functionName = te.name;
                            requester.message.functionCall = { id: te.id, name: te.name, args: te.args };
                        }
                        requester.message.functionPending = true;
                        return;
                    }
                    
                    // Handle backend tool result event (tool finished executing)
                    if (result.toolResult) {
                        const tr = result.toolResult;
                        // Update the corresponding tool call in the array
                        const idx = requester.message.toolCalls.findIndex(tc => tc.id === tr.id);
                        if (idx >= 0) {
                            const updated = requester.message.toolCalls.slice();
                            updated[idx] = {
                                id: updated[idx].id,
                                name: updated[idx].name,
                                args: updated[idx].args,
                                status: "completed",
                                result: tr.result
                            };
                            requester.message.toolCalls = updated;
                        }
                        // Check if all tools are completed
                        const allCompleted = requester.message.toolCalls.every(tc => tc.status === "completed");
                        requester.message.functionPending = !allCompleted;
                        // Legacy: set functionResponse for backward compatibility
                        if (!requester.message.functionResponse) {
                            requester.message.functionResponse = tr.result?.output || JSON.stringify(tr.result);
                        }
                        return;
                    }
                    
                    // Handle continuation event (backend is making follow-up request)
                    if (result.continuation) {
                        return;  // Just continue reading, more data coming
                    }

                    // Note: Tool calls are now handled by backend automatically.
                    // Frontend only receives tool_execution and tool_result events for display.
                    
                    if (result.tokenUsage) {
                        const rid = (result.tokenUsage.requestId ?? "").toString();
                        const key = rid.length > 0 ? rid : "__no_request_id__";
                        const entry = {
                            input: result.tokenUsage.input,
                            output: result.tokenUsage.output,
                            total: result.tokenUsage.total,
                            estimated: !!result.tokenUsage.estimated,
                        };
                        requester._usageByRequestId[key] = entry;

                        // Update last-request usage (ctx indicator).
                        root.requestTokenCount.input = entry.input;
                        root.requestTokenCount.output = entry.output;
                        root.requestTokenCount.total = entry.total;
                        root.requestTokenCount.estimated = entry.estimated;

                        // Aggregate in-flight usage across all upstream requests seen in this generation.
                        let sumI = 0;
                        let sumO = 0;
                        let sumT = 0;
                        let any = false;
                        let anyEstimated = false;
                        for (let k in requester._usageByRequestId) {
                            const u = requester._usageByRequestId[k];
                            if (!u || typeof u.total !== "number" || u.total < 0) continue;
                            any = true;
                            sumI += Math.max(0, Number(u.input));
                            sumO += Math.max(0, Number(u.output));
                            sumT += Math.max(0, Number(u.total));
                            anyEstimated = anyEstimated || !!u.estimated;
                        }

                        if (any) {
                            root.inFlightTokenCount.input = sumI;
                            root.inFlightTokenCount.output = sumO;
                            root.inFlightTokenCount.total = sumT;
                            root.inFlightTokenCount.estimated = anyEstimated;
                        } else {
                            root.inFlightTokenCount.input = -1;
                            root.inFlightTokenCount.output = -1;
                            root.inFlightTokenCount.total = -1;
                            root.inFlightTokenCount.estimated = false;
                        }

                        requester._usageEstimated = requester._usageEstimated || entry.estimated;
                        root._recomputeTokenDisplay();
                    }
                    if (result.finished) {
                        requester.markDone();
                    }

                    // Some terminal conditions (backend error, upstream error) should immediately end
                    // the generating state in UI (stop button -> send button).
                    if (result.stopNow) {
                        // Avoid continuing queued follow-ups after a fatal error.
                        root._requestQueued = false;
                        if (root.isGenerating) {
                            root.stopGenerating("error");
                        }
                    }
                    
                } catch (e) {
                    console.log("[AI] Could not parse response: ", e);
                    requester.message.rawContent += data;
                    requester.message.content += data;
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (root._destroying) return;
            const result = requester.currentStrategy.onRequestFinished(requester.message);
            
            if (result.finished) {
                requester.markDone();
            } else if (!requester.message.done) {
                requester.markDone();
            }

            // Handle error responses
            if (requester.message.content.includes("API key not valid")) {
                root.addApiKeyAdvice(models[requester.message.model]);
            }
            
            // Explicitly reset running state after the process exits
            // (Process.running should auto-reset but force it for reliability)
            requester.running = false;

            // Run a queued follow-up request (if any) after the current process fully exits.
            if (!root._stopRequested && root._requestQueued) {
                // Defer to the next tick to avoid re-entrancy inside Process callbacks.
                queuedRequestTimer.restart();
            }

            root._finishStopIfIdle();
        }
    }

    function sendUserMessage(message) {
        if (message.length === 0) return;
        root.addMessage(message, "user");
        root.requestFromUserAction();
    }

    function attachFile(filePath: string) {
        root.pendingFilePath = CF.FileUtils.trimFileProtocol(filePath);
    }

    function regenerate(messageIndex) {
        if (messageIndex < 0 || messageIndex >= messageIDs.length) return;
        const id = root.messageIDs[messageIndex];
        const message = root.messageByID[id];
        if (message.role !== "assistant") return;
        // Remove all messages after this one
        for (let i = root.messageIDs.length - 1; i >= messageIndex; i--) {
            root.removeMessage(i);
        }
        root.requestFromUserAction();
    }

    /**
     * Roll back the conversation to keep only messages up to (and including) the specified index.
     * This removes all messages after that index, saving them to the undo stack.
     * @param messageIndex - The index of the last message to keep
     * @param requestNewResponse - If true, requests a new response after rollback
     * @returns The number of messages removed
     */
    function rollbackTo(messageIndex, requestNewResponse = false) {
        if (messageIndex < 0 || messageIndex >= messageIDs.length) return 0;
        
        let removedCount = 0;
        // Remove messages from the end down to (but not including) messageIndex
        for (let i = root.messageIDs.length - 1; i > messageIndex; i--) {
            root.removeMessage(i);
            removedCount++;
        }
        
        if (removedCount > 0) {
            root.addMessage(
                Translation.tr("Rolled back %n message(s).", "", removedCount),
                root.interfaceRole
            );
        }
        
        if (requestNewResponse) {
            root.requestFromUserAction();
        }
        
        return removedCount;
    }

    /**
     * Roll back to a message and request a new assistant response.
     * Works like regenerate but for user messages too.
     */
    function rollbackAndRegenerate(messageIndex) {
        if (messageIndex < 0 || messageIndex >= messageIDs.length) return;
        
        // For user messages, rollback to that message and request a new response
        // For assistant messages, remove it and regenerate
        const id = root.messageIDs[messageIndex];
        const message = root.messageByID[id];
        
        if (message.role === "assistant") {
            // Same as regenerate - remove this message and all after, then request new
            for (let i = root.messageIDs.length - 1; i >= messageIndex; i--) {
                root.removeMessage(i);
            }
            root.requestFromUserAction();
        } else if (message.role === "user") {
            // Keep the user message, remove everything after, then request new response
            for (let i = root.messageIDs.length - 1; i > messageIndex; i--) {
                root.removeMessage(i);
            }
            root.requestFromUserAction();
        }
    }

    function createFunctionOutputMessage(name, output, includeOutputInChat = true, functionCall = undefined) {
        return aiMessageComponent.createObject(root, {
            "role": "user",
            "content": `[[ Output of ${name} ]]${includeOutputInChat ? ("\n\n<think>\n" + output + "\n</think>") : ""}`,
            "rawContent": `[[ Output of ${name} ]]${includeOutputInChat ? ("\n\n<think>\n" + output + "\n</think>") : ""}`,
            "functionName": name,
            "functionCall": functionCall,
            "functionResponse": output,
            "thinking": false,
            "done": true,
            // "visibleToUser": false,
        });
    }

    function addFunctionOutputMessage(name, output, functionCall = undefined) {
        const aiMessage = createFunctionOutputMessage(name, output, true, functionCall);
        const id = idForMessage(aiMessage);
        root.messageIDs = [...root.messageIDs, id];
        root.messageByID[id] = aiMessage;

        // Save function output to backend
        root._saveMessageToBackend({
            role: aiMessage.role,
            content: aiMessage.content,
            rawContent: aiMessage.rawContent,
            functionName: aiMessage.functionName,
            functionCall: aiMessage.functionCall,
            functionResponse: aiMessage.functionResponse,
            done: true,
        }, aiMessage);
    }

    function rejectCommand(message: AiMessageData) {
        if (!message.functionPending) return;
        message.functionPending = false; // User decided, no more "thinking"
        addFunctionOutputMessage(message.functionName, Translation.tr("Command rejected by user"), message.functionCall)
        root.requestOrQueue(); // Let the model react to rejection
    }

    function approveCommand(message: AiMessageData) {
        if (!message.functionPending) return;
        message.functionPending = false; // User decided, no more "thinking"

        const responseMessage = createFunctionOutputMessage(message.functionName, "", false, message.functionCall);
        const id = idForMessage(responseMessage);
        root.messageIDs = [...root.messageIDs, id];
        root.messageByID[id] = responseMessage;

        commandExecutionProc.message = responseMessage;
        commandExecutionProc.baseMessageContent = responseMessage.content;
        commandExecutionProc.shellCommand = message.functionCall.args.command;
        commandExecutionProc.running = true; // Start the command execution
    }

    Process {
        id: commandExecutionProc
        property string shellCommand: ""
        property AiMessageData message
        property string baseMessageContent: ""
        command: ["bash", "-c", shellCommand]
        stdout: SplitParser {
            onRead: (output) => {
                if (root._destroying) return;
                if (root._stopRequested) return;
                commandExecutionProc.message.functionResponse += output + "\n\n";
                const updatedContent = commandExecutionProc.baseMessageContent + `\n\n<think>\n<tt>${commandExecutionProc.message.functionResponse}</tt>\n</think>`;
                commandExecutionProc.message.rawContent = updatedContent;
                commandExecutionProc.message.content = updatedContent;
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (root._destroying) return;
            commandExecutionProc.message.functionResponse += `[[ Command exited with code ${exitCode} (${exitStatus}) ]]\n`;
            
            // Explicitly reset running state
            commandExecutionProc.running = false;
            
            if (!root._stopRequested) {
                root.requestOrQueue(); // Continue
            }
            root._finishStopIfIdle();
        }
    }

    Component.onDestruction: {
        root._destroying = true;
        // Best-effort: stop any in-flight work so QS reload doesn't tear down objects mid-callback.
        try { finishStopTimer.stop(); } catch (e) {}
        try { queuedRequestTimer.stop(); } catch (e) {}
        try { backendHealthTimer.stop(); } catch (e) {}

        try { root._stopRequested = true; } catch (e) {}
        try { root._requestQueued = false; } catch (e) {}

        try { if (requester.running) requester.running = false; } catch (e) {}
        try { if (commandExecutionProc.running) commandExecutionProc.running = false; } catch (e) {}
        try { if (backendHealthProc.running) backendHealthProc.running = false; } catch (e) {}

        // Note: Backend is managed by systemd, no need to stop backendProc.

        try { if (getDefaultPrompts.running) getDefaultPrompts.running = false; } catch (e) {}
        try { if (getUserPrompts.running) getUserPrompts.running = false; } catch (e) {}
        try { if (getSavedChats.running) getSavedChats.running = false; } catch (e) {}
    }

    // Note: Tool execution is now fully handled by the backend (server.py).
    // The backend automatically injects tools, executes them, and continues the conversation.
    // Frontend only receives tool_execution and tool_result events for display purposes.

    function chatToJson() {
        return root.messageIDs.map(id => {
            const message = root.messageByID[id]
            return ({
                "role": message.role,
                "rawContent": message.rawContent,
                "fileMimeType": message.fileMimeType,
                "fileUri": message.fileUri,
                "localFilePath": message.localFilePath,
                "model": message.model,
                "thinking": false,
                "done": true,
                "annotations": message.annotations,
                "annotationSources": message.annotationSources,
                "functionName": message.functionName,
                "functionCall": message.functionCall,
                "functionResponse": message.functionResponse,
                "visibleToUser": message.visibleToUser,
            })
        })
    }

    // Note: Chat history is now stored in the backend via API.
    // saveChat/loadChat removed; use backend API instead.
}
