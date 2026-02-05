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

    // NOTE: Don't manually truncate here.
    // Long lines should scroll, not turn into an ellipsis.
    readonly property string mainText: ((SPlayerLyrics.main ?? "").toString())
    readonly property string translationText: ((SPlayerLyrics.translation ?? "").toString())

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

        readonly property real naturalWidth: Math.ceil(line._metricWidth(metrics))
        readonly property real contentWidthWithSlack: line.naturalWidth + line.scrollEndSlackPx
        readonly property real maxScrollX: Math.max(0, line.contentWidthWithSlack - flick.width)
        readonly property bool shouldScroll: line.useScroll && line.maxScrollX > 1 && (line.dwellMs <= 0 || line.dwellMs >= 1800)

        property real fillProgress: 1

        // Karaoke: computed state for continuous fill when segments exist.
        // - _karaokePrevText: fully-filled prefix text
        // - _karaokeActiveText: current segment full text (for partial fill)
        // - _karaokeActiveProgress: 0..1 progress within active segment
        // - _karaokeUsable: false when timing data is malformed (fallback to lineProgress fill)
        property string _karaokePrevText: ""
        property string _karaokeActiveText: ""
        property real _karaokeActiveProgress: 0
        property bool _karaokeUsable: false

        function _clamp01(v) {
            return Math.max(0, Math.min(1, v));
        }

        function _metricWidth(tm) {
            if (!tm) return 0;
            const tr = tm.tightBoundingRect;
            const br = tm.boundingRect;
            const a = (tr && tr.width > 0) ? tr.width : 0;
            const b = (br && br.width > 0) ? br.width : 0;
            const c = (tm.width > 0) ? tm.width : 0;
            return Math.max(a, b, c);
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

        function _updateKaraokeState() {
            const segs = Array.isArray(line.segments) ? line.segments : [];
            if (!line.useFill || segs.length === 0) {
                line._karaokePrevText = "";
                line._karaokeActiveText = "";
                line._karaokeActiveProgress = 0;
                line._karaokeUsable = false;
                return;
            }

            // Validate timing data. If malformed, fall back to lineProgress fill.
            let lastEnd = -1;
            for (let j = 0; j < segs.length; j++) {
                const ss = segs[j];
                const stt = Number((ss && ss.start != null) ? ss.start : -1);
                const enn = Number((ss && ss.end != null) ? ss.end : -1);
                if (!(stt >= 0 && enn > stt)) {
                    line._karaokePrevText = "";
                    line._karaokeActiveText = "";
                    line._karaokeActiveProgress = 0;
                    line._karaokeUsable = false;
                    return;
                }
                if (lastEnd >= 0 && stt < (lastEnd - 5)) {
                    line._karaokePrevText = "";
                    line._karaokeActiveText = "";
                    line._karaokeActiveProgress = 0;
                    line._karaokeUsable = false;
                    return;
                }
                lastEnd = enn;
            }
            line._karaokeUsable = true;

            const t = line.playheadTimeMs;
            let prev = "";
            let activeText = "";
            let activeP = 0;
            for (let i = 0; i < segs.length; i++) {
                const s = segs[i];
                const txt = (s && typeof s.text === "string") ? s.text : "";
                const st = Number((s && s.start != null) ? s.start : -1);
                const en = Number((s && s.end != null) ? s.end : -1);
                if (!(st >= 0 && en > st)) {
                    // No timing: treat as not yet filled.
                    break;
                }

                if (t >= en) {
                    prev += txt;
                    continue;
                }

                if (t <= st) {
                    activeText = txt;
                    activeP = 0;
                    break;
                }

                // Within this segment: fill continuously by clipping width.
                activeText = txt;
                activeP = Math.max(0, Math.min(1, (t - st) / (en - st)));

                // If this is the last segment, allow a tiny epsilon so we don't
                // get stuck at 99% when the playhead stops updating a few ms early.
                if (i === segs.length - 1 && (en - t) <= 45) {
                    activeP = 1;
                }
                break;
            }

            line._karaokePrevText = prev;
            line._karaokeActiveText = activeText;
            line._karaokeActiveProgress = activeP;
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

            // Karaoke state.
            line._updateKaraokeState();
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
            line._updateKaraokeState();
        }

        onExternalScrollProgressChanged: {
            if (line.externalScrollProgress < 0) return;
            scrollAnim.stop();
            line._updateScrollFromFill();
        }

        onFillProgressChanged: line._updateScrollFromFill()
        onPlayheadTimeMsChanged: line._updateKaraokeState()
        onSegmentsChanged: line._updateKaraokeState()

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

                // Measures the karaoke prefix and current segment widths for continuous fill.
                TextMetrics {
                    id: karaokePrevMetrics
                    text: line._karaokePrevText
                    font {
                        family: Appearance.font.family.main
                        pixelSize: line.fontPixelSize
                        hintingPreference: Font.PreferDefaultHinting
                        variableAxes: Appearance.font.variableAxes.main
                    }
                }

                TextMetrics {
                    id: karaokePrevPlusMetrics
                    text: line._karaokePrevText + line._karaokeActiveText
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
                    elide: Text.ElideNone
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
                    readonly property bool hasKaraoke: !!line._karaokeUsable
                    readonly property real karaokePrevW: Math.ceil(line._metricWidth(karaokePrevMetrics))
                    readonly property real karaokePrevPlusW: Math.ceil(line._metricWidth(karaokePrevPlusMetrics))
                    readonly property real targetWidth: line.useFill
                        ? (fillOverlay.hasKaraoke
                            ? (fillOverlay.karaokePrevW + (fillOverlay.karaokePrevPlusW - fillOverlay.karaokePrevW) * Math.max(0, Math.min(1, line._karaokeActiveProgress)))
                            : (fillBaseWidth * line.fillProgress))
                        : 0
                    width: targetWidth
                    clip: true

                    // Smooth interpolation so fill doesn't "jump" between ticks.
                    // Duration adapts to API update interval for seamless transitions.
                    // On line transitions, use 3x faster animation to "catch up" quickly.
                    Behavior on width {
                        // Karaoke is already driven at ~60fps by QS-side playhead;
                        // smoothing here would lag behind and can leave the tail slightly unfilled.
                        enabled: line.useFill && line.externalFillProgress >= 0 && !fillOverlay.hasKaraoke
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
                        elide: Text.ElideNone
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
