// Local Projects plugin: collection script + pure parsers.
//
// Two sources of "things listening on localhost":
//   NATIVE  - plain processes (ss -ltnp), identified by PID. The project
//             folder is the cwd of that PID (e.g. `npm run dev`, `php artisan
//             serve` run directly on the host). CPU/RSS come from `ps`. Each
//             row also carries the process's /proc starttime (a monotonic
//             per-boot counter): PIDs get reused, but a (pid, starttime)
//             pair identifies one specific process instance, which is what
//             lets the kill action below verify it's still killing the same
//             process it showed you, not whatever reused that PID meanwhile.
//   DOCKER  - containers with published host ports. The project folder is
//             read from the docker-compose working-dir label, so a whole
//             compose stack (nginx, vite, mailpit, ...) groups under the
//             folder that holds its docker-compose.yml. CPU/mem come from
//             `docker stats --no-stream`. Each row also carries the
//             container's immutable 64-char ID, used for the kill action
//             instead of its (renamable, reusable) name.
//
// Output is sectioned, "|" separated (folder/container names cannot contain "|"):
//   ==NATIVE== port|folder|comm|pid|cpuPercent|rssKb|startTime
//   ==DOCKER== name|composeProject|workingDir|hostPort1,hostPort2,...|containerId
//   ==STATS==  name|cpuPercent|memUsageText   (docker stats, one line per container)
var snapshotScript = [
  "echo '==NATIVE=='",
  "ss -Hltnp 2>/dev/null | while read -r _state _recvq _sendq local _peer proc _rest; do",
  "  port=\"${local##*:}\"",
  "  addr=\"${local%:*}\"",
  "  addr=$(printf '%s' \"$addr\" | tr -d '[]')",
  "  case \"$addr\" in",
  "    127.0.0.1|localhost|0.0.0.0|::|::1) ;;",
  "    *) continue ;;",
  "  esac",
  "  [[ $proc =~ pid=([0-9]+) ]] || continue",
  "  pid=\"${BASH_REMATCH[1]}\"",
  "  cwd=$(readlink -f \"/proc/$pid/cwd\" 2>/dev/null)",
  "  [ -z \"$cwd\" ] && continue",
  "  folder=$(basename \"$cwd\")",
  "  read -r cpu rss comm <<< \"$(ps -p \"$pid\" -o %cpu=,rss=,comm= 2>/dev/null)\"",
  "  starttime=$(awk -v RS=')' 'END{n=split($0,a,\" \"); print a[20]}' \"/proc/$pid/stat\" 2>/dev/null)",
  "  echo \"native|$port|$folder|${comm:-process}|$pid|${cpu:-0}|${rss:-0}|${starttime:-0}\"",
  "done",
  "echo '==DOCKER=='",
  "if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then",
  "  ids=$(docker ps -q 2>/dev/null)",
  "  if [ -n \"$ids\" ]; then",
  "    docker inspect --format '{{.Name}}|{{index .Config.Labels \"com.docker.compose.project\"}}|{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}|{{range $p,$b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}},{{end}}{{end}}|{{.Id}}' $ids 2>/dev/null",
  "    echo '==STATS=='",
  "    docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' $ids 2>/dev/null",
  "  fi",
  "fi"
].join("\n")

// Run as `python3 -u -c <this> <pid> <expectedStartTime>`, fed "confirm\n" (or
// nothing, on cancel) over stdin. Verifies the target is still the exact
// process instance the popup showed (same pid *and* /proc starttime), opens
// a pidfd for it, prints READY, then blocks on stdin. A pidfd stays bound to
// that one process instance even if its numeric PID is later reused by an
// unrelated process, so the SIGTERM sent on "confirm" — however long the
// user took to click through the confirmation dialog — either reaches the
// original process or fails closed (ESRCH), never a PID-reuse impostor.
var pidfdHelperScript = [
  "import sys, os, signal",
  "",
  "def current_starttime(pid):",
  "    try:",
  "        with open('/proc/%d/stat' % pid, 'r') as f:",
  "            data = f.read()",
  "    except Exception:",
  "        return None",
  "    idx = data.rfind(')')",
  "    if idx < 0:",
  "        return None",
  "    rest = data[idx + 2:].split()",
  "    if len(rest) < 20:",
  "        return None",
  "    return rest[19]",
  "",
  "pid = int(sys.argv[1])",
  "expected_start = sys.argv[2]",
  "",
  "if current_starttime(pid) != expected_start:",
  "    print('MISMATCH'); sys.stdout.flush(); sys.exit(3)",
  "",
  "try:",
  "    fd = os.pidfd_open(pid, 0)",
  "except OSError:",
  "    print('NOPID'); sys.stdout.flush(); sys.exit(4)",
  "",
  "print('READY'); sys.stdout.flush()",
  "line = sys.stdin.readline()",
  "if line.strip() == 'confirm':",
  "    if current_starttime(pid) != expected_start:",
  "        print('MISMATCH')",
  "    else:",
  "        try:",
  "            signal.pidfd_send_signal(fd, signal.SIGTERM, None, 0)",
  "            print('SIGNALED')",
  "        except OSError as e:",
  "            print('ESRCH' if e.errno == 3 else ('ERROR:' + str(e)))",
  "else:",
  "    print('CANCELED')",
  "sys.stdout.flush()",
  "os.close(fd)"
].join("\n")

function basename(p) {
  var s = String(p || "").replace(/\/+$/, "")
  var idx = s.lastIndexOf("/")
  return idx >= 0 ? s.slice(idx + 1) : s
}

function uniqueSortedPorts(csv) {
  var seen = {}
  var out = []
  var parts = String(csv || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var n = parseInt(parts[i], 10)
    if (!isFinite(n) || n <= 0 || seen[n]) continue
    seen[n] = true
    out.push(n)
  }
  return out
}

function parseCpuPercent(raw) {
  var m = /^(\d+(?:\.\d+)?)/.exec(String(raw || "").trim())
  return m ? m[1] : ""
}

function parseSizeToBytes(text) {
  var m = /^(\d+(?:\.\d+)?)\s*([KMGT]?i?B)$/i.exec(String(text || "").trim())
  if (!m) return 0
  var value = parseFloat(m[1])
  if (!isFinite(value)) return 0
  var unit = m[2].toUpperCase()
  var mult = 1
  if (unit === "KB") mult = 1000
  else if (unit === "KIB") mult = 1024
  else if (unit === "MB") mult = 1000 * 1000
  else if (unit === "MIB") mult = 1024 * 1024
  else if (unit === "GB") mult = 1000 * 1000 * 1000
  else if (unit === "GIB") mult = 1024 * 1024 * 1024
  return Math.round(value * mult)
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n >= 1073741824) return (Math.round(n / 1073741824 * 10) / 10) + " GiB"
  if (n >= 1048576) return (Math.round(n / 1048576 * 10) / 10) + " MiB"
  if (n >= 1024) return (Math.round(n / 1024 * 10) / 10) + " KiB"
  return Math.round(n) + " B"
}

// Groups rows by folder, sorts entries within a group by port, and sorts
// groups by their lowest port so the most likely "main" project surfaces
// first without needing any per-service guesswork.
function groupByFolder(rows) {
  var order = []
  var byFolder = {}
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!byFolder[row.folder]) {
      byFolder[row.folder] = { folder: row.folder, entries: [] }
      order.push(row.folder)
    }
    byFolder[row.folder].entries.push({
      port: row.port,
      label: row.label,
      source: row.source,
      pid: row.pid || 0,
      startTime: row.startTime || "",
      containerId: row.containerId || "",
      containerName: row.containerName || "",
      cpuPercent: row.cpuPercent || "",
      memBytes: row.memBytes || 0
    })
  }

  var groups = order.map(function(folder) { return byFolder[folder] })
  groups.forEach(function(g) {
    g.entries.sort(function(a, b) { return a.port - b.port })
  })
  groups.sort(function(a, b) { return a.entries[0].port - b.entries[0].port })
  return groups
}

function parseSnapshot(text) {
  var sections = {}
  var current = ""
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var header = /^==(.+)==$/.exec(line.trim())
    if (header) {
      current = header[1]
      sections[current] = []
    } else if (current !== "") {
      sections[current].push(line)
    }
  }

  // docker stats indexed by container name, so port rows (built from the
  // separate inspect pass) can attach live CPU/mem without a second lookup.
  var statsByName = {}
  var statsLines = sections["STATS"] || []
  for (var s = 0; s < statsLines.length; s++) {
    var sp = statsLines[s].split("|")
    if (sp.length < 3 || sp[0].trim() === "") continue
    var memPart = String(sp[2] || "").split("/")[0]
    statsByName[sp[0].trim()] = {
      cpuPercent: parseCpuPercent(sp[1]),
      memBytes: parseSizeToBytes(memPart)
    }
  }

  var portsSeen = {}
  var rows = []

  var nativeLines = sections["NATIVE"] || []
  for (var n = 0; n < nativeLines.length; n++) {
    var np = nativeLines[n].split("|")
    if (np.length < 4 || np[0] !== "native") continue
    var nPort = parseInt(np[1], 10)
    if (!isFinite(nPort) || nPort <= 0 || portsSeen[nPort]) continue
    var nFolder = String(np[2] || "").trim()
    if (nFolder === "") continue
    portsSeen[nPort] = true
    rows.push({
      folder: nFolder,
      port: nPort,
      label: String(np[3] || "").trim() || "process",
      source: "native",
      pid: parseInt(np[4], 10) || 0,
      cpuPercent: parseCpuPercent(np[5]),
      memBytes: (parseInt(np[6], 10) || 0) * 1024,
      startTime: String(np[7] || "0").trim()
    })
  }

  var dockerLines = sections["DOCKER"] || []
  for (var d = 0; d < dockerLines.length; d++) {
    var dp = dockerLines[d].split("|")
    if (dp.length < 4) continue
    var containerName = String(dp[0] || "").trim().replace(/^\//, "")
    var composeProject = String(dp[1] || "").trim()
    var workingDir = String(dp[2] || "").trim()
    var folder = basename(workingDir) || composeProject || containerName
    var containerId = String(dp[4] || "").trim()
    var stats = statsByName[containerName] || { cpuPercent: "", memBytes: 0 }
    var dPorts = uniqueSortedPorts(dp[3])
    for (var p = 0; p < dPorts.length; p++) {
      var port = dPorts[p]
      if (portsSeen[port]) continue
      portsSeen[port] = true
      rows.push({
        folder: folder,
        port: port,
        label: containerName,
        source: "docker",
        containerName: containerName,
        containerId: containerId,
        cpuPercent: stats.cpuPercent,
        memBytes: stats.memBytes
      })
    }
  }

  return groupByFolder(rows)
}

if (typeof module !== "undefined") {
  module.exports = {
    snapshotScript: snapshotScript,
    pidfdHelperScript: pidfdHelperScript,
    basename: basename,
    uniqueSortedPorts: uniqueSortedPorts,
    parseCpuPercent: parseCpuPercent,
    parseSizeToBytes: parseSizeToBytes,
    formatBytes: formatBytes,
    groupByFolder: groupByFolder,
    parseSnapshot: parseSnapshot
  }
}
