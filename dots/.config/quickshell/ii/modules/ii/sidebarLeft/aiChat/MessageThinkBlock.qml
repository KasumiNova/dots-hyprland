pragma ComponentBehavior: Bound

import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell

Item {
    id: root
    // These are needed on the parent loader
    property bool editing: false
    property bool renderMarkdown: true
    property bool enableMouseSelection: false
    property var segmentContent: ({})
    property var messageData: {}
    property bool done: true
    property bool completed: false

    // Tool calls to display nested within the think block
    property var toolCalls: []

    property real thinkBlockBackgroundRounding: Appearance.rounding.small
    property real thinkBlockHeaderPaddingVertical: 3
    property real thinkBlockHeaderPaddingHorizontal: 10
    property real thinkBlockComponentSpacing: 2

    property var collapseAnimation: messageTextBlock.implicitHeight > 40 ? Appearance.animation.elementMoveEnter : Appearance.animation.elementMoveFast
    property bool userToggled: false
    // While thinking, show the content (streaming). After completed, auto-collapse unless user toggled.
    property bool collapsed: false

    // Only animate collapse/expand transitions (not every height change while streaming).
    property bool __animateCollapseNow: false

    Timer {
        id: animateCollapseResetTimer
        interval: collapseAnimation.duration + 60
        repeat: false
        onTriggered: root.__animateCollapseNow = false
    }

    function __triggerCollapseAnimation() {
        root.__animateCollapseNow = true;
        animateCollapseResetTimer.restart();
    }

    // Prevent double-trigger (header MouseArea + button) and ultra-fast toggling.
    Timer {
        id: toggleCooldownTimer
        interval: 80
        repeat: false
    }

    function toggleCollapsed() {
        if (toggleCooldownTimer.running) return;
        toggleCooldownTimer.restart();
        root.userToggled = true;
        root.__triggerCollapseAnimation();
        root.collapsed = !root.collapsed;
    }

    onCompletedChanged: {
        // Show streaming content while incomplete
        if (!root.completed) {
            if (!root.userToggled) root.collapsed = false;
            return;
        }

        // Once completed, auto-collapse unless user already interacted during streaming.
        if (!root.userToggled) {
            root.__triggerCollapseAnimation();
            root.collapsed = true;
        }
    }

    // If the delegate gets (re)created after the think block is already completed,
    // onCompletedChanged won't fire. Do a one-shot animated collapse after first layout.
    Component.onCompleted: {
        if (root.completed && !root.userToggled) {
            root.collapsed = false;
            Qt.callLater(() => {
                if (root.userToggled) return;
                root.__triggerCollapseAnimation();
                root.collapsed = true;
            });
        }
    }

    Layout.fillWidth: true
    implicitHeight: collapsed ? header.implicitHeight : columnLayout.implicitHeight
    // Ensure the visual bounds follow the animated implicitHeight.
    // Without this, children may continue to paint outside the collapsed area and overlap other delegates.
    height: implicitHeight
    clip: true

    Behavior on implicitHeight {
        enabled: root.__animateCollapseNow
        NumberAnimation {
            duration: collapseAnimation.duration
            easing.type: collapseAnimation.type
            easing.bezierCurve: collapseAnimation.bezierCurve
        }
    }

    ColumnLayout {
        id: columnLayout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 0

        Rectangle { // Header background
            id: header
            color: Appearance.colors.colSurfaceContainerHighest
            Layout.fillWidth: true
            implicitHeight: thinkBlockTitleBarRowLayout.implicitHeight + thinkBlockHeaderPaddingVertical * 2
            topLeftRadius: thinkBlockBackgroundRounding
            topRightRadius: thinkBlockBackgroundRounding
            bottomLeftRadius: root.collapsed ? thinkBlockBackgroundRounding : 0
            bottomRightRadius: root.collapsed ? thinkBlockBackgroundRounding : 0

            MouseArea { // Click to reveal
                id: headerMouseArea
                enabled: true
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: (mouse) => {
                    // Clicking the expand button should not also trigger the header click.
                    const p = expandButton.mapToItem(headerMouseArea, 0, 0);
                    const inExpandButton = mouse.x >= p.x && mouse.x <= (p.x + expandButton.width)
                        && mouse.y >= p.y && mouse.y <= (p.y + expandButton.height);
                    if (inExpandButton) return;

                    root.toggleCollapsed();
                }
            }

            RowLayout { // Header content
                id: thinkBlockTitleBarRowLayout
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: thinkBlockHeaderPaddingHorizontal
                anchors.rightMargin: thinkBlockHeaderPaddingHorizontal
                spacing: 10

                // Left icon (normalized spacing/size across blocks)
                Item {
                    Layout.fillWidth: false
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 22
                    implicitHeight: 22

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "linked_services"
                        iconSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colOnLayer2
                    }
                }
                StyledText {
                    id: thinkBlockLanguage
                    Layout.fillWidth: false
                    Layout.alignment: Qt.AlignLeft
                    text: root.completed ? Translation.tr("Thought") : Translation.tr("Thinking")
                }
                Item { Layout.fillWidth: true }
                RippleButton { // Expand button
                    id: expandButton
                    visible: true
                    implicitWidth: 22
                    implicitHeight: 22
                    colBackground: headerMouseArea.containsMouse ? Appearance.colors.colLayer2Hover
                        : ColorUtils.transparentize(Appearance.colors.colLayer2, 1)
                    colBackgroundHover: Appearance.colors.colLayer2Hover
                    colRipple: Appearance.colors.colLayer2Active

                    onClicked: {
                        root.toggleCollapsed();
                    }
                    
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "keyboard_arrow_down"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        iconSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colOnLayer2
                        rotation: root.collapsed ? 0 : 180
                        Behavior on rotation {
                            NumberAnimation {
                                duration: Appearance.animation.elementMoveFast.duration
                                easing.type: Appearance.animation.elementMoveFast.type
                                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
                            }
                        }
                    }

                }
                
            }

        }

        Item {
            id: content
            Layout.fillWidth: true
            implicitHeight: collapsed ? 0 : contentBackground.implicitHeight + thinkBlockComponentSpacing
            height: implicitHeight
            clip: true

            Behavior on implicitHeight {
                enabled: root.__animateCollapseNow
                NumberAnimation {
                    duration: collapseAnimation.duration
                    easing.type: collapseAnimation.type
                    easing.bezierCurve: collapseAnimation.bezierCurve
                }
            }

            Rectangle {
                id: contentBackground
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                implicitHeight: contentColumnInner.implicitHeight
                color: Appearance.colors.colLayer2
                topLeftRadius: 0
                topRightRadius: 0
                bottomLeftRadius: thinkBlockBackgroundRounding
                bottomRightRadius: thinkBlockBackgroundRounding

                // Load data for the message at the correct scope
                property bool editing: root.editing
                property bool renderMarkdown: root.renderMarkdown
                property bool enableMouseSelection: root.enableMouseSelection
                property var messageData: root.messageData
                property bool done: root.done

                ColumnLayout {
                    id: contentColumnInner
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 8

                    MessageTextBlock {
                        id: messageTextBlock
                        Layout.fillWidth: true
                        segmentContent: root.segmentContent
                    }

                    // Nested tool calls within think block
                    Repeater {
                        model: ScriptModel {
                            values: root.toolCalls ?? []
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
            }
        }
    }
}
