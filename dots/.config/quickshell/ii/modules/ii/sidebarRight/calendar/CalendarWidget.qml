import qs.services
import qs.modules.common
import qs.modules.common.widgets
import "calendar_layout.js" as CalendarLayout
import "lunar_calendar.js" as LunarCalendar
import QtQuick
import QtQuick.Layouts

Item {
    id: root
    // Layout.topMargin: 10
    anchors.topMargin: 10
    property int monthShift: 0
    property var viewingDate: CalendarLayout.getDateInXMonthsTime(monthShift)
    property var calendarLayout: CalendarLayout.getCalendarLayout(viewingDate, monthShift === 0)
    readonly property string activeLanguageCode: (Translation.languageCode ?? "").toString().replace("-", "_").toLowerCase()
    readonly property string systemLocaleCode: (Qt.locale().name ?? "").toString().replace("-", "_").toLowerCase()
    readonly property string configuredLanguageCode: (Config?.options?.language?.ui ?? "").toString().replace("-", "_").toLowerCase()
    readonly property bool showChineseLunar: activeLanguageCode.startsWith("zh") || configuredLanguageCode.startsWith("zh") || systemLocaleCode.startsWith("zh")
    readonly property bool chineseLunarSupported: LunarCalendar.isSupported(new Date())
    readonly property real calendarCellScale: 1.0
    readonly property real calendarTextScale: showChineseLunar ? 1.3 : 1.0
    width: calendarColumn.width
    implicitHeight: calendarColumn.height + 10 * 2

    Keys.onPressed: (event) => {
        if ((event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp)
            && event.modifiers === Qt.NoModifier) {
            if (event.key === Qt.Key_PageDown) {
                monthShift++;
            } else if (event.key === Qt.Key_PageUp) {
                monthShift--;
            }
            event.accepted = true;
        }
    }
    MouseArea {
        anchors.fill: parent
        onWheel: (event) => {
            if (event.angleDelta.y > 0) {
                monthShift--;
            } else if (event.angleDelta.y < 0) {
                monthShift++;
            }
        }
    }

    ColumnLayout {
        id: calendarColumn
        anchors.centerIn: parent
        spacing: 5

        // Calendar header
        RowLayout {
            Layout.fillWidth: true
            spacing: 5
            CalendarHeaderButton {
                clip: true
                buttonText: `${monthShift != 0 ? "• " : ""}${viewingDate.toLocaleDateString(Qt.locale(), "MMMM yyyy")}`
                tooltipText: (monthShift === 0) ? "" : Translation.tr("Jump to current month")
                downAction: () => {
                    monthShift = 0;
                }
            }
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: false
            }
            CalendarHeaderButton {
                forceCircle: true
                downAction: () => {
                    monthShift--;
                }
                contentItem: MaterialSymbol {
                    text: "chevron_left"
                    iconSize: Appearance.font.pixelSize.larger
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.colors.colOnLayer1
                }
            }
            CalendarHeaderButton {
                forceCircle: true
                downAction: () => {
                    monthShift++;
                }
                contentItem: MaterialSymbol {
                    text: "chevron_right"
                    iconSize: Appearance.font.pixelSize.larger
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.colors.colOnLayer1
                }
            }
        }

        // Week days row
        RowLayout {
            id: weekDaysRow
            Layout.alignment: Qt.AlignHCenter
            Layout.fillHeight: false
            spacing: 5
            Repeater {
                model: CalendarLayout.weekDays
                delegate: CalendarDayButton {
                    day: Translation.tr(modelData.day)
                    isToday: typeof modelData.today === "number" ? modelData.today : -1
                    bold: true
                    showSubLabel: false
                    cellScale: root.calendarCellScale
                    enabled: false
                }
            }
        }

        // Real week rows
        Repeater {
            id: calendarRows
            // model: calendarLayout
            model: 6
            delegate: RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillHeight: false
                spacing: 5
                Repeater {
                    model: Array(7).fill(modelData)
                    delegate: CalendarDayButton {
                        property var cellModel: calendarLayout[modelData] ? calendarLayout[modelData][index] : null
                        day: cellModel && cellModel.day !== undefined ? cellModel.day : ""
                        isToday: cellModel && typeof cellModel.today === "number" ? cellModel.today : -1
                        cellScale: root.calendarCellScale
                        dayFontScale: root.calendarTextScale
                        subLabelFontScale: root.calendarTextScale
                        subLabelPixelSize: 11
                        showSubLabel: root.showChineseLunar && root.chineseLunarSupported
                        subLabel: !cellModel || cellModel.today === -1 ? "" : LunarCalendar.lunarSubLabelText(cellModel.date)
                        highlightSubLabel: !!(cellModel && cellModel.today !== -1 && LunarCalendar.lunarFestivalText(cellModel.date).length > 0)
                    }
                }
            }
        }
    }
}