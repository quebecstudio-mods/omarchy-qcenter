#!/usr/bin/env python3
"""Turn ICS calendars into the agenda JSON qCenter reads.

Reads {"calendars": [{"name", "color", "url"}]} on stdin (links can hold a
private token, so they never travel in argv), where url is an https:// or
webcal:// link or the path of a local .ics file, and writes

    {"generated": "...", "events": [{"title", "start", "end", "allDay",
                                     "color", "calendar", "join"}]}

with the events from the start of today to seven days ahead. Python's
standard library only. Time zones: IANA names through zoneinfo, Windows names
(Outlook, Exchange) through a table, and otherwise the calendar's own
VTIMEZONE definitions. Recurrences: a small RRULE expander that covers what
calendar apps publish (DAILY, WEEKLY, MONTHLY, YEARLY with INTERVAL, COUNT,
UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS), EXDATE, RDATE and moved or
cancelled occurrences (RECURRENCE-ID).

Downloads are cached; a link is fetched at most every five minutes, and the
last copy is used when the network is down. Only https is used: a link names
a private calendar, so it never travels in clear.
"""
import argparse
import calendar as cal
import datetime as dt
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DAYS_AHEAD = 7
FETCH_EVERY = 5 * 60
MAX_BYTES = 20 * 1024 * 1024
MAX_PERIODS = 200000     # periods walked per series, from its first one
MAX_IN_WINDOW = 1000     # occurrences kept per series inside the window

WEEKDAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}

# Windows zone names (Outlook, Exchange) for the most common zones; anything
# else falls back to the VTIMEZONE the calendar carries.
WINDOWS_ZONES = {
    "Dateline Standard Time": "Etc/GMT+12", "UTC-11": "Etc/GMT+11", "Hawaiian Standard Time": "Pacific/Honolulu",
    "Alaskan Standard Time": "America/Anchorage", "Pacific Standard Time (Mexico)": "America/Tijuana",
    "Pacific Standard Time": "America/Los_Angeles", "US Mountain Standard Time": "America/Phoenix",
    "Mountain Standard Time (Mexico)": "America/Mazatlan", "Mountain Standard Time": "America/Denver",
    "Central America Standard Time": "America/Guatemala", "Central Standard Time": "America/Chicago",
    "Central Standard Time (Mexico)": "America/Mexico_City", "Canada Central Standard Time": "America/Regina",
    "SA Pacific Standard Time": "America/Bogota", "Eastern Standard Time (Mexico)": "America/Cancun",
    "Eastern Standard Time": "America/New_York", "US Eastern Standard Time": "America/Indianapolis",
    "Venezuela Standard Time": "America/Caracas", "Paraguay Standard Time": "America/Asuncion",
    "Atlantic Standard Time": "America/Halifax", "Central Brazilian Standard Time": "America/Cuiaba",
    "SA Western Standard Time": "America/La_Paz", "Pacific SA Standard Time": "America/Santiago",
    "Newfoundland Standard Time": "America/St_Johns", "E. South America Standard Time": "America/Sao_Paulo",
    "Argentina Standard Time": "America/Buenos_Aires", "SA Eastern Standard Time": "America/Cayenne",
    "Greenland Standard Time": "America/Godthab", "Montevideo Standard Time": "America/Montevideo",
    "UTC-02": "Etc/GMT+2", "Azores Standard Time": "Atlantic/Azores", "Cape Verde Standard Time": "Atlantic/Cape_Verde",
    "UTC": "UTC", "Coordinated Universal Time": "UTC", "GMT Standard Time": "Europe/London",
    "Greenwich Standard Time": "Atlantic/Reykjavik", "Morocco Standard Time": "Africa/Casablanca",
    "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
    "Romance Standard Time": "Europe/Paris", "Central European Standard Time": "Europe/Warsaw",
    "W. Central Africa Standard Time": "Africa/Lagos", "GTB Standard Time": "Europe/Bucharest",
    "Middle East Standard Time": "Asia/Beirut", "Egypt Standard Time": "Africa/Cairo",
    "E. Europe Standard Time": "Europe/Chisinau", "FLE Standard Time": "Europe/Kiev",
    "Israel Standard Time": "Asia/Jerusalem", "South Africa Standard Time": "Africa/Johannesburg",
    "Turkey Standard Time": "Europe/Istanbul", "Arabic Standard Time": "Asia/Baghdad",
    "Arab Standard Time": "Asia/Riyadh", "Russian Standard Time": "Europe/Moscow",
    "E. Africa Standard Time": "Africa/Nairobi", "Iran Standard Time": "Asia/Tehran",
    "Arabian Standard Time": "Asia/Dubai", "Azerbaijan Standard Time": "Asia/Baku",
    "Afghanistan Standard Time": "Asia/Kabul", "Pakistan Standard Time": "Asia/Karachi",
    "West Asia Standard Time": "Asia/Tashkent", "India Standard Time": "Asia/Kolkata",
    "Sri Lanka Standard Time": "Asia/Colombo", "Nepal Standard Time": "Asia/Katmandu",
    "Central Asia Standard Time": "Asia/Almaty", "Bangladesh Standard Time": "Asia/Dhaka",
    "Myanmar Standard Time": "Asia/Rangoon", "SE Asia Standard Time": "Asia/Bangkok",
    "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore",
    "Taipei Standard Time": "Asia/Taipei", "W. Australia Standard Time": "Australia/Perth",
    "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
    "Cen. Australia Standard Time": "Australia/Adelaide", "AUS Central Standard Time": "Australia/Darwin",
    "E. Australia Standard Time": "Australia/Brisbane", "AUS Eastern Standard Time": "Australia/Sydney",
    "West Pacific Standard Time": "Pacific/Port_Moresby", "Tasmania Standard Time": "Australia/Hobart",
    "New Zealand Standard Time": "Pacific/Auckland", "Fiji Standard Time": "Pacific/Fiji",
    "Tonga Standard Time": "Pacific/Tongatapu", "Samoa Standard Time": "Pacific/Apia",
}

JOIN_LINK = re.compile(
    r"https://(?:[a-z0-9-]+\.)*(?:teams\.microsoft\.com|teams\.live\.com|zoom\.us|meet\.google\.com|"
    r"whereby\.com|webex\.com|meet\.jit\.si|gotomeeting\.com|chime\.aws)/[^\s\"'<>\\]*", re.I)


def local_zone():
    """The local zone with its DST rules, not just today's offset."""
    names = [os.environ.get("TZ", "").lstrip(":")]
    try:
        names.append(os.path.realpath("/etc/localtime").split("/zoneinfo/", 1)[1])
    except (IndexError, OSError):
        pass
    for name in names:
        if name:
            try:
                return ZoneInfo(name)
            except (ZoneInfoNotFoundError, ValueError):
                continue
    return dt.datetime.now().astimezone().tzinfo


# ---- Fetching --------------------------------------------------------------

class NoDowngrade(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.lower().startswith("https://"):
            raise ValueError("redirect away from https")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(NoDowngrade)


def cache_name(url):
    return hashlib.sha256(url.encode()).hexdigest()[:24] + ".ics"


def normalized(url):
    url = url.strip()
    if url.lower().startswith("webcal://"):
        url = "https://" + url[len("webcal://"):]
    return url


def fetch(url, cache_dir):
    """The calendar's text: downloaded (cached), or read from a local file."""
    url = normalized(url)
    if url.lower().startswith("http://"):
        raise ValueError("plain http refused")
    if not url.lower().startswith("https://"):
        return Path(os.path.expanduser(url)).read_text(encoding="utf-8", errors="replace")

    cached = cache_dir / cache_name(url)
    if cached.exists() and time.time() - cached.stat().st_mtime < FETCH_EVERY:
        return cached.read_text(encoding="utf-8", errors="replace")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "qcenter-agenda"})
        with OPENER.open(request, timeout=20) as response:
            data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError("calendar larger than 20 MB")
        text = data.decode("utf-8", errors="replace")
        if "BEGIN:VCALENDAR" not in text:
            raise ValueError("not an ICS calendar")
        cache_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(cache_dir, 0o700)
        tmp = cached.with_suffix(".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(cached)
        return text
    except Exception:
        if cached.exists():
            return cached.read_text(encoding="utf-8", errors="replace")
        raise


def prune_cache(cache_dir, urls):
    """Copies of calendars no longer in the settings go."""
    keep = {cache_name(normalized(u)) for u in urls}
    if cache_dir.is_dir():
        for path in cache_dir.glob("*.ics"):
            if path.name not in keep:
                path.unlink(missing_ok=True)


# ---- Reading ---------------------------------------------------------------

def unfold(text):
    return re.sub(r"\r?\n[ \t]", "", text).splitlines()


def parse_line(line):
    """'DTSTART;TZID=X:2026…' → ('DTSTART', {'TZID': 'X'}, '2026…')."""
    quoted = False
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == ":" and not quoted:
            parts = line[:i].split(";")
            params = {}
            for part in parts[1:]:
                key, _, val = part.partition("=")
                params[key.upper()] = val.strip('"')
            return parts[0].upper(), params, line[i + 1:]
    return None


ESCAPES = {"n": "\n", "N": "\n", ",": ",", ";": ";", "\\": "\\"}


def unescape(value):
    return re.sub(r"\\([nN,;\\])", lambda m: ESCAPES[m.group(1)], value)


def components(lines):
    """VEVENTs and VTIMEZONEs, each a tree: {"name", "props": [(name, params, value)], "children": [...]}."""
    root = {"name": "", "props": [], "children": []}
    stack = [root]
    for line in lines:
        parsed = parse_line(line)
        if not parsed:
            continue
        name, params, value = parsed
        if name == "BEGIN":
            node = {"name": value.strip().upper(), "props": [], "children": []}
            stack[-1]["children"].append(node)
            stack.append(node)
        elif name == "END":
            if len(stack) > 1:
                stack.pop()
        else:
            stack[-1]["props"].append((name, params, value))
    out = []

    def walk(node):
        for child in node["children"]:
            if child["name"] in ("VEVENT", "VTIMEZONE"):
                out.append(child)
            else:
                walk(child)
    walk(root)
    return out


# ---- Time ------------------------------------------------------------------

def parse_offset(text):
    m = re.fullmatch(r"([+-])(\d{2})(\d{2})(\d{2})?", text.strip())
    if not m:
        raise ValueError("bad offset " + text)
    sign = -1 if m.group(1) == "-" else 1
    return sign * dt.timedelta(hours=int(m.group(2)), minutes=int(m.group(3)), seconds=int(m.group(4) or 0))


class VTimezone(dt.tzinfo):
    """A zone from the calendar's own VTIMEZONE: its STANDARD and DAYLIGHT onsets."""

    def __init__(self, name, observances):
        self.name = name
        self.observances = observances   # [{"daylight", "start", "from", "to", "rrule"}]
        self.standard = next((o["to"] for o in observances if not o["daylight"]),
                             observances[0]["to"] if observances else dt.timedelta(0))
        self.years = {}

    def onsets(self, year):
        if year not in self.years:
            found = []
            end = dt.datetime(year + 1, 1, 1)
            for o in self.observances:
                if o["rrule"]:
                    for when in occurrences(o["start"], o["rrule"], dt.datetime(year, 1, 1), end):
                        if when.year == year:
                            found.append((when, o))
                elif o["start"].year == year:
                    found.append((o["start"], o))
            self.years[year] = sorted(found, key=lambda pair: pair[0])
        return self.years[year]

    def observance(self, wall):
        latest = None
        for year in (wall.year - 1, wall.year):
            for onset, o in self.onsets(year):
                if onset <= wall:
                    latest = o
        if latest is None and self.observances:
            first = min(self.observances, key=lambda o: o["start"])
            return {"to": first["from"], "daylight": False}
        return latest or {"to": self.standard, "daylight": False}

    def utcoffset(self, d):
        return self.observance(d.replace(tzinfo=None))["to"]

    def dst(self, d):
        return self.utcoffset(d) - self.standard

    def tzname(self, d):
        return self.name


def read_vtimezone(node):
    tzid = next((v for n, _, v in node["props"] if n == "TZID"), "").strip()
    observances = []
    for child in node["children"]:
        if child["name"] not in ("STANDARD", "DAYLIGHT"):
            continue
        o = {"daylight": child["name"] == "DAYLIGHT", "rrule": None}
        try:
            for name, params, value in child["props"]:
                if name == "DTSTART":
                    o["start"] = parse_time(value, {}, None)
                elif name == "TZOFFSETFROM":
                    o["from"] = parse_offset(value)
                elif name == "TZOFFSETTO":
                    o["to"] = parse_offset(value)
                elif name == "RRULE":
                    o["rrule"] = parse_rrule(value)
        except ValueError:
            continue
        if isinstance(o.get("start"), dt.datetime) and "to" in o:
            o.setdefault("from", o["to"])
            observances.append(o)
    return tzid, (VTimezone(tzid, observances) if observances else None)


def zone_named(tzid, vtimezones, fallback):
    if not tzid:
        return fallback
    name = tzid.strip().strip('"')
    mapped = WINDOWS_ZONES.get(name, name)
    # Some exporters prefix the IANA name with a path ("/mozilla.org/…/America/Toronto").
    for candidate in [mapped] + ["/".join(mapped.split("/")[-k:]) for k in (2, 3) if mapped.count("/") >= k]:
        try:
            return ZoneInfo(candidate)
        except (ZoneInfoNotFoundError, ValueError):
            continue
    if vtimezones.get(name):
        return vtimezones[name]
    # Outlook display names: "(UTC-05:00) Eastern Time (US & Canada)", a fixed offset at worst.
    m = re.match(r"\(UTC(?:([+-])(\d{2}):(\d{2}))?\)", name)
    if m:
        sign = -1 if m.group(1) == "-" else 1
        return dt.timezone(sign * dt.timedelta(hours=int(m.group(2) or 0), minutes=int(m.group(3) or 0)))
    return fallback


def parse_time(value, params, zone, vtimezones=None):
    """A date (all day), an aware datetime, or a naive one when zone is None."""
    value = value.strip()
    if params.get("VALUE", "").upper() == "DATE" or re.fullmatch(r"\d{8}", value):
        return dt.date(int(value[:4]), int(value[4:6]), int(value[6:8]))
    m = re.fullmatch(r"(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)", value)
    if not m:
        raise ValueError("bad date-time " + value)
    naive = dt.datetime(*map(int, m.groups()[:6]))
    if m.group(7):
        return naive.replace(tzinfo=dt.timezone.utc)
    if zone is None:
        return naive
    return naive.replace(tzinfo=zone_named(params.get("TZID"), vtimezones or {}, zone))


def parse_duration(value):
    m = re.fullmatch(r"([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", value.strip())
    if not m:
        return None
    sign = -1 if m.group(1) == "-" else 1
    w, d, h, mi, s = (int(x or 0) for x in m.groups()[1:])
    return sign * dt.timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)


def key_of(value):
    """Comparable key for RECURRENCE-ID and EXDATE matching."""
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:
            return value.strftime("%Y%m%dT%H%M%S")
        return value.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%S")
    return value.strftime("%Y%m%d")


# ---- Recurrence ------------------------------------------------------------

def parse_rrule(value):
    rule = {}
    for part in value.split(";"):
        key, _, val = part.partition("=")
        rule[key.strip().upper()] = val.strip()
    return rule


def byday_list(text):
    out = []
    for item in filter(None, text.split(",")):
        m = re.fullmatch(r"([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)", item.strip().upper())
        if m:
            out.append((int(m.group(1)) if m.group(1) else None, WEEKDAYS[m.group(2)]))
    return out


def ints(text):
    return [int(x) for x in text.split(",") if re.fullmatch(r"[+-]?\d+", x.strip())]


def month_dates(year, month, byday, bymonthday, start_date):
    days = cal.monthrange(year, month)[1]
    if not byday and not bymonthday:
        return [dt.date(year, month, start_date.day)] if start_date.day <= days else []
    by_monthday = set()
    for n in bymonthday:
        day = n if n > 0 else days + n + 1
        if 1 <= day <= days:
            by_monthday.add(dt.date(year, month, day))
    by_weekday = set()
    for ordinal, weekday in byday:
        found = [dt.date(year, month, d) for d in range(1, days + 1) if dt.date(year, month, d).weekday() == weekday]
        if ordinal is None:
            by_weekday.update(found)
        elif 0 < ordinal <= len(found):
            by_weekday.add(found[ordinal - 1])
        elif -len(found) <= ordinal < 0:
            by_weekday.add(found[ordinal])
    if byday and bymonthday:
        return sorted(by_monthday & by_weekday)
    return sorted(by_monthday | by_weekday)


def period_dates(freq, anchor, rule, start_date):
    """Candidate dates within the period that begins at anchor."""
    byday = byday_list(rule.get("BYDAY", ""))
    bymonthday = ints(rule.get("BYMONTHDAY", ""))
    bymonth = ints(rule.get("BYMONTH", ""))

    if freq == "DAILY":
        dates = [anchor]
    elif freq == "WEEKLY":
        week_start = WEEKDAYS.get(rule.get("WKST", "MO").upper(), 0)
        first = anchor - dt.timedelta(days=(anchor.weekday() - week_start) % 7)
        wanted = [d for _, d in byday] or [start_date.weekday()]
        dates = sorted(first + dt.timedelta(days=(w - week_start) % 7) for w in wanted)
    elif freq == "MONTHLY":
        dates = month_dates(anchor.year, anchor.month, byday, bymonthday, start_date)
    else:
        dates = []
        for month in bymonth or [start_date.month]:
            if not 1 <= month <= 12:
                continue
            if byday or bymonthday:
                dates += month_dates(anchor.year, month, byday, bymonthday, start_date)
            elif start_date.day <= cal.monthrange(anchor.year, month)[1]:
                dates.append(dt.date(anchor.year, month, start_date.day))
        dates.sort()

    if bymonth and freq != "YEARLY":
        dates = [d for d in dates if d.month in bymonth]
    if bymonthday and freq in ("DAILY", "WEEKLY"):
        dates = [d for d in dates if d.day in bymonthday or d.day - cal.monthrange(d.year, d.month)[1] - 1 in bymonthday]
    if byday and freq == "DAILY":
        dates = [d for d in dates if d.weekday() in [w for _, w in byday]]

    setpos = ints(rule.get("BYSETPOS", ""))
    if setpos:
        picked = []
        for pos in setpos:
            if 0 < pos <= len(dates):
                picked.append(dates[pos - 1])
            elif -len(dates) <= pos < 0:
                picked.append(dates[pos])
        dates = sorted(set(picked))
    return dates


def add_months(date, months):
    total = date.year * 12 + date.month - 1 + months
    return dt.date(total // 12, total % 12 + 1, 1)


def occurrences(start, rule, window_start, window_end):
    """Starts of a recurring event from window_start to window_end.

    COUNT counts from the first occurrence, so every period from the start is
    walked; only occurrences inside the window are kept.
    """
    freq = rule.get("FREQ", "").upper()
    try:
        interval = max(1, int(rule.get("INTERVAL") or 1))
    except ValueError:
        interval = 1
    count = int(rule["COUNT"]) if rule.get("COUNT", "").isdigit() else None

    timed = isinstance(start, dt.datetime)
    until = None
    if rule.get("UNTIL"):
        try:
            until = parse_time(rule["UNTIL"], {}, start.tzinfo if timed else None)
            if timed and not isinstance(until, dt.datetime):
                until = dt.datetime.combine(until, dt.time(23, 59, 59), start.tzinfo)
            elif not timed and isinstance(until, dt.datetime):
                until = until.date()
            elif timed and (start.tzinfo is None) != (until.tzinfo is None):
                until = until.replace(tzinfo=start.tzinfo) if start.tzinfo else until.replace(tzinfo=None)
        except ValueError:
            until = None

    start_date = start.date() if timed else start
    clock = start.timetz() if timed else None

    def at(date):
        if clock is None:
            return date
        # Wall time in the event's zone, so 9:00 stays 9:00 across DST.
        return dt.datetime.combine(date, clock.replace(tzinfo=None), start.tzinfo)

    def inside(when):
        return when >= window_start

    # The first occurrence is DTSTART, whether or not it fits the rule.
    produced, kept = 1, 0
    if start <= window_end and inside(start):
        kept += 1
        yield start
    if count is not None and count <= 1:
        return

    # HOURLY and MINUTELY: steps of absolute time, skipping straight to the window.
    if freq in ("HOURLY", "MINUTELY") and timed:
        step = dt.timedelta(hours=interval) if freq == "HOURLY" else dt.timedelta(minutes=interval)
        utc = dt.timezone.utc
        origin = start.astimezone(utc) if start.tzinfo else start
        low = window_start.astimezone(utc) if start.tzinfo else window_start.replace(tzinfo=None)
        k = max(1, int((low - origin) / step))
        while kept < MAX_IN_WINDOW:
            when = origin + k * step
            when = when.astimezone(start.tzinfo) if start.tzinfo else when
            if (count is not None and k + 1 > count) or (until is not None and when > until) or when > window_end:
                return
            if inside(when):
                kept += 1
                yield when
            k += 1
        return
    if freq not in ("DAILY", "WEEKLY", "MONTHLY", "YEARLY"):
        return

    anchor = {"DAILY": start_date, "WEEKLY": start_date, "MONTHLY": start_date.replace(day=1),
              "YEARLY": start_date.replace(month=1, day=1)}[freq]
    last_day = window_end.date() if isinstance(window_end, dt.datetime) else window_end
    for step in range(MAX_PERIODS):
        if freq == "DAILY":
            period = anchor + dt.timedelta(days=step * interval)
        elif freq == "WEEKLY":
            period = anchor + dt.timedelta(weeks=step * interval)
        elif freq == "MONTHLY":
            period = add_months(anchor, step * interval)
        else:
            period = dt.date(anchor.year + step * interval, 1, 1)
        if period > last_day:
            return
        for date in period_dates(freq, period, rule, start_date):
            if date < start_date:
                continue
            when = at(date)
            if when == start:
                continue
            if (until is not None and when > until) or when > window_end:
                return
            produced += 1
            if inside(when):
                kept += 1
                yield when
            if (count is not None and produced >= count) or kept >= MAX_IN_WINDOW:
                return


# ---- Events ----------------------------------------------------------------

def read_events(text, name, color, window_start, window_end):
    zone = local_zone()
    nodes = components(unfold(text))
    vtimezones = {}
    for node in nodes:
        if node["name"] == "VTIMEZONE":
            tzid, tz = read_vtimezone(node)
            if tzid and tz:
                vtimezones[tzid] = tz

    masters, overrides = [], {}
    for node in nodes:
        if node["name"] != "VEVENT":
            continue
        event = {"exdates": set(), "exdays": set(), "rdates": []}
        for prop, params, value in node["props"]:
            try:
                if prop == "DTSTART":
                    event["start"] = parse_time(value, params, zone, vtimezones)
                elif prop == "DTEND":
                    event["end"] = parse_time(value, params, zone, vtimezones)
                elif prop == "DURATION":
                    event["duration"] = parse_duration(value)
                elif prop == "SUMMARY":
                    event["title"] = unescape(value)
                elif prop == "UID":
                    event["uid"] = value.strip()
                elif prop == "RRULE":
                    event["rrule"] = parse_rrule(value)
                elif prop == "EXDATE":
                    for item in value.split(","):
                        when = parse_time(item, params, zone, vtimezones)
                        (event["exdates"] if isinstance(when, dt.datetime) else event["exdays"]).add(key_of(when))
                elif prop == "RDATE" and params.get("VALUE", "").upper() != "PERIOD":
                    event["rdates"] += [parse_time(item, params, zone, vtimezones) for item in value.split(",")]
                elif prop == "RECURRENCE-ID":
                    event["recurrence"] = key_of(parse_time(value, params, zone, vtimezones))
                elif prop == "STATUS":
                    event["cancelled"] = value.strip().upper() == "CANCELLED"
                elif prop in ("URL", "LOCATION", "DESCRIPTION", "X-MICROSOFT-SKYPETEAMSMEETINGURL",
                              "X-GOOGLE-CONFERENCE"):
                    m = JOIN_LINK.search(unescape(value))
                    if m and "join" not in event:
                        event["join"] = m.group(0).rstrip(").,;:!?]")
            except (ValueError, OverflowError):
                continue
        if "start" not in event:
            continue
        if "recurrence" in event:
            overrides.setdefault(event.get("uid", ""), {})[event["recurrence"]] = event
        else:
            masters.append(event)

    out = []

    def length_of(event, fallback=None):
        start = event["start"]
        if "end" in event and type(event["end"]) is type(start):
            length = event["end"] - start
            if length >= dt.timedelta(0):
                return length
        if event.get("duration") is not None:
            return event["duration"]
        if fallback is not None:
            return fallback
        return dt.timedelta(days=1) if not isinstance(start, dt.datetime) else dt.timedelta(0)

    def emit(event, start, length):
        if event.get("cancelled"):
            return
        all_day = not isinstance(start, dt.datetime)
        end = start + length
        if all_day:
            if end <= window_start.date() or start >= window_end.date():
                return
        elif end <= window_start or start >= window_end:
            return
        out.append({"title": event.get("title", ""), "start": start.isoformat(), "end": end.isoformat(),
                    "allDay": all_day, "color": color, "calendar": name, "join": event.get("join", "")})

    def sort_time(when):
        return (when if isinstance(when, dt.datetime) else
                dt.datetime.combine(when, dt.time(), dt.timezone.utc)).timestamp()

    for event in masters:
        # One bad series must not take the rest of the calendar with it.
        try:
            moved = overrides.pop(event.get("uid", ""), {})
            start = event["start"]
            length = length_of(event)
            timed = isinstance(start, dt.datetime)
            # An occurrence that started before the window may still be running in it.
            lo = (window_start - length - dt.timedelta(days=1)) if timed else (window_start.date() - length - dt.timedelta(days=1))
            hi = window_end if timed else window_end.date()
            if "rrule" in event or event["rdates"]:
                starts = list(occurrences(start, event["rrule"], lo, hi)) if "rrule" in event else [start]
                starts += [d for d in event["rdates"] if type(d) is type(start)]
                seen = set()
                for when in sorted(starts, key=sort_time):
                    key = key_of(when)
                    if key in seen or key in event["exdates"] or key_of(when.date() if timed else when) in event["exdays"]:
                        continue
                    seen.add(key)
                    if key in moved:
                        replacement = moved.pop(key)
                        emit(replacement, replacement["start"], length_of(replacement, length))
                    else:
                        emit(event, when, length)
                for replacement in moved.values():
                    emit(replacement, replacement["start"], length_of(replacement, length))
            else:
                emit(event, start, length)
        except Exception:
            continue
    # Moved occurrences whose series is not in the file.
    for moved in overrides.values():
        for replacement in moved.values():
            try:
                emit(replacement, replacement["start"], length_of(replacement))
            except Exception:
                continue
    return out


def sort_key(event):
    if event["allDay"]:
        return (0, event["start"], event["title"])
    return (1, dt.datetime.fromisoformat(event["start"]).timestamp(), event["title"])


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", required=True)
    parser.add_argument("--days", type=int, default=DAYS_AHEAD)
    args = parser.parse_args()

    try:
        data = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as error:
        sys.exit("qcenter-agenda: bad input: %s" % error)
    calendars = data.get("calendars") if isinstance(data, dict) else None
    calendars = [c for c in calendars if isinstance(c, dict) and c.get("url")] if isinstance(calendars, list) else []

    output = Path(os.path.expanduser(args.output))
    cache_dir = output.parent / "cache"
    now = dt.datetime.now(local_zone())
    window_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    window_end = window_start + dt.timedelta(days=args.days + 1)

    events, failed = [], 0
    for index, entry in enumerate(calendars):
        name = str(entry.get("name") or "calendar %d" % (index + 1))
        try:
            events += read_events(fetch(str(entry["url"]), cache_dir), name, str(entry.get("color") or ""),
                                  window_start, window_end)
        except Exception as error:
            failed += 1
            # The name only: the link may carry a private token.
            print("qcenter-agenda: %s: %s" % (name, type(error).__name__), file=sys.stderr)
    prune_cache(cache_dir, [str(c["url"]) for c in calendars])

    # Every calendar failed: keep the last agenda rather than show an empty day.
    if calendars and failed == len(calendars) and output.exists():
        sys.exit(1)
    events.sort(key=sort_key)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=output.parent, prefix=".agenda-")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump({"generated": now.isoformat(timespec="seconds"), "events": events}, handle,
                  ensure_ascii=False, indent=1)
        handle.write("\n")
    os.replace(tmp, output)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
