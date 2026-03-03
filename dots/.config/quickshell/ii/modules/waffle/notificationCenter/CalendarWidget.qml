pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.waffle.looks

BodyRectangle {
    id: root

    // State
    property bool collapsed

    // Locale
    property var locale: Qt.locale(Config.options.calendar.locale)
    readonly property string activeLanguageCode: (Translation.languageCode ?? "").toString().replace("-", "_").toLowerCase()
    readonly property string calendarLocaleCode: (locale?.name ?? "").toString().replace("-", "_").toLowerCase()
    readonly property bool showChineseLunar: activeLanguageCode.startsWith("zh") || calendarLocaleCode.startsWith("zh")
    readonly property var chineseLunarLocale: Qt.locale("zh_CN@calendar=chinese")
    readonly property var chineseLunarMonthNumberMap: ({
        "正月": 1, "一月": 1,
        "二月": 2,
        "三月": 3,
        "四月": 4,
        "五月": 5,
        "六月": 6,
        "七月": 7,
        "八月": 8,
        "九月": 9,
        "十月": 10,
        "冬月": 11, "十一月": 11,
        "腊月": 12, "十二月": 12
    })
    readonly property var chineseLunarFestivalMap: ({
        "1-1": "春节",
        "1-15": "元宵",
        "5-5": "端午",
        "7-7": "七夕",
        "8-15": "中秋",
        "9-9": "重阳",
        "12-8": "腊八",
        "12-23": "小年"
    })
    readonly property var chineseLunarDayNames: ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十", "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十", "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
    readonly property bool chineseLunarSupported: {
        if (!showChineseLunar)
            return false;

        try {
            const probeDate = new Date(2024, 1, 10); // Lunar new year 2024 -> 初一
            const probeText = (probeDate.toLocaleDateString(chineseLunarLocale, "d") ?? "").trim();
            return probeText === "1" || probeText === "01" || probeText === "初一";
        } catch (e) {
            return false;
        }
    }

    function lunarDayText(date) {
        if (!showChineseLunar || !chineseLunarSupported || !date || typeof date.getTime !== "function")
            return "";

        try {
            const rawText = (date.toLocaleDateString(chineseLunarLocale, "d") ?? "").trim();
            if (!rawText)
                return "";

            if (/^\d+$/.test(rawText)) {
                const dayValue = Number(rawText);
                if (dayValue >= 1 && dayValue <= chineseLunarDayNames.length)
                    return chineseLunarDayNames[dayValue - 1];

                return "";
            }

            return rawText;
        } catch (e) {
            return "";
        }
    }

    function lunarMonthNumber(rawMonthText) {
        if (!rawMonthText)
            return -1;

        const normalized = rawMonthText.toString().trim().replace("闰", "");
        const numericMatch = normalized.match(/\d+/);
        if (numericMatch)
            return Number(numericMatch[0]);

        return chineseLunarMonthNumberMap[normalized] ?? -1;
    }

    function lunarDayNumber(rawDayText) {
        if (!rawDayText)
            return -1;

        const normalized = rawDayText.toString().trim();
        const numericMatch = normalized.match(/\d+/);
        if (numericMatch)
            return Number(numericMatch[0]);

        const namedIndex = chineseLunarDayNames.indexOf(normalized);
        if (namedIndex >= 0)
            return namedIndex + 1;

        return -1;
    }

    function lunarDateParts(date) {
        if (!showChineseLunar || !chineseLunarSupported || !date || typeof date.getTime !== "function")
            return null;

        try {
            const rawMonth = (date.toLocaleDateString(chineseLunarLocale, "M") ?? "").trim();
            const rawDay = (date.toLocaleDateString(chineseLunarLocale, "d") ?? "").trim();
            const month = lunarMonthNumber(rawMonth);
            const day = lunarDayNumber(rawDay);

            if (month < 1 || month > 12 || day < 1 || day > 30)
                return null;

            return {
                month,
                day,
                leapMonth: rawMonth.includes("闰")
            };
        } catch (e) {
            return null;
        }
    }

    function lunarFestivalText(date) {
        const parts = lunarDateParts(date);
        if (!parts)
            return "";

        if (!parts.leapMonth) {
            const directFestival = chineseLunarFestivalMap[`${parts.month}-${parts.day}`] ?? "";
            if (directFestival)
                return directFestival;

            if (parts.month === 12) {
                const nextDate = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1);
                const nextParts = lunarDateParts(nextDate);
                if (nextParts && !nextParts.leapMonth && nextParts.month === 1 && nextParts.day === 1)
                    return "除夕";
            }
        }

        return "";
    }

    function lunarSubLabelText(date) {
        const festivalText = lunarFestivalText(date);
        if (festivalText)
            return festivalText;

        return lunarDayText(date);
    }

    implicitHeight: collapsed ? 0 : contentColumn.implicitHeight
    implicitWidth: contentColumn.implicitWidth

    Behavior on implicitHeight {
        animation: Looks.transition.enter.createObject(this)
    }

    clip: true
    ColumnLayout {
        id: contentColumn
        spacing: 12
        CalendarHeader {
            Layout.topMargin: 10
            Layout.fillWidth: true
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 5
            Layout.rightMargin: 5
            spacing: 1
            DayOfWeekRow {
                Layout.fillWidth: true
                locale: root.locale
                spacing: calendarView.buttonSpacing
                implicitHeight: calendarView.buttonSize
                delegate: Item {
                    id: dayOfWeekItem
                    required property var model
                    implicitHeight: calendarView.buttonSize
                    implicitWidth: calendarView.buttonSize
                    WText {
                        anchors.centerIn: parent
                        text: {
                            var result = dayOfWeekItem.model.shortName;
                            if (Config.options.waffles.calendar.force2CharDayOfWeek) result = result.substring(0,2);
                            return result;
                        }
                        color: Looks.colors.fg
                        font.pixelSize: Looks.font.pixelSize.large
                    }
                }
            }
            CalendarView {
                id: calendarView
                locale: root.locale
                verticalPadding: 2
                buttonSize: root.showChineseLunar && root.chineseLunarSupported ? 48 : 41 // ???
                buttonSpacing: 6
                buttonVerticalSpacing: 1
                Layout.fillWidth: true
                delegate: DayButton {}
            }
        }
    }

    component DayButton: WButton {
        id: dayButton
        required property var model
        readonly property bool showLunarText: root.showChineseLunar && root.chineseLunarSupported
        readonly property string festivalText: root.lunarFestivalText(dayButton.model.date)
        readonly property string lunarSubLabel: root.lunarSubLabelText(dayButton.model.date)
        checked: model.today
        enabled: hovered || checked || model.month === calendarView.focusedMonth
        implicitWidth: calendarView.buttonSize
        implicitHeight: calendarView.buttonSize
        radius: height / 2

        required property int index

        contentItem: Item {
            Column {
                anchors.centerIn: parent
                width: parent.width
                spacing: dayButton.showLunarText ? -1 : 0

                WText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: dayButton.model.day
                    color: dayButton.fgColor
                    font.pixelSize: dayButton.showLunarText ? Looks.font.pixelSize.large : Looks.font.pixelSize.larger
                }

                WText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: dayButton.lunarSubLabel
                    visible: dayButton.showLunarText && text.length > 0
                    color: dayButton.fgColor
                    opacity: dayButton.festivalText.length > 0 ? 0.95 : 0.72
                    font.pixelSize: Looks.font.pixelSize.normal
                    font.weight: dayButton.festivalText.length > 0 ? Looks.font.weight.strong : Looks.font.weight.regular
                }
            }
        }
    }

    component CalendarHeader: RowLayout {
        Layout.leftMargin: 8
        Layout.rightMargin: 8
        spacing: 8

        WBorderlessButton {
            Layout.fillWidth: true
            implicitHeight: 34
            contentItem: Item {
                WText {
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignLeft
                    text: Qt.locale().toString(calendarView.focusedDate, "MMMM yyyy")
                    font.pixelSize: Looks.font.pixelSize.large
                    font.weight: Looks.font.weight.strong
                }
            }
        }
        ScrollMonthButton {
            scrollDown: false
        }
        ScrollMonthButton {
            scrollDown: true
        }
    }

    component ScrollMonthButton: WBorderlessButton {
        id: scrollMonthButton
        required property bool scrollDown
        Layout.alignment: Qt.AlignVCenter

        onClicked: {
            calendarView.scrollMonthsAndSnap(scrollDown ? 1 : -1);
        }
        implicitWidth: 32
        implicitHeight: 34

        contentItem: FluentIcon {
            filled: true
            implicitSize: 12
            icon: scrollMonthButton.scrollDown ? "caret-down" : "caret-up"
        }
    }
}
