import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window

Item {
    id: root
    required property var scopeRoot
    property int sidebarPadding: 10
    anchors.fill: parent
    // Provided by `SidebarLeft.qml` on the content parent (sidebarLeftBackground)
    readonly property real outputScale: (parent?.monitorScale ?? 1)
    property bool aiChatEnabled: Config.options.policies.ai !== 0
    property bool translatorEnabled: Config.options.sidebar.translator.enable
    property bool animeEnabled: Config.options.policies.weeb !== 0
    property bool animeCloset: Config.options.policies.weeb === 2

    // Keep tabs and pages in sync. Do not insert "invisible" pages in between;
    // SwipeView indexes must correspond 1:1 with ToolbarTabBar indexes.
    property var tabDefs: [
        ...(root.aiChatEnabled ? [{"key": "ai", "icon": "neurology", "name": Translation.tr("Intelligence")}] : []),
        ...(root.translatorEnabled ? [{"key": "translator", "icon": "translate", "name": Translation.tr("Translator")}] : []),
        ...((root.animeEnabled && !root.animeCloset) ? [{"key": "anime", "icon": "bookmark_heart", "name": Translation.tr("Anime")}] : [])
    ]
    property var tabButtonList: (root.tabDefs ?? []).map(d => ({"icon": d.icon, "name": d.name}))
    property int tabCount: (root.tabDefs?.length ?? 0)

    function focusActiveItem() {
        swipeView.currentItem.forceActiveFocus()
    }

    function _applyRequestedTab() {
        const key = (GlobalStates.sidebarLeftRequestedTab ?? "").trim();
        if (key.length === 0) return;
        const idx = (root.tabDefs ?? []).findIndex(d => d?.key === key);
        if (idx >= 0) {
            // Only set TabBar; SwipeView follows via binding (swipeView.currentIndex: tabBar.currentIndex)
            tabBar.setCurrentIndex(idx);
            Qt.callLater(() => {
                try { root.focusActiveItem(); } catch (e) {}
            });
            GlobalStates.sidebarLeftRequestedTab = "";
        }
    }

    Keys.onPressed: (event) => {
        if (event.modifiers === Qt.ControlModifier) {
            if (event.key === Qt.Key_PageDown) {
                swipeView.incrementCurrentIndex()
                event.accepted = true;
            }
            else if (event.key === Qt.Key_PageUp) {
                swipeView.decrementCurrentIndex()
                event.accepted = true;
            }
        }
    }

    Connections {
        target: GlobalStates
        function onSidebarLeftOpenChanged() {
            if (GlobalStates.sidebarLeftOpen) root._applyRequestedTab();
        }
        function onSidebarLeftRequestedTabChanged() {
            if (GlobalStates.sidebarLeftOpen) root._applyRequestedTab();
        }
    }

    ColumnLayout {
        anchors {
            fill: parent
            margins: sidebarPadding
        }
        spacing: sidebarPadding

        Toolbar {
            visible: tabButtonList.length > 0
            Layout.alignment: Qt.AlignHCenter
            enableShadow: false
            ToolbarTabBar {
                id: tabBar
                Layout.alignment: Qt.AlignHCenter
                tabButtonList: root.tabButtonList
                currentIndex: swipeView.currentIndex
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitWidth: swipeView.implicitWidth
            implicitHeight: swipeView.implicitHeight
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1

            SwipeView { // Content pages
                id: swipeView
                anchors.fill: parent
                // Add margins to keep content away from rounded corners
                anchors.margins: Appearance.rounding.small / 2
                spacing: 10
                currentIndex: tabBar.currentIndex

                visible: (root.tabDefs?.length ?? 0) > 0

                clip: true
                // layer disabled to fix fractional scaling blur
                layer.enabled: false

                Repeater {
                    model: root.tabDefs ?? []
                    delegate: Loader {
                        required property var modelData
                        active: true
                        visible: true
                        sourceComponent: {
                            const k = modelData?.key;
                            if (k === "ai") return aiChatPage;
                            if (k === "translator") return translatorPage;
                            if (k === "anime") return animePage;
                            return placeholderPage;
                        }
                    }
                }
            }

            // Placeholder when no tabs are enabled.
            Loader {
                anchors.fill: parent
                active: (root.tabDefs?.length ?? 0) === 0
                visible: active
                sourceComponent: placeholderPage
            }
        }
    }

    // Page components (referenced by SwipeView delegates)
    Component {
        id: aiChatPage
        AiChat {
            outputScale: root.outputScale
            dialogOverlayParent: root
        }
    }

    Component {
        id: translatorPage
        Translator {}
    }

    Component {
        id: animePage
        Anime {}
    }

    Component {
        id: placeholderPage
        Item {
            StyledText {
                anchors.centerIn: parent
                text: root.animeCloset ? Translation.tr("Nothing") : Translation.tr("Enjoy your empty sidebar...")
                color: Appearance.colors.colSubtext
            }
        }
    }
}