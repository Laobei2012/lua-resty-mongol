// Runs in the legacy mongo shell inside the Mongo pod.
// Set SAMPLES with --eval. SAMPLES=0 prints one full snapshot and exits.
// Otherwise it prints one JSON line of storage counters per second.
function readFile(path) {
    try { return cat(path); } catch (e) { return null; }
}
function pick(section, keys) {
    var out = {};
    keys.forEach(function (k) { out[k] = section ? section[k] : null; });
    return out;
}
function disks() {
    var text = readFile("/proc/diskstats");
    if (text === null) return null;
    return text.split("\n").filter(function (line) {
        var name = line.trim().split(/\s+/)[2];
        return /^(sd[a-z]+|vd[a-z]+|nvme\d+n\d+|dm-\d+)$/.test(name || "");
    }).map(function (line) { return line.trim(); });
}
var LOG = ["log bytes written", "log sync operations",
    "log sync time duration (usecs)", "log flush operations",
    "slot join calls slept", "slot joins yield time (usecs)"];
var TXN = ["transaction checkpoints", "transaction checkpoint currently running",
    "transaction checkpoint total time (msecs)",
    "transaction checkpoint max time (msecs)",
    "transaction checkpoint most recent time (msecs)"];
var CACHE = ["tracked dirty bytes in the cache", "bytes currently in the cache",
    "application threads page write from cache to disk time (usecs)",
    "application threads page write from cache to disk count",
    "pages evicted by application threads", "modified pages evicted"];
var BLOCK = ["bytes written", "bytes written for checkpoint", "blocks written"];
function line(histograms) {
    var s = db.adminCommand({ serverStatus: 1, opLatencies: { histograms: histograms } });
    var wt = s.wiredTiger;
    return {
        t_ms: new Date().getTime(),
        writes: s.opLatencies.writes,
        log: pick(wt.log, LOG),
        txn: pick(wt.transaction, TXN),
        cache: pick(wt.cache, CACHE),
        block: pick(wt["block-manager"], BLOCK),
        disks: disks(),
        host_io_psi: readFile("/proc/pressure/io"),
        host_cpu_psi: readFile("/proc/pressure/cpu"),
        cg_io_psi: readFile("/sys/fs/cgroup/io.pressure"),
        cg_cpu_psi: readFile("/sys/fs/cgroup/cpu.pressure"),
        cg_cpu_stat: readFile("/sys/fs/cgroup/cpu.stat")
    };
}
if (SAMPLES === 0) {
    print(JSON.stringify(line(true)));
} else {
    for (var i = 0; i < SAMPLES; i++) {
        print(JSON.stringify(line(false)));
        sleep(1000);
    }
}
