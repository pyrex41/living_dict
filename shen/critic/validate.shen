\\ forth-shen critic. Named validate: Accept | Reject.
\\ Portable, eval-free. No lua.call, js.call, runtime (tc +), eval, or load.
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

(define ch-code
  C -> (string->n C))

(define ws-code?
  N -> (or (= N 32)
           (or (= N 9)
               (or (= N 10)
                   (or (= N 13)
                       (or (= N 12) (= N 11)))))))

(define ws?
  C -> (ws-code? (ch-code C)))

(define dq
  -> (n->string 34))

(define bslash
  -> (n->string 92))

(define nlch
  -> (n->string 10))

(define is-digit?
  C -> (let N (ch-code C)
         (and (>= N 48) (<= N 57))))

(define all-digits?
  "" -> true
  S -> (and (is-digit? (hdstr S)) (all-digits? (tlstr S))))

(define number-token?
  "" -> false
  "+" -> false
  "-" -> false
  S -> (if (= (hdstr S) "-")
           (and (not (= (tlstr S) "")) (all-digits? (tlstr S)))
           (all-digits? S)))

(define parse-nat
  "" Acc -> Acc
  S Acc -> (parse-nat (tlstr S) (+ (* Acc 10) (- (ch-code (hdstr S)) 48))))

(define parse-int
  S -> (if (= (hdstr S) "-")
           (- 0 (parse-nat (tlstr S) 0))
           (parse-nat S 0)))

(define skip-line
  "" -> ""
  S -> (if (= (hdstr S) (nlch)) S (skip-line (tlstr S))))

\\ Paren groups are captured as comment tokens (the critic needs to SEE
\\ contract groups; runtime Forth VMs keep discarding them). Unterminated
\\ groups run to end-of-source, mirroring the old skip-paren.
(define take-paren-h
  "" Acc -> [Acc ""]
  S Acc -> (if (= (hdstr S) ")")
               [Acc (tlstr S)]
               (take-paren-h (tlstr S) (cn Acc (hdstr S)))))

(define s-quote?
  S -> (and (not (= S ""))
            (and (not (= (tlstr S) ""))
                 (and (or (= (hdstr S) "S") (= (hdstr S) "s"))
                      (= (hdstr (tlstr S)) (dq))))))

(define after-s-quote
  S -> (let Rest (tlstr (tlstr S))
         (if (and (not (= Rest "")) (= (hdstr Rest) " "))
             (tlstr Rest)
             Rest)))

(define take-string-h
  "" Acc -> [bad]
  S Acc -> (if (= (hdstr S) (dq))
               [ok Acc (tlstr S)]
               (take-string-h (tlstr S) (cn Acc (hdstr S)))))

(define take-word-h
  "" Acc -> [Acc ""]
  S Acc -> (if (ws? (hdstr S))
               [Acc S]
               (take-word-h (tlstr S) (cn Acc (hdstr S)))))

(define tokenise-h
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
                    (tokenise-h (hd (tl P)) true
                      [["comment" (hd P) (length Acc)] | Acc]))
                  (if (s-quote? S)
                      (let P (take-string-h (after-s-quote S) "")
                        (if (= (hd P) bad)
                            (simple-error (cn "unterminated S" (cn (dq) " string")))
                            (tokenise-h (hd (tl (tl P))) false
                              [["string" (hd (tl P)) (length Acc)] | Acc])))
                      (let W (take-word-h S "")
                        (let Raw (hd W)
                          (let Rest (hd (tl W))
                            (tokenise-h Rest false
                              [(if (number-token? Raw)
                                   ["number" (parse-int Raw) (length Acc)]
                                   ["word" Raw (length Acc)]) | Acc]))))))))))

(define tokenise-program
  Program -> (tokenise-h Program true []))

(define upcase-char
  C -> (let N (ch-code C)
         (if (and (>= N 97) (<= N 122))
             (n->string (- N 32))
             C)))

(define upcase
  "" -> ""
  S -> (cn (upcase-char (hdstr S)) (upcase (tlstr S))))

(define tok-kind
  T -> (hd T))

(define tok-value
  T -> (hd (tl T)))

(define tok-index
  T -> (hd (tl (tl T))))

(define tok-nth
  Tokens I -> (nth (+ I 1) Tokens))

(define tok-len
  Tokens -> (length Tokens))

(define err-at
  Index Msg -> (cn "token " (cn (str Index) (cn ": " Msg))))

(define string<
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
  X [] -> [X]
  X [Y | Ys] -> (if (string< X Y) [X Y | Ys] [Y | (insert-str X Ys)]))

(define sort-strings
  [] -> []
  [X | Y] -> (insert-str X (sort-strings Y)))

(define join-comma
  [] -> ""
  [X] -> X
  [X | Xs] -> (cn X (cn ", " (join-comma Xs))))

(define uniq-append
  Acc [] -> Acc
  Acc [E | Es] -> (uniq-append (if (element? E Acc) Acc (append Acc [E])) Es))

(define not-subset
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
  "" Acc Parts -> (if (= Acc "") (reverse Parts) (reverse [Acc | Parts]))
  S Acc Parts ->
    (let C (hdstr S)
      (if (or (ws? C) (= C ","))
          (split-contract-h (tlstr S) "" (if (= Acc "") Parts [Acc | Parts]))
          (split-contract-h (tlstr S) (cn Acc C) Parts))))

\\ [ok In Out SortedEffects] | [bad Reason]
(define parse-contract
  Inner -> (parse-contract-ins (split-contract-h Inner "" []) 0))

(define parse-contract-ins
  [] _ -> [bad "missing --"]
  ["--" | Rest] In -> (parse-contract-outs Rest In 0)
  ["|" | _] _ -> [bad "| before --"]
  [_ | Rest] In -> (parse-contract-ins Rest (+ In 1)))

(define parse-contract-outs
  [] In Out -> [ok In Out []]
  ["--" | _] _ _ -> [bad "more than one --"]
  ["|" | Rest] In Out -> (parse-contract-effs Rest In Out [])
  [_ | Rest] In Out -> (parse-contract-outs Rest In (+ Out 1)))

(define parse-contract-effs
  [] _ _ [] -> [bad "| requires at least one effect"]
  [] In Out Effs -> [ok In Out (sort-strings Effs)]
  ["--" | _] _ _ _ -> [bad "more than one --"]
  ["|" | _] _ _ _ -> [bad "more than one |"]
  [W | Rest] In Out Effs ->
    (if (allowed-effect-name? W)
        (parse-contract-effs Rest In Out (uniq-append Effs [W]))
        [bad (cn "unknown effect: " W)]))

\\ Canonical rendering, used verbatim in mismatch rejects so repair is
\\ mechanical: counts, " -- ", sorted effects after " | ".
(define format-contract
  In Out [] -> (cn "( " (cn (str In) (cn " -- " (cn (str Out) " )"))))
  In Out Effs -> (cn "( " (cn (str In)
                    (cn " -- " (cn (str Out)
                      (cn " | " (cn (join-comma Effs) " )")))))))

(define min2
  A B -> (if (< A B) A B))

(define strlen
  "" -> 0
  S -> (+ 1 (strlen (tlstr S))))

(define drop-n
  0 S -> S
  N S -> (if (= S "")
             ""
             (drop-n (- N 1) (tlstr S))))

(define starts-with?
  "" S -> true
  Pre "" -> false
  Pre S -> (and (= (hdstr Pre) (hdstr S))
                (starts-with? (tlstr Pre) (tlstr S))))

(define abs-path?
  Path -> (and (not (= Path "")) (= (hdstr Path) "/")))

(define split-slashes-h
  "" Acc Parts -> (if (= Acc "") (reverse Parts) (reverse [Acc | Parts]))
  Path Acc Parts ->
    (if (= (hdstr Path) "/")
        (split-slashes-h (tlstr Path) "" (if (= Acc "") Parts [Acc | Parts]))
        (split-slashes-h (tlstr Path) (cn Acc (hdstr Path)) Parts)))

(define split-slashes
  Path -> (split-slashes-h Path "" []))

(define normalise-parts
  [] Acc -> (reverse Acc)
  ["." | Rest] Acc -> (normalise-parts Rest Acc)
  [".." | Rest] [] -> (normalise-parts Rest [])
  [".." | Rest] Acc -> (normalise-parts Rest (tl Acc))
  [P | Rest] Acc -> (normalise-parts Rest [P | Acc]))

(define join-slashes
  [] -> ""
  [P] -> P
  [P | Ps] -> (cn P (cn "/" (join-slashes Ps))))

(define normalise-path
  Path ->
    (let Parts (normalise-parts (split-slashes Path) [])
      (if (abs-path? Path)
          (cn "/" (join-slashes Parts))
          (join-slashes Parts))))

(define under-workspace?
  Abs -> (or (= Abs "/workspace")
             (starts-with? "/workspace/" Abs)))

(define strip-workspace
  Abs -> (if (= Abs "/workspace")
             ""
             (drop-n 11 Abs)))

(define workspace-rel
  Path ->
    (let Abs (if (abs-path? Path)
                 (normalise-path Path)
                 (normalise-path (cn "/workspace/" Path)))
      (if (under-workspace? Abs)
          [ok (strip-workspace Abs)]
          [bad (cn "path escapes workspace: " Path)])))

(define lookup-word
  Name [] -> []
  Name [[Name In Out Eff] | _] -> [In Out Eff]
  Name [_ | Rest] -> (lookup-word Name Rest))

(define bind-word
  Name In Out Eff Words -> [[Name In Out Eff] | Words])

(define contract-triple
  Name ->
    (let In (contract-inputs Name)
      (if (= In -1)
          []
          [In (contract-outputs Name) (contract-effect Name)])))

(define word-contract
  Name Words ->
    (let Bound (lookup-word Name Words)
      (if (empty? Bound)
          (contract-triple Name)
          Bound)))

(define literal-before
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
  Tokens J Name Idx Words Allowed Forbidden Artifacts Errors ->
    (if (and (< J (tok-len Tokens))
             (= (tok-kind (tok-nth Tokens J)) "comment"))
        (let P (parse-contract (tok-value (tok-nth Tokens J)))
          (if (= (hd P) ok)
              (walk-body Tokens (+ J 1) Name Idx
                         [declared (hd (tl P)) (hd (tl (tl P)))
                                   (hd (tl (tl (tl P))))]
                         0 0 [] Words Allowed Forbidden Artifacts Errors)
              (walk-body Tokens (+ J 1) Name Idx none
                         0 0 [] Words Allowed Forbidden Artifacts
                         (append Errors
                           [(err-at (tok-index (tok-nth Tokens J))
                              (cn "invalid contract for "
                                  (cn Name (cn ": " (hd (tl P))))))]))))
        (walk-body Tokens J Name Idx none
                   0 0 [] Words Allowed Forbidden Artifacts Errors)))

(define walk-body
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
      (if (empty? C)
          (walk-body Tokens (+ J 1) Name Idx Decl Depth Low Effs
                     Words Allowed Forbidden Artifacts
                     (append Errors
                       [(err-at (tok-index T)
                                (cn "unknown word " (tok-value T)))]))
          (let In (hd C)
            (let Out (hd (tl C))
              (let Eff (hd (tl (tl C)))
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

(define write-check
  Tokens I Allowed Forbidden Errors ->
    (let Lit (literal-before Tokens I)
      (if (empty? Lit)
          Errors
          (let Rel (workspace-rel (hd Lit))
            (if (= (hd Rel) ok)
                (let Path (hd (tl Rel))
                  (if (write-ok? Path Allowed Forbidden)
                      Errors
                      (append Errors
                        [(err-at (tok-index (tok-nth Tokens I))
                                 (write-deny-reason Path Allowed Forbidden))])))
                (append Errors
                  [(err-at (tok-index (tok-nth Tokens I)) (hd (tl Rel)))]))))))

(define artifact-check
  Tokens I Artifacts Errors ->
    (let Lit (literal-before Tokens I)
      (if (empty? Lit)
          Errors
          (if (element? (hd Lit) Artifacts)
              Errors
              (append Errors
                [(err-at (tok-index (tok-nth Tokens I))
                         (cn "no artifact: " (hd Lit)))])))))

(define special-checks
  "WRITE-FILE" Tokens I Allowed Forbidden Artifacts Errors ->
    (write-check Tokens I Allowed Forbidden Errors)
  "USE-ARTIFACT" Tokens I Allowed Forbidden Artifacts Errors ->
    (artifact-check Tokens I Artifacts Errors)
  Name Tokens I Allowed Forbidden Artifacts Errors -> Errors)

(define apply-word
  T Name Tokens I Depth Words Effects Allowed Forbidden Artifacts Errors ->
    (let C (word-contract Name Words)
      (if (empty? C)
          (walk Tokens (+ I 1) Depth Words Effects Allowed Forbidden Artifacts
                (append Errors
                  [(err-at (tok-index T)
                           (cn "unknown word " (tok-value T)))]))
          (let In (hd C)
            (let Out (hd (tl C))
              (let Eff (hd (tl (tl C)))
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
                          (let NI (hd SC)
                            (let Def (hd (tl SC))
                              (let BIn (hd (tl (tl SC)))
                                (let BOut (hd (tl (tl (tl SC))))
                                  (let BEff (hd (tl (tl (tl (tl SC)))))
                                    (let ER (hd (tl (tl (tl (tl (tl SC))))))
                                      (walk Tokens NI Depth
                                            (if (= Def "")
                                                Words
                                                (bind-word Def BIn BOut BEff
                                                           Words))
                                            Effects Allowed Forbidden
                                            Artifacts ER))))))))
                        (apply-word T Name Tokens I Depth Words Effects Allowed
                                    Forbidden Artifacts Errors))))))))

(define finish
  Errors Depth Effects Allowed ->
    (let Excess (sort-strings (not-subset Effects Allowed))
      (let AllErr (if (empty? Excess)
                      Errors
                      (append Errors
                        [(cn "effects not allowed: " (join-comma Excess))]))
        (if (empty? AllErr)
            [accept Depth (sort-strings Effects)]
            [reject AllErr Depth (sort-strings Effects)]))))

(define validate-tokens
  Tokens AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys ->
    (let R (walk Tokens 0 0 [] [] AllowedGlobs ForbiddenGlobs ArtifactKeys [])
      (finish (hd R) (hd (tl R)) (hd (tl (tl R))) AllowedEffects)))

(define validate
  Program AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys ->
    (trap-error
      (validate-tokens (tokenise-program Program)
                       AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys)
      (/. E [reject [(error-to-string E)] 0 []])))
