// hc board: every herdr-core terminal as a card in three columns,
// NEEDS YOU | WORKING | DONE. Port of hc-board.ps1 (github.com/linyaDev/hc-board).
//
// Card: "project · agent · role" (role: `hc label <t> role=<role>`), the last
// request sent to the agent (read off its screen), the last output lines while
// it works or waits for you, and how long it has been in its current status.
// Hidden unless toggled: plain programs (p), finished terminals (f),
// agents idle longer than IDLE_HIDE_MIN (i). r re-reads everything.

import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { terminals, agents, panes, spaces, run, theme, settings, hc, exec, home, notify, nextCommand, checking } from "herdr";

const IDLE_HIDE_MIN = 20;
const TAIL_LINES = 3;
const TAIL_MS = 2000;
const NARROW = 620;

const COLUMNS = [
  { id: "needs", title: "Needs you", color: "blocked" },
  { id: "working", title: "Working", color: "working" },
  { id: "done", title: "Done", color: "done" },
];

const leaf = (p) => (p ?? "").split(/[\\/]/).filter(Boolean).at(-1) ?? "";
const crashed = (t) => t.state === "finished" && t.exit_code != null && t.exit_code !== 0 && !/kill/.test(t.reason ?? "");
const statusWord = (s) => (s == null ? null : typeof s === "string" ? s : s.state ?? null);

function age(ms, now) {
  if (!ms) return "";
  const s = Math.max(0, Math.floor((now - ms) / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}

// Where the agent's input box starts: Claude Code — the second-to-last ─── rule;
// Codex — the last "› " line; others (Kimi) — the last ╭ box top.
function inputStart(lines, app) {
  if (/^claude/.test(app)) {
    const rules = [];
    lines.forEach((l, i) => { if (/^─{10,}/.test(l)) rules.push(i); });
    return rules.length >= 2 ? rules.at(-2) : lines.length;
  }
  const re = /^codex/.test(app) ? /^› / : /^\s*╭/;
  for (let i = lines.length - 1; i >= 0; i--) if (re.test(lines[i])) return i;
  return lines.length;
}

// The last message sent to the agent: Claude "❯ text", Codex "› text".
function lastPrompt(lines, app) {
  let hit = "";
  if (/^claude/.test(app)) {
    for (let i = inputStart(lines, app) - 1; i >= 0; i--) {
      const m = /^❯ (.+)$/.exec(lines[i]);
      if (m) { hit = m[1]; break; }
    }
  } else if (/^codex/.test(app)) {
    const sent = lines.map((l) => /^› (.+)$/.exec(l)?.[1]).filter(Boolean);
    if (sent.length >= 2) hit = sent.at(-2);
  } else {
    for (let i = lines.length - 1; i >= 0; i--) {
      const m = /^\s*[❯›] (.+)$/.exec(lines[i]);
      if (m) { hit = m[1]; break; }
    }
  }
  hit = hit.trim();
  // A task from another agent: <hc from="t7 dragon-claude">text</hc>
  const m = /^<hc from="(?:\S+ )?([^"]+)"[^>]*>(.*)$/.exec(hit);
  if (m) hit = `от ${m[1]}: ${m[2].replace(/<\/hc>\s*$/, "")}`;
  return hit;
}

// The agent's last n output lines above its input box, blanks and rules dropped.
function screenTail(lines, app, n) {
  const out = [];
  for (let i = inputStart(lines, app) - 1; i >= 0 && out.length < n; i--) {
    const s = (lines[i] ?? "").trim();
    if (!s || /^[─━═\-_=·\s]+$/.test(s) || /^\(ctrl\+/.test(s) || /^⎿\s+Tip:/.test(s)) continue;
    out.unshift(s);
  }
  return out;
}

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

export default class Board extends View {
  init(_props, cx) {
    this.handle = cx.focus_handle();
    this.stamps = {};          // address -> { key, status, turn, ms, created, prompt, found, tail, app, title }
    this.busy = new Set();     // addresses being read now
    this.boardStart = Date.now();
    this.width = 1200;
    try { this.prompts = JSON.parse(localStorage.getItem("prompts") ?? "{}") ?? {}; } catch { this.prompts = {}; }
    try { this.show = JSON.parse(localStorage.getItem("show") ?? "{}") ?? {}; } catch { this.show = {}; }
    if (checking()) return;

    // Data: notice status/turn changes, re-read busy agents' screens.
    cx.timer.every(1000, (cx) => this.sync(cx, false));
    cx.timer.every(TAIL_MS, (cx) => this.tails(cx));
    // Clock: seconds tick only while some card is under a minute old.
    this.lastTick = 0;
    cx.timer.every(1000, (cx) => {
      const now = Date.now();
      if (this.fresh || now - this.lastTick >= 30000) { this.lastTick = now; cx.notify(); }
    });
    this.sync(cx, true);

    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        if (c === "focus") this.handle.focus();
        else this.key(c, cx);
        cx.notify();
      }
    });
  }

  savePrompts() {
    const keys = Object.keys(this.prompts);
    for (const k of keys.slice(0, Math.max(0, keys.length - 300))) delete this.prompts[k];
    localStorage.setItem("prompts", JSON.stringify(this.prompts));
  }

  toggle(what) {
    this.show[what] = !this.show[what];
    localStorage.setItem("show", JSON.stringify(this.show));
  }

  key(k, cx) {
    if (k === "p" || k === "plain") this.toggle("plain");
    else if (k === "f" || k === "finished") this.toggle("finished");
    else if (k === "i" || k === "idle") this.toggle("idle");
    else if (k === "r" || k === "reload") this.sync(cx, true);
    else if (k === "t" || k === "team") this.team(cx);
    else return false;
    return true;
  }

  // Re-read the terminals whose status or turn changed (all of them when full).
  sync(cx, full) {
    const live = terminals().filter((t) => t.state === "live" && statusWord(t.status));
    const seen = new Set(live.map((t) => t.address));
    let dropped = false;
    for (const a of Object.keys(this.stamps)) if (!seen.has(a)) { delete this.stamps[a]; dropped = true; }
    if (dropped) cx.notify();
    for (const t of live) {
      const s = this.stamps[t.address];
      const st = statusWord(t.status);
      if (!full && s && s.status === st && s.turn === t.turn && s.found) continue;
      this.load(cx, t, st);
    }
  }

  load(cx, t, st) {
    const addr = t.address;
    if (this.busy.has(addr)) return;
    this.busy.add(addr);
    cx.spawn(async (cx) => {
      try {
        const g = JSON.parse((await hc(["get", addr, "--json"])).stdout || "null");
        if (!g) return;
        const old = this.stamps[addr];
        const key = `${addr}@${g.created_ms}`;
        const app = (g.status && typeof g.status === "object" && g.status.app) || t.agent || "";
        let prompt = old?.key === key && old.prompt ? old.prompt : this.prompts[key] ?? "";
        const lines = (await hc(["read", addr, "--lines", "200"])).stdout.split(/\r?\n/);
        const found = lastPrompt(lines, app);
        if (found && found !== prompt) {
          prompt = found;
          this.prompts[key] = found;
          this.savePrompts();
        }
        this.stamps[addr] = {
          key, app, prompt, found: Boolean(found),
          status: st, turn: t.turn,
          ms: g.status_ms ?? 0, created: g.created_ms ?? 0,
          role: g.labels?.role ?? "",
          tail: screenTail(lines, app, TAIL_LINES),
        };
        cx.notify();
      } catch {
        // hc not answering: try again on the next change or reload.
      } finally {
        this.busy.delete(addr);
      }
    });
  }

  // Busy agents' last lines follow along.
  tails(cx) {
    for (const t of terminals()) {
      const s = this.stamps[t.address];
      if (!s || t.state !== "live" || !["working", "blocked", "error"].includes(statusWord(t.status))) continue;
      const addr = t.address;
      if (this.busy.has(addr)) continue;
      this.busy.add(addr);
      cx.spawn(async (cx) => {
        try {
          const lines = (await hc(["read", addr])).stdout.split(/\r?\n/);
          const tail = screenTail(lines, s.app, TAIL_LINES);
          if (tail.join("\n") !== (s.tail ?? []).join("\n")) { s.tail = tail; cx.notify(); }
        } catch {} finally { this.busy.delete(addr); }
      });
    }
  }

  since(t) {
    const s = this.stamps[t.address];
    if (s?.ms && s.status === statusWord(t.status)) return s.ms;
    return t.finished_ms || t.created_ms || s?.created || 0;
  }

  // The status shown: Herdr's view for its own agents (done turns idle once seen);
  // for others, done from before the board started counts as seen.
  shown(t, herdr) {
    const st = statusWord(t.status);
    if (herdr.has(t.address)) return herdr.get(t.address);
    if (st === "done" && this.since(t) && this.since(t) < this.boardStart) return "idle";
    return st;
  }

  // 0 needs you, 1 working, 2 done; -1 plain program; -2 ended normally.
  column(t, st) {
    if (t.state === "finished") return crashed(t) ? 0 : -2;
    return { blocked: 0, error: 0, working: 1, done: 2, idle: 2 }[st] ?? -1;
  }

  card(t, th, info, now, mono) {
    const { st, kind } = info;
    const s = this.stamps[t.address];
    const plain = kind === "plain";
    const ended = t.state === "finished";
    const color = crashed(t) ? th.blocked
      : ended || plain ? th.dim
      : th[st === "error" ? "blocked" : st] ?? th.dim;
    const machine = t.address.includes("/") ? t.address.split("/")[0] : null;
    const agent = (t.program?.name ?? t.agent ?? "?").replace(/-code$/, "").replace(/\.exe$/, "");
    const role = s?.role || t.labels?.role || "";
    const who = [leaf(t.cwd) || "~", agent, role].filter(Boolean).join(" · ");
    const task = plain ? "" : s?.prompt || "";
    const busy = !plain && !ended && ["working", "blocked", "error"].includes(st);
    const tail = busy ? s?.tail ?? [] : [];
    const statusText = ended ? `${crashed(t) ? "crashed" : "finished"} · ${t.exit_code != null ? `exit ${t.exit_code}` : t.reason || "finished"}`
      : plain ? "plain · running" : st;
    const since = plain ? 0 : this.since(t);
    if (since && now - since < 60000) this.fresh = true;
    const hasPane = this.paneOf.has(t.address);

    return v_flex()
      .id(`card-${t.address}`)
      .flex_none()
      .p(10)
      .gap(5)
      .rounded(8)
      .border(1)
      .border_color(color + (st === "idle" || plain || ended ? "40" : "80"))
      .bg(th.surface)
      .when(!ended, (el) => el.cursor_pointer().hover((h) => h.bg(th.hover))
        .on_click(() => (hasPane ? run("pane.focus", { terminal: t.address }) : run("terminal.peek", { terminal: t.address }))))
      .tooltip(hasPane ? `${t.address}: show` : `${t.address}: peek (hc attach ${t.name || t.address})`)
      .child(h_flex().gap(7).items_center().min_w(0)
        .when(Boolean(icon(t.program, 14, th.foreground)), (el) => el.child(icon(t.program, 14, th.foreground)))
        .child(div().flex_1().min_w(0).truncate().font_medium().text_color(th.foreground).child(who))
        .when(Boolean(machine), (el) => el.child(div().flex_none().text_size(10.5).text_color(th.dim).child(machine))))
      .child(div().min_w(0).truncate().text_color(task ? th.foreground : th.dim).child(task || "—"))
      .when(busy, (el) => el.child(v_flex().min_w(0).pl(8).border_l(2).border_color(color + "55")
        .font_family(mono).text_size(11.5).text_color(th.muted)
        .children(Array.from({ length: TAIL_LINES }, (_, k) => div().h(16).min_w(0).truncate().child(tail[k] ?? "")))))
      .child(h_flex().gap(6).items_center().text_size(11.5)
        .child(this.mark(th, st, color, plain || ended))
        .child(div().flex_1().min_w(0).truncate().text_color(color).child(statusText))
        .when(Boolean(since), (el) => el.child(div().flex_none().text_color(th.dim).child(age(since, now)))));
  }

  mark(th, st, color, quiet) {
    if (quiet) return div().size(7).mx(2).flex_none().rounded(4).border(1.5).border_color(th.dim);
    if (st === "working") return svg("mods/workspace-chrome/spinner.svg").size(11).flex_none().text_color(color).spin(900);
    if (st === "idle") return div().size(7).mx(2).flex_none().rounded(4).border(1.5).border_color(color);
    return div().size(7).mx(2).flex_none().rounded(4).bg(color);
  }

  // Starts the shown space's team (hc-team: .herdr/team.json or .vscode/tasks.json).
  team(cx) {
    const space = spaces().find((s) => s.active);
    if (!space?.folder || this.starting) return;
    this.starting = true;
    cx.spawn(async (cx) => {
      try {
        const r = await exec(`${home()}/.local/bin/hc-team`, [space.folder], { timeout: 60000, on: space.machine });
        const out = (r.stdout + r.stderr).trim();
        notify({ title: r.code ? "hc-team failed" : `Team: ${space.name}`, body: out || "nothing to start", level: r.code ? "error" : "info" });
      } catch (e) {
        notify({ title: "hc-team failed", body: String(e), level: "error" });
      } finally {
        this.starting = false;
        cx.notify();
      }
    });
  }

  chip(th, id, label, on) {
    return div().id(`chip-${id}`).flex_none().px(8).h(22).rounded(6).flex().items_center()
      .text_size(11.5).cursor_pointer()
      .border(1).border_color(on ? th.accent : th.border)
      .text_color(on ? th.foreground : th.muted)
      .hover((h) => h.bg(th.hover))
      .on_click((_e, cx) => { this.key(id, cx); this.handle.focus(); cx.notify(); })
      .child(label);
  }

  render(cx) {
    const th = theme();
    const now = Date.now();
    const mono = settings().font_family ?? "JetBrains Mono";
    const herdr = new Map(agents().map((a) => [a.address, a.status]));
    this.paneOf = new Set(panes().map((p) => p.terminal).filter(Boolean));
    this.fresh = false;

    const buckets = [[], [], []];
    let plainN = 0, finishedN = 0, idleN = 0;
    for (const t of terminals()) {
      const st = this.shown(t, herdr);
      let i = this.column(t, st);
      let kind = "agent";
      if (i === 2 && st === "idle" && now - this.since(t) > IDLE_HIDE_MIN * 60000 && this.since(t)) {
        idleN++;
        if (!this.show.idle) continue;
      }
      if (i === -2) { finishedN++; if (!this.show.finished) continue; i = 2; kind = "ended"; }
      else if (i === -1) { plainN++; if (!this.show.plain) continue; i = 2; kind = "plain"; }
      buckets[i].push({ t, st, kind });
    }
    // Waiting longest first in Needs you; newest first in Working;
    // Done: done, then idle, plain, finished, newest first within each.
    const by = (x) => this.since(x.t);
    buckets[0].sort((a, b) => by(a) - by(b));
    buckets[1].sort((a, b) => by(b) - by(a));
    const rank = (x) => (x.kind === "ended" ? 3 : x.kind === "plain" ? 2 : x.st === "done" ? 0 : 1);
    buckets[2].sort((a, b) => rank(a) - rank(b) || by(b) - by(a));

    const narrow = this.width < NARROW;
    const column = (c, i) => {
      const items = buckets[i];
      const head = h_flex().flex_none().gap(6).items_center().px(2).pb(2)
        .child(div().size(8).rounded(4).bg(th[c.color]))
        .child(div().text_size(12).font_semibold().text_color(th[c.color]).child(c.title.toUpperCase()))
        .child(div().text_size(12).text_color(th.dim).child(String(items.length)));
      const cards = items.length
        ? items.map((x) => this.card(x.t, th, x, now, mono))
        : [div().px(2).text_color(th.dim).child("—")];
      return narrow
        ? [head, ...cards]
        : v_flex().id(`col-${c.id}`).flex_1().min_w(0).min_h(0).gap(8).child(head)
          .child(v_flex().id(`list-${c.id}`).flex_1().min_h(0).gap(8).overflow_y_scrollbar().children(cards));
    };

    return v_flex()
      .id("root")
      .on_size_change((size, cx) => { if (Math.abs(size.width - this.width) > 1) { this.width = size.width; cx.notify(); } })
      .track_focus(this.handle)
      .on_mouse_down("left", () => this.handle.focus())
      .on_key_down((e, cx) => {
        if (e.modifiers?.control || e.modifiers?.platform || e.modifiers?.alt) return;
        if (this.key(e.key, cx)) { cx.stop_propagation(); cx.notify(); }
      })
      .size_full()
      .min_h(0)
      .bg(th.canvas ?? th.background)
      .text_size(13)
      .text_color(th.foreground)
      .p(12)
      .gap(10)
      .child(h_flex().flex_none().gap(6).items_center().flex_wrap()
        .child(div().text_size(13).font_semibold().mr(6).child("hc board"))
        .child(this.chip(th, "plain", `plain ${plainN}`, this.show.plain))
        .child(this.chip(th, "finished", `finished ${finishedN}`, this.show.finished))
        .child(this.chip(th, "idle", `idle >${IDLE_HIDE_MIN}m ${idleN}`, this.show.idle))
        .child(this.chip(th, "reload", "reload", false))
        .child(this.chip(th, "team", this.starting ? "starting…" : "▶ team", false))
        .child(div().flex_1())
        .when(!narrow, (el) => el.child(div().text_size(11).text_color(th.dim).child("p f i r t · click: show / peek"))))
      .child(narrow
        ? v_flex().id("board").flex_1().min_h(0).gap(8).overflow_y_scrollbar().children(COLUMNS.flatMap(column))
        : div().flex().flex_row().flex_1().min_h(0).gap(12).children(COLUMNS.map(column)));
  }
}
