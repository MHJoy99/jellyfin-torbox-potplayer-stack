(function () {
"use strict";
try { if (window.__plydLoaded) return; window.__plydLoaded = true; } catch (_) {}
try {
var DOC = document, WIN = window;
function $(sel, root) { try { return (root || DOC).querySelector(sel); } catch (_) { return null; } }
function $all(sel, root) { try { return Array.prototype.slice.call((root || DOC).querySelectorAll(sel)); } catch (_) { return []; } }
function mk(tag, cls, text) { var n = DOC.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
function lsGet(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function lsGetJ(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } }
function lsSetJ(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }
function toast(msg) { var t = DOC.getElementById("toast"); if (t) { t.textContent = msg; t.className = "toast show"; clearTimeout(toast._t); toast._t = setTimeout(function () { t.classList.remove("show"); }, 3200); } }
function curTitle() {
  var p = $("#playback-status");
  if (p && p.textContent) { var t = p.textContent.trim().split("\n")[0].trim(); if (t && t.length > 2 && t.length < 140) return t; }
  var h = $("h1, h2, .detail-title, [data-title]");
  if (h && h.textContent && h.textContent.trim().length > 1 && h.textContent.trim().length < 140) return h.textContent.trim();
  var d = DOC.title; if (d && d.length > 1) return d.replace(/\s*[|\-–]\s*Jellyfin.*$/i, "").trim() || d;
  return "";
}
function libItems() {
  var sels = ["#services .service-card[data-service-id]", ".library-item", ".poster-card", "[data-item-id]", ".card[data-title]", ".item[data-title]"];
  for (var i = 0; i < sels.length; i++) { var n = $all(sels[i]); if (n.length) return n; }
  return [];
}
function itemKey(n) {
  try {
    var k = n.getAttribute("data-item-id") || n.getAttribute("data-service-id") || n.getAttribute("data-title") || n.getAttribute("aria-label") || "";
    if (!k) { var h = n.querySelector("h1,h2,h3,h4,.title,.name,strong"); if (h && h.textContent) k = h.textContent.trim(); }
    if (!k && n.textContent) k = n.textContent.trim().split("\n")[0].trim();
    return (k || "item").slice(0, 80);
  } catch (_) { return "item"; }
}
function itemLabel(n) { return itemKey(n); }
function CSS() {
  if (DOC.getElementById("playd-style")) return;
  var s = DOC.createElement("style"); s.id = "playd-style";
  s.textContent = ".playd-bar{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 10px;padding:8px;border:1px solid var(--accent-ring,#334);border-radius:10px;font-size:12px;background:transparent}.playd-badge{display:inline-flex;align-items:center;gap:4px;font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid var(--accent-ring,#334);color:var(--muted,#999)}.playd-badge.is-on{color:#cfe1ff;border-color:var(--accent,#4f8cff)}.playd-btn{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:8px;padding:3px 10px;font-size:12px;background:transparent;color:var(--text,#e6edf7)}.playd-btn:hover{border-color:var(--accent,#4f8cff)}.playd-btn.is-on{color:#cfe1ff;border-color:var(--accent,#4f8cff)}.playd-sel{font:inherit;font-size:12px;padding:3px 8px;border-radius:8px;border:1px solid var(--accent-ring,#334);background:var(--bg,#0e1522);color:var(--text,#e6edf7)}.playd-chip{cursor:pointer;font-size:11px;padding:2px 10px;border-radius:999px;border:1px solid var(--accent-ring,#334);background:transparent;color:var(--muted,#999)}.playd-chip.is-on{color:#cfe1ff;border-color:var(--accent,#4f8cff)}.playd-fav{position:absolute;top:4px;right:4px;z-index:5;cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:8px;background:var(--bg,#0e1522);color:var(--muted,#999);font-size:14px;line-height:1;padding:2px 6px;opacity:.85}.playd-fav.is-on{color:#ffd75e;border-color:#ffd75e;opacity:1}.playd-stars{display:inline-flex;gap:2px}.playd-stars button{cursor:pointer;background:transparent;border:0;color:var(--muted,#999);font-size:13px;padding:0 1px}.playd-stars button.is-on{color:#ffd75e}.playd-modal{position:fixed;inset:0;z-index:99;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.7)}.playd-modal-box{max-width:min(720px,92vw);width:100%;background:var(--bg,#0e1522);border:1px solid var(--accent-ring,#334);border-radius:12px;padding:12px;color:var(--text,#e6edf7)}.playd-modal-box iframe,.playd-modal-box video{width:100%;min-height:320px;border:0;border-radius:8px}.playd-listview .playd-item-host{display:block!important;width:100%!important;max-width:none!important}.playd-blur .playd-blurable{filter:blur(8px);pointer-events:none;user-select:none}.playd-hist{max-height:150px;overflow:auto;font-size:11px;color:var(--muted,#999);border:1px solid var(--accent-ring,#334);border-radius:8px;padding:6px 8px;margin:8px 0}.playd-hist div{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:1px 0}";
  DOC.head.appendChild(s);
}
function bar() {
  CSS();
  var b = DOC.getElementById("playd-bar");
  if (b) return b;
  b = mk("div", "playd-bar"); b.id = "playd-bar";
  b.setAttribute("role", "toolbar"); b.setAttribute("aria-label", "Playback discovery wins");
  var anchor = $("#playback-status") || $("main.shell") || $("main") || DOC.body;
  try {
    if (anchor && anchor.id === "playback-status" && anchor.parentElement) anchor.parentElement.insertBefore(b, anchor);
    else if (anchor && anchor.firstChild) anchor.insertBefore(b, anchor.firstChild);
    else DOC.body.appendChild(b);
  } catch (_) { try { DOC.body.appendChild(b); } catch (_) {} }
  return b;
}
function watchedSet() { return lsGetJ("playd.watched", {}); }
function isWatched(n) {
  try {
    if (n.getAttribute("data-watched") === "1" || n.getAttribute("data-played") === "true") return true;
    if (n.querySelector(".watched,.is-watched,[data-watched],.played")) return true;
    var w = watchedSet(); return !!w[itemKey(n)];
  } catch (_) { return false; }
}

// PLYD-001
function wHistory() {
  try {
    var KEY = "playd.hist", CAP = 100;
    function push(entry) {
      try {
        var h = lsGetJ(KEY, []);
        h.unshift(entry);
        if (h.length > CAP) h = h.slice(0, CAP);
        lsSetJ(KEY, h);
        paint();
      } catch (_) {}
    }
    function paint() {
      try {
        var box = DOC.getElementById("playd-hist"); if (!box) return;
        var h = lsGetJ(KEY, []);
        box.innerHTML = "";
        if (!h.length) { box.appendChild(mk("div", "", "No watch history yet.")); return; }
        h.slice(0, 20).forEach(function (e) {
          var d = null; try { d = new Date(e.at); } catch (_) {}
          box.appendChild(mk("div", "", (d ? d.toLocaleString() : "?") + " — " + (e.title || "untitled")));
        });
      } catch (_) {}
    }
    DOC.addEventListener("play", function (e) {
      try {
        if (e.target && e.target.tagName === "VIDEO") {
          var t = curTitle() || "video";
          push({ title: t, at: Date.now(), ev: "play" });
          try {
            var w = watchedSet(); w[t] = Date.now(); lsSetJ("playd.watched", w);
          } catch (_) {}
        }
      } catch (_) {}
    }, true);
    DOC.addEventListener("ended", function (e) {
      try { if (e.target && e.target.tagName === "VIDEO") push({ title: curTitle() || "video", at: Date.now(), ev: "ended" }); } catch (_) {}
    }, true);
    var b = bar(); if (!b || DOC.getElementById("playd-hist-wrap")) { paint(); return; }
    var wrap = mk("div", ""); wrap.id = "playd-hist-wrap";
    var btn = mk("button", "playd-btn", "History"); btn.setAttribute("aria-expanded", "false");
    var box = mk("div", "playd-hist"); box.id = "playd-hist"; box.style.display = "none";
    btn.addEventListener("click", function () {
      try {
        var open = box.style.display !== "none";
        box.style.display = open ? "none" : "block";
        btn.setAttribute("aria-expanded", open ? "false" : "true");
        if (!open) paint();
      } catch (_) {}
    });
    var clear = mk("button", "playd-btn", "Clear"); clear.setAttribute("aria-label", "Clear watch history");
    clear.addEventListener("click", function () { try { lsSetJ(KEY, []); paint(); toast("Watch history cleared."); } catch (_) {} });
    wrap.appendChild(btn); wrap.appendChild(clear); wrap.appendChild(box);
    b.appendChild(wrap);
    paint();
  } catch (_) {}
}

// PLYD-002
function wFavs() {
  try {
    var KEY = "playd.favs";
    function favs() { return lsGetJ(KEY, {}); }
    function paint() {
      try {
        var f = favs();
        $all(".playd-fav").forEach(function (btn) {
          try {
            var host = btn.parentElement, k = btn.getAttribute("data-playd-key") || (host ? itemKey(host) : "");
            var on = !!f[k];
            btn.classList.toggle("is-on", on);
            btn.textContent = on ? "★" : "☆";
            btn.setAttribute("aria-pressed", on ? "true" : "false");
          } catch (_) {}
        });
      } catch (_) {}
    }
    function attach() {
      try {
        libItems().forEach(function (n) {
          try {
            if (n.querySelector(":scope > .playd-fav")) return;
            var pos = null; try { pos = WIN.getComputedStyle(n).position; } catch (_) {}
            if (pos === "static") { try { n.style.position = "relative"; } catch (_) {} }
            var k = itemKey(n);
            var btn = mk("button", "playd-fav", "☆");
            btn.setAttribute("aria-label", "Favorite " + k);
            btn.setAttribute("data-playd-key", k);
            btn.addEventListener("click", function (ev) {
              try {
                ev.stopPropagation();
                var f = favs(), kk = btn.getAttribute("data-playd-key");
                if (f[kk]) { delete f[kk]; toast("Removed from favorites: " + kk); }
                else { f[kk] = Date.now(); toast("★ Favorited: " + kk); }
                lsSetJ(KEY, f); paint();
              } catch (_) {}
            });
            n.appendChild(btn);
          } catch (_) {}
        });
        paint();
      } catch (_) {}
    }
    attach();
    try {
      var mo = new MutationObserver(function () { try { attach(); } catch (_) {} });
      mo.observe(DOC.body, { childList: true, subtree: true });
      setTimeout(function () { try { mo.disconnect(); } catch (_) {} }, 60000);
    } catch (_) {}
    var b = bar(); if (b && !DOC.getElementById("playd-favonly")) {
      var t = mk("button", "playd-btn", "★ Favorites only"); t.id = "playd-favonly"; t.setAttribute("aria-pressed", "false");
      t.addEventListener("click", function () {
        try {
          var on = t.classList.toggle("is-on");
          t.setAttribute("aria-pressed", on ? "true" : "false");
          var f = favs();
          libItems().forEach(function (n) {
            try { n.style.display = (on && !f[itemKey(n)]) ? "none" : ""; } catch (_) {}
          });
          toast(on ? "Showing favorites only." : "Showing all items.");
        } catch (_) {}
      });
      b.appendChild(t);
    }
  } catch (_) {}
}

// PLYD-003
function wHideWatched() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playd-hidewatched")) return;
    var t = mk("button", "playd-btn", "Hide watched"); t.id = "playd-hidewatched"; t.setAttribute("aria-pressed", "false");
    var on = lsGet("playd.hideWatched", "0") === "1";
    function apply() {
      try {
        libItems().forEach(function (n) {
          try { if (isWatched(n)) n.style.display = on ? "none" : ""; } catch (_) {}
        });
        t.classList.toggle("is-on", on);
        t.setAttribute("aria-pressed", on ? "true" : "false");
      } catch (_) {}
    }
    if (on) { t.classList.add("is-on"); t.setAttribute("aria-pressed", "true"); }
    t.addEventListener("click", function () {
      try { on = !on; lsSet("playd.hideWatched", on ? "1" : "0"); apply(); toast(on ? "Watched items hidden." : "Watched items shown."); } catch (_) {}
    });
    b.appendChild(t);
    apply();
  } catch (_) {}
}

// PLYD-004
function wRatings() {
  try {
    var KEY = "playd.ratings";
    function ratings() { return lsGetJ(KEY, {}); }
    function row(k, host) {
      try {
        var r = ratings(), cur = +r[k] || 0;
        var s = mk("span", "playd-stars"); s.setAttribute("role", "group"); s.setAttribute("aria-label", "Rate " + k);
        for (var i = 1; i <= 5; i++) {
          (function (v) {
            var b = mk("button", v <= cur ? "is-on" : "", v <= cur ? "★" : "☆");
            b.setAttribute("aria-label", "Rate " + v + " of 5");
            b.addEventListener("click", function (ev) {
              try {
                ev.stopPropagation();
                var rr = ratings();
                if (+rr[k] === v) delete rr[k]; else rr[k] = v;
                lsSetJ(KEY, rr);
                try {
                  var btns = s.querySelectorAll("button");
                  for (var j = 0; j < btns.length; j++) {
                    var on = j < (+rr[k] || 0);
                    btns[j].textContent = on ? "★" : "☆";
                    btns[j].classList.toggle("is-on", on);
                  }
                } catch (_) {}
                toast(rr[k] ? ("Rated " + rr[k] + "/5: " + k) : ("Rating cleared: " + k));
              } catch (_) {}
            });
            s.appendChild(b);
          })(i);
        }
        return s;
      } catch (_) { return null; }
    }
    function attach() {
      try {
        libItems().forEach(function (n) {
          try {
            if (n.querySelector(":scope > .playd-stars")) return;
            var s = row(itemKey(n), n);
            if (s) n.appendChild(s);
          } catch (_) {}
        });
      } catch (_) {}
    }
    attach();
    try {
      var mo = new MutationObserver(function () { try { attach(); } catch (_) {} });
      mo.observe(DOC.body, { childList: true, subtree: true });
      setTimeout(function () { try { mo.disconnect(); } catch (_) {} }, 60000);
    } catch (_) {}
  } catch (_) {}
}

// PLYD-005
function wGenreChips() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playd-genres")) return;
    var wrap = mk("span", ""); wrap.id = "playd-genres";
    var active = "";
    function genres() {
      var set = {};
      libItems().forEach(function (n) {
        try {
          var g = n.getAttribute("data-genre") || n.getAttribute("data-genres") || "";
          if (!g) { var c = n.querySelector(".genre,[data-genre],.meta-genre"); if (c && c.textContent) g = c.textContent.trim(); }
          String(g).split(/[|,;/]/).forEach(function (x) { x = x.trim().slice(0, 24); if (x) set[x] = 1; });
        } catch (_) {}
      });
      return Object.keys(set).sort().slice(0, 12);
    }
    function apply() {
      libItems().forEach(function (n) {
        try {
          if (!active) { n.style.display = ""; return; }
          var g = (n.getAttribute("data-genre") || n.getAttribute("data-genres") || ((function () { var c = n.querySelector(".genre,[data-genre],.meta-genre"); return c && c.textContent ? c.textContent : ""; })()) || "").toLowerCase();
          n.style.display = g.indexOf(active.toLowerCase()) >= 0 ? "" : "none";
        } catch (_) {}
      });
    }
    function build() {
      try {
        wrap.innerHTML = "";
        var all = mk("button", "playd-chip" + (active ? "" : " is-on"), "All");
        all.addEventListener("click", function () { active = ""; build(); apply(); });
        wrap.appendChild(all);
        genres().forEach(function (g) {
          var c = mk("button", "playd-chip" + (active === g ? " is-on" : ""), g);
          c.addEventListener("click", function () { active = (active === g) ? "" : g; build(); apply(); toast(active ? ("Genre: " + active) : "Genre filter cleared."); });
          wrap.appendChild(c);
        });
      } catch (_) {}
    }
    b.appendChild(wrap);
    build();
    setTimeout(build, 4000);
  } catch (_) {}
}

// PLYD-006
function wYearFilter() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playd-year")) return;
    var sel = DOC.createElement("select"); sel.id = "playd-year"; sel.className = "playd-sel"; sel.setAttribute("aria-label", "Filter by decade");
    ["", "2020s", "2010s", "2000s", "1990s", "1980s", "older"].forEach(function (d) {
      var op = DOC.createElement("option"); op.value = d; op.textContent = d ? d : "Any year"; sel.appendChild(op);
    });
    sel.value = lsGet("playd.decade", "");
    function yearOf(n) {
      try {
        var y = n.getAttribute("data-year") || n.getAttribute("data-premiere") || "";
        var m = String(y).match(/(19|20)\d{2}/);
        if (m) return +m[0];
        var c = n.querySelector(".year,[data-year],.meta-year");
        if (c && c.textContent) { m = c.textContent.match(/(19|20)\d{2}/); if (m) return +m[0]; }
        if (n.textContent) { m = n.textContent.match(/\b(19|20)\d{2}\b/); if (m) return +m[0]; }
        return 0;
      } catch (_) { return 0; }
    }
    function apply() {
      var d = sel.value;
      libItems().forEach(function (n) {
        try {
          if (!d) { n.style.display = ""; return; }
          var y = yearOf(n), show = false;
          if (d === "older") show = y > 0 && y < 1980;
          else { var dec = +d.slice(0, 4); show = y >= dec && y < dec + 10; }
          n.style.display = show ? "" : "none";
        } catch (_) {}
      });
    }
    sel.addEventListener("change", function () { try { lsSet("playd.decade", sel.value); apply(); toast(sel.value ? ("Decade: " + sel.value) : "Year filter cleared."); } catch (_) {} });
    b.appendChild(sel);
    apply();
  } catch (_) {}
}

// PLYD-007
function wSort() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playd-sort")) return;
    var sel = DOC.createElement("select"); sel.id = "playd-sort"; sel.className = "playd-sel"; sel.setAttribute("aria-label", "Sort items");
    [["", "Sort: default"], ["title", "Sort: title A–Z"], ["rating", "Sort: rating"], ["added", "Sort: recently added"]].forEach(function (o) {
      var op = DOC.createElement("option"); op.value = o[0]; op.textContent = o[1]; sel.appendChild(op);
    });
    sel.value = lsGet("playd.sort", "");
    function val(n, mode) {
      try {
        if (mode === "title") return itemLabel(n).toLowerCase();
        if (mode === "rating") {
          var r = lsGetJ("playd.ratings", {});
          var mine = +r[itemKey(n)] || 0;
          if (mine) return -mine;
          var t = n.querySelector("[data-rating],.rating"); if (t) return -(parseFloat(t.getAttribute("data-rating") || t.textContent) || 0);
          return 0;
        }
        if (mode === "added") {
          var h = lsGetJ("playd.hist", []);
          var k = itemKey(n);
          for (var i = 0; i < h.length; i++) { if (h[i] && h[i].title === k) return i; }
          var a = n.getAttribute("data-added") || n.getAttribute("data-created") || "";
          var tm = Date.parse(a); return isNaN(tm) ? 1e15 : -tm;
        }
        return 0;
      } catch (_) { return 0; }
    }
    function apply() {
      try {
        var mode = sel.value; if (!mode) return;
        var items = libItems(); if (items.length < 2) return;
        var parent = items[0].parentElement; if (!parent) return;
        var ranked = items.map(function (n, i) { return { n: n, v: val(n, mode), i: i }; });
        ranked.sort(function (a, c) {
          if (a.v < c.v) return -1; if (a.v > c.v) return 1; return a.i - c.i;
        });
        ranked.forEach(function (r) { try { parent.appendChild(r.n); } catch (_) {} });
      } catch (_) {}
    }
    sel.addEventListener("change", function () { try { lsSet("playd.sort", sel.value); apply(); toast(sel.value ? ("Sorted: " + sel.value) : "Default order restored."); } catch (_) {} });
    b.appendChild(sel);
  } catch (_) {}
}

// PLYD-008
function wViewToggle() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playd-view")) return;
    var t = mk("button", "playd-btn", "List view"); t.id = "playd-view"; t.setAttribute("aria-pressed", "false");
    var list = lsGet("playd.view", "grid") === "list";
    function host() {
      var items = libItems(); if (!items.length) return null;
      return items[0].parentElement;
    }
    function apply() {
      try {
        var h = host(); if (!h) return;
        h.classList.toggle("playd-listview", list);
        t.textContent = list ? "Grid view" : "List view";
        t.classList.toggle("is-on", list);
        t.setAttribute("aria-pressed", list ? "true" : "false");
      } catch (_) {}
    }
    if (list) apply();
    t.addEventListener("click", function () {
      try { list = !list; lsSet("playd.view", list ? "list" : "grid"); apply(); toast(list ? "List view." : "Grid view."); } catch (_) {}
    });
    b.appendChild(t);
  } catch (_) {}
}

// PLYD-009
function wTrailer() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playd-trailer")) return;
    function url() {
      try {
        var a = DOC.querySelector("[data-trailer-url],[data-trailer]");
        if (a) { var u = a.getAttribute("data-trailer-url") || a.getAttribute("data-trailer") || a.getAttribute("href"); if (u && /^https?:/i.test(u)) return u; }
        var links = $all('a[href*="youtube.com/watch"],a[href*="youtu.be/"]');
        for (var i = 0; i < links.length; i++) { var h = links[i].getAttribute("href"); if (h) return h; }
        return "";
      } catch (_) { return ""; }
    }
    function open(u) {
      try {
        close();
        var m = mk("div", "playd-modal"); m.id = "playd-modal"; m.setAttribute("role", "dialog"); m.setAttribute("aria-label", "Trailer");
        var box = mk("div", "playd-modal-box");
        var head = mk("div", ""); head.style.cssText = "display:flex;justify-content:space-between;align-items:center;margin-bottom:8px";
        head.appendChild(mk("strong", "", "Trailer"));
        var x = mk("button", "playd-btn", "Close"); x.setAttribute("aria-label", "Close trailer");
        x.addEventListener("click", close);
        head.appendChild(x); box.appendChild(head);
        var yt = u.match(/(?:youtube\.com\/watch\?v=|youtu\.be\/)([\w-]{6,})/i);
        if (yt) {
          var f = DOC.createElement("iframe");
          f.setAttribute("src", "https://www.youtube.com/embed/" + yt[1] + "?autoplay=1&rel=0");
          f.setAttribute("allow", "autoplay; encrypted-media; picture-in-picture");
          f.setAttribute("allowfullscreen", "true");
          box.appendChild(f);
        } else {
          var v = DOC.createElement("video");
          v.setAttribute("src", u); v.setAttribute("controls", "true"); v.setAttribute("autoplay", "true");
          box.appendChild(v);
        }
        m.addEventListener("click", function (e) { try { if (e.target === m) close(); } catch (_) {} });
        m.appendChild(box);
        DOC.body.appendChild(m);
        try { x.focus(); } catch (_) {}
      } catch (_) {}
    }
    function close() { try { var m = DOC.getElementById("playd-modal"); if (m && m.parentElement) m.parentElement.removeChild(m); } catch (_) {} }
    DOC.addEventListener("keydown", function (e) { try { if (e && e.key === "Escape") close(); } catch (_) {} });
    var t = mk("button", "playd-btn", "▶ Trailer"); t.id = "playd-trailer";
    t.addEventListener("click", function () {
      try {
        var u = url();
        if (!u) { toast("No trailer link found on this page."); return; }
        open(u);
      } catch (_) {}
    });
    b.appendChild(t);
  } catch (_) {}
}

// PLYD-010
function wParental() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playd-parental")) return;
    var t = mk("button", "playd-btn", "Parental blur: off"); t.id = "playd-parental"; t.setAttribute("aria-pressed", "false");
    var on = lsGet("playd.blur", "0") === "1";
    function tag(n) {
      try {
        if (n.classList.contains("playd-blurable")) return;
        var items = libItems(); if (!items.length) return;
        var h = items[0].parentElement; if (h) h.classList.add("playd-blur-host");
        n.classList.add("playd-blurable");
        var posters = n.querySelectorAll("img,.poster,.thumb,.backdrop");
        for (var i = 0; i < posters.length; i++) { try { posters[i].classList.add("playd-blurable"); } catch (_) {} }
      } catch (_) {}
    }
    function apply() {
      try {
        var h = null, items = libItems();
        if (items.length && items[0].parentElement) h = items[0].parentElement;
        libItems().forEach(tag);
        if (h) {
          if (on) h.classList.add("playd-blur");
          else h.classList.remove("playd-blur");
          if (!h.classList.contains("playd-blur") && on) {
            libItems().forEach(function (n) { try { n.classList.add("playd-blurable"); } catch (_) {} });
            DOC.body.classList.add("playd-blur");
          } else if (!on) {
            try { DOC.body.classList.remove("playd-blur"); } catch (_) {}
          }
        } else {
          if (on) DOC.body.classList.add("playd-blur");
          else DOC.body.classList.remove("playd-blur");
        }
        t.textContent = "Parental blur: " + (on ? "on" : "off");
        t.classList.toggle("is-on", on);
        t.setAttribute("aria-pressed", on ? "true" : "false");
      } catch (_) {}
    }
    if (on) { t.textContent = "Parental blur: on"; t.classList.add("is-on"); t.setAttribute("aria-pressed", "true"); }
    t.addEventListener("click", function () {
      try {
        on = !on; lsSet("playd.blur", on ? "1" : "0"); apply();
        toast(on ? "Parental blur on (client convenience only — not a lock)." : "Parental blur off.");
      } catch (_) {}
    });
    b.appendChild(t);
    apply();
  } catch (_) {}
}
try { wHistory(); } catch (_) {}
try { wFavs(); } catch (_) {}
try { wHideWatched(); } catch (_) {}
try { wRatings(); } catch (_) {}
try { wGenreChips(); } catch (_) {}
try { wYearFilter(); } catch (_) {}
try { wSort(); } catch (_) {}
try { wViewToggle(); } catch (_) {}
try { wTrailer(); } catch (_) {}
try { wParental(); } catch (_) {}
} catch (_) {}
})();
