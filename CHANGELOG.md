# Changelog

## 1.1.0 - 2026-11-12

### Added

- **A settings window**, drawn with Omarchy's own controls: Appearance, Notifications, Left out, Apps for sites, Agenda and About. Open it from the gear at the top of the center, from the app launcher (qCenter Settings) or with `omarchy-shell -q quebecstudio.qcenter settings`. Calendars are added there with a masked link, and apps for sites picked from the launcher's list.
- **Four styles**, qDock's: Omarchy, Cupertino, Redmond and Plasma.
- **Confirmations stay out of the center.** Low-urgency notifications (a screenshot saved, a layout changed, copied to the clipboard) still show as bubbles but no longer pile up in the center; turn `lowUrgency` on to keep them.
- **Leave apps out** (`hiddenApps`): their bubbles still show, the center skips them.
- **Apps for sites** (`webApps`): a website's notification opens its web app, or the app you chose for it, rather than the browser.

### Changed

- **`style` `"mac"` is now `"cupertino"`**; the old name still reads. Cupertino stays the default.
- A notification without an icon takes its app's icon from the launcher, else a plain bell, instead of its initial.

### Fixed

- A one-line notification is no longer shorter than its icon.

## 1.0.0 - 2026-11-11

First release.
