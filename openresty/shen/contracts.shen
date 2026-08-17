\\ Living Dictionary capability contracts.
\\ Portable typed core for shen-lua / ShenScript. No lua.call.
\\ The Forth body remains the only executor. preflight.shen calls these
\\ functions from named validate (Accept | Reject).
\\
\\ Stack effects are documentary:
\\   read-file     ( path -- content )
\\   list-dir      ( path -- listing )
\\   search        ( query -- hits )
\\   write-file    ( content path -- receipt )
\\   run-tests     ( -- test-receipt )
\\   receipt       ( -- receipt )
\\   use-artifact  ( path -- content )
\\
\\ write-ok? uses POSIX fnmatch (* matches any string, including /),
\\ matching Python fnmatch.fnmatch / livingdict.policy.

(define allowed-effect?
  {symbol --> boolean}
  read -> true
  write -> true
  exec -> true
  X -> false)

(define allowed-effect-name?
  {string --> boolean}
  "read" -> true
  "write" -> true
  "exec" -> true
  X -> false)

(define member-string?
  {string --> (list string) --> boolean}
  S [] -> false
  S [S | Rest] -> true
  S [_ | Rest] -> (member-string? S Rest))

(define stars-only?
  {string --> boolean}
  "" -> true
  Pattern -> (and (= (hdstr Pattern) "*") (stars-only? (tlstr Pattern))))

(define glob-match?
  {string --> string --> boolean}
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
  {string --> (list string) --> boolean}
  Path [] -> false
  Path [P | Ps] -> (or (glob-match? Path P) (matches-any? Path Ps)))

(define write-ok?
  {string --> (list string) --> (list string) --> boolean}
  Path Allowed Forbidden ->
    (and (matches-any? Path Allowed)
         (not (matches-any? Path Forbidden))))

(define write-deny-reason
  {string --> (list string) --> (list string) --> string}
  Rel Allowed Forbidden ->
    (if (matches-any? Rel Forbidden)
        (cn "forbidden path: " Rel)
        (if (write-ok? Rel Allowed Forbidden)
            ""
            (cn "path outside allowed change set: " Rel))))

(define contract-inputs
  {string --> number}
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
  {string --> number}
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
  {string --> (list string)}
  "READ-FILE" -> ["read"]
  "LIST-DIR" -> ["read"]
  "SEARCH" -> ["read"]
  "WRITE-FILE" -> ["write"]
  "RUN-TESTS" -> ["exec"]
  "RUN-GATES" -> ["exec"]
  "USE-ARTIFACT" -> ["read"]
  X -> [])

(define host-word?
  {string --> boolean}
  Name -> (not (= (contract-inputs Name) -1)))
