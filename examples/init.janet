## Sample mast init.janet
##
## Copy this file to $XDG_CONFIG_HOME/mast/init.janet (default
## ~/.config/mast/init.janet). mast evaluates it on startup so anything
## you define here is available at the first M-x prompt.
##
## The evaluation happens in mast's live Janet env, so you have access
## to every Janet core function PLUS mast's bound C-functions:
##
##   (stax-pid)              → integer (host PID)
##   (stax-bash "cmd")       → integer (exit status of shelling out)
##   (buffer-name)           → string or nil
##   (buffer-size)           → integer
##   (buffer-count)          → integer
##   (buffer-current-index)  → integer
##   (buffer-next)           → integer (new index)
##   (buffer-prev)           → integer (new index)
##   (buffer-switch idx)     → integer (new index, or -1 on range error)
##   (agent/run cmd)         → integer (new :agent buffer index, sync)
##   (agent/spawn cmd)       → integer (handle id; output streams to :agent buffer via poll)
##   (agent/poll handle)     → integer exit-status or nil if running
##   (agent/wait handle)     → integer exit-status (blocking)
##   (agent/count)           → integer
##   (agent/alive? handle)   → boolean
##   (agent/kill handle)     → boolean

# ─── Section 1: simple utility verbs ───────────────────────────────────
#
# These are the smallest possible demonstrations. (hello "world")
# returns "hello, world" — the doctest harness pins this exact form.

(def hello (fn [name] (string "hello, " name)))
(def square (fn [x] (* x x)))

# ─── Section 2: stax-fleet bridges ─────────────────────────────────────
#
# Compose mast with the existing local CLI fleet. Each requires the
# `exec` capability (auto-granted under v1 host policy; suppressed
# under MAST_SANDBOX_STRICT=1).

(def stax-doctor    (fn [] (stax-bash "stax-doctor")))
(def stax-loop-once (fn [] (stax-bash "stax-loop --self --once --max-iters 1")))
(def fleet-dashboard (fn [] (stax-bash "stax-dashboard --top 8 2>/dev/null || echo '(stax-dashboard not on PATH)'")))

# ─── Section 3: buffer introspection ───────────────────────────────────

(def buffer-info
  (fn []
    (if (buffer-name)
      (string "buffer: " (buffer-name) ", " (buffer-size) " bytes")
      "no buffer open")))

(def ring-summary
  (fn []
    (string "buffer ring: " (buffer-count) " buffers, current index = " (buffer-current-index))))

# ─── Section 4: agent-as-buffer demos (v1.3.0) ─────────────────────────
#
# Each spawn creates a new :agent buffer attached to the spawned cmd's
# stdout (and stderr — both are redirected to the pipe). The buffer
# enters the multi-buffer ring; switch to it via M-x switch-buffer N
# or by binding a verb here.

(def quick-uptime    (fn [] (agent/run "uptime")))
(def list-tmp        (fn [] (agent/run "ls -la /tmp | head -20")))
(def git-status      (fn [] (agent/run "git status -s 2>&1 | head -20")))

# Async demo: spawn three parallel agents, wait for all, return total
# bytes captured across all three buffers. The kind of pattern the
# steipete-thesis "background fleet" workflow uses.
(def parallel-three
  (fn [cmd-a cmd-b cmd-c]
    (let [h1 (agent/spawn cmd-a)
          h2 (agent/spawn cmd-b)
          h3 (agent/spawn cmd-c)]
      (agent/wait h1)
      (agent/wait h2)
      (agent/wait h3)
      (string "three agents complete: " (agent/count) " total handles"))))

# ─── Section 5: sandbox-posture probes ─────────────────────────────────
#
# Every removed binding panics. Wrap the call in (try ...) so the user
# script can inspect the panic message without crashing. These verbs
# are the load-bearing G1 evidence — proving the G2 closure is observable
# end-to-end from a user-script context.

(def probe-removed
  (fn [thunk]
    (try (do (thunk) "REMOVED-BINDING-LEAK")
         ([err] (string "sandbox OK — " err)))))

(def sandbox-audit-mini
  (fn []
    (string
      "exec-removed:    " (probe-removed (fn [] (os/execute ["true"] :p))) "\n"
      "fileio-removed:  " (probe-removed (fn [] (slurp "/etc/hostname"))) "\n"
      "net-removed:     " (probe-removed (fn [] (net/connect "127.0.0.1" "1"))) "\n"
      "unmarshal-removed: " (probe-removed (fn [] (unmarshal @"x"))) "\n"
      "exit-removed:    " (probe-removed (fn [] (os/exit 0))) "\n"
      "env-removed:     " (probe-removed (fn [] (os/getenv "HOME"))))))

# ─── Section 6: composite verbs ────────────────────────────────────────
#
# These string together the above into "morning-brief"-style verbs you
# can run in one keystroke.

(def session-brief
  (fn []
    (string
      "── mast session ──\n"
      "pid:      " (stax-pid) "\n"
      "buffers:  " (ring-summary) "\n"
      "buffer:   " (buffer-info) "\n"
      "agents:   " (agent/count) " handles\n"
      "(M-x (fleet-dashboard) for cluster view; M-x (sandbox-audit-mini) for sandbox)")))
