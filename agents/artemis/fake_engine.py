import json, socket, subprocess, sys, time, base64, os
PORT = 8799
env = dict(os.environ)
env.setdefault("ARTEMIS_AIB_MODEL", "qwen3-vl:8b")  # vision *and* tools
proc = subprocess.Popen(
    [sys.executable, os.path.join(os.path.dirname(__file__), "aib_artemis_agent.py"), "--port", str(PORT)],
    env=env,
)
time.sleep(4)
s = socket.create_connection(("127.0.0.1", PORT), timeout=20); f = s.makefile("rwb")
n = [0]
def call(method, payload=None, timeout=120):
    n[0] += 1
    s.settimeout(timeout)
    f.write((json.dumps({"jsonrpc":"2.0","id":n[0],"method":method,"params":payload or {}})+"\n").encode()); f.flush()
    return json.loads(f.readline())
import zlib, struct

def _png(width=8, height=8):
    raw = b"".join(b"\x00" + bytes([200, 200, 200] * width) for _ in range(height))
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

png = base64.b64encode(_png()).decode()
try:
    call("aib.handshake", {"protocolVersion": "2.0", "role": "engine"}); call("agent.manifest")
    print("startEpisode:", call("agent.startEpisode", {"task": {"instruction": "Zeig mir die Artikel."}, "environment": {"environmentId": "fake", "envelopes": []}}))
    last = None
    for turn in range(6):
        started = time.monotonic()
        reply = call("agent.next", {"budget": {"stepsUsed":0,"maxSteps":30,"elapsedMs":0,"maxWallClockMs":300000,"tokensUsed":0}, **({"lastResult": last} if last else {})})
        envelope = reply.get("result", {}).get("envelope") or reply
        key = envelope.get("key") if isinstance(envelope, dict) else "?"
        decision = envelope.get("decision") if isinstance(envelope, dict) else None
        tokens = f"{decision.get('tokensPrompt', 0)}+{decision.get('tokensCompletion', 0)} in {decision.get('llmCalls', 0)} call(s)" if decision else "no decision"
        print(f"turn {turn}: {key} after {time.monotonic()-started:.1f}s  [{tokens}]  err={reply.get('error')}")
        if key == "screen.capture":
            last = {"status":"ok","payload":{"image":png,"format":"png;base64","width":1200,"height":800,"scale":1}}
        elif key == "semantics.tree":
            last = {"status":"ok","payload":{"tree":[{"id":1,"label":"Artikel","rect":{"left":10,"top":20,"width":100,"height":40}}]}}
        elif key and key.startswith("meta."):
            print("   payload:", json.dumps(envelope.get("payload"))[:300]); break
        else:
            last = {"status":"ok","payload":{}}
finally:
    proc.kill()
