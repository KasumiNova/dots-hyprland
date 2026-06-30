import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const helperPath = new URL("../modules/common/functions/AppSearchPinyin.js", import.meta.url);
const helperSource = fs.readFileSync(helperPath, "utf8")
  .replace(/^\.pragma library\s*/m, "")
  .replace(/^Qt\.include\(.*\)\s*/m, "");

const context = {
  console,
  pinyin(text, options = {}) {
    const map = {
      "火": "huo",
      "狐": "hu",
      "浏": "liu",
      "览": "lan",
      "器": "qi",
    };
    const values = Array.from(text).map(ch => map[ch] ?? ch).filter(Boolean);
    if (options.pattern === "first") {
      return values.map(value => value[0] ?? "").join(options.separator ?? " ");
    }
    return values.join(options.separator ?? " ");
  },
};

vm.createContext(context);
vm.runInContext(helperSource, context);

const firefoxCn = {
  id: "firefox.desktop",
  name: "火狐浏览器",
  genericName: "Web Browser",
  comment: "Browse the Web",
  keywords: ["browser", "web"],
};

assert.equal(
  context.searchTextForEntry(firefoxCn, false),
  "火狐浏览器 Web Browser Browse the Web firefox.desktop browser web",
  "pinyin text is not included while disabled",
);

const enabledText = context.searchTextForEntry(firefoxCn, true);
assert.match(enabledText, /huo hu liu lan qi/, "full pinyin is included");
assert.match(enabledText, /huohuliulanqi/, "compact pinyin is included");
assert.match(enabledText, /hhllq/, "pinyin initials are included");

const latinOnly = context.searchTextForEntry({
  id: "code.desktop",
  name: "Visual Studio Code",
  genericName: "",
  comment: "",
  keywords: [],
}, true);
assert.equal(latinOnly, "Visual Studio Code code.desktop", "latin-only entries are not expanded");

console.log("app search pinyin tests passed");
