"""The read-only team page at /t/{public_id}: league points, the team ring,
side quest stars, members, and where the team stands in the league. Only shown if the team
turned it on.

Colors and fonts follow mobile-app/DESIGN.md (play register: rings, brand
violet, soft surfaces). Rings always carry a number, never color alone. The
page updates itself in place every 30 s (no reload, no scroll jump).
"""

import html

CSS = """
:root {
  --bg: #FFFBF5; --surface: #FFFFFF; --alt: #F3EEE6; --outline: #E6E0D6;
  --text: #1C1B1F; --text2: #6B6770; --brand: #6C4CF1; --brand-soft: #EEE9FE;
  --headsup: #2D9CDB; --outside: #F2A900; --team: #C2549A;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #121214; --surface: #1C1C20; --alt: #2A2A30; --outline: #33333B;
    --text: #F4F2EE; --text2: #ABA7B2; --brand: #A99BFF; --brand-soft: #2A2547;
    --headsup: #6CC4F5; --outside: #FFC845; --team: #E58AC4;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.4 "Atkinson Hyperlegible Next", "Atkinson Hyperlegible", system-ui, sans-serif; }
main { max-width: 560px; margin: 0 auto; padding: 20px 16px 40px; }
h1, h2, .num { font-family: Nunito, system-ui, sans-serif; font-weight: 800; margin: 0; }
h1 { font-size: 36px; line-height: 1.1; letter-spacing: -0.01em; }
h2 { font-size: 13px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--text2);
  margin: 28px 4px 10px; }
.brand { display: inline-flex; align-items: center; gap: 8px; font-weight: 700; font-size: 14px;
  color: var(--text2); margin-bottom: 10px; }
.brand::before { content: ""; width: 10px; height: 10px; border-radius: 50%; background: var(--brand); }
.rank { display: inline-block; margin-top: 8px; padding: 4px 12px; border-radius: 999px;
  background: var(--brand-soft); color: var(--brand); font-weight: 700; font-size: 15px; }
.card { background: var(--surface); border: 1px solid var(--outline); border-radius: 24px; }
.hero { margin-top: 20px; padding: 20px; display: flex; align-items: center; gap: 20px; }
.hero svg { flex: none; }
.stats { flex: 1; display: grid; gap: 14px; }
.stat .num { font-size: 26px; line-height: 1; font-variant-numeric: tabular-nums; }
.stat .num .star { color: var(--brand); }
.stat .label { color: var(--text2); font-size: 14px; }
.next { margin-top: 12px; padding: 12px 16px; display: flex; gap: 10px; align-items: center; font-weight: 700; }
.next .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--brand); flex: none; }
ol { list-style: none; margin: 0; padding: 0; overflow: hidden; }
li { display: flex; align-items: center; gap: 12px; padding: 12px 16px; }
li + li { border-top: 1px solid var(--outline); }
.avatar { width: 36px; height: 36px; border-radius: 50%; background: var(--alt); flex: none;
  display: grid; place-items: center; font-weight: 700; }
.who { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.name { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rings { display: flex; gap: 12px; margin-top: 2px; color: var(--text2); font-size: 14px;
  font-variant-numeric: tabular-nums; }
.mini { display: inline-flex; align-items: center; gap: 4px; }
.score { font-family: Nunito, system-ui, sans-serif; font-weight: 800; font-size: 20px; white-space: nowrap;
  font-variant-numeric: tabular-nums; }
.score .star { color: var(--brand); font-size: 16px; margin-right: 2px; }
.score small { font-size: 13px; color: var(--text2); margin-left: 2px; }
.place { width: 24px; text-align: center; font-weight: 700; color: var(--text2); flex: none; }
li.me { background: var(--brand-soft); }
li.me .place { color: var(--brand); }
a { color: inherit; text-decoration: none; }
a:hover .name { text-decoration: underline; }
.sub { color: var(--text2); font-size: 14px; }
footer { margin-top: 28px; text-align: center; color: var(--text2); font-size: 13px; }
@media (max-width: 330px) { .hero { flex-direction: column; align-items: flex-start; } }
"""

# Swaps in a fresh copy of the page every 30 s, keeping the scroll position,
# and shows times in the viewer's own time zone.
SCRIPT = """
function localTimes(root) {
  root.querySelectorAll('time[datetime]').forEach(function (t) {
    t.textContent = new Date(t.getAttribute('datetime'))
      .toLocaleTimeString([], {hour: 'numeric', minute: '2-digit'});
  });
}
localTimes(document);
setInterval(function () {
  fetch(location.href, {cache: 'no-store'})
    .then(function (r) { return r.ok ? r.text() : null; })
    .then(function (text) {
      if (!text) return;
      var fresh = new DOMParser().parseFromString(text, 'text/html').querySelector('main');
      if (!fresh) return;
      localTimes(fresh);
      document.querySelector('main').replaceWith(fresh);
    })
    .catch(function () {});
}, 30000);
"""


def ring_svg(percent, size=124, stroke=14):
    r = (size - stroke) / 2
    c = 2 * 3.14159265 * r
    filled = c * max(0, min(percent, 100)) / 100
    mid = size / 2
    return (
        f'<svg width="{size}" height="{size}" viewBox="0 0 {size} {size}" role="img" '
        f'aria-label="Team ring today, {percent} percent">'
        f'<circle cx="{mid}" cy="{mid}" r="{r}" fill="none" stroke="var(--alt)" stroke-width="{stroke}"/>'
        f'<circle cx="{mid}" cy="{mid}" r="{r}" fill="none" stroke="var(--team)" stroke-width="{stroke}" '
        f'stroke-linecap="round" stroke-dasharray="{filled:.1f} {c:.1f}" transform="rotate(-90 {mid} {mid})"/>'
        f'<text x="{mid}" y="{mid + 4}" text-anchor="middle" font-family="Nunito, system-ui, sans-serif" '
        f'font-weight="800" font-size="28" fill="var(--text)">{percent}%</text>'
        f'<text x="{mid}" y="{mid + 22}" text-anchor="middle" font-size="12" fill="var(--text2)">team ring</text>'
        f'</svg>'
    )


def mini_ring(percent, color_var, label):
    size, stroke = 16, 3
    r = (size - stroke) / 2
    c = 2 * 3.14159265 * r
    filled = c * max(0, min(percent, 100)) / 100
    mid = size / 2
    return (
        f'<span class="mini" aria-label="{label} {percent} percent" title="{label}">'
        f'<svg width="{size}" height="{size}" viewBox="0 0 {size} {size}" aria-hidden="true">'
        f'<circle cx="{mid}" cy="{mid}" r="{r}" fill="none" stroke="var(--alt)" stroke-width="{stroke}"/>'
        f'<circle cx="{mid}" cy="{mid}" r="{r}" fill="none" stroke="var({color_var})" stroke-width="{stroke}" '
        f'stroke-dasharray="{filled:.1f} {c:.1f}" transform="rotate(-90 {mid} {mid})"/></svg>{percent}%</span>'
    )


def stars(n, label):
    shown = f"{n:g}"
    return (f'<span class="score" aria-label="{shown} {label}">'
            f'<span class="star" aria-hidden="true">★</span>{shown}</span>')


def points(n):
    return f'<span class="score" aria-label="{n} points">{n}<small>pts</small></span>'


def ordinal(n):
    return f"{n}{'th' if 10 <= n % 100 <= 20 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')}"


def render(data):
    e = html.escape
    members = "".join(
        f'<li><span class="avatar" aria-hidden="true">{e(m["name"][:1].upper())}</span>'
        f'<span class="who"><span class="name">{e(m["name"])}</span>'
        f'<span class="rings">{mini_ring(m["heads_up"], "--headsup", "Heads-up")}'
        f'{mini_ring(m["outside"], "--outside", "Outside")}</span></span>'
        f'{stars(m["stars_week"], "stars this week")}</li>'
        for m in data["members"]
    ) or '<li class="sub">No members yet.</li>'

    def team_row(t):
        name = f'<span class="name">{e(t["name"])}</span>'
        if t["public_id"] and not t["me"]:
            name = f'<a href="/t/{e(t["public_id"])}">{name}</a>'
        count = f'{t["members"]} {"member" if t["members"] == 1 else "members"} · ★ {t["stars"]:g} each'
        return (f'<li class="{"me" if t["me"] else ""}"><span class="place">{t["rank"]}</span>'
                f'<span class="who">{name}<span class="sub">{count}</span></span>'
                f'{points(t["points"])}</li>')

    league = "".join(team_row(t) for t in data["league"])

    soon = [b for b in data["breaks"] if b["status"] in ("upcoming", "running")]
    next_break = ""
    if soon:
        b = min(soon, key=lambda b: b["starts_at"])
        when = ("Screen break happening now" if b["status"] == "running" else
                f'Next screen break at <time datetime="{e(b["starts_at"])}">{e(b["starts_at"][11:16])} UTC</time>')
        next_break = f'<div class="card next"><span class="dot"></span>{when}</div>'

    rank = "Top team this week" if data["rank"] == 1 else f'{ordinal(data["rank"])} of {data["teams"]} teams this week'
    taken = data["breaks_taken"]
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(data["name"])} · Omni Glasses</title>
<link rel="icon" href="data:,">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible+Next:wght@400;700&family=Nunito:wght@800&display=swap" rel="stylesheet">
<style>{CSS}</style></head>
<body><main>
<div class="brand">Omni Glasses</div>
<h1>{e(data["name"])}</h1>
<span class="rank">{rank}</span>
<section class="card hero">
  {ring_svg(data["team"])}
  <div class="stats">
    <div class="stat"><div class="num">{data["points"]}</div>
      <div class="label">league points this week</div></div>
    <div class="stat"><div class="num"><span class="star">★</span> {data["stars"]:g}</div>
      <div class="label">stars per member</div></div>
    <div class="stat"><div class="num">{data["ring_week"]}%</div>
      <div class="label">average ring this week</div></div>
  </div>
</section>
{next_break}
<h2>Members</h2>
<ol class="card">{members}</ol>
<h2>League</h2>
<ol class="card">{league}</ol>
<p class="sub" style="margin: 8px 4px 0">10 points per star per member, plus the team's average ring.
{taken} screen break{"" if taken == 1 else "s"} taken together.</p>
<footer>Names, rings and stars only. No video, audio or location.</footer>
</main>
<script>{SCRIPT}</script>
</body></html>"""
