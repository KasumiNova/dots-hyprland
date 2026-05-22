import qs.modules.common
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Controls.Material
import QtQuick.Layouts

Menu {
    id: menu
    required property Item editor

    popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
    margins: 0
    verticalPadding: 4
    implicitWidth: Math.max(296, implicitContentWidth + leftPadding + rightPadding)

    Material.elevation: 0

    function materialIconName(iconName) {
        switch (iconName) {
        case "edit-undo": return "undo";
        case "edit-redo": return "redo";
        case "edit-cut": return "content_cut";
        case "edit-copy": return "content_copy";
        case "edit-paste": return "content_paste";
        case "edit-delete": return "delete";
        case "edit-select-all": return "select_all";
        default: return iconName;
        }
    }

    delegate: MenuItem {
        id: item

        implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                                implicitContentWidth + leftPadding + rightPadding)
        implicitHeight: 44
        padding: 12
        spacing: 12

        icon.width: 22
        icon.height: 22

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            cursorShape: item.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        }

        contentItem: RowLayout {
            spacing: item.spacing

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: item.icon.width
                horizontalAlignment: Text.AlignHCenter
                iconSize: item.icon.width
                text: menu.materialIconName(item.icon.name)
                color: item.enabled ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
            }

            StyledText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: item.text
                font.family: Appearance.font.family.main
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: item.enabled ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
                elide: Text.ElideRight
            }
        }

        background: Rectangle {
            radius: Math.max(0, Appearance.rounding.windowRounding - menu.verticalPadding)
            color: item.highlighted ? Appearance.colors.colLayer0Hover : "transparent"
        }
    }

    background: Rectangle {
        implicitWidth: 296
        implicitHeight: 44
        color: Appearance.colors.colLayer0Base
        radius: Appearance.rounding.windowRounding
        border.width: 1
        border.color: Appearance.colors.colLayer0Border
        clip: true

        StyledRectangularShadow {
            target: parent
        }
    }

    UndoAction {
        editor: menu.editor
    }
    RedoAction {
        editor: menu.editor
    }

    MenuSeparator {}

    CutAction {
        editor: menu.editor
    }
    CopyAction {
        editor: menu.editor
    }
    PasteAction {
        editor: menu.editor
    }
    DeleteAction {
        editor: menu.editor
    }

    MenuSeparator {}

    SelectAllAction {
        editor: menu.editor
    }
}
