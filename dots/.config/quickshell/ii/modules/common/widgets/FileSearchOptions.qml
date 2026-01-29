pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

Item {
    id: root

    readonly property string filesPrefix: Config.options.search.prefix.files
    readonly property bool active: LauncherSearch.query.startsWith(filesPrefix)
    visible: active

    function _pushUniqueList(key, value) {
        const v = String(value ?? "").trim();
        if (!v.length) return;
        const current = (Config.options.search.files[key] ?? []).slice?.() ?? [];
        if (current.includes(v)) return;
        Config.options.search.files[key] = current.concat([v]);
    }

    function _removeFromList(key, value) {
        const v = String(value ?? "").trim();
        const current = (Config.options.search.files[key] ?? []).slice?.() ?? [];
        Config.options.search.files[key] = current.filter(x => x !== v);
    }

    implicitWidth: columnLayout.implicitWidth
    implicitHeight: columnLayout.implicitHeight

    ColumnLayout {
        id: columnLayout
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 8

        // Mode toggles
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            StyledText {
                text: Translation.tr("Files")
                color: Appearance.colors.colOnSurfaceVariant
                font.pixelSize: Appearance.font.pixelSize.small
            }

            Item { Layout.fillWidth: true }

            // Backend
            SelectionGroupButton {
                buttonText: "plocate"
                toggled: Config.options.search.files.backend === "plocate"
                onClicked: {
                    Config.options.search.files.backend = "plocate";
                    LauncherSearch.refreshFileSearch();
                }
            }
            SelectionGroupButton {
                buttonText: "baloo"
                toggled: Config.options.search.files.backend === "baloo"
                onClicked: {
                    Config.options.search.files.backend = "baloo";
                    LauncherSearch.refreshFileSearch();
                }
            }

            Rectangle { width: 1; height: 24; color: Appearance.colors.colOutlineVariant }

            // Scope
            SelectionGroupButton {
                buttonText: Translation.tr("Path")
                toggled: Config.options.search.files.defaultScope === "path"
                onClicked: {
                    Config.options.search.files.defaultScope = "path";
                    LauncherSearch.refreshFileSearch();
                }
            }
            SelectionGroupButton {
                buttonText: Translation.tr("Name")
                toggled: Config.options.search.files.defaultScope === "name"
                onClicked: {
                    Config.options.search.files.defaultScope = "name";
                    LauncherSearch.refreshFileSearch();
                }
            }

            Rectangle { width: 1; height: 24; color: Appearance.colors.colOutlineVariant }

            // Type
            SelectionGroupButton {
                buttonText: Translation.tr("Any")
                toggled: Config.options.search.files.defaultType === "any"
                onClicked: {
                    Config.options.search.files.defaultType = "any";
                    LauncherSearch.refreshFileSearch();
                }
            }
            SelectionGroupButton {
                buttonText: Translation.tr("File")
                toggled: Config.options.search.files.defaultType === "file"
                onClicked: {
                    Config.options.search.files.defaultType = "file";
                    LauncherSearch.refreshFileSearch();
                }
            }
            SelectionGroupButton {
                buttonText: Translation.tr("Folder")
                toggled: Config.options.search.files.defaultType === "dir"
                onClicked: {
                    Config.options.search.files.defaultType = "dir";
                    LauncherSearch.refreshFileSearch();
                }
            }
        }

        // Path filters
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialTextField {
                id: includeField
                Layout.fillWidth: true
                placeholderText: Translation.tr("Include path prefix")
                onAccepted: {
                    root._pushUniqueList("includePaths", text)
                    text = ""
                    LauncherSearch.refreshFileSearch();
                }
            }
            GroupButton {
                buttonText: Translation.tr("Add")
                onClicked: {
                    root._pushUniqueList("includePaths", includeField.text)
                    includeField.text = ""
                    LauncherSearch.refreshFileSearch();
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialTextField {
                id: excludeField
                Layout.fillWidth: true
                placeholderText: Translation.tr("Exclude path prefix")
                onAccepted: {
                    root._pushUniqueList("excludePaths", text)
                    text = ""
                    LauncherSearch.refreshFileSearch();
                }
            }
            GroupButton {
                buttonText: Translation.tr("Add")
                onClicked: {
                    root._pushUniqueList("excludePaths", excludeField.text)
                    excludeField.text = ""
                    LauncherSearch.refreshFileSearch();
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: Config.options.search.files.includePaths
                delegate: RippleButtonWithIcon {
                    required property var modelData
                    materialIcon: "close"
                    mainText: `in:${modelData}`
                    onClicked: {
                        root._removeFromList("includePaths", modelData);
                        LauncherSearch.refreshFileSearch();
                    }
                }
            }
            Repeater {
                model: Config.options.search.files.excludePaths
                delegate: RippleButtonWithIcon {
                    required property var modelData
                    materialIcon: "close"
                    mainText: `notin:${modelData}`
                    onClicked: {
                        root._removeFromList("excludePaths", modelData);
                        LauncherSearch.refreshFileSearch();
                    }
                }
            }
        }
    }
}
