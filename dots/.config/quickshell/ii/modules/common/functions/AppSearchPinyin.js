.pragma library

Qt.include("pinyin-pro.js")

// pinyin-pro is vendored as a browser/UMD build in pinyin-pro.js.
// This helper keeps AppSearch.qml independent from the library's bundle shape.

function hasChinese(text) {
    return /[\u3400-\u9fff]/.test(String(text ?? ""));
}

function compact(text) {
    return String(text ?? "").replace(/\s+/g, "");
}

function uniqueWords(words) {
    const seen = {};
    const result = [];
    for (const word of words) {
        const value = String(word ?? "").trim();
        if (!value || seen[value])
            continue;
        seen[value] = true;
        result.push(value);
    }
    return result;
}

function baseSearchTextForEntry(entry) {
    return uniqueWords([
        entry?.name,
        entry?.genericName,
        entry?.comment,
        entry?.id,
        ...(entry?.keywords ?? []),
    ]).join(" ");
}

function pinyinForText(text) {
    if (!hasChinese(text) || typeof pinyin !== "function")
        return "";

    const chineseText = (String(text ?? "").match(/[\u3400-\u9fff]+/g) ?? []).join(" ");
    if (!chineseText)
        return "";

    const full = pinyin(chineseText, {
        toneType: "none",
        type: "string",
        separator: " ",
        nonZh: "spaced",
        v: true,
    });
    const first = pinyin(chineseText, {
        pattern: "first",
        toneType: "none",
        type: "string",
        separator: "",
        nonZh: "removed",
        v: true,
    });

    return uniqueWords([full, compact(full), first]).join(" ");
}

function searchTextForEntry(entry, enablePinyin) {
    const base = baseSearchTextForEntry(entry);
    if (!enablePinyin)
        return base;

    return uniqueWords([base, pinyinForText(base)]).join(" ");
}
