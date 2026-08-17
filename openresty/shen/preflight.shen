\\ forth-shen critic. Named validate: Accept | Reject.
\\ Does not emit patches, does not call a model, does not replace Forth.
\\ Tokenise matches the hosted Forth VM (via livingdict.tokenise).
\\ Colon bodies are not checked (Contract 0,0). Leftover depth is not a reject.
\\
\\ Host-word arity/effects come from contract-inputs / contract-outputs /
\\ contract-effect. Literal WRITE-FILE paths are gated by write-ok? /
\\ write-deny-reason (glob fnmatch in the typed core).

(define upcase
  S -> (lua.call "string.upper" [S]))

(define tokenise-program
  Program -> (lua.call "livingdict.tokenise" [Program]))

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

\\ Colon definitions only. Host words are contract-inputs / contract-outputs /
\\ contract-effect from the typed core — never a parallel hardcoded table.
(define lookup-word
  Name [] -> []
  Name [[Name In Out Eff] | _] -> [In Out Eff]
  Name [_ | Rest] -> (lookup-word Name Rest))

(define bind-word
  Name Words -> [[Name 0 0 []] | Words])

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
              [(str (tok-value P))]
              []))))

(define scan-colon-body
  Tokens J Name Errors ->
    (if (>= J (tok-len Tokens))
        [(tok-len Tokens) "" (append Errors ["unterminated colon definition"])]
        (let T (tok-nth Tokens J)
          (if (and (= (tok-kind T) "word")
                   (= (upcase (str (tok-value T))) ";"))
              [(+ J 1) Name Errors]
              (if (and (= (tok-kind T) "word")
                       (= (upcase (str (tok-value T))) ":"))
                  [(+ J 1) ""
                   (append Errors
                     [(err-at (tok-index T)
                              "nested colon definitions are not supported")])]
                  (scan-colon-body Tokens (+ J 1) Name Errors))))))

(define skip-colon
  Tokens I Errors ->
    (if (>= (+ I 1) (tok-len Tokens))
        [(+ I 1) ""
         (append Errors
           [(err-at (tok-index (tok-nth Tokens I)) "expected name after :")])]
        (let NameTok (tok-nth Tokens (+ I 1))
          (if (not (= (tok-kind NameTok) "word"))
              [(+ I 1) ""
               (append Errors
                 [(err-at (tok-index (tok-nth Tokens I))
                          "expected name after :")])]
              (scan-colon-body Tokens (+ I 2)
                               (upcase (str (tok-value NameTok))) Errors)))))

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
                           (cn "unknown word " (str (tok-value T))))]))
          (let In (nth 1 C)
            (let Out (nth 2 C)
              (let Eff (nth 3 C)
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
          (if (or (= (tok-kind T) "string") (= (tok-kind T) "number"))
              (walk Tokens (+ I 1) (+ Depth 1) Words Effects Allowed Forbidden
                    Artifacts Errors)
              (let Name (upcase (str (tok-value T)))
                (if (= Name ":")
                    (let SC (skip-colon Tokens I Errors)
                      (let NI (nth 1 SC)
                        (let Def (nth 2 SC)
                          (let ER (nth 3 SC)
                            (walk Tokens NI Depth
                                  (if (= Def "") Words (bind-word Def Words))
                                  Effects Allowed Forbidden Artifacts ER)))))
                    (apply-word T Name Tokens I Depth Words Effects Allowed
                                Forbidden Artifacts Errors)))))))

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
      (finish (nth 1 R) (nth 2 R) (nth 3 R) AllowedEffects)))

(define validate
  Program AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys ->
    (trap-error
      (validate-tokens (tokenise-program Program)
                       AllowedEffects AllowedGlobs ForbiddenGlobs ArtifactKeys)
      (/. E [reject [(error-to-string E)] 0 []])))
