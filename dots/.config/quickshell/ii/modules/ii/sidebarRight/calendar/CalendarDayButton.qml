import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

RippleButton {
    id: button
    property string day
    property string subLabel: ""
    property int isToday
    property bool bold
    property bool showSubLabel: false
    property bool highlightSubLabel: false
    property real cellScale: 1.0
    property real dayFontScale: 1.0
    property real subLabelFontScale: 1.0
    property int subLabelPixelSize: 11
    readonly property bool hasSubLabel: showSubLabel && subLabel.length > 0
    readonly property real pixelRatio: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    readonly property real snappedCornerRadius: Math.round(Math.max(1, Appearance.rounding.small * cellScale) * pixelRatio) / pixelRatio
    readonly property color dayTextColor: (isToday == 1) ? Appearance.m3colors.m3onPrimary :
        (isToday == 0) ? Appearance.colors.colOnLayer1 :
        Appearance.colors.colOutlineVariant

    Layout.fillWidth: false
    Layout.fillHeight: false
    implicitWidth: Math.max(1, Math.round(38 * cellScale))
    implicitHeight: Math.max(1, Math.round((hasSubLabel ? 42 : 38) * cellScale))

    toggled: (isToday == 1)
    buttonRadius: snappedCornerRadius
    rippleEnabled: false
    background.layer.enabled: false

    transform: Translate {
        x: Math.round(button.x * button.pixelRatio) / button.pixelRatio - button.x
        y: Math.round(button.y * button.pixelRatio) / button.pixelRatio - button.y
    }
    
    contentItem: Item {
        Column {
            anchors.centerIn: parent
            width: parent.width
            spacing: hasSubLabel ? -Math.max(1, Math.round(2 * cellScale)) : 0

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: day
                font.weight: bold ? Font.DemiBold : Font.Normal
                font.pixelSize: Math.max(1, Math.round(Appearance.font.pixelSize.smaller * dayFontScale))
                color: button.dayTextColor

                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }

            StyledText {
                width: parent.width
                visible: hasSubLabel
                horizontalAlignment: Text.AlignHCenter
                text: subLabel
                font.pixelSize: Math.max(1, Math.round(subLabelPixelSize))
                font.weight: highlightSubLabel ? Font.DemiBold : Font.Normal
                color: button.dayTextColor
                opacity: highlightSubLabel ? 0.95 : 0.72

                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }
        }
    }
}

