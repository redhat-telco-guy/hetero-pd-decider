#!/usr/bin/env python3
"""hw-monitor: read-only hardware readings for the node it runs on, served as JSON on :9477/json.

Runs as a privileged DaemonSet pod with the host network (so it sees the host's network cards and /dev/ipmi0)
and the host filesystem at /host. Reads only:
  BMC (ipmitool sensor / dcmi / sel): fans, fan zones, every temperature sensor with its alarm thresholds,
       sensors with no reading, server power, recent BMC events
  Linux: NVIDIA cards via the driver container's nvidia-smi, chip temperatures from hwmon, network cards,
       kernel warnings since boot
It never writes to the BMC, the cards or the host.
"""
import glob, json, os, re, subprocess, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

NODE = os.environ.get("NODE_NAME", "?")
PORT = int(os.environ.get("PORT", "9477"))
S = {"node": NODE, "t": 0, "tBmc": 0, "server": {}, "fans": [], "zones": [], "temps": [], "blind": [], "power": None,
     "cards": [], "chips": [], "nics": [], "kernel": [], "sel": [], "errors": []}
L = threading.Lock()

def run(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None

def rd(p, default=""):
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return default

def server_info():
    g = lambda k: run(["dmidecode", "-s", k]).strip()
    mc = run(["ipmitool", "mc", "info"])
    m = re.search(r"Firmware Revision\s*:\s*(\S+)", mc)
    return {"maker": g("system-manufacturer"), "model": g("system-product-name"), "bios": g("bios-version"),
            "biosDate": g("bios-release-date"), "bmc": m.group(1) if m else "", "upSince": run(["chroot", "/host", "uptime", "-s"]).strip()}

BLIND = re.compile(r"pcie|gpu|ocp|accel|riser", re.I)
def bmc_loop():
    nsel = 0
    while True:
        out = run(["ipmitool", "sensor"], 120)
        fans, zones, temps, blind = [], [], [], []
        for ln in out.splitlines():
            c = [p.strip() for p in ln.split("|")]
            if len(c) < 10:
                continue
            name, val, unit, status = c[0], num(c[1]), c[2], c[3]
            th = dict(zip(("lnr", "lcr", "lnc", "unc", "ucr", "unr"), map(num, c[4:10])))
            if unit == "degrees C":
                if val is None:
                    if BLIND.search(name):
                        blind.append(name)
                else:
                    temps.append({"name": name, "c": val, "warn": th["unc"], "crit": th["ucr"], "status": status})
            elif unit == "RPM" and val is not None:
                fans.append({"name": name, "rpm": val, "lowCrit": th["lcr"], "status": status})
            elif unit == "percent" and val is not None and re.search(r"fan|zone|pwm|duty", name, re.I):
                zones.append({"name": name, "pct": val})
        pw = None
        m = re.search(r"Instantaneous power reading:\s*(\d+)", run(["ipmitool", "dcmi", "power", "reading"]))
        if m:
            pw = float(m.group(1))
        sel = S["sel"]
        if nsel % 6 == 0:
            sel = [l.strip() for l in run(["ipmitool", "sel", "elist"]).splitlines()[-12:]]
        nsel += 1
        with L:
            S.update(fans=fans, zones=zones, temps=sorted(temps, key=lambda t: -t["c"]), blind=sorted(set(blind)),
                     power=pw, sel=sel, tBmc=time.time())
        time.sleep(5)

NV = "/host/run/nvidia/driver"
def nvidia():
    if not os.path.exists(NV + "/usr/bin/nvidia-smi"):
        return []
    q = "index,pci.bus_id,name,temperature.gpu,power.draw,power.limit,utilization.gpu,clocks_throttle_reasons.active"
    out = run(["chroot", NV, "nvidia-smi", "--query-gpu=" + q, "--format=csv,noheader,nounits"], 20)
    cards = []
    for ln in out.splitlines():
        c = [x.strip() for x in ln.split(",")]
        if len(c) >= 8:
            cards.append({"vendor": "NVIDIA", "id": "A30 #" + str(int(c[0]) + 1), "bus": c[1], "name": c[2], "c": num(c[3]),
                          "w": num(c[4]), "limitW": num(c[5]), "util": num(c[6]), "throttle": c[7]})
    return cards

NVLIM = {}
def nvidia_limits():
    out = run(["chroot", NV, "nvidia-smi", "-q", "-d", "TEMPERATURE"], 20)
    lim = {}
    for k, key in (("GPU Shutdown Temp", "shutdown"), ("GPU Slowdown Temp", "slowdown"), ("GPU Max Operating Temp", "maxOp")):
        m = re.search(k + r"\s*:\s*(\d+)", out)
        if m:
            lim[key] = float(m.group(1))
    return lim

def chips():
    res = []
    for h in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        nm = rd(h + "/name")
        if nm in ("coretemp", "acpitz", "pch_cannonlake", "pch_icelake"):
            continue
        dev = os.path.basename(os.path.realpath(h + "/device")) if os.path.exists(h + "/device") else ""
        for t in sorted(glob.glob(h + "/temp*_input")):
            b = t[:-6]; v = num(rd(t))
            if v is None:
                continue
            mx, cr = num(rd(b + "_max", None)), num(rd(b + "_crit", None))
            res.append({"chip": nm, "dev": dev, "label": rd(b + "_label") or os.path.basename(b), "c": v / 1000,
                        "max": mx / 1000 if mx else None, "crit": cr / 1000 if cr else None})
    return res

LSPCI = {}
def nics():
    route = rd("/proc/net/route").splitlines()[1:]
    dflt = next((l.split()[0] for l in route if l.split()[1] == "00000000"), "")
    res = []
    for i in sorted(glob.glob("/sys/class/net/*")):
        n = os.path.basename(i)
        if not os.path.exists(i + "/device"):
            continue
        bdf = os.path.basename(os.path.realpath(i + "/device"))
        if bdf not in LSPCI:
            LSPCI[bdf] = run(["lspci", "-s", bdf]).strip().split(" ", 1)[-1]
        st = lambda k: int(rd(f"{i}/statistics/{k}", "0") or 0)
        res.append({"name": n, "bus": bdf, "desc": LSPCI[bdf], "driver": os.path.basename(os.path.realpath(i + "/device/driver")),
                    "state": rd(i + "/operstate"), "speed": num(rd(i + "/speed")), "default": n == dflt,
                    "rxErr": st("rx_errors"), "txErr": st("tx_errors"), "rxDrop": st("rx_dropped"), "txDrop": st("tx_dropped"),
                    "crc": st("rx_crc_errors")})
    return res

KRE = re.compile(r"habanalabs|nvrm|xid|thermal|throttl|aer|pcie bus error|mce|hardware error|temperature", re.I)
KBAD = re.compile(r"err|fail|warn|thermal|throttl|xid|critical|over|temperature", re.I)
def kernel():
    out = run(["chroot", "/host", "journalctl", "-k", "-b", "--no-pager", "-o", "short-iso"], 60)
    hits = [l for l in out.splitlines() if KRE.search(l) and KBAD.search(l)]
    return {"count": len(hits), "last": hits[-12:]}

def fast_loop():
    global NVLIM
    k = 0
    while True:
        try:
            if k % 120 == 0 and os.path.exists(NV + "/usr/bin/nvidia-smi"):
                NVLIM = nvidia_limits()
            cards = nvidia()
            for c in cards:
                c.update(NVLIM)
            upd = {"cards": cards, "chips": chips(), "nics": nics(), "t": time.time()}
            if k % 12 == 0:
                upd["kernel"] = kernel()
            if k % 120 == 0:
                upd["server"] = server_info()
            with L:
                S.update(upd)
        except Exception as e:
            with L:
                S["errors"] = [str(e)[:200]]
        k += 1
        time.sleep(5)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        with L:
            b = json.dumps(S).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

if __name__ == "__main__":
    threading.Thread(target=bmc_loop, daemon=True).start()
    threading.Thread(target=fast_loop, daemon=True).start()
    print(f"hw-monitor on {NODE} serving :{PORT}/json", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
