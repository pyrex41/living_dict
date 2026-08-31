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

(define check-contract-parse
  -> (report "contract-parse"
             (both (= (parse-contract "key path -- receipt | read, write")
                      [ok 2 1 ["read" "write"]])
                   (both (= (parse-contract " -- ") [ok 0 0 []])
                         (both (= (hd (parse-contract "no dashes")) bad)
                               (both (= (hd (parse-contract "a -- b -- c")) bad)
                                     (both (= (hd (parse-contract "a -- b |")) bad)
                                           (= (hd (parse-contract "a -- | fly")) bad))))))))

(define check-colon-declared
  -> (let Prog (cn ": INSTALL ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ; "
                   (cn (s-lit "app/config.py") " INSTALL"))
       (let R (validate Prog ["read" "write" "exec"]
                        ["app/config.py"] [] ["app/config.py"])
         (report "colon-declared-accept" (= (hd R) accept)))))

(define check-colon-mismatch
  -> (let R (validate ": INSTALL ( a b -- | write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;"
                      ["read" "write" "exec"] ["**"] [] ["app/config.py"])
       (let J (join-space (hd (tl R)))
         (report "colon-contract-mismatch"
                 (and (= (hd R) reject)
                      (and (contains-sub? J "contract mismatch for INSTALL")
                           (and (contains-sub? J "declared ( 2 -- 0 | write )")
                                (contains-sub? J "computed ( 1 -- 0 | read, write )"))))))))

(define check-colon-call-underflow
  -> (let R (validate ": INSTALL ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ; INSTALL"
                      ["read" "write" "exec"] ["**"] [] ["app/config.py"])
       (report "colon-call-underflow"
               (and (= (hd R) reject)
                    (contains-sub? (join-space (hd (tl R)))
                                   "stack underflow at INSTALL")))))

(define check-colon-recursion
  -> (let R (validate ": LOOPY ( -- ) LOOPY ;"
                      ["read" "write" "exec"] ["**"] [] [])
       (report "colon-recursion-reject"
               (and (= (hd R) reject)
                    (contains-sub? (join-space (hd (tl R)))
                                   "recursive colon definition LOOPY")))))

(define check-colon-invalid
  -> (let R (validate ": FOO ( no dashes here ) DROP ;"
                      ["read" "write" "exec"] ["**"] [] [])
       (report "colon-invalid-contract"
               (and (= (hd R) reject)
                    (contains-sub? (join-space (hd (tl R)))
                                   "invalid contract for FOO")))))

(define check-colon-inference
  -> (let A (validate ": TWICE DUP ; 5 TWICE DROP DROP"
                      ["read" "write" "exec"] ["**"] [] [])
       (let B (validate ": TWICE DUP ; TWICE"
                        ["read" "write" "exec"] ["**"] [] [])
         (report "colon-inference"
                 (and (= (hd A) accept)
                      (and (= (hd B) reject)
                           (contains-sub? (join-space (hd (tl B)))
                                          "stack underflow at TWICE")))))))

(define check-colon-body-path
  -> (let Prog (cn ": SNEAK ( -- | write ) "
                   (cn (s-lit "hello")
                       (cn " " (cn (s-lit "tests/test_public.py") " WRITE-FILE DROP ;"))))
       (let R (validate Prog ["read" "write" "exec"] ["app/**"] ["tests/**"] [])
         (report "colon-body-forbidden-path"
                 (and (= (hd R) reject)
                      (contains-sub? (join-space (hd (tl R)))
                                     "forbidden path: tests/test_public.py"))))))

(define check-comment-token
  -> (let Toks (tokenise-program "( a note ) RUN-GATES")
       (let R (validate "( just a note ) RUN-GATES DROP"
                        ["read" "write" "exec"] ["**"] [] [])
         (report "comment-token-inert"
                 (and (= (tok-kind (hd Toks)) "comment")
                      (and (= (tok-value (hd Toks)) " a note ")
                           (= (hd R) accept)))))))

(define check-validate-catalog
  -> (let Toks (tokenise-program "INSTALL RECEIPT")
       (let Catalog [["INSTALL" 2 0 ["read" "write"]]]
         (let R (validate-catalog Toks Catalog
                                  ["read" "write" "exec"] ["**"] [] [])
           (report "validate-catalog-starved"
                   (and (= (hd R) reject)
                        (contains-sub? (join-space (hd (tl R)))
                                       "stack underflow at INSTALL")))))))

(define all-pass
  [] -> true
  [true | Rest] -> (all-pass Rest)
  [_ | _] -> false)

(define run-critic-suite
  -> (let Results [(check-accept-straight)
                   (check-reject-bundle)
                   (check-missing-artifact)
                   (check-write-ok)
                   (check-tokenise)
                   (check-contract-parse)
                   (check-colon-declared)
                   (check-colon-mismatch)
                   (check-colon-call-underflow)
                   (check-colon-recursion)
                   (check-colon-invalid)
                   (check-colon-inference)
                   (check-colon-body-path)
                   (check-comment-token)
                   (check-validate-catalog)]
       (if (all-pass Results)
           (do (output "ALL PASS~%") true)
           (do (output "SOME FAIL~%") false))))

(run-critic-suite)
