import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.ii.sidebarLeft.translator
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

/**
 * Translator widget with the `trans` commandline tool.
 */
Item {
    id: root

    // Sizes
    property real padding: 4

    // Widgets
    property var inputField: inputCanvas.inputTextArea

    // Widget variables
    property bool translationFor: false // Indicates if the translation is for an autocorrected text
    property string translatedText: ""
    property var languages: []
    property var languageIndex: ({})

    // Options
    property string targetLanguage: Config.options.language.translator.targetLanguage
    property string sourceLanguage: Config.options.language.translator.sourceLanguage
    property string hostLanguage: targetLanguage

    // States
    property bool showLanguageSelector: false
    property bool languageSelectorTarget: false // true for target language, false for source language

    // Injection state (clipboard -> input box)
    property string _pendingInjectedText: ""
    property int _injectAttempts: 0

    function normalizeLanguageCode(lang) {
        const s = (lang ?? "").trim();
        if (s.length === 0) return "auto";
        return s.split(/\s+/)[0];
    }

    function languageLabel(code) {
        const key = (code ?? "").trim();
        return root.languageIndex?.[key] ?? key;
    }

    function swapLanguages() {
        const tmp = root.sourceLanguage;
        root.sourceLanguage = root.targetLanguage;
        root.targetLanguage = tmp;
        Config.options.language.translator.sourceLanguage = root.sourceLanguage;
        Config.options.language.translator.targetLanguage = root.targetLanguage;
        translateTimer.restart();
    }

    function _consumeRequestedText() {
        const t = (GlobalStates.sidebarLeftTranslatorRequestedText ?? "").trim();
        if (t.length === 0) return;

        root._pendingInjectedText = t;
        root._injectAttempts = 0;
        root._tryApplyPendingInjectedText();
    }

    function _tryApplyPendingInjectedText() {
        const t = (root._pendingInjectedText ?? "").trim();
        if (t.length === 0) return;

        // TextCanvas uses a Loader for the TextArea; on some setups it may not be ready immediately.
        if (!root.inputField || root.inputField.text === undefined) {
            root._injectAttempts++;
            if (root._injectAttempts <= 50) {
                injectRetryTimer.restart();
            } else {
                console.error("[Translator] Failed to inject clipboard text: input field not ready after 50 attempts");
            }
            return;
        }

        root.inputField.text = t;
        root._pendingInjectedText = "";
        GlobalStates.sidebarLeftTranslatorRequestedText = "";
        translateTimer.restart();
        Qt.callLater(() => {
            try { root.inputField.forceActiveFocus(); } catch (e) {}
        });
    }

    Timer {
        id: injectRetryTimer
        interval: 16
        repeat: false
        onTriggered: root._tryApplyPendingInjectedText()
    }

    function showLanguageSelectorDialog(isTargetLang: bool) {
        root.languageSelectorTarget = isTargetLang;
        root.showLanguageSelector = true
    }

    Component.onCompleted: root._consumeRequestedText()

    Connections {
        target: GlobalStates
        function onSidebarLeftTranslatorRequestedTextChanged() {
            root._consumeRequestedText();
        }
    }

    onFocusChanged: (focus) => {
        if (focus) {
            root.inputField.forceActiveFocus()
        }
    }

    Timer {
        id: translateTimer
        interval: Config.options.sidebar.translator.delay
        repeat: false
        onTriggered: () => {
            if (root.inputField.text.trim().length > 0) {
                // console.log("Translating with command:", translateProc.command);
                translateProc.running = false;
                translateProc.buffer = ""; // Clear the buffer
                translateProc.running = true; // Restart the process
            } else {
                root.translatedText = "";
            }
        }
    }

    Process {
        id: translateProc
        command: ["bash", "-c", `trans -brief`
            + ` -source '${StringUtils.shellSingleQuoteEscape(root.normalizeLanguageCode(root.sourceLanguage))}'`
            + ` -target '${StringUtils.shellSingleQuoteEscape(root.normalizeLanguageCode(root.targetLanguage))}'`
            + ` '${StringUtils.shellSingleQuoteEscape(root.inputField.text.trim())}'`]
        property string buffer: ""
        stdout: SplitParser {
            onRead: data => {
                translateProc.buffer += data + "\n";
            }
        }
        onExited: (exitCode, exitStatus) => {
            // With -brief mode, we get output with no metadata
            root.translatedText = translateProc.buffer.trim();
        }
    }

    Process {
        id: getLanguagesProc
        command: ["trans", "-list-languages", "-no-bidi"]
        property list<string> bufferList: ["auto"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                getLanguagesProc.bufferList.push(data.trim());
            }
        }
        onExited: (exitCode, exitStatus) => {
            // Parse `trans -list-languages` into objects for SelectionDialog (displayName/value/searchText)
            // Typical line format: "zh-CN Chinese (Simplified)"
            const parsed = [];
            for (const raw of (getLanguagesProc.bufferList ?? [])) {
                const line = (raw ?? "").trim();
                if (line.length === 0) continue;
                if (line === "auto") continue;

                const m = line.match(/^(\S+)\s+(.*)$/);
                const code = (m?.[1] ?? line).trim();
                const name = (m?.[2] ?? "").trim();
                const displayName = name.length > 0 ? `${name} (${code})` : code;
                parsed.push({
                    displayName,
                    value: code,
                    searchText: `${code} ${name} ${displayName}`.trim(),
                });
            }
            parsed.sort((a, b) => (a.displayName ?? "").localeCompare((b.displayName ?? "")));
            parsed.unshift({
                displayName: `Auto (auto)`,
                value: "auto",
                searchText: "auto automatic detect",
            });

            const idx = {};
            for (const it of parsed) {
                if (it?.value) idx[it.value] = it.displayName;
            }

            root.languages = parsed;
            root.languageIndex = idx;
            getLanguagesProc.bufferList = []; // Clear the buffer
        }
    }

    ColumnLayout {
        anchors {
            fill: parent
            margins: root.padding
        }

        StyledFlickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: contentColumn.implicitHeight

            ColumnLayout {
                id: contentColumn
                anchors.fill: parent

                RowLayout {
                    Layout.fillWidth: true

                    LanguageSelectorButton { // Target language button
                        id: targetLanguageButton
                        Layout.fillWidth: true
                        displayText: root.languageLabel(root.targetLanguage)
                        onClicked: {
                            root.showLanguageSelectorDialog(true);
                        }
                    }

                    GroupButton {
                        id: swapLangButton
                        baseWidth: height
                        buttonRadius: Appearance.rounding.small
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            horizontalAlignment: Text.AlignHCenter
                            iconSize: Appearance.font.pixelSize.larger
                            text: "swap_horiz"
                            color: Appearance.colors.colOnLayer1
                        }
                        onClicked: root.swapLanguages()
                    }
                }

                TextCanvas { // Content translation
                    id: outputCanvas
                    isInput: false
                    placeholderText: Translation.tr("Translation goes here...")
                    property bool hasTranslation: (root.translatedText.trim().length > 0)
                    text: hasTranslation ? root.translatedText : ""
                    GroupButton {
                        id: copyButton
                        baseWidth: height
                        buttonRadius: Appearance.rounding.small
                        enabled: outputCanvas.displayedText.trim().length > 0
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            horizontalAlignment: Text.AlignHCenter
                            iconSize: Appearance.font.pixelSize.larger
                            text: "content_copy"
                            color: copyButton.enabled ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                        }
                        onClicked: {
                            Quickshell.clipboardText = outputCanvas.displayedText
                        }
                    }
                    GroupButton {
                        id: searchButton
                        baseWidth: height
                        buttonRadius: Appearance.rounding.small
                        enabled: outputCanvas.displayedText.trim().length > 0
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            horizontalAlignment: Text.AlignHCenter
                            iconSize: Appearance.font.pixelSize.larger
                            text: "travel_explore"
                            color: searchButton.enabled ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                        }
                        onClicked: {
                            let url = Config.options.search.engineBaseUrl + outputCanvas.displayedText;
                            for (let site of Config.options.search.excludedSites) {
                                url += ` -site:${site}`;
                            }
                            Qt.openUrlExternally(url);
                        }
                    }
                }

            }    
        }

        ConfigSwitch {
            id: doubleCopySwitch
            buttonIcon: "content_copy"
            text: Translation.tr("Double-copy clipboard to translate")
            checked: Config.options.sidebar.translator.doubleCopyTranslateClipboard
            onCheckedChanged: {
                Config.options.sidebar.translator.doubleCopyTranslateClipboard = checked;
            }
        }

        LanguageSelectorButton { // Source language button
            id: sourceLanguageButton
            displayText: root.languageLabel(root.sourceLanguage)
            onClicked: {
                root.showLanguageSelectorDialog(false);
            }
        }

        TextCanvas { // Content input
            id: inputCanvas
            isInput: true
            placeholderText: Translation.tr("Enter text to translate...")
            onInputTextChanged: {
                translateTimer.restart();
            }
            GroupButton {
                id: pasteButton
                baseWidth: height
                buttonRadius: Appearance.rounding.small
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    horizontalAlignment: Text.AlignHCenter
                    iconSize: Appearance.font.pixelSize.larger
                    text: "content_paste"
                    color: deleteButton.enabled ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                }
                onClicked: {
                    root.inputField.text = Quickshell.clipboardText
                }
            }
            GroupButton {
                id: deleteButton
                baseWidth: height
                buttonRadius: Appearance.rounding.small
                enabled: inputCanvas.inputTextArea.text.length > 0
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    horizontalAlignment: Text.AlignHCenter
                    iconSize: Appearance.font.pixelSize.larger
                    text: "close"
                    color: deleteButton.enabled ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                }
                onClicked: {
                    root.inputField.text = ""
                }
            }
        }
    }

    Loader {
        anchors.fill: parent
        active: root.showLanguageSelector
        visible: root.showLanguageSelector
        z: 9999
        sourceComponent: SelectionDialog {
            id: languageSelectorDialog
            titleText: Translation.tr("Select Language")
            items: root.languages
            searchable: true
            searchPlaceholderText: Translation.tr("Search languages...")
            defaultChoice: root.languageSelectorTarget ? root.targetLanguage : root.sourceLanguage
            onCanceled: () => {
                root.showLanguageSelector = false;
            }
            onSelected: (result) => {
                root.showLanguageSelector = false;
                const r = (result ?? "").trim();
                if (r.length === 0) return; // No selection made

                if (root.languageSelectorTarget) {
                    root.targetLanguage = r;
                    Config.options.language.translator.targetLanguage = r; // Save to config
                } else {
                    root.sourceLanguage = r;
                    Config.options.language.translator.sourceLanguage = r; // Save to config
                }

                translateTimer.restart(); // Restart translation after language change
            }
        }
    }
}
