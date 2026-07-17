/* The ONLY thing you edit in the app before building.
 * Point it at your restreamer host (the machine running camtv.py + serve.py), port 8099.
 * Everything else — camera names, count, grid layout — is fetched from that host at runtime,
 * so you change cameras by editing the restreamer's config.json, NOT by rebuilding the app.
 */
window.CAMTV = {
  host: "http://CHANGE_ME:8099"
};
