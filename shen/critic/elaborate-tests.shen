\\ Bifrost fixture body. Packed after elaborate.shen into elaborate-suite.shen.
\\ No load / eval / tc. Prints ALL PASS iff every check holds.
\\ The manifest below is examples/orders/ld-system.json flattened the way
\\ beam/lib/ld_host/elaborate.ex `shen_request` flattens it.

(define el-report
  Label true -> (do (output (make-string "ok  ~A~%" Label)) true)
  Label false -> (do (output (make-string "FAIL ~A~%" Label)) false))

(define el-orders
  -> [["build_reproducibility" ["unpinned" "pinned" "attested"]]
      ["clock" ["ambient" "recorded" "logical"]]
      ["entropy" ["ambient" "ambient-seeded" "seeded-replayable"]]
      ["external_effects" ["ambient" "recorded" "durable-intent-commit"]]
      ["floating_point" ["platform" "canonical"]]
      ["global_checkpoint" ["unsupported" "supported"]]
      ["replay" ["none" "rerun-only" "in-process" "cross-process"]]
      ["snapshot" ["none" "guest-declared" "component" "whole-machine"]]])

(define el-profiles
  -> [["wasm-durable-v1" true
       [["build_reproducibility" "pinned"] ["clock" "logical"]
        ["entropy" "seeded-replayable"] ["external_effects" "durable-intent-commit"]
        ["floating_point" "canonical"] ["global_checkpoint" "unsupported"]
        ["replay" "cross-process"] ["snapshot" "component"]]
       ["crash"]]
      ["unikraft-confined-transducer-experimental" false
       [["build_reproducibility" "unpinned"] ["clock" "ambient"]
        ["entropy" "ambient-seeded"] ["external_effects" "ambient"]
        ["floating_point" "platform"] ["global_checkpoint" "unsupported"]
        ["replay" "rerun-only"] ["snapshot" "none"]]
       []]])

(define el-components
  PaymentSub WorkerCmdType ->
    [["api" "order-api/v1" "wasm-durable-v1"
      [["commands" "out" "order-command/v1"]]
      [["clock" "logical"] ["entropy" "seeded-replayable"] ["snapshot" "component"]
       ["replay" "cross-process"] ["floating_point" "canonical"]]]
     ["worker" "order-worker/v1" "wasm-durable-v1"
      [["commands" "in" WorkerCmdType] ["charges" "out" "charge-request/v1"]]
      [["clock" "logical"] ["entropy" "seeded-replayable"] ["snapshot" "component"]
       ["replay" "cross-process"] ["fault_controls" "crash"]]]
     ["payment" "payment-broker/v1" PaymentSub
      [["charges" "in" "charge-request/v1"]]
      [["external_effects" "durable-intent-commit"] ["snapshot" "component"]
       ["replay" "cross-process"]]]])

(define el-channels
  -> [["order-commands" "api.commands" "worker.commands" "at-least-once" "per-key"]
      ["charge-requests" "worker.charges" "payment.charges" "at-least-once" "per-key"]])

(define el-effects
  -> [["charge-card" "payment" "durable-intent-commit" "host-derived" "card-provider"]])

(define el-invariants
  -> [["no-double-charge" "safety" ["charge-card"]]
      ["committed-order-has-payment" "safety" ["worker" "payment"]]
      ["terminal-orders-never-regress" "safety" ["worker"]]
      ["only-payment-reaches-card-provider" "forbidden-path" ["api" "card-provider"]]
      ["accepted-orders-settle" "liveness" ["order-commands" "charge-requests"]]])

(define el-failures
  -> ["crash-before-effect" "crash-after-effect" "crash-after-commit"
      "message-duplicate" "message-reorder" "partition" "heal"])

(define el-run
  PaymentSub WorkerCmdType ->
    (elaborate "orders" (el-components PaymentSub WorkerCmdType) (el-channels)
               (el-effects) ["card-provider"] (el-invariants) (el-failures)
               (el-profiles) (el-orders)))

(define check-accepted
  -> (let R (el-run "wasm-durable-v1" "order-command/v1")
       (let Obls (hd (tl (tl (tl R))))
         (el-report "orders-accepted"
                    (and (= (hd R) accepted)
                         (and (element? "runtime:effects-exactly-once:charge-card" Obls)
                              (and (element? "netkat:isolated:api->card-provider" Obls)
                                   (and (element? "tla:delivery-at-least-once:order-commands" Obls)
                                        (= (hd Obls) "runtime:replay-stable:api")))))))))

(define check-deterministic
  -> (el-report "derivation-deterministic"
                (= (el-run "wasm-durable-v1" "order-command/v1")
                   (el-run "wasm-durable-v1" "order-command/v1"))))

(define check-experimental-rejected
  -> (let R (el-run "unikraft-confined-transducer-experimental" "order-command/v1")
       (let Failed (hd (tl (tl R)))
         (el-report "payment-on-experimental-rejected-on-external-effects"
                    (and (= (hd R) rejected)
                         (and (element? "substrate-satisfies:payment.external_effects" Failed)
                              (and (element? "effect-owner:charge-card" Failed)
                                   (and (element? "substrate-admissible:payment" Failed)
                                        (= (hd (tl (tl (tl R)))) [])))))))))

(define check-type-mismatch
  -> (let R (el-run "wasm-durable-v1" "something-else/v1")
       (el-report "channel-type-mismatch-rejected"
                  (and (= (hd R) rejected)
                       (= (hd (tl (tl R))) ["channel-endpoints:order-commands"])))))

(define check-unknown-profile
  -> (let R (elaborate "x"
                       [["a" "c/v1" "nowhere-v9" [] [["clock" "logical"]]]]
                       [] [] [] [] [] (el-profiles) (el-orders))
       (el-report "unknown-substrate-rejected-by-every-rule-that-sees-it"
                  (and (= (hd R) rejected)
                       (= (hd (tl (tl R)))
                          ["component-well-formed:a" "substrate-satisfies:a.profile"
                           "substrate-admissible:a"])))))

(define check-unmet-dimension-detail
  -> (let R (elaborate "x"
                       [["a" "c/v1" "wasm-durable-v1" []
                         [["global_checkpoint" "supported"] ["made-up" "x"] ["fault_controls" "crash,drop"]]]]
                       [] [] [] [] [] (el-profiles) (el-orders))
       (el-report "unmet-dimensions-each-named"
                  (= (hd (tl (tl R)))
                     ["substrate-satisfies:a.fault_controls"
                      "substrate-satisfies:a.global_checkpoint"
                      "substrate-satisfies:a.unknown"]))))

(define run-all
  -> (let A (check-accepted)
       (let B (check-deterministic)
         (let C (check-experimental-rejected)
           (let D (check-type-mismatch)
             (let E (check-unknown-profile)
               (let F (check-unmet-dimension-detail)
                 (if (and A (and B (and C (and D (and E F)))))
                     (do (output "ALL PASS~%") true)
                     (do (output "SUITE FAILED~%") false)))))))))

(run-all)
