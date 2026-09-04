"use strict";

const SERVICE_ORDER = ["gdrive", "torboxmount", "jellyfin", "proxy", "bridge"];
const POLL_MS = 5000;
const TICK_MS = 1000;
const STATUS_TIMEOUT_MS = 20000;
const ACTION_TIMEOUT_MS = 300000;
const LOG_RE = /^\[(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\]\s*([\s\S]*)$/;
// F3: Timeline render cap — virtualize: never render more than this many DOM nodes.
const TIMELINE_RENDER_CAP = 300;
// F4: Fetch retry with exponential backoff.
const FETCH_MAX_RETRIES = 3;
const FETCH_BACKOFF_BASE_MS = 500;
const FETCH_BACKOFF_MAX_MS = 4000;
// F6: Service badges primary source with fallback to /api/status.
const HEALTH_URL = "/api/health";
const METRICS_URL = "/api/metrics";
const STATUS_URL = "/api/status";

const SERVICE_ICONS = {
  jellyfin:
    '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><circle cx="12" cy="12" r="7"></circle><circle cx="12" cy="12" r="2.2" fill="currentColor" stroke="none"></circle></svg>',
  proxy:
    '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 8h13"></path><path d="M14 4.5L17.5 8 14 11.5"></path><path d="M20 16H7"></path><path d="M10 12.5L6.5 16l3.5 3.5"></path></svg>',
  bridge:
    '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4.5" width="18" height="12.5" rx="2"></rect><path d="M9 21h6"></path><path d="M12 17v4"></path></svg>',
  gdrive:
    '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 18a4.5 4.5 0 1 1 .8-8.93 5.5 5.5 0 0 1 10.6 1.43A3.75 3.75 0 0 1 17.5 18Z"></path></svg>',
  torboxmount:
    '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="8" width="18" height="8" rx="2"></rect><path d="M7 12h.01"></path><path d="M11 12h.01"></path></svg>',
};

const ACTION_LABELS = { start: "Starting", restart: "Restarting", stop: "Stopping", sync: "Syncing" };

const FILTER_STORAGE_SOURCE = "jellyfin.panel.activity.sourceFilter";
const FILTER_STORAGE_ERRORS = "jellyfin.panel.activity.errorsOnly";

function loadSourceFilter() {
  try {
    const raw = localStorage.getItem(FILTER_STORAGE_SOURCE);
    if (typeof raw === "string" && raw.trim()) return raw.trim().toLowerCase();
  } catch (_) {
    /* storage unavailable */
  }
  return "all";
}

function loadErrorsOnly() {
  try {
    return localStorage.getItem(FILTER_STORAGE_ERRORS) === "1";
  } catch (_) {
    return false;
  }
}

const state = {
  lastPayload: null,
  activityKey: null,
  timelineKey: null,
  filterKey: null,
  sourceFilter: loadSourceFilter(),
  errorsOnly: loadErrorsOnly(),
  pending: null,
  fetching: false,
  lastCheckedAt: null,
  unreachable: false,
  // F1: tab visibility — pauses auto-refresh while hidden.
  tabVisible: typeof document === "undefined" ? true : !document.hidden,
  pollTimer: null,
  // F4: retry/backoff bookkeeping + status pill state.
  retryAttempt: 0,
  backoffMs: 0,
  fetchStatus: "idle",
  // F5: last-play card dedupe key (refresh without full reload).
  playbackKey: null,
  // F10: track browser offline state to toast only on transitions.
  wasOffline: typeof navigator !== "undefined" ? navigator.onLine === false : false,
};

const els = {
  services: document.getElementById("services"),
  playback: document.getElementById("playback-status"),
  activity: document.getElementById("activity-log"),
  filters: null,
  chips: null,
  errorsOnly: null,
  stackChip: document.getElementById("stack-chip"),
  stackLabel: document.getElementById("stack-chip-label"),
  lastCheckedText: document.getElementById("last-checked-text"),
  lastChecked: document.getElementById("last-checked"),
  refresh: document.getElementById("refresh-button"),
  toast: document.getElementById("toast"),
  statusPill: null,
};

const GLOBAL_BUTTON_DEFAULTS = new Map(
  Array.from(document.querySelectorAll(".global-actions [data-action]")).map((btn) => [btn, btn.innerHTML]),
);

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function showToast(message, kind = "info") {
  const toast = els.toast;
  if (!toast) return;
  toast.textContent = message;
  toast.className = `toast toast-${kind} show`;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => toast.classList.remove("show"), 5200);
}

// F4: status pill — tinyFetch-state indicator next to the stack chip.
// States: live | fetching | retrying | offline | stale
function ensureStatusPill() {
  if (els.statusPill && document.contains(els.statusPill)) return els.statusPill;
  let pill = document.getElementById("fetch-status-pill");
  if (!pill) {
    pill = document.createElement("span");
    pill.id = "fetch-status-pill";
    pill.className = "fetch-pill is-idle";
    pill.setAttribute("role", "status");
    pill.setAttribute("aria-live", "polite");
    pill.title = "Fetch status";
    const anchor = els.stackChip || els.lastChecked || els.refresh;
    if (anchor && anchor.parentElement) {
      anchor.parentElement.insertBefore(pill, anchor.nextSibling);
    } else {
      document.body.appendChild(pill);
    }
    if (!document.getElementById("fetch-pill-styles")) {
      const style = document.createElement("style");
      style.id = "fetch-pill-styles";
      style.textContent = [
        ".fetch-pill{display:inline-flex;align-items:center;gap:6px;font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid var(--accent-ring, #334);color:var(--muted, #999);margin-left:8px;white-space:nowrap;}",
        ".fetch-pill.is-live{color:#7dd88a;border-color:rgba(125,216,138,.4);}",
        ".fetch-pill.is-fetching{color:#7aa8ff;border-color:rgba(122,168,255,.4);}",
        ".fetch-pill.is-retry{color:#f0b35c;border-color:rgba(240,179,92,.45);}",
        ".fetch-pill.is-error{color:#f06a6a;border-color:rgba(240,106,106,.45);}",
      ].join("\n");
      document.head.appendChild(style);
    }
  }
  els.statusPill = pill;
  return pill;
}

function setStatusPill(status, text) {
  state.fetchStatus = status;
  const pill = ensureStatusPill();
  if (!pill) return;
  const labels = {
    idle: "Idle",
    live: "Live",
    fetching: "Fetching…",
    retrying: text || "Retrying…",
    offline: "Offline",
    stale: "Stale",
  };
  pill.textContent = labels[status] || text || status;
  pill.className = `fetch-pill is-${status === "retrying" ? "retry" : status === "live" ? "live" : status === "fetching" ? "fetching" : status === "offline" || status === "stale" ? "error" : "idle"}`;
  pill.title = status === "retrying" ? `Fetch retry — ${pill.textContent}` : `Fetch status: ${pill.textContent}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function backoffDelayMs(attempt) {
  const exp = FETCH_BACKOFF_BASE_MS * 2 ** Math.max(0, attempt - 1);
  return Math.min(exp, FETCH_BACKOFF_MAX_MS);
}

function relTime(ts, now = Date.now()) {
  const seconds = Math.max(0, Math.round((now - ts) / 1000));
  if (seconds < 5) return "just now";
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

function pad2(value) {
  return String(value).padStart(2, "0");
}

function verbLabel(service, action) {
  const base = ACTION_LABELS[action] || "Working";
  return service === "all" ? `${base} all…` : `${base}…`;
}

function badgeFor(service) {
  const stateKey = ["healthy", "warning", "starting", "stopped"].includes(service.state)
    ? service.state
    : "stopped";
  return `<span class="badge badge-${stateKey}" title="${escapeHtml(service.detail || "")}">${escapeHtml(
    service.state_label || stateKey,
  )}</span>`;
}

function metaChips(service) {
  const chips = [];
  if (service.version) {
    chips.push(`<span class="chip chip-mono" title="Reported version">v${escapeHtml(service.version)}</span>`);
  }
  if (service.server_name) {
    chips.push(`<span class="chip" title="Server name">${escapeHtml(service.server_name)}</span>`);
  }
  if (service.process_count > 0) {
    const pids = Array.isArray(service.pids) ? service.pids.join(", ") : "";
    chips.push(
      `<span class="chip" title="Process IDs: ${escapeHtml(pids)}">${service.process_count} ${
        service.process_count === 1 ? "process" : "processes"
      }</span>`,
    );
  }
  if (service.player) {
    chips.push(
      service.player.running
        ? `<span class="chip chip-live" title="PotPlayer is running">${escapeHtml(
            service.player.process || "PotPlayer",
          )} active</span>`
        : '<span class="chip chip-dim">Player idle</span>',
    );
  }
  if (!chips.length) return "";
  return `<div class="svc-meta">${chips.join("")}</div>`;
}

function serviceCard(service) {
  const stateKey = ["healthy", "warning", "starting", "stopped"].includes(service.state)
    ? service.state
    : "stopped";
  const icon = SERVICE_ICONS[service.id] || SERVICE_ICONS.jellyfin;
  return `
    <article class="service-card st-${stateKey}" data-service-id="${escapeHtml(service.id)}">
      <div class="card-top">
        <span class="svc-icon" aria-hidden="true">${icon}</span>
        <div class="svc-idblock">
          <h3 class="svc-name">${escapeHtml(service.name)}</h3>
          <span class="svc-addr">${
            service.port != null ? `127.0.0.1:${escapeHtml(service.port)}` : escapeHtml(service.mount_path || "drive mount")
          }</span>
        </div>
        ${badgeFor(service)}
      </div>
      <p class="svc-detail">${escapeHtml(service.detail || "")}</p>
      ${metaChips(service)}
      <div class="svc-actions" role="group" aria-label="${escapeHtml(service.name)} actions">
        <button class="btn btn-sm btn-primary" type="button" data-action="start" data-service="${escapeHtml(service.id)}">Start</button>
        <button class="btn btn-sm btn-secondary" type="button" data-action="restart" data-service="${escapeHtml(service.id)}">Restart</button>
        <button class="btn btn-sm btn-danger-ghost" type="button" data-action="stop" data-service="${escapeHtml(service.id)}">Stop</button>
      </div>
    </article>`;
}

function playbackStateKey(playback) {
  return ["healthy", "warning", "starting", "stopped"].includes(playback?.state)
    ? playback.state
    : "stopped";
}

function playbackCard(playback) {
  if (!playback || !playback.last_run) {
    return `
      <article class="playback-card st-stopped">
        <div class="playback-main">
          <span class="playback-icon" aria-hidden="true">${SERVICE_ICONS.bridge}</span>
          <div class="playback-copy">
            <span class="playback-kicker">Reliable playlist</span>
            <h3>Waiting for a playlist run</h3>
            <p>No validated season playlist has been recorded yet.</p>
          </div>
          ${badgeFor({ ...playback, detail: playback.detail || "No playlist run recorded" })}
        </div>
      </article>`;
  }

  const stateKey = playbackStateKey(playback);
  const context = [playback.show, playback.season ? `Season ${playback.season}` : ""]
    .filter(Boolean)
    .join(" · ") || "Latest season playlist";
  const selected = playback.selected ? `E${String(playback.selected).padStart(2, "0")}` : "—";
  const expected = Number(playback.expected_entries || playback.entries || 0);
  const entries = Number(playback.entries || 0);
  const lastRun = playback.last_run ? new Date(playback.last_run.replace(" ", "T")).getTime() : NaN;
  const lastRunLabel = Number.isFinite(lastRun) ? relTime(lastRun) : "unknown";
  // F7: relative timestamp with title=absolute for the playlist last-run.
  const lastRunTitle = playback.last_run ? String(playback.last_run).replace("T", " ") : "";
  const sourceLabel = playback.source_label || "No source candidates";
  const sourceCount = [playback.local_candidates, playback.rclone_candidates, playback.jellyfin_candidates]
    .filter((count) => Number(count) > 0).length;
  // F5: last-play snippet (bridge "Handling play request") — refreshed via
  // refreshLastPlayCard() without a full panel reload. Guarded: absent when
  // the backend omits last_play.
  const lastPlay = playback.last_play || null;
  let lastPlayHtml = "";
  if (lastPlay && (lastPlay.target_basename || lastPlay.started_iso)) {
    const startedIso = String(lastPlay.started_iso || "");
    const startedMs = startedIso ? Date.parse(startedIso.replace(" ", "T")) : NaN;
    const ageLabel = Number.isFinite(startedMs)
      ? relTime(startedMs)
      : typeof lastPlay.age_s === "number"
        ? relTime(Date.now() - lastPlay.age_s * 1000)
        : "unknown";
    const absolute = startedIso ? startedIso.replace("T", " ") : "";
    const base = String(lastPlay.target_basename || "Unknown title");
    const short = lastPlay.item_id_short ? ` · ${lastPlay.item_id_short}` : "";
    lastPlayHtml = `<div class="playback-lastplay" data-testid="last-play">Last play: <strong title="${escapeHtml(
      base + short,
    )}">${escapeHtml(base)}</strong> <time datetime="${escapeHtml(startedIso)}" title="${escapeHtml(
      absolute,
    )}">${escapeHtml(ageLabel)}</time></div>`;
  }
  return `
    <article class="playback-card st-${stateKey}">
      <div class="playback-main">
        <span class="playback-icon" aria-hidden="true">${SERVICE_ICONS.bridge}</span>
        <div class="playback-copy">
          <span class="playback-kicker">Reliable playlist</span>
          <h3>${escapeHtml(context)}</h3>
          <p>${escapeHtml(playback.detail || "Playlist status unavailable")}</p>
          ${lastPlayHtml}
        </div>
        ${badgeFor({ ...playback, detail: playback.detail || "Playlist status" })}
      </div>
      <div class="playback-metrics" role="list" aria-label="Playback summary">
        <div class="playback-metric" role="listitem">
          <span>Playlist</span>
          <strong>${entries} / ${expected}</strong>
          <small>entries valid</small>
        </div>
        <div class="playback-metric" role="listitem">
          <span>Selected</span>
          <strong>${escapeHtml(selected)}</strong>
          <small>episode</small>
        </div>
        <div class="playback-metric" role="listitem">
          <span>Coverage</span>
          <strong>${sourceCount} tier${sourceCount === 1 ? "" : "s"}</strong>
          <small title="${escapeHtml(sourceLabel)}">${escapeHtml(sourceLabel)}</small>
        </div>
      </div>
      <div class="playback-footer">
        <span class="playback-file" title="Validated playlist filename">${escapeHtml(playback.playlist_name || "Unknown playlist")}</span>
        <time datetime="${escapeHtml(playback.last_run || "")}" title="${escapeHtml(lastRunTitle)}">Last run ${escapeHtml(lastRunLabel)}</time>
      </div>
    </article>`;
}

function skeletonCards() {
  return Array.from({ length: 5 })
    .map(
      () => `
    <article class="service-card skeleton" aria-hidden="true">
      <div class="sk sk-w45"></div>
      <div class="sk sk-w80"></div>
      <div class="sk sk-w60"></div>
      <div class="sk sk-w90"></div>
    </article>`,
    )
    .join("");
}

function playbackSkeleton() {
  return `
    <article class="playback-card skeleton" aria-hidden="true">
      <div class="sk sk-w45"></div>
      <div class="sk sk-w80"></div>
      <div class="sk sk-w60"></div>
    </article>`;
}

function updateStackChip(services) {
  const chip = els.stackChip;
  const list = SERVICE_ORDER.map((key) => services[key]).filter(Boolean);
  const healthy = list.filter((svc) => svc.state === "healthy").length;
  const warning = list.some((svc) => svc.state === "warning");
  const starting = list.some((svc) => svc.state === "starting");
  let cls = "is-warn";
  let label = `Degraded · ${healthy} of ${list.length || 5} healthy`;
  if (state.unreachable) {
    cls = "is-down";
    label = "Panel unreachable";
  } else if (list.length && healthy === list.length && !warning) {
    cls = "is-ok";
    label = "All systems healthy";
  } else if (healthy === 0 && !starting && !warning) {
    cls = "is-down";
    label = "Stack stopped";
  } else if (warning) {
    cls = "is-warn";
    label = `Healthy with warnings · ${healthy} of ${list.length} up`;
  } else if (starting) {
    cls = "is-warn";
    label = starting && healthy === 0 ? "Starting…" : `Starting · ${healthy} of ${list.length} healthy`;
  }
  chip.className = `stack-chip ${cls}`;
  els.stackLabel.textContent = label;
}

function parseLogLine(line) {
  const match = LOG_RE.exec(String(line || "").trim());
  if (!match) return { ts: null, iso: null, clock: null, message: String(line || "").trim() };
  const [, y, mo, d, h, mi, s, message] = match;
  const ts = new Date(+y, +mo - 1, +d, +h, +mi, +s).getTime();
  return {
    ts,
    iso: `${y}-${mo}-${d}T${h}:${mi}:${s}`,
    clock: `${h}:${mi}:${s}`,
    message: message.trim(),
  };
}

function activityItem(parsed) {
  if (parsed.ts === null) {
    return `<li class="act-item"><span class="act-dot" aria-hidden="true"></span><div class="act-body"><p class="act-msg">${escapeHtml(
      parsed.message,
    )}</p></div></li>`;
  }
  return `
    <li class="act-item" data-ts="${parsed.ts}">
      <span class="act-dot" aria-hidden="true"></span>
      <div class="act-body">
        <p class="act-msg">${escapeHtml(parsed.message)}</p>
        <time class="act-time" datetime="${parsed.iso}" title="${escapeHtml(parsed.iso.replace("T", " "))}">
          <span class="act-rel">${relTime(parsed.ts)}</span><span class="act-clock">${parsed.clock}</span>
        </time>
      </div>
    </li>`;
}

function renderActivity(lines) {
  const key = lines.join("\n");
  if (key === state.activityKey) return;
  state.activityKey = key;
  // F3: cap rendered nodes (drop oldest beyond the cap).
  const items = lines.slice(-TIMELINE_RENDER_CAP).reverse().map((line) => parseLogLine(line));
  els.activity.innerHTML = items.length
    ? items.map(activityItem).join("")
    : '<li class="act-empty">No panel actions recorded yet.</li>';
  // F3: hard virtualize guard — trim any excess DOM nodes, oldest first.
  trimActivityDom();
}

// F3: ensure the activity list never exceeds TIMELINE_RENDER_CAP nodes.
function trimActivityDom() {
  if (!els.activity) return;
  const overflow = els.activity.children.length - TIMELINE_RENDER_CAP;
  if (overflow > 0) {
    // Newest-first list: oldest nodes are at the end, drop them.
    for (let i = 0; i < overflow; i += 1) {
      const last = els.activity.lastElementChild;
      if (!last) break;
      last.remove();
    }
  }
}

function ensureFilterStyles() {
  if (document.getElementById("activity-filter-styles")) return;
  const style = document.createElement("style");
  style.id = "activity-filter-styles";
  style.textContent = [
    ".act-filters{display:flex;flex-wrap:wrap;gap:8px;align-items:center;justify-content:space-between;margin-bottom:10px;}",
    ".act-chips{display:flex;flex-wrap:wrap;gap:6px;min-width:0;flex:1 1 auto;}",
    ".act-filter-chip{cursor:pointer;font:inherit;}",
    ".act-filter-chip:hover{border-color:var(--accent-ring);color:var(--text);}",
    ".act-filter-chip.is-active{background:var(--accent-soft);border-color:var(--accent-ring);color:#cfe1ff;font-weight:700;}",
    ".act-errors-toggle{display:inline-flex;align-items:center;gap:6px;font-size:11.5px;color:var(--muted);cursor:pointer;white-space:nowrap;user-select:none;}",
    ".act-errors-toggle input{accent-color:var(--accent);width:13px;height:13px;margin:0;cursor:pointer;}",
    ".act-level-warn .act-dot{border-color:var(--amber);box-shadow:0 0 0 3px rgba(240,179,92,0.12);}",
    ".act-level-error .act-dot{border-color:var(--red);box-shadow:0 0 0 3px rgba(240,106,106,0.12);}",
    ".act-src,.act-lvl{color:var(--faint);}",
    // F8: click-to-copy affordance for log lines.
    ".act-item{cursor:copy;}",
    ".act-item:hover .act-msg{text-decoration:underline dotted;}",
    ".act-item.is-copied{outline:1px solid var(--accent-ring);border-radius:6px;}",
  ].join("\n");
  document.head.appendChild(style);
}

function ensureFilterUI() {
  ensureFilterStyles();
  if (els.filters && document.contains(els.filters)) return;
  const pane = els.activity ? els.activity.parentElement : null;
  if (!pane) return;
  let container = document.getElementById("activity-filters");
  if (!container) {
    container = document.createElement("div");
    container.id = "activity-filters";
    container.className = "act-filters";
    const chips = document.createElement("div");
    chips.id = "activity-chips";
    chips.className = "act-chips";
    chips.setAttribute("role", "group");
    chips.setAttribute("aria-label", "Filter activity by source");
    const toggle = document.createElement("label");
    toggle.className = "act-errors-toggle";
    toggle.title = "Show warnings and errors only";
    const box = document.createElement("input");
    box.type = "checkbox";
    box.id = "activity-errors-only";
    box.checked = Boolean(state.errorsOnly);
    toggle.appendChild(box);
    toggle.appendChild(document.createTextNode("Errors only"));
    container.appendChild(chips);
    container.appendChild(toggle);
    pane.insertBefore(container, els.activity);
    chips.addEventListener("click", (event) => {
      const btn = event.target.closest("button[data-source]");
      if (!btn) return;
      const next = String(btn.dataset.source || "all").toLowerCase() || "all";
      if (next === state.sourceFilter) return;
      state.sourceFilter = next;
      try {
        localStorage.setItem(FILTER_STORAGE_SOURCE, next);
      } catch (_) {
        /* storage unavailable */
      }
      if (state.lastPayload) renderTimeline(state.lastPayload);
    });
    box.addEventListener("change", () => {
      state.errorsOnly = Boolean(box.checked);
      try {
        localStorage.setItem(FILTER_STORAGE_ERRORS, box.checked ? "1" : "0");
      } catch (_) {
        /* storage unavailable */
      }
      if (state.lastPayload) renderTimeline(state.lastPayload);
    });
  }
  els.filters = container;
  els.chips = container.querySelector("#activity-chips");
  els.errorsOnly = container.querySelector("#activity-errors-only");
}

// F2: errors-only client toggle — single entry point for checkbox UI + keyboard shortcut.
function setErrorsOnly(next) {
  state.errorsOnly = Boolean(next);
  try {
    localStorage.setItem(FILTER_STORAGE_ERRORS, state.errorsOnly ? "1" : "0");
  } catch (_) {
    /* storage unavailable */
  }
  ensureFilterUI();
  if (els.errorsOnly && els.errorsOnly.checked !== state.errorsOnly) {
    els.errorsOnly.checked = state.errorsOnly;
  }
  // Force re-render even when only the filter changed (bypass timelineKey fast-path).
  state.filterKey = null;
  if (state.lastPayload) renderTimeline(state.lastPayload);
}

function isErrorLevel(level) {
  return level === "warn" || level === "error";
}

function normalizeTimelineEntry(raw) {
  if (!raw || typeof raw !== "object") return null;
  const msg = String(raw.msg ?? raw.message ?? "").trim();
  if (!msg) return null;
  const source = String(raw.source ?? "panel").trim().toLowerCase() || "panel";
  const level = String(raw.level ?? "info").trim().toLowerCase() || "info";
  const isoRaw = raw.iso ?? raw.ts ?? "";
  let iso = "";
  let epoch = null;
  let clock = "";
  if (typeof isoRaw === "number" && Number.isFinite(isoRaw)) {
    epoch = isoRaw > 1e12 ? Math.round(isoRaw) : Math.round(isoRaw * 1000);
    const d = new Date(epoch);
    if (!Number.isNaN(d.getTime())) {
      iso = `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}T${pad2(d.getHours())}:${pad2(
        d.getMinutes(),
      )}:${pad2(d.getSeconds())}`;
      clock = iso.slice(11, 19);
    }
  } else if (isoRaw) {
    iso = String(isoRaw).trim();
    const parseable = iso.includes(" ") && !iso.includes("T") ? iso.replace(" ", "T") : iso;
    const parsed = Date.parse(parseable);
    if (Number.isFinite(parsed)) {
      epoch = parsed;
      if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?/.test(iso)) {
        clock = iso.slice(11, 19);
      } else {
        const d = new Date(parsed);
        clock = `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
      }
      if (iso.includes(" ")) iso = iso.replace(" ", "T");
      iso = iso.slice(0, 19);
    } else {
      iso = String(isoRaw).trim().slice(0, 64);
    }
  }
  return { epoch, iso, clock, source, level, msg };
}

function activityLinesToEntries(lines, skipSync) {
  const out = [];
  for (const line of lines || []) {
    const parsed = parseLogLine(line);
    const message = String(parsed.message || "").trim();
    if (!message) continue;
    const isSync = /^sync\s*:/i.test(message);
    if (skipSync && isSync) continue;
    out.push({
      epoch: parsed.ts,
      iso: parsed.iso || "",
      clock: parsed.clock || "",
      source: isSync ? "sync" : "panel",
      level: "info",
      msg: message,
    });
  }
  return out;
}

function buildCombinedTimeline(payload) {
  const rawTimeline = Array.isArray(payload.timeline) ? payload.timeline : [];
  const normalized = [];
  for (const raw of rawTimeline) {
    const entry = normalizeTimelineEntry(raw);
    if (entry) normalized.push(entry);
  }
  const activityLines = Array.isArray(payload.activity) ? payload.activity : [];
  const skipSync = Array.isArray(payload.timeline);
  const panelEntries = activityLinesToEntries(activityLines, skipSync);
  const seen = new Set(normalized.map((e) => `${e.iso}|${e.source}|${e.msg}`));
  for (const entry of panelEntries) {
    const key = `${entry.iso}|${entry.source}|${entry.msg}`;
    if (!seen.has(key)) {
      normalized.push(entry);
      seen.add(key);
    }
  }
  normalized.sort((a, b) => {
    if (a.epoch != null && b.epoch != null) return a.epoch - b.epoch;
    return String(a.iso || "").localeCompare(String(b.iso || ""));
  });
  return normalized;
}

function timelineItem(entry) {
  const source = String(entry.source || "panel");
  const level = String(entry.level || "info");
  const msg = String(entry.msg ?? "");
  const iso = String(entry.iso || "");
  const levelClass = level === "error" ? " act-level-error" : level === "warn" ? " act-level-warn" : "";
  const dotTitle = `${source} \u00B7 ${level}`;
  if (entry.epoch == null) {
    return `<li class="act-item${levelClass}"><span class="act-dot" title="${escapeHtml(
      dotTitle,
    )}" aria-hidden="true"></span><div class="act-body"><p class="act-msg">${escapeHtml(
      msg,
    )}</p><div class="act-time"><span class="act-src">${escapeHtml(source)}</span><span aria-hidden="true">\u00B7</span><span class="act-lvl">${escapeHtml(
      level,
    )}</span></div></div></li>`;
  }
  const clock = entry.clock || (iso.includes("T") ? iso.slice(11, 19) : "");
  const isoTitle = iso ? iso.replace("T", " ") : "";
  return (
    `<li class="act-item${levelClass}" data-ts="${entry.epoch}">` +
    `<span class="act-dot" title="${escapeHtml(dotTitle)}" aria-hidden="true"></span>` +
    `<div class="act-body"><p class="act-msg">${escapeHtml(msg)}</p>` +
    `<time class="act-time" datetime="${escapeHtml(iso)}" title="${escapeHtml(isoTitle)}">` +
    `<span class="act-src">${escapeHtml(source)}</span><span aria-hidden="true">\u00B7</span>` +
    `<span class="act-lvl">${escapeHtml(level)}</span><span aria-hidden="true">\u00B7</span>` +
    `<span class="act-rel">${relTime(entry.epoch)}</span><span class="act-clock">${escapeHtml(clock)}</span>` +
    `</time></div></li>`
  );
}

function renderFilterChips(sources, counts, total) {
  if (!els.chips) return;
  const parts = [
    `<button type="button" class="chip act-filter-chip${
      state.sourceFilter === "all" ? " is-active" : ""
    }" data-source="all" aria-pressed="${
      state.sourceFilter === "all" ? "true" : "false"
    }" title="Show all sources">All (${total})</button>`,
  ];
  for (const src of sources) {
    const count = counts.get(src) || 0;
    const active = state.sourceFilter === src;
    parts.push(
      `<button type="button" class="chip act-filter-chip${
        active ? " is-active" : ""
      }" data-source="${escapeHtml(src)}" aria-pressed="${
        active ? "true" : "false"
      }" title="Show ${escapeHtml(src)} entries only">${escapeHtml(src)} (${count})</button>`,
    );
  }
  els.chips.innerHTML = parts.join("");
}

function renderTimeline(payload) {
  ensureFilterUI();
  const combined = buildCombinedTimeline(payload || {});
  const dataKey = combined.map((e) => `${e.iso}|${e.source}|${e.level}|${e.msg}`).join("\n");
  const filterKey = `${state.sourceFilter}|${state.errorsOnly ? "1" : "0"}`;
  if (dataKey === state.timelineKey && filterKey === state.filterKey) return;
  state.timelineKey = dataKey;
  state.filterKey = filterKey;
  const errorsFiltered = state.errorsOnly ? combined.filter((e) => isErrorLevel(e.level)) : combined;
  const counts = new Map();
  for (const entry of errorsFiltered) counts.set(entry.source, (counts.get(entry.source) || 0) + 1);
  let sources = [...new Set(combined.map((e) => e.source))].sort();
  if (state.sourceFilter !== "all" && !sources.includes(state.sourceFilter)) sources.push(state.sourceFilter);
  sources.sort();
  renderFilterChips(sources, counts, errorsFiltered.length);
  if (els.errorsOnly && els.errorsOnly.checked !== state.errorsOnly) {
    els.errorsOnly.checked = state.errorsOnly;
  }
  const visible = errorsFiltered.filter(
    (entry) => state.sourceFilter === "all" || entry.source === state.sourceFilter,
  );
  // F3: virtualize — cap DOM nodes at TIMELINE_RENDER_CAP, drop oldest beyond the window.
  const windowed = visible.slice(-TIMELINE_RENDER_CAP);
  const items = windowed.reverse().map(timelineItem);
  if (!items.length) {
    let emptyText = "No panel actions recorded yet.";
    if (state.sourceFilter !== "all") emptyText = `No ${state.sourceFilter} entries in the last window`;
    else if (state.errorsOnly) emptyText = "No warn/error entries in the last window";
    els.activity.innerHTML = `<li class="act-empty">${escapeHtml(emptyText)}</li>`;
  } else {
    els.activity.innerHTML = items.join("");
  }
  trimActivityDom();
  try {
    state.activityKey = `${Array.isArray(payload.activity) ? payload.activity.join("\n") : ""}|${dataKey}|${filterKey}`;
  } catch (_) {
    /* ignore */
  }
}

function applyPendingState() {
  const pending = state.pending;
  document.querySelectorAll("button[data-action]").forEach((btn) => {
    const isMatch =
      Boolean(pending) && btn.dataset.service === pending.service && btn.dataset.action === pending.action;
    btn.disabled = Boolean(pending);
    btn.classList.toggle("is-loading", isMatch);
    if (isMatch) {
      btn.innerHTML = `<span class="spinner" aria-hidden="true"></span>${escapeHtml(pending.label)}`;
    } else if (!pending && GLOBAL_BUTTON_DEFAULTS.has(btn)) {
      btn.innerHTML = GLOBAL_BUTTON_DEFAULTS.get(btn);
    }
  });
  els.services.setAttribute("aria-busy", pending ? "true" : "false");
}

function render(payload) {
  state.lastPayload = payload;
  state.playbackKey = playbackKeyOf(payload);
  const services = payload.services || {};
  const cards = SERVICE_ORDER.map((key) => services[key]).filter(Boolean);
  els.services.innerHTML = cards.length
    ? cards.map(serviceCard).join("")
    : '<p class="pane-empty">No services reported by the panel.</p>';
  els.playback.innerHTML = playbackCard(payload.playback || null);
  updateStackChip(services);
  renderTimeline(payload);
  updateLastChecked();
  applyPendingState();
}

function updateLastChecked() {
  els.lastCheckedText.textContent = state.lastCheckedAt ? relTime(state.lastCheckedAt.getTime()) : "—";
}

function updateRelativeTimes() {
  updateLastChecked();
  const now = Date.now();
  document.querySelectorAll(".act-item[data-ts]").forEach((item) => {
    const rel = item.querySelector(".act-rel");
    if (rel) rel.textContent = relTime(Number(item.dataset.ts), now);
  });
}

async function fetchJson(url, options = null, timeoutMs = STATUS_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { cache: "no-store", signal: controller.signal, ...(options || {}) });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return await response.json();
  } catch (error) {
    if (error && error.name === "AbortError") {
      throw new Error("Request timed out");
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

// F4: fetch with exponential backoff + status pill updates.
// Retries network/5xx/timeout failures; 4xx (except 429) fails fast.
async function fetchJsonWithRetry(url, options = null, timeoutMs = STATUS_TIMEOUT_MS, maxRetries = FETCH_MAX_RETRIES) {
  let lastError = null;
  for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
    try {
      if (attempt > 0) {
        const delay = backoffDelayMs(attempt);
        state.backoffMs = delay;
        state.retryAttempt = attempt;
        setStatusPill("retrying", `Retrying… ${attempt}/${maxRetries}`);
        await sleep(delay);
      } else {
        state.retryAttempt = 0;
        setStatusPill("fetching");
      }
      const data = await fetchJson(url, options, timeoutMs);
      state.retryAttempt = 0;
      state.backoffMs = 0;
      return data;
    } catch (error) {
      lastError = error;
      const msg = String((error && error.message) || "");
      const statusMatch = /HTTP\s+(\d{3})/.exec(msg);
      const statusCode = statusMatch ? Number(statusMatch[1]) : 0;
      const retryable =
        statusCode === 0 || statusCode === 429 || statusCode >= 500 || /timed out|network|failed to fetch/i.test(msg);
      if (!retryable || attempt >= maxRetries) break;
    }
  }
  throw lastError || new Error("Request failed");
}

async function refreshStatus() {
  if (state.fetching) return;
  // F1: never poll while the tab is hidden.
  if (!state.tabVisible) return;
  state.fetching = true;
  if (els.lastChecked) els.lastChecked.classList.add("is-fetching");
  setStatusPill("fetching");
  try {
    const payload = await fetchJsonWithRetry(STATUS_URL);
    state.lastCheckedAt = new Date();
    state.unreachable = false;
    setStatusPill("live", "Live");
    render(payload);
    // F6: opportunistically enrich badges from /api/health (guarded, fallback to status).
    refreshServiceBadges(true);
  } catch (error) {
    state.unreachable = true;
    setStatusPill("stale", "Stale");
    updateStackChip(state.lastPayload ? state.lastPayload.services || {} : {});
    if (els.lastCheckedText) els.lastCheckedText.textContent = "stale";
  } finally {
    state.fetching = false;
    if (els.lastChecked) els.lastChecked.classList.remove("is-fetching");
  }
}

// F6: Service badges rendered from /api/health with fallback.
// Tries /api/health first; accepts several shapes; falls back to
// state.lastPayload.services (/api/status) and finally to the current DOM.
async function refreshServiceBadges(silent = false) {
  let health = null;
  try {
    health = await fetchJson(HEALTH_URL, null, 8000);
  } catch (_) {
    health = null;
  }
  const fromHealth = normalizeHealthToServices(health);
  if (fromHealth) {
    applyServiceBadges(fromHealth);
    return true;
  }
  if (!silent) {
    // Fallback 1: last /api/status payload already in memory.
    if (state.lastPayload && state.lastPayload.services) {
      applyServiceBadges(state.lastPayload.services);
      return true;
    }
  }
  // Fallback 2: try /api/metrics (may carry per-service health hints).
  try {
    const metrics = await fetchJson(METRICS_URL, null, 8000);
    const fromMetrics = normalizeMetricsToServices(metrics);
    if (fromMetrics) {
      applyServiceBadges(fromMetrics);
      return true;
    }
  } catch (_) {
    /* metrics absent — keep current badges */
  }
  if (state.lastPayload && state.lastPayload.services) {
    applyServiceBadges(state.lastPayload.services);
    return true;
  }
  return false;
}

function normalizeHealthToServices(health) {
  if (!health || typeof health !== "object") return null;
  // Shape A: { services: { jellyfin: {...}, ... } } (preferred).
  if (health.services && typeof health.services === "object") return health.services;
  // Shape B: { checks: [...] } or array of { id, state, ... }.
  const list = Array.isArray(health) ? health : health.checks || health.items;
  if (Array.isArray(list)) {
    const out = {};
    for (const item of list) {
      if (!item || typeof item !== "object") continue;
      const id = String(item.id || item.service || item.name || "").toLowerCase();
      if (!id) continue;
      out[id] = item;
    }
    return Object.keys(out).length ? out : null;
  }
  // Shape C: flat { status: "ok" } panel heartbeat — not per-service, use fallback.
  return null;
}

function normalizeMetricsToServices(metrics) {
  if (!metrics || typeof metrics !== "object") return null;
  if (metrics.services && typeof metrics.services === "object") return metrics.services;
  return null;
}

function applyServiceBadges(services) {
  if (!services || !els.services) return;
  for (const key of SERVICE_ORDER) {
    const svc = services[key];
    if (!svc) continue;
    const card = els.services.querySelector(`[data-service-id="${CSS.escape(key)}"]`);
    if (!card) continue;
    const badge = card.querySelector(".badge");
    if (badge) badge.outerHTML = badgeFor(svc);
    const detail = card.querySelector(".svc-detail");
    if (detail && typeof svc.detail === "string") detail.textContent = svc.detail;
    const stateKey = ["healthy", "warning", "starting", "stopped"].includes(svc.state) ? svc.state : "stopped";
    card.className = `service-card st-${stateKey}`;
  }
  updateStackChip({ ...(state.lastPayload ? state.lastPayload.services || {} : {}), ...services });
}

// F5: Last-play card refresh without full reload.
// Fetches status once and patches ONLY #playback-status when the playback
// payload actually changed (playbackKey dedupe). Never touches services/timeline.
async function refreshLastPlayCard() {
  if (!els.playback || state.fetching) return false;
  let payload = null;
  try {
    payload = await fetchJsonWithRetry(STATUS_URL, null, STATUS_TIMEOUT_MS, 1);
  } catch (_) {
    return false;
  }
  const playback = payload && payload.playback ? payload.playback : null;
  const key = JSON.stringify(playback || null);
  if (key === state.playbackKey) return true;
  state.playbackKey = key;
  els.playback.innerHTML = playbackCard(playback);
  if (payload && payload.services) {
    state.lastPayload = { ...(state.lastPayload || {}), ...payload, services: payload.services };
  }
  return true;
}

function playbackKeyOf(payload) {
  try {
    return JSON.stringify((payload && payload.playback) || null);
  } catch (_) {
    return null;
  }
}

async function runAction(service, action) {
  if (state.pending) return;
  state.pending = { service, action, label: verbLabel(service, action) };
  applyPendingState();
  try {
    const data = await fetchJson(
      "/api/action",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ service, action }),
      },
      ACTION_TIMEOUT_MS,
    );
    if (!data.ok) throw new Error(data.error || "Action failed");
    showToast(data.message || "Action completed", "success");
    if (data.status) {
      state.lastCheckedAt = new Date();
      state.unreachable = false;
      render(data.status);
    }
  } catch (error) {
    showToast(error.message || "Action failed", "error");
  } finally {
    state.pending = null;
    if (state.lastPayload) {
      render(state.lastPayload);
    } else {
      applyPendingState();
    }
    refreshStatus();
  }
}

// F8: click a log line to copy its text (msg + absolute timestamp).
async function copyTextToClipboard(text) {
  const value = String(text || "");
  if (!value) return false;
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(value);
      return true;
    }
  } catch (_) {
    /* fall through to legacy path */
  }
  try {
    const ta = document.createElement("textarea");
    ta.value = value;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand("copy");
    ta.remove();
    return ok;
  } catch (_) {
    return false;
  }
}

function logLineText(item) {
  if (!item) return "";
  const msg = item.querySelector(".act-msg");
  const time = item.querySelector("time");
  const body = msg ? msg.textContent.trim() : item.textContent.trim();
  const stamp = time ? (time.getAttribute("title") || time.getAttribute("datetime") || "").trim() : "";
  return stamp ? `${body} [${stamp}]` : body;
}

async function handleActivityCopy(event) {
  const item = event.target.closest ? event.target.closest(".act-item") : null;
  if (!item || !els.activity || !els.activity.contains(item)) return;
  // Don't hijack filter-chip or link clicks inside the timeline.
  if (event.target.closest("button, a")) return;
  const text = logLineText(item);
  if (!text) return;
  const ok = await copyTextToClipboard(text);
  showToast(ok ? "Log line copied" : "Copy failed", ok ? "success" : "error");
  if (ok) {
    item.classList.add("is-copied");
    setTimeout(() => item.classList.remove("is-copied"), 900);
  }
}

// F1: managed auto-refresh — pause when hidden, resume when visible.
function startPolling() {
  stopPolling();
  state.pollTimer = setInterval(() => {
    if (!state.tabVisible || state.pending || state.fetching) return;
    refreshStatus();
  }, POLL_MS);
}

function stopPolling() {
  if (state.pollTimer) {
    clearInterval(state.pollTimer);
    state.pollTimer = null;
  }
}

function handleVisibilityChange() {
  state.tabVisible = !document.hidden;
  if (document.hidden) {
    // F1: pause — stop the timer so no fetch fires while hidden.
    stopPolling();
  } else {
    // F1: resume — restart the timer and refresh immediately.
    startPolling();
    if (!state.pending) refreshStatus();
  }
}

// F9: keyboard shortcuts — e = errors-only toggle, r = refresh.
// Ignores keystrokes inside inputs/textareas/selects and contentEditable.
function handleKeyboardShortcut(event) {
  if (!event || event.defaultPrevented) return;
  if (event.ctrlKey || event.metaKey || event.altKey) return;
  const target = event.target;
  if (target) {
    const tag = String(target.tagName || "").toLowerCase();
    if (tag === "input" || tag === "textarea" || tag === "select" || target.isContentEditable) return;
  }
  const key = String(event.key || "").toLowerCase();
  if (key === "e") {
    ensureFilterUI();
    setErrorsOnly(!state.errorsOnly);
    showToast(state.errorsOnly ? "Errors-only filter on" : "Errors-only filter off", "info");
  } else if (key === "r") {
    if (!state.pending) refreshStatus();
  }
}

// F10: connection-status toast on offline/online transitions.
function handleOffline() {
  state.wasOffline = true;
  setStatusPill("offline", "Offline");
  showToast("Connection lost — panel offline", "error");
}

function handleOnline() {
  if (state.wasOffline) {
    showToast("Connection restored", "success");
  }
  state.wasOffline = false;
  setStatusPill("fetching");
  refreshStatus();
}

document.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-action]");
  if (button && !button.disabled) {
    runAction(button.dataset.service, button.dataset.action);
  }
});

// F8: delegate copy handler on the activity list.
if (els.activity) {
  els.activity.addEventListener("click", handleActivityCopy);
}

if (els.refresh) {
  els.refresh.addEventListener("click", () => {
    if (!state.pending) refreshStatus();
  });
}

function showSkeletons() {
  els.services.innerHTML = skeletonCards();
  els.playback.innerHTML = playbackSkeleton();
  els.activity.innerHTML = '<li class="act-empty">Loading activity…</li>';
}

// F1: pause auto-refresh when tab hidden, resume on visible.
document.addEventListener("visibilitychange", handleVisibilityChange);
// F9: e = errors toggle, r = refresh.
document.addEventListener("keydown", handleKeyboardShortcut);
// F10: offline/online connection toasts.
window.addEventListener("offline", handleOffline);
window.addEventListener("online", handleOnline);

showSkeletons();
ensureStatusPill();
setStatusPill("fetching");
refreshStatus();
startPolling();
// F7: relative timestamps tick every second (title holds the absolute time).
setInterval(updateRelativeTimes, TICK_MS);
