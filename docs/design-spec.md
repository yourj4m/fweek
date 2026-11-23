# Design spec

Measured reference for the planner UI. Values were taken on 2026-11-13 from the
publicly served Tweek web app (demo planner on the home page, logged out) with
the scripts in `tools/analysis/`: `rea` for passive page and bundle inspection,
a small CDP driver for interactions, computed-style dumps at 17 viewport sizes,
and the four public stylesheets.

Ground rules for using this document:

- It records **measurements and behaviour**, which this project reimplements
  from scratch. No code, stylesheet, image, icon, font, logo, mascot or UI copy
  from the reference app is used in this repository. Captures live in the
  git-ignored `reference/` folder.
- The reference typeface (Suisse Int'l) and icon set (Font Awesome Pro) are
  commercial. This project uses **Inter** and **Lucide** instead; see
  [Substitutions](#substitutions).
- Each section says how it was established: **live** (observed in the demo),
  **css** (read from stylesheet rules, not seen rendered), or **slide** (seen
  only in the product's own illustration of a paid feature).

All sizes are CSS pixels at device pixel ratio 1.

## 1. Tokens

### Colour (live)

| Role | Light | Dark |
| --- | --- | --- |
| Background | `#FFFFFF` | `#000000` |
| Text | `#000000` | `#FFFFFF` |
| Accent (today, focus, selection) | `#5167F4` | `#5167F4` |
| Row hover rule | accent at 40 % (`#5167F466`) | same |
| Ruled line | text at 10 % | text at 10 % |
| Round nav buttons | `#27282B` bg in theme vars, renders `#000` / white icon | same |
| Account button | `#BE9CF3` bg, black icon | same |
| Task dialog surface | `#FFFFFF` (tinted by task colour) | `#202023` |
| Popover surface | `rgba(239,239,239,.9)` + 6 px backdrop blur | `rgba(32,32,35,.9)` |
| Dialog backdrop | black at 40 % | black at 60 % |
| Danger | `#DF525F`, pressed `#CD2C54` | same |
| Scrollbar thumb | text at 30 % | text at 30 % |

Neutral ramp: the text colour at 5, 10, 15, 20, 25, 40, 50, 60, 75, 90 %
opacity. Dark mode swaps the black and white ramps (the 5–25 % steps become
12, 15, 20, 25, 30 % white).

Task highlight colours (named in the stylesheet): pink/red `#E00052`
(`#CD2C54` in the newer ramp), yellow `#FDEF5D`, cornflower `#5167F4`,
lavender `#DDE1FB`, green `#22FFA1`, mango `#FFB022`, grey `#C2C2C2`,
lilac `#D85DFD`, cyan `#98F4F9`, purple `#BE9CF3`, black `#000`.
Text on cornflower, black and pink is white; on the others black.
The logged-out demo offers two (red, yellow); the rest sit behind the paywall.

### Type scale (live + css)

| Token | Size / line height | Used for |
| --- | --- | --- |
| 36 | 36 / 48, weight 700, tracking −1 px | Page title, desktop |
| 31 | 31 / 40, weight 700, tracking −1 px | Page title, below 1024 px |
| 28 | 28 / 34, weight 700 | Task dialog title |
| 24 | 24 / 28 | Large headings in sheets |
| 21 | 21 / 28 | Day header, desktop (date 700 with −0.5 px tracking, weekday 400) |
| 18 | 18 / 28 | Day header, below 1024 px |
| body 17 | 17 / 22 | Buttons (700), menu items, notes |
| 16 | 16 / 22 | Task text below 1024 px |
| 15 | 15 / 20 | Small buttons, secondary labels |
| 14 | 14 / 22 | Task text on desktop; captions 14 / 20 |
| 12 | 12 / 18 | Badges, calendar weekday initials |

Two weights only: 400 and 700.

### Shape, size, motion (css)

- Radii: 6, 12, 16, 24, pill. Menus 16, menu items 8, toolbars 10, dialog card 24.
- Control heights: 22 (compact), 32 (small), 36 (inline), 40 (medium), 44 (large); list cell 52.
- Icons: 16, 20, 24.
- Menu shadow: `0 8px 16px rgba(0,0,0,.1)`.
- Durations: 0.1 s (fast) and 0.2 s (medium), `ease`. Hover-in is instant
  (0 s), hover-out uses the fast duration. Slide distance for entering sheets: 16 px.
- Reduced motion: animations collapse to 0 s.

## 2. Layout

One breakpoint: **1024 px**.

### Desktop, ≥ 1024 px (live)

- Page padding 24 px on all sides.
- **Header**, 48 px tall: title "November 2026" (36/48 bold), then the week
  number "W46" 12 px to its right at 20 % opacity, fading out at its right edge.
  Right-aligned toolbar of 40 px round buttons with 6 px gaps: account,
  previous, next (black, white 20 px chevrons). 72 px gap below the header.
- **Week grid**: six equal columns (each 1/6 of the content width plus the
  gutter), 24 px between column contents. Columns 1–5 are Monday–Friday;
  column 6 stacks Saturday above Sunday with a 42 px gap.
- **Day column**: header 42 px tall (28 px text + 12 px padding + 2 px rule in
  text colour). Date left ("9 Nov", bold), weekday right ("Mon", 30 % opacity).
  Today: date, label and rule in the accent colour, label reads "Today" at
  full opacity.
- **Rows**: 42 px each, separated by a 1 px rule at 10 %. Minimum 10 rows for
  a weekday, 4 for each weekend day; a column grows when it holds more tasks.
  The grid does not stretch with window height (minimum height 462 px).
- **Someday area**: 32 px below the week grid. Three equal columns with the
  same 24 px spacing. Each has a 53 px heading (21 px bold, 1 px rule below);
  the first is titled "Someday", the others are untitled until named. Rows as
  above, 2 by default.
- An "About" pill button floats bottom right in the demo (not needed here).
- Edge zones: while dragging, a 34 × 200 px rounded tab peeks in from the left
  and right screen edges (text colour at 10 %, 25 % and 1.15× scale when the
  pointer is over it); holding a task there flips to the previous/next week.

### Narrow, < 1024 px (live)

- Header is sticky, 16 px padding, title 31/40 and abbreviated ("Nov 2026"),
  over a background that fades to transparent at the bottom.
- Days stack in one column with 24 px side padding and 24 px between days.
  Each day shows its tasks plus one empty row (two for today); day header 18/28.
- Task text 16/22. The check button is always visible.
- Someday follows the last day, 48 px bottom padding.
- The task dialog becomes a bottom sheet with 24 px top corners.

### Phone app (store pictures and help pages, not a running app)

The reference's phone apps are native, not the web page in a wrapper, and
differ from the narrow web layout. Nothing below comes from running them:
the sources are the stores' promotional pictures (designed mock-ups, 1290 px
wide), a 2024 screen recording of the older iPhone app, and the public help
pages. Notes and the pictures are in the git-ignored `reference/mobile/`.

| Element | Reference phone app | Narrow web layout | Here, on a phone |
| --- | --- | --- | --- |
| Arrangement | one column of days, then Someday, under a pinned top bar | same | same |
| Row pitch | about 50 dp (12.8 % of the width) | 42 px | 50 |
| Task text | about 17.5 sp | 16 | 17 |
| Side margin | 16 dp | 24 | 16 |
| Day header | bold date about 22 sp, pale weekday, 2 dp rule | 18 | 21 |
| Highlight pill | 27 dp tall, hugging the text | 22 | 27 |
| Top-bar buttons | 40 dp circles, 6 dp apart | same | same |
| Task card | bottom sheet tinted by the task colour | bottom sheet | bottom sheet |

Behaviour taken from the help pages: tap an empty line to type and Return for
the next task; tap the circle to complete; press and hold to drag, to the
screen edge to change week; tap the title to return to today, and from the
current week to open the month.

Choices of this project where the sources were silent or it seemed better:

- A sideways swipe turns the week (no source mentions one).
- The week opens scrolled to today.
- Reminders, repeats, subtasks and the month view are not paid features.
- Not built: the day view, the floating view switcher with its "+" button,
  swipe-free quick add for today, undo after delete, the home-screen widget.

## 3. Components

### Task row (live + css)

- 42 px tall, 35 px right padding reserved for the check button.
- Text sits in a pill: 22 px line height, 6 px horizontal padding, 11 px
  radius, 10 px above and below. Uncoloured tasks have a transparent pill, so
  text starts 6 px in from the column edge. Single line, ellipsis when too long.
- Coloured task: the pill is filled with the task colour (a highlighter mark
  that hugs the text, not the full row).
- Optional leading glyphs inside the pill, 12 px, 4 px gap: bell (has
  reminder), circular arrow (recurring), note mark (has notes) — **slide/css**.
- A set time is shown as a text prefix ("12:00 PM Set a time").
- Hover: bottom rule turns accent at 40 %; a 22 px circled-check button fades
  in at the right (0.2 s). Cursor: pointer on the row, grab on the text.
- Done: text struck through at 30 % opacity; the check is filled and at 30 %.
- Selected (multi-select): 2 px accent ring around the pill. A group being
  dragged shows a count badge (accent, 20 px, 12 px semibold) — **css**.

### Empty row / add task (live)

- Every empty ruled row is an input. Hover shows the same accent rule.
- Focus raises a card over the row: 8 px wider on each side and 2 px taller,
  4 px radius, shadow `0 1px 4px 1px rgba(0,0,0,.11)`, background surface.
- Enter saves and moves focus to the next empty row (rapid entry). Escape
  leaves the input.

### Task dialog (live)

- Centred card, **512 px** wide, 24 px radius, over the dimmed page; 32 px
  inner padding at the sides. Tinted with the task colour when one is set
  (**slide**: the whole card turns yellow).
- Top row: calendar icon + date button ("Sat, 14 Nov 2026"), a clock button
  for the time, and at the right "Expand" (grey) which grows the card to fill
  the window with a 696 px text column and a "Compact" button to return; the
  expanded view also has a "Next task" arrow bottom right.
- Title: 28 px bold, multi-line, with a 44 px ghost "completed" toggle at the
  right. A 1 px rule below.
- Notes: rich text with placeholder "Add some extra notes here…" (17 px, 25 %).
  Formatting observed in the stylesheet: bold, italic, strike, links,
  blockquote, lists — **css**.
- Footer: five 44 px ghost icon buttons spread evenly — subtasks, repeat,
  colour, reminder, more. The active one has a black-5 % circle.
- **Colour** opens a small popover above the button: 36 px round swatches;
  the selected one shows a check.
- **Date** opens a 288 × 324 popover: month title with previous/next
  chevrons, weekday initials (12 px, muted), 6 × 7 day grid of ~38 px cells,
  selected day as a black disc with white text, other-month days muted.
- **Time** opens a 160 × 400 popover: an editable time field on top, then a
  scrolling list in 30-minute steps (36 px rows), 12- or 24-hour by setting.
- **More** opens a 204 px menu (36 px items, icon + label): Attach file,
  Move ›, Copy ›, Delete (danger colour).
- Escape or a click on the backdrop closes the dialog. Changes save as typed.

### Paid-tier screens (slide + css; not observed live)

- **Subtasks**: a checklist under the notes. Circle checkbox, text, optional
  star marker for "important"; completed items struck and muted; plain lines
  act as section headings; items can be indented one level; reorder by drag.
- **Repeat** menu: Never, Daily, Weekly, Weekdays, Biweekly, Monthly,
  Annually, Custom ›. Custom editor: "every N" + unit (day / week / month /
  year); for months a day-of-month grid plus "on the same day" or "every
  second Friday" style options; for years a month grid; "Ending" (never, or a
  date); a plain-language summary line; Apply.
- **Reminder**: date + hour + minute picker with a "Set Reminder" button;
  delivery by notification.
- **Colours**: a row of swatches (none, red, yellow, black, grey, blue,
  orange, green, purple, cyan, …) plus "add colour", which opens a
  hue/saturation square with a hex field and Save. Colours can be named.
- **Themes**: about eight whole-app colour themes (white, black, pale blue,
  pink, cream, yellow, beige, …), each restyling background, text and accent.
- **Month view**: a 7-column month grid; each day lists its tasks as small
  coloured chips with a "N more" overflow line; today's number in an accent
  disc. A three-way switch chooses month / week / day.
- **Day view**: a single day as a full-width list.
- **Search**: opened with Ctrl+F; a search field, a row of colour filter
  dots, and a flat list of matching tasks with their check buttons.
- **Settings → completed tasks**: three switches — move unfinished tasks to
  the next day, sort completed tasks down, hide tasks after completion.
- **Other settings** (help pages): date format (DD-MM / MM-DD), language,
  12/24-hour time, week start.
- **Export**: XML, TXT, CSV, ICS.

## 4. Behaviour (live unless noted)

- Click a task: opens the task dialog. Click an empty row: start typing.
- Click the check: toggles done.
- Drag a task (pointer down on its text and move): the row's text follows the
  pointer with no card or shadow; the source row closes up; rows at the target
  open a 42 px gap. Drop into any day or Someday list, at any position. Drag
  to a screen-edge tab to move it to another week.
- Previous / next buttons and the Left / Right arrow keys change week;
  `T` returns to the current week; Ctrl+F opens search; Escape closes the
  topmost dialog or popover. Shortcuts are ignored while typing — **help pages**.
- Clicking the page title returns to today (title dims to 75 % on hover).
- Unfinished tasks from past days roll over to today when the option is on —
  **help pages**.
- Keyboard drag is supported (space to pick up, arrows to move, escape to
  cancel) — announced by the page's accessibility text.

## 5. Substitutions

| Reference | Here | Why |
| --- | --- | --- |
| Suisse Int'l (Book, Bold) | Inter (400, 700), OFL | Commercial font; Inter is the closest open neo-grotesque. Tracking is tightened to match the reference's compact headings. |
| Font Awesome 5 Pro | Lucide, ISC | Commercial icon set. |
| Name, logo, mascot, onboarding text | Own name and icon, own wording | Trademarks and trade dress are reserved by the reference app's terms. |
| Firebase backend, accounts | Local SQLite, optional file sync | Local-first by design. |

## 6. Gaps

- Paid-tier screens were specified from product illustrations and stylesheet
  rules, never from a running paid account. Exact spacing inside the repeat
  editor, reminder picker, month view and settings is therefore approximate.
- Themes other than the default light and dark were not captured; this
  project defines its own.
- Rich-text notes, attachments, sharing and calendar-provider sync were not
  analyzed in depth.
- rea's static bundle analysis timed out on the two large scripts at its
  default 30 s per-script limit and was not rerun; nothing in this spec
  depends on it.

## 7. Where this project departs from the reference

Sections 1 to 6 record what was measured. This one records what the planner
does differently by now, and why, so that the two are not confused.

### Highlight colours

The measured palette has four colours at or near full strength beside pale
ones (green `#22FFA1`, lilac `#D85DFD`, yellow `#FDEF5D`, cyan `#98F4F9`);
on a page of several coloured tasks those shout over the rest. The keys that
tasks store are kept, the tones are evened out to a similar, moderate
strength:

| Key | Was | Is | Text |
| --- | --- | --- | --- |
| red | `#CD2C54` | `#C8405C` | white |
| yellow | `#FEEE5D` | `#F3DC6B` | black |
| blue | `#5167F4` | `#5568D8` | white |
| green | `#23FFA1` | `#7FD8A6` | black |
| orange | `#FFB022` | `#F1A85B` | black |
| purple | `#BE9CF3` | `#B8A3EC` | black |
| lilac | `#D85DFD` | `#D98BD3` | black |
| cyan | `#98F4F9` | `#9BDCE5` | black |
| lavender | `#DCE1FD` | `#D9DEFA` | black |
| grey | `#C2C2C2` | `#C6C6CA` | black |
| black | text colour of the theme | same | theme background |

Rules the tests hold them to (`test/theme/contrast_test.dart`): text on each
at 4.5 : 1 or better; any two at least 40 apart in RGB; none with a
saturation above 0.72; each told from the page of every theme.

### Themes

Twelve, offered in three rows: light (Light, Paper, Ice, Rose, Sage), dark
(Dark, Slate) and semi-dark. A semi-dark theme is a deep, muted colour
instead of black, an off-white tinted the same way for text, and a soft
accent of the same family:

| Theme | Page | Text | Accent | Card |
| --- | --- | --- | --- | --- |
| Wine | `#2A1519` | `#F5E9EA` | `#E58A9B` | `#3A2025` |
| Plum | `#221A2E` | `#EFEAF6` | `#B9A2EA` | `#312641` |
| Forest | `#14231C` | `#E8F1EA` | `#86C9A0` | `#1F3329` |
| Midnight | `#121B2B` | `#E8EDF6` | `#8FB0F0` | `#1D2A40` |
| Cocoa | `#261D17` | `#F3EBE3` | `#E0A873` | `#362A21` |

Every theme: text on page, card and menu at 7 : 1 or better; the muted text
(60 % step) at 4.5 : 1; accent on page at 3 : 1.

### Calendar events

- **Row**: a task row with a 3 px bar in the calendar's colour at its left
  (height: pill − 6, or row − 16 when there is a second line). Everything
  else as for a task, including the check circle. A colour given to the
  event by the user fills its pill; the bar stays the calendar's.
- **Band**: events over several days lie directly under the day headings,
  above all rows. One lane per event that overlaps, 24 px bars (30 on a
  phone) with 4 px between and 6 px above the first. A bar is a wash of the
  calendar's colour (18 % on light, 26 % on dark pages) with the 3 px bar at
  its start, radius 6, square at an end where the event goes on beyond the
  week. In the desktop week the band spans the six columns; Sunday, stacked
  under Saturday, repeats its bars under its own heading on full ruled rows
  so that the grid still lines up. In the single-column week every day
  shows its bars under its heading with "2/3" for the second of three days.
  In the month, bars sit at the top of each cell, flush with the cell's edge
  where the event continues, titled once per row.
- **Card**: the task card, with a line saying which calendar the event is
  from and its own times, the calendar's description below the user's notes,
  and "Edited · Reset" once anything was changed.

### Rows

Beside title and time a row shows, in muted ink after the pill: a note mark,
subtasks as done/total, and for hidden events an eye-off mark. A place is a
second line under the title (11.5 px, 13 on a phone), only when there is one.
Done tasks and hidden events are drawn at 30 % by their colours.

### Today

The 2 px rule under today's heading is a 3 px bar instead: accent at 22 % as
the track, accent as the part of the day that has passed. In the month, a
2 px bar at the top of today's cell. No number, no clock.

### Menus

Right-click (long press and release on a phone) on a task, an event, a band
bar or a month chip: Open, Mark as done · Move to, Time, Colour, Note, Place
(Open map) · Duplicate / Delete for tasks, or Make a task, Reset, Hide, Hide
calendar for events. 248 px wide, rows 36 px (44 on a phone). On a phone the
menu surface is opaque: no backdrop blur there.

### Phone: editing bar

While a line has the keyboard: a 48 px bar above it, the surface of a card,
with a rule on top. Round 40 px buttons for Time, Place, Note, Colour and
All details, and a filled Done button at the right. A button shows what is
attached (the time, the place's name, a colour dot) and opens its panel in
place above the bar: wheels for hours and minutes, the place field with its
suggestions, a note field, the colour swatches.

### Lists: a page of their own

The reference keeps its lists ("Someday") under the week. Here they have a
page of their own, and the week takes the whole window: as many ruled rows
as reach its bottom (at least 4), the two weekend days sharing their column
half and half.

- **Tasks page**, wide: a header like the week's ("Tasks", the number still
  to do at 20 %), 28 px, then every list as a column, 24 px apart, 220 to
  360 px wide; heading 53 px (21 px bold, an unnamed list at 55 %), ruled
  rows to the bottom of the window, then a 42 px line "n done" (14 px,
  45 %) that opens the done tasks in the place of blank rows. With room for
  one more column, a blank one reads "+ New list" (30 %, 60 % under the
  pointer).
- When the lists do not all fit at 220 px: their names in a 216 px column
  at the left (rows 40 px, 15 px text, the open one bold on 8 % ink, counts
  at 40 %), the open list beside them, at most 640 px wide.
- On a phone (and below 560 px): the names as tabs in a 48 px strip (15 px,
  the open one bold over a 2 px rule), "+" after them and the open list's
  menu at the right; the lists are pages, swiped sideways.
- A task with a day says so after its title (11.5 px medium, 50 %; today in
  the accent colour). A deadline is a flag with its date (red once passed);
  in the week only the flag, and a flag in the heading of the day it is due.
- **Phone bar**: 56 px at the bottom, a rule on top; two tabs (icon 22 px
  over a 12 px label), the open one in the text colour and bold, the other
  at 45 %. Hidden while the keyboard is up.
- **Phone top bar**: the month in full (24 px bold) over the year and the
  week's number (14 px, 50 %), instead of the abbreviated one-line title.
- **Panel beside the week** (windows from 1240 px): 280 px plus padding at
  the right, a 1 px rule at its left; "Lists" (24 px bold) level with the
  week's title, and at its right the one button that shuts the panel; each
  list a heading like a day's (18 px bold over a 2 px rule) that folds it,
  and its tasks on ruled rows. A new list's heading is a field for its
  name, in the same type, at once.
- **The panel's edge** is dragged: a 10 px strip over the rule takes the
  pointer (column-resize cursor) and shows a 3 px line of 25 % ink, 45 %
  while dragged. 220 to 640 px, the week keeping 920 px; a double click
  returns to 280 px.
- **Ticked today**: in a list a task ticked today keeps its row, drawn as
  done (struck through, 30 %), until the day ends; the count beside the
  list's name is of what is still to do. Then it goes under "n done".

### The header's buttons

From the left: the icon that opens the panel (a plain 40 px icon, no
ground; only in the week, in a window with room, while the panel is shut),
the views, the new-event button (40 px, 5 % ink), the sync button (the
same; not on a phone), the menu, the arrows. What comes and goes stands
first, so that nothing after it moves.

- **Sync**: two arrows in a circle, which turn (one turn in 0.9 s, the
  turn under way finished when the run ends) while everything is synced;
  a red cloud with a warning mark while the last sync with Nextcloud
  stands failed. On a phone the page is pulled down from its top instead:
  a round mark (the page's menu colour, a 2 px arrow in the text colour)
  follows the finger from under the header, and turns until the sync is
  through; a quarter of the page's height arms it.

- **Views**: a 40 px pill of 5 % ink holding "Week", "Month", "Tasks"
  (15 px; 14 px padding at each side), the one on show bold on a pill in
  the page's colour, the others medium at 60 %. Each name takes the width
  of its bold form. In a single-column window from 646 px they stay; from
  546 px they are icons (18 px, 9 px padding); below, one button that
  turns between the planner and the tasks. While a task is dragged, the
  names it can be carried to have a 35 % outline; held over one for
  650 ms, that page comes up.
- **Arrows** stand on every page. On the Tasks page they turn to the next
  list where one list shows at a time; with nothing to turn they are 8 %
  ink with a 30 % chevron.
- **Hints**: after 600 ms under the pointer, an icon-only button shows its
  purpose 6 px under it: 12 px semibold on a dark pill (light in dark
  themes), radius 8, kept inside the window.

### A new event, and events over several days

- **The form**: a card like a task's (512 px, 24 px radius; on a phone a
  sheet from the bottom). "New event" (15 px, 60 %), the title (28 px bold,
  hint at 25 %), a rule, then one line per thing, 42 px high: an icon
  (16 px, 60 %) for the first line of a group, a 76 px label (15 px, 60 %),
  and the value as a 34 px pill of 5 % ink, radius 10 (15 px; what is not
  set at 60 %). Starts and Ends: the day, and the time unless "All day" is
  on (a switch; the whole line presses). Then Repeat, Reminder, Colour (a
  12 px dot of it before its name), the place field and the notes, each
  with its icon. Bottom right: "Cancel" (plain) and "Add event" (black;
  faint until there is a title).
- **Bars of your own events**: as the calendars' bars, in 8 % ink with a
  40 % mark at the start; filled in the event's colour when it has one.
  In the month a bar keeps its line through a week: a day it does not
  cover leaves the line free.
- **In the card**: the date reads "Fri, 13 – Sun, 15 Nov 2026"; an event
  without a time reads "All day" after the clock; the end time of an
  event over several days names its day ("– Sat 7:00"). The date's month
  has, under it, "Ends on another day…" (then "Last day, 15 Nov" and "One
  day only").
