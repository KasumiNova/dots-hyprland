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
    property var tabButtonList: [
        ...(root.aiChatEnabled ? [{"icon": "neurology", "name": Translation.tr("Intelligence")}] : []),
        ...(root.translatorEnabled ? [{"icon": "translate", "name": Translation.tr("Translator")}] : []),
        ...((root.animeEnabled && !root.animeCloset) ? [{"icon": "bookmark_heart", "name": Translation.tr("Anime")}] : [])
    ]
    property int tabCount: swipeView.count

    function focusActiveItem() {
        swipeView.currentItem.forceActiveFocus()
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

                clip: true
                // layer disabled to fix fractional scaling blur
                layer.enabled: false

                // Use Loader for better object lifecycle management.
                // Static Loaders avoid the createObject() re-creation issue on every binding update.
                Loader {
                    active: root.aiChatEnabled
                    visible: active
                    sourceComponent: Component {
                        AiChat {
                            outputScale: root.outputScale
                            dialogOverlayParent: root
                        }
                    }
                }
                Loader {
                    active: root.translatorEnabled
                    visible: active
                    sourceComponent: Component {
                        Translator {}
                    }
                }
                Loader {
                    active: root.tabButtonList.length === 0 || (!root.aiChatEnabled && !root.translatorEnabled && root.animeCloset)
                    visible: active
                    sourceComponent: Component {
                        Item {
                            StyledText {
                                anchors.centerIn: parent
                                text: root.animeCloset ? Translation.tr("Nothing") : Translation.tr("Enjoy your empty sidebar...")
                                color: Appearance.colors.colSubtext
                            }
                        }
                    }
                }
                Loader {
                    active: root.animeEnabled
                    visible: active
                    sourceComponent: Component {
                        Anime {}
                    }
                }
            }
        }
    }
}