/* Copy this to config.js and set your host — `config.js` is gitignored, so your
 * address never lands in the repo:
 *
 *     cp app/js/config.example.js app/js/config.js
 *
 * Point it at your restreamer host (the machine running camtv.py + serve.py), port 8099.
 * That address is the ONLY app-side setting. Camera names, count, and grid layout are
 * fetched from that host at runtime, so you change cameras by editing the restreamer's
 * config.json — no app rebuild needed.
 */
window.CAMTV = {
  host: "http://CHANGE_ME:8099"
};
