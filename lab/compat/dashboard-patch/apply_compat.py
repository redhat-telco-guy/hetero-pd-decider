import os, sys
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


patch(srv, [
    ("import http.client, json, os, random, re, ssl, threading, time, urllib.parse, urllib.request",
     "import http.client, json, os, random, re, ssl, threading, time, urllib.error, urllib.parse, urllib.request"),
    ("# ---------------- http ----------------", open(os.path.join(d, "server_compat.py")).read() + "\n# ---------------- http ----------------"),
    ('''        if self.path.startswith("/api/hw"):''', '''        if self.path.startswith("/api/compat"):
            try:
                return self.send_json(compat_state())
            except Exception as ex:
                return self.send_json({"error": str(ex)[:200]}, 500)
        if self.path.startswith("/api/hw"):'''),
    ('''            if self.path == "/api/heat/start":''', '''            if self.path in ("/api/compat/approve", "/api/compat/revoke", "/api/compat/retest"):
                who = self.headers.get("X-Forwarded-User") or self.headers.get("X-Forwarded-Email") or "dashboard"
                try:
                    compat_update(str(b.get("id", "")), self.path.rsplit("/", 1)[1], who)
                except PermissionError as ex:
                    return self.send_json({"error": str(ex)}, 409)
                except ValueError as ex:
                    return self.send_json({"error": str(ex)}, 400)
                return self.send_json({"ok": True})
            if self.path == "/api/heat/start":'''),
], "def compat_state(")

patch(page, [
    ('''    <div class="panel">
      <h2>What runs where</h2>''', open(os.path.join(d, "compat.html")).read() + '''    <div class="panel">
      <h2>What runs where</h2>'''),
    ("// ---------- heat test (Stack tab) ----------", open(os.path.join(d, "compat.js")).read() + "\n// ---------- heat test (Stack tab) ----------"),
    ("requestAnimationFrame(()=>{drawStack();loadInv();loadHW();});", "requestAnimationFrame(()=>{drawStack();loadInv();loadHW();loadCompat();});"),
], "id=\"compatPanel\"")

patch(yml, [
    ('''  - {apiGroups: [""], resources: ["configmaps"], verbs: ["create"]}''',
     '''  - {apiGroups: [""], resources: ["configmaps"], verbs: ["create"]}
  - {apiGroups: [""], resources: ["configmaps"], resourceNames: ["kv-compat-approvals"], verbs: ["get", "patch"]}'''),
], "kv-compat-approvals")
