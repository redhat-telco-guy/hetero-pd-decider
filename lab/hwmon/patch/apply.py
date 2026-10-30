import sys, os
d = os.path.dirname(os.path.abspath(__file__))
p = sys.argv[1]
s = open(p).read()
if "loadHW" in s:
    print("already patched"); sys.exit(0)
css, html, js = (open(os.path.join(d, f)).read() for f in ("hw.css", "hw.html", "hw.js"))
def rep(a, b):
    global s
    assert s.count(a) == 1, "anchor not found once: " + a[:60]
    s = s.replace(a, b)
rep("section[hidden]{display:none}", "section[hidden]{display:none}" + css)
rep('  <section id="stack" role="tabpanel" aria-labelledby="t-stack" class="stack" hidden>\n', html)
rep("// ---------- the stack ----------", js + "\n// ---------- the stack ----------")
rep("if(id==='stack'){invT=0;requestAnimationFrame(()=>{drawStack();loadInv();});}",
    "if(id==='stack'){invT=0;requestAnimationFrame(()=>{drawStack();loadInv();loadHW();});}")
rep("window.addEventListener('resize',()=>{if(!$('stack').hidden)drawStack();});",
    "window.addEventListener('resize',()=>{if(!$('stack').hidden){drawStack();if(HWD)drawHWCharts();}});")
open(p, "w").write(s)
print("patched", p)
