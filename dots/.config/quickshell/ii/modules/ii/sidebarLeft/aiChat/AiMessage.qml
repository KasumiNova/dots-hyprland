import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

Rectangle {
    id: root
    property int messageIndex
    property var messageData
    property var messageInputField

    // Guard: skip rendering if messageData is null/undefined
    visible: root.messageData !== null && root.messageData !== undefined
    enabled: visible

    property real messagePadding: 7
    property real contentSpacing: 3

    property bool enableMouseSelection: false
    property bool renderMarkdown: true
    property bool editing: false

    // NOTE: Don't use list<var> binding here.
    // list properties are not reliably re-evaluated as messageData.content streams in.
    // Use a var + explicit recomputation so unfinished code/think blocks grow live.
    property var messageBlocks: ([])

    function recomputeMessageBlocks() {
        const content = root.messageData?.content ?? "";
        root.messageBlocks = StringUtils.splitMarkdownBlocks(content);
    }

    onMessageDataChanged: recomputeMessageBlocks()

    Connections {
        target: root.messageData ?? null
        enabled: root.messageData !== null
        function onContentChanged() {
            root.recomputeMessageBlocks();
        }
        function onToolCallsChanged() {
            // Force update when tool calls change
            root.messageDataChanged();
        }
    }

    Component.onCompleted: recomputeMessageBlocks()

    anchors.left: parent?.left
    anchors.right: parent?.right
    implicitHeight: columnLayout.implicitHeight + root.messagePadding * 2

    radius: Appearance.rounding.normal
    color: Appearance.colors.colLayer1

    function saveMessage() {
        if (!root.editing) return;
        // Get all Loader children (each represents a segment)
        const segments = messageContentColumnLayout.children
            .map(child => child.segment)
            .filter(segment => (segment));

        // Reconstruct markdown
        const newContent = segments.map(segment => {
            if (segment.type === "code") {
                const lang = segment.lang ? segment.lang : "";
                // Remove trailing newlines
                const code = segment.content.replace(/\n+$/, "");
                return "```" + lang + "\n" + code + "\n```";
            } else {
                return segment.content;
            }
        }).join("");

        root.editing = false
        root.messageData.content = newContent;
    }

    Keys.onPressed: (event) => {
        if ( // Prevent de-select
            event.key === Qt.Key_Control || 
            event.key == Qt.Key_Shift || 
            event.key == Qt.Key_Alt || 
            event.key == Qt.Key_Meta
        ) {
            event.accepted = true
        }
        // Ctrl + S to save
        if ((event.key === Qt.Key_S) && event.modifiers == Qt.ControlModifier) {
            root.saveMessage();
            event.accepted = true;
        }
    }

    ColumnLayout { // Main layout of the whole thing
        id: columnLayout

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: messagePadding
        spacing: root.contentSpacing

        Rectangle {
            Layout.fillWidth: true
            implicitWidth: headerRowLayout.implicitWidth + 4 * 2
            implicitHeight: headerRowLayout.implicitHeight + 4 * 2
            color: Appearance.colors.colSecondaryContainer
            radius: Appearance.rounding.small
        
            RowLayout { // Header
                id: headerRowLayout
                anchors {
                    fill: parent
                    margins: 4
                }
                spacing: 18

                Item { // Name
                    id: nameWrapper
                    implicitHeight: Math.max(nameRowLayout.implicitHeight + 5 * 2, 30)
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter

                    RowLayout {
                        id: nameRowLayout
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 12

                        Item {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.fillHeight: true
                            // Always show model/role icon, never tool icon in header
                            implicitWidth: messageData?.role == 'assistant' ? modelIcon.width : roleIcon.implicitWidth
                            implicitHeight: messageData?.role == 'assistant' ? modelIcon.height : roleIcon.implicitHeight

                            CustomIcon {
                                id: modelIcon
                                anchors.centerIn: parent
                                visible: messageData?.role == 'assistant' && (Ai.models[messageData?.model]?.icon ?? false)
                                width: Appearance.font.pixelSize.large
                                height: Appearance.font.pixelSize.large
                                source: messageData?.role == 'assistant' ? (Ai.models[messageData?.model]?.icon ?? "") :
                                    messageData?.role == 'user' ? 'linux-symbolic' : 'desktop-symbolic'

                                colorize: true
                                color: Appearance.m3colors.m3onSecondaryContainer
                            }

                            MaterialSymbol {
                                id: roleIcon
                                anchors.centerIn: parent
                                visible: !parent.isToolMessage && !modelIcon.visible
                                iconSize: Appearance.font.pixelSize.larger
                                color: Appearance.m3colors.m3onSecondaryContainer
                                text: messageData?.role == 'user' ? 'person' : 
                                    messageData?.role == 'interface' ? 'settings' : 
                                    messageData?.role == 'assistant' ? 'neurology' : 
                                    'computer'
                            }
                        }

                        StyledText {
                            id: providerName
                            Layout.alignment: Qt.AlignVCenter
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.normal
                            color: Appearance.m3colors.m3onSecondaryContainer
                            // Always show model/user name - tool info is in the tool blocks
                            text: messageData?.role == 'assistant' ? (Ai.models[messageData?.model]?.name ?? "") :
                                (messageData?.role == 'user' && SystemInfo.username) ? SystemInfo.username :
                                Translation.tr("Interface")
                        }
                    }
                }

                Button { // Not visible to model
                    id: modelVisibilityIndicator
                    visible: messageData?.role == 'interface'
                    implicitWidth: 16
                    implicitHeight: 30
                    Layout.alignment: Qt.AlignVCenter

                    background: Item

                    MaterialSymbol {
                        id: notVisibleToModelText
                        anchors.centerIn: parent
                        iconSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colSubtext
                        text: "visibility_off"
                    }
                    StyledToolTip {
                        text: Translation.tr("Not visible to model")
                    }
                }

                ButtonGroup {
                    spacing: 5

                    AiMessageControlButton {
                        id: regenButton
                        buttonIcon: "refresh"
                        visible: messageData?.role === 'assistant'

                        onClicked: {
                            Ai.regenerate(root.messageIndex)
                        }
                        
                        StyledToolTip {
                            text: Translation.tr("Regenerate")
                        }
                    }

                    AiMessageControlButton {
                        id: rollbackButton
                        buttonIcon: "history"
                        // Show for user messages to get a new response from here
                        // Also show for messages that have subsequent messages (not the last message)
                        visible: messageData?.role === 'user' && root.messageIndex < Ai.messageIDs.length - 1

                        onClicked: {
                            Ai.rollbackAndRegenerate(root.messageIndex)
                        }
                        
                        StyledToolTip {
                            text: Translation.tr("Rollback & regenerate from here")
                        }
                    }

                    AiMessageControlButton {
                        id: copyButton
                        buttonIcon: activated ? "inventory" : "content_copy"

                        onClicked: {
                            Quickshell.clipboardText = root.messageData?.content
                            copyButton.activated = true
                            copyIconTimer.restart()
                        }

                        Timer {
                            id: copyIconTimer
                            interval: 1500
                            repeat: false
                            onTriggered: {
                                copyButton.activated = false
                            }
                        }
                        
                        StyledToolTip {
                            text: Translation.tr("Copy")
                        }
                    }
                    AiMessageControlButton {
                        id: editButton
                        activated: root.editing
                        enabled: root.messageData?.done ?? false
                        buttonIcon: "edit"
                        onClicked: {
                            root.editing = !root.editing
                            if (!root.editing) { // Save changes
                                root.saveMessage()
                            }
                        }
                        StyledToolTip {
                            text: root.editing ? Translation.tr("Save") : Translation.tr("Edit")
                        }
                    }
                    AiMessageControlButton {
                        id: toggleMarkdownButton
                        activated: !root.renderMarkdown
                        buttonIcon: "code"
                        onClicked: {
                            root.renderMarkdown = !root.renderMarkdown
                        }
                        StyledToolTip {
                            text: Translation.tr("View Markdown source")
                        }
                    }
                    AiMessageControlButton {
                        id: deleteButton
                        buttonIcon: "close"
                        onClicked: {
                            Ai.removeMessage(root.messageIndex)
                        }
                        StyledToolTip {
                            text: Translation.tr("Delete")
                        }
                    }
                }
            }
        }

        Loader {
            Layout.fillWidth: true
            active: (root.messageData?.localFilePath ?? "").length > 0
            sourceComponent: AttachedFileIndicator {
                filePath: root.messageData?.localFilePath ?? ""
                canRemove: false
            }
        }

        ColumnLayout { // Message content
            id: messageContentColumnLayout
            // Add vertical spacing between rich blocks (think/tool/code/text)
            // so the timeline reads cleanly.
            spacing: 6
            // Always show message content - tool block is displayed separately above
            visible: root.messageBlocks.length > 0

            Item {
                Layout.fillWidth: true
                implicitHeight: loadingIndicatorLoader.shown ? loadingIndicatorLoader.implicitHeight : 0
                implicitWidth: loadingIndicatorLoader.implicitWidth
                visible: implicitHeight > 0

                Behavior on implicitHeight {
                    animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                }
                FadeLoader {
                    id: loadingIndicatorLoader
                    anchors.centerIn: parent
                    shown: (root.messageBlocks.length < 1) && (root.messageData != null) && (root.messageData?.done === false) && !toolBlocksRepeater.count
                    sourceComponent: MaterialLoadingIndicator {
                        loading: true
                    }
                }
            }
            Repeater {
                model: ScriptModel {
                    values: root.messageBlocks
                }
                delegate: DelegateChooser {
                    id: messageDelegate
                    role: "type"

                    DelegateChoice { roleValue: "code"; MessageCodeBlock {
                        editing: root.editing
                        renderMarkdown: root.renderMarkdown
                        enableMouseSelection: root.enableMouseSelection
                        segmentContent: modelData.content
                        segmentLang: modelData.lang
                        messageData: root.messageData
                    } }
                    DelegateChoice { roleValue: "think"; MessageThinkBlock {
                        editing: root.editing
                        renderMarkdown: root.renderMarkdown
                        enableMouseSelection: root.enableMouseSelection
                        segmentContent: modelData.content
                        messageData: root.messageData
                        done: root.messageData?.done ?? false
                        completed: modelData.completed ?? false
                        // Don't pass toolCalls here - they are now shown inline via tool markers
                        toolCalls: []
                    } }
                    DelegateChoice { roleValue: "text"; MessageTextBlock {
                        editing: root.editing
                        renderMarkdown: root.renderMarkdown
                        enableMouseSelection: root.enableMouseSelection
                        segmentContent: modelData.content
                        messageData: root.messageData
                        done: root.messageData?.done ?? false
                        forceDisableChunkSplitting: (root.messageData?.content ?? "").includes("```")
                    } }
                    DelegateChoice { roleValue: "tool"; MessageToolBlock {
                        // Find the tool call data by ID
                        property string __toolId: modelData.toolId ?? ""
                        property var matchedToolCall: {
                            const toolId = __toolId;
                            const calls = root.messageData?.toolCalls ?? [];
                            return calls.find(tc => tc.id === toolId) ?? null;
                        }
                        Layout.fillWidth: true
                        toolCallData: matchedToolCall ?? ({
                            id: __toolId,
                            name: root.messageData?.functionName || "tool",
                            args: {},
                            status: "completed",
                            result: {
                                success: false,
                                output: "【历史记录】该工具调用的详细信息在保存的会话里缺失（通常是旧会话：当时还没把 toolCalls 持久化进后端数据库）。"
                            }
                        })
                        messageData: root.messageData
                        visible: (__toolId.length > 0)
                    } }
                }
            }
        }

        // Tool calls - only displayed when there are tool calls without position markers
        ColumnLayout {
            id: toolBlocksColumn
            Layout.fillWidth: true
            Layout.topMargin: visible ? 8 : 0
            spacing: 6
            // Only show tool calls that don't have inline position markers
            visible: {
                const allToolCalls = root.messageData?.toolCalls ?? [];
                const markedToolIds = root.messageBlocks.filter(b => b.type === "tool").map(b => b.toolId);
                const unmarkedCalls = allToolCalls.filter(tc => !markedToolIds.includes(tc.id));
                return unmarkedCalls.length > 0;
            }

            Repeater {
                id: toolBlocksRepeater
                model: ScriptModel {
                    // Only show tool calls without inline markers
                    values: {
                        const allToolCalls = root.messageData?.toolCalls ?? [];
                        const markedToolIds = root.messageBlocks.filter(b => b.type === "tool").map(b => b.toolId);
                        return allToolCalls.filter(tc => !markedToolIds.includes(tc.id));
                    }
                }
                delegate: MessageToolBlock {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    toolCallData: modelData
                    messageData: root.messageData
                }
            }
        }

        Flow { // Annotations
            visible: root.messageData?.annotationSources?.length > 0
            spacing: 5
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignLeft

            Repeater {
                model: ScriptModel {
                    values: root.messageData?.annotationSources || []
                }
                delegate: AnnotationSourceButton {
                    required property var modelData
                    displayText: modelData.text
                    url: modelData.url
                }
            }
        }

        Flow { // Search queries
            visible: root.messageData?.searchQueries?.length > 0
            spacing: 5
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignLeft

            Repeater {
                model: ScriptModel {
                    values: root.messageData?.searchQueries || []
                }
                delegate: SearchQueryButton {
                    required property var modelData
                    query: modelData
                }
            }
        }

    }
}

