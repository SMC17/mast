## Sample mast init.janet
##
## Copy this file to $XDG_CONFIG_HOME/mast/init.janet (default
## ~/.config/mast/init.janet). mast evaluates it on startup so anything
## you define here is available at the first M-x prompt.
##
## The evaluation happens in mast's live Janet env, so you have access
## to every Janet core function PLUS mast's bound C-functions:
##
##   (stax-pid)             → integer (host PID)
##   (stax-bash "cmd")      → integer (exit status of shelling out)
##   (buffer-name)          → string or nil
##   (buffer-size)          → integer

# Simple verbs callable as `M-x (hello "world")`
(def hello (fn [name] (string "hello, " name)))
(def square (fn [x] (* x x)))

# Shell out to common stax-* CLIs without typing the whole verb each time
(def stax-doctor    (fn [] (stax-bash "stax-doctor")))
(def stax-loop-once (fn [] (stax-bash "stax-loop --self --once --max-iters 1")))

# A trivial buffer-aware command — usable as `M-x (buffer-info)`
(def buffer-info
  (fn []
    (if (buffer-name)
      (string "buffer: " (buffer-name) ", " (buffer-size) " bytes")
      "no buffer open")))
