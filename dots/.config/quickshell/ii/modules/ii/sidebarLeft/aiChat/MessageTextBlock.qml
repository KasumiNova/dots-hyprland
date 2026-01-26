pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland

ColumnLayout {
    id: root
    // These are needed on the parent loader
    property bool editing: false
    property bool renderMarkdown: true
    property bool enableMouseSelection: false
    property var segmentContent: ({})
    // Must be a QObject (AiMessageData) or null. Using a plain JS object here can crash when
    // used as Connections.target (expects QObject*).
    property QtObject messageData: null
    property bool done: true
    property bool forceDisableChunkSplitting: false

    property list<string> renderedLatexHashes: []
    property string renderedSegmentContent: ""
    property string shownText: ""
    property bool fadeChunkSplitting: !forceDisableChunkSplitting && !editing && !/\n\|/.test(shownText) && Config.options.sidebar.ai.textFadeIn

    Layout.fillWidth: true

    Timer {
        id: renderTimer
        interval: 1000
        repeat: false
        onTriggered: {
            renderLatex()
            for (const hash of renderedLatexHashes) {
                handleRenderedLatex(hash, true);
            }
        }
    }

    function renderLatex() {
        // Regex for $...$, $$...$$, \[...\]
        // Note: This is a simple approach and may need refinement for edge cases
        let regex = /(\$\$([\s\S]+?)\$\$)|(\$([^\$]+?)\$)|(\\\[((?:.|\n)+?)\\\])|(\\\(([\s\S]+?)\\\))/g;
        let match;
        while ((match = regex.exec(segmentContent)) !== null) {
            let expression = match[1] || match[2] || match[3] || match[4] || match[5] || match[6] || match[7] || match[8];
            if (expression) {
                Qt.callLater(() => {
                    const [renderHash, isNew] = LatexRenderer.requestRender(expression.trim());
                    if (!renderedLatexHashes.includes(renderHash)) {
                        renderedLatexHashes.push(renderHash);
                    }
                });
            }
        }
    }

    function handleRenderedLatex(hash, force = false) {
        if (renderedLatexHashes.includes(hash) || force) {
            const imagePath = LatexRenderer.renderedImagePaths[hash];
            const markdownImage = `![latex](${imagePath})`;

            const expression = LatexRenderer.processedExpressions[hash];
            renderedSegmentContent = renderedSegmentContent.replace(expression, markdownImage);
        }
    }

    onDoneChanged: {
        renderTimer.restart();
    }
    onEditingChanged: {
        if (!editing) {
            renderLatex()
        } else {
            // console.log("Editing mode enabled", segmentContent)
            root.shownText = segmentContent
        }
    }

    onSegmentContentChanged: {
        // console.log("Segment content changed: " + segmentContent);
        renderedSegmentContent = segmentContent;
        if (!root.editing && segmentContent) {
            root.renderLatex();
        }
    }

    onRenderedSegmentContentChanged: {
        // console.log("Rendered segment content changed: " + renderedSegmentContent);
        if (renderedSegmentContent) {
            root.shownText = renderedSegmentContent;
        }
    }

    // When something finishes rendering
    // 1. Check if the hash is in the list
    // 2. If it is, replace the expression with the image path
    Connections {
        target: LatexRenderer
        function onRenderFinished(hash, imagePath) {
            const expression = LatexRenderer.processedExpressions[hash];
            // console.log("Render finished: " + hash + " " + expression);
            handleRenderedLatex(hash);
        }
    }

    spacing: 0
    Repeater {
        id: textLinesRepeater
        property list<real> textLineOpacities: []
        model: ScriptModel {
            // Split by either double newlines or single newlines in a list
            values: root.fadeChunkSplitting ? root.shownText.split(/\n\n(?= {0,2})|\n(?= {0,2}[-\*])/g).filter(line => line.trim() !== "") : [root.shownText]
            onValuesChanged: {
                const done = root.messageData ? !!root.messageData.done : root.done;
                const oldLen = textLinesRepeater.textLineOpacities.length;
                while (textLinesRepeater.textLineOpacities.length < values.length) {
                    // New chunk: start hidden while streaming, then fade in.
                    // When done, keep everything visible.
                    textLinesRepeater.textLineOpacities.push(done ? 1 : 0);
                }

                // Trigger fade-in for newly created chunks.
                if (root.fadeChunkSplitting && !done) {
                    for (let i = oldLen; i < values.length; i++) {
                        const idx = i;
                        Qt.callLater(() => {
                            textLinesRepeater.textLineOpacities[idx] = 1;
                        });
                    }
                }
            }
        }
        delegate: TextArea {
            id: textArea
            required property int index
            required property string modelData

            // A subtle pulse for the last chunk while streaming.
            // This makes incremental updates feel more like a fade instead of a hard jump.
            property real revealOpacity: 1

            Timer {
                id: revealTimer
                interval: 90
                repeat: false
                onTriggered: textArea.revealOpacity = 1
            }

            // Fade in animation
            visible: opacity > 0
            opacity: {
                if (!fadeChunkSplitting) return 1;
                const done = root.messageData ? !!root.messageData.done : true;
                const base = (textLinesRepeater.textLineOpacities[index] ?? (done ? 1 : 0));
                return base * textArea.revealOpacity;
            }
            Connections {
                target: root.messageData
                function onDoneChanged() {
                    if (root.messageData && root.messageData.done) {
                        textLinesRepeater.textLineOpacities[textArea.index] = 1
                    }
                }
            }
            Connections {
                target: textLinesRepeater.model
                function onValuesChanged() {
                    if (textLinesRepeater.model.values.length > textArea.index + 1) {
                        textLinesRepeater.textLineOpacities[textArea.index] = 1
                    }
                }
            }
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

            Behavior on revealOpacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

            Layout.fillWidth: true
            readOnly: !editing
            selectByMouse: enableMouseSelection || editing
            renderType: Text.NativeRendering
            font.family: Appearance.font.family.reading
            font.hintingPreference: Font.PreferNoHinting // Prevent weird bold text
            font.pixelSize: Appearance.font.pixelSize.small
            selectedTextColor: Appearance.m3colors.m3onSecondaryContainer
            selectionColor: Appearance.colors.colSecondaryContainer
            wrapMode: TextEdit.Wrap
            color: root.messageData?.thinking ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer1
            textFormat: renderMarkdown ? TextEdit.MarkdownText : TextEdit.PlainText
            text: modelData

            onTextChanged: {
                if (root.editing) {
                    segmentContent = text
                    return;
                }

                if (!fadeChunkSplitting) return;
                const done = root.messageData ? !!root.messageData.done : true;
                if (done) return;

                // Only pulse the last displayed chunk.
                const lastIndex = (textLinesRepeater.model?.values?.length ?? 1) - 1;
                if (textArea.index !== lastIndex) return;

                // Pulse: quickly dip opacity then fade back in.
                textArea.revealOpacity = 0.65;
                revealTimer.restart();
            }

            onLinkActivated: (link) => {
                Qt.openUrlExternally(link)
                GlobalStates.sidebarLeftOpen = false
            }

            MouseArea { // Pointing hand for links
                anchors.fill: parent
                acceptedButtons: Qt.NoButton // Only for hover
                hoverEnabled: true
                cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : 
                    (enableMouseSelection || editing) ? Qt.IBeamCursor : Qt.ArrowCursor
            }

            // Rectangle {
            //     anchors.fill: parent
            //     color: "#22786378"
            //     border.width: 1
            //     border.color: "#7E7E7E"
            // }
        }
    }
}
