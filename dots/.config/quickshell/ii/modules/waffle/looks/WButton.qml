import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.functions
import qs.modules.waffle.looks

// Generic button with background
Button {
    id: root

    property color colBackgroundHover: Looks.colors.bg2Hover
    property color colBackgroundActive: Looks.colors.bg2Active
    property color colBackgroundToggled: Looks.colors.accent
    property color colBackgroundToggledHover: Looks.colors.accentHover
    property color colBackgroundToggledActive: Looks.colors.accentActive
    property color colForeground: Looks.colors.fg
    property color colForegroundToggled: Looks.colors.accentFg
    property color colForegroundDisabled: ColorUtils.transparentize(Looks.colors.subfg, 0.4)
    property alias backgroundOpacity: backgroundRect.opacity
    property color color: {
        if (!root.enabled) return colBackground;
        if (root.checked) {
            if (root.down) {
                return root.colBackgroundToggledActive;
            } else if (root.hovered) {
                return root.colBackgroundToggledHover;
            } else {
                return root.colBackgroundToggled;
            }
        }
        if (root.down) {
            return root.colBackgroundActive;
        } else if (root.hovered) {
            return root.colBackgroundHover;
        } else {
            return root.colBackground;
        }
    }
    property color fgColor: {
        if (!root.enabled) return root.colForegroundDisabled
        if (root.checked) return root.colForegroundToggled
        if (root.enabled) return root.colForeground
        return root.colForeground
    }
    property alias horizontalAlignment: buttonText.horizontalAlignment
    font {
        family: Looks.font.family.ui
        pixelSize: Looks.font.pixelSize.large
        weight: Looks.font.weight.regular
    }

    // Hover stuff
    signal hoverTimedOut
    property bool shouldShowTooltip: false
    ToolTip.delay: 400
    property Timer hoverTimer: Timer {
        id: hoverTimer
        running: root.hovered
        interval: root.ToolTip.delay
        onTriggered: {
            root.hoverTimedOut();
        }
    }
    onHoverTimedOut: {
        root.shouldShowTooltip = true;
    }
    onHoveredChanged: {
        if (!root.hovered) {
            root.shouldShowTooltip = false;
            root.hoverTimer.stop();
        }
    }

    property alias monochromeIcon: buttonIcon.monochrome
    property bool forceShowIcon: false

    property var altAction: () => {}
    property var middleClickAction: () => {}

    property real inset: 2
    topInset: inset
    bottomInset: inset
    leftInset: inset
    rightInset: inset
    horizontalPadding: 10
    verticalPadding: 6
    implicitHeight: contentItem.implicitHeight + verticalPadding * 2
    implicitWidth: contentItem.implicitWidth + horizontalPadding * 2

    background: Rectangle {
        radius: Looks.radius.medium
        color: {
            if (root.down) {
                return root.colBackgroundActive;
            } else if ((root.hovered && !root.down) || root.checked) {
                return root.colBackgroundHover;
            } else {
                return root.colBackground;
            }
        }
        Behavior on color {
            animation: Looks.transition.color.createObject(this)
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton | Qt.MiddleButton
        onClicked: (event) => {
            if (event.button === Qt.LeftButton) root.clicked();
            if (event.button === Qt.RightButton) root.altAction();
            if (event.button === Qt.MiddleButton) root.middleClickAction();
        }
    }

    contentItem: Item {
        anchors {
            fill: parent
            margins: root.inset
        }
        implicitWidth: contentLayout.implicitWidth
        implicitHeight: contentLayout.implicitHeight
        RowLayout {
            id: contentLayout
            anchors {
                fill: parent
                leftMargin: root.horizontalPadding
                rightMargin: root.horizontalPadding
            }
            spacing: 12
            FluentIcon {
                id: buttonIcon
                visible: root.icon.name !== "" || root.forceShowIcon
                monochrome: true
                implicitSize: 16
                Layout.leftMargin: 6
                Layout.fillWidth: false
                Layout.alignment: Qt.AlignVCenter
                icon: root.icon.name
            }
            WText {
                Layout.rightMargin: 12
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter | Qt.AlignLeft
                text: root.text
                horizontalAlignment: Text.AlignLeft
                font {
                    pixelSize: Looks.font.pixelSize.large
                }
            }
        }
    }
}
