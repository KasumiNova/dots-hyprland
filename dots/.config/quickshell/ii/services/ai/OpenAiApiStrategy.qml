import QtQuick

ApiStrategy {
    property bool isReasoning: false
    // Note: Tool call handling is now done by the backend.
    // Frontend only receives tool_execution and tool_result events.
    
    function buildEndpoint(model: AiModel): string {
        // console.log("[AI] Endpoint: " + model.endpoint);
        return model.endpoint;
    }

    function buildRequestData(model: AiModel, messages, systemPrompt: string, temperature: real, tools: list<var>, filePath: string) {
        function needsReasoningContentField(): bool {
            const m = (model?.model ?? "").toLowerCase();
            // DeepSeek thinking-mode models require reasoning_content in assistant messages.
            // https://api-docs.deepseek.com/guides/thinking_mode#tool-calls
            return m === "deepseek-reasoner" || m.includes("deepseek-reasoner");
        }

        function isDeepSeekEndpoint(): bool {
            const ep = (model?.endpoint ?? "").toLowerCase();
            return ep.includes("api.deepseek.com");
        }

        function splitThinkBlocks(text: string): var {
            const s = (typeof text === "string") ? text : "";
            const parts = [];
            // Our UI stores thinking in <think>...</think> blocks.
            const re = /<think>\s*([\s\S]*?)\s*<\/think>/g;
            let m;
            while ((m = re.exec(s)) !== null) {
                parts.push(m[1]);
            }

            // Handle streaming edge case: we may have an opening <think> without a closing tag
            // (e.g. tool_calls emitted while still in reasoning). In that case, treat everything
            // after the first <think> as reasoning.
            if (parts.length === 0) {
                const openIdx = s.indexOf("<think>");
                const closeIdx = s.indexOf("</think>");
                if (openIdx !== -1 && closeIdx === -1) {
                    const before = s.slice(0, openIdx);
                    const after = s.slice(openIdx + "<think>".length);
                    const contentOnlyUnclosed = before.replace(/\n{3,}/g, "\n\n").trim();
                    const reasoningUnclosed = after.replace(/^\s+/, "").trim();
                    return {
                        content: contentOnlyUnclosed,
                        reasoning: reasoningUnclosed,
                    };
                }
            }

            const contentOnly = s
                .replace(re, "")
                .replace(/\n{3,}/g, "\n\n")
                .trim();
            return {
                content: contentOnly,
                reasoning: parts.join("\n\n").trim(),
            };
        }

        const includeReasoningField = needsReasoningContentField();
        const isDeepSeek = includeReasoningField || isDeepSeekEndpoint();

        // Build messages array, handling tool calls properly
        const builtMessages = [];
        builtMessages.push({role: "system", content: systemPrompt});
        
        for (const message of messages) {
            const hasToolCalls = (message.toolCalls ?? []).length > 0;
            const hasFunctionCall = message.functionCall != undefined && (message.functionName?.length ?? 0) > 0;

            const split = includeReasoningField && message.role === "assistant"
                ? splitThinkBlocks(message.rawContent)
                : { content: (message.rawContent ?? ""), reasoning: "" };

            // For messages with tool calls, we need to generate:
            // 1. An assistant message with tool_calls
            // 2. One or more tool messages with results
            if (hasToolCalls && message.role === "assistant") {
                // Build assistant message with tool_calls
                const toolCalls = message.toolCalls.map((tc, idx) => ({
                    id: tc.id || `call_${idx}`,
                    type: "function",
                    function: {
                        name: tc.name,
                        arguments: JSON.stringify(tc.args || {})
                    }
                }));
                
                let assistantMsg = {
                    role: "assistant",
                    content: split.content || "",
                    tool_calls: toolCalls
                };
                if (includeReasoningField) {
                    assistantMsg.reasoning_content = split.reasoning || "";
                }
                builtMessages.push(assistantMsg);
                
                // Build tool messages for each completed tool call
                for (const tc of message.toolCalls) {
                    if (tc.status === "completed" && tc.result) {
                        builtMessages.push({
                            role: "tool",
                            tool_call_id: tc.id,
                            content: tc.result?.output || JSON.stringify(tc.result)
                        });
                    }
                }
                continue;
            }
            
            // Legacy: handle old-style single function call
            if (hasFunctionCall && message.role === "assistant") {
                const callId = message.functionCall?.id;
                const argsObj = message.functionCall?.args ?? {};
                
                // Build assistant message with tool_calls
                let assistantMsg = {
                    role: "assistant",
                    content: split.content || "",
                    tool_calls: [{
                        id: callId || "call_0",
                        type: "function",
                        function: {
                            name: message.functionName,
                            arguments: JSON.stringify(argsObj)
                        }
                    }]
                };
                if (includeReasoningField) {
                    assistantMsg.reasoning_content = split.reasoning || "";
                }
                builtMessages.push(assistantMsg);
                
                // Build tool message if there's a response
                if ((message.functionResponse?.length ?? 0) > 0) {
                    builtMessages.push({
                        role: "tool",
                        tool_call_id: callId || "call_0",
                        content: message.functionResponse
                    });
                }
                continue;
            }

            // Regular message (no tool calls)
            let messageData = {
                role: message.role,
                content: split.content,
            };

            if (includeReasoningField && message.role === "assistant") {
                messageData.reasoning_content = split.reasoning;
            }

            builtMessages.push(messageData);
        }

        let baseData = {
            "model": model.model,
            "messages": builtMessages,
            "stream": true,
            // Ask upstream to include token usage in streaming (OpenAI-style).
            // Some providers send usage in a final chunk with empty choices.
            "stream_options": { "include_usage": true },
            "tools": tools,
            "temperature": temperature,
        };

        // DeepSeek Chat Completions API exposes tool_choice and defaults to "none" when omitted.
        // Being explicit here helps ensure tools are actually considered.
        if (isDeepSeek && tools && tools.length > 0) {
            baseData.tool_choice = "auto";
        }
        return model.extraParams ? Object.assign({}, baseData, model.extraParams) : baseData;
    }

    function buildAuthorizationHeader(apiKeyEnvVarName: string): string {
        return `-H "Authorization: Bearer \$\{${apiKeyEnvVarName}\}"`;
    }

    function parseResponseLine(line, message) {
        // Remove 'data: ' prefix if present and trim whitespace
        let cleanData = line.trim();
        if (cleanData.startsWith("data:")) {
            cleanData = cleanData.slice(5).trim();
        }

        // console.log("[AI] OpenAI: Data:", cleanData);
        
        // Handle special cases
        if (!cleanData || cleanData.startsWith(":")) return {};
        if (cleanData === "[DONE]") {
            return { finished: true };
        }
        
        // Real stuff
        try {
            // Handle backend tool events (not from OpenAI API, but from our backend)
            const maybeObj = JSON.parse(cleanData);
            if (maybeObj.type === "error") {
                const where = maybeObj.where ? ` (${maybeObj.where})` : "";
                const rid = maybeObj.request_id ? ` [${maybeObj.request_id}]` : "";
                const msg = `\n\n**Error**${where}${rid}: ${maybeObj.message || JSON.stringify(maybeObj)}\n\n`;
                message.rawContent += msg;
                message.content += msg;
                // Treat backend error as terminal: stop UI "generating" state immediately.
                return { finished: true, stopNow: true };
            }
            if (maybeObj.type === "usage") {
                const u = maybeObj.usage || {};
                return {
                    tokenUsage: {
                        input: u.prompt_tokens ?? -1,
                        output: u.completion_tokens ?? -1,
                        total: u.total_tokens ?? -1,
                        estimated: !!maybeObj.estimated,
                        requestId: (maybeObj.request_id ?? ""),
                    }
                };
            }
            if (maybeObj.type === "tool_execution") {
                // Tool is being executed by the backend
                return {
                    toolExecution: {
                        id: maybeObj.tool_call?.id ?? "",
                        name: maybeObj.tool_call?.name ?? "",
                        args: maybeObj.tool_call?.args ?? {},
                        status: maybeObj.status ?? "executing"
                    }
                };
            }
            if (maybeObj.type === "tool_result") {
                // Tool execution completed
                return {
                    toolResult: {
                        id: maybeObj.tool_call?.id ?? "",
                        name: maybeObj.tool_call?.name ?? "",
                        args: maybeObj.tool_call?.args ?? {},
                        result: maybeObj.result ?? {}
                    }
                };
            }
            if (maybeObj.type === "continuation") {
                // Backend is continuing after tool execution
                return { continuation: true };
            }
            const dataJson = maybeObj;  // Reuse parsed object

            // Error response handling
            if (dataJson.error) {
                const errorMsg = `**Error**: ${dataJson.error.message || JSON.stringify(dataJson.error)}`;
                message.rawContent += errorMsg;
                message.content += errorMsg;
                return { finished: true, stopNow: true };
            }

            let newContent = "";

            // Tool calls (OpenAI function calling)
            // Note: Tool calls are now fully handled by the backend.
            // Backend executes tools, continues conversation, and sends tool_execution/tool_result events.
            // Frontend only displays these events; no need to parse tool_calls here.
            // We just skip tool_calls deltas and wait for the backend's special events.
            const toolCallsDelta = dataJson.choices?.[0]?.delta?.tool_calls;
            if (toolCallsDelta && toolCallsDelta.length > 0) {
                // Tool call data is being streamed; backend will handle it.
                // Close reasoning block if open.
                if (isReasoning) {
                    isReasoning = false;
                    const endBlock = "\n\n</think>\n\n";
                    message.content += endBlock;
                    message.rawContent += endBlock;
                }
                return {};
            }

            // Usage metadata may arrive in a chunk with empty choices.
            if (dataJson.usage) {
                return {
                    tokenUsage: {
                        input: dataJson.usage.prompt_tokens ?? -1,
                        output: dataJson.usage.completion_tokens ?? -1,
                        total: dataJson.usage.total_tokens ?? -1,
                        estimated: false,
                        requestId: (dataJson.id ?? ""),
                    }
                };
            }

            // Defensive: some backend events are valid JSON but not OpenAI chunks.
            if (!dataJson.choices || !dataJson.choices[0]) {
                return {};
            }

            const responseContent = dataJson.choices[0]?.delta?.content || dataJson.message?.content;
            const responseReasoning = dataJson.choices[0]?.delta?.reasoning || dataJson.choices[0]?.delta?.reasoning_content;

            if (responseContent && responseContent.length > 0) {
                if (isReasoning) {
                    isReasoning = false;
                    const endBlock = "\n\n</think>\n\n";
                    message.content += endBlock;
                    message.rawContent += endBlock;
                }
                newContent = responseContent;
            } else if (responseReasoning && responseReasoning.length > 0) {
                if (!isReasoning) {
                    isReasoning = true;
                    const startBlock = "\n\n<think>\n\n";
                    message.rawContent += startBlock;
                    message.content += startBlock;
                }
                newContent = responseReasoning;
            }

            message.content += newContent;
            message.rawContent += newContent;

            if (dataJson.done) {
                return { finished: true };
            }
            
        } catch (e) {
            console.log("[AI] OpenAI: Could not parse line: ", e);
            message.rawContent += line;
            message.content += line;
        }
        
        return {};
    }
    
    function onRequestFinished(message) {
        // OpenAI format doesn't need special finish handling
        return {};
    }
    
    function reset() {
        isReasoning = false;
    }

}
