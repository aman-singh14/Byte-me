# Omni Glasses — Design System

The app is the glasses' companion: playful where we celebrate, calm and literal where we keep people safe, and usable by everyone, including Deaf, hard-of-hearing, blind, and low-vision users.

**Stack:** Flutter (iOS + Android), Material 3 with custom tokens, light and dark themes that follow the system setting.

---

## 1. Design principles

1. **Glanceable first.** The glasses do the talking; the app is for quick check-ins. Every screen answers its main question within two seconds.
2. **Never rely on one sense.** Every alert or state is shown in at least two ways: color + icon + text, plus haptics or sound where it matters. A Deaf user and a blind user must both get the full message.
3. **Play is for rewards, never for warnings.** Rings, quests, and confetti live in the social and wellness areas. Safety alerts are plain, high-contrast, and literal. Nothing about a near miss is ever gamified (no points, no streaks, no badges).
4. **Celebrate showing up, never shame.** No red for missed goals, no guilt copy. Streak freezes exist. A partial ring is progress, not failure.
5. **Privacy you can see.** Show what's tracked and what's shared, right where it happens ("Nothing recorded", "Friends see ring % only").
6. **Big, forgiving, one-handed.** Large touch targets, generous spacing, layouts that survive 200% text size.
7. **Calm motion.** Animations are short, purposeful, skippable, and switched off when the system's reduce-motion setting is on.

---

## 2. Two registers

The app speaks in two voices. Choose by context, never mix them on one component.

| | Play register | Safety register |
|---|---|---|
| Where | Today rings, Together tab, quests, friends | Alerts, social taps, link lost, rear view |
| Color | Ring colors, brand violet, soft surfaces | Urgent red, gentle amber, social teal, neutrals |
| Shape | Rounded, soft, pill buttons, rings | Full-width banners, strong borders, big icons |
| Motion | Ring fills, small bounces, confetti (≤1.5 s) | Instant appear (≤100 ms fade), no bounce, no confetti |
| Copy | Warm, encouraging, a little fun | Short, literal, directional ("Car behind you, left") |
| Sound/haptic | Success haptic, optional chime | Matches the glasses' buzz patterns exactly |

---

## 3. Color tokens

Ring and alert colors are chosen to stay distinguishable for common color blindness. They never carry meaning alone: every use is paired with an icon and a text label. Check every text/background pair for **≥ 4.5:1 contrast** (≥ 3:1 for large text and UI shapes) before shipping.

### Neutrals

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | `#FFFBF5` | `#121214` | Page background |
| `surface` | `#FFFFFF` | `#1E1E22` | Cards, sheets |
| `surfaceAlt` | `#F3EEE6` | `#2A2A30` | Inset areas, ring tracks |
| `outline` | `#D9D3CA` | `#3A3A42` | Borders, dividers |
| `textPrimary` | `#1C1B1F` | `#F4F2EE` | Body and headings |
| `textSecondary` | `#5D5A63` | `#B5B1BA` | Supporting text |

### Brand and play

| Token | Light | Dark | Use |
|---|---|---|---|
| `brand` | `#6C4CF1` | `#A99BFF` | Primary buttons, selected tab, links |
| `ringHeadsUp` | `#2D9CDB` | `#6CC4F5` | Heads-up ring (icon: eye looking up) |
| `ringOutside` | `#F2A900` | `#FFC845` | Outside ring (icon: sun) |
| `ringTeam` | `#C2549A` | `#E58AC4` | Team ring and group quests (icon: people) |

### Safety and status

| Token | Light | Dark | Use |
|---|---|---|---|
| `alertUrgent` | `#C62828` | `#FF6B6B` | Urgent approach (always with icon + word + side) |
| `alertGentle` | `#F2A900` | `#FFC845` | Gentle approach (dark text on top) |
| `socialTap` | `#00796B` | `#4DD0C4` | Someone stopped to talk |
| `linkLost` | `textSecondary` + striped fill | same | Glasses not watching |
| `ok` | `brand` | `brand` | Connected / all clear (never use green-vs-red pairs) |

Implement as a Flutter `ThemeExtension<OmniColors>` with light and dark instances. Widgets read tokens only, never raw hex.

---

## 4. Typography

- **Body, numbers, captions:** Atkinson Hyperlegible (designed for low-vision readers; use the Next version if available via `google_fonts`).
- **Headings and celebrations:** Nunito (rounded, friendly), weights 700–800.
- **Numbers:** tabular figures so ring values don't jitter while counting.

| Style | Size (sp) | Weight | Font |
|---|---|---|---|
| `display` | 34 | 800 | Nunito |
| `title` | 24 | 700 | Nunito |
| `headline` | 20 | 700 | Nunito |
| `body` | 17 | 400 | Atkinson Hyperlegible |
| `label` | 15 | 700 | Atkinson Hyperlegible |
| `caption` | 13 | 400 | Atkinson Hyperlegible (minimum size anywhere) |
| `captionView` | 28 default, user-adjustable 20–48 | 400 | Atkinson Hyperlegible (live captions) |

Never set fixed heights on text containers. Every screen must work at 200% system text size.

---

## 5. Layout and shape

- **Spacing:** 8-pt grid (`4, 8, 12, 16, 24, 32, 48`). Page margins 16. Gap between cards 12–16.
- **Radius:** cards 20, buttons and chips fully rounded (pill), sheets 28 at the top.
- **Touch targets:** minimum 48×48 dp, even when the visible icon is smaller.
- **Elevation:** flat. Separate with surface color and outline, not heavy shadows.
- **Icons:** Material Symbols Rounded, 24 dp default, 32 dp in alerts. Every icon that conveys meaning gets a semantic label.
- **Signature motif:** concentric rings. Use them for progress, nowhere else, so they always mean "your goals."

---

## 6. Navigation and screens

Bottom navigation with four tabs, labels always visible:

1. **Today**: the balanced overview (home)
2. **Aware**: rear view, alerts, social taps, captions, "Who's around me?"
3. **Eyes**: eye-health dashboard
4. **Together**: rings detail, friends, groups, quests

Settings and privacy open from a profile button at the top right of Today.

### Today (home): card order
1. **Status strip:** glasses connected, battery, "Nothing recorded" chip. Turns into a full-width `linkLost` banner if the glasses disconnect.
2. **Rings card:** Heads-up and Outside rings, plus the Team ring if the user is in a group, each with value text ("2 h 10 m of 3 h").
3. **Awareness card:** last alert or social tap with time and side, plus a big "Who's around me?" button.
4. **Eyes card:** close-up minutes today, current reading distance, blink rate vs baseline.
5. **Quests card:** active group quest first (with countdown and member initials), then side quests.

### Aware
- Live rear view with labeled boxes and a "Nothing recorded" chip.
- `SideIndicator` above the video showing which side an alert or tap came from.
- Event log, newest first.
- Captions toggle (off by default) and "Who's around me?" button.

### Eyes
- Today's close-up time, reading distance over the day, blink rate vs personal baseline, longest session, breaks taken. Copy says "habits linked to eye strain," never a diagnosis.

### Together
- Rings detail by day and week.
- Friends list: names + ring percentages only.
- Groups: team ring, scheduled group breaks ("3:00 pm screen break, 6 of 8 joined"), group quests.
- Side quests with difficulty tiers the user picks.

---

## 7. Core components

| Component | Behavior | Accessibility |
|---|---|---|
| `RingStack` | Concentric arcs with an icon at each ring's start; value text beside it. Fill animates 600 ms ease-out. | Semantics: "Heads-up ring, 2 hours 10 minutes of 3 hours, 72 percent." |
| `StatusStrip` | Connection, battery, privacy chip. Becomes a link-lost banner. | Announces connection changes. |
| `AlertBanner` | Full-width, safety register. Icon + one word + side ("Car · behind left"). Stays until resolved or dismissed. | Live-region announcement via `SemanticsService.announce`; phone haptic matches the glasses' pattern. |
| `SideIndicator` | Top-down head outline with left / behind / right arcs; the active arc fills. | Text equivalent always shown ("Left"). |
| `SocialTapCard` | Teal, friendly: "Someone stopped behind you, left." | Announced; never uses the urgent color. |
| `QuestCard` | Title, progress bar, member initials, countdown, join button. | Progress read as text. |
| `FriendRow` | Avatar initial, name, mini ring percentages. | "Maya: heads-up 80 percent, outside 40 percent." |
| `CaptionView` | Large high-contrast text, clear speaker turns, user font-size slider. | Never auto-hides; respects system text size. |
| `WhoAroundSheet` | One big button; result shown as large text and spoken aloud. | Fully operable with the screen reader; result read automatically. |
| `Celebration` | Confetti in ring colors + success haptic, ≤1.5 s, tap to skip. | Disabled under reduce motion; replaced by a text toast. |

---

## 8. Motion

- Ring fills: 600 ms ease-out. Quest complete: ≤1.5 s celebration, skippable.
- Safety alerts: ≤100 ms fade in, no bounce, no shake.
- Respect `MediaQuery.disableAnimations`: swap motion for instant state changes and text.
- No looping animations on any screen.

---

## 9. Voice and copy

| Do | Don't |
|---|---|
| "Car behind you, left." | "Whoa, watch out!" |
| "Someone stopped to talk, behind you." | "Social interaction detected." |
| "2 h 10 m heads-up today. Nice." | "You failed your goal." |
| "Ring paused today. Back tomorrow." | "Streak lost!" |
| "Friends see your ring % only." | "Data is shared with partners." |
| "Nothing recorded." | (no privacy statement) |

Second person, short sentences, numbers as digits, no exclamation marks in the safety register.

---

## 10. Accessibility checklist (every screen)

- [ ] Text contrast ≥ 4.5:1, UI shapes ≥ 3:1, in both themes
- [ ] No meaning carried by color alone
- [ ] All custom-painted widgets wrapped in `Semantics` with full sentences
- [ ] Works at 200% text size with no clipped text
- [ ] Logical screen-reader order; alerts announced
- [ ] Touch targets ≥ 48×48 dp
- [ ] Reduce-motion respected
- [ ] Haptic + text equivalent for every sound; text + sound equivalent for every visual alert
- [ ] Dark mode checked separately, not just inverted

---

## 11. Flutter implementation notes

- `ThemeData(useMaterial3: true)` with custom `ColorScheme` built from the tokens, plus `ThemeExtension`s: `OmniColors`, `OmniSpacing`, `OmniRadii`.
- Fonts via the `google_fonts` package.
- Use `.adaptive` constructors (switches, dialogs, progress indicators) so controls feel native on iOS and Android.
- Rings with `CustomPainter`, always wrapped in `Semantics`.
- Build a **Widget Gallery** debug screen showing every component in light, dark, and 200% text so the team can review the design in one place.