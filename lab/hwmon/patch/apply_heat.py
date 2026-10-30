import sys, os
d = os.path.dirname(os.path.abspath(__file__))
srv, page, yml = sys.argv[1], sys.argv[2], sys.argv[3]

def patch(path, pairs, marker):
    s = open(path).read()
    if marker in s:
        print("already patched", path); return
    for a, b in pairs:
        assert s.count(a) == 1, f"{path}: anchor not found once: {a[:70]}"
        s = s.replace(a, b)
    open(path, "w").write(s); print("patched", path)

heat = open(os.path.join(d, "heat_server.py")).read()
patch(srv, [
    ("# ---------------- http ----------------", heat + "\n# ---------------- http ----------------"),
    ('''                h = dict(HW); ser = {k: thin(v) for k, v in HW["series"].items()}''',
     '''                h = dict(HW); ser = {k: thin(v) for k, v in HW["series"].items()}
                h["heat"] = dict(HEAT, windows=[dict(w) for w in HEAT["windows"]])'''),
    ('''            if self.path == "/api/traffic/start":
                if SUITE.get("running"):''',
     '''            if self.path == "/api/heat/start":
                if HEAT.get("running"):
                    return self.send_json({"error": "A heat test is already running."}, 409)
                if (RUN and RUN.alive()) or SUITE.get("running"):
                    return self.send_json({"error": "Stop the traffic or test suite first."}, 409)
                try:
                    start_heat(b)
                except ValueError as ex:
                    return self.send_json({"error": str(ex)}, 400)
                return self.send_json({"ok": True})
            if self.path == "/api/heat/stop":
                HEAT_STOP.set(); return self.send_json({"ok": True})
            if self.path == "/api/traffic/start":
                if HEAT.get("running"):
                    return self.send_json({"error": "A heat test is running (Stack tab)."}, 409)
                if SUITE.get("running"):'''),
    ('''            if self.path == "/api/traffic/stop":
                SUITE["stop"] = True''',
     '''            if self.path == "/api/traffic/stop":
                SUITE["stop"] = True; HEAT_STOP.set()   # the Gaudi watchdog calls this too'''),
], "def start_heat(")

patch(page, [
    ('''      <ul class="issues" id="hwIssues"></ul>
    </div>''', open(os.path.join(d, "heat.html")).read()),
    ("// ---------- live hardware (Stack tab) ----------", open(os.path.join(d, "heat.js")).read() + "\n// ---------- live hardware (Stack tab) ----------"),
    ("  drawHWCharts();\n}", "  drawHWCharts();drawHeat();\n}"),
    ("lineChart('chTemp','lgTemp',temp,{unit:'°C',refs:[{v:80,label:'Gaudi stop 80 °C'}],yMin:20});",
     "const wins=((HWD.heat||{}).windows||[]);\n  lineChart('chTemp','lgTemp',temp,{unit:'°C',refs:[{v:80,label:'Gaudi stop 80 °C'}],yMin:20,wins});"),
    ("lineChart('chPow','lgPow',per('power'),{unit:'W',yMin:0});", "lineChart('chPow','lgPow',per('power'),{unit:'W',yMin:0,wins});"),
    ("lineChart('chFan','lgFan',per('fanrpm'),{unit:'RPM',yMin:0});", "lineChart('chFan','lgFan',per('fanrpm'),{unit:'RPM',yMin:0,wins});"),
    ("lineChart('chZone','lgZone',per('fanpct'),{unit:'%',yMin:0,yMax:100,empty:", "lineChart('chZone','lgZone',per('fanpct'),{unit:'%',yMin:0,yMax:100,wins,empty:"),
    ("  for(let v=lo;v<=hi+1e-9;v+=step){el2('line'",
     "  (o.wins||[]).forEach(w=>{const a=Math.max(t0,w.start),b=w.end||now;if(b<t0)return;el2('rect',{x:X(a),y:mt,width:Math.max(1,X(b)-X(a)),height:H-mt-mb,fill:'var(--accent-soft)'});el2('text',{x:X(a)+3,y:mt+11,'font-size':10,fill:'var(--accent)'},'test: '+w.target);});\n  for(let v=lo;v<=hi+1e-9;v+=step){el2('line'"),
], "id=\"heatGo\"")

patch(yml, [
    ('''  - {apiGroups: ["apps"], resources: ["deployments"], resourceNames: ["hetero-pd-epp"], verbs: ["get", "patch"]}''',
     '''  - {apiGroups: ["apps"], resources: ["deployments"], resourceNames: ["hetero-pd-epp", "decode-gaudi3"], verbs: ["get", "patch"]}
  - {apiGroups: ["apps"], resources: ["deployments/scale"], resourceNames: ["decode-gaudi3"], verbs: ["get", "patch"]}'''),
], "deployments/scale")
