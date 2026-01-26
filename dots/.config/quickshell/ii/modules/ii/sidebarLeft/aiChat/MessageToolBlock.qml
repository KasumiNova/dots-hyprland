pragma ComponentBehavior: Bound

import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

/**
 * A compact block to represent tool/function calls in the chat.
 * Shows the function name, parameters, and result in a collapsible format.
 */
Item {
    id: root

    property var messageData: null
    property var toolCallData: null  // New: for parallel tool calls {id, name, args, status, result}
    
    // Derive properties from toolCallData if available, otherwise fall back to legacy messageData
    property string functionName: toolCallData?.name ?? messageData?.functionName ?? ""
    property var functionCall: toolCallData ? { id: toolCallData.id, name: toolCallData.name, args: toolCallData.args } : messageData?.functionCall ?? null
    property string functionResponse: toolCallData?.result?.output ?? (toolCallData?.result ? JSON.stringify(toolCallData.result) : "") ?? messageData?.functionResponse ?? ""
    property bool functionPending: toolCallData ? (toolCallData.status === "executing") : (messageData?.functionPending ?? false)
    property bool done: toolCallData ? (toolCallData.status === "completed") : (messageData?.done ?? true)

    property bool collapsed: true
    property bool userToggled: false

    property real blockPadding: 8
    property real blockRounding: Appearance.rounding.small

    // Prevent rapid toggling
    Timer {
        id: toggleCooldownTimer
        interval: 80
        repeat: false
    }

    function toggleCollapsed() {
        if (toggleCooldownTimer.running) return;
        toggleCooldownTimer.restart();
        root.userToggled = true;
        root.collapsed = !root.collapsed;
    }

    // Auto-collapse when done
    onDoneChanged: {
        if (root.done && !root.userToggled) {
            root.collapsed = true;
        }
    }

    Layout.fillWidth: true
    implicitHeight: collapsed ? header.implicitHeight : columnLayout.implicitHeight
    height: implicitHeight
    clip: true

    Behavior on implicitHeight {
        enabled: root.done
        NumberAnimation {
            duration: Appearance.animation.elementMoveFast.duration
            easing.type: Appearance.animation.elementMoveFast.type
            easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
        }
    }

    ColumnLayout {
        id: columnLayout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 0

        // Header bar
        Rectangle {
            id: header
            Layout.fillWidth: true
            implicitHeight: headerRow.implicitHeight + blockPadding * 2
            color: root.functionPending 
                ? ColorUtils.mix(Appearance.colors.colWarningContainer, Appearance.colors.colLayer2, 0.7)
                : Appearance.colors.colSurfaceContainerHighest
            radius: root.collapsed ? blockRounding : 0
            topLeftRadius: blockRounding
            topRightRadius: blockRounding
            bottomLeftRadius: root.collapsed ? blockRounding : 0
            bottomRightRadius: root.collapsed ? blockRounding : 0

            MouseArea {
                id: headerMouseArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: root.toggleCollapsed()
            }

            RowLayout {
                id: headerRow
                anchors.fill: parent
                anchors.margins: blockPadding
                spacing: 10

                // Left icon (normalized spacing/size across blocks)
                Item {
                    Layout.fillWidth: false
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 22
                    implicitHeight: 22

                    MaterialSymbol {
                        id: toolStateIcon
                        anchors.centerIn: parent
                        text: root.functionPending ? "hourglass_empty" :
                              root.functionResponse ? "check_circle" : "build"
                        iconSize: Appearance.font.pixelSize.normal
                        color: root.functionPending
                            ? Appearance.colors.colWarning
                            : Appearance.colors.colOnSurfaceVariant

                        // Spin animation for pending
                        RotationAnimator on rotation {
                            from: 0
                            to: 360
                            duration: 1500
                            loops: Animation.Infinite
                            running: root.functionPending
                        }
                    }
                }

                // Function name
                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: root.functionPending 
                        ? Translation.tr("Calling: %1...").arg(root.functionName)
                        : Translation.tr("Tool: %1").arg(root.functionName)
                    font.pixelSize: Appearance.font.pixelSize.small
                    font.weight: Font.Medium
                    color: Appearance.colors.colOnSurfaceVariant
                    elide: Text.ElideRight
                }

                // Expand button (match Think block style)
                RippleButton {
                    id: expandButton
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 22
                    implicitHeight: 22
                    colBackground: headerMouseArea.containsMouse ? Appearance.colors.colLayer2Hover
                        : ColorUtils.transparentize(Appearance.colors.colLayer2, 1)
                    colBackgroundHover: Appearance.colors.colLayer2Hover
                    colRipple: Appearance.colors.colLayer2Active

                    onClicked: root.toggleCollapsed()

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

        // Content area (parameters and response)
        Item {
            id: contentArea
            Layout.fillWidth: true
            implicitHeight: root.collapsed ? 0 : contentColumn.implicitHeight + blockPadding
            height: implicitHeight
            clip: true

            Behavior on implicitHeight {
                enabled: root.done
                NumberAnimation {
                    duration: Appearance.animation.elementMoveFast.duration
                    easing.type: Appearance.animation.elementMoveFast.type
                    easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
                }
            }

            Rectangle {
                anchors.fill: parent
                color: Appearance.colors.colLayer2
                topLeftRadius: 0
                topRightRadius: 0
                bottomLeftRadius: blockRounding
                bottomRightRadius: blockRounding

                ColumnLayout {
                    id: contentColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: blockPadding
                    spacing: 8

                    // Parameters section
                    Loader {
                        Layout.fillWidth: true
                        active: root.functionCall !== null && root.functionCall !== undefined
                        sourceComponent: ColumnLayout {
                            spacing: 4

                            StyledText {
                                text: Translation.tr("Parameters:")
                                font.pixelSize: Appearance.font.pixelSize.small
                                font.weight: Font.Medium
                                color: Appearance.colors.colSubtext
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: paramsText.implicitHeight + 12
                                color: Appearance.colors.colLayer1
                                radius: Appearance.rounding.small

                                StyledText {
                                    id: paramsText
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    text: {
                                        try {
                                            if (typeof root.functionCall === "string") {
                                                return root.functionCall;
                                            }
                                            return JSON.stringify(root.functionCall, null, 2);
                                        } catch (e) {
                                            return String(root.functionCall);
                                        }
                                    }
                                    font.family: "monospace"
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colOnLayer1
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }

                    // Response section
                    Loader {
                        Layout.fillWidth: true
                        active: root.functionResponse && root.functionResponse.length > 0
                        sourceComponent: ColumnLayout {
                            spacing: 4

                            StyledText {
                                text: Translation.tr("Result:")
                                font.pixelSize: Appearance.font.pixelSize.small
                                font.weight: Font.Medium
                                color: Appearance.colors.colSubtext
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: Math.min(responseText.implicitHeight + 12, 200)
                                color: Appearance.colors.colLayer1
                                radius: Appearance.rounding.small
                                clip: true

                                ScrollView {
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    clip: true

                                    StyledText {
                                        id: responseText
                                        width: parent.width
                                        text: root.functionResponse
                                        font.family: "monospace"
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.colors.colOnLayer1
                                        wrapMode: Text.Wrap
                                    }
                                }
                            }
                        }
                    }

                    // Loading indicator when pending
                    Loader {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignHCenter
                        active: root.functionPending
                        sourceComponent: RowLayout {
                            spacing: 8
                            MaterialLoadingIndicator {
                                loading: true
                                implicitWidth: 16
                                implicitHeight: 16
                            }
                            StyledText {
                                text: Translation.tr("Executing...")
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colSubtext
                            }
                        }
                    }
                }
            }
        }
    }
}
