// Legacy mongo shell: print WiredTiger eviction/split/yield counters once per
// 100 ms for SAMPLES iterations. Keys match "forced", "split", "page acquire",
// "evict" or "reconcil" in the cache, thread-yield and reconciliation sections.
var re = /forced|split|page acquire|evict|reconcil/;
for (var i = 0; i < SAMPLES; i++) {
    var wt = db.adminCommand({ serverStatus: 1 }).wiredTiger;
    var out = { t_ms: new Date().getTime() };
    ["cache", "thread-yield", "reconciliation"].forEach(function (section) {
        Object.keys(wt[section] || {}).forEach(function (k) {
            if (re.test(k)) out[section + ": " + k] = wt[section][k];
        });
    });
    print(JSON.stringify(out));
    sleep(100);
}
