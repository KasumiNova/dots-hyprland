pragma ComponentBehavior: Bound

import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import org.kde.syntaxhighlighting

ColumnLayout {
    id: root
    // These are needed on the parent loader
    property bool editing: false
    property bool renderMarkdown: true
    property bool enableMouseSelection: false
    property string segmentContent: ""
    property string segmentLang: "txt"
    property var messageData: {}
    property bool isCommandRequest: segmentLang === "command"
    property string displayLang: (isCommandRequest ? "bash" : segmentLang)

    // Used by edit/save flow in AiMessage.qml
    property var segment: ({
        "type": "code",
        "lang": root.segmentLang,
        "content": root.segmentContent,
    })

    property real codeBlockBackgroundRounding: Appearance.rounding.small
    property real codeBlockHeaderPadding: 3
    property real codeBlockComponentSpacing: 2
    // Maximum height of the code area (not including the title bar)
    property real maxCodeAreaHeight: 260

    // Cache the internal Flickable from ScrollView so we can sync line numbers.
    property var __codeFlick: null

    function __handleCodeWheel(wheel) {
        const flick = codeFlick;
        if (!flick) return false;

        const eps = 0.5;

        // Prefer pixelDelta for touchpads; fallback to angleDelta for mouse wheels
        const dx = (wheel.pixelDelta && wheel.pixelDelta.x !== 0) ? wheel.pixelDelta.x : wheel.angleDelta.x;
        const dy = (wheel.pixelDelta && wheel.pixelDelta.y !== 0) ? wheel.pixelDelta.y : wheel.angleDelta.y;

        // Horizontal scrolling (trackpads etc.)
        const canScrollX = (flick.contentWidth > flick.width + 1);
        if (Math.abs(dx) > Math.abs(dy) && dx !== 0 && canScrollX) {
            const maxX = Math.max(0, flick.contentWidth - flick.width);
            const stepX = (wheel.pixelDelta && wheel.pixelDelta.x !== 0) ? 1 : 40;
            const deltaX = (wheel.pixelDelta && wheel.pixelDelta.x !== 0) ? dx : (dx / 120) * stepX;

            // At edges: bubble the wheel to the outer chat list.
            if ((flick.contentX <= eps && deltaX > 0) || (flick.contentX >= maxX - eps && deltaX < 0)) {
                return false;
            }

            const nextX = Math.max(0, Math.min(maxX, flick.contentX - deltaX));
            const didScrollX = Math.abs(nextX - flick.contentX) > 0.01;
            if (didScrollX) flick.contentX = nextX;
            return didScrollX;
        }

        // Vertical scrolling
        const canScrollY = (flick.contentHeight > flick.height + 1);
        if (!canScrollY || dy === 0) return false;

        const maxY = Math.max(0, flick.contentHeight - flick.height);
        const stepY = (wheel.pixelDelta && wheel.pixelDelta.y !== 0) ? 1 : 48;
        const deltaY = (wheel.pixelDelta && wheel.pixelDelta.y !== 0) ? dy : (dy / 120) * stepY;

        // At edges: bubble the wheel to the outer chat list.
        if ((flick.contentY <= eps && deltaY > 0) || (flick.contentY >= maxY - eps && deltaY < 0)) {
            return false;
        }

        const nextY = Math.max(0, Math.min(maxY, flick.contentY - deltaY));
        const didScrollY = Math.abs(nextY - flick.contentY) > 0.01;
        if (didScrollY) flick.contentY = nextY;
        return didScrollY;
    }

    spacing: codeBlockComponentSpacing

    Rectangle { // Code background
        Layout.fillWidth: true
        topLeftRadius: codeBlockBackgroundRounding
        topRightRadius: codeBlockBackgroundRounding
        bottomLeftRadius: Appearance.rounding.unsharpen
        bottomRightRadius: Appearance.rounding.unsharpen
        color: Appearance.colors.colSurfaceContainerHighest
        implicitHeight: codeBlockTitleBarRowLayout.implicitHeight + codeBlockHeaderPadding * 2

        RowLayout { // Language and buttons
            id: codeBlockTitleBarRowLayout
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: codeBlockHeaderPadding
            anchors.rightMargin: codeBlockHeaderPadding
            spacing: 5

            StyledText {
                id: codeBlockLanguage
                Layout.alignment: Qt.AlignLeft
                Layout.fillWidth: false
                Layout.topMargin: 7
                Layout.bottomMargin: 7
                Layout.leftMargin: 10
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnLayer2
                text: root.displayLang ? Repository.definitionForName(root.displayLang).name : "plain"
            }

            Item { Layout.fillWidth: true }

            ButtonGroup {
                AiMessageControlButton {
                    id: copyCodeButton
                    buttonIcon: activated ? "inventory" : "content_copy"

                    onClicked: {
                        Quickshell.clipboardText = segmentContent
                        copyCodeButton.activated = true
                        copyIconTimer.restart()
                    }

                    Timer {
                        id: copyIconTimer
                        interval: 1500
                        repeat: false
                        onTriggered: {
                            copyCodeButton.activated = false
                        }
                    }
                    StyledToolTip {
                        text: Translation.tr("Copy code")
                    }
                }
                AiMessageControlButton {
                    id: saveCodeButton
                    buttonIcon: activated ? "check" : "save"

                    onClicked: {
                        const downloadPath = FileUtils.trimFileProtocol(Directories.downloads)
                        Quickshell.execDetached(["bash", "-c", 
                            `echo '${StringUtils.shellSingleQuoteEscape(segmentContent)}' > '${downloadPath}/code.${segmentLang || "txt"}'`
                        ])
                        Quickshell.execDetached(["notify-send", 
                            Translation.tr("Code saved to file"), 
                            Translation.tr("Saved to %1").arg(`${downloadPath}/code.${segmentLang || "txt"}`),
                            "-a", "Shell"
                        ])
                        saveCodeButton.activated = true
                        saveIconTimer.restart()
                    }

                    Timer {
                        id: saveIconTimer
                        interval: 1500
                        repeat: false
                        onTriggered: {
                            saveCodeButton.activated = false
                        }
                    }
                    StyledToolTip {
                        text: Translation.tr("Save to Downloads")
                    }
                }
            }
        }
    }

    RowLayout { // Line numbers and code
        spacing: codeBlockComponentSpacing

        Rectangle { // Line numbers
            implicitWidth: 40
            implicitHeight: codeFlick.implicitHeight
            Layout.fillHeight: false
            Layout.fillWidth: false
            topLeftRadius: Appearance.rounding.unsharpen
            bottomLeftRadius: codeBlockBackgroundRounding
            topRightRadius: Appearance.rounding.unsharpen
            bottomRightRadius: Appearance.rounding.unsharpen
            color: Appearance.colors.colLayer2

            // Make line numbers scroll in sync with the code area.
            Flickable {
                id: lineNumberFlick
                anchors.fill: parent
                interactive: false
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                contentWidth: width
                contentHeight: lineNumberColumnLayout.implicitHeight + 12
                contentY: root.__codeFlick ? root.__codeFlick.contentY : 0

                // Wheel over line numbers should scroll the code area.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: (wheel) => {
                        const did = root.__handleCodeWheel(wheel);
                        wheel.accepted = did;
                    }
                }

                ColumnLayout {
                    id: lineNumberColumnLayout
                    width: parent.width
                    anchors.top: parent.top
                    anchors.topMargin: 6
                    anchors.right: parent.right
                    anchors.rightMargin: 5
                    spacing: 0

                    Repeater {
                        model: codeTextEdit.text.split("\n").length
                        Text {
                            required property int index
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignRight
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                            horizontalAlignment: Text.AlignRight
                            text: index + 1
                        }
                    }
                }
            }
        }

        Rectangle { // Code background
            Layout.fillWidth: true
            topLeftRadius: Appearance.rounding.unsharpen
            bottomLeftRadius: Appearance.rounding.unsharpen
            topRightRadius: Appearance.rounding.unsharpen
            bottomRightRadius: codeBlockBackgroundRounding
            color: Appearance.colors.colLayer2
            implicitHeight: codeColumnLayout.implicitHeight

            ColumnLayout {
                id: codeColumnLayout
                anchors.fill: parent
                spacing: 0
                // Use an explicit Flickable instead of ScrollView.
                // This guarantees contentHeight/contentWidth reflect the growing TextEdit,
                // so scrollbars appear and streaming content can be reached by scrolling.
                Flickable {
                    id: codeFlick
                    Layout.fillWidth: true
                    implicitWidth: parent.width
                    // Cap height so the code area can scroll vertically.
                    implicitHeight: Math.min(codeTextEdit.height + 1, root.maxCodeAreaHeight)
                    Layout.maximumHeight: root.maxCodeAreaHeight
                    clip: true

                    interactive: false
                    boundsBehavior: Flickable.StopAtBounds

                    contentWidth: codeTextEdit.width
                    contentHeight: codeTextEdit.height

                    Component.onCompleted: {
                        root.__codeFlick = codeFlick;
                        // Some Qt versions expose wheelEnabled; disable it so wheel can bubble out.
                        if (("wheelEnabled" in codeFlick)) codeFlick.wheelEnabled = false;
                    }

                    // Use Wheel via MouseArea so events can propagate to the outer StyledListView
                    // when we don't scroll (e.g. already at top/bottom).
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: (wheel) => {
                            const did = root.__handleCodeWheel(wheel);
                            wheel.accepted = did;
                        }
                    }

                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AsNeeded
                        width: 8
                        padding: 2
                        contentItem: Rectangle {
                            implicitWidth: 6
                            radius: Appearance.rounding.small
                            color: Appearance.colors.colLayer2Active
                        }
                    }

                    
                    ScrollBar.horizontal: ScrollBar {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        padding: 5
                        policy: ScrollBar.AsNeeded
                        opacity: visualSize == 1 ? 0 : 1
                        visible: opacity > 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Appearance.animation.elementMoveFast.duration
                                easing.type: Appearance.animation.elementMoveFast.type
                                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
                            }
                        }
                        
                        contentItem: Rectangle {
                            implicitHeight: 6
                            radius: Appearance.rounding.small
                            color: Appearance.colors.colLayer2Active
                        }
                    }

                    // Use a plain TextEdit instead of TextArea here.
                    // TextArea has its own internal Flickable; nesting it inside ScrollView
                    // makes outer scrolling (and streaming growth) appear "clipped".
                    TextEdit {
                        id: codeTextEdit
                        width: Math.max(codeFlick.width, contentWidth + 1)
                        height: Math.max(1, contentHeight + 1)

                        readOnly: !root.editing
                        selectByMouse: root.enableMouseSelection || root.editing
                        renderType: Text.NativeRendering
                        font.family: Appearance.font.family.monospace
                        font.hintingPreference: Font.PreferNoHinting // Prevent weird bold text
                        font.pixelSize: Appearance.font.pixelSize.small
                        selectedTextColor: Appearance.m3colors.m3onSecondaryContainer
                        selectionColor: Appearance.colors.colSecondaryContainer
                        wrapMode: TextEdit.NoWrap
                        textFormat: TextEdit.PlainText
                        color: root.messageData.thinking ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer1

                        text: root.segmentContent
                        onTextChanged: {
                            // Only update backing segment content while editing;
                            // otherwise keep the external binding so streaming updates flow in.
                            if (!root.editing) return;
                            root.segmentContent = text;
                        }

                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Tab) {
                                // Insert 4 spaces at cursor
                                const cursor = codeTextEdit.cursorPosition;
                                codeTextEdit.insert(cursor, "    ");
                                codeTextEdit.cursorPosition = cursor + 4;
                                event.accepted = true;
                            } else if ((event.key === Qt.Key_C) && event.modifiers == Qt.ControlModifier) {
                                codeTextEdit.copy();
                                event.accepted = true;
                            }
                        }

                        SyntaxHighlighter {
                            id: highlighter
                            textEdit: codeTextEdit
                            repository: Repository
                            definition: Repository.definitionForName(root.displayLang || "plaintext")
                            theme: Appearance.syntaxHighlightingTheme
                        }
                    }
                }
                Loader {
                    active: root.isCommandRequest && root.messageData.functionPending
                    visible: active
                    Layout.fillWidth: true
                    Layout.margins: 6
                    Layout.topMargin: 0
                    sourceComponent: RowLayout {
                        Item { Layout.fillWidth: true }
                        ButtonGroup {
                            GroupButton {
                                contentItem: StyledText {
                                    text: Translation.tr("Reject")
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.colors.colOnLayer2
                                }
                                onClicked: Ai.rejectCommand(root.messageData)
                            }
                            GroupButton {
                                toggled: true
                                contentItem: StyledText {
                                    text: Translation.tr("Approve")
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.colors.colOnPrimary
                                }
                                onClicked: Ai.approveCommand(root.messageData)
                            }
                        }
                    }
                }
            }

            // MouseArea to block scrolling
            // MouseArea {
            //     id: codeBlockMouseArea
            //     anchors.fill: parent
            //     acceptedButtons: editing ? Qt.NoButton : Qt.LeftButton
            //     cursorShape: (enableMouseSelection || editing) ? Qt.IBeamCursor : Qt.ArrowCursor
            //     onWheel: (event) => {
            //         event.accepted = false
            //     }
            // }
        }
    }
}