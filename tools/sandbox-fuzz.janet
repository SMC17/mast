# tools/sandbox-fuzz.janet
#
# Loaded as init.janet by tools/sandbox-fuzz.sh; defines `sandbox-fuzz`
# which the harness then triggers via `M-x (sandbox-fuzz)`.
#
# Round-3 fuzz harness against the post-applyDefaultDeny env.  Walks
# every binding in root-env, classifies, attempts to call each
# cfunction with no args, and prints one line per cfunction.
#
# Output lines (parsed by tools/sandbox-fuzz.sh):
#   MAST-HOST <sym>          — host-provided binding, expected
#   PANICKED-MAST <sym>      — mast.sandbox panic, expected for gates
#   PANICKED-ARITY <sym>     — Janet's own arg-validation fired
#   PANICKED-OTHER <sym> :: <err> — neither — flag for review
#   RETURNED <sym> = <result> — cfunction returned without panic;
#                                flag if symbol looks dangerous
#
# Closes round-2 adversarial-review-round2.md's "Round 3" prescription.

(defn sandbox-fuzz
  []
  (def all-syms (all-bindings root-env))
  (var cfunc-count 0)
  (var mast-host-count 0)
  (var returned-count 0)
  (var panic-mast-count 0)
  (var panic-arity-count 0)
  (var panic-other-count 0)

  (printf "ROUNDTHREE_FUZZ_BEGIN total-syms=%d\n" (length all-syms))

  (each sym all-syms
    (def entry (get root-env sym))
    (when (and (table? entry) (= :cfunction (type (get entry :value))))
      (set cfunc-count (+ cfunc-count 1))
      (def s (string sym))
      (def is-mast-host
        (or (= s "stax-pid")
            (= s "stax-bash")
            (string/has-prefix? "buffer-" s)
            (string/has-prefix? "agent/" s)))
      (cond
        is-mast-host
        (do
          (set mast-host-count (+ mast-host-count 1))
          (printf "MAST-HOST %s\n" s))

        (do
          (def cfn (get entry :value))
          (def [ok-or-err result]
            (try [true (cfn)] ([err] [false err])))
          (if ok-or-err
            (do
              (set returned-count (+ returned-count 1))
              (printf "RETURNED %s = %s\n" s (string result)))
            (do
              (def errstr (string result))
              (cond
                (string/find "mast.sandbox" errstr)
                (do (set panic-mast-count (+ panic-mast-count 1))
                    (printf "PANICKED-MAST %s\n" s))

                (or (string/find "arity mismatch" errstr)
                    (string/find "expected " errstr)
                    (string/find "bad slot" errstr))
                (do (set panic-arity-count (+ panic-arity-count 1))
                    (printf "PANICKED-ARITY %s\n" s))

                (do (set panic-other-count (+ panic-other-count 1))
                    (printf "PANICKED-OTHER %s :: %s\n" s errstr)))))))))

  (printf "ROUNDTHREE_FUZZ_END cfuncs=%d mast-host=%d returned=%d panicked-mast=%d panicked-arity=%d panicked-other=%d\n"
          cfunc-count mast-host-count returned-count panic-mast-count panic-arity-count panic-other-count))
