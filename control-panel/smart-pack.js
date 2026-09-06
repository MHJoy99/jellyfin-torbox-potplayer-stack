(function () {
"use strict";
try {
var G = typeof globalThis !== "undefined" ? globalThis : Function("return this")();
var W = (G && G.window) ? G.window : G;
var D = (G && G.document) ? G.document : (typeof document !== "undefined" ? document : null);
var GQ = W.__smtpack = W.__smtpack || {};
function E(id) { try { return D ? D.getElementById(id) : null; } catch (_) { return null; } }
function Q(s, r) { try { return Array.prototype.slice.call((r || D).querySelectorAll(s)); } catch (_) { return []; } }
function MK(t, c, x) { var n = D.createElement(t); if (c) n.className = c; if (x != null) n.textContent = x; return n; }
function ON(n, e, f) { try { if (n) n.addEventListener(e, f); } catch (_) {} }
function TS(m) { try { var t = E("toast"); if (t) { t.textContent = m; t.className = "toast show"; clearTimeout(TS._t); TS._t = setTimeout(function () { t.classList.remove("show"); }, 4200); } } catch (_) {} }
function CP(t, msg) {
  function fb() { try { var ta = D.createElement("textarea"); ta.value = t; D.body.appendChild(ta); ta.select(); try { D.execCommand("copy"); } catch (_) {} ta.remove(); TS(msg || "Copied."); } catch (_) {} }
  try { if (W.navigator && W.navigator.clipboard && W.navigator.clipboard.writeText) W.navigator.clipboard.writeText(t).then(function () { TS(msg || "Copied."); }, fb); else fb(); } catch (_) { fb(); }
}
function ESC(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
function BYTES(n) { n = Number(n); if (!isFinite(n) || n < 0) return "—"; if (n === 0) return "0 B"; var u = ["B", "KB", "MB", "GB", "TB"]; var i = 0; while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; } return (n >= 100 ? Math.round(n) : (Math.round(n * 10) / 10)) + " " + u[i]; }
function NUM(n, fb) { n = Number(n); return isFinite(n) ? n : (fb == null ? 0 : fb); }
function FETCHJ(url, ms) {
  try {
    var ctrl = null, timer = 0;
    try { if (W.AbortController) ctrl = new W.AbortController(); } catch (_) {}
    var opts = {};
    if (ctrl) opts.signal = ctrl.signal;
    if (ctrl) timer = setTimeout(function () { try { ctrl.abort(); } catch (_) {} }, ms || 8000);
    return fetch(url, opts).then(function (r) {
      try { if (timer) clearTimeout(timer); } catch (_) {}
      if (!r.ok) throw new Error("http " + r.status);
      return r.json();
    }, function (e) { try { if (timer) clearTimeout(timer); } catch (_) {} throw e; });
  } catch (e) { return Promise.reject(e); }
}
function LOGTEXT() { return Q("#activity-log li").map(function (li) { return li.textContent || ""; }); }
function CSS() {
  if (!D || E("smt-style")) return;
  var s = D.createElement("style"); s.id = "smt-style";
  s.textContent = ".smt-wrap{border:1px solid var(--line,rgba(148,170,200,.14));border-radius:var(--radius,14px);background:var(--surface,rgba(15,22,36,.88));padding:12px;margin:12px 0;font-size:12.5px}.smt-wrap h3{font-size:13px;margin:0 0 8px}.smt-row{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:6px 0}.smt-chip{cursor:pointer;border:1px solid var(--line-strong,rgba(148,170,200,.26));border-radius:999px;padding:2px 10px;font-size:11.5px;background:var(--surface-2,#131e30);color:var(--text-dim,#a7b4c8)}.smt-chip.is-on{background:var(--accent-soft,rgba(79,140,255,.14));color:var(--text,#e9eef7);font-weight:700}.smt-btn{cursor:pointer;border:1px solid var(--line-strong,rgba(148,170,200,.26));border-radius:8px;padding:3px 10px;font-size:12px;background:transparent;color:inherit}.smt-btn:hover{border-color:var(--accent-ring,rgba(79,140,255,.45))}.smt-table{width:100%;border-collapse:collapse;font-size:12px;margin-top:6px}.smt-table th,.smt-table td{border:1px solid var(--line,rgba(148,170,200,.14));padding:4px 7px;text-align:left}.smt-table th{color:var(--muted,#7d8ca3);font-weight:600}.smt-bar{height:8px;border-radius:999px;background:var(--surface-3,#182438);overflow:hidden;min-width:90px}.smt-bar i{display:block;height:100%;background:var(--accent,#4f8cff)}.smt-meter{font-variant-numeric:tabular-nums;color:var(--muted,#7d8ca3)}.smt-q{font-size:11px;color:var(--muted,#7d8ca3)}";
  try { D.head.appendChild(s); } catch (_) {}
}
function WRAP() {
  try {
    if (!D || !D.body) return null;
    var w = E("smt-collections");
    if (w && D.contains(w)) return w;
    w = MK("section", "smt-wrap"); w.id = "smt-collections";
    w.setAttribute("aria-label", "Smart collections");
    var h = MK("h3", null, "Smart collections"); w.appendChild(h);
    var sub = MK("div", "smt-q", "Local-only views built from on-page activity + existing status endpoints. Nothing is written back."); w.appendChild(sub);
    var host = Q(".activity-pane")[0] || Q("main.shell")[0] || D.body;
    try { host.appendChild(w); } catch (_) { D.body.appendChild(w); }
    return w;
  } catch (_) { return null; }
}
function ROW(wrap, title) {
  var r = MK("div", "smt-row"); r.setAttribute("data-smt-row", title);
  var b = MK("strong", null, title + ": "); b.style.minWidth = "150px"; r.appendChild(b);
  try { wrap.appendChild(r); } catch (_) {}
  return r;
}
// SMT-001
function w001(wrap) {
  try {
    var row = ROW(wrap, "New this week");
    var chip = MK("button", "smt-chip", "Show new (7d)"); chip.type = "button";
    var count = MK("span", "smt-q", ""); row.appendChild(chip); row.appendChild(count);
    GQ.newWeek = function () {
      var out = [];
      Q("#activity-log li").forEach(function (li) {
        var t = li.getAttribute("datetime") || li.getAttribute("data-ts") || (li.querySelector("time") || {}).dateTime || "";
        var ms = Date.parse(t);
        if (!isNaN(ms) && (Date.now() - ms) < 7 * 864e5) out.push(li);
      });
      return out;
    };
    ON(chip, "click", function () {
      var on = chip.classList.toggle("is-on");
      var hits = [];
      try { hits = GQ.newWeek(); } catch (_) { hits = []; }
      count.textContent = hits.length + " item(s) under 7 days";
      Q("#activity-log li").forEach(function (li) { if (on) li.style.display = hits.indexOf(li) >= 0 ? "" : "none"; else li.style.display = ""; });
      TS(on ? "Filtered to new-this-week (" + hits.length + ")." : "Filter cleared.");
    });
  } catch (_) {}
}
// SMT-002
function w002(wrap) {
  try {
    var row = ROW(wrap, "Duplicate finder");
    var btn = MK("button", "smt-btn", "Find duplicates"); btn.type = "button";
    var out = MK("div", "smt-q", "Same title, different quality badge."); row.appendChild(btn); wrap.appendChild(out);
    GQ.normTitle = function (s) {
      return String(s || "").toLowerCase().replace(/\b(2160p|1080p|720p|480p|4k|uhd|hdr|hevc|x265|x264|bluray|web-?dl|webrip|remux|extended|proper|repack)\b/g, " ").replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
    };
    ON(btn, "click", function () {
      var groups = {}, order = [];
      LOGTEXT().forEach(function (t) {
        var k = GQ.normTitle(t.slice(0, 120));
        if (!k) return;
        if (!groups[k]) { groups[k] = { n: 0, quals: {} }; order.push(k); }
        groups[k].n++;
        var q = /2160p|4k|uhd/i.test(t) ? "4K" : /1080p/i.test(t) ? "1080p" : /720p/i.test(t) ? "720p" : "other";
        groups[k].quals[q] = 1;
      });
      var dups = order.filter(function (k) { return groups[k].n > 1 && Object.keys(groups[k].quals).length > 1; }).slice(0, 20);
      out.innerHTML = dups.length ? ESC(dups.length + " candidate(s): ") + dups.map(function (k) { return "<span class='smt-chip'>" + ESC(k) + " ×" + groups[k].n + "</span>"; }).join(" ") : "No cross-quality duplicates found in visible activity.";
    });
  } catch (_) {}
}
// SMT-003
function w003(wrap) {
  try {
    var row = ROW(wrap, "Missing episodes");
    var btn = MK("button", "smt-btn", "Detect gaps"); btn.type = "button";
    var out = MK("div", "smt-q", "Looks for SxxEyy gaps per series."); row.appendChild(btn); wrap.appendChild(out);
    ON(btn, "click", function () {
      var shows = {};
      LOGTEXT().forEach(function (t) {
        var m = /(.+?)\s+[Ss](\d{1,2})[Ee](\d{1,3})/.exec(t);
        if (!m) return;
        var name = m[1].trim().toLowerCase().slice(-60), se = "S" + m[2], ep = NUM(m[3], 0);
        var k = name + " " + se;
        (shows[k] = shows[k] || []).push(ep);
      });
      var gaps = [];
      Object.keys(shows).slice(0, 40).forEach(function (k) {
        var eps = shows[k].filter(function (n) { return n > 0 && n < 400; }).sort(function (a, b) { return a - b; });
        for (var i = 1; i < eps.length; i++) { if (eps[i] - eps[i - 1] > 1) { gaps.push(k.toUpperCase() + ": missing E" + (eps[i - 1] + 1) + "–E" + (eps[i] - 1)); break; } }
      });
      out.textContent = gaps.length ? gaps.slice(0, 10).join(" · ") : "No numbering gaps found in visible activity.";
    });
  } catch (_) {}
}
// SMT-004
function w004(wrap) {
  try {
    var row = ROW(wrap, "Unwatched cleanup");
    var btn = MK("button", "smt-btn", "Suggest cleanup"); btn.type = "button";
    var out = MK("div", "smt-q", "Old + unwatched candidates."); row.appendChild(btn); wrap.appendChild(out);
    ON(btn, "click", function () {
      var cands = [];
      Q("#activity-log li").forEach(function (li) {
        var t = (li.textContent || "").toLowerCase();
        if (/play|watch|resume/.test(t)) return;
        var tm = li.getAttribute("datetime") || "";
        var age = Date.parse(tm);
        var old = !isNaN(age) ? (Date.now() - age > 180 * 864e5) : /download|add|sync/.test(t);
        if (old && cands.length < 20) cands.push((li.textContent || "").trim().slice(0, 90));
      });
      out.innerHTML = cands.length ? "<ul>" + cands.map(function (c) { return "<li>" + ESC(c) + "</li>"; }).join("") + "</ul>" : "Nothing looks stale + unwatched right now.";
    });
  } catch (_) {}
}
// SMT-005
function w005(wrap) {
  try {
    var row = ROW(wrap, "Storage hogs");
    var btn = MK("button", "smt-btn", "Top 20 biggest"); btn.type = "button";
    var out = MK("div", null, ""); row.appendChild(btn); wrap.appendChild(out);
    ON(btn, "click", function () {
      var items = [];
      LOGTEXT().forEach(function (t) {
        var m = /(\d+(?:\.\d+)?)\s*(TB|GB|MB|KB)\b/i.exec(t);
        if (!m) return;
        var v = NUM(m[1], 0), u = m[2].toUpperCase();
        var b = v * (u === "TB" ? 1099511627776 : u === "GB" ? 1073741824 : u === "MB" ? 1048576 : 1024);
        items.push({ t: t.slice(0, 100), b: b });
      });
      items.sort(function (a, b) { return b.b - a.b; });
      var top = items.slice(0, 20);
      out.innerHTML = top.length ? "<table class='smt-table'><thead><tr><th>#</th><th>Item</th><th>Size</th></tr></thead><tbody>" + top.map(function (r, i) { return "<tr><td>" + (i + 1) + "</td><td>" + ESC(r.t) + "</td><td>" + ESC(BYTES(r.b)) + "</td></tr>"; }).join("") + "</tbody></table>" : "No sized entries in visible activity.";
    });
  } catch (_) {}
}
// SMT-006
function w006(wrap) {
  try {
    var row = ROW(wrap, "Bandwidth meter");
    var lab = MK("span", "smt-meter", "idle"); row.appendChild(lab);
    GQ.bwTick = function () {
      try {
        return FETCHJ("/api/metrics", 6000).then(function (m) {
          var v = m && (m.bandwidth_bps != null ? m.bandwidth_bps : (m.streams && m.streams.bandwidth_bps));
          if (v == null && m && m.proxy && m.proxy.bandwidth_bps != null) v = m.proxy.bandwidth_bps;
          v = NUM(v, 0);
          lab.textContent = v > 0 ? (Math.round(v / 1e6 * 10) / 10) + " Mbps live" : "idle";
          return v;
        }, function () { lab.textContent = "metrics unavailable"; return 0; });
      } catch (_) { return Promise.resolve(0); }
    };
    try { if (W.setInterval) W.setInterval(function () { try { GQ.bwTick(); } catch (_) {} }, 15000); } catch (_) {}
    try { GQ.bwTick(); } catch (_) {}
  } catch (_) {}
}
// SMT-007
function w007(wrap) {
  try {
    var row = ROW(wrap, "Per-user watch stats");
    var btn = MK("button", "smt-btn", "Compute from activity"); btn.type = "button";
    var out = MK("div", null, ""); row.appendChild(btn); wrap.appendChild(out);
    ON(btn, "click", function () {
      var users = {};
      LOGTEXT().forEach(function (t) {
        var m = /(?:user|profile)\s+([a-z0-9_\-@.]+)/i.exec(t) || /^([a-z0-9_\-@.]+)\s+(played|watched|resumed)/i.exec(t);
        if (!m) return;
        var u = String(m[1] || "").toLowerCase().slice(0, 32);
        if (!u) return;
        var d = /(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)/i.exec(t);
        var mins = d ? (NUM(d[1], 0) * 60 + NUM(d[2], 0)) : 25;
        var r = users[u] = users[u] || { plays: 0, mins: 0 };
        r.plays++; r.mins += mins;
      });
      var keys = Object.keys(users).slice(0, 20);
      out.innerHTML = keys.length ? "<table class='smt-table'><thead><tr><th>User</th><th>Plays</th><th>Minutes</th></tr></thead><tbody>" + keys.map(function (k) { return "<tr><td>" + ESC(k) + "</td><td>" + users[k].plays + "</td><td>" + users[k].mins + "</td></tr>"; }).join("") + "</tbody></table>" : "No per-user play lines in visible activity.";
    });
  } catch (_) {}
}
// SMT-008
function w008(wrap) {
  try {
    var row = ROW(wrap, "Weekly digest");
    var btn = MK("button", "smt-btn", "Generate markdown"); btn.type = "button";
    var cp = MK("button", "smt-btn", "Copy"); cp.type = "button";
    var pre = MK("pre", "smt-q", "New-media markdown appears here."); row.appendChild(btn); row.appendChild(cp); wrap.appendChild(pre);
    GQ.digest = function () {
      var lines = ["# Weekly media digest", ""];
      var hits = [];
      try { hits = GQ.newWeek ? GQ.newWeek() : []; } catch (_) { hits = []; }
      var src = hits.length ? hits.map(function (li) { return li.textContent || ""; }) : LOGTEXT().slice(0, 30);
      src.slice(0, 30).forEach(function (t) { lines.push("- " + String(t).trim().slice(0, 110)); });
      if (!src.length) lines.push("- Nothing new this week.");
      return lines.join("\n");
    };
    ON(btn, "click", function () { try { pre.textContent = GQ.digest(); } catch (_) {} });
    ON(cp, "click", function () { try { CP(GQ.digest(), "Digest copied."); } catch (_) {} });
  } catch (_) {}
}
// SMT-009
function w009(wrap) {
  try {
    var row = ROW(wrap, "Queue position");
    var lab = MK("span", "smt-q", "checking…"); row.appendChild(lab);
    GQ.queueTick = function () {
      try {
        return FETCHJ("/api/status", 8000).then(function (s) {
          var q = null;
          try {
            q = s.queue || s.torbox_queue || (s.services && (s.services.torboxmount || {}).queue) || (s.torbox && s.torbox.queue);
          } catch (_) { q = null; }
          if (q == null) { lab.textContent = "no queue field in /api/status"; return null; }
          var pos = (q.position != null ? q.position : q.pos), of = (q.total != null ? q.total : q.size), nm = q.name || q.title || "";
          lab.textContent = pos != null ? "Position " + pos + (of != null ? " of " + of : "") + (nm ? " — " + String(nm).slice(0, 60) : "") : "Queue: " + String(JSON.stringify(q)).slice(0, 80);
          return q;
        }, function () { lab.textContent = "queue unavailable"; return null; });
      } catch (_) { return Promise.resolve(null); }
    };
    try { GQ.queueTick(); } catch (_) {}
  } catch (_) {}
}
// SMT-010
function w010() {
  try {
    if (!D) return;
    if (E("smt-quota")) return;
    var bar = MK("span", "smt-chip", "Drive: …"); bar.id = "smt-quota"; bar.title = "GDrive quota (from /api/status quota field)";
    var host = Q(".topbar-status")[0] || Q("header.topbar")[0];
    if (host) { try { host.appendChild(bar); } catch (_) { return; } } else return;
    GQ.quotaTick = function () {
      try {
        return FETCHJ("/api/status", 8000).then(function (s) {
          var q = null;
          try { q = s.quota || s.gdrive_quota || (s.services && s.services.gdrive && s.services.gdrive.quota) || (s.gdrive && s.gdrive.quota); } catch (_) { q = null; }
          if (!q) { bar.textContent = "Drive: n/a"; return null; }
          var used = NUM(q.used != null ? q.used : q.used_bytes, NaN), total = NUM(q.total != null ? q.total : q.total_bytes, NaN);
          var pct = (isFinite(used) && isFinite(total) && total > 0) ? Math.max(0, Math.min(100, used / total * 100)) : (q.pct != null ? NUM(q.pct, 0) : null);
          bar.innerHTML = "";
          var t = MK("span", null, "Drive " + (pct != null ? Math.round(pct) + "%" : (q.label || "ok")) + " ");
          var track = MK("span", "smt-bar"); track.style.display = "inline-block"; track.style.width = "70px"; track.style.verticalAlign = "middle";
          var fill = MK("i", null, ""); try { fill.style.width = (pct != null ? pct : 0) + "%"; } catch (_) {}
          track.appendChild(fill); bar.appendChild(t); bar.appendChild(track);
          bar.title = "Used " + (isFinite(used) ? BYTES(used) : "?") + " of " + (isFinite(total) ? BYTES(total) : "?");
          return q;
        }, function () { bar.textContent = "Drive: ?"; return null; });
      } catch (_) { return Promise.resolve(null); }
    };
    try { GQ.quotaTick(); } catch (_) {}
  } catch (_) {}
}
function BOOT() {
  try {
    if (!D || !D.body) return;
    CSS();
    var w = WRAP();
    if (!w) return;
    w001(w); w002(w); w003(w); w004(w); w005(w); w006(w); w007(w); w008(w); w009(w); w010();
  } catch (_) {}
}
GQ.boot = BOOT;
try {
  if (D && D.readyState === "loading") D.addEventListener("DOMContentLoaded", BOOT);
  else if (D) BOOT();
} catch (_) {}
} catch (_) {}
})();
