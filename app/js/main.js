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
 */
var HOST = (window.CAMTV && window.CAMTV.host) || "";
var cams = [];            // [{name, stream}]
var cols = 2, rows = 2;
var mode = "grid", sel = 0;
var hl, label, msg;

function showMsg(t){ msg.textContent = t; msg.style.display = t ? "block" : "none"; }

function closePlayer() {
  try {
    var st = webapis.avplay.getState();
    if (st !== "NONE" && st !== "IDLE") webapis.avplay.stop();
    webapis.avplay.close();
  } catch (e) {}
}

function play(url) {
  showMsg("Loading…");
  closePlayer();
  var av = webapis.avplay;
  try {
    av.open(url);
    av.setDisplayRect(0, 0, 1920, 1080);
    try { av.setDisplayMethod("PLAYER_DISPLAY_MODE_FULL_SCREEN"); } catch (e) {}
    av.setListener({
      onbufferingcomplete: function(){ showMsg(""); },
      onerror: function(){ showMsg("Stream error"); }
    });
    av.prepareAsync(
      function(){ try { av.play(); } catch(e){} showMsg(""); },
      function(){ showMsg("Can't open stream"); }
    );
  } catch (e) { showMsg("Open failed"); }
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
  document.addEventListener("visibilitychange", function(){ if (document.hidden) closePlayer(); });
  window.addEventListener("beforeunload", closePlayer);

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
