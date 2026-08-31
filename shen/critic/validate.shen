\\ forth-shen critic. Named validate: Accept | Reject.
\\ Portable, eval-free. No lua.call, js.call, runtime (tc +), eval, or load.
\\ Fully typed: this file typechecks under `yggdrasil check` (loaded with
\\ (tc +) at build time); the datatypes below are the rigid specification
\\ of the critic's data shapes. Types are erased in the shake — the built
\\ artifacts are identical in behavior to the untyped critic.
\\ Tokenise is portable Shen (tokenise.shen) or the host passes tokens.
\\ Colon bodies are CHECKED: the first paren group after the name is the
\\ word's contract — ( ins -- outs | effects ) — and the body is abstractly
\\ interpreted against the current word table; a declared contract must
\\ match the computed one exactly, an absent contract is inferred, and the
\\ word is bound with its real (in out effects) triple so call sites are
\\ checked pre-I/O. Recursion is rejected (definition-before-use, single
\\ pass). Leftover depth is still not a reject.
\\
\\ This file is the shake entry: ratatoskr build shen/critic/validate.shen …
\\ It is self-contained (contracts + tokenise + validate) so a single PROG
\\ does not need runtime load (load would flip needs-eval).
\\
\\ TODO Stage-1 graph rules (Python livingdict.preflight already enforces;
\\ implement here before claiming Shen parity — do not ship a weaker Accept):
\\ 1. duplicate node ids → Reject "duplicate node id: <id>"
\\ 2. unknown depends_on → Reject "unknown depends_on: <node> -> <dep>"
\\ 3. dependency cycles → Reject "dependency cycle: a -> b -> a" (report the cycle)
\\ 4. a node program WRITE-FILE path outside that node's writes, narrowed to
\\    intersection(request.allowed_globs, node.writes|allowed_globs) with the
\\    same PathPolicy / forbidden globs → Reject as today, prefixed "node <id>:"
\\ 5. two nodes with overlapping write sets unless one depends transitively
\\    on the other → Reject "overlapping independent writes: <a> <b>"
\\ 6. when nodes are present, every artifact key must be covered by some
\\    node's writes → Reject "uncovered artifact: <key>"
\\ 7. existing stack / effect / glob / missing-artifact checks run per node
\\    program (and still on the composed program)
\\ 8. when task_graph.json is present AND envelope has nodes: if an envelope
\\    node's writes intersect a task-graph node's writes, then for each of
\\    that task-graph node's depends_on the envelope must schedule the
\\    covering writes strictly before it → Reject "graph order: envelope
\\    node <id> must follow task-graph dependency <dep>" naming both nodes
\\ Absent nodes: today's program-only validate. No new Forth words.

\\ ---------------------------- typed spec --------------------------------
\\ Datatypes for the heterogeneous fixed-shape lists this critic passes
\\ around. Bidirectional (====) rules are needed wherever a shape is
\\ deconstructed by pattern matching; one-way (____) rules suffice for
\\ construct-only shapes. Deconstruction is via the small pattern-matching
\\ accessors defined next to each consumer (hd/tl chains do not typecheck
\\ against these shapes); the runtime representation is unchanged.

\\ token: [Kind Value Idx]. Kind is "word" | "string" | "number" |
\\ "comment"; Value is a string except for "number" tokens (second rule).
\\ tok-value is typed string — honest at every call site, because number
\\ token values are never read (number tokens only bump the abstract
\\ depth); the number rule exists so the tokeniser can build them.
(datatype token
  Kind : string; Value : string; Idx : number;
  ============================================
  [Kind Value Idx] : token;

  Kind : string; Value : number; Idx : number;
  ____________________________________________
  [Kind Value Idx] : token;)

\\ take-paren-h / take-word-h result: [Captured Rest]. (hd/tl are not
\\ type-secure in this kernel, so even homogeneous fixed-shape pairs get a
\\ datatype plus pattern accessors.)
(datatype strpair
  A : string; B : string;
  =======================
  [A B] : strpair;)

\\ take-string-h result: [bad] | [ok Captured Rest].
(datatype strtake
  ________________
  [bad] : strtake;

  Str : string; Rest : string;
  ============================
  [ok Str Rest] : strtake;)

\\ parse-contract result: [ok In Out SortedEffects] | [bad Reason].
(datatype cparse
  In : number; Out : number; Effs : (list string);
  ================================================
  [ok In Out Effs] : cparse;

  Reason : string;
  =====================
  [bad Reason] : cparse;)

\\ word-table row: [Name In Out Effects].
(datatype wordrow
  Name : string; In : number; Out : number; Eff : (list string);
  ==============================================================
  [Name In Out Eff] : wordrow;)

\\ word-contract lookup result: [] (unknown word) | [In Out Effects].
(datatype wtriple
  ________________
  [] : wtriple;

  In : number; Out : number; Eff : (list string);
  ===============================================
  [In Out Eff] : wtriple;)

\\ declared-contract state while walking a colon body:
\\ none | [declared In Out Effects].
(datatype decl
  _____________
  none : decl;

  In : number; Out : number; Effs : (list string);
  ================================================
  [declared In Out Effs] : decl;)

\\ check-colon result: [NextIndex Name In Out Effects Errors]; Name "" when
\\ the definition is unusable (no binding).
(datatype colres
  NI : number; Name : string; In : number; Out : number;
  Effs : (list string); Errors : (list string);
  ======================================================
  [NI Name In Out Effs Errors] : colres;)

\\ walk result: [Errors Depth Effects].
(datatype wres
  Errors : (list string); Depth : number; Effs : (list string);
  =============================================================
  [Errors Depth Effs] : wres;)

\\ workspace-rel result: [ok Rel] | [bad Message].
(datatype relres
  Rel : string;
  ===================
  [ok Rel] : relres;

  Msg : string;
  =====================
  [bad Msg] : relres;)

\\ validate result: [accept Depth Effects] | [reject Errors Depth Effects].
\\ Construct-only here; hosts (and the untyped suite fixture) deconstruct.
(datatype verdict
  Depth : number; Effs : (list string);
  _____________________________________
  [accept Depth Effs] : verdict;

  Errors : (list string); Depth : number; Effs : (list string);
  _____________________________________________________________
  [reject Errors Depth Effs] : verdict;)

\\ ------------------------------------------------------------------------

(define allowed-effect-name?
  { string --> boolean }
  "read" -> true
  "write" -> true
  "exec" -> true
  X -> false)

(define stars-only?
  { string --> boolean }
  "" -> true
  Pattern -> (and (= (hdstr Pattern) "*") (stars-only? (tlstr Pattern))))

(define glob-match?
  { string --> string --> boolean }
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
  { string --> (list string) --> boolean }
  Path [] -> false
  Path [P | Ps] -> (or (glob-match? Path P) (matches-any? Path Ps)))

(define write-ok?
  { string --> (list string) --> (list string) --> boolean }
  Path Allowed Forbidden ->
    (and (matches-any? Path Allowed)
         (not (matches-any? Path Forbidden))))

(define write-deny-reason
  { string --> (list string) --> (list string) --> string }
  Rel Allowed Forbidden ->
    (if (matches-any? Rel Forbidden)
        (cn "forbidden path: " Rel)
        (if (write-ok? Rel Allowed Forbidden)
            ""
            (cn "path outside allowed change set: " Rel))))

(define contract-inputs
  { string --> number }
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
  { string --> number }
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
  { string --> (list string) }
  "READ-FILE" -> ["read"]
  "LIST-DIR" -> ["read"]
  "SEARCH" -> ["read"]
  "WRITE-FILE" -> ["write"]
  "RUN-TESTS" -> ["exec"]
  "RUN-GATES" -> ["exec"]
  "USE-ARTIFACT" -> ["read"]
  X -> [])

(define host-word?
  { string --> boolean }
  Name -> (not (= (contract-inputs Name) -1)))

(define ch-code
  { string --> number }
  C -> (string->n C))

(define ws-code?
  { number --> boolean }
  N -> (or (= N 32)
           (or (= N 9)
               (or (= N 10)
                   (or (= N 13)
                       (or (= N 12) (= N 11)))))))

(define ws?
  { string --> boolean }
  C -> (ws-code? (ch-code C)))

(define dq
  { --> string }
  -> (n->string 34))

(define bslash
  { --> string }
  -> (n->string 92))

(define nlch
  { --> string }
  -> (n->string 10))

(define is-digit?
  { string --> boolean }
  C -> (let N (ch-code C)
         (and (>= N 48) (<= N 57))))

(define all-digits?
  { string --> boolean }
  "" -> true
  S -> (and (is-digit? (hdstr S)) (all-digits? (tlstr S))))

(define number-token?
  { string --> boolean }
  "" -> false
  "+" -> false
  "-" -> false
  S -> (if (= (hdstr S) "-")
           (and (not (= (tlstr S) "")) (all-digits? (tlstr S)))
           (all-digits? S)))

(define parse-nat
  { string --> number --> number }
  "" Acc -> Acc
  S Acc -> (parse-nat (tlstr S) (+ (* Acc 10) (- (ch-code (hdstr S)) 48))))

(define parse-int
  { string --> number }
  S -> (if (= (hdstr S) "-")
           (- 0 (parse-nat (tlstr S) 0))
           (parse-nat S 0)))

(define skip-line
  { string --> string }
  "" -> ""
  S -> (if (= (hdstr S) (nlch)) S (skip-line (tlstr S))))

\\ Paren groups are captured as comment tokens (the critic needs to SEE
\\ contract groups; runtime Forth VMs keep discarding them). Unterminated
\\ groups run to end-of-source, mirroring the old skip-paren.
(define take-paren-h
  { string --> string --> strpair }
  "" Acc -> [Acc ""]
  S Acc -> (if (= (hdstr S) ")")
               [Acc (tlstr S)]
               (take-paren-h (tlstr S) (cn Acc (hdstr S)))))

\\ strpair accessors (was hd / (hd (tl _))).
(define spair-fst
  { strpair --> string }
  [A _] -> A)

(define spair-snd
  { strpair --> string }
  [_ B] -> B)

(define s-quote?
  { string --> boolean }
  S -> (and (not (= S ""))
            (and (not (= (tlstr S) ""))
                 (and (or (= (hdstr S) "S") (= (hdstr S) "s"))
                      (= (hdstr (tlstr S)) (dq))))))

(define after-s-quote
  { string --> string }
  S -> (let Rest (tlstr (tlstr S))
         (if (and (not (= Rest "")) (= (hdstr Rest) " "))
             (tlstr Rest)
             Rest)))

(define take-string-h
  { string --> string --> strtake }
  "" Acc -> [bad]
  S Acc -> (if (= (hdstr S) (dq))
               [ok Acc (tlstr S)]
               (take-string-h (tlstr S) (cn Acc (hdstr S)))))

\\ strtake accessors (was (= (hd P) bad) / (hd (tl P)) / (hd (tl (tl P)))).
(define strtake-bad?
  { strtake --> boolean }
  [ok _ _] -> false
  _ -> true)

(define strtake-str
  { strtake --> string }
  [ok Str _] -> Str)

(define strtake-rest
  { strtake --> string }
  [ok _ Rest] -> Rest)

(define take-word-h
  { string --> string --> strpair }
  "" Acc -> [Acc ""]
  S Acc -> (if (ws? (hdstr S))
               [Acc S]
               (take-word-h (tlstr S) (cn Acc (hdstr S)))))

(define tokenise-h
  { string --> boolean --> (list token) --> (list token) }
  "" PrevSpace Acc -> (reverse Acc)
  S PrevSpace Acc ->
    (let C (hdstr S)
      (if (ws? C)
          (tokenise-h (tlstr S) true Acc)
          (if (and (= C (bslash)) PrevSpace)
              (tokenise-h (skip-line S) true Acc)
              (if (and (= C "(")
                       (or (= (tlstr S) "") (ws? (hdstr (tlstr S)))))
                  (let P (take-paren-h (tlstr S) "")
                    (tokenise-h (spair-snd P) true
                      [["comment" (spair-fst P) (length Acc)] | Acc]))
                  (if (s-quote? S)
                      (let P (take-string-h (after-s-quote S) "")
                        (if (strtake-bad? P)
                            (simple-error (cn "unterminated S" (cn (dq) " string")))
                            (tokenise-h (strtake-rest P) false
                              [["string" (strtake-str P) (length Acc)] | Acc])))
                      (let W (take-word-h S "")
                        (let Raw (spair-fst W)
                          (let Rest (spair-snd W)
                            (tokenise-h Rest false
                              [(if (number-token? Raw)
                                   ["number" (parse-int Raw) (length Acc)]
                                   ["word" Raw (length Acc)]) | Acc]))))))))))

(define tokenise-program
  { string --> (list token) }
  Program -> (tokenise-h Program true []))

(define upcase-char
  { string --> string }
  C -> (let N (ch-code C)
         (if (and (>= N 97) (<= N 122))
             (n->string (- N 32))
             C)))

(define upcase
  { string --> string }
  "" -> ""
  S -> (cn (upcase-char (hdstr S)) (upcase (tlstr S))))

(define tok-kind
  { token --> string }
  [Kind _ _] -> Kind)

\\ Typed string (see token datatype note): number token values are never
\\ read, so every tok-value call site really does receive a string.
(define tok-value
  { token --> string }
  [_ Value _] -> Value)

(define tok-index
  { token --> number }
  [_ _ Idx] -> Idx)

(define tok-nth
  { (list token) --> number --> token }
  Tokens I -> (nth (+ I 1) Tokens))

(define tok-len
  { (list token) --> number }
  Tokens -> (length Tokens))

(define err-at
  { number --> string --> string }
  Index Msg -> (cn "token " (cn (str Index) (cn ": " Msg))))

(define string<
  { string --> string --> boolean }
  "" "" -> false
  "" S -> true
  S "" -> false
  A B -> (let CA (string->n (hdstr A))
           (let CB (string->n (hdstr B))
             (if (< CA CB)
                 true
                 (if (> CA CB)
                     false
                     (string< (tlstr A) (tlstr B)))))))

(define insert-str
  { string --> (list string) --> (list string) }
  X [] -> [X]
  X [Y | Ys] -> (if (string< X Y) [X Y | Ys] [Y | (insert-str X Ys)]))

(define sort-strings
  { (list string) --> (list string) }
  [] -> []
  [X | Y] -> (insert-str X (sort-strings Y)))

(define join-comma
  { (list string) --> string }
  [] -> ""
  [X] -> X
  [X | Xs] -> (cn X (cn ", " (join-comma Xs))))

(define uniq-append
  { (list A) --> (list A) --> (list A) }
  Acc [] -> Acc
  Acc [E | Es] -> (uniq-append (if (element? E Acc) Acc (append Acc [E])) Es))

(define not-subset
  { (list A) --> (list A) --> (list A) }
  [] Allowed -> []
  [E | Es] Allowed ->
    (if (element? E Allowed)
        (not-subset Es Allowed)
        [E | (not-subset Es Allowed)]))

\\ ---------------- word contracts: ( ins -- outs | effects ) -------------
\\ Grammar: items before -- are the inputs, items after are the outputs
\\ (names documentary; arity = count), and an optional | introduces a
\\ non-empty comma/space-separated effect list drawn from read/write/exec.
\\ Exactly one --, at most one |, nested parens impossible (the tokeniser
\\ ends the group at the first close paren).

(define split-contract-h
  { string --> string --> (list string) --> (list string) }
  "" Acc Parts -> (if (= Acc "") (reverse Parts) (reverse [Acc | Parts]))
  S Acc Parts ->
    (let C (hdstr S)
      (if (or (ws? C) (= C ","))
          (split-contract-h (tlstr S) "" (if (= Acc "") Parts [Acc | Parts]))
          (split-contract-h (tlstr S) (cn Acc C) Parts))))

\\ [ok In Out SortedEffects] | [bad Reason]
(define parse-contract
  { string --> cparse }
  Inner -> (parse-contract-ins (split-contract-h Inner "" []) 0))

(define parse-contract-ins
  { (list string) --> number --> cparse }
  [] _ -> [bad "missing --"]
  ["--" | Rest] In -> (parse-contract-outs Rest In 0)
  ["|" | _] _ -> [bad "| before --"]
  [_ | Rest] In -> (parse-contract-ins Rest (+ In 1)))

(define parse-contract-outs
  { (list string) --> number --> number --> cparse }
  [] In Out -> [ok In Out []]
  ["--" | _] _ _ -> [bad "more than one --"]
  ["|" | Rest] In Out -> (parse-contract-effs Rest In Out [])
  [_ | Rest] In Out -> (parse-contract-outs Rest In (+ Out 1)))

(define parse-contract-effs
  { (list string) --> number --> number --> (list string) --> cparse }
  [] _ _ [] -> [bad "| requires at least one effect"]
  [] In Out Effs -> [ok In Out (sort-strings Effs)]
  ["--" | _] _ _ _ -> [bad "more than one --"]
  ["|" | _] _ _ _ -> [bad "more than one |"]
  [W | Rest] In Out Effs ->
    (if (allowed-effect-name? W)
        (parse-contract-effs Rest In Out (uniq-append Effs [W]))
        [bad (cn "unknown effect: " W)]))

\\ cparse accessors (was (= (hd P) ok) / hd-tl chains).
(define cparse-ok?
  { cparse --> boolean }
  [ok _ _ _] -> true
  _ -> false)

(define cparse-in
  { cparse --> number }
  [ok In _ _] -> In)

(define cparse-out
  { cparse --> number }
  [ok _ Out _] -> Out)

(define cparse-effs
  { cparse --> (list string) }
  [ok _ _ Effs] -> Effs)

(define cparse-reason
  { cparse --> string }
  [bad Reason] -> Reason)

\\ Canonical rendering, used verbatim in mismatch rejects so repair is
\\ mechanical: counts, " -- ", sorted effects after " | ".
(define format-contract
  { number --> number --> (list string) --> string }
  In Out [] -> (cn "( " (cn (str In) (cn " -- " (cn (str Out) " )"))))
  In Out Effs -> (cn "( " (cn (str In)
                    (cn " -- " (cn (str Out)
                      (cn " | " (cn (join-comma Effs) " )")))))))

(define min2
  { number --> number --> number }
  A B -> (if (< A B) A B))

(define strlen
  { string --> number }
  "" -> 0
  S -> (+ 1 (strlen (tlstr S))))

(define drop-n
  { number --> string --> string }
  0 S -> S
  N S -> (if (= S "")
             ""
             (drop-n (- N 1) (tlstr S))))

(define starts-with?
  { string --> string --> boolean }
  "" S -> true
  Pre "" -> false
  Pre S -> (and (= (hdstr Pre) (hdstr S))
                (starts-with? (tlstr Pre) (tlstr S))))

(define abs-path?
  { string --> boolean }
  Path -> (and (not (= Path "")) (= (hdstr Path) "/")))

(define split-slashes-h
  { string --> string --> (list string) --> (list string) }
  "" Acc Parts -> (if (= Acc "") (reverse Parts) (reverse [Acc | Parts]))
  Path Acc Parts ->
    (if (= (hdstr Path) "/")
        (split-slashes-h (tlstr Path) "" (if (= Acc "") Parts [Acc | Parts]))
        (split-slashes-h (tlstr Path) (cn Acc (hdstr Path)) Parts)))

(define split-slashes
  { string --> (list string) }
  Path -> (split-slashes-h Path "" []))

(define normalise-parts
  { (list string) --> (list string) --> (list string) }
  [] Acc -> (reverse Acc)
  ["." | Rest] Acc -> (normalise-parts Rest Acc)
  [".." | Rest] [] -> (normalise-parts Rest [])
  [".." | Rest] [_ | AccRest] -> (normalise-parts Rest AccRest)
  [P | Rest] Acc -> (normalise-parts Rest [P | Acc]))

(define join-slashes
  { (list string) --> string }
  [] -> ""
  [P] -> P
  [P | Ps] -> (cn P (cn "/" (join-slashes Ps))))

(define normalise-path
  { string --> string }
  Path ->
    (let Parts (normalise-parts (split-slashes Path) [])
      (if (abs-path? Path)
          (cn "/" (join-slashes Parts))
          (join-slashes Parts))))

(define under-workspace?
  { string --> boolean }
  Abs -> (or (= Abs "/workspace")
             (starts-with? "/workspace/" Abs)))

(define strip-workspace
  { string --> string }
  Abs -> (if (= Abs "/workspace")
             ""
             (drop-n 11 Abs)))

(define workspace-rel
  { string --> relres }
  Path ->
    (let Abs (if (abs-path? Path)
                 (normalise-path Path)
                 (normalise-path (cn "/workspace/" Path)))
      (if (under-workspace? Abs)
          [ok (strip-workspace Abs)]
          [bad (cn "path escapes workspace: " Path)])))

\\ relres accessors (was (= (hd Rel) ok) / (hd (tl Rel))).
(define relres-ok?
  { relres --> boolean }
  [ok _] -> true
  _ -> false)

(define relres-path
  { relres --> string }
  [ok Rel] -> Rel)

(define relres-msg
  { relres --> string }
  [bad Msg] -> Msg)

(define lookup-word
  { string --> (list wordrow) --> wtriple }
  Name [] -> []
  Name [[Name In Out Eff] | _] -> [In Out Eff]
  Name [_ | Rest] -> (lookup-word Name Rest))

(define bind-word
  { string --> number --> number --> (list string) --> (list wordrow)
    --> (list wordrow) }
  Name In Out Eff Words -> [[Name In Out Eff] | Words])

(define contract-triple
  { string --> wtriple }
  Name ->
    (let In (contract-inputs Name)
      (if (= In -1)
          []
          [In (contract-outputs Name) (contract-effect Name)])))

(define word-contract
  { string --> (list wordrow) --> wtriple }
  Name Words ->
    (let Bound (lookup-word Name Words)
      (if (triple-none? Bound)
          (contract-triple Name)
          Bound)))

\\ wtriple accessors (was empty? / hd-tl chains).
(define triple-none?
  { wtriple --> boolean }
  [] -> true
  _ -> false)

(define triple-in
  { wtriple --> number }
  [In _ _] -> In)

(define triple-out
  { wtriple --> number }
  [_ Out _] -> Out)

(define triple-eff
  { wtriple --> (list string) }
  [_ _ Eff] -> Eff)

\\ Typed head for the non-empty (list string) cases below (hd is not
\\ type-secure in this kernel); every call is guarded by empty?.
(define first-str
  { (list string) --> string }
  [S | _] -> S)

(define literal-before
  { (list token) --> number --> (list string) }
  Tokens I ->
    (if (= I 0)
        []
        (let P (tok-nth Tokens (- I 1))
          (if (= (tok-kind P) "string")
              [(tok-value P)]
              []))))

\\ check-colon: parse the optional contract group after the name, then
\\ abstractly interpret the body against the current word table (running
\\ depth from 0; the minimum reached defines the inputs, the final depth
\\ the outputs; effects accumulate from called words). Returns
\\ [NI Name In Out Effs Errors] — Name "" when the definition is unusable
\\ (no binding), exactly as the old skip path behaved on malformed defs.
(define check-colon
  { (list token) --> number --> (list wordrow) --> (list string)
    --> (list string) --> (list string) --> (list string) --> colres }
  Tokens I Words Allowed Forbidden Artifacts Errors ->
    (if (>= (+ I 1) (tok-len Tokens))
        [(+ I 1) "" 0 0 []
         (append Errors
           [(err-at (tok-index (tok-nth Tokens I)) "expected name after :")])]
        (let NameTok (tok-nth Tokens (+ I 1))
          (if (not (= (tok-kind NameTok) "word"))
              [(+ I 1) "" 0 0 []
               (append Errors
                 [(err-at (tok-index (tok-nth Tokens I))
                          "expected name after :")])]
              (check-colon-decl Tokens (+ I 2)
                                (upcase (tok-value NameTok))
                                (tok-index NameTok)
                                Words Allowed Forbidden Artifacts Errors)))))

\\ The first token after the name decides the declaration: a comment token
\\ is parsed as the contract (invalid -> reject, then treated as absent);
\\ anything else means no declaration (inference).
(define check-colon-decl
  { (list token) --> number --> string --> number --> (list wordrow)
    --> (list string) --> (list string) --> (list string) --> (list string)
    --> colres }
  Tokens J Name Idx Words Allowed Forbidden Artifacts Errors ->
    (if (and (< J (tok-len Tokens))
             (= (tok-kind (tok-nth Tokens J)) "comment"))
        (let P (parse-contract (tok-value (tok-nth Tokens J)))
          (if (cparse-ok? P)
              (walk-body Tokens (+ J 1) Name Idx
                         [declared (cparse-in P) (cparse-out P)
                                   (cparse-effs P)]
                         0 0 [] Words Allowed Forbidden Artifacts Errors)
              (walk-body Tokens (+ J 1) Name Idx none
                         0 0 [] Words Allowed Forbidden Artifacts
                         (append Errors
                           [(err-at (tok-index (tok-nth Tokens J))
                              (cn "invalid contract for "
                                  (cn Name (cn ": " (cparse-reason P)))))]))))
        (walk-body Tokens J Name Idx none
                   0 0 [] Words Allowed Forbidden Artifacts Errors)))

(define walk-body
  { (list token) --> number --> string --> number --> decl --> number
    --> number --> (list string) --> (list wordrow) --> (list string)
    --> (list string) --> (list string) --> (list string) --> colres }
  Tokens J Name Idx Decl Depth Low Effs Words Allowed Forbidden Artifacts Errors ->
    (if (>= J (tok-len Tokens))
        [(tok-len Tokens) "" 0 0 []
         (append Errors ["unterminated colon definition"])]
        (let T (tok-nth Tokens J)
          (if (= (tok-kind T) "comment")
              (walk-body Tokens (+ J 1) Name Idx Decl Depth Low Effs
                         Words Allowed Forbidden Artifacts Errors)
              (if (or (= (tok-kind T) "string") (= (tok-kind T) "number"))
                  (walk-body Tokens (+ J 1) Name Idx Decl (+ Depth 1) Low Effs
                             Words Allowed Forbidden Artifacts Errors)
                  (walk-body-word Tokens J (upcase (tok-value T)) T
                                  Name Idx Decl Depth Low Effs
                                  Words Allowed Forbidden Artifacts Errors))))))

(define walk-body-word
  { (list token) --> number --> string --> token --> string --> number
    --> decl --> number --> number --> (list string) --> (list wordrow)
    --> (list string) --> (list string) --> (list string) --> (list string)
    --> colres }
  Tokens J ";" T Name Idx Decl Depth Low Effs Words Allowed Forbidden Artifacts Errors ->
    (finish-colon (+ J 1) Name Idx Decl (- 0 Low) (- Depth Low)
                  (sort-strings Effs) Errors)
  Tokens J ":" T Name Idx Decl Depth Low Effs Words Allowed Forbidden Artifacts Errors ->
    [(+ J 1) "" 0 0 []
     (append Errors
       [(err-at (tok-index T) "nested colon definitions are not supported")])]
  Tokens J Name T Name Idx Decl Depth Low Effs Words Allowed Forbidden Artifacts Errors ->
    (walk-body Tokens (+ J 1) Name Idx Decl Depth Low Effs
               Words Allowed Forbidden Artifacts
               (append Errors
                 [(err-at (tok-index T)
                    (cn "recursive colon definition "
                        (cn Name " is not supported")))]))
  Tokens J W T Name Idx Decl Depth Low Effs Words Allowed Forbidden Artifacts Errors ->
    (let C (word-contract W Words)
      (if (triple-none? C)
          (walk-body Tokens (+ J 1) Name Idx Decl Depth Low Effs
                     Words Allowed Forbidden Artifacts
                     (append Errors
                       [(err-at (tok-index T)
                                (cn "unknown word " (tok-value T)))]))
          (let In (triple-in C)
            (let Out (triple-out C)
              (let Eff (triple-eff C)
                (let Dropped (- Depth In)
                  (let NewLow (min2 Low Dropped)
                    (let NewErr (special-checks W Tokens J Allowed
                                                Forbidden Artifacts Errors)
                      (walk-body Tokens (+ J 1) Name Idx Decl
                                 (+ Dropped Out) NewLow
                                 (uniq-append Effs Eff)
                                 Words Allowed Forbidden Artifacts NewErr))))))))))

\\ At the terminating ; : computed contract = (in out effects). A declared
\\ contract must match exactly; the mismatch reject echoes both renderings
\\ verbatim. The word binds with its declared contract when one was given
\\ (mismatch already recorded), else the inferred one — never (0 0 []).
(define finish-colon
  { number --> string --> number --> decl --> number --> number
    --> (list string) --> (list string) --> colres }
  NI Name Idx none In Out Effs Errors -> [NI Name In Out Effs Errors]
  NI Name Idx [declared DIn DOut DEffs] In Out Effs Errors ->
    (if (and (= DIn In) (and (= DOut Out) (= DEffs Effs)))
        [NI Name DIn DOut DEffs Errors]
        [NI Name DIn DOut DEffs
         (append Errors
           [(err-at Idx
              (cn "contract mismatch for "
                  (cn Name
                      (cn ": declared "
                          (cn (format-contract DIn DOut DEffs)
                              (cn " computed "
                                  (format-contract In Out Effs)))))))])]))

\\ colres accessors (was hd-tl chains in walk).
(define colres-ni
  { colres --> number }
  [NI _ _ _ _ _] -> NI)

(define colres-name
  { colres --> string }
  [_ Name _ _ _ _] -> Name)

(define colres-in
  { colres --> number }
  [_ _ In _ _ _] -> In)

(define colres-out
  { colres --> number }
  [_ _ _ Out _ _] -> Out)

(define colres-effs
  { colres --> (list string) }
  [_ _ _ _ Effs _] -> Effs)

(define colres-errors
  { colres --> (list string) }
  [_ _ _ _ _ Errors] -> Errors)

(define write-check
  { (list token) --> number --> (list string) --> (list string)
    --> (list string) --> (list string) }
  Tokens I Allowed Forbidden Errors ->
    (let Lit (literal-before Tokens I)
      (if (empty? Lit)
          Errors
          (let Rel (workspace-rel (first-str Lit))
            (if (relres-ok? Rel)
                (let Path (relres-path Rel)
                  (if (write-ok? Path Allowed Forbidden)
                      Errors
                      (append Errors
                        [(err-at (tok-index (tok-nth Tokens I))
                                 (write-deny-reason Path Allowed Forbidden))])))
                (append Errors
                  [(err-at (tok-index (tok-nth Tokens I)) (relres-msg Rel))]))))))

(define artifact-check
  { (list token) --> number --> (list string) --> (list string)
    --> (list string) }
  Tokens I Artifacts Errors ->
    (let Lit (literal-before Tokens I)
      (if (empty? Lit)
          Errors
          (if (element? (first-str Lit) Artifacts)
              Errors
              (append Errors
                [(err-at (tok-index (tok-nth Tokens I))
                         (cn "no artifact: " (first-str Lit)))])))))

(define special-checks
  { string --> (list token) --> number --> (list string) --> (list string)
    --> (list string) --> (list string) --> (list string) }
  "WRITE-FILE" Tokens I Allowed Forbidden Artifacts Errors ->
    (write-check Tokens I Allowed Forbidden Errors)
  "USE-ARTIFACT" Tokens I Allowed Forbidden Artifacts Errors ->
    (artifact-check Tokens I Artifacts Errors)
  Name Tokens I Allowed Forbidden Artifacts Errors -> Errors)

(define apply-word
  { token --> string --> (list token) --> number --> number
    --> (list wordrow) --> (list string) --> (list string) --> (list string)
    --> (list string) --> (list string) --> wres }
  T Name Tokens I Depth Words Effects Allowed Forbidden Artifacts Errors ->
    (let C (word-contract Name Words)
      (if (triple-none? C)
          (walk Tokens (+ I 1) Depth Words Effects Allowed Forbidden Artifacts
                (append Errors
                  [(err-at (tok-index T)
                           (cn "unknown word " (tok-value T)))]))
          (let In (triple-in C)
            (let Out (triple-out C)
              (let Eff (triple-eff C)
                (let Under (< Depth In)
                  (let NewDepth (if Under Out (+ (- Depth In) Out))
                    (let NewErr (if Under
                                    (append Errors
                                      [(err-at (tok-index T)
                                               (cn "stack underflow at " Name))])
                                    Errors)
                      (let NewEff (uniq-append Effects Eff)
                        (let NewErr2 (special-checks Name Tokens I Allowed
                                                     Forbidden Artifacts NewErr)
                          (walk Tokens (+ I 1) NewDepth Words NewEff Allowed
                                Forbidden Artifacts NewErr2))))))))))))

(define walk
  { (list token) --> number --> number --> (list wordrow) --> (list string)
    --> (list string) --> (list string) --> (list string) --> (list string)
    --> wres }
  Tokens I Depth Words Effects Allowed Forbidden Artifacts Errors ->
    (if (>= I (tok-len Tokens))
        [Errors Depth Effects]
        (let T (tok-nth Tokens I)
          (if (= (tok-kind T) "comment")
              (walk Tokens (+ I 1) Depth Words Effects Allowed Forbidden
                    Artifacts Errors)
              (if (or (= (tok-kind T) "string") (= (tok-kind T) "number"))
                  (walk Tokens (+ I 1) (+ Depth 1) Words Effects Allowed
                        Forbidden Artifacts Errors)
                  (let Name (upcase (tok-value T))
                    (if (= Name ":")
                        (let SC (check-colon Tokens I Words Allowed Forbidden
                                             Artifacts Errors)
                          (let NI (colres-ni SC)
                            (let Def (colres-name SC)
                              (let BIn (colres-in SC)
                                (let BOut (colres-out SC)
                                  (let BEff (colres-effs SC)
                                    (let ER (colres-errors SC)
                                      (walk Tokens NI Depth
                                            (if (= Def "")
                                                Words
                                                (bind-word Def BIn BOut BEff
                                                           Words))
                                            Effects Allowed Forbidden
                                            Artifacts ER))))))))
                        (apply-word T Name Tokens I Depth Words Effects Allowed
                                    Forbidden Artifacts Errors))))))))

\\ wres accessors (was hd-tl chains in validate-tokens).
(define wres-errors
  { wres --> (list string) }
  [Errors _ _] -> Errors)

(define wres-depth
  { wres --> number }
  [_ Depth _] -> Depth)

(define wres-effs
  { wres --> (list string) }
  [_ _ Effs] -> Effs)

(define finish
  { (list string) --> number --> (list string) --> (list string) --> verdict }
  Errors Depth Effects Allowed ->
    (let Excess (sort-strings (not-subset Effects Allowed))
      (let AllErr (if (empty? Excess)
                      Errors
                      (append Errors
                        [(cn "effects not allowed: " (join-comma Excess))]))
        (if (empty? AllErr)
            [accept Depth (sort-strings Effects)]
            [reject AllErr Depth (sort-strings Effects)]))))

(define validate-catalog
  { (list token) --> (list wordrow) --> (list string) --> (list string)
    --> (list string) --> (list string) --> verdict }
  Tokens Catalog AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys ->
    (let R (walk Tokens 0 0 Catalog [] AllowedGlobs ForbiddenGlobs ArtifactKeys [])
      (finish (wres-errors R) (wres-depth R) (wres-effs R) AllowedEffects)))

(define validate-tokens
  { (list token) --> (list string) --> (list string) --> (list string)
    --> (list string) --> verdict }
  Tokens AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys ->
    (validate-catalog Tokens [] AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys))

(define validate
  { string --> (list string) --> (list string) --> (list string)
    --> (list string) --> verdict }
  Program AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys ->
    (trap-error
      (validate-tokens (tokenise-program Program)
                       AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys)
      (/. E [reject [(error-to-string E)] 0 []])))
