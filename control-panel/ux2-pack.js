(function () {
"use strict";
try {
function G(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function SV(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function GJ(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } }
function SJ(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }
function E(id) { return document.getElementById(id); }
function MK(t, c, x) { var n = document.createElement(t); if (c) n.className = c; if (x != null) n.textContent = x; return n; }
function TS(m) { var t = E("toast"); if (t) { t.textContent = m; t.className = "toast show"; clearTimeout(TS._t); TS._t = setTimeout(function () { t.classList.remove("show"); }, 4200); } }
function ON(n, e, f) { if (n) n.addEventListener(e, f); }
function CP(t, msg) {
  function fb() { var ta = document.createElement("textarea"); ta.value = t; document.body.appendChild(ta); ta.select(); try { document.execCommand("copy"); } catch (_) {} ta.remove(); TS(msg || "Copied."); }
  if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(function () { TS(msg || "Copied."); }, fb); else fb();
}
function CARDS() { return Array.prototype.slice.call(document.querySelectorAll("#services .service-card[data-service-id]")); }
function SID(c) { return c.getAttribute("data-service-id") || ""; }
function LOGS() { return Array.prototype.slice.call(document.querySelectorAll("#activity-log li")); }
function DL(name, text, mime) { var b = new Blob([text], { type: mime || "text/plain" }); var u = URL.createObjectURL(b); var a = document.createElement("a"); a.href = u; a.download = name; document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(u); a.remove(); }, 600); }
function STAMP() { var d = new Date(); function p(n) { return (n < 10 ? "0" : "") + n; } return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + "-" + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds()); }
function VIS() { return LOGS().filter(function (li) { return li.style.display !== "none"; }); }
function TXTL(li) { return (li.textContent || "").toLowerCase(); }
var LS = { views: "ux2.views", dview: "ux2.defaultView", sort: "ux2.tblSort", opq: "ux2.opq", tr: "ux2.timerange", iv: "ux2.interval", snd: "ux2.sound", pins: "ux2.pins", notes: "ux2.notes", recent: "ux2.recent", notif: "ux2.notifs", sched: "ux2.sched", tab: "ux2.tab", dock: "ux2.dock", seq: "ux2.seq" };
function CSS() {
  if (E("ux2-style")) return;
  var s = document.createElement("style"); s.id = "ux2-style";
  s.textContent = ".ux2-bar{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 10px;padding:8px;border:1px solid var(--accent-ring,#334);border-radius:10px;font-size:12px}.ux2-bar .ux2-grp{display:flex;flex-wrap:wrap;gap:6px;align-items:center}.ux2-bar .ux2-sep{width:1px;height:18px;background:var(--accent-ring,#334)}.ux2-chip{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:999px;padding:2px 10px;font-size:12px;background:transparent;color:inherit}.ux2-chip.is-on{background:var(--accent-soft,rgba(122,168,255,.15));font-weight:700}.ux2-btn{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:8px;padding:3px 10px;font-size:12px;background:transparent;color:inherit}.ux2-btn:hover{border-color:var(--accent,#4f8cff)}.ux2-sel select,.ux2-sel input[type=text],.ux2-sel input[type=search]{font:inherit;font-size:12px;padding:3px 8px;border-radius:8px;border:1px solid var(--accent-ring,#334);background:transparent;color:inherit;max-width:190px}.ux2-drawer{position:fixed;top:0;right:0;bottom:0;width:min(380px,92vw);z-index:90;background:var(--bg,#0e1522);border-left:1px solid var(--accent-ring,#334);padding:14px;overflow:auto;box-shadow:-12px 0 32px rgba(0,0,0,.4)}.ux2-dock{position:fixed;left:12px;bottom:12px;z-index:80;display:flex;gap:6px;flex-wrap:wrap;background:var(--bg,#0e1522);border:1px solid var(--accent-ring,#334);border-radius:12px;padding:8px 10px;font-size:12px}.ux2-note{width:100%;font:inherit;font-size:12px;margin-top:6px;border-radius:8px;border:1px solid var(--accent-ring,#334);background:transparent;color:inherit;padding:6px}.ux2-pinbtn,.ux2-cpbtn{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:6px;font-size:11px;padding:1px 7px;background:transparent;color:inherit;margin:2px 4px 2px 0}.ux2-warn{border:1px solid rgba(240,179,92,.5);border-radius:10px;padding:10px;margin:8px 0;font-size:13px}.ux2-err-card{border:1px solid rgba(240,106,106,.5);border-radius:10px;padding:10px;margin:8px 0;font-size:13px}.ux2-flash{outline:2px solid #f0b35c !important;outline-offset:2px}.ux2-pulse{animation:ux2p 1s ease 2}@keyframes ux2p{50%{background:rgba(240,179,92,.35)}}.ux2-pre{max-height:220px;overflow:auto;font-size:11.5px;background:rgba(0,0,0,.3);border-radius:8px;padding:8px;white-space:pre-wrap;word-break:break-word}.ux2-kv{display:flex;gap:6px;align-items:center;flex-wrap:wrap}.ux2-count{font-size:11px;opacity:.8}.ux2-bell{position:relative}.ux2-bell .ux2-dot{position:absolute;top:-6px;right:-6px;min-width:17px;height:17px;border-radius:999px;background:#f06a6a;color:#fff;font-size:10px;display:flex;align-items:center;justify-content:center;padding:0 4px}";
  document.head.appendChild(s);
}
// UX2-001
function w001() { try { CSS(); var m = document.querySelector("main.shell"); if (!m || E("ux2-bar")) return; var b = MK("div", "ux2-bar"); b.id = "ux2-bar"; b.setAttribute("role", "toolbar"); b.setAttribute("aria-label", "Extended panel tools"); m.insertBefore(b, m.firstChild); } catch (_) {} }
// UX2-002
function w002() { try { var b = E("ux2-bar"); if (!b) return; var g = MK("div", "ux2-grp"); g.id = "ux2-views"; var lab = MK("span", "ux2-count", "Views:"); g.appendChild(lab); var sv = MK("button", "ux2-btn", "Save view"); sv.id = "ux2-save-view"; sv.type = "button"; g.appendChild(sv); b.appendChild(g); } catch (_) {} }
// UX2-003
function w003() {
  try {
    var sv = E("ux2-save-view"); if (!sv || sv._w) return; sv._w = 1;
    ON(sv, "click", function () {
      var name = null; try { name = window.prompt("Name this filter view:", "my view"); } catch (_) {}
      if (!name) return; name = String(name).slice(0, 40);
      var q = E("ux-activity-search") ? E("ux-activity-search").value : (E("ux2-opq") ? E("ux2-opq").value : "");
      var src = G("jellyfin.panel.activity.sourceFilter", "all");
      var eo = E("activity-errors-only") ? !!E("activity-errors-only").checked : false;
      var tr = G(LS.tr, "all");
      var v = GJ(LS.views, []); v = v.filter(function (x) { return x.name !== name; }); v.push({ name: name, q: q, src: src, eo: eo, tr: tr });
      SJ(LS.views, v.slice(-12)); w004r(); TS("View saved: " + name);
    });
  } catch (_) {}
}
function w004r() { try { paintViews(); } catch (_) {} }
// UX2-004
function w004() {
  try {
    window.paintViews = function () {
      var wrap = E("ux2-views"); if (!wrap) return;
      Array.prototype.slice.call(wrap.querySelectorAll(".ux2-chip[data-view]")).forEach(function (c) { c.remove(); });
      GJ(LS.views, []).forEach(function (v) {
        var c = MK("button", "ux2-chip", v.name); c.type = "button"; c.setAttribute("data-view", v.name); c.title = "Apply view (double-click deletes)";
        ON(c, "click", function () { applyView(v); });
        ON(c, "dblclick", function () { if (window.confirm("Delete view '" + v.name + "'?")) { SJ(LS.views, GJ(LS.views, []).filter(function (x) { return x.name !== v.name; })); paintViews(); TS("View deleted."); } });
        wrap.appendChild(c);
      });
    };
    paintViews();
  } catch (_) {}
}
function applyView(v) {
  try {
    var s = E("ux-activity-search"); if (s) { s.value = v.q || ""; s.dispatchEvent(new Event("input", { bubbles: true })); }
    var o = E("ux2-opq"); if (o) { o.value = v.q || ""; o.dispatchEvent(new Event("input", { bubbles: true })); }
    var e = E("activity-errors-only"); if (e && !!e.checked !== !!v.eo) { e.checked = !!v.eo; e.dispatchEvent(new Event("change", { bubbles: true })); }
    if (v.src) { try { localStorage.setItem("jellyfin.panel.activity.sourceFilter", v.src); } catch (_) {} var chips = E("activity-chips"); if (chips) { var btns = chips.querySelectorAll("button"); for (var i = 0; i < btns.length; i++) { if ((btns[i].textContent || "").toLowerCase().indexOf(String(v.src).toLowerCase()) >= 0) { btns[i].click(); break; } } } }
    if (v.tr) { SV(LS.tr, v.tr); paintTR(); applyTR(); }
    TS("View applied: " + v.name);
  } catch (_) {}
}
// UX2-005
function w005() {
  try {
    var wrap = E("ux2-views"); if (!wrap || E("ux2-def-view")) return;
    var b = MK("button", "ux2-btn", "Set default"); b.id = "ux2-def-view"; b.type = "button"; b.title = "Save current filters as the default view applied on load";
    ON(b, "click", function () {
      var q = E("ux-activity-search") ? E("ux-activity-search").value : "";
      SJ(LS.dview, { q: q, src: G("jellyfin.panel.activity.sourceFilter", "all"), eo: E("activity-errors-only") ? !!E("activity-errors-only").checked : false });
      TS("Default view saved.");
    });
    wrap.appendChild(b);
    try { if (!sessionStorage.getItem("ux2.dv") && GJ(LS.dview, null)) { sessionStorage.setItem("ux2.dv", "1"); applyView({ name: "default", q: GJ(LS.dview, {}).q, src: GJ(LS.dview, {}).src, eo: GJ(LS.dview, {}).eo }); } } catch (_) {}
  } catch (_) {}
}
// UX2-006
function w006() {
  try {
    var ths = document.querySelectorAll(".endpoints-details thead th, .table-wrap thead th"); if (!ths.length || ths[0]._ux2) return;
    Array.prototype.forEach.call(ths, function (th, i) { th._ux2 = 1; th.style.cursor = "pointer"; th.title = "Sort column"; ON(th, "click", function () { sortTbl(th.closest("table"), i); }); });
  } catch (_) {}
}
function sortTbl(t, i) {
  try {
    if (!t) return; var tb = t.tBodies[0]; if (!tb) return;
    var rows = Array.prototype.slice.call(tb.rows);
    var prev = GJ(LS.sort, {}); var dir = (prev.i === i && prev.d === "a") ? "d" : "a";
    var num = rows.every(function (r) { return !r.cells[i] || /^[0-9.\s]*$/.test((r.cells[i].textContent || "").trim()); });
    rows.sort(function (a, b) {
      var x = (a.cells[i] ? a.cells[i].textContent.trim() : ""), y = (b.cells[i] ? b.cells[i].textContent.trim() : "");
      var c = num ? (parseFloat(x) - parseFloat(y)) : x.localeCompare(y);
      return dir === "a" ? c : -c;
    });
    rows.forEach(function (r) { tb.appendChild(r); });
    SJ(LS.sort, { i: i, d: dir }); paintSortInd(t, i, dir);
  } catch (_) {}
}
// UX2-007
function w007() { try { var t = document.querySelector(".endpoints-details table, .table-wrap table"); var p = GJ(LS.sort, {}); if (t && p.i != null) paintSortInd(t, p.i, p.d); } catch (_) {} }
function paintSortInd(t, i, d) {
  try {
    Array.prototype.forEach.call(t.querySelectorAll("thead th"), function (th, k) {
      var tx = (th.textContent || "").replace(/ [▲▼]$/, "");
      th.textContent = tx + (k === i ? (d === "a" ? " ▲" : " ▼") : "");
    });
  } catch (_) {}
}
// UX2-008
function w008() { try { var t = document.querySelector(".endpoints-details table"); if (t && !t._ux2n) { t._ux2n = 1; } } catch (_) {} }
// UX2-009
function w009() { try { var t = document.querySelector(".endpoints-details table, .table-wrap table"); var p = GJ(LS.sort, null); if (t && p && p.i != null) sortTbl(t, p.i === 0 ? 1 : p.i); } catch (_) {} }
// UX2-010
function w010() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-opq")) return;
    var g = MK("div", "ux2-grp ux2-sel"); var lab = MK("span", "ux2-count", "Find:"); g.appendChild(lab);
    var inp = document.createElement("input"); inp.id = "ux2-opq"; inp.type = "search"; inp.placeholder = "status:stopped source:jellyfin level:error text"; inp.setAttribute("aria-label", "Smart search with operators"); inp.value = G(LS.opq, "");
    g.appendChild(inp);
    var clr = MK("button", "ux2-btn", "Clear"); clr.type = "button"; clr.id = "ux2-opq-clear"; g.appendChild(clr);
    b.appendChild(g); var sp = MK("span", "ux2-sep"); b.appendChild(sp);
    var tm = null;
    ON(inp, "input", function () { SV(LS.opq, inp.value); clearTimeout(tm); tm = setTimeout(applyOps, 180); });
    ON(clr, "click", function () { inp.value = ""; SV(LS.opq, ""); applyOps(); });
  } catch (_) {}
}
function parseOps(q) {
  var o = { status: null, source: null, level: null, port: null, text: [] };
  String(q || "").split(/\s+/).forEach(function (tok) {
    var m = tok.match(/^(status|source|level|port):(.+)$/i);
    if (m) o[m[1].toLowerCase()] = m[2].toLowerCase(); else if (tok) o.text.push(tok.toLowerCase());
  });
  return o;
}
// UX2-011
function w011() { try { applyOps(); } catch (_) {} }
function applyOps() {
  try {
    var inp = E("ux2-opq"); if (!inp) return; var o = parseOps(inp.value);
    LOGS().forEach(function (li) {
      var t = TXTL(li); var show = true;
      if (o.status && t.indexOf(o.status) < 0) show = false;
      if (show && o.source && t.indexOf(o.source) < 0) show = false;
      if (show && o.level) {
        var lv = o.level;
        if (lv === "error" || lv === "err") { if (!(li.className.indexOf("error") >= 0 || t.indexOf("error") >= 0 || t.indexOf("fail") >= 0)) show = false; }
        else if (lv === "warn" || lv === "warning") { if (!(li.className.indexOf("warn") >= 0 || t.indexOf("warn") >= 0)) show = false; }
        else if (t.indexOf(lv) < 0) show = false;
      }
      if (show && o.port && t.indexOf(o.port) < 0) show = false;
      if (show) o.text.forEach(function (w) { if (t.indexOf(w) < 0) show = false; });
      li.style.display = show ? "" : "none";
    });
    applyTR();
  } catch (_) {}
}
// UX2-012
function w012() {
  try {
    var g = E("ux2-opq") ? E("ux2-opq").parentNode : null; if (!g || E("ux2-op-hint")) return;
    var h = MK("span", "ux2-count", "status: source: level: port: + text"); h.id = "ux2-op-hint"; h.title = "All operators combine with AND"; g.appendChild(h);
  } catch (_) {}
}
// UX2-013
function w013() {
  try {
    var log = E("activity-log"); if (!log || log._ux2op) return; log._ux2op = 1;
    var tm = null;
    new MutationObserver(function () { clearTimeout(tm); tm = setTimeout(function () { applyOps(); }, 400); }).observe(log, { childList: true });
  } catch (_) {}
}
// UX2-014
function w014() {
  try {
    var inp = E("ux2-opq"); if (!inp || inp._ux2s) return; inp._ux2s = 1;
    ON(inp, "keydown", function (ev) { if (ev.key === "Escape") { inp.value = ""; SV(LS.opq, ""); applyOps(); inp.blur(); } });
  } catch (_) {}
}
// UX2-015
function w015() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-op-count")) return;
    var c = MK("span", "ux2-count", ""); c.id = "ux2-op-count"; b.appendChild(c);
    setInterval(function () { try { var v = VIS().length, a = LOGS().length; c.textContent = v + "/" + a + " shown"; } catch (_) {} }, 2000);
  } catch (_) {}
}
// UX2-016
function w016() {
  try {
    if (E("ux2-bulkbar")) return; var b = E("ux2-bar"); if (!b) return;
    var g = MK("div", "ux2-grp"); g.id = "ux2-bulkbar";
    var all = MK("button", "ux2-btn", "Select all"); all.type = "button"; all.id = "ux2-sel-all";
    var none = MK("button", "ux2-btn", "None"); none.type = "button"; none.id = "ux2-sel-none";
    var cnt = MK("span", "ux2-count", "0 selected"); cnt.id = "ux2-sel-count";
    var goS = MK("button", "ux2-btn", "Start selected"); goS.type = "button"; goS.id = "ux2-bulk-start";
    var goR = MK("button", "ux2-btn", "Restart selected"); goR.type = "button"; goR.id = "ux2-bulk-restart";
    var goF = MK("button", "ux2-btn", "Retry failed"); goF.type = "button"; goF.id = "ux2-bulk-retry";
    [all, none, cnt, goS, goR, goF].forEach(function (n) { g.appendChild(n); });
    b.appendChild(g); b.appendChild(MK("span", "ux2-sep"));
    ON(all, "click", function () { selAll(true); }); ON(none, "click", function () { selAll(false); });
    ON(goS, "click", function () { bulkDo("start", false); }); ON(goR, "click", function () { bulkDo("restart", false); }); ON(goF, "click", function () { bulkDo("start", true); });
  } catch (_) {}
}
function selAll(on) { try { CARDS().forEach(function (c) { var x = c.querySelector(".ux2-sel"); if (x) x.checked = on; }); paintSel(); } catch (_) {} }
function selList() { try { return CARDS().filter(function (c) { var x = c.querySelector(".ux2-sel"); return x && x.checked; }); } catch (_) { return []; } }
function paintSel() { try { var n = E("ux2-sel-count"); if (n) n.textContent = selList().length + " selected"; } catch (_) {} }
// UX2-017
function w017() {
  try {
    function add() {
      CARDS().forEach(function (c) {
        if (c.querySelector(".ux2-sel")) return;
        var x = document.createElement("input"); x.type = "checkbox"; x.className = "ux2-sel"; x.title = "Select for bulk actions"; x.setAttribute("aria-label", "Select " + SID(c));
        ON(x, "change", paintSel);
        c.insertBefore(x, c.firstChild);
      });
      paintSel();
    }
    add();
    var sv = E("services"); if (sv && !sv._ux2sel) { sv._ux2sel = 1; new MutationObserver(add).observe(sv, { childList: true, subtree: true }); }
  } catch (_) {}
}
// UX2-018
function w018() { try { paintSel(); } catch (_) {} }
function bulkDo(action, failedOnly) {
  try {
    var list = selList();
    if (failedOnly) list = CARDS().filter(function (c) { return /stop|error|fail|down|unreach/i.test(c.textContent || ""); });
    if (!list.length) { TS(failedOnly ? "No failed services found." : "Select services first."); return; }
    var n = 0;
    list.forEach(function (c, i) {
      setTimeout(function () {
        var btn = c.querySelector('button[data-action="' + action + '"]') || c.querySelector("button[data-action]");
        if (btn && !btn.disabled) { btn.click(); n++; }
        if (i === list.length - 1) setTimeout(function () { TS("Bulk " + action + ": " + n + "/" + list.length + " sent."); selAll(false); }, 600);
      }, i * 700);
    });
  } catch (_) {}
}
// UX2-019
function w019() { try { var n = E("ux2-sel-count"); if (n) n.title = "Bulk actions stagger 700ms apart to avoid overloading the panel"; } catch (_) {} }
// UX2-020
function w020() {
  try {
    var sv = E("services"); if (!sv || sv._ux2kb) return; sv._ux2kb = 1;
    ON(sv, "keydown", function (ev) { if (ev.target && ev.target.classList && ev.target.classList.contains("ux2-sel") && (ev.key === " " || ev.key === "Enter")) paintSel(); });
  } catch (_) {}
}
// UX2-021
function w021() {
  try {
    var g = E("ux2-bulkbar"); if (!g || E("ux2-sel-inv")) return;
    var b = MK("button", "ux2-btn", "Invert"); b.id = "ux2-sel-inv"; b.type = "button"; b.title = "Invert selection";
    ON(b, "click", function () { CARDS().forEach(function (c) { var x = c.querySelector(".ux2-sel"); if (x) x.checked = !x.checked; }); paintSel(); });
    g.appendChild(b);
  } catch (_) {}
}
// UX2-022
function w022() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-exp-json")) return;
    var g = MK("div", "ux2-grp");
    [["ux2-exp-json", "Export JSON"], ["ux2-exp-csv", "Export CSV"], ["ux2-exp-copy", "Copy visible"]].forEach(function (d) {
      var x = MK("button", "ux2-btn", d[1]); x.id = d[0]; x.type = "button"; g.appendChild(x);
    });
    b.appendChild(g);
    ON(E("ux2-exp-json"), "click", function () {
      var rows = VIS().map(function (li) { return { t: li.textContent.trim(), cls: li.className }; });
      DL("panel-logs-" + STAMP() + ".json", JSON.stringify({ exportedAt: new Date().toISOString(), count: rows.length, rows: rows }, null, 2), "application/json");
      TS("Exported " + rows.length + " log rows (JSON).");
    });
  } catch (_) {}
}
// UX2-023
function w023() {
  try {
    var b = E("ux2-exp-csv"); if (!b || b._w) return; b._w = 1;
    ON(b, "click", function () {
      function q(s) { return '"' + String(s == null ? "" : s).replace(/"/g, '""') + '"'; }
      var csv = "time,message\n" + VIS().map(function (li) {
        var t = (li.textContent || "").trim(); var m = t.match(/^\[([^\]]+)\]\s*([\s\S]*)$/);
        return q(m ? m[1] : "") + "," + q(m ? m[2] : t);
      }).join("\n");
      DL("panel-logs-" + STAMP() + ".csv", csv, "text/csv"); TS("Exported visible logs (CSV).");
    });
  } catch (_) {}
}
// UX2-024
function w024() {
  try {
    var b = E("ux2-exp-copy"); if (!b || b._w) return; b._w = 1;
    ON(b, "click", function () { var t = VIS().map(function (li) { return li.textContent.trim(); }).join("\n") || "(no visible logs)"; CP(t, "Visible logs copied."); });
  } catch (_) {}
}
// UX2-025
function w025() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-exp-err")) return;
    var x = MK("button", "ux2-btn", "Export errors"); x.id = "ux2-exp-err"; x.type = "button"; x.title = "Download only visible error/warning rows as JSON";
    ON(x, "click", function () {
      var rows = VIS().filter(function (li) { var t = TXTL(li); return /error|fail|warn|stop|down/.test(t); }).map(function (li) { return li.textContent.trim(); });
      DL("panel-errors-" + STAMP() + ".json", JSON.stringify(rows, null, 2), "application/json"); TS("Exported " + rows.length + " error rows.");
    });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-026
function w026() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-exp-svc")) return;
    var x = MK("button", "ux2-btn", "Export services"); x.id = "ux2-exp-svc"; x.type = "button"; x.title = "Download current service states as JSON";
    ON(x, "click", function () {
      var rows = CARDS().map(function (c) { return { id: SID(c), text: (c.textContent || "").replace(/\s+/g, " ").trim().slice(0, 300) }; });
      DL("panel-services-" + STAMP() + ".json", JSON.stringify(rows, null, 2), "application/json"); TS("Exported " + rows.length + " services.");
    });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-027
function w027() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-notifs")) return;
    var g = MK("div", "ux2-grp"); g.id = "ux2-notifs";
    var bell = MK("button", "ux2-btn ux2-bell", "Notifications"); bell.id = "ux2-bell"; bell.type = "button";
    var dot = MK("span", "ux2-dot", "0"); dot.id = "ux2-bell-dot"; dot.hidden = true; bell.appendChild(dot);
    var hist = MK("button", "ux2-btn", "History"); hist.id = "ux2-hist"; hist.type = "button";
    g.appendChild(bell); g.appendChild(hist); b.appendChild(g);
    ON(bell, "click", function () { toggleDrawer("ux2-drawer-notif"); markRead(); });
    ON(hist, "click", function () { toggleDrawer("ux2-drawer-notif"); markRead(); });
  } catch (_) {}
}
function notifStore() { return GJ(LS.notif, { items: [], unread: 0 }); }
function pushNotif(msg, kind) {
  try {
    var st = notifStore(); st.items.push({ t: new Date().toISOString(), msg: String(msg).slice(0, 300), kind: kind || "info" });
    st.items = st.items.slice(-100); st.unread = Math.min(99, (st.unread || 0) + 1); SJ(LS.notif, st);
    paintBell(); renderNotifs();
  } catch (_) {}
}
function paintBell() { try { var d = E("ux2-bell-dot"); var st = notifStore(); if (d) { d.hidden = !(st.unread > 0); d.textContent = String(st.unread || 0); } } catch (_) {} }
function markRead() { try { var st = notifStore(); st.unread = 0; SJ(LS.notif, st); paintBell(); } catch (_) {} }
// UX2-028
function w028() {
  try {
    if (E("ux2-drawer-notif")) return;
    var d = MK("div", "ux2-drawer"); d.id = "ux2-drawer-notif"; d.hidden = true; d.setAttribute("role", "dialog"); d.setAttribute("aria-label", "Notification center");
    var h = MK("h2", null, "Notification center"); d.appendChild(h);
    var row = MK("div", "ux2-kv");
    var mr = MK("button", "ux2-btn", "Mark read"); mr.type = "button";
    var cl = MK("button", "ux2-btn", "Clear history"); cl.type = "button";
    var x = MK("button", "ux2-btn", "Close"); x.type = "button";
    ON(mr, "click", markRead); ON(cl, "click", function () { SJ(LS.notif, { items: [], unread: 0 }); renderNotifs(); paintBell(); }); ON(x, "click", function () { d.hidden = true; });
    [mr, cl, x].forEach(function (n) { row.appendChild(n); }); d.appendChild(row);
    var ol = MK("ol", null, null); ol.id = "ux2-notif-list"; ol.style.cssText = "padding-left:18px;font-size:13px"; d.appendChild(ol);
    document.body.appendChild(d); renderNotifs(); paintBell();
  } catch (_) {}
}
function renderNotifs() {
  try {
    var ol = E("ux2-notif-list"); if (!ol) return; ol.innerHTML = "";
    var items = notifStore().items.slice().reverse();
    if (!items.length) { var li = MK("li", null, "No notifications yet. Panel toasts and failures appear here."); ol.appendChild(li); return; }
    items.slice(0, 60).forEach(function (n) {
      var li = MK("li", null, "[" + n.t.slice(11, 19) + "] " + n.msg); li.title = n.t;
      ON(li, "click", function () { CP(n.msg, "Notification copied."); });
      ol.appendChild(li);
    });
  } catch (_) {}
}
function toggleDrawer(id) { try { var d = E(id); if (!d) return; var open = d.hidden; document.querySelectorAll(".ux2-drawer").forEach(function (x) { x.hidden = true; }); d.hidden = !open; } catch (_) {} }
// UX2-029
function w029() {
  try {
    var t = E("toast"); if (!t || t._ux2n) return; t._ux2n = 1;
    new MutationObserver(function () { var m = (t.textContent || "").trim(); if (m) pushNotif(m, /fail|error|offline/i.test(m) ? "error" : "info"); }).observe(t, { childList: true, characterData: true, subtree: true });
  } catch (_) {}
}
// UX2-030
function w030() {
  try {
    var log = E("activity-log"); if (!log || log._ux2ne) return; log._ux2ne = 1;
    var seen = {};
    new MutationObserver(function () {
      LOGS().slice(-5).forEach(function (li) {
        var t = (li.textContent || "").trim();
        if (/error|fail/i.test(t) && !seen[t]) { seen[t] = 1; pushNotif(t.slice(0, 200), "error"); }
      });
    }).observe(log, { childList: true });
  } catch (_) {}
}
// UX2-031
function w031() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-notif-test")) return;
    var x = MK("button", "ux2-btn", "Test notify"); x.id = "ux2-notif-test"; x.type = "button"; x.title = "Send a test notification";
    ON(x, "click", function () { pushNotif("Test notification at " + new Date().toLocaleTimeString(), "info"); TS("Test notification sent."); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-032
function w032() {
  try {
    document.querySelectorAll(".ux2-drawer").forEach(function (d) {
      if (d._ux2esc) return; d._ux2esc = 1;
      ON(d, "keydown", function (ev) { if (ev.key === "Escape") d.hidden = true; });
    });
  } catch (_) {}
}
// UX2-033
function w033() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-sched")) return;
    var g = MK("div", "ux2-grp ux2-sel"); g.id = "ux2-sched";
    g.appendChild(MK("span", "ux2-count", "Run in:"));
    var svc = document.createElement("select"); svc.id = "ux2-sch-svc"; svc.setAttribute("aria-label", "Scheduled service");
    ["all", "gdrive", "torboxmount", "jellyfin", "proxy", "bridge", "torbox-sync"].forEach(function (s) { var o = document.createElement("option"); o.value = s; o.textContent = s; svc.appendChild(o); });
    var act = document.createElement("select"); act.id = "ux2-sch-act"; act.setAttribute("aria-label", "Scheduled action");
    ["start", "restart", "stop", "sync"].forEach(function (s) { var o = document.createElement("option"); o.value = s; o.textContent = s; act.appendChild(o); });
    var del = document.createElement("select"); del.id = "ux2-sch-delay"; del.setAttribute("aria-label", "Delay");
    [["30", "30s"], ["60", "1m"], ["300", "5m"], ["900", "15m"]].forEach(function (p) { var o = document.createElement("option"); o.value = p[0]; o.textContent = p[1]; del.appendChild(o); });
    var go = MK("button", "ux2-btn", "Schedule"); go.id = "ux2-sch-go"; go.type = "button";
    [svc, act, del, go].forEach(function (n) { g.appendChild(n); });
    b.appendChild(g);
    ON(go, "click", function () {
      var items = GJ(LS.sched, []);
      items.push({ svc: svc.value, act: act.value, at: Date.now() + parseInt(del.value, 10) * 1000 });
      SJ(LS.sched, items); renderSched(); TS("Scheduled " + act.value + " " + svc.value + " in " + del.selectedOptions[0].text + ".");
    });
  } catch (_) {}
}
function renderSched() {
  try {
    var box = E("ux2-sched-list");
    if (!box) {
      var b = E("ux2-bar"); if (!b) return;
      box = MK("span", "ux2-count", ""); box.id = "ux2-sched-list"; b.appendChild(box);
    }
    var items = GJ(LS.sched, []).filter(function (x) { return x.at > Date.now(); });
    SJ(LS.sched, items);
    box.innerHTML = "";
    if (!items.length) { box.textContent = "No scheduled actions."; return; }
    items.forEach(function (x, i) {
      var s = Math.max(0, Math.round((x.at - Date.now()) / 1000));
      var chip = MK("button", "ux2-chip", x.act + " " + x.svc + " in " + s + "s ✕"); chip.type = "button"; chip.title = "Click to cancel";
      ON(chip, "click", function () { var it = GJ(LS.sched, []); it.splice(i, 1); SJ(LS.sched, it); renderSched(); TS("Scheduled action cancelled."); });
      box.appendChild(chip);
    });
  } catch (_) {}
}
// UX2-034
function w034() {
  try {
    if (w034._x) return; w034._x = 1;
    setInterval(function () {
      try {
        var items = GJ(LS.sched, []); var keep = []; var changed = false;
        items.forEach(function (x) {
          if (x.at <= Date.now()) {
            changed = true;
            var btn = document.querySelector('button[data-action="' + x.act + '"][data-service="' + x.svc + '"]');
            if (btn && !btn.disabled) btn.click(); pushNotif("Scheduled action fired: " + x.act + " " + x.svc, "info");
          } else keep.push(x);
        });
        if (changed) SJ(LS.sched, keep);
        renderSched();
      } catch (_) {}
    }, 1000);
  } catch (_) {}
}
// UX2-035
function w035() { try { renderSched(); } catch (_) {} }
// UX2-036
function w036() {
  try {
    var g = E("ux2-sched"); if (!g || E("ux2-sch-clear")) return;
    var x = MK("button", "ux2-btn", "Clear all"); x.id = "ux2-sch-clear"; x.type = "button";
    ON(x, "click", function () { SJ(LS.sched, []); renderSched(); TS("All scheduled actions cleared."); });
    g.appendChild(x);
  } catch (_) {}
}
// UX2-037
function w037() {
  try {
    var items = GJ(LS.sched, []); if (items.length) pushNotif(items.length + " scheduled action(s) restored after reload.", "info");
  } catch (_) {}
}
// UX2-038
function w038() {
  try {
    if (E("ux2-pinstrip")) return; var b = E("ux2-bar"); if (!b) return;
    var g = MK("div", "ux2-grp"); g.id = "ux2-pinstrip"; g.appendChild(MK("span", "ux2-count", "Pinned:")); b.appendChild(g);
  } catch (_) {}
}
function pinSet() { try { return GJ(LS.pins, []); } catch (_) { return []; } }
// UX2-039
function w039() {
  try {
    function add() {
      CARDS().forEach(function (c) {
        if (c.querySelector(".ux2-pinbtn")) return;
        var p = MK("button", "ux2-pinbtn", pinSet().indexOf(SID(c)) >= 0 ? "★" : "☆"); p.type = "button"; p.title = "Pin service";
        p.setAttribute("aria-label", "Pin " + SID(c));
        ON(p, "click", function (ev) {
          ev.stopPropagation();
          var s = pinSet(); var id = SID(c);
          s = s.indexOf(id) >= 0 ? s.filter(function (x) { return x !== id; }) : s.concat([id]);
          SJ(LS.pins, s); p.textContent = s.indexOf(id) >= 0 ? "★" : "☆"; paintPins();
        });
        c.insertBefore(p, c.firstChild);
      });
    }
    add();
    var sv = E("services"); if (sv && !sv._ux2pin) { sv._ux2pin = 1; new MutationObserver(add).observe(sv, { childList: true, subtree: true }); }
  } catch (_) {}
}
function paintPins() {
  try {
    var g = E("ux2-pinstrip"); if (!g) return;
    Array.prototype.slice.call(g.querySelectorAll(".ux2-chip")).forEach(function (c) { c.remove(); });
    pinSet().forEach(function (id) {
      var c = MK("button", "ux2-chip", "★ " + id); c.type = "button"; c.title = "Jump to " + id;
      ON(c, "click", function () {
        var t = document.querySelector('#services .service-card[data-service-id="' + id + '"]');
        if (t) { t.scrollIntoView({ block: "center", behavior: "smooth" }); t.classList.add("ux2-pulse"); setTimeout(function () { t.classList.remove("ux2-pulse"); }, 2100); }
      });
      g.appendChild(c);
    });
  } catch (_) {}
}
// UX2-040
function w040() { try { paintPins(); } catch (_) {} }
// UX2-041
function w041() {
  try {
    var g = E("ux2-pinstrip"); if (!g || E("ux2-unpin")) return;
    var x = MK("button", "ux2-btn", "Unpin all"); x.id = "ux2-unpin"; x.type = "button";
    ON(x, "click", function () { SJ(LS.pins, []); CARDS().forEach(function (c) { var p = c.querySelector(".ux2-pinbtn"); if (p) p.textContent = "☆"; }); paintPins(); });
    g.appendChild(x);
  } catch (_) {}
}
// UX2-042
function w042() {
  try {
    if (document._ux2rec) return; document._ux2rec = 1;
    document.addEventListener("click", function (ev) {
      var b = ev.target && ev.target.closest ? ev.target.closest("button[data-action]") : null; if (!b) return;
      var r = GJ(LS.recent, []);
      r.unshift({ svc: b.getAttribute("data-service"), act: b.getAttribute("data-action"), t: new Date().toISOString() });
      SJ(LS.recent, r.slice(0, 20)); paintRecent();
    }, true);
  } catch (_) {}
}
function paintRecent() {
  try {
    var s = E("ux2-recent"); if (!s) return; s.innerHTML = "";
    var r = GJ(LS.recent, []);
    if (!r.length) { var o = document.createElement("option"); o.value = ""; o.textContent = "Recent: none"; s.appendChild(o); return; }
    var h = document.createElement("option"); h.value = ""; h.textContent = "Recent actions (" + r.length + ")…"; s.appendChild(h);
    r.forEach(function (x, i) {
      var o = document.createElement("option"); o.value = String(i); o.textContent = x.act + " " + x.svc + " · " + String(x.t).slice(11, 19);
      s.appendChild(o);
    });
  } catch (_) {}
}
// UX2-043
function w043() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-recent")) return;
    var g = MK("div", "ux2-grp ux2-sel"); g.appendChild(MK("span", "ux2-count", "Recent:"));
    var s = document.createElement("select"); s.id = "ux2-recent"; s.setAttribute("aria-label", "Recent actions jump list");
    ON(s, "change", function () {
      if (s.value === "") return;
      var r = GJ(LS.recent, [])[parseInt(s.value, 10)];
      if (r) { var btn = document.querySelector('button[data-action="' + r.act + '"][data-service="' + r.svc + '"]'); if (btn && !btn.disabled) btn.click(); else TS("Action no longer available."); }
      s.value = "";
    });
    g.appendChild(s); b.appendChild(g); paintRecent();
  } catch (_) {}
}
// UX2-044
function w044() {
  try {
    var g = E("ux2-recent") ? E("ux2-recent").parentNode : null; if (!g || E("ux2-rec-clear")) return;
    var x = MK("button", "ux2-btn", "Clear"); x.id = "ux2-rec-clear"; x.type = "button";
    ON(x, "click", function () { SJ(LS.recent, []); paintRecent(); TS("Recent actions cleared."); });
    g.appendChild(x);
  } catch (_) {}
}
// UX2-045
function w045() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-rec-copy")) return;
    var x = MK("button", "ux2-btn", "Copy last action"); x.id = "ux2-rec-copy"; x.type = "button";
    ON(x, "click", function () { var r = GJ(LS.recent, [])[0]; if (r) CP(r.act + " " + r.svc, "Last action copied."); else TS("No recent actions."); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-046
function w046() {
  try {
    function add() {
      var notes = GJ(LS.notes, {});
      CARDS().forEach(function (c) {
        if (c.querySelector(".ux2-note")) return;
        var d = document.createElement("details"); d.className = "ux2-nd";
        var sm = document.createElement("summary"); sm.textContent = "Note"; sm.style.cssText = "cursor:pointer;font-size:11px;opacity:.8";
        var ta = document.createElement("textarea"); ta.className = "ux2-note"; ta.rows = 2; ta.placeholder = "Private note for " + SID(c) + " (this machine only)…"; ta.value = notes[SID(c)] || "";
        ta.setAttribute("aria-label", "Note for " + SID(c));
        d.appendChild(sm); d.appendChild(ta); c.appendChild(d);
      });
    }
    add();
    var sv = E("services"); if (sv && !sv._ux2nt) { sv._ux2nt = 1; new MutationObserver(add).observe(sv, { childList: true, subtree: true }); }
  } catch (_) {}
}
// UX2-047
function w047() {
  try {
    var sv = E("services"); if (!sv || sv._ux2nt2) return; sv._ux2nt2 = 1;
    var tm = null;
    ON(sv, "input", function (ev) {
      var ta = ev.target && ev.target.closest ? ev.target.closest(".ux2-note") : null; if (!ta) return;
      clearTimeout(tm); tm = setTimeout(function () {
        var card = ta.closest(".service-card"); if (!card) return;
        var n = GJ(LS.notes, {}); var v = ta.value.slice(0, 500);
        if (v) n[SID(card)] = v; else delete n[SID(card)];
        SJ(LS.notes, n); TS("Note saved.");
      }, 600);
    });
  } catch (_) {}
}
// UX2-048
function w048() {
  try {
    var sv = E("services"); if (!sv || sv._ux2nc) return; sv._ux2nc = 1;
    ON(sv, "click", function (ev) {
      var t = ev.target && ev.target.closest ? ev.target.closest(".ux2-note-clear") : null; if (!t) return;
      var card = t.closest(".service-card"); var ta = card ? card.querySelector(".ux2-note") : null;
      if (ta) ta.value = "";
      var n = GJ(LS.notes, {}); if (card) delete n[SID(card)]; SJ(LS.notes, n); TS("Note cleared.");
    });
    CARDS().forEach(function (c) {
      if (c.querySelector(".ux2-note-clear")) return;
      var x = MK("button", "ux2-cpbtn ux2-note-clear", "Clear note"); x.type = "button"; c.appendChild(x);
    });
  } catch (_) {}
}
// UX2-049
function w049() {
  try {
    var n = GJ(LS.notes, {}); var k = Object.keys(n).length;
    if (k) pushNotif(k + " service note(s) restored from this machine.", "info");
  } catch (_) {}
}
// UX2-050
function w050() {
  try {
    CARDS().forEach(function (c) {
      if (c.querySelector("[data-ux2cp=id]")) return;
      var b = MK("button", "ux2-cpbtn", "Copy ID"); b.type = "button"; b.setAttribute("data-ux2cp", "id");
      ON(b, "click", function (ev) { ev.stopPropagation(); CP(SID(c), "Service ID copied."); });
      c.appendChild(b);
    });
  } catch (_) {}
}
// UX2-051
function w051() {
  try {
    CARDS().forEach(function (c) {
      if (c.querySelector("[data-ux2cp=url]")) return;
      var b = MK("button", "ux2-cpbtn", "Copy URL"); b.type = "button"; b.setAttribute("data-ux2cp", "url"); b.title = "Copy endpoint URL from the endpoints table";
      ON(b, "click", function (ev) {
        ev.stopPropagation();
        var id = SID(c); var url = "";
        Array.prototype.forEach.call(document.querySelectorAll(".endpoints-details tbody tr, .table-wrap tbody tr"), function (r) {
          if ((r.textContent || "").toLowerCase().indexOf(id.slice(0, 5).toLowerCase()) >= 0) { var td = r.cells[1]; if (td) url = td.textContent.trim(); }
        });
        CP(url ? "http://" + url : id, url ? "Endpoint URL copied." : "Service ID copied (no table row).");
      });
      c.appendChild(b);
    });
  } catch (_) {}
}
// UX2-052
function w052() {
  try {
    CARDS().forEach(function (c) {
      if (c.querySelector("[data-ux2cp=curl]")) return;
      var b = MK("button", "ux2-cpbtn", "curl"); b.type = "button"; b.setAttribute("data-ux2cp", "curl"); b.title = "Copy curl health-check command";
      ON(b, "click", function (ev) {
        ev.stopPropagation();
        var map = { jellyfin: "http://127.0.0.1:8096/System/Info/Public", proxy: "http://127.0.0.1:8888/health", bridge: "http://127.0.0.1:18099/health" };
        CP("curl " + (map[SID(c)] || "http://127.0.0.1:18080/api/status"), "curl command copied.");
      });
      c.appendChild(b);
    });
  } catch (_) {}
}
// UX2-053
function w053() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-cp-cmds")) return;
    var x = MK("button", "ux2-btn", "Copy action commands"); x.id = "ux2-cp-cmds"; x.type = "button"; x.title = "Copy the panel action endpoints for scripting";
    ON(x, "click", function () {
      CP("GET  http://127.0.0.1:18080/api/status\nGET  http://127.0.0.1:18080/api/health\nGET  http://127.0.0.1:18080/api/metrics\nPOST http://127.0.0.1:18080/api/action {service, action}", "API commands copied.");
    });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-054
function w054() {
  try {
    CARDS().forEach(function (c) {
      if (c.querySelector("[data-ux2cp=st]")) return;
      var b = MK("button", "ux2-cpbtn", "Copy status"); b.type = "button"; b.setAttribute("data-ux2cp", "st");
      ON(b, "click", function (ev) { ev.stopPropagation(); CP(SID(c) + " :: " + (c.textContent || "").replace(/\s+/g, " ").trim().slice(0, 400), "Status copied."); });
      c.appendChild(b);
    });
  } catch (_) {}
}
// UX2-055
function w055() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-cp-all")) return;
    var x = MK("button", "ux2-btn", "Copy summary"); x.id = "ux2-cp-all"; x.type = "button";
    ON(x, "click", function () {
      var rows = CARDS().map(function (c) { return { id: SID(c), status: (c.textContent || "").replace(/\s+/g, " ").trim().slice(0, 200) }; });
      CP(JSON.stringify(rows, null, 2), "Summary copied.");
    });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-056
function w056() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-tr")) return;
    var g = MK("div", "ux2-grp"); g.id = "ux2-tr"; g.appendChild(MK("span", "ux2-count", "Range:"));
    [["5m", 5], ["15m", 15], ["1h", 60], ["24h", 1440], ["all", 0]].forEach(function (p) {
      var c = MK("button", "ux2-chip", p[0]); c.type = "button"; c.setAttribute("data-tr", String(p[1]));
      ON(c, "click", function () { SV(LS.tr, String(p[1])); paintTR(); applyTR(); });
      g.appendChild(c);
    });
    b.appendChild(g); paintTR();
  } catch (_) {}
}
function paintTR() {
  try {
    var cur = G(LS.tr, "all");
    Array.prototype.forEach.call(document.querySelectorAll("#ux2-tr [data-tr]"), function (c) { c.classList.toggle("is-on", c.getAttribute("data-tr") === cur); });
  } catch (_) {}
}
function applyTR() {
  try {
    var mins = parseInt(G(LS.tr, "all"), 10);
    if (!mins) return;
    var cut = Date.now() - mins * 60000;
    VIS().forEach(function (li) {
      var m = (li.textContent || "").match(/\[(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\]/);
      if (m) { var t = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).getTime(); if (t < cut) li.style.display = "none"; }
    });
  } catch (_) {}
}
// UX2-057
function w057() { try { applyTR(); } catch (_) {} }
// UX2-058
function w058() {
  try {
    var log = E("activity-log"); if (!log || log._ux2tr) return; log._ux2tr = 1;
    var tm = null;
    new MutationObserver(function () { clearTimeout(tm); tm = setTimeout(applyTR, 500); }).observe(log, { childList: true });
  } catch (_) {}
}
// UX2-059
function w059() {
  try {
    var g = E("ux2-tr"); if (!g || E("ux2-tr-clear")) return;
    var x = MK("button", "ux2-btn", "All"); x.id = "ux2-tr-clear"; x.type = "button"; x.title = "Show all time ranges";
    ON(x, "click", function () { SV(LS.tr, "all"); paintTR(); applyOps(); });
    g.appendChild(x);
  } catch (_) {}
}
// UX2-060
function w060() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-iv")) return;
    var g = MK("div", "ux2-grp ux2-sel"); g.appendChild(MK("span", "ux2-count", "Refresh:"));
    var s = document.createElement("select"); s.id = "ux2-iv"; s.setAttribute("aria-label", "Auto-refresh interval");
    [["0", "Off"], ["5", "5s"], ["10", "10s"], ["30", "30s"], ["60", "60s"]].forEach(function (p) { var o = document.createElement("option"); o.value = p[0]; o.textContent = p[1]; s.appendChild(o); });
    s.value = G(LS.iv, "0");
    var nx = MK("span", "ux2-count", ""); nx.id = "ux2-iv-next";
    g.appendChild(s); g.appendChild(nx); b.appendChild(g);
    ON(s, "change", function () { SV(LS.iv, s.value); armIV(); });
  } catch (_) {}
}
function armIV() {
  try {
    clearInterval(armIV._t);
    var s = E("ux2-iv"); var secs = s ? parseInt(s.value, 10) : 0;
    var nx = E("ux2-iv-next"); if (nx) nx.textContent = secs ? ("every " + secs + "s") : "manual";
    if (!secs) return;
    armIV._t = setInterval(function () {
      try {
        if (document.hidden) return;
        var r = E("refresh-button"); if (r && !r.disabled) r.click();
      } catch (_) {}
    }, secs * 1000);
  } catch (_) {}
}
// UX2-061
function w061() { try { armIV(); } catch (_) {} }
// UX2-062
function w062() {
  try {
    document.addEventListener("visibilitychange", function () {
      var nx = E("ux2-iv-next"); if (nx && document.hidden) nx.textContent = "paused (tab hidden)";
      else armIV();
    });
  } catch (_) {}
}
// UX2-063
function w063() {
  try {
    var s = E("ux2-iv"); if (!s || s._w) return; s._w = 1;
    ON(s, "focus", function () { TS("Auto-refresh supplements the built-in poll; Off = panel default."); });
  } catch (_) {}
}
// UX2-064
function w064() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-snd")) return;
    var x = MK("button", "ux2-chip", G(LS.snd, "off") === "on" ? "🔔 Sound on" : "🔕 Sound off"); x.id = "ux2-snd"; x.type = "button";
    ON(x, "click", function () { var on = G(LS.snd, "off") !== "on"; SV(LS.snd, on ? "on" : "off"); x.textContent = on ? "🔔 Sound on" : "🔕 Sound off"; if (on) beep(); });
    b.appendChild(x);
  } catch (_) {}
}
function beep() {
  try {
    var AC = window.AudioContext || window.webkitAudioContext; if (!AC) return;
    var ctx = beep._c || (beep._c = new AC());
    var o = ctx.createOscillator(); var g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination); o.frequency.value = 660; g.gain.value = 0.08;
    o.start(); o.stop(ctx.currentTime + 0.25);
  } catch (_) {}
}
// UX2-065
function w065() {
  try {
    var log = E("activity-log"); if (!log || log._ux2beep) return; log._ux2beep = 1;
    new MutationObserver(function (muts) {
      if (G(LS.snd, "off") !== "on") return;
      var hit = false;
      muts.forEach(function (m) {
        Array.prototype.forEach.call(m.addedNodes, function (n) { if (/error|fail/i.test(n.textContent || "")) hit = true; });
      });
      if (hit) beep();
    }).observe(log, { childList: true });
  } catch (_) {}
}
// UX2-066
function w066() {
  try {
    var log = E("activity-log"); if (!log || log._ux2fl) return; log._ux2fl = 1;
    var orig = document.title;
    new MutationObserver(function (muts) {
      var hit = false;
      muts.forEach(function (m) {
        Array.prototype.forEach.call(m.addedNodes, function (n) { if (/error|fail/i.test(n.textContent || "")) hit = true; });
      });
      if (hit) {
        document.title = "⚠ Failure — " + orig;
        try { var sc = E("stack-chip"); if (sc) { sc.classList.add("ux2-flash"); setTimeout(function () { sc.classList.remove("ux2-flash"); }, 3000); } } catch (_) {}
        setTimeout(function () { document.title = orig; }, 8000);
      }
    }).observe(log, { childList: true });
  } catch (_) {}
}
// UX2-067
function w067() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-flash-test")) return;
    var x = MK("button", "ux2-btn", "Flash test"); x.id = "ux2-flash-test"; x.type = "button"; x.title = "Preview the failure flash + sound";
    ON(x, "click", function () { beep(); try { var sc = E("stack-chip"); if (sc) { sc.classList.add("ux2-flash"); setTimeout(function () { sc.classList.remove("ux2-flash"); }, 1500); } } catch (_) {} });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-068
function w068() {
  try {
    SV("ux2.sound.seen", "1");
    var b = E("ux2-snd"); if (b) b.title = "Play a tone and flash when new failures arrive (persisted)";
  } catch (_) {}
}
// UX2-069
function w069() {
  try {
    if (document._ux2seq) return; document._ux2seq = 1;
    var pending = null;
    document.addEventListener("keydown", function (ev) {
      var t = ev.target;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) return;
      if (pending && ev.key === "Escape") { pending = null; return; }
      if (!pending && (ev.key === "g" || ev.key === "G")) { pending = Date.now(); TS("g… press s / a / e / r"); return; }
      if (pending && Date.now() - pending < 1200) {
        var k = String(ev.key).toLowerCase(); pending = null;
        if (k === "s") seqGo("#services", "Services");
        else if (k === "a") seqGo("#activity-log", "Activity");
        else if (k === "e") seqGo(".endpoints-details", "Endpoints");
        else if (k === "r") { var r = E("refresh-button"); if (r) r.click(); TS("Refreshing."); }
      } else pending = null;
    });
  } catch (_) {}
}
function seqGo(sel, name) { try { var n = document.querySelector(sel); if (n) { n.scrollIntoView({ block: "start", behavior: "smooth" }); TS(name + "."); } } catch (_) {} }
// UX2-070
function w070() { try { seqGoKB("services"); } catch (_) {} }
function seqGoKB() { try { SJ(LS.seq, { seen: 1 }); } catch (_) {} }
// UX2-071
function w071() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-seq-hint")) return;
    var h = MK("span", "ux2-count", "Keys: g s · g a · g e · g r"); h.id = "ux2-seq-hint"; h.title = "Press g, then a second key"; b.appendChild(h);
  } catch (_) {}
}
// UX2-072
function w072() {
  try {
    document.addEventListener("keydown", function (ev) {
      if (ev.key === "Escape") document.querySelectorAll(".ux2-drawer").forEach(function (d) { d.hidden = true; });
    });
  } catch (_) {}
}
// UX2-073
function w073() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-go-svc")) return;
    var x = MK("button", "ux2-btn", "Go: services"); x.id = "ux2-go-svc"; x.type = "button";
    ON(x, "click", function () { seqGo("#services", "Services"); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-074
function w074() {
  try {
    if (E("ux2-empty-act")) return;
    var box = MK("div", "ux2-warn", null); box.id = "ux2-empty-act"; box.hidden = true;
    box.innerHTML = "<strong>No activity to show.</strong><br>1. Clear the search above &nbsp;2. Press Refresh &nbsp;3. Run Sync TorBox to generate entries.";
    var r = MK("button", "ux2-btn", "Refresh now"); r.type = "button";
    ON(r, "click", function () { var b = E("refresh-button"); if (b) b.click(); });
    var d = MK("button", "ux2-btn", "Dismiss"); d.type = "button";
    ON(d, "click", function () { try { sessionStorage.setItem("ux2.hideEmpty", "1"); } catch (_) {} box.hidden = true; });
    box.appendChild(document.createElement("br")); box.appendChild(r); box.appendChild(document.createTextNode(" ")); box.appendChild(d);
    var log = E("activity-log"); if (log && log.parentNode) log.parentNode.insertBefore(box, log);
    paintEmpty();
  } catch (_) {}
}
function paintEmpty() {
  try {
    var hide = null; try { hide = sessionStorage.getItem("ux2.hideEmpty"); } catch (_) {}
    var box = E("ux2-empty-act"); if (!box || hide) return;
    box.hidden = VIS().length > 0;
  } catch (_) {}
}
// UX2-075
function w075() {
  try {
    if (E("ux2-empty-svc")) return; var sv = E("services"); if (!sv || !sv.parentNode) return;
    var box = MK("div", "ux2-warn", null); box.id = "ux2-empty-svc"; box.hidden = true;
    var span = MK("span", null, "No service cards yet. Wait for the first poll, then press Refresh. ");
    var r = MK("button", "ux2-btn", "Refresh now"); r.type = "button";
    ON(r, "click", function () { var b = E("refresh-button"); if (b) b.click(); });
    box.appendChild(span); box.appendChild(r);
    sv.parentNode.insertBefore(box, sv);
  } catch (_) {}
}
// UX2-076
function w076() {
  try {
    var sv = E("services"); if (!sv || sv._ux2em) return; sv._ux2em = 1;
    new MutationObserver(function () {
      paintEmpty();
      var box = E("ux2-empty-svc"); if (box) box.hidden = CARDS().length > 0;
    }).observe(sv, { childList: true });
  } catch (_) {}
}
// UX2-077
function w077() {
  try {
    var log = E("activity-log"); if (!log || log._ux2em2) return; log._ux2em2 = 1;
    new MutationObserver(function () { paintEmpty(); }).observe(log, { childList: true, subtree: true });
  } catch (_) {}
}
// UX2-078
function w078() {
  try {
    var box = E("ux2-empty-act"); if (!box || box._w) return; box._w = 1;
    ON(box, "click", function (ev) { if (ev.target && ev.target.tagName === "BUTTON") paintEmpty(); });
  } catch (_) {}
}
// UX2-079
function w079() {
  try {
    if (E("ux2-firstfail")) return;
    var box = MK("div", "ux2-err-card", null); box.id = "ux2-firstfail"; box.hidden = true;
    var log = E("activity-log"); if (log && log.parentNode) log.parentNode.insertBefore(box, log);
  } catch (_) {}
}
var FF_SEEN = {};
function ffHint(t) {
  t = t.toLowerCase();
  if (t.indexOf("jellyfin") >= 0) return "Jellyfin: open http://127.0.0.1:8096/ — if it loads, the panel poller lagged; press Refresh.";
  if (t.indexOf("8888") >= 0 || t.indexOf("proxy") >= 0 || t.indexOf("torbox") >= 0) return "Proxy: check http://127.0.0.1:8888/health, then Restart proxy.";
  if (t.indexOf("18099") >= 0 || t.indexOf("bridge") >= 0) return "Bridge: check http://127.0.0.1:18099/health, then Restart bridge.";
  if (t.indexOf("mount") >= 0 || t.indexOf("drive") >= 0 || t.indexOf("rclone") >= 0) return "Mount: restart the mount service, then Sync TorBox.";
  return "Press Refresh once; if it persists, restart the named service and re-check.";
}
// UX2-080
function w080() {
  try {
    var log = E("activity-log"); if (!log || log._ux2ff) return; log._ux2ff = 1;
    new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        Array.prototype.forEach.call(m.addedNodes, function (n) {
          var t = ((n.textContent) || "").trim();
          if (!/error|fail|stopped|unreach/i.test(t) || FF_SEEN[t]) return;
          FF_SEEN[t] = 1; showFF(t);
        });
      });
    }).observe(log, { childList: true });
  } catch (_) {}
}
function showFF(t) {
  try {
    var box = E("ux2-firstfail"); if (!box) return; box.hidden = false; box.innerHTML = "";
    box.appendChild(MK("strong", null, "First failure: "));
    var p = MK("div", null, t.slice(0, 300)); box.appendChild(p);
    box.appendChild(MK("div", null, ffHint(t)));
    var row = MK("div", "ux2-kv");
    var cp = MK("button", "ux2-btn", "Copy diagnostic"); cp.type = "button";
    ON(cp, "click", function () { CP(t + "\n" + ffHint(t) + "\n" + new Date().toISOString(), "Diagnostic copied."); });
    var fx = MK("button", "ux2-btn", "Fix-it flow"); fx.type = "button";
    ON(fx, "click", function () { openFix(t); });
    var dis = MK("button", "ux2-btn", "Dismiss"); dis.type = "button";
    ON(dis, "click", function () { box.hidden = true; });
    [cp, fx, dis].forEach(function (n) { row.appendChild(n); });
    box.appendChild(row);
  } catch (_) {}
}
// UX2-081
function w081() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-ff-jump")) return;
    var x = MK("button", "ux2-btn", "Latest failure"); x.id = "ux2-ff-jump"; x.type = "button"; x.title = "Scroll to the newest error line";
    ON(x, "click", function () {
      var errs = LOGS().filter(function (li) { return li.style.display !== "none" && /error|fail/i.test(li.textContent || ""); });
      if (!errs.length) { TS("No failures visible."); return; }
      var li = errs[errs.length - 1];
      li.scrollIntoView({ block: "center", behavior: "smooth" }); li.classList.add("ux2-pulse");
      setTimeout(function () { li.classList.remove("ux2-pulse"); }, 2100);
    });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-082
function w082() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-ff-copy")) return;
    var x = MK("button", "ux2-btn", "Copy latest failure"); x.id = "ux2-ff-copy"; x.type = "button";
    ON(x, "click", function () {
      var errs = VIS().filter(function (li) { return /error|fail/i.test(li.textContent || ""); });
      CP(errs.length ? errs[errs.length - 1].textContent.trim() : "(no failures)", errs.length ? "Failure copied." : "Nothing to copy.");
    });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-083
function w083() {
  try {
    var box = E("ux2-firstfail"); if (box) box.title = "Shows once per unique failure; guided fix-it flows start here";
  } catch (_) {}
}
// UX2-084
function w084() {
  try {
    if (E("ux2-fix")) return;
    var d = MK("div", "ux2-drawer"); d.id = "ux2-fix"; d.hidden = true; d.setAttribute("role", "dialog"); d.setAttribute("aria-label", "Guided fix-it flow");
    var h = MK("h2", null, "Fix-it flow"); h.id = "ux2-fix-title"; d.appendChild(h);
    var dots = MK("div", "ux2-kv", null); dots.id = "ux2-fix-dots"; d.appendChild(dots);
    var body = MK("div", null, null); body.id = "ux2-fix-body"; body.style.cssText = "font-size:13.5px;line-height:1.55;margin:10px 0"; d.appendChild(body);
    var row = MK("div", "ux2-kv");
    var back = MK("button", "ux2-btn", "← Back"); back.type = "button"; back.id = "ux2-fix-back";
    var next = MK("button", "ux2-btn", "Next →"); next.type = "button"; next.id = "ux2-fix-next";
    var cancel = MK("button", "ux2-btn", "Cancel"); cancel.type = "button";
    ON(back, "click", function () { fixStep(Math.max(0, fixIdx - 1)); });
    ON(next, "click", function () { fixStep(fixIdx + 1); });
    ON(cancel, "click", function () { d.hidden = true; });
    [back, next, cancel].forEach(function (n) { row.appendChild(n); });
    d.appendChild(row); document.body.appendChild(d);
  } catch (_) {}
}
var fixIdx = 0; var fixSvc = "";
function openFix(t) {
  try {
    fixSvc = /jellyfin|proxy|bridge|gdrive|torboxmount|mount|drive/i.test(t) ? (t.match(/jellyfin|proxy|bridge|gdrive|torboxmount/i) || ["service"])[0].toLowerCase() : "service";
    fixStep(0); toggleDrawer("ux2-fix");
  } catch (_) {}
}
function fixStep(i) {
  try {
    var steps = [
      { t: "Step 1 — Check: confirm the symptom for " + fixSvc + ". Open its health endpoint or re-read the failure line.", run: null },
      { t: "Step 2 — Restart: press the service Restart button (bulk Restart selected also works).", run: "restart" },
      { t: "Step 3 — Verify: press Refresh and confirm the service shows healthy.", run: "verify" }
    ];
    fixIdx = Math.max(0, Math.min(steps.length - 1, i));
    var body = E("ux2-fix-body"); if (body) body.textContent = steps[fixIdx].t;
    var dots = E("ux2-fix-dots");
    if (dots) {
      dots.innerHTML = "";
      steps.forEach(function (_, k) { var s = MK("span", "ux2-chip" + (k === fixIdx ? " is-on" : ""), String(k + 1)); dots.appendChild(s); });
    }
    var nx = E("ux2-fix-next"); if (nx) nx.textContent = fixIdx === steps.length - 1 ? "Done ✓" : "Next →";
    var st = steps[fixIdx];
    if (st.run === "restart") {
      var btn = document.querySelector('#services .service-card[data-service-id="' + fixSvc + '"] button[data-action="restart"]');
      if (btn && !btn.disabled) { btn.click(); TS("Restart sent for " + fixSvc + "."); }
    } else if (st.run === "verify") {
      var r = E("refresh-button"); if (r) r.click();
      if (fixIdx === steps.length - 1) { TS("Fix-it flow complete for " + fixSvc + "."); pushNotif("Fix-it flow completed for " + fixSvc + ".", "info"); }
    }
  } catch (_) {}
}
// UX2-085
function w085() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-fix-open")) return;
    var x = MK("button", "ux2-btn", "Fix-it…"); x.id = "ux2-fix-open"; x.type = "button"; x.title = "Start a guided fix-it flow for a service";
    ON(x, "click", function () {
      var id = (selList()[0] && SID(selList()[0])) || "service";
      fixSvc = id; fixStep(0); toggleDrawer("ux2-fix");
    });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-086
function w086() {
  try {
    var d = E("ux2-fix"); if (d) d.title = "Three steps: check, restart, verify — actions run against the real buttons";
  } catch (_) {}
}
// UX2-087
function w087() {
  try {
    var h = E("ux2-fix-title"); if (h) h.textContent = "Fix-it flow (check → restart → verify)";
  } catch (_) {}
}
// UX2-088
function w088() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-fix-svc")) return;
    var g = MK("div", "ux2-grp ux2-sel"); g.appendChild(MK("span", "ux2-count", "Fix:"));
    var s = document.createElement("select"); s.id = "ux2-fix-svc"; s.setAttribute("aria-label", "Fix-it service");
    ["jellyfin", "proxy", "bridge", "gdrive", "torboxmount"].forEach(function (v) { var o = document.createElement("option"); o.value = v; o.textContent = v; s.appendChild(o); });
    var go = MK("button", "ux2-btn", "Start"); go.type = "button";
    ON(go, "click", function () { fixSvc = s.value; fixStep(0); toggleDrawer("ux2-fix"); });
    g.appendChild(s); g.appendChild(go); b.appendChild(g);
  } catch (_) {}
}
// UX2-089
function w089() {
  try {
    if (E("ux2-dock")) return;
    var d = MK("div", "ux2-dock", null); d.id = "ux2-dock"; d.setAttribute("role", "navigation"); d.setAttribute("aria-label", "Quick links");
    [["Jellyfin", "http://127.0.0.1:8096/"], ["Proxy", "http://127.0.0.1:8888/health"], ["Bridge", "http://127.0.0.1:18099/health"], ["Status API", "/api/status"], ["Metrics", "/api/metrics"]].forEach(function (p) {
      var a = document.createElement("a"); a.href = p[1]; a.target = "_blank"; a.rel = "noopener"; a.className = "ux2-btn"; a.textContent = p[0]; a.style.textDecoration = "none";
      d.appendChild(a);
    });
    document.body.appendChild(d);
    if (G(LS.dock, "show") === "hide") d.style.display = "none";
  } catch (_) {}
}
// UX2-090
function w090() {
  try {
    var d = E("ux2-dock"); if (!d || E("ux2-dock-cp")) return;
    var x = MK("button", "ux2-btn", "Copy links"); x.id = "ux2-dock-cp"; x.type = "button";
    ON(x, "click", function () {
      var ls = Array.prototype.map.call(d.querySelectorAll("a"), function (a) { return a.textContent + ": " + a.href; }).join("\n");
      CP(ls, "Links copied.");
    });
    d.appendChild(x);
  } catch (_) {}
}
// UX2-091
function w091() {
  try {
    var d = E("ux2-dock"); if (!d || E("ux2-dock-hide")) return;
    var x = MK("button", "ux2-btn", "Hide"); x.id = "ux2-dock-hide"; x.type = "button";
    ON(x, "click", function () { d.style.display = "none"; SV(LS.dock, "hide"); TS("Dock hidden — use Show dock to restore."); });
    d.appendChild(x);
  } catch (_) {}
}
// UX2-092
function w092() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-dock-show")) return;
    var x = MK("button", "ux2-btn", "Show dock"); x.id = "ux2-dock-show"; x.type = "button";
    ON(x, "click", function () { var d = E("ux2-dock"); if (d) d.style.display = ""; SV(LS.dock, "show"); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-093
function w093() {
  try {
    var d = E("ux2-dock"); if (d) d.title = "Loopback-only quick links; Status/Metrics hit this panel";
  } catch (_) {}
}
// UX2-094
function w094() {
  try {
    if (document._ux2tab) return; document._ux2tab = 1;
    document.querySelectorAll(".tabs [data-density]").forEach(function (t) {
      ON(t, "click", function () { SV(LS.tab, t.getAttribute("data-density") || "comfortable"); });
    });
  } catch (_) {}
}
// UX2-095
function w095() {
  try {
    var want = G(LS.tab, ""); if (!want) return;
    var t = document.querySelector('.tabs [data-density="' + want + '"]');
    if (t) setTimeout(function () { try { t.click(); } catch (_) {} }, 300);
  } catch (_) {}
}
// UX2-096
function w096() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-tab-reset")) return;
    var x = MK("button", "ux2-btn", "Reset view tab"); x.id = "ux2-tab-reset"; x.type = "button"; x.title = "Forget the remembered Cards/Compact tab";
    ON(x, "click", function () { SV(LS.tab, ""); TS("Tab memory cleared."); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-097
function w097() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-goto-err")) return;
    var x = MK("button", "ux2-btn", "Scroll to error"); x.id = "ux2-goto-err"; x.type = "button";
    ON(x, "click", function () { gotoErr(0); });
    b.appendChild(x);
  } catch (_) {}
}
var ERR_IDX = 0;
function gotoErr(step) {
  try {
    var errs = VIS().filter(function (li) { return /error|fail|warn/i.test(li.textContent || ""); });
    if (!errs.length) { TS("No errors to scroll to."); return; }
    ERR_IDX = (ERR_IDX + step) % errs.length;
    var li = errs[ERR_IDX];
    li.scrollIntoView({ block: "center", behavior: "smooth" }); li.classList.add("ux2-pulse");
    setTimeout(function () { li.classList.remove("ux2-pulse"); }, 2100);
  } catch (_) {}
}
// UX2-098
function w098() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-goto-next")) return;
    var x = MK("button", "ux2-btn", "Next error"); x.id = "ux2-goto-next"; x.type = "button";
    ON(x, "click", function () { gotoErr(1); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-099
function w099() {
  try {
    var b = E("ux2-goto-err"); if (b) b.title = "Jump to the first warning/error; Next error cycles through them";
  } catch (_) {}
}
// UX2-100 [UX2-0100]
function w100() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-expand")) return;
    var x = MK("button", "ux2-btn", "Expand all"); x.id = "ux2-expand"; x.type = "button";
    ON(x, "click", function () { document.querySelectorAll("details.log-details").forEach(function (d) { d.open = true; }); TS("All sections expanded."); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-101 [UX2-0101]
function w101() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-collapse")) return;
    var x = MK("button", "ux2-btn", "Collapse all"); x.id = "ux2-collapse"; x.type = "button";
    ON(x, "click", function () { document.querySelectorAll("details.log-details").forEach(function (d) { d.open = false; }); TS("All sections collapsed."); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-102 [UX2-0102]
function w102() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-ep-toggle")) return;
    var x = MK("button", "ux2-btn", "Endpoints"); x.id = "ux2-ep-toggle"; x.type = "button"; x.title = "Toggle + jump to the endpoints table";
    ON(x, "click", function () {
      var d = document.querySelector("details.endpoints-details");
      if (d) { d.open = !d.open; if (d.open) d.scrollIntoView({ block: "start", behavior: "smooth" }); }
    });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-103 [UX2-0103]
function w103() {
  try {
    if (E("ux2-json")) return;
    var d = MK("div", "ux2-drawer"); d.id = "ux2-json"; d.hidden = true; d.setAttribute("role", "dialog"); d.setAttribute("aria-label", "Status payload viewer");
    d.appendChild(MK("h2", null, "Status payload"));
    var row = MK("div", "ux2-kv");
    var rf = MK("button", "ux2-btn", "Fetch /api/status"); rf.type = "button";
    var cp = MK("button", "ux2-btn", "Copy"); cp.type = "button";
    var x = MK("button", "ux2-btn", "Close"); x.type = "button";
    var ts = MK("span", "ux2-count", ""); ts.id = "ux2-json-ts";
    ON(rf, "click", fetchPayload); ON(cp, "click", function () { var p = E("ux2-json-pre"); if (p) CP(p.textContent, "Payload copied."); });
    ON(x, "click", function () { d.hidden = true; });
    [rf, cp, x, ts].forEach(function (n) { row.appendChild(n); }); d.appendChild(row);
    var pre = MK("pre", "ux2-pre", "Press Fetch to load the live /api/status payload."); pre.id = "ux2-json-pre"; d.appendChild(pre);
    var kv = MK("div", null, null); kv.id = "ux2-json-keys"; d.appendChild(kv);
    document.body.appendChild(d);
  } catch (_) {}
}
function fetchPayload() {
  try {
    var pre = E("ux2-json-pre"); if (pre) pre.textContent = "Loading…";
    fetch("/api/status").then(function (r) { return r.text(); }).then(function (t) {
      var obj = null; try { obj = JSON.parse(t); } catch (_) {}
      if (pre) pre.textContent = obj ? JSON.stringify(obj, null, 2).slice(0, 8000) : String(t).slice(0, 8000);
      var ts = E("ux2-json-ts"); if (ts) ts.textContent = "fetched " + new Date().toLocaleTimeString();
      var kv = E("ux2-json-keys");
      if (kv && obj && typeof obj === "object") {
        kv.innerHTML = "";
        Object.keys(obj).slice(0, 20).forEach(function (k) {
          var det = document.createElement("details"); var sm = document.createElement("summary");
          sm.textContent = k; sm.style.cssText = "cursor:pointer;font-size:12px";
          var pp = MK("pre", "ux2-pre", JSON.stringify(obj[k], null, 2).slice(0, 2000));
          det.appendChild(sm); det.appendChild(pp); kv.appendChild(det);
        });
      }
    }, function () { if (pre) pre.textContent = "Fetch failed — panel unreachable."; });
  } catch (_) {}
}
// UX2-104 [UX2-0104]
function w104() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-json-open")) return;
    var x = MK("button", "ux2-btn", "Payload viewer"); x.id = "ux2-json-open"; x.type = "button"; x.title = "Compact JSON viewer for the live status payload";
    ON(x, "click", function () { toggleDrawer("ux2-json"); });
    b.appendChild(x);
  } catch (_) {}
}
// UX2-105 [UX2-0105]
function w105() {
  try {
    var pre = E("ux2-json-pre"); if (pre) pre.title = "Click Copy to grab the whole payload for bug reports";
  } catch (_) {}
}
// UX2-106 [UX2-0106]
function w106() {
  try {
    var d = E("ux2-json"); if (d && !d._w) { d._w = 1; ON(d, "keydown", function (ev) { if (ev.key === "Escape") d.hidden = true; }); }
  } catch (_) {}
}
// UX2-107 [UX2-0107]
function w107() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-diff")) return;
    var g = MK("div", "ux2-grp"); g.id = "ux2-diff";
    var snap = MK("button", "ux2-btn", "Snapshot states"); snap.type = "button"; snap.id = "ux2-diff-snap";
    var chk = MK("button", "ux2-btn", "Check changes"); chk.type = "button"; chk.id = "ux2-diff-check";
    var clr = MK("button", "ux2-btn", "Clear"); clr.type = "button"; clr.id = "ux2-diff-clear";
    var out = MK("span", "ux2-count", ""); out.id = "ux2-diff-out";
    ON(snap, "click", function () { SJ("ux2.snap", snapStates()); TS("Snapshot saved."); paintDiff([]); });
    ON(chk, "click", function () { diffCheck(true); });
    ON(clr, "click", function () { try { localStorage.removeItem("ux2.snap"); } catch (_) {} paintDiff([]); TS("Snapshot cleared."); });
    [snap, chk, clr, out].forEach(function (n) { g.appendChild(n); });
    b.appendChild(g);
  } catch (_) {}
}
function snapStates() {
  var o = {};
  try {
    CARDS().forEach(function (c) { o[SID(c)] = (c.textContent || "").replace(/\s+/g, " ").trim().slice(0, 160); });
  } catch (_) {}
  return { at: new Date().toISOString(), states: o };
}
function paintDiff(changes) {
  try {
    var out = E("ux2-diff-out"); if (!out) return;
    out.textContent = changes.length ? (changes.length + " changed: " + changes.map(function (c) { return c.id; }).join(", ")) : "No changes vs snapshot.";
    out.title = changes.map(function (c) { return c.id + ": " + c.from.slice(0, 60) + " → " + c.to.slice(0, 60); }).join("\n");
  } catch (_) {}
}
function diffCheck(loud) {
  try {
    var snap = GJ("ux2.snap", null);
    if (!snap) { if (loud) TS("Take a snapshot first."); return []; }
    var now = snapStates().states; var changes = [];
    Object.keys(now).forEach(function (id) {
      if (snap.states[id] !== undefined && snap.states[id] !== now[id]) changes.push({ id: id, from: snap.states[id], to: now[id] });
    });
    paintDiff(changes);
    if (changes.length) {
      pushNotif("Status changed: " + changes.map(function (c) { return c.id; }).join(", "), "info");
      if (loud) TS(changes.length + " service(s) changed since snapshot.");
    } else if (loud) TS("No changes since snapshot.");
    return changes;
  } catch (_) { return []; }
}
// UX2-108 [UX2-0108]
function w108() {
  try {
    if (w108._x) return; w108._x = 1;
    setInterval(function () { try { if (GJ("ux2.snap", null)) diffCheck(false); } catch (_) {} }, 15000);
  } catch (_) {}
}
// UX2-109 [UX2-0109]
function w109() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-diff-copy")) return;
    var x = MK("button", "ux2-btn", "Copy diff"); x.id = "ux2-diff-copy"; x.type = "button"; x.title = "Copy before→after for changed services";
    ON(x, "click", function () {
      var ch = diffCheck(false);
      CP(ch.length ? ch.map(function (c) { return c.id + ":\n- " + c.from + "\n+ " + c.to; }).join("\n\n") : "(no changes vs snapshot)", "Diff copied.");
    });
    var g = E("ux2-diff"); if (g) g.appendChild(x); else b.appendChild(x);
  } catch (_) {}
}
// UX2-110 [UX2-0110]
function w110() {
  try {
    var b = E("ux2-bar"); if (!b || E("ux2-scroll-top")) return;
    var x = MK("button", "ux2-btn", "↑ Top"); x.id = "ux2-scroll-top"; x.type = "button"; x.title = "Back to top";
    ON(x, "click", function () { window.scrollTo({ top: 0, behavior: "smooth" }); });
    b.appendChild(x);
    [w001, w002, w003, w004, w005].forEach(function (f) { try { f(); } catch (_) {} });
    TS("Extended tools ready.");
  } catch (_) {}
}
[w001, w002, w003, w004, w005, w006, w007, w008, w009, w010, w011, w012, w013, w014, w015, w016, w017, w018, w019, w020, w021, w022, w023, w024, w025, w026, w027, w028, w029, w030, w031, w032, w033, w034, w035, w036, w037, w038, w039, w040, w041, w042, w043, w044, w045, w046, w047, w048, w049, w050, w051, w052, w053, w054, w055, w056, w057, w058, w059, w060, w061, w062, w063, w064, w065, w066, w067, w068, w069, w070, w071, w072, w073, w074, w075, w076, w077, w078, w079, w080, w081, w082, w083, w084, w085, w086, w087, w088, w089, w090, w091, w092, w093, w094, w095, w096, w097, w098, w099, w100, w101, w102, w103, w104, w105, w106, w107, w108, w109, w110].forEach(function (f) { try { f(); } catch (_) {} });
} catch (_) {}
})();
