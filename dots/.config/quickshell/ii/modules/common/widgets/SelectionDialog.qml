import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell

Item {
    id: root
    property real dialogPadding: 15
    property real dialogMargin: 30
    property string titleText: "Selection Dialog"
    // Accept either list<string> or list<object>.
    // Object shape (recommended):
    // { displayName: string, value: string, searchText?: string }
    // Backward compatible: plain strings.
    property var items: []
    property bool searchable: false
    property string searchPlaceholderText: Translation.tr("Search")
    property string query: ""

    // Internal normalized items: [{ displayName, value, searchText }]
    property var _normalizedItems: []
    property var _filteredItems: []
    property int selectedId: choiceListView.currentIndex
    property var defaultChoice

    signal canceled();
    signal selected(var result);

    function _normalizeItem(it) {
        if (it === null || it === undefined) return null;
        if (typeof it === "string") {
            const s = it;
            return { displayName: s, value: s, searchText: s };
        }
        if (typeof it === "object") {
            const displayName = (it.displayName ?? it.label ?? it.name ?? it.value ?? "").toString();
            const value = (it.value ?? it.code ?? it.id ?? displayName).toString();
            const searchText = (it.searchText ?? it.searchKey ?? `${displayName} ${value}`).toString();
            return { displayName, value, searchText };
        }
        const fallback = it.toString();
        return { displayName: fallback, value: fallback, searchText: fallback };
    }

    function _rebuildModel() {
        const raw = root.items ?? [];
        const normalized = [];
        for (let i = 0; i < raw.length; i++) {
            const n = root._normalizeItem(raw[i]);
            if (n && (n.displayName?.length ?? 0) > 0) normalized.push(n);
        }
        root._normalizedItems = normalized;
        root._applyFilterAndSelection();
    }

    function _applyFilterAndSelection() {
        const q = (root.query ?? "").trim().toLowerCase();
        const base = root._normalizedItems ?? [];
        if (q.length === 0) {
            root._filteredItems = base;
        } else {
            root._filteredItems = base.filter(it => {
                const hay = ((it.searchText ?? "") + " " + (it.displayName ?? "") + " " + (it.value ?? "")).toLowerCase();
                return hay.includes(q);
            });
        }
        choiceModel.values = root._filteredItems;

        // Set initial selection (best-effort) when defaultChoice is provided.
        const d = root.defaultChoice;
        if (d !== undefined && d !== null) {
            const dv = d.toString();
            const idx = root._filteredItems.findIndex(it => it.value === dv || it.displayName === dv);
            if (idx >= 0) choiceListView.currentIndex = idx;
        }
    }

    onItemsChanged: root._rebuildModel()
    onDefaultChoiceChanged: root._applyFilterAndSelection()
    onQueryChanged: root._applyFilterAndSelection()
    Component.onCompleted: root._rebuildModel()

    Rectangle { // Scrim
        id: scrimOverlay
        anchors.fill: parent
        radius: Appearance.rounding.small
        color: Appearance.colors.colScrim
        MouseArea {
            hoverEnabled: true
            anchors.fill: parent
            preventStealing: true
            propagateComposedEvents: false
        }
    }

    Rectangle { // The dialog
        id: dialog
        color: Appearance.m3colors.m3surfaceContainerHigh
        radius: Appearance.rounding.normal
        anchors.fill: parent
        anchors.margins: dialogMargin
        implicitHeight: dialogColumnLayout.implicitHeight
        
        ColumnLayout {
            id: dialogColumnLayout
            anchors.fill: parent
            spacing: 16

            StyledText {
                id: dialogTitle
                Layout.topMargin: dialogPadding
                Layout.leftMargin: dialogPadding
                Layout.rightMargin: dialogPadding
                Layout.alignment: Qt.AlignLeft
                color: Appearance.m3colors.m3onSurface
                font.pixelSize: Appearance.font.pixelSize.larger
                text: root.titleText
            }

            Rectangle {
                color: Appearance.m3colors.m3outline
                implicitHeight: 1
                Layout.fillWidth: true
                Layout.leftMargin: dialogPadding
                Layout.rightMargin: dialogPadding
            }

            MaterialTextField {
                id: searchField
                visible: root.searchable
                Layout.leftMargin: dialogPadding
                Layout.rightMargin: dialogPadding
                Layout.fillWidth: true
                placeholderText: root.searchPlaceholderText
                text: root.query
                onTextChanged: root.query = text
            }

            StyledListView {
                id: choiceListView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 6

                model: ScriptModel {
                    id: choiceModel
                }

                delegate: StyledRadioButton {
                    id: radioButton
                    required property var modelData
                    required property int index
                    anchors {
                        left: parent?.left
                        right: parent?.right
                        leftMargin: root.dialogPadding
                        rightMargin: root.dialogPadding
                    }

                    description: modelData.displayName
                    checked: index === choiceListView.currentIndex

                    onCheckedChanged: {
                        if (checked) {
                            choiceListView.currentIndex = index;
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
                id: dialogButtonsRowLayout
                Layout.bottomMargin: dialogPadding
                Layout.leftMargin: dialogPadding
                Layout.rightMargin: dialogPadding
                Layout.alignment: Qt.AlignRight

                DialogButton {
                    buttonText: Translation.tr("Cancel")
                    onClicked: root.canceled()
                }
                DialogButton {
                    buttonText: Translation.tr("OK")
                    onClicked: root.selected(
                        root.selectedId === -1 ? null :
                        choiceModel.values[root.selectedId]?.value ?? null
                    )
                }
            }
        }
    }
}
