#!/usr/bin/env python3
"""Claude -> Codex session transfer bridge.

Speaks JSON-RPC over `codex app-server` stdio to import a Claude Code
transcript (JSONL) as a persistent Codex thread.

Design points (from adversarial review round 4 + live probe):
- Codex only imports files it detects as real agent sessions (snapshot copies
  are rejected with failureStage=session_missing), so the LIVE transcript is
  imported. The TOCTOU race (a live session grows between our hash and
  codex's import-time hash) is closed on the lookup side instead: prefer the
  exact sha match, fall back to the NEWEST ledger record for the path, and
  log when the transcript changed mid-transfer.
- A SIGALRM deadline bounds the WHOLE exchange — a silent or partial-line
  app-server cannot hang the bridge on a blocking readline().
- SIGTERM/SIGINT are handled so the app-server child is terminated (then
  killed) instead of orphaned, and cleanup always waits on it.
- The import response's importId is correlated with the completion
  notification; itemTypeResults are surfaced as diagnostics on failure.
- app-server stderr is captured and its tail is printed on failure.

Usage: transfer-bridge.py <claude-jsonl> <cwd> <outfile>
  stderr: progress + a `session id: <thread-id>` line the wrapper parses
  outfile: the final message (thread id + resume instructions)

Exit codes: 0 imported, 1 failure (reason on stderr), 2 usage.
Protocol per openai/codex-plugin-cc (Apache-2.0) and codex-rs app-server.
"""
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def is_thread_id(value):
    # fullmatch: re $ would accept a trailing newline, letting a malformed
    # target bypass the ledger fallback as a false success
    return isinstance(value, str) and bool(UUID_RE.fullmatch(value))


def log(msg):
    print(msg, file=sys.stderr)


def main() -> int:
    if len(sys.argv) != 4:
        log("usage: transfer-bridge.py <claude-jsonl> <cwd> <outfile>")
        return 2
    orig = os.path.realpath(sys.argv[1])
    cwd = sys.argv[2]
    outfile = sys.argv[3]
    codex_bin = os.environ.get("CODEX_BIN", "codex")
    codex_home = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
    try:
        timeout = float(os.environ.get("CODEX_TRANSFER_TIMEOUT", "180"))
    except ValueError:
        timeout = 180.0
    if not (0 < timeout < 86400):  # also rejects nan/inf
        timeout = 180.0

    def on_alarm(_sig, _frame):
        raise RuntimeError(
            "timed out waiting for codex app-server (CODEX_TRANSFER_TIMEOUT=%ds)" % int(timeout)
        )

    def on_term(sig, _frame):
        raise RuntimeError("interrupted by signal %d" % sig)

    signal.signal(signal.SIGALRM, on_alarm)
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    signal.alarm(max(1, int(timeout)))

    proc = None
    errfile = None
    try:
        # Hash the live transcript just before importing; the ledger lookup
        # below prefers this hash and falls back to the newest record for the
        # path if the session grew while codex was importing.
        with open(orig, "rb") as f:
            sha = hashlib.sha256(f.read()).hexdigest()
        log("hashed transcript (%d bytes)" % os.path.getsize(orig))

        errfile = tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace")
        try:
            proc = subprocess.Popen(
                [codex_bin, "app-server"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=errfile,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
        except OSError as exc:
            raise RuntimeError("cannot start '%s app-server': %s" % (codex_bin, exc))

        def send(obj):
            proc.stdin.write(json.dumps(obj) + "\n")
            proc.stdin.flush()

        def read_msg():
            # SIGALRM bounds the blocking readline; non-JSON banner lines skipped
            while True:
                line = proc.stdout.readline()
                if not line:
                    raise RuntimeError("codex app-server closed the connection unexpectedly")
                line = line.strip()
                if not line:
                    continue
                try:
                    return json.loads(line)
                except ValueError:
                    continue

        log("initializing codex app-server")
        send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "clientInfo": {"title": "codex.sh transfer", "name": "Claude Code", "version": "1.0.0"},
                "capabilities": {
                    "experimentalApi": False,
                    "requestAttestation": False,
                    "optOutNotificationMethods": [
                        "item/agentMessage/delta",
                        "item/reasoning/summaryTextDelta",
                        "item/reasoning/summaryPartAdded",
                        "item/reasoning/textDelta",
                    ],
                },
            },
        })
        while True:
            m = read_msg()
            if m.get("id") == 1:
                if "error" in m:
                    raise RuntimeError("initialize failed: %s" % m["error"])
                break
        send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

        log("importing Claude session into Codex")
        send({
            "jsonrpc": "2.0", "id": 2, "method": "externalAgentConfig/import",
            "params": {
                "migrationItems": [{
                    "itemType": "SESSIONS",
                    "description": "Transfer Claude session %s" % os.path.basename(orig),
                    "cwd": None,
                    "details": {
                        "plugins": [],
                        "sessions": [{"path": orig, "cwd": cwd, "title": None}],
                        "mcpServers": [],
                        "hooks": [],
                        "subagents": [],
                        "commands": [],
                    },
                }],
            },
        })
        import_id = None
        got_response = False
        completed_params = None
        while not (got_response and completed_params is not None):
            m = read_msg()
            if m.get("id") == 2:
                if "error" in m:
                    err = m["error"]
                    if err.get("code") == -32601:
                        raise RuntimeError(
                            "this codex CLI does not support Claude session transfer "
                            "(externalAgentConfig/import missing) — npm install -g @openai/codex@latest"
                        )
                    raise RuntimeError("import failed: %s" % err)
                result = m.get("result")
                if isinstance(result, dict):
                    import_id = result.get("importId")
                got_response = True
            elif m.get("method") == "externalAgentConfig/import/completed":
                params = m.get("params") or {}
                notified_id = params.get("importId")
                # Correlate when both sides carry an id; accept otherwise
                if import_id is None or notified_id is None or notified_id == import_id:
                    completed_params = params

        # An explicit per-item failure beats any ledger evidence — a stale
        # record for the same path must never mask a failed import.
        results = (completed_params or {}).get("itemTypeResults")
        if isinstance(results, list):
            for r in results:
                if isinstance(r, dict) and (r.get("failed") or r.get("failures")):
                    raise RuntimeError(
                        "codex reported import failures. itemTypeResults: %s"
                        % json.dumps(results)[:600]
                    )

        # Authoritative success signal (codex 0.144.1): THIS import's thread id
        # in itemTypeResults[].successes[].target — immune to stale ledger
        # records for the same path and to concurrent imports.
        thread_id = None
        if isinstance(results, list):
            for r in results:
                if not isinstance(r, dict):
                    continue
                for s in (r.get("successes") or []):
                    if not isinstance(s, dict):
                        continue
                    t = s.get("target") or s.get("threadId") or s.get("thread_id")
                    if isinstance(t, dict):
                        t = t.get("threadId") or t.get("id")
                    if is_thread_id(t):
                        thread_id = t
                    elif t:
                        log("ignoring malformed import target: %r" % (t,))
        if thread_id:
            log("thread id resolved from itemTypeResults target")

        # Fallback (older protocol shapes): the ledger. Prefer the exact
        # content hash; if the live session grew during the import the hash
        # won't match — fall back to the newest record for the path.
        ledger_path = os.path.join(codex_home, "external_agent_session_imports.json")
        newest_for_path = None
        if not thread_id:
            ledger = None
            for _attempt in range(2):  # tolerate a concurrent partial write
                try:
                    with open(ledger_path, encoding="utf-8") as f:
                        ledger = json.load(f)
                    break
                except ValueError:
                    time.sleep(0.2)
                except OSError:
                    break
            for rec in ((ledger or {}).get("records") or []):
                if not isinstance(rec, dict):
                    continue
                if rec.get("source_path") != orig:
                    continue
                if not is_thread_id(rec.get("imported_thread_id")):
                    continue
                newest_for_path = rec["imported_thread_id"]
                if rec.get("content_sha256") == sha:
                    thread_id = rec["imported_thread_id"]
        race_note = ""
        if not thread_id and newest_for_path:
            race_note = (
                "\n(note: the transcript changed while codex imported it — live session;"
                " resolved the newest imported thread for this path.)\n"
            )
            log("note: transcript changed while codex imported it (live session) — using the newest imported thread for this path")
            thread_id = newest_for_path
        if not thread_id:
            detail = ""
            if completed_params:
                detail = " itemTypeResults: %s" % json.dumps(
                    completed_params.get("itemTypeResults")
                )[:500]
            raise RuntimeError(
                "import reported complete but no imported thread was recorded in %s.%s"
                % (ledger_path, detail)
            )

        log("session id: %s" % thread_id)
        with open(outfile, "w", encoding="utf-8") as f:
            f.write(
                "Imported Claude session %s into Codex thread %s.\n"
                "(The thread keeps the working directory recorded in the transcript.)\n%s\n"
                "Continue it:\n"
                "- Codex TUI:  codex resume %s\n"
                "- wrapper:    codex.sh resume --session %s \"<follow-up>\"\n"
                % (os.path.basename(orig), thread_id, race_note, thread_id, thread_id)
            )
        return 0
    except Exception as exc:  # surfaced via wrapper stderr tail
        log("ERROR: %s" % exc)
        if errfile is not None:
            try:
                errfile.seek(0)
                tail = errfile.read()[-2000:]
                if tail.strip():
                    log("[app-server stderr tail]")
                    log(tail)
            except OSError:
                pass
        return 1
    finally:
        signal.alarm(0)
        if proc is not None:
            try:
                proc.stdin.close()
            except OSError:
                pass
            # Shorter than the wrapper's 5s TERM→KILL escalation window so a
            # TERM-ignoring app-server is KILLed here before the wrapper can
            # KILL this bridge mid-cleanup (which would orphan the server)
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass


if __name__ == "__main__":
    sys.exit(main())
