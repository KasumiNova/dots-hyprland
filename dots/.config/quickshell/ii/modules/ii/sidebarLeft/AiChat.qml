import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.ii.sidebarLeft.aiChat
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io

Item {
    id: root
    // Guard against teardown races during reload.
    property bool _destroying: false
    property real padding: 4
    property var inputField: messageInputField
    property string commandPrefix: "/"

    // Optional: a parent item above this page (e.g. SidebarLeftContent) used to host dialogs.
    // This avoids being clipped by the SwipeView page container.
    property Item dialogOverlayParent: null

    property bool showRequestLog: false

    function fmtTokensCompact(n) {
        const v = Number(n);
        if (!isFinite(v) || v < 0) return "-";

        function fmtScaled(x, unit) {
            if (x < 10) return `${x.toFixed(1)}${unit}`;
            return `${Math.round(x)}${unit}`;
        }

        if (v >= 1000000) return fmtScaled(v / 1000000, "M");
        if (v >= 1000) return fmtScaled(v / 1000, "k");
        return `${Math.round(v)}`;
    }

    component TokenRing: Item {
        id: ring
        property real progress: 0
        property color colBg: Appearance.colors.colOutlineVariant
        property color colFg: Appearance.colors.colPrimary
        implicitWidth: 22
        implicitHeight: 22

        Canvas {
            id: canvas
            anchors.fill: parent
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const w = width;
                const h = height;
                const cx = w/2;
                const cy = h/2;
                const r = Math.min(w, h)/2 - 2;
                const start = -Math.PI/2;
                const p = Math.max(0, Math.min(1, ring.progress || 0));

                ctx.lineWidth = 2;
                ctx.lineCap = "round";

                // bg circle
                ctx.strokeStyle = ring.colBg;
                ctx.beginPath();
                ctx.arc(cx, cy, r, 0, Math.PI*2);
                ctx.stroke();

                // fg arc
                if (p > 0) {
                    ctx.strokeStyle = ring.colFg;
                    ctx.beginPath();
                    ctx.arc(cx, cy, r, start, start + Math.PI*2*p);
                    ctx.stroke();
                }
            }
        }

        onProgressChanged: canvas.requestPaint()
        Component.onCompleted: canvas.requestPaint()
    }

    // Prevent input/suggestions from visually overflowing the page bounds.
    clip: true

    // Visual API settings dialog (OpenAI-compatible base URL + API key)
    property bool showApiSettingsDialog: false
    property string apiBaseUrlDraft: ""
    property string apiKeyDraft: ""
    property bool apiKeyVisible: false

    // When a modal overlay is open, never steal focus back to the chat input.
    // Chat/session manager is also a modal.
    property bool showChatManagerDialog: false
    property string newChatNameDraft: ""
    property int __pendingDeleteChatId: -1
    property int __editingChatId: -1
    property string __editingChatNameDraft: ""
    readonly property bool modalOpen: root.showApiSettingsDialog || root.showRequestLog || root.showChatManagerDialog

    function openChatManager() {
        // Always refresh list when opening.
        Ai.refreshChatList();
        root.__pendingDeleteChatId = -1;
        root.newChatNameDraft = "";
        root.showChatManagerDialog = true;

        Qt.callLater(() => {
            if (root._destroying) return;
            if (!root.showChatManagerDialog) return;
            try { newChatNameField.forceActiveFocus(); } catch (e) {}
        });
    }

    function openApiSettings() {
        // Best-effort: preload keyring so the dialog can show existing values.
        if (!KeyringStorage.loaded) KeyringStorage.fetchKeyringData();
        root.apiBaseUrlDraft = Ai.getOpenAiBaseUrl();
        root.apiKeyDraft = Ai.openaiApiKey ?? "";
        root.apiKeyVisible = false;
        root.showApiSettingsDialog = true;

        // Ensure focus moves into the dialog, otherwise Ctrl+V and other key events
        // can bubble up and get intercepted by the chat input.
        Qt.callLater(() => {
            if (root._destroying) return;
            if (!root.showApiSettingsDialog) return;
            try {
                apiBaseUrlField.forceActiveFocus();
            } catch (e) {
                // Fallback: focus API key field if Base URL field is not available.
                try { apiKeyField.forceActiveFocus(); } catch (e2) {}
            }
        });
    }

    Component.onDestruction: {
        // Mark as destroying first so any in-flight callbacks can bail out.
        root._destroying = true;
        // On reload, this page can be destroyed while subprocesses/dialog loaders are active.
        // Stop them explicitly to reduce teardown races inside QS/Qt.
        try { root.showApiSettingsDialog = false; } catch (e) {}
        try { root.showRequestLog = false; } catch (e) {}
        try { if (decodeImageAndAttachProc.running) decodeImageAndAttachProc.running = false; } catch (e) {}
    }

    // Set by parent sidebar content to match the actual output scale (e.g. Hyprland monitor.scale)
    property real outputScale: 1

    readonly property real __dpr: (Screen.devicePixelRatio || 1)
    readonly property bool __fractionalScale: Math.abs(__dpr - Math.round(__dpr)) > 0.001

    property var suggestionQuery: ""
    property var suggestionList: []

    onFocusChanged: focus => {
        if (focus) {
            if (!root.modalOpen) root.inputField.forceActiveFocus();
        }
    }

    Keys.onPressed: event => {
        // If a modal dialog is open, do not redirect key events to the chat input.
        // This fixes paste/typing being stolen by the background input field.
        if (root.modalOpen) {
            event.accepted = false;
            return;
        }
        if (event.modifiers === Qt.NoModifier) {
            if (event.key === Qt.Key_PageUp) {
                messageInputField.forceActiveFocus();
                messageListView.contentY = Math.max(0, messageListView.contentY - messageListView.height / 2);
                event.accepted = true;
            } else if (event.key === Qt.Key_PageDown) {
                messageInputField.forceActiveFocus();
                messageListView.contentY = Math.min(messageListView.contentHeight - messageListView.height / 2, messageListView.contentY + messageListView.height / 2);
                event.accepted = true;
            }
        }
        if ((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_O) {
            messageInputField.forceActiveFocus();
            Ai.clearMessages();
        }
        // Ctrl+Z to undo delete (only when input field is empty to not interfere with text editing)
        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Z && messageInputField.text.length === 0) {
            if (Ai.canUndoDelete) {
                messageInputField.forceActiveFocus();
                Ai.undoLastDelete();
                event.accepted = true;
            }
        }
    }

    property var allCommands: [
        {
            name: "attach",
            description: Translation.tr("Attach a file. Only works with Gemini."),
            execute: args => {
                Ai.attachFile(args.join(" ").trim());
            }
        },
        {
            name: "model",
            description: Translation.tr("Choose model"),
            execute: args => {
                Ai.setModel(args[0]);
            }
        },
        {
            name: "tool",
            description: Translation.tr("Set the tool to use for the model."),
            execute: args => {
                // console.log(args)
                if (args.length == 0 || args[0] == "get") {
                    Ai.addMessage(Translation.tr("Usage: %1tool TOOL_NAME").arg(root.commandPrefix), Ai.interfaceRole);
                } else {
                    const tool = args[0];
                    const switched = Ai.setTool(tool);
                    if (switched) {
                        Ai.addMessage(Translation.tr("Tool set to: %1").arg(tool), Ai.interfaceRole);
                    }
                }
            }
        },
        {
            name: "prompt",
            description: Translation.tr("Set the system prompt for the model."),
            execute: args => {
                if (args.length === 0 || args[0] === "get") {
                    Ai.printPrompt();
                    return;
                }
                Ai.loadPrompt(args.join(" ").trim());
            }
        },
        {
            name: "key",
            description: Translation.tr("Set API key"),
            execute: args => {
                if (args[0] == "get") {
                    Ai.printApiKey();
                } else {
                    Ai.setApiKey(args[0]);
                }
            }
        },
        {
            name: "save",
            description: Translation.tr("Rename current chat"),
            execute: args => {
                const joinedArgs = args.join(" ").trim();
                if (joinedArgs.length === 0) {
                    Ai.addMessage(Translation.tr("Usage: %1save CHAT_NAME").arg(root.commandPrefix), Ai.interfaceRole);
                    return;
                }
                Ai.renameCurrentChat(joinedArgs);
            }
        },
        {
            name: "chats",
            description: Translation.tr("List all chats"),
            execute: () => {
                Ai.refreshChatList();
                let msg = Translation.tr("**Chats:**\n");
                if (Ai.chatList.length === 0) {
                    msg += Translation.tr("No chats found.");
                } else {
                    for (const chat of Ai.chatList) {
                        const current = (chat.id === Ai.currentChatId) ? " ← current" : "";
                        msg += `- **${chat.name || "Unnamed"}** (ID: ${chat.id})${current}\n`;
                    }
                }
                Ai.addMessage(msg, Ai.interfaceRole);
            }
        },
        {
            name: "clear",
            description: Translation.tr("Clear chat history"),
            execute: () => {
                Ai.clearMessages();
            }
        },
        {
            name: "temp",
            description: Translation.tr("Set temperature (randomness) of the model. Values range between 0 to 2 for Gemini, 0 to 1 for other models. Default is 0.5."),
            execute: args => {
                // console.log(args)
                if (args.length == 0 || args[0] == "get") {
                    Ai.printTemperature();
                } else {
                    const temp = parseFloat(args[0]);
                    Ai.setTemperature(temp);
                }
            }
        },
        {
            name: "test",
            description: Translation.tr("Markdown test"),
            execute: () => {
                Ai.addMessage(`
<think>
A longer think block to test revealing animation
OwO wem ipsum dowo sit amet, consekituwet awipiscing ewit, sed do eiuwsmod tempow inwididunt ut wabowe et dowo mawa. Ut enim ad minim weniam, quis nostwud exeucitation uwuwamcow bowowis nisi ut awiquip ex ea commowo consequat. Duuis aute iwuwe dowo in wepwependewit in wowuptate velit esse ciwwum dowo eu fugiat nuwa pawiatuw. Excepteuw sint occaecat cupidatat non pwowoident, sunt in cuwpa qui officia desewunt mowit anim id est wabowum. Meouw! >w<
Mowe uwu wem ipsum!
</think>
## ✏️ Markdown test
### Formatting

- *Italic*, \`Monospace\`, **Bold**, [Link](https://example.com)
- Arch lincox icon <img src="${Quickshell.shellPath("assets/icons/arch-symbolic.svg")}" height="${Appearance.font.pixelSize.small}"/>

### Table

Quickshell vs AGS/Astal

|                          | Quickshell       | AGS/Astal         |
|--------------------------|------------------|-------------------|
| UI Toolkit               | Qt               | Gtk3/Gtk4         |
| Language                 | QML              | Js/Ts/Lua         |
| Reactivity               | Implied          | Needs declaration |
| Widget placement         | Mildly difficult | More intuitive    |
| Bluetooth & Wifi support | ❌               | ✅                |
| No-delay keybinds        | ✅               | ❌                |
| Development              | New APIs         | New syntax        |

### Code block

Just a hello world...

\`\`\`cpp
#include <bits/stdc++.h>
// This is intentionally very long to test scrolling
const std::string GREETING = \"UwU\";
int main(int argc, char* argv[]) {
    std::cout << GREETING;
}
\`\`\`

### LaTeX


Inline w/ dollar signs: $\\frac{1}{2} = \\frac{2}{4}$

Inline w/ double dollar signs: $$\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}$$

Inline w/ backslash and square brackets \\[\\int_0^\\infty \\frac{1}{x^2} dx = \\infty\\]

Inline w/ backslash and round brackets \\(e^{i\\pi} + 1 = 0\\)
`, Ai.interfaceRole);
            }
        },
    ]

    function handleInput(inputText) {
        if (inputText.startsWith(root.commandPrefix)) {
            // Handle special commands
            const command = inputText.split(" ")[0].substring(1);
            const args = inputText.split(" ").slice(1);
            const commandObj = root.allCommands.find(cmd => cmd.name === `${command}`);
            if (commandObj) {
                commandObj.execute(args);
            } else {
                Ai.addMessage(Translation.tr("Unknown command: ") + command, Ai.interfaceRole);
            }
        } else {
            Ai.sendUserMessage(inputText);
        }
    }

    Process {
        id: decodeImageAndAttachProc
        property string imageDecodePath: Directories.cliphistDecode
        property string imageDecodeFileName: "image"
        property string imageDecodeFilePath: `${imageDecodePath}/${imageDecodeFileName}`
        function handleEntry(entry: string) {
            imageDecodeFileName = parseInt(entry.match(/^(\d+)\t/)[1]);
            decodeImageAndAttachProc.exec(["bash", "-c", `[ -f ${imageDecodeFilePath} ] || echo '${StringUtils.shellSingleQuoteEscape(entry)}' | ${Cliphist.cliphistBinary} decode > '${imageDecodeFilePath}'`]);
        }
        onExited: (exitCode, exitStatus) => {
            if (root._destroying) return;
            if (exitCode === 0) {
                Ai.attachFile(imageDecodeFilePath);
            } else {
                console.error("[AiChat] Failed to decode image in clipboard content");
            }
        }
    }

    component StatusItem: MouseArea {
        id: statusItem
        property string icon
        property string statusText
        property string description
        hoverEnabled: true
        implicitHeight: statusItemRowLayout.implicitHeight
        implicitWidth: statusItemRowLayout.implicitWidth

        RowLayout {
            id: statusItemRowLayout
            spacing: 0
            MaterialSymbol {
                text: statusItem.icon
                iconSize: Appearance.font.pixelSize.huge
                color: Appearance.colors.colSubtext
            }
            StyledText {
                font.pixelSize: Appearance.font.pixelSize.small
                text: statusItem.statusText
                color: Appearance.colors.colSubtext
                animateChange: true
            }
        }

        StyledToolTip {
            text: statusItem.description
            extraVisibleCondition: false
            alternativeVisibleCondition: statusItem.containsMouse
        }
    }



    component StatusSeparator: Rectangle {
        implicitWidth: 4
        implicitHeight: 4
        radius: implicitWidth / 2
        color: Appearance.colors.colOutlineVariant
    }

    ColumnLayout {
        id: columnLayout
        anchors {
            fill: parent
            margins: root.padding
        }
        spacing: root.padding

        Item {
            // Messages
            id: messagesContainer
            Layout.fillWidth: true
            Layout.fillHeight: true

            clip: true
            // layer disabled to fix fractional scaling blur
            layer.enabled: false

            StyledRectangularShadow {
                z: 1
                target: statusBg
                opacity: messageListView.atYBeginning ? 0 : 1
                visible: opacity > 0
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }
            Rectangle {
                id: statusBg
                z: 2
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: parent.top
                    topMargin: 4
                }
                implicitWidth: statusRowLayout.implicitWidth + 10 * 2
                implicitHeight: Math.max(statusRowLayout.implicitHeight, 38)
                radius: Appearance.rounding.normal - root.padding
                color: messageListView.atYBeginning ? Appearance.colors.colLayer2 : Appearance.colors.colLayer2Base
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
                RowLayout {
                    id: statusRowLayout
                    anchors.centerIn: parent
                    spacing: 10

                    // Animated mirrors for token values (so UI can smoothly transition).
                    // requestAnim: per-request usage (drives ctx window)
                    // sessionAnim: session totals (shown in token status item)
                    QtObject {
                        id: requestAnim
                        property real input: Ai.requestTokenCount.input
                        property real output: Ai.requestTokenCount.output
                        property real total: Ai.requestTokenCount.total

                        Behavior on input {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on output {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on total {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                    }

                    QtObject {
                        id: sessionAnim
                        property real input: Ai.tokenCount.input
                        property real output: Ai.tokenCount.output
                        property real total: Ai.tokenCount.total

                        Behavior on input {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on output {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on total {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                    }

                    // (ctx window indicator moved to bottom input bar)

                    // Chat/session switcher
                    MouseArea {
                        id: chatSwitcher
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !Ai.isGenerating
                        implicitHeight: Math.max(22, chatRow.implicitHeight)
                        implicitWidth: chatRow.implicitWidth

                        onClicked: root.openChatManager()

                        RowLayout {
                            id: chatRow
                            spacing: 6
                            Layout.alignment: Qt.AlignVCenter

                            MaterialSymbol {
                                Layout.alignment: Qt.AlignVCenter
                                text: "forum"
                                iconSize: Appearance.font.pixelSize.huge
                                color: Appearance.colors.colSubtext
                            }

                            StyledText {
                                Layout.alignment: Qt.AlignVCenter
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colSubtext
                                elide: Text.ElideRight
                                // Keep it compact; full name in tooltip.
                                text: {
                                    const cid = Ai.currentChatId;
                                    const name = (Ai.currentChatName ?? "").trim();
                                    if (cid < 0) return Translation.tr("No chat");
                                    if (name.length > 0) return name;
                                    return `#${cid}`;
                                }
                                maximumLineCount: 1
                                width: Math.min(180, implicitWidth)
                            }
                        }

                        StyledToolTip {
                            text: {
                                if (Ai.isGenerating) return Translation.tr("Can't switch chats while generating");
                                const cid = Ai.currentChatId;
                                const name = (Ai.currentChatName ?? "").trim();
                                if (cid < 0) return Translation.tr("Chat sessions");
                                return Translation.tr("Chat sessions\nCurrent: %1 (%2)")
                                    .arg(name.length > 0 ? name : Translation.tr("Unnamed"))
                                    .arg(`#${cid}`);
                            }
                            extraVisibleCondition: false
                            alternativeVisibleCondition: chatSwitcher.containsMouse
                        }
                    }

                    StatusSeparator {}
                    StatusItem {
                        icon: "device_thermostat"
                        statusText: Ai.temperature.toFixed(1)
                        description: Translation.tr("Temperature\nChange with /temp VALUE")
                    }
                    StatusItem {
                        visible: true
                        icon: "token"
                        statusText: {
                            if (sessionAnim.total < 0) return "I: - / O: -";
                            const i = root.fmtTokensCompact(sessionAnim.input);
                            const o = root.fmtTokensCompact(sessionAnim.output);
                            return `I: ${i} / O: ${o}`;
                        }
                        description: {
                            if (Ai.tokenCount.total < 0) return Translation.tr("Token usage unknown (provider did not return usage yet)");
                            return Translation.tr("Token usage (Input/Output/Total)\nInput: %1\nOutput: %2\nTotal: %3")
                                .arg(Ai.tokenCount.input)
                                .arg(Ai.tokenCount.output)
                                .arg(Ai.tokenCount.total);
                        }
                    }

                    StatusSeparator {}
                    StatusItem {
                        icon: "bug_report"
                        statusText: ""
                        description: Translation.tr("Request log\nView the full payload sent to the server")
                        onClicked: root.showRequestLog = true
                    }
                }
            }

            ScrollEdgeFade {
                z: 1
                target: messageListView
                vertical: true
            }

            StyledListView { // Message list
                id: messageListView
                z: 0
                anchors.fill: parent
                spacing: 10
                popin: false
                // Disable smooth scrolling animation to keep scroll feel snappy.
                animateScroll: false
                topMargin: statusBg.implicitHeight + statusBg.anchors.topMargin * 2

                touchpadScrollFactor: Config.options.interactions.scrolling.touchpadScrollFactor * 1.4
                mouseScrollFactor: Config.options.interactions.scrolling.mouseScrollFactor * 1.4

                property int lastResponseLength: 0

                add: null // Prevent function calls from being janky

                model: ScriptModel {
                    values: Ai.messageIDs.filter(id => {
                        const message = Ai.messageByID[id];
                        return message?.visibleToUser ?? true;
                    })
                }
                delegate: AiMessage {
                    required property var modelData
                    required property int index
                    messageIndex: index
                    messageData: Ai.messageByID[modelData] ?? null
                    messageInputField: root.inputField
                    visible: messageData !== null
                }
            }

            PagePlaceholder {
                z: 2
                shown: Ai.messageIDs.length === 0
                icon: "neurology"
                title: Translation.tr("Large language models")
                description: Translation.tr("Type /key to get started with online models\nCtrl+O to expand sidebar\nCtrl+P to pin sidebar\nCtrl+D to detach sidebar")
                shape: MaterialShape.Shape.PixelCircle
            }

            ScrollToBottomButton {
                z: 3
                target: messageListView
            }
        }

        DescriptionBox {
            text: root.suggestionList[suggestions.selectedIndex]?.description ?? ""
            showArrows: root.suggestionList.length > 1
        }

        FlowButtonGroup { // Suggestions
            id: suggestions
            visible: root.suggestionList.length > 0 && messageInputField.text.length > 0
            property int selectedIndex: 0
            Layout.fillWidth: true
            spacing: 5

            Repeater {
                id: suggestionRepeater
                model: {
                    suggestions.selectedIndex = 0;
                    return root.suggestionList.slice(0, 10);
                }
                delegate: ApiCommandButton {
                    id: commandButton
                    colBackground: suggestions.selectedIndex === index ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colSecondaryContainer
                    bounce: false
                    contentItem: StyledText {
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.m3colors.m3onSurface
                        horizontalAlignment: Text.AlignHCenter
                        text: modelData.displayName ?? modelData.name
                    }

                    onHoveredChanged: {
                        if (commandButton.hovered) {
                            suggestions.selectedIndex = index;
                        }
                    }
                    onClicked: {
                        suggestions.acceptSuggestion(modelData.name);
                    }
                }
            }

            function acceptSuggestion(word) {
                const words = messageInputField.text.trim().split(/\s+/);
                if (words.length > 0) {
                    words[words.length - 1] = word;
                } else {
                    words.push(word);
                }
                const updatedText = words.join(" ") + " ";
                messageInputField.text = updatedText;
                messageInputField.cursorPosition = messageInputField.text.length;
                messageInputField.forceActiveFocus();
            }

            function acceptSelectedWord() {
                if (suggestions.selectedIndex >= 0 && suggestions.selectedIndex < suggestionRepeater.count) {
                    const word = root.suggestionList[suggestions.selectedIndex].name;
                    suggestions.acceptSuggestion(word);
                }
            }
        }

        Rectangle { // Input area
            id: inputWrapper
            property real spacing: 5
            Layout.fillWidth: true
            radius: Appearance.rounding.normal - root.padding
            color: Appearance.colors.colLayer2
            implicitHeight: Math.max(
                inputFieldRowLayout.implicitHeight
                    + inputFieldRowLayout.anchors.topMargin
                    + commandButtonsRow.implicitHeight
                    + commandButtonsRow.anchors.bottomMargin
                    + spacing,
                45
            ) + (
                attachedFileIndicator.visible
                    ? (attachedFileIndicator.implicitHeight + spacing + attachedFileIndicator.anchors.topMargin)
                    : 0
            )
            clip: true

            Behavior on implicitHeight {
                animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
            }

            AttachedFileIndicator {
                id: attachedFileIndicator
                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                    margins: visible ? 5 : 0
                }
                filePath: Ai.pendingFilePath
                onRemove: Ai.attachFile("")
            }

            RowLayout { // Input field and send button
                id: inputFieldRowLayout
                anchors {
                    top: attachedFileIndicator.bottom
                    left: parent.left
                    right: parent.right
                    topMargin: 5
                }
                spacing: 0

                StyledTextArea { // The actual TextArea
                    id: messageInputField
                    wrapMode: TextArea.Wrap
                    Layout.fillWidth: true
                    padding: 10
                    color: activeFocus ? Appearance.m3colors.m3onSurface : Appearance.m3colors.m3onSurfaceVariant
                    placeholderText: Translation.tr('Message the model... "%1" for commands').arg(root.commandPrefix)

                    background: null

                    onTextChanged: {
                        // Handle suggestions
                        if (messageInputField.text.length === 0) {
                            root.suggestionQuery = "";
                            root.suggestionList = [];
                            return;
                        } else if (messageInputField.text.startsWith(`${root.commandPrefix}model`)) {
                            root.suggestionQuery = messageInputField.text.split(" ")[1] ?? "";
                            const modelResults = Fuzzy.go(root.suggestionQuery, Ai.modelList.map(model => {
                                return {
                                    name: Fuzzy.prepare(model),
                                    obj: model
                                };
                            }), {
                                all: true,
                                key: "name"
                            });
                            root.suggestionList = modelResults.map(model => {
                                return {
                                    name: `${messageInputField.text.trim().split(" ").length == 1 ? (root.commandPrefix + "model ") : ""}${model.target}`,
                                    displayName: `${Ai.models[model.target].name}`,
                                    description: `${Ai.models[model.target].description}`
                                };
                            });
                        } else if (messageInputField.text.startsWith(`${root.commandPrefix}prompt`)) {
                            root.suggestionQuery = messageInputField.text.split(" ")[1] ?? "";
                            const promptFileResults = Fuzzy.go(root.suggestionQuery, Ai.promptFiles.map(file => {
                                return {
                                    name: Fuzzy.prepare(file),
                                    obj: file
                                };
                            }), {
                                all: true,
                                key: "name"
                            });
                            root.suggestionList = promptFileResults.map(file => {
                                return {
                                    name: `${messageInputField.text.trim().split(" ").length == 1 ? (root.commandPrefix + "prompt ") : ""}${file.target}`,
                                    displayName: `${FileUtils.trimFileExt(FileUtils.fileNameForPath(file.target))}`,
                                    description: Translation.tr("Load prompt from %1").arg(file.target)
                                };
                            });
                        } else if (messageInputField.text.startsWith(`${root.commandPrefix}save`)) {
                            root.suggestionQuery = messageInputField.text.split(" ")[1] ?? "";
                            const promptFileResults = Fuzzy.go(root.suggestionQuery, Ai.savedChats.map(file => {
                                return {
                                    name: Fuzzy.prepare(file),
                                    obj: file
                                };
                            }), {
                                all: true,
                                key: "name"
                            });
                            root.suggestionList = promptFileResults.map(file => {
                                const chatName = FileUtils.trimFileExt(FileUtils.fileNameForPath(file.target)).trim();
                                return {
                                    name: `${messageInputField.text.trim().split(" ").length == 1 ? (root.commandPrefix + "save ") : ""}${chatName}`,
                                    displayName: `${chatName}`,
                                    description: Translation.tr("Save chat to %1").arg(chatName)
                                };
                            });
                        } else if (messageInputField.text.startsWith(`${root.commandPrefix}load`)) {
                            root.suggestionQuery = messageInputField.text.split(" ")[1] ?? "";
                            const promptFileResults = Fuzzy.go(root.suggestionQuery, Ai.savedChats.map(file => {
                                return {
                                    name: Fuzzy.prepare(file),
                                    obj: file
                                };
                            }), {
                                all: true,
                                key: "name"
                            });
                            root.suggestionList = promptFileResults.map(file => {
                                const chatName = FileUtils.trimFileExt(FileUtils.fileNameForPath(file.target)).trim();
                                return {
                                    name: `${messageInputField.text.trim().split(" ").length == 1 ? (root.commandPrefix + "load ") : ""}${chatName}`,
                                    displayName: `${chatName}`,
                                    description: Translation.tr(`Load chat from %1`).arg(file.target)
                                };
                            });
                        } else if (messageInputField.text.startsWith(`${root.commandPrefix}tool`)) {
                            root.suggestionQuery = messageInputField.text.split(" ")[1] ?? "";
                            const toolResults = Fuzzy.go(root.suggestionQuery, Ai.availableTools.map(tool => {
                                return {
                                    name: Fuzzy.prepare(tool),
                                    obj: tool
                                };
                            }), {
                                all: true,
                                key: "name"
                            });
                            root.suggestionList = toolResults.map(tool => {
                                const toolName = tool.target;
                                return {
                                    name: `${messageInputField.text.trim().split(" ").length == 1 ? (root.commandPrefix + "tool ") : ""}${tool.target}`,
                                    displayName: toolName,
                                    description: Ai.toolDescriptions[toolName]
                                };
                            });
                        } else if (messageInputField.text.startsWith(root.commandPrefix)) {
                            root.suggestionQuery = messageInputField.text;
                            root.suggestionList = root.allCommands.filter(cmd => cmd.name.startsWith(messageInputField.text.substring(1))).map(cmd => {
                                return {
                                    name: `${root.commandPrefix}${cmd.name}`,
                                    description: `${cmd.description}`
                                };
                            });
                        }
                    }

                    function accept() {
                        root.handleInput(text);
                        text = "";
                    }

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Tab) {
                            suggestions.acceptSelectedWord();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up && suggestions.visible) {
                            suggestions.selectedIndex = Math.max(0, suggestions.selectedIndex - 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down && suggestions.visible) {
                            suggestions.selectedIndex = Math.min(root.suggestionList.length - 1, suggestions.selectedIndex + 1);
                            event.accepted = true;
                        } else if ((event.key === Qt.Key_Enter || event.key === Qt.Key_Return)) {
                            if (event.modifiers & Qt.ShiftModifier) {
                                // Insert newline
                                messageInputField.insert(messageInputField.cursorPosition, "\n");
                                event.accepted = true;
                            } else {
                                // If the model is currently generating, don't send a new message.
                                // Let Enter behave like newline so users can keep drafting.
                                if (Ai.isGenerating) {
                                    messageInputField.insert(messageInputField.cursorPosition, "\n");
                                } else {
                                    // Accept text
                                    const inputText = messageInputField.text;
                                    messageInputField.clear();
                                    root.handleInput(inputText);
                                }
                                event.accepted = true;
                            }
                        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) {
                            // Intercept Ctrl+V to handle image/file pasting
                            if (event.modifiers & Qt.ShiftModifier) {
                                // Let Shift+Ctrl+V = plain paste
                                messageInputField.text += Quickshell.clipboardText;
                                event.accepted = true;
                                return;
                            }
                            // Try image paste first
                            const currentClipboardEntry = Cliphist.entries[0];
                            const cleanCliphistEntry = StringUtils.cleanCliphistEntry(currentClipboardEntry);
                            if (/^\d+\t\[\[.*binary data.*\d+x\d+.*\]\]$/.test(currentClipboardEntry)) {
                                // First entry = currently copied entry = image?
                                decodeImageAndAttachProc.handleEntry(currentClipboardEntry);
                                event.accepted = true;
                                return;
                            } else if (cleanCliphistEntry.startsWith("file://")) {
                                // First entry = currently copied entry = image?
                                const fileName = decodeURIComponent(cleanCliphistEntry);
                                Ai.attachFile(fileName);
                                event.accepted = true;
                                return;
                            }
                            event.accepted = false; // No image, let text pasting proceed
                        } else if (event.key === Qt.Key_Escape) {
                            // Esc to detach file
                            if (Ai.pendingFilePath.length > 0) {
                                Ai.attachFile("");
                                event.accepted = true;
                            } else if (Ai.isGenerating) {
                                Ai.stopGenerating();
                                event.accepted = true;
                            } else {
                                event.accepted = false;
                            }
                        }
                    }
                }

                // Always-visible (while generating) activity indicator at the tail of the input box.
                BusyIndicator {
                    id: generatingIndicator
                    Layout.alignment: Qt.AlignTop
                    Layout.rightMargin: 6
                    implicitWidth: 18
                    implicitHeight: 18
                    running: Ai.isGenerating
                    visible: opacity > 0
                    opacity: Ai.isGenerating ? 1 : 0

                    Behavior on opacity {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                }

                RippleButton { // Send button
                    id: sendButton
                    Layout.alignment: Qt.AlignTop
                    Layout.rightMargin: 5
                    implicitWidth: 40
                    implicitHeight: 40
                    buttonRadius: Appearance.rounding.small
                    enabled: Ai.isGenerating || messageInputField.text.length > 0
                    toggled: Ai.isGenerating ? true : enabled

                    // Make the stop state visually distinct.
                    colBackgroundToggled: Ai.isGenerating ? Appearance.colors.colErrorContainer : Appearance.colors.colPrimary
                    colBackgroundToggledHover: Ai.isGenerating ? Appearance.colors.colErrorContainerHover : Appearance.colors.colPrimaryHover
                    colRippleToggled: Ai.isGenerating ? Appearance.colors.colErrorContainerActive : Appearance.colors.colPrimaryActive

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: sendButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (Ai.isGenerating) {
                                Ai.stopGenerating();
                                return;
                            }
                            const inputText = messageInputField.text;
                            root.handleInput(inputText);
                            messageInputField.clear();
                        }
                    }

                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        horizontalAlignment: Text.AlignHCenter
                        iconSize: 22
                        color: sendButton.enabled
                            ? (Ai.isGenerating ? Appearance.colors.colOnErrorContainer : Appearance.m3colors.m3onPrimary)
                            : Appearance.colors.colOnLayer2Disabled
                        text: Ai.isGenerating ? "stop" : "arrow_upward"
                    }
                }
            }

            RowLayout { // Controls
                id: commandButtonsRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 5
                anchors.leftMargin: 10
                anchors.rightMargin: 5
                spacing: 4

                property var commandsShown: [
                    {
                        name: "",
                        sendDirectly: false,
                        dontAddSpace: true
                    },
                    {
                        name: "clear",
                        sendDirectly: true
                    },
                ]

                ApiInputBoxIndicator {
                    // Model indicator
                    icon: "api"
                    text: Ai.getModel().name
                    tooltipText: Translation.tr("Current model: %1\nSet it with %2model MODEL").arg(Ai.getModel().name).arg(root.commandPrefix)
                }

                ApiInputBoxIndicator {
                    // Tool indicator
                    icon: "service_toolbox"
                    text: Ai.currentTool.charAt(0).toUpperCase() + Ai.currentTool.slice(1)
                    tooltipText: Translation.tr("Current tool: %1\nSet it with %2tool TOOL").arg(Ai.currentTool).arg(root.commandPrefix)
                }

                RippleButton {
                    id: apiSettingsButton
                    implicitWidth: 30
                    implicitHeight: 30
                    buttonRadius: Appearance.rounding.small
                    padding: 0
                    colBackground: Appearance.colors.colLayer2
                    colBackgroundHover: Appearance.colors.colLayer2Hover
                    colRipple: Appearance.colors.colLayer2Active

                    MouseArea {
                        id: apiSettingsButtonMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openApiSettings()
                    }

                    contentItem: MaterialSymbol {
                        anchors.fill: parent
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        iconSize: Appearance.font.pixelSize.normal
                        color: Appearance.m3colors.m3onSurface
                        text: "settings"
                    }

                    StyledToolTip {
                        extraVisibleCondition: false
                        alternativeVisibleCondition: apiSettingsButtonMouseArea.containsMouse
                        text: Translation.tr("API settings (Base URL + API Key)")
                    }
                }

                // Undo delete button
                RippleButton {
                    id: undoDeleteButton
                    visible: Ai.canUndoDelete
                    implicitWidth: 30
                    implicitHeight: 30
                    buttonRadius: Appearance.rounding.small
                    padding: 0
                    colBackground: Appearance.colors.colLayer2
                    colBackgroundHover: Appearance.colors.colLayer2Hover
                    colRipple: Appearance.colors.colLayer2Active

                    MouseArea {
                        id: undoDeleteButtonMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Ai.undoLastDelete()
                    }

                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        iconSize: Appearance.font.pixelSize.normal
                        color: Appearance.m3colors.m3onSurface
                        text: "undo"
                    }

                    StyledToolTip {
                        extraVisibleCondition: false
                        alternativeVisibleCondition: undoDeleteButtonMouseArea.containsMouse
                        text: Translation.tr("Undo delete (Ctrl+Z)")
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                // Context window indicator (moved from top status bar)
                MouseArea {
                    id: ctxWindowItem
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: true
                    implicitHeight: Math.max(22, ctxRow.implicitHeight)
                    implicitWidth: ctxRow.implicitWidth
                    Layout.alignment: Qt.AlignVCenter

                    // Prefer prompt tokens (input) as a context-window proxy.
                    property int used: Math.round(requestAnim.input)
                    property int limit: (Ai.models?.[Ai.currentModelId]?.context_length ?? 0)
                    property real progressTarget: (limit > 0 && used >= 0) ? Math.min(1, used / limit) : 0
                    property real progress: progressTarget

                    Behavior on progress {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }

                    RowLayout {
                        id: ctxRow
                        spacing: 6
                        Layout.alignment: Qt.AlignVCenter
                        TokenRing {
                            progress: ctxWindowItem.progress
                        }
                        StyledText {
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                            Layout.alignment: Qt.AlignVCenter
                            text: {
                                if (ctxWindowItem.limit <= 0) return "-";
                                if (ctxWindowItem.used < 0) return `? / ${root.fmtTokensCompact(ctxWindowItem.limit)}`;
                                return `${root.fmtTokensCompact(ctxWindowItem.used)} / ${root.fmtTokensCompact(ctxWindowItem.limit)}`;
                            }
                        }
                    }

                    StyledToolTip {
                        text: {
                            const used = ctxWindowItem.used;
                            const limit = ctxWindowItem.limit;
                            if (limit <= 0) return Translation.tr("Context window: unknown");
                            if (used < 0) return Translation.tr("Context window\n? / %1 tokens").arg(limit);
                            return Translation.tr("Context window (prompt tokens)\n%1 / %2 tokens (%3%)")
                                .arg(used)
                                .arg(limit)
                                .arg(Math.round(ctxWindowItem.progress * 100));
                        }
                        extraVisibleCondition: false
                        alternativeVisibleCondition: ctxWindowItem.containsMouse
                    }
                }

                ButtonGroup {
                    // Command buttons
                    padding: 0

                    Repeater {
                        // Command buttons
                        model: commandButtonsRow.commandsShown
                        delegate: ApiCommandButton {
                            property string commandRepresentation: `${root.commandPrefix}${modelData.name}`
                            buttonText: commandRepresentation
                            downAction: () => {
                                if (modelData.sendDirectly) {
                                    root.handleInput(commandRepresentation);
                                } else {
                                    messageInputField.text = commandRepresentation + (modelData.dontAddSpace ? "" : " ");
                                    messageInputField.cursorPosition = messageInputField.text.length;
                                    messageInputField.forceActiveFocus();
                                }
                                if (modelData.name === "clear") {
                                    messageInputField.text = "";
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // If keyring finishes loading while dialog is open, populate the draft (if still empty)
    Connections {
        target: KeyringStorage
        function onLoadedChanged() {
            if (root._destroying) return;
            if (!root.showApiSettingsDialog) return;
            if ((root.apiKeyDraft ?? "").length === 0) {
                root.apiKeyDraft = Ai.openaiApiKey ?? "";
            }
        }
    }

    WindowDialog {
        id: apiSettingsDialog
        // Avoid complex parent binding; just use root. dialogOverlayParent causes teardown issues.
        parent: root
        anchors.fill: parent
        z: 9999
        show: root.showApiSettingsDialog
        // Tune size: narrower (-15%) and a bit taller for comfortable spacing.
        backgroundWidth: 442
        backgroundHeight: 380
        onDismiss: root.showApiSettingsDialog = false

        onShowChanged: {
            if (!show) return;
            Qt.callLater(() => {
                if (root._destroying) return;
                if (!root.showApiSettingsDialog) return;
                try { apiBaseUrlField.forceActiveFocus(); } catch (e) {}
            });
        }

        WindowDialogTitle {
            text: Translation.tr("API settings")
        }

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: Appearance.m3colors.m3onSurfaceVariant
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("Configure an OpenAI-compatible provider. For DeepSeek use Base URL https://api.deepseek.com (no /v1).")
        }

        MaterialTextField {
            id: apiBaseUrlField
            Layout.fillWidth: true
            placeholderText: Translation.tr("Base URL (e.g. https://api.deepseek.com)")
            text: root.apiBaseUrlDraft
            onTextChanged: root.apiBaseUrlDraft = text
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialTextField {
                id: apiKeyField
                Layout.fillWidth: true
                placeholderText: Translation.tr("API key")
                echoMode: root.apiKeyVisible ? TextInput.Normal : TextInput.Password
                text: root.apiKeyDraft
                onTextChanged: root.apiKeyDraft = text
            }

            DialogButton {
                buttonText: root.apiKeyVisible ? Translation.tr("Hide") : Translation.tr("Show")
                onClicked: root.apiKeyVisible = !root.apiKeyVisible
            }
        }

        WindowDialogSeparator {}

        WindowDialogButtonRow {
            DialogButton {
                buttonText: Translation.tr("Cancel")
                onClicked: apiSettingsDialog.dismiss()
            }

            Item { Layout.fillWidth: true }

            DialogButton {
                buttonText: Translation.tr("Save")
                onClicked: {
                    Ai.setOpenAiBaseUrl(root.apiBaseUrlDraft, false);
                    Ai.setOpenAiApiKey(root.apiKeyDraft, false);
                    // Apply settings to local backend immediately.
                    Ai.restartBackend();
                    apiSettingsDialog.dismiss();
                }
            }
        }
    }

    // Chat/session manager
    WindowDialog {
        id: chatManagerDialog
        parent: root
        anchors.fill: parent
        z: 9999
        show: root.showChatManagerDialog
        // Responsive sizing: fit within available page area.
        backgroundWidth: Math.max(300, Math.min(520, (root.width || 0) - 24))
        backgroundHeight: Math.max(380, Math.min(560, (root.height || 0) - 24))
        onDismiss: root.showChatManagerDialog = false

        onShowChanged: {
            if (!show) return;
            // Keep list fresh whenever opened.
            Ai.refreshChatList();
        }

        Timer {
            id: pendingDeleteResetTimer
            interval: 2500
            repeat: false
            onTriggered: root.__pendingDeleteChatId = -1
        }

        WindowDialogTitle {
            text: Translation.tr("Chats")
        }

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: Appearance.m3colors.m3onSurfaceVariant
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("Switch between sessions, create new ones, rename them, or delete old chats.")
        }

        Rectangle {
            Layout.fillWidth: true
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.small
            implicitHeight: chatListColumn.implicitHeight + 10 * 2

            ColumnLayout {
                id: chatListColumn
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6

                StyledText {
                    Layout.fillWidth: true
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                    text: Translation.tr("Sessions")
                }

                Loader {
                    Layout.fillWidth: true
                    active: (Ai.chatList?.length ?? 0) === 0
                    sourceComponent: StyledText {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        color: Appearance.colors.colSubtext
                        font.pixelSize: Appearance.font.pixelSize.small
                        text: Translation.tr("No chats found.")
                    }
                }

                ScrollView {
                    Layout.fillWidth: true
                    // Keep the list area bounded inside the dialog.
                    implicitHeight: Math.min(280, listInner.implicitHeight)
                    clip: true
                    visible: (Ai.chatList?.length ?? 0) > 0

                    ColumnLayout {
                        id: listInner
                        width: parent.width
                        spacing: 6

                        Repeater {
                            model: Ai.chatList ?? []
                            delegate: Rectangle {
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: row.implicitHeight + 8 * 2
                                height: implicitHeight
                                radius: Appearance.rounding.small
                                color: (modelData?.id === Ai.currentChatId)
                                    ? Appearance.colors.colSecondaryContainer
                                    : Appearance.colors.colLayer1

                                property bool hovered: false

                                RowLayout {
                                    id: row
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 10

                                    // Click area for switching chats (exclude action buttons on the right).
                                    MouseArea {
                                        id: switchArea
                                        anchors {
                                            left: parent.left
                                            top: parent.top
                                            bottom: parent.bottom
                                            // Keep right side free for edit/delete buttons.
                                            right: editChatButton.left
                                        }
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        enabled: root.__editingChatId !== (modelData?.id ?? -999)
                                        onEntered: parent.parent.hovered = true
                                        onExited: parent.parent.hovered = false
                                        onClicked: {
                                            const cid = modelData?.id;
                                            if (typeof cid !== "number") return;
                                            if (cid === Ai.currentChatId) {
                                                chatManagerDialog.dismiss();
                                                return;
                                            }
                                            Ai.loadChatById(cid, true /* quiet */);
                                            chatManagerDialog.dismiss();
                                        }
                                    }

                                    Item {
                                        Layout.alignment: Qt.AlignVCenter
                                        implicitWidth: 22
                                        implicitHeight: 22
                                        MaterialSymbol {
                                            anchors.centerIn: parent
                                            text: (modelData?.id === Ai.currentChatId) ? "check_circle" : "chat_bubble"
                                            iconSize: Appearance.font.pixelSize.normal
                                            color: (modelData?.id === Ai.currentChatId)
                                                ? Appearance.m3colors.m3onSecondaryContainer
                                                : Appearance.colors.colSubtext
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        Loader {
                                            Layout.fillWidth: true
                                            active: root.__editingChatId === (modelData?.id ?? -999)
                                            sourceComponent: MaterialTextField {
                                                Layout.fillWidth: true
                                                placeholderText: Translation.tr("Chat name")
                                                text: root.__editingChatNameDraft
                                                onTextChanged: root.__editingChatNameDraft = text
                                            }
                                        }

                                        Loader {
                                            Layout.fillWidth: true
                                            active: root.__editingChatId !== (modelData?.id ?? -999)
                                            sourceComponent: StyledText {
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                                font.pixelSize: Appearance.font.pixelSize.small
                                                color: (modelData?.id === Ai.currentChatId)
                                                    ? Appearance.m3colors.m3onSecondaryContainer
                                                    : Appearance.colors.colOnLayer1
                                                text: {
                                                    const n = (modelData?.name ?? "").trim();
                                                    return n.length > 0 ? n : Translation.tr("Unnamed")
                                                }
                                            }
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            color: Appearance.colors.colSubtext
                                            text: `#${modelData?.id ?? "?"}`
                                        }
                                    }

                                    // Rename button / confirm-cancel while editing
                                    RippleButton {
                                        id: editChatButton
                                        implicitWidth: 28
                                        implicitHeight: 28
                                        Layout.alignment: Qt.AlignVCenter
                                        buttonRadius: Appearance.rounding.small
                                        padding: 0
                                        colBackground: ColorUtils.transparentize(Appearance.colors.colLayer2, 1)
                                        colBackgroundHover: Appearance.colors.colLayer2Hover
                                        colRipple: Appearance.colors.colLayer2Active

                                        contentItem: MaterialSymbol {
                                            anchors.fill: parent
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                            text: (root.__editingChatId === modelData?.id) ? "check" : "edit"
                                            iconSize: Appearance.font.pixelSize.normal
                                            color: Appearance.colors.colSubtext
                                        }

                                        onClicked: {
                                            const cid = modelData?.id;
                                            if (typeof cid !== "number") return;
                                            if (root.__editingChatId !== cid) {
                                                root.__editingChatId = cid;
                                                root.__editingChatNameDraft = (modelData?.name ?? "").toString();
                                                return;
                                            }

                                            // Confirm rename
                                            const nextName = (root.__editingChatNameDraft ?? "").trim();
                                            Ai.renameChatById(cid, nextName, true /* quiet */);
                                            root.__editingChatId = -1;
                                            root.__editingChatNameDraft = "";
                                        }

                                        StyledToolTip {
                                            extraVisibleCondition: false
                                            alternativeVisibleCondition: editChatButton.hovered
                                            text: (root.__editingChatId === modelData?.id)
                                                ? Translation.tr("Save")
                                                : Translation.tr("Rename")
                                        }
                                    }

                                    RippleButton {
                                        id: cancelEditChatButton
                                        visible: root.__editingChatId === modelData?.id
                                        implicitWidth: 28
                                        implicitHeight: 28
                                        Layout.alignment: Qt.AlignVCenter
                                        buttonRadius: Appearance.rounding.small
                                        padding: 0
                                        colBackground: ColorUtils.transparentize(Appearance.colors.colLayer2, 1)
                                        colBackgroundHover: Appearance.colors.colLayer2Hover
                                        colRipple: Appearance.colors.colLayer2Active

                                        contentItem: MaterialSymbol {
                                            anchors.fill: parent
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                            text: "close"
                                            iconSize: Appearance.font.pixelSize.normal
                                            color: Appearance.colors.colSubtext
                                        }

                                        onClicked: {
                                            root.__editingChatId = -1;
                                            root.__editingChatNameDraft = "";
                                        }

                                        StyledToolTip {
                                            extraVisibleCondition: false
                                            alternativeVisibleCondition: cancelEditChatButton.hovered
                                            text: Translation.tr("Cancel")
                                        }
                                    }

                                    RippleButton {
                                        id: deleteChatButton
                                        implicitWidth: 28
                                        implicitHeight: 28
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: root.__editingChatId !== modelData?.id
                                        buttonRadius: Appearance.rounding.small
                                        padding: 0
                                        colBackground: (root.__pendingDeleteChatId === modelData?.id)
                                            ? Appearance.colors.colErrorContainer
                                            : ColorUtils.transparentize(Appearance.colors.colLayer2, 1)
                                        colBackgroundHover: Appearance.colors.colLayer2Hover
                                        colRipple: Appearance.colors.colLayer2Active

                                        contentItem: MaterialSymbol {
                                            anchors.fill: parent
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                            text: "delete"
                                            iconSize: Appearance.font.pixelSize.normal
                                            color: (root.__pendingDeleteChatId === modelData?.id)
                                                ? Appearance.m3colors.m3onErrorContainer
                                                : Appearance.colors.colSubtext
                                        }

                                        onClicked: {
                                            const cid = modelData?.id;
                                            if (typeof cid !== "number") return;
                                            if (root.__pendingDeleteChatId !== cid) {
                                                root.__pendingDeleteChatId = cid;
                                                pendingDeleteResetTimer.restart();
                                                return;
                                            }
                                            root.__pendingDeleteChatId = -1;
                                            pendingDeleteResetTimer.stop();
                                            Ai.deleteChatById(cid, true /* quiet */);
                                            // Keep dialog open; list will refresh via Ai.deleteChatById -> refreshChatList.
                                        }

                                        StyledToolTip {
                                            extraVisibleCondition: false
                                            alternativeVisibleCondition: deleteChatButton.hovered
                                            text: (root.__pendingDeleteChatId === modelData?.id)
                                                ? Translation.tr("Click again to delete")
                                                : Translation.tr("Delete")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialTextField {
                id: newChatNameField
                Layout.fillWidth: true
                placeholderText: Translation.tr("New chat name (optional)")
                text: root.newChatNameDraft
                onTextChanged: root.newChatNameDraft = text
            }

            DialogButton {
                buttonText: Translation.tr("New")
                onClicked: {
                    Ai.createNewChat(root.newChatNameDraft, true /* quiet */);
                    chatManagerDialog.dismiss();
                }
            }
        }

        WindowDialogButtonRow {
            DialogButton {
                buttonText: Translation.tr("Close")
                onClicked: chatManagerDialog.dismiss()
            }

            Item { Layout.fillWidth: true }

            DialogButton {
                buttonText: Translation.tr("Refresh")
                onClicked: Ai.refreshChatList()
            }
        }
    }

    Loader {
        parent: root.dialogOverlayParent ?? root
        anchors.fill: parent
        active: root.showRequestLog
        visible: root.showRequestLog
        z: 9999
        sourceComponent: Component {
            RequestLogDialog {
                anchors.fill: parent
                onClosed: root.showRequestLog = false
            }
        }
    }
}
