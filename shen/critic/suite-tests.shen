\\ Bifrost fixture body. Packed after validate.shen into suite.shen.
\\ No load / eval / tc. Prints ALL PASS iff every check holds.

(define s-lit
  Path -> (cn "S" (cn (dq) (cn " " (cn Path (dq))))))

(define forth-write
  Path -> (cn (s-lit Path)
              (cn " USE-ARTIFACT " (cn (s-lit Path) " WRITE-FILE"))))

(define join-space
  [] -> ""
  [X] -> X
  [X | Xs] -> (cn X (cn " " (join-space Xs))))

(define contains-sub?
  Hay "" -> true
  "" Needle -> false
  Hay Needle -> (or (starts-with? Needle Hay)
                    (contains-sub? (tlstr Hay) Needle)))

(define report
  Label true -> (do (output (make-string "ok  ~A~%" Label)) true)
  Label false -> (do (output (make-string "FAIL ~A~%" Label)) false))

(define both
  A B -> (and A B))

(define check-accept-straight
  -> (let Prog (cn (forth-write "src/records.py") " RUN-TESTS RECEIPT")
       (let R (validate Prog
                        ["read" "write" "exec"]
                        ["src/records.py"]
                        []
                        ["src/records.py"])
         (report "accept-straight" (= (hd R) accept)))))

(define check-reject-bundle
  -> (let Prog (cn "DROP MYSTERY " (cn (s-lit "tests/test_public.py") " WRITE-FILE"))
       (let R (validate Prog
                        ["read" "write" "exec"]
                        ["app/config.py"]
                        ["tests/**"]
                        [])
         (let J (join-space (hd (tl R)))
           (report "reject-unknown-underflow-forbidden"
                   (and (= (hd R) reject)
                        (and (contains-sub? J "underflow")
                             (and (contains-sub? J "unknown word")
                                  (contains-sub? J "forbidden")))))))))

(define check-missing-artifact
  -> (let R (validate (cn (s-lit "app/config.py") " USE-ARTIFACT")
                      ["read" "write" "exec"]
                      ["**"]
                      []
                      [])
       (report "reject-missing-artifact"
               (and (= (hd R) reject)
                    (contains-sub? (join-space (hd (tl R))) "no artifact")))))

(define check-write-ok
  -> (report "write-ok"
             (and (not (write-ok? "tests/test_public.py"
                                  ["app/config.py"]
                                  ["tests/**"]))
                  (write-ok? "app/config.py"
                             ["app/config.py"]
                             ["tests/**"]))))

(define check-tokenise
  -> (let Toks (tokenise-program (cn (s-lit "hello world") " 5 WRITE-FILE"))
       (report "tokenise"
               (and (= (tok-kind (hd Toks)) "string")
                    (and (= (tok-value (hd Toks)) "hello world")
                         (and (= (tok-kind (hd (tl Toks))) "number")
                              (= (tok-value (hd (tl Toks))) 5)))))))

(define run-critic-suite
  -> (let A (check-accept-straight)
       (let B (check-reject-bundle)
         (let C (check-missing-artifact)
           (let D (check-write-ok)
             (let E (check-tokenise)
               (if (and A (and B (and C (and D E))))
                   (do (output "ALL PASS~%") true)
                   (do (output "SOME FAIL~%") false))))))))

(run-critic-suite)
