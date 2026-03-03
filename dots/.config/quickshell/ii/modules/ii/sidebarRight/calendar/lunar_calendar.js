const LUNAR_INFO = [
    0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,
    0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,
    0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,
    0x06566, 0x0d4a0, 0x0ea50, 0x06e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,
    0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,
    0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5d0, 0x14573, 0x052d0, 0x0a9a8, 0x0e950, 0x06aa0,
    0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,
    0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b5a0, 0x195a6,
    0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,
    0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x05ac0, 0x0ab60, 0x096d5, 0x092e0,
    0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,
    0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,
    0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530,
    0x05aa0, 0x076a3, 0x096d0, 0x04bd7, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,
    0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0
];

const MIN_YEAR = 1900;
const MAX_YEAR = MIN_YEAR + LUNAR_INFO.length - 1;
const BASE_SOLAR_DATE = new Date(1900, 0, 31, 12); // 1900-01-31 == 农历正月初一
const MS_PER_DAY = 24 * 60 * 60 * 1000;

const DAY_NAMES = [
    "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"
];

const FESTIVAL_MAP = {
    "1-1": "春节",
    "1-15": "元宵",
    "5-5": "端午",
    "7-7": "七夕",
    "8-15": "中秋",
    "9-9": "重阳",
    "12-8": "腊八",
    "12-23": "小年"
};

function isValidDate(date) {
    return date && typeof date.getTime === "function" && !Number.isNaN(date.getTime());
}

function normalizeDate(date) {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 12);
}

function isSupported(date) {
    if (!isValidDate(date)) return false;
    const d = normalizeDate(date);
    const y = d.getFullYear();
    return y >= MIN_YEAR && y <= MAX_YEAR;
}

function leapMonth(year) {
    return LUNAR_INFO[year - MIN_YEAR] & 0x0f;
}

function leapDays(year) {
    const lm = leapMonth(year);
    if (lm === 0) return 0;
    return (LUNAR_INFO[year - MIN_YEAR] & 0x10000) ? 30 : 29;
}

function monthDays(year, month) {
    return (LUNAR_INFO[year - MIN_YEAR] & (0x10000 >> month)) ? 30 : 29;
}

function yearDays(year) {
    let sum = 348;
    for (let mask = 0x8000; mask > 0x8; mask >>= 1) {
        if (LUNAR_INFO[year - MIN_YEAR] & mask) sum++;
    }
    return sum + leapDays(year);
}

function solarToLunar(solarDate) {
    if (!isSupported(solarDate)) return null;

    const date = normalizeDate(solarDate);
    let offset = Math.floor((date.getTime() - BASE_SOLAR_DATE.getTime()) / MS_PER_DAY);

    let year = MIN_YEAR;
    let temp = 0;
    for (; year <= MAX_YEAR && offset > 0; year++) {
        temp = yearDays(year);
        offset -= temp;
    }
    if (offset < 0) {
        offset += temp;
        year--;
    }

    const leap = leapMonth(year);
    let isLeap = false;
    let month = 1;

    for (; month <= 12 && offset > 0; month++) {
        if (leap > 0 && month === leap + 1 && !isLeap) {
            month--;
            isLeap = true;
            temp = leapDays(year);
        } else {
            temp = monthDays(year, month);
        }

        if (isLeap && month === leap + 1) {
            isLeap = false;
        }

        offset -= temp;
    }

    if (offset === 0 && leap > 0 && month === leap + 1) {
        if (isLeap) {
            isLeap = false;
        } else {
            isLeap = true;
            month--;
        }
    }

    if (offset < 0) {
        offset += temp;
        month--;
    }

    return {
        year,
        month,
        day: offset + 1,
        leapMonth: isLeap
    };
}

function lunarDayText(solarDate) {
    const lunar = solarToLunar(solarDate);
    if (!lunar) return "";
    return DAY_NAMES[lunar.day - 1] ?? "";
}

function lunarFestivalText(solarDate) {
    const lunar = solarToLunar(solarDate);
    if (!lunar || lunar.leapMonth) return "";

    const direct = FESTIVAL_MAP[`${lunar.month}-${lunar.day}`] ?? "";
    if (direct) return direct;

    if (lunar.month === 12) {
        const d = normalizeDate(solarDate);
        const tomorrow = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 12);
        const nextLunar = solarToLunar(tomorrow);
        if (nextLunar && !nextLunar.leapMonth && nextLunar.month === 1 && nextLunar.day === 1) {
            return "除夕";
        }
    }

    return "";
}

function lunarSubLabelText(solarDate) {
    const festival = lunarFestivalText(solarDate);
    if (festival) return festival;
    return lunarDayText(solarDate);
}
