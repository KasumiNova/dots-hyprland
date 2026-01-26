import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

Rectangle {
    id: root

    property bool show: false
    default property alias data: contentColumn.data
    // Natural dialog height (content-driven). This must not depend on dialogBackground.implicitHeight,
    // otherwise hiding (implicitHeight=0) would collapse the remembered height and break show animation.
    property real backgroundHeight: contentColumn.implicitHeight + dialogBackground.radius * 2
    property real backgroundWidth: 350
    property real backgroundAnimationMovementDistance: 60

    // When shown, the dialog should be able to take focus so key events (e.g. Esc)
    // won't unexpectedly bubble into the background UI.
    focus: root.show
    activeFocusOnTab: root.show
    
    signal dismiss()
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            root.dismiss();
            event.accepted = true;
        }
    }

    color: root.show ? Appearance.colors.colScrim : ColorUtils.transparentize(Appearance.colors.colScrim)
    Behavior on color {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }
    // Keep visible while animating closed (implicitHeight > 0) to allow the closing animation to finish.
    // But when initially created with show=false, implicitHeight should be 0 to avoid covering the UI.
    visible: root.show || dialogBackground.implicitHeight > 0

    onShowChanged: {
        dialogBackgroundHeightAnimation.easing.bezierCurve = (show ? Appearance.animationCurves.emphasizedDecel : Appearance.animationCurves.emphasizedAccel)
        dialogBackground.implicitHeight = show ? backgroundHeight : 0
    }

    // If the content height changes while open, keep the dialog sized to it.
    onBackgroundHeightChanged: {
        if (root.show) dialogBackground.implicitHeight = backgroundHeight
    }

    radius: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1

    MouseArea { // Clicking outside the dialog should dismiss
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onPressed: root.dismiss()
    }

    Rectangle {
        id: dialogBackground
        anchors.horizontalCenter: parent.horizontalCenter
        radius: Appearance.rounding.large
        color: Appearance.m3colors.m3surfaceContainerHigh // Use opaque version of layer3
        
        property real targetY: root.height / 2 - root.backgroundHeight / 2
        y: root.show ? targetY : (targetY - root.backgroundAnimationMovementDistance)
        implicitWidth: root.backgroundWidth
        // Drive the height by show/animation logic; do not bind to content height directly.
        implicitHeight: 0
        Behavior on implicitHeight {
            NumberAnimation {
                id: dialogBackgroundHeightAnimation
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
            }
        }
        Behavior on y {
            NumberAnimation {
                duration: dialogBackgroundHeightAnimation.duration
                easing.type: dialogBackgroundHeightAnimation.easing.type
                easing.bezierCurve: dialogBackgroundHeightAnimation.easing.bezierCurve
            }
        }

        MouseArea { // So clicking inside the dialog won't dismiss
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
        }

        ColumnLayout {
            id: contentColumn
            anchors {
                fill: parent
                margins: dialogBackground.radius
            }
            spacing: 16
            opacity: root.show ? 1 : 0
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

        }
    }

    Component.onCompleted: {
        // Ensure we start hidden without covering the UI when show is initially false.
        dialogBackground.implicitHeight = root.show ? root.backgroundHeight : 0;
    }
}
