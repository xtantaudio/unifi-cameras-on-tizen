/* UniFi cameras on Tizen — grid + D-pad fullscreen selection.
 *
 * On load it fetches <host>/config.json (written by the restreamer) to learn the camera
 * names, count, and grid layout, then renders accordingly. So the app auto-adapts: change
 * cameras/order/count in the restreamer's config.json and the app follows on next launch.
 *
 * GRID mode : plays <host>/mosaic/index.m3u8; a highlight box marks the selected cell.
 *             Arrows move it; OK opens that camera fullscreen.
 * FULL mode : plays <host>/<stream>/index.m3u8 for one camera; Left/Right switch cameras;
 *             Back / OK returns to the grid.
 *
 * The TV has ONE hardware decoder, so every source switch fully tears down and rebuilds
 * AVPlay, and we release it on hide/close (else the next open() fails: InvalidAccessError).
 *
 * AUTO-RECOVERY: if the restreamer's ffmpeg restarts (or a stream stalls), the app
 * transparently reconnects instead of freezing on an error. See the retry block below.
 */
var HOST = (window.CAMTV && window.CAMTV.host) || "";
var cams = [];            // [{name, stream}]
var cols = 2, rows = 2;
var mode = "grid", sel = 0;
var hl, label, msg;

function showMsg(t){ msg.textContent = t; msg.style.display = t ? "block" : "none"; }

/* ---- auto-recovery ------------------------------------------------------
 * The restreamer's ffmpeg can go away underneath us — it restarts on a camera
 * change, gets kicked by the watchdog when it stalls, or the host reboots. The
 * naive handling (show "Stream error" and stop) leaves the TV dead until someone
 * relaunches the app by hand, which defeats the point of a wall display.
 *
 * So on failure we quietly reopen the SAME url, showing "Reconnecting…" rather than
 * an error.
 *
 * WE RETRY FOREVER, DELIBERATELY. An earlier version gave up after 10 attempts at 5s
 * = a 50 second budget, which measured well against a quick service restart and then
 * failed in the field: a 45s outage plus ~10s of ffmpeg startup put the stream back
 * at ~T+55, just after the retries ran out. The display showed "Stream error" and sat
 * dead indefinitely while a perfectly healthy stream was being served — and because
 * the app was still running, even relaunching it did nothing (the runtime just
 * foregrounds a live app without re-running its JS). Only a reinstall recovered it.
 *
 * Any finite ceiling has this failure mode; it only moves the outage length that
 * breaks it. A wall display has nobody standing by to press a button, so giving up
 * is never the right answer — a display that recovers late still recovers, while one
 * that stops trying is broken until a human intervenes. Hence backoff (fast for the
 * common quick restart, easing off so we don't hammer a host that's genuinely down)
 * with no upper bound.
 *
 *   curUrl     : source currently playing, so a retry knows what to replay
 *   retryCount : attempts made during THIS outage; reset to 0 on any success. It only
 *                selects the backoff delay and drives the message — it never stops us.
 *   bufferTimer: AVPlay's onerror does NOT always fire — a dead stream often just
 *                hangs in "buffering" forever. This catches that case.
 *   playToken  : bumped on every new play(). Any timer or callback carrying an old
 *                token is ignored, so switching cameras cleanly supersedes in-flight
 *                retries from the previous source (the TV has one decoder — a stale
 *                retry firing against a torn-down player is a hard failure).
 */
/* Backoff schedule in ms; the final value repeats forever. Quick at first so an
 * ordinary restreamer restart is nearly invisible, then easing to every 30s. */
var RETRY_BACKOFF_MS = [2000, 3000, 5000, 5000, 10000, 15000, 30000];
var HINT_AFTER_ATTEMPTS = 6; // when to start naming the likely cause on screen
var BUFFER_TIMEOUT = 15000;  // buffering-start with no complete => treat as an error

var curUrl = null;
var retryCount = 0;
var retryTimer = null;
var bufferTimer = null;
var playToken = 0;

function clearBufferWatchdog() {
  if (bufferTimer) { clearTimeout(bufferTimer); bufferTimer = null; }
}

function clearRetryTimers() {
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  clearBufferWatchdog();
}

/* Cancel pending recovery and invalidate outstanding callbacks. Call before any
 * teardown (close/hide/exit) so a stale retry can't fire against a dead player. */
function resetRetryState() {
  clearRetryTimers();
  retryCount = 0;
  curUrl = null;
  playToken++;
}

function armBufferWatchdog(token) {
  clearBufferWatchdog();
  bufferTimer = setTimeout(function () {
    if (token !== playToken) return;      // superseded by a newer play()
    handleStreamFailure(token);           // buffering never completed => hung
  }, BUFFER_TIMEOUT);
}

/* Single failure path for both onerror and the buffering-hang watchdog.
 * There is no give-up branch here on purpose — see the note above. */
function handleStreamFailure(token) {
  if (token !== playToken) return;        // stale event from a previous source
  clearRetryTimers();
  retryCount++;

  var delay = RETRY_BACKOFF_MS[Math.min(retryCount - 1, RETRY_BACKOFF_MS.length - 1)];

  // Early on, stay quiet and reassuring — most outages are a service restart and end
  // within seconds. Once it's clearly not that, name the likely cause, but keep going.
  if (retryCount < HINT_AFTER_ATTEMPTS) {
    showMsg("Reconnecting…");
  } else {
    showMsg("Reconnecting… (attempt " + retryCount + ") — check the restreamer");
  }

  retryTimer = setTimeout(function () {
    if (token !== playToken) return;      // superseded while waiting
    if (curUrl) openStream(curUrl, playToken);
  }, delay);
}

function closePlayer() {
  clearRetryTimers();
  try {
    var st = webapis.avplay.getState();
    if (st !== "NONE" && st !== "IDLE") webapis.avplay.stop();
    webapis.avplay.close();
  } catch (e) {}
}

/* Start a brand-new source. Resets the outage counter so each source gets a full
 * retry budget. */
function play(url) {
  resetRetryState();
  curUrl = url;
  openStream(url, playToken);
}

/* Open/prepare/play. Used by both play() (new source) and the retry path (same
 * source), so it must NOT touch retryCount or playToken. */
function openStream(url, token) {
  if (retryCount === 0) showMsg("Loading…");
  // Tear the decoder down but keep retry timers/token intact.
  try {
    var st = webapis.avplay.getState();
    if (st !== "NONE" && st !== "IDLE") webapis.avplay.stop();
    webapis.avplay.close();
  } catch (e) {}
  var av = webapis.avplay;
  try {
    av.open(url);
    av.setDisplayRect(0, 0, 1920, 1080);
    try { av.setDisplayMethod("PLAYER_DISPLAY_MODE_FULL_SCREEN"); } catch (e) {}
    av.setListener({
      onbufferingstart: function(){
        if (token !== playToken) return;
        armBufferWatchdog(token);
      },
      onbufferingcomplete: function(){
        if (token !== playToken) return;
        clearBufferWatchdog();
        retryCount = 0;                   // buffering succeeded => outage over
        showMsg("");
      },
      onerror: function(){ handleStreamFailure(token); }
    });
    av.prepareAsync(
      function(){
        if (token !== playToken) return;  // a newer play() won; abandon this one
        try { av.play(); } catch(e){}
        clearBufferWatchdog();
        retryCount = 0;
        showMsg("");
      },
      function(){ handleStreamFailure(token); }
    );
  } catch (e) {
    handleStreamFailure(token);           // synchronous open failure => retry
  }
}

function cellRect(i) {
  var cw = Math.floor(1920 / cols), ch = Math.floor(1080 / rows);
  return { x: (i % cols) * cw, y: Math.floor(i / cols) * ch, w: cw, h: ch };
}

function positionHighlight() {
  var r = cellRect(sel);
  hl.style.left = r.x + "px"; hl.style.top = r.y + "px";
  hl.style.width = r.w + "px"; hl.style.height = r.h + "px";
}

function enterGrid() {
  mode = "grid";
  label.style.display = "none";
  hl.style.display = "block";
  positionHighlight();
  play(HOST + "/mosaic/index.m3u8");
}

function enterFull() {
  mode = "full";
  hl.style.display = "none";
  label.textContent = cams[sel].name;
  label.style.display = "block";
  play(HOST + "/" + cams[sel].stream + "/index.m3u8");
}

function move(dCol, dRow) {
  var col = sel % cols, row = Math.floor(sel / cols);
  col = Math.min(cols - 1, Math.max(0, col + dCol));
  row = Math.min(rows - 1, Math.max(0, row + dRow));
  var next = row * cols + col;
  if (next < cams.length) sel = next;   // don't land on an empty (black) cell
}

function onKey(ev) {
  var k = ev.keyCode;
  if (mode === "grid") {
    if (k === 37) { move(-1, 0); positionHighlight(); }
    else if (k === 39) { move(1, 0); positionHighlight(); }
    else if (k === 38) { move(0, -1); positionHighlight(); }
    else if (k === 40) { move(0, 1); positionHighlight(); }
    else if (k === 13) { enterFull(); }
    else if (k === 10009) { exitApp(); }
  } else {
    if (k === 39) { sel = (sel + 1) % cams.length; label.textContent = cams[sel].name; play(HOST + "/" + cams[sel].stream + "/index.m3u8"); }
    else if (k === 37) { sel = (sel + cams.length - 1) % cams.length; label.textContent = cams[sel].name; play(HOST + "/" + cams[sel].stream + "/index.m3u8"); }
    else if (k === 10009 || k === 13) { enterGrid(); }
  }
}

function exitApp() {
  resetRetryState();
  closePlayer();
  try { tizen.application.getCurrentApplication().exit(); } catch (e) {}
}

function loadManifestThen(cb) {
  var xhr = new XMLHttpRequest();
  xhr.open("GET", HOST + "/config.json?_=" + Date.now(), true);
  xhr.onreadystatechange = function () {
    if (xhr.readyState !== 4) return;
    if (xhr.status === 200) {
      try {
        var m = JSON.parse(xhr.responseText);
        cams = m.cameras || [];
        cols = (m.grid && m.grid.cols) || Math.ceil(Math.sqrt(cams.length)) || 1;
        rows = (m.grid && m.grid.rows) || 1;
      } catch (e) {}
    }
    cb();
  };
  xhr.onerror = cb;
  xhr.send();
}

window.onload = function () {
  hl = document.getElementById("hl");
  label = document.getElementById("label");
  msg = document.getElementById("msg");

  try {
    ["ArrowLeft","ArrowRight","ArrowUp","ArrowDown","Enter","Return"].forEach(function(n){
      try { tizen.tvinputdevice.registerKey(n); } catch(e){}
    });
  } catch (e) {}

  document.addEventListener("keydown", onKey);
  // Backgrounded/hidden: stop pending reconnects too, or they fire against a
  // released decoder when the TV suspends the app.
  document.addEventListener("visibilitychange", function(){
    if (document.hidden) { resetRetryState(); closePlayer(); }
  });
  window.addEventListener("beforeunload", function(){ resetRetryState(); closePlayer(); });
  try {
    tizen.application.getCurrentApplication().addEventListener("blur", function(){
      resetRetryState(); closePlayer();
    });
  } catch (e) {}

  if (!HOST || HOST.indexOf("CHANGE_ME") !== -1) {
    showMsg("Set your restreamer host in app/js/config.js, then rebuild.");
    return;
  }
  showMsg("Connecting to " + HOST + "…");
  loadManifestThen(function () {
    if (!cams.length) { showMsg("No cameras from " + HOST + "/config.json — is the restreamer running?"); return; }
    enterGrid();
  });
};
