import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

Item {
    id: root
    readonly property HyprlandMonitor monitor: Hyprland.monitorFor(root.QsWindow.window?.screen)
    readonly property Toplevel activeWindow: ToplevelManager.activeToplevel

    property string activeWindowAddress: `0x${activeWindow?.HyprlandToplevel?.address}`
    property bool focusingThisMonitor: HyprlandData.activeWorkspace?.monitor == monitor?.name
    property var biggestWindow: HyprlandData.biggestWindowForWorkspace(HyprlandData.monitors[root.monitor?.id]?.activeWorkspace.id)

    // Prevent long titles from bleeding into neighboring bar sections.
    clip: true
    // Avoid a huge implicitWidth based on title length influencing parent layout sizing.
    implicitWidth: 0

    ColumnLayout {
        id: colLayout

        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: -4

        StyledText {
            Layout.fillWidth: true
            Layout.maximumWidth: colLayout.width
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            text: root.focusingThisMonitor && root.activeWindow?.activated && root.biggestWindow ? 
                root.activeWindow?.appId :
                (root.biggestWindow?.class) ?? Translation.tr("Desktop")

        }

        StyledText {
            Layout.fillWidth: true
            Layout.maximumWidth: colLayout.width
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer0
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            text: root.focusingThisMonitor && root.activeWindow?.activated && root.biggestWindow ? 
                root.activeWindow?.title :
                (root.biggestWindow?.title) ?? `${Translation.tr("Workspace")} ${monitor?.activeWorkspace?.id ?? 1}`
        }

    }

}
