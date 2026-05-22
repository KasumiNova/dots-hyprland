pragma Singleton
pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * A nice wrapper for date and time strings.
 */
Singleton {
    property var clock: SystemClock {
        id: clock
        precision: {
            if (Config.options.time.secondPrecision || GlobalStates.screenLocked)
                return SystemClock.Seconds;
            return SystemClock.Minutes;
        }
    }
    readonly property var locale: Qt.locale()
    readonly property string localeCode: {
        const configured = Config.options?.language?.ui ?? "auto";
        if (configured !== "auto")
            return configured;
        const systemLocale = (locale.name ?? "").toString();
        if (systemLocale && systemLocale !== "C")
            return systemLocale;
        return systemLocaleFromEnvironment();
    }
    readonly property bool useChineseDateFormat: localeCode.replace("-", "_").toLowerCase().startsWith("zh")
    readonly property var displayLocale: useChineseDateFormat ? Qt.locale(localeCode) : locale
    property string time: displayLocale.toString(clock.date, Config.options?.time.format ?? "hh:mm")
    property string shortDate: formatDate(clock.date, "short", Config.options?.time.shortDateFormat, "dd/MM")
    property string date: formatDate(clock.date, "medium", Config.options?.time.dateWithYearFormat, "dd/MM/yyyy")
    property string longDate: formatDate(clock.date, "long", Config.options?.time.dateFormat, "ddd, dd/MM")
    property string collapsedCalendarFormat: formatDate(clock.date, "full")
    property string tooltipDateTime: formatDateTime(clock.date)
    property string uptime: formatDuration(0, 0, 0)

    function isCustomFormat(format, legacyDefault) {
        return !!format && format !== legacyDefault;
    }

    function normalizedLocaleCode(value) {
        const raw = (value ?? "").toString();
        if (!raw || raw === "C" || raw === "C.UTF-8")
            return "";
        return raw.split(".")[0];
    }

    function systemLocaleFromEnvironment() {
        return normalizedLocaleCode(Quickshell.env("LC_TIME"))
            || normalizedLocaleCode(Quickshell.env("LC_MESSAGES"))
            || normalizedLocaleCode(Quickshell.env("LANG"))
            || "C";
    }

    function formatDate(date, style, configuredFormat, legacyDefault) {
        if (isCustomFormat(configuredFormat, legacyDefault))
            return displayLocale.toString(date, configuredFormat);

        if (useChineseDateFormat) {
            switch (style) {
            case "short":
                return displayLocale.toString(date, Translation.tr("Date format short"));
            case "medium":
                return displayLocale.toString(date, Translation.tr("Date format medium"));
            case "long":
                return displayLocale.toString(date, Translation.tr("Date format long"));
            case "full":
                return displayLocale.toString(date, Translation.tr("Date format full"));
            default:
                return displayLocale.toString(date, Translation.tr("Date format full"));
            }
        }

        switch (style) {
        case "short":
            return date.toLocaleDateString(displayLocale, Locale.ShortFormat);
        case "medium":
            return date.toLocaleDateString(displayLocale, Locale.ShortFormat);
        case "long":
            return date.toLocaleDateString(displayLocale, Locale.LongFormat);
        case "full":
            return date.toLocaleDateString(displayLocale, Locale.LongFormat);
        default:
            return date.toLocaleDateString(displayLocale, Locale.LongFormat);
        }
    }

    function formatDateTime(date) {
        if (useChineseDateFormat)
            return `${formatDate(date, "full")} ${time}`;
        return `${formatDate(date, "full")}\n\n${date.toLocaleString(displayLocale, Locale.ShortFormat)}`;
    }

    function formatDuration(days, hours, minutes) {
        if (useChineseDateFormat) {
            let parts = [];
            if (days > 0)
                parts.push(Translation.tr("%1 days").arg(days));
            if (hours > 0)
                parts.push(Translation.tr("%1 hours").arg(hours));
            if (minutes > 0 || parts.length === 0)
                parts.push(Translation.tr("%1 minutes").arg(minutes));
            return parts.join(" ");
        }

        let formatted = "";
        if (days > 0)
            formatted += `${days}d`;
        if (hours > 0)
            formatted += `${formatted ? ", " : ""}${hours}h`;
        if (minutes > 0 || !formatted)
            formatted += `${formatted ? ", " : ""}${minutes}m`;
        return formatted;
    }

    Timer {
        interval: 10
        running: true
        repeat: true
        onTriggered: {
            fileUptime.reload();
            const textUptime = fileUptime.text();
            const uptimeSeconds = Number(textUptime.split(" ")[0] ?? 0);

            // Convert seconds to days, hours, and minutes
            const days = Math.floor(uptimeSeconds / 86400);
            const hours = Math.floor((uptimeSeconds % 86400) / 3600);
            const minutes = Math.floor((uptimeSeconds % 3600) / 60);

            uptime = formatDuration(days, hours, minutes);
            interval = Config.options?.resources?.updateInterval ?? 3000;
        }
    }

    FileView {
        id: fileUptime

        path: "/proc/uptime"
    }
}
