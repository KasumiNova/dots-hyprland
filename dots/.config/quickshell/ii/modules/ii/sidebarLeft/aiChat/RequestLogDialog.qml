import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

Item {
    id: root

    // This dialog is meant to be used as an overlay (typically inside a Loader).
    // Ensure it always tracks the available panel size.
    anchors.fill: parent

    property real dialogPadding: 14
    property real dialogMargin: 18
    property var entries: Ai.requestLog

    signal closed()

    property var selectedEntry: null

    function formatTs(ts) {
        try {
            return Qt.formatDateTime(new Date(ts), "HH:mm:ss");
        } catch (_) {
            return "" + ts;
        }
    }

    Rectangle { // Scrim
        anchors.fill: parent
        radius: Appearance.rounding.small
        color: Appearance.colors.colScrim
        MouseArea {
            hoverEnabled: true
            anchors.fill: parent
            preventStealing: true
            propagateComposedEvents: false
            onClicked: root.closed()
        }
    }

    Rectangle { // Dialog
        id: dialog
        color: Appearance.m3colors.m3surfaceContainerHigh
        radius: Appearance.rounding.normal
        anchors.fill: parent
        anchors.margins: dialogMargin

        ColumnLayout {
            id: dialogColumnLayout
            anchors.fill: parent
            spacing: 10

            RowLayout {
                Layout.topMargin: dialogPadding
                Layout.leftMargin: dialogPadding
                Layout.rightMargin: dialogPadding
                spacing: 10

                MaterialSymbol {
                    text: root.selectedEntry ? "arrow_back" : "bug_report"
                    iconSize: Appearance.font.pixelSize.huge
                    color: Appearance.m3colors.m3onSurface
                    MouseArea {
                        anchors.fill: parent
                        enabled: !!root.selectedEntry
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectedEntry = null
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    font.pixelSize: Appearance.font.pixelSize.larger
                    color: Appearance.m3colors.m3onSurface
                    text: root.selectedEntry ? Translation.tr("Request details") : Translation.tr("Request log")
                    elide: Text.ElideRight
                }

                DialogButton {
                    visible: !root.selectedEntry
                    buttonText: Translation.tr("Clear")
                    onClicked: Ai.clearRequestLog()
                }

                DialogButton {
                    visible: !!root.selectedEntry
                    buttonText: Translation.tr("Copy")
                    onClicked: {
                        const text = root.selectedEntry?.payloadPretty ?? "";
                        Quickshell.clipboardText = text;
                    }
                }

                DialogButton {
                    buttonText: Translation.tr("Close")
                    onClicked: root.closed()
                }
            }

            Rectangle {
                color: Appearance.m3colors.m3outline
                implicitHeight: 1
                Layout.fillWidth: true
                Layout.leftMargin: dialogPadding
                Layout.rightMargin: dialogPadding
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // List view
                StyledListView {
                    id: listView
                    anchors.fill: parent
                    visible: !root.selectedEntry
                    clip: true
                    spacing: 8

                    model: ScriptModel {
                        values: (root.entries || []).slice().reverse()
                    }

                    delegate: Rectangle {
                        required property var modelData
                        required property int index

                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer2
                        border.width: 1
                        border.color: Appearance.colors.colOutlineVariant
                        anchors {
                            left: parent?.left
                            right: parent?.right
                            leftMargin: root.dialogPadding
                            rightMargin: root.dialogPadding
                        }
                        implicitHeight: contentLayout.implicitHeight + 12

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectedEntry = modelData
                        }

                        RowLayout {
                            id: contentLayout
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 12
                                rightMargin: 12
                            }
                            spacing: 10

                            MaterialSymbol {
                                text: "send"
                                iconSize: Appearance.font.pixelSize.huge
                                color: Appearance.colors.colSubtext
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                StyledText {
                                    Layout.fillWidth: true
                                    font.pixelSize: Appearance.font.pixelSize.normal
                                    color: Appearance.m3colors.m3onSurface
                                    text: `${root.formatTs(modelData.ts)}  ·  ${modelData.modelName ?? modelData.modelId ?? ""}`
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.colors.colSubtext
                                    text: `${modelData.apiFormat ?? ""}  ·  tool=${modelData.tool ?? ""}  ·  ${modelData.endpoint ?? ""}`
                                    elide: Text.ElideRight
                                }
                            }

                            MaterialSymbol {
                                text: "chevron_right"
                                iconSize: Appearance.font.pixelSize.huge
                                color: Appearance.colors.colSubtext
                            }
                        }
                    }
                }

                // Details
                ColumnLayout {
                    anchors.fill: parent
                    visible: !!root.selectedEntry

                    Rectangle {
                        Layout.leftMargin: root.dialogPadding
                        Layout.rightMargin: root.dialogPadding
                        Layout.fillWidth: true
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer2
                        border.width: 1
                        border.color: Appearance.colors.colOutlineVariant

                        implicitHeight: headerLayout.implicitHeight + 14

                        RowLayout {
                            id: headerLayout
                            anchors {
                                left: parent.left
                                right: parent.right
                                leftMargin: 12
                                rightMargin: 12
                                verticalCenter: parent.verticalCenter
                            }
                            spacing: 10

                            MaterialSymbol {
                                text: "info"
                                iconSize: Appearance.font.pixelSize.huge
                                color: Appearance.colors.colSubtext
                            }

                            StyledText {
                                Layout.fillWidth: true
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colSubtext
                                text: `${root.formatTs(root.selectedEntry?.ts ?? 0)}  ·  ${root.selectedEntry?.modelName ?? root.selectedEntry?.modelId ?? ""}`
                                elide: Text.ElideRight
                            }
                        }
                    }

                    ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.leftMargin: root.dialogPadding
                        Layout.rightMargin: root.dialogPadding
                        clip: true

                        background: Rectangle {
                            color: Appearance.colors.colLayer2
                            radius: Appearance.rounding.small
                            border.width: 1
                            border.color: Appearance.colors.colOutlineVariant
                        }

                        TextArea {
                            id: detailText
                            readOnly: true
                            wrapMode: TextEdit.NoWrap
                            selectByMouse: true
                            padding: 12
                            text: root.selectedEntry?.payloadPretty ?? ""
                            font.family: "monospace"
                            color: Appearance.m3colors.m3onSurface
                            background: null
                        }
                    }
                }
            }

            Rectangle {
                color: Appearance.m3colors.m3outline
                implicitHeight: 1
                Layout.fillWidth: true
                Layout.leftMargin: dialogPadding
                Layout.rightMargin: dialogPadding
            }

            RowLayout {
                Layout.bottomMargin: dialogPadding
                Layout.leftMargin: dialogPadding
                Layout.rightMargin: dialogPadding
                Layout.alignment: Qt.AlignRight

                DialogButton {
                    visible: !!root.selectedEntry
                    buttonText: Translation.tr("Back")
                    onClicked: root.selectedEntry = null
                }
            }
        }
    }
}
