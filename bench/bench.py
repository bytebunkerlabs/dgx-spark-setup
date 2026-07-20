#!/usr/bin/env python3
"""bench.py - tiny, dependency-free load test for an OpenAI-compatible endpoint.

Measures throughput (output tokens/sec), latency (p50/p99), and time-to-first-token
under a fixed concurrency. Uses only the Python standard library, so it runs on the
DGX host with no pip installs. Works against ANY OpenAI-compatible server — the
TP cluster, the PP cluster, a single-node engine, or the LiteLLM gateway.

Example:
  python3 bench.py --url http://127.0.0.1:8000/v1 --model MODEL \
      --concurrency 8 --requests 32 --input-tokens 512 --output-tokens 128 \
      --label pp --csv results.csv
"""
import argparse, json, time, statistics, urllib.parse, http.client
from concurrent.futures import ThreadPoolExecutor

def one_request(base_url, api_key, model, prompt, out_tokens):
    u = urllib.parse.urlparse(base_url)
    Conn = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    conn = Conn(u.netloc, timeout=900)
    path = (u.path.rstrip("/")) + "/chat/completions"
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": out_tokens,
        "temperature": 0,
        "stream": True,
        "ignore_eos": True,          # vLLM: force full output length for stable throughput
    })
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    t0 = time.perf_counter()
    ttft = None
    toks = 0
    try:
        conn.request("POST", path, body=body, headers=headers)
        resp = conn.getresponse()
        if resp.status != 200:
            msg = resp.read()[:160].decode("utf-8", "ignore")
            return {"ok": False, "err": f"HTTP {resp.status}: {msg}"}
        while True:
            raw = resp.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            if ttft is None:
                ttft = time.perf_counter() - t0
            try:
                j = json.loads(data)
                ch = j["choices"][0]
                piece = ch.get("delta", {}).get("content") or ch.get("text") or ""
                if piece:
                    toks += 1            # ~1 streamed chunk == 1 token
            except Exception:
                pass
        return {"ok": True, "latency": time.perf_counter() - t0,
                "ttft": ttft if ttft is not None else 0.0, "tokens": toks}
    except Exception as e:
        return {"ok": False, "err": repr(e)}
    finally:
        conn.close()

def pct(xs, p):
    if not xs:
        return 0.0
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round((p / 100.0) * (len(xs) - 1)))))
    return xs[k]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="OpenAI base, e.g. http://127.0.0.1:8000/v1")
    ap.add_argument("--model", required=True)
    ap.add_argument("--api-key", default="")
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--requests", type=int, default=None, help="total requests (default: 4x concurrency)")
    ap.add_argument("--input-tokens", type=int, default=512)
    ap.add_argument("--output-tokens", type=int, default=128)
    ap.add_argument("--label", default="run")
    ap.add_argument("--csv", default="")
    a = ap.parse_args()

    total = a.requests if a.requests else a.concurrency * 4
    # ~1 word ≈ 1 token of filler; deterministic, model doesn't need to understand it.
    prompt = ("token " * a.input_tokens).strip()

    t_start = time.perf_counter()
    results = []
    with ThreadPoolExecutor(max_workers=a.concurrency) as ex:
        futs = [ex.submit(one_request, a.url, a.api_key, a.model, prompt, a.output_tokens)
                for _ in range(total)]
        for f in futs:
            results.append(f.result())
    wall = time.perf_counter() - t_start

    ok = [r for r in results if r.get("ok")]
    bad = [r for r in results if not r.get("ok")]
    out_tokens = sum(r["tokens"] for r in ok)
    thruput = out_tokens / wall if wall > 0 else 0.0
    lats = [r["latency"] for r in ok]
    ttfts = [r["ttft"] for r in ok]

    print(f"[{a.label}] conc={a.concurrency} in={a.input_tokens} out={a.output_tokens} "
          f"| thruput={thruput:7.1f} tok/s "
          f"| lat p50={pct(lats,50):5.2f}s p99={pct(lats,99):5.2f}s "
          f"| ttft={statistics.mean(ttfts) if ttfts else 0:5.2f}s "
          f"| ok={len(ok)}/{total}")
    if bad:
        print(f"    first error: {bad[0].get('err','?')[:160]}")

    if a.csv:
        import os
        new = not os.path.exists(a.csv)
        with open(a.csv, "a") as fh:
            if new:
                fh.write("label,concurrency,input_tokens,output_tokens,throughput_tok_s,"
                         "lat_p50_s,lat_p99_s,ttft_mean_s,ok,total\n")
            fh.write(f"{a.label},{a.concurrency},{a.input_tokens},{a.output_tokens},"
                     f"{thruput:.1f},{pct(lats,50):.3f},{pct(lats,99):.3f},"
                     f"{statistics.mean(ttfts) if ttfts else 0:.3f},{len(ok)},{total}\n")

    # exit non-zero if a majority failed — lets the sweep detect a boundary
    raise SystemExit(0 if len(ok) >= total / 2 else 2)

if __name__ == "__main__":
    main()
