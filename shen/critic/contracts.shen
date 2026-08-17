\\ Living Dictionary capability contracts.
\\ Portable, eval-free. No lua.call, js.call, declare, or (tc +).
\\ write-ok? uses POSIX fnmatch (* matches any string, including /),
\\ matching Python fnmatch.fnmatch / livingdict.policy.

(define allowed-effect-name?
  "read" -> true
  "write" -> true
  "exec" -> true
  X -> false)

(define stars-only?
  "" -> true
  Pattern -> (and (= (hdstr Pattern) "*") (stars-only? (tlstr Pattern))))

(define glob-match?
  "" "" -> true
  Path "" -> false
  "" Pattern -> (stars-only? Pattern)
  Path Pattern ->
    (if (= (hdstr Pattern) "*")
        (or (glob-match? Path (tlstr Pattern))
            (glob-match? (tlstr Path) Pattern))
        (if (or (= (hdstr Pattern) "?") (= (hdstr Pattern) (hdstr Path)))
            (glob-match? (tlstr Path) (tlstr Pattern))
            false)))

(define matches-any?
  Path [] -> false
  Path [P | Ps] -> (or (glob-match? Path P) (matches-any? Path Ps)))

(define write-ok?
  Path Allowed Forbidden ->
    (and (matches-any? Path Allowed)
         (not (matches-any? Path Forbidden))))

(define write-deny-reason
  Rel Allowed Forbidden ->
    (if (matches-any? Rel Forbidden)
        (cn "forbidden path: " Rel)
        (if (write-ok? Rel Allowed Forbidden)
            ""
            (cn "path outside allowed change set: " Rel))))

(define contract-inputs
  "READ-FILE" -> 1
  "LIST-DIR" -> 1
  "SEARCH" -> 1
  "WRITE-FILE" -> 2
  "RUN-TESTS" -> 0
  "RUN-GATES" -> 0
  "RECEIPT" -> 0
  "USE-ARTIFACT" -> 1
  "DUP" -> 1
  "DROP" -> 1
  "SWAP" -> 2
  "OVER" -> 2
  "+" -> 2
  "-" -> 2
  "*" -> 2
  "IF" -> 1
  "ELSE" -> 0
  "THEN" -> 0
  X -> -1)

(define contract-outputs
  "READ-FILE" -> 1
  "LIST-DIR" -> 1
  "SEARCH" -> 1
  "WRITE-FILE" -> 1
  "RUN-TESTS" -> 1
  "RUN-GATES" -> 1
  "RECEIPT" -> 1
  "USE-ARTIFACT" -> 1
  "DUP" -> 2
  "DROP" -> 0
  "SWAP" -> 2
  "OVER" -> 3
  "+" -> 1
  "-" -> 1
  "*" -> 1
  "IF" -> 0
  "ELSE" -> 0
  "THEN" -> 0
  X -> 0)

(define contract-effect
  "READ-FILE" -> ["read"]
  "LIST-DIR" -> ["read"]
  "SEARCH" -> ["read"]
  "WRITE-FILE" -> ["write"]
  "RUN-TESTS" -> ["exec"]
  "RUN-GATES" -> ["exec"]
  "USE-ARTIFACT" -> ["read"]
  X -> [])

(define host-word?
  Name -> (not (= (contract-inputs Name) -1)))
