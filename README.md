<p align="center">
  <img src="assets/logo.png" width="128" alt="qCenter owl">
</p>

<h1 align="center">qCenter</h1>

<p align="center">A Mac-style notification center for <a href="https://omarchy.org">Omarchy</a>, in your theme's colors.</p>

<p align="center"><a href="README.fr.md">Version française</a></p>

![qCenter on Tokyo Night](docs/center.png)

**Coming from macOS?** qCenter is the Notification Center, with the calendar of the Today
view; the bell does what clicking the clock does on a Mac. From Windows: the notification
panel with its calendar. It pairs with [qDock](https://github.com/quebecstudio-mods/omarchy-qdock), the Dock, and [qExposé](https://github.com/quebecstudio-mods/omarchy-qexpose),
Exposé and Mission Control.

- **What you missed, in one place.** Omarchy's bubbles fade after a few
  seconds; the ones that faded on their own, or that Do Not Disturb kept off
  the screen, wait here, grouped by app, newest first. Bubbles still on screen
  are outlined. Web notifications are told apart by
  site: Teams, Gmail and Outlook each get their own group, not one "Chrome".
- **Built on Omarchy's own notifications**, not in their place: qCenter reads
  what Omarchy already records. Of its own, it keeps only what you cleared,
  and today's agenda with copies of your calendars, in
  `~/.local/state/qcenter/`. Omarchy's bubbles, sounds and rules stay as they
  are.
- **Click to go there.** A notification opens the command it came with, or
  brings its app's window forward, or opens its site.
- **Do Not Disturb**, one switch at the top. Notifications it holds back are
  in the center when you look.
- **Today's agenda** from your calendars: Google, Outlook, iCloud, Fastmail or
  any ICS link or file, with a **Join** button for Meet, Teams and Zoom calls.
- **A bell for the bar**, with the number waiting.
- **Two styles.** Mac (round corners, frosted glass) or Omarchy (your theme's
  corners, opaque).
- **English and French**, following Omarchy's language.

| Omarchy style | En français |
| --- | --- |
| ![Omarchy style](docs/omarchy-style.png) | ![French](docs/french.png) |

## Install

```bash
omarchy plugin add https://github.com/quebecstudio-mods/omarchy-qcenter --enable
```

The bell lands on the right of the bar. To open the center from the keyboard,
add a binding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + N", "Notification center", "omarchy-shell -q quebecstudio.qcenter toggle")
```

### Frosted glass

In the Mac style, the panel is translucent. For the blur behind it, add this
rule to `~/.config/hypr/hyprland.lua`:

```lua
hl.layer_rule({ match = { namespace = "^qcenter$" }, blur = true, ignore_alpha = 0.2 })
```

## Settings

In qCenter's entry under `plugins` in `~/.config/omarchy/shell.json`:

```json
{
  "id": "quebecstudio.qcenter",
  "style": "mac",
  "calendars": [
    { "name": "Work", "color": "#7aa2f7", "url": "https://calendar.google.com/calendar/ical/…/basic.ics" },
    { "name": "Home", "color": "#9ece6a", "url": "~/Calendars/home.ics" }
  ]
}
```

| Setting | Values | Default |
| --- | --- | --- |
| `style` | `"mac"`, `"omarchy"` | `"mac"` |
| `calendars` | A list of `{ name, color, url }`: an `https://` or `webcal://` link, or the path of an `.ics` file | none |
| `agendaFile` | The path of an agenda JSON you keep up to date yourself (see below); replaces `calendars` | none |

Without `calendars` or `agendaFile`, there is no agenda section.

### Calendars

Every calendar app can publish a private ICS link: in Google Calendar,
*Settings › your calendar › Secret address in iCal format*; in Outlook,
*Settings › Calendar › Shared calendars › Publish a calendar*; in iCloud, share
the calendar as a public calendar. qCenter fetches each link at most every
five minutes (every ten in the background), keeps a copy for when you are
offline, and handles time zones and recurring events. It needs only Python,
which Omarchy ships.

The links are secrets: anyone who has one can read the calendar. They stay in
your `shell.json`, qCenter never puts them on a command line, and it fetches
them only over https: a plain `http://` link is refused.

### Your own agenda file

If your calendar has no ICS link, have any script write this JSON and point
`agendaFile` to it; qCenter reloads it when it changes:

```json
{
  "events": [
    { "title": "Design review", "start": "2026-11-11T10:00:00-05:00", "end": "2026-11-11T11:00:00-05:00",
      "color": "#7aa2f7", "join": "https://meet.google.com/abc-defg-hij" },
    { "title": "Sprint week", "start": "2026-11-11", "end": "2026-11-12", "allDay": true }
  ]
}
```

`start` and `end` are ISO 8601 dates, or plain dates for all-day events (`end`
excluded). `color`, `join` (an `https://` link) and `allDay` are optional.

## Commands

```bash
omarchy-shell -q quebecstudio.qcenter toggle
omarchy-shell -q quebecstudio.qcenter open
omarchy-shell -q quebecstudio.qcenter close
omarchy-shell quebecstudio.qcenter count        # notifications waiting
omarchy-shell -q quebecstudio.qcenter syncAgenda   # fetch the calendars now
```

## Good to know

- qCenter needs Omarchy's own notifications, the built-in `notifications`
  plugin, enabled as it is by default: nothing to uninstall or turn off
  first. If you replaced them with another notification daemon (mako, swaync,
  dunst), qCenter has nothing to read.
- **✕** removes notifications from the center; a bubble still on screen stays
  until it fades or you close it. **Clear all** also closes every bubble.
- Clicking the newest bubble's card does what clicking the bubble does,
  including the app's own action.
- Omarchy keeps its notification history for 24 hours, 100 entries at most;
  qCenter shows what is in it.
- qCenter reads Omarchy's files in `~/.local/state/omarchy/notifications/`. If
  a future Omarchy changes their format, the center may come up empty until
  qCenter catches up.

## Works with

- [qDock](https://github.com/quebecstudio-mods/omarchy-qdock), a Mac-style dock.
- [qExposé](https://github.com/quebecstudio-mods/omarchy-qexpose), Exposé and
  Alt+Tab with previews.

## License

MIT © Québec Studio. Window routing adapted from Omarchy's notification service (MIT), which
began as [Omapager](https://github.com/omacom/omapager) by Neil Jagdish Patel.

macOS, Mission Control and Exposé are trademarks of Apple Inc. This project is not affiliated with or endorsed by Apple.
