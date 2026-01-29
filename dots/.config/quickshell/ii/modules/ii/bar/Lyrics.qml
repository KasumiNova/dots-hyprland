import QtQuick
import QtQuick.Layouts

import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services

Item {
    id: root

    readonly property bool enabled: (Config.options?.bar?.lyrics?.enable ?? false)
    readonly property int maxChars: (Config.options?.bar?.lyrics?.maxChars ?? 40)
    readonly property int targetWidth: (Config.options?.bar?.lyrics?.width ?? 260)
    readonly property bool animate: (Config.options?.bar?.lyrics?.animate ?? true)
    readonly property bool showTranslation: (Config.options?.bar?.lyrics?.showTranslation ?? true)
    readonly property int horizontalPadding: 6

    implicitWidth: targetWidth
    implicitHeight: Appearance.sizes.baseBarHeight

    function _truncate(str) {
        const s = (str ?? "").toString();
        const limit = Math.max(0, root.maxChars);
        if (limit <= 0) return "";
        if (s.length <= limit) return s;
        return s.slice(0, Math.max(0, limit - 1)) + "…";
    }

    readonly property string mainText: _truncate(SPlayerLyrics.main)
    readonly property string translationText: _truncate(SPlayerLyrics.translation)

    readonly property bool waitingForLyrics: root.enabled && SPlayerLyrics.connected && root.mainText.length === 0
    readonly property bool disconnected: root.enabled && !SPlayerLyrics.connected

    readonly property string placeholderDisconnected: Translation.tr("No connection")
    readonly property string placeholderWaiting: "· · ·"

    // Computed scroll progress for the main line (for translation line to follow).
    readonly property real mainScrollProgress: {
        const a = 0.15;  // syncScrollStartAt
        const b = 0.95;  // syncScrollEndAt
        const fp = Number(SPlayerLyrics.lineProgress ?? -1);
        if (fp < 0) return -1;
        if (b - a <= 0.0001) return Math.max(0, Math.min(1, fp));
        return Math.max(0, Math.min(1, (fp - a) / (b - a)));
    }

    readonly property string mainDisplayText: root.mainText.length > 0
        ? root.mainText
        : (root.waitingForLyrics ? root.placeholderWaiting : (root.enabled ? root.placeholderDisconnected : ""))

    component MarqueeFillLine: Item {
        id: line

        required property string text
        // Optional karaoke segments: [{text,start,end,roman}]
        property var segments: []
        // Current playhead time in ms (for karaoke fill)
        property int playheadTimeMs: 0
        property int fontPixelSize: Appearance.font.pixelSize.small
        property color baseColor: Appearance.colors.colOnLayer0
        property color fillColor: Appearance.colors.colOnLayer0
        property bool useFill: true
        property bool useScroll: true
        property bool animateChange: true
        property real animationDistanceY: 4

        // Optional timing inputs (ms). If provided, use them to drive fill + scroll.
        // - externalFillProgress: 0..1, negative means "no external".
        property real externalFillProgress: -1
        // - externalScrollProgress: 0..1, when >= 0, directly drives scroll position (for translation sync).
        property real externalScrollProgress: -1
        property int dwellMs: 0
        // Adaptive animation duration based on API update interval.
        property int fillAnimDurationMs: 150
        // When true, use faster initial animation (for line transitions).
        property bool isTransition: false

        // When true, the marquee position is driven by fillProgress instead of an independent loop.
        // This makes long lyrics "reveal" and scroll in sync with the line timing.
        property bool syncScrollToFill: false
        // Fill progress range where scrolling happens (0..1). Keeps the beginning/end calmer.
        property real syncScrollStartAt: 0.15
        property real syncScrollEndAt: 0.95

        // px/s (may be recomputed from dwellMs)
        property real scrollSpeed: 55
        property int scrollStartDelayMs: 700
        property int scrollEndPauseMs: 600

        // Extra slack so the last glyph doesn't get visually cut off at the end.
        property int scrollEndSlackPx: 10

        // When true, center the text horizontally (for placeholders).
        property bool centerText: false

        clip: true
        implicitHeight: baseText.implicitHeight

        TextMetrics {
            id: metrics
            text: line.text
            font {
                family: Appearance.font.family.main
                pixelSize: line.fontPixelSize
                hintingPreference: Font.PreferDefaultHinting
                variableAxes: Appearance.font.variableAxes.main
            }
        }

        readonly property real naturalWidth: {
            const tr = metrics.tightBoundingRect;
            const br = metrics.boundingRect;
            const w = (tr && tr.width > 0) ? tr.width : ((br && br.width > 0) ? br.width : metrics.width);
            return Math.ceil(w);
        }
        readonly property real contentWidthWithSlack: line.naturalWidth + line.scrollEndSlackPx
        readonly property real maxScrollX: Math.max(0, line.contentWidthWithSlack - flick.width)
        readonly property bool shouldScroll: line.useScroll && line.maxScrollX > 1 && (line.dwellMs <= 0 || line.dwellMs >= 1800)

        property real fillProgress: 1

        // Karaoke: measured width for the filled prefix when segments exist.
        property string _karaokeFillText: ""

        function _clamp01(v) {
            return Math.max(0, Math.min(1, v));
        }

        function _scrollProgressFromFill(fp) {
            const a = Math.max(0, Math.min(1, line.syncScrollStartAt));
            const b = Math.max(a, Math.min(1, line.syncScrollEndAt));
            if (b - a <= 0.0001) return line._clamp01(fp);
            return line._clamp01((fp - a) / (b - a));
        }

        function _updateScrollFromFill() {
            if (!line.shouldScroll) return;
            // If we have external scroll progress, use it directly.
            if (line.externalScrollProgress >= 0) {
                flick.contentX = Math.round(line.maxScrollX * line._clamp01(line.externalScrollProgress));
                return;
            }
            if (!(line.syncScrollToFill && line.useFill)) return;
            flick.contentX = Math.round(line.maxScrollX * line._scrollProgressFromFill(line.fillProgress));
        }

        function _updateKaraokeFillText() {
            const segs = Array.isArray(line.segments) ? line.segments : [];
            if (!line.useFill || segs.length === 0) {
                line._karaokeFillText = "";
                return;
            }

            const t = line.playheadTimeMs;
            let out = "";
            for (let i = 0; i < segs.length; i++) {
                const s = segs[i];
                const txt = (s && typeof s.text === "string") ? s.text : "";
                const st = Number(s?.start ?? -1);
                const en = Number(s?.end ?? -1);
                if (!(st >= 0 && en > st)) {
                    // No timing: treat as not yet filled.
                    break;
                }

                if (t >= en) {
                    out += txt;
                    continue;
                }

                if (t <= st) {
                    break;
                }

                const p = (t - st) / (en - st);
                const clamped = Math.max(0, Math.min(1, p));
                const n = Math.max(0, Math.min(txt.length, Math.round(txt.length * clamped)));
                out += txt.slice(0, n);
                break;
            }

            line._karaokeFillText = out;
        }

        function restartAnimations() {
            // Fill
            if (line.externalFillProgress >= 0) {
                // External progress is already smooth (predicted locally), just follow it.
                fillAnim.stop();
                line.fillProgress = line._clamp01(line.externalFillProgress);
            } else if (line.useFill && line.text.length > 0) {
                line.fillProgress = 0;
                fillAnim.restart();
            } else {
                fillAnim.stop();
                line.fillProgress = 1;
            }

            // Scroll animation
            if (line.shouldScroll && line.externalScrollProgress < 0 && !(line.syncScrollToFill && line.useFill)) {
                // If we have a dwell time, try to traverse the full distance within it.
                if (line.dwellMs > 0) {
                    const secs = Math.max(0.8, line.dwellMs / 1000.0);
                    const targetSpeed = line.maxScrollX / (secs * 0.8);
                    line.scrollSpeed = Math.max(35, Math.min(160, targetSpeed));
                }
                scrollAnim.restart();
            } else {
                scrollAnim.stop();
                flick.contentX = 0;
            }

            // If synced, set initial scroll position.
            line._updateScrollFromFill();

            // Karaoke prefix.
            line._updateKaraokeFillText();
        }

        onTextChanged: Qt.callLater(line.restartAnimations)
        onWidthChanged: Qt.callLater(line.restartAnimations)

        // When driven by external progress (from the bridge), don't "step" each tick.
        // External progress is predicted locally, so we can follow it directly.
        onExternalFillProgressChanged: {
            if (line.externalFillProgress < 0) return;
            fillAnim.stop();
            line.fillProgress = line._clamp01(line.externalFillProgress);
            line._updateScrollFromFill();
            line._updateKaraokeFillText();
        }

        onExternalScrollProgressChanged: {
            if (line.externalScrollProgress < 0) return;
            scrollAnim.stop();
            line._updateScrollFromFill();
        }

        onFillProgressChanged: line._updateScrollFromFill()
        onPlayheadTimeMsChanged: line._updateKaraokeFillText()
        onSegmentsChanged: line._updateKaraokeFillText()

        NumberAnimation {
            id: fillAnim
            target: line
            property: "fillProgress"
            to: 1
            duration: 520
            easing.type: Easing.Linear
        }

        SequentialAnimation {
            id: scrollAnim
            loops: Animation.Infinite

            PauseAnimation { duration: line.scrollStartDelayMs }
            NumberAnimation {
                target: flick
                property: "contentX"
                from: 0
                to: line.maxScrollX
                duration: Math.max(1, Math.round((line.maxScrollX / Math.max(1, line.scrollSpeed)) * 1000))
                easing.type: Easing.InOutSine
            }
            PauseAnimation { duration: line.scrollEndPauseMs }
            NumberAnimation {
                target: flick
                property: "contentX"
                from: line.maxScrollX
                to: 0
                duration: Math.max(1, Math.round((line.maxScrollX / Math.max(1, line.scrollSpeed)) * 1000))
                easing.type: Easing.InOutSine
            }
            PauseAnimation { duration: 250 }
        }

        Flickable {
            id: flick
            anchors.fill: parent
            clip: true
            interactive: false
            boundsBehavior: Flickable.StopAtBounds
            contentHeight: height
            contentWidth: line.shouldScroll ? line.contentWidthWithSlack : width

            Item {
                id: content
                width: flick.contentWidth
                height: flick.height

                // Measures the filled prefix width for karaoke segments.
                TextMetrics {
                    id: fillMetrics
                    text: line._karaokeFillText
                    font {
                        family: Appearance.font.family.main
                        pixelSize: line.fontPixelSize
                        hintingPreference: Font.PreferDefaultHinting
                        variableAxes: Appearance.font.variableAxes.main
                    }
                }

                // Base text (optionally elided when not scrolling)
                StyledText {
                    id: baseText
                    anchors.left: line.centerText ? undefined : parent.left
                    anchors.horizontalCenter: line.centerText ? parent.horizontalCenter : undefined
                    anchors.verticalCenter: parent.verticalCenter
                    width: line.centerText ? implicitWidth : (line.shouldScroll ? line.contentWidthWithSlack : flick.width)
                    wrapMode: Text.NoWrap
                    elide: (line.shouldScroll || line.centerText) ? Text.ElideNone : Text.ElideRight
                    horizontalAlignment: line.centerText ? Text.AlignHCenter : Text.AlignLeft
                    text: line.text
                    font.pixelSize: line.fontPixelSize
                    color: line.baseColor
                    animateChange: line.animateChange && !line.shouldScroll
                    animationDistanceY: line.animationDistanceY
                }

                // Fill/reveal overlay (clipped)
                Item {
                    id: fillOverlay
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    readonly property real fillBaseWidth: line.shouldScroll ? line.naturalWidth : flick.width
                    readonly property real targetWidth: line.useFill
                        ? (Array.isArray(line.segments) && line.segments.length > 0
                            ? Math.max(0, fillMetrics.tightBoundingRect.width)
                            : (fillBaseWidth * line.fillProgress))
                        : 0
                    width: targetWidth
                    clip: true

                    // Smooth interpolation so fill doesn't "jump" between ticks.
                    // Duration adapts to API update interval for seamless transitions.
                    // On line transitions, use 3x faster animation to "catch up" quickly.
                    Behavior on width {
                        enabled: line.useFill && line.externalFillProgress >= 0
                        NumberAnimation {
                            duration: line.isTransition
                                ? Math.max(10, Math.round(line.fillAnimDurationMs / 3))
                                : Math.max(30, line.fillAnimDurationMs)
                            easing.type: line.isTransition ? Easing.OutQuad : Easing.Linear
                        }
                    }

                    StyledText {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: baseText.width
                        wrapMode: baseText.wrapMode
                        elide: baseText.elide
                        text: baseText.text
                        font.pixelSize: baseText.font.pixelSize
                        color: line.fillColor
                        animateChange: false
                    }
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: root.horizontalPadding
        anchors.rightMargin: root.horizontalPadding
        // Slightly less negative than ActiveWindow: makes the translation line sit lower.
        spacing: -2

        MarqueeFillLine {
            Layout.fillWidth: true
            fontPixelSize: Appearance.font.pixelSize.small
            baseColor: (root.mainText.length > 0 || SPlayerLyrics.connected)
                ? ColorUtils.applyAlpha(Appearance.colors.colOnLayer0, 0.25)
                : Appearance.colors.colSubtext
            fillColor: Appearance.colors.colOnLayer0
            useFill: root.animate && (root.mainText.length > 0)
            useScroll: (root.mainText.length > 0)
            syncScrollToFill: root.animate && (root.mainText.length > 0)
            animateChange: root.animate
            animationDistanceY: 4
            centerText: (root.mainText.length === 0)
            text: root.mainDisplayText
            dwellMs: (SPlayerLyrics.lineDuration ?? 0)
            externalFillProgress: (SPlayerLyrics.lineProgress ?? -1)
            fillAnimDurationMs: (SPlayerLyrics.updateIntervalMs ?? 150)
            isTransition: (SPlayerLyrics.isTransition ?? false)
            segments: (SPlayerLyrics.segments ?? [])
            playheadTimeMs: (SPlayerLyrics.time ?? 0)
        }

        // Translation line: sync scroll with main line, no fill.
        MarqueeFillLine {
            Layout.fillWidth: true
            fontPixelSize: Appearance.font.pixelSize.smaller
            baseColor: Appearance.colors.colSubtext
            fillColor: Appearance.colors.colSubtext
            useFill: false
            useScroll: root.translationText.length > 0
            externalScrollProgress: root.mainScrollProgress
            animateChange: root.animate
            animationDistanceY: 4

            visible: root.showTranslation && root.translationText.length > 0
            text: root.translationText
            dwellMs: (SPlayerLyrics.lineDuration ?? 0)
        }
    }
}
