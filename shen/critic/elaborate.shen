\\ ld-system/v1 elaborator. Named elaborate: [accepted Steps [] Obligations]
\\ | [rejected Steps Failed []].
\\ Portable, eval-free. No lua.call, js.call, runtime (tc +), eval, or load.
\\ Fully typed: this file typechecks under `yggdrasil build --typecheck`
\\ (loaded with (tc +) at build time). The datatypes below are the rigid
\\ specification of the flattened manifest a host passes in; the host
\\ (beam/lib/ld_host/elaborate.ex `shen_request`, beam/priv/elaborate_server.mjs)
\\ does the JSON work, this file does the judging.
\\
\\ Judgments, applied in this fixed order, every step recorded:
\\   R1 component-well-formed   component names a registered substrate
\\   R2 channel-endpoints       out port -> in port, equal types
\\   R3 effect-owner            owner exists; substrate carries the protocol
\\   R4 substrate-satisfies     every requires dimension met (one step per unmet)
\\   R5 substrate-admissible    substrate may back runtime claims
\\   R6 invariant-scope         about names only declared things
\\   R7 failure-model           entries listed (vocabulary is host-checked)
\\ Accepted manifests yield obligation ids (tool:kind:subject) in a fixed
\\ order. LdHost.Elaborate (Elixir) must agree step for step; the
\\ conformance test is beam/test/elaborate_shen_test.exs.

\\ ---------------------------- typed spec --------------------------------

\\ [Key Value]: requires entries, substrate vector entries.
(datatype pair
  K : string; V : string;
  =======================
  [K V] : pair;)

\\ [Name Direction Type]
(datatype port
  Name : string; Dir : string; Type : string;
  ===========================================
  [Name Dir Type] : port;)

\\ [Name Contract Substrate Ports Requires]. fault_controls travels inside
\\ Requires as a comma-joined value under the key "fault_controls".
(datatype component
  Name : string; Contract : string; Sub : string;
  Ports : (list port); Req : (list pair);
  ===============================================
  [Name Contract Sub Ports Req] : component;)

\\ [Name From To Delivery Ordering]; From/To are "component.port".
(datatype channel
  Name : string; From : string; To : string; Del : string; Ord : string;
  =====================================================================
  [Name From To Del Ord] : channel;)

\\ [Name Owner Protocol Identity Target]; Target "" when absent.
(datatype effect
  Name : string; Owner : string; Proto : string; Ident : string; Target : string;
  ==============================================================================
  [Name Owner Proto Ident Target] : effect;)

\\ [Id Kind About]
(datatype invariant
  Id : string; Kind : string; About : (list string);
  ==================================================
  [Id Kind About] : invariant;)

\\ [Name Claims Vector Faults]: a registered substrate profile.
(datatype profile
  Name : string; Claims : boolean; Vec : (list pair); Faults : (list string);
  ===========================================================================
  [Name Claims Vec Faults] : profile;)

\\ [Dimension Values]: lattice order, weakest first.
(datatype order
  Dim : string; Vals : (list string);
  ===================================
  [Dim Vals] : order;)

\\ [Rule Subject Ok Detail]
(datatype step
  Rule : string; Subject : string; Ok : boolean; Detail : string;
  ===============================================================
  [Rule Subject Ok Detail] : step;)

\\ [Dimension Required Supplied]
(datatype unmet
  Dim : string; Req : string; Sup : string;
  =========================================
  [Dim Req Sup] : unmet;)

(datatype compopt
  ________________
  [] : compopt;

  C : component;
  =====================
  [found C] : compopt;)

(datatype portopt
  ________________
  [] : portopt;

  P : port;
  =====================
  [found P] : portopt;)

(datatype profopt
  ________________
  [] : profopt;

  P : profile;
  =====================
  [found P] : profopt;)

\\ elaborate result. Construct-only here; hosts deconstruct.
(datatype derivation
  Steps : (list step); Obls : (list string);
  ==========================================
  [accepted Steps [] Obls] : derivation;

  Steps : (list step); Failed : (list string);
  ============================================
  [rejected Steps Failed []] : derivation;)

\\ ---------------------------- strings -----------------------------------

(define el-str<
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
                     (el-str< (tlstr A) (tlstr B)))))))

(define el-insert-str
  { string --> (list string) --> (list string) }
  X [] -> [X]
  X [Y | Ys] -> (if (el-str< X Y) [X Y | Ys] [Y | (el-insert-str X Ys)]))

(define el-sort-strings
  { (list string) --> (list string) }
  [] -> []
  [X | Xs] -> (el-insert-str X (el-sort-strings Xs)))

(define el-join
  { string --> (list string) --> string }
  Sep [] -> ""
  Sep [X] -> X
  Sep [X | Xs] -> (cn X (cn Sep (el-join Sep Xs))))

(define el-split-h
  { string --> string --> string --> (list string) }
  Sep "" Acc -> [Acc]
  Sep S Acc -> (if (= (hdstr S) Sep)
                   [Acc | (el-split-h Sep (tlstr S) "")]
                   (el-split-h Sep (tlstr S) (cn Acc (hdstr S)))))

\\ Split on a one-character separator; "" splits to [].
(define el-split
  { string --> string --> (list string) }
  Sep "" -> []
  Sep S -> (el-split-h Sep S ""))

\\ Dimension keys arrive as written; the registry uses underscores.
(define el-normalize-dim
  { string --> string }
  "" -> ""
  S -> (cn (if (= (hdstr S) "-") "_" (hdstr S)) (el-normalize-dim (tlstr S))))

(define el-not-in
  { (list string) --> (list string) --> (list string) }
  [] Known -> []
  [X | Xs] Known -> (if (element? X Known)
                        (el-not-in Xs Known)
                        [X | (el-not-in Xs Known)]))

(define el-all-in?
  { (list string) --> (list string) --> boolean }
  [] Known -> true
  [X | Xs] Known -> (and (element? X Known) (el-all-in? Xs Known)))

\\ ---------------------------- accessors ---------------------------------

(define pair-key
  { pair --> string }
  [K V] -> K)

(define pair-val
  { pair --> string }
  [K V] -> V)

(define port-name
  { port --> string }
  [N D T] -> N)

(define port-dir
  { port --> string }
  [N D T] -> D)

(define port-type
  { port --> string }
  [N D T] -> T)

(define comp-name
  { component --> string }
  [N C S P R] -> N)

(define comp-contract
  { component --> string }
  [N C S P R] -> C)

(define comp-sub
  { component --> string }
  [N C S P R] -> S)

(define comp-ports
  { component --> (list port) }
  [N C S P R] -> P)

(define comp-req
  { component --> (list pair) }
  [N C S P R] -> R)

(define chan-name
  { channel --> string }
  [N F T D O] -> N)

(define chan-from
  { channel --> string }
  [N F T D O] -> F)

(define chan-to
  { channel --> string }
  [N F T D O] -> T)

(define chan-del
  { channel --> string }
  [N F T D O] -> D)

(define chan-ord
  { channel --> string }
  [N F T D O] -> O)

(define eff-name
  { effect --> string }
  [N O P I T] -> N)

(define eff-owner
  { effect --> string }
  [N O P I T] -> O)

(define eff-proto
  { effect --> string }
  [N O P I T] -> P)

(define eff-ident
  { effect --> string }
  [N O P I T] -> I)

(define eff-target
  { effect --> string }
  [N O P I T] -> T)

(define inv-id
  { invariant --> string }
  [I K A] -> I)

(define inv-kind
  { invariant --> string }
  [I K A] -> K)

(define inv-about
  { invariant --> (list string) }
  [I K A] -> A)

(define prof-name
  { profile --> string }
  [N C V F] -> N)

(define prof-claims
  { profile --> boolean }
  [N C V F] -> C)

(define prof-vec
  { profile --> (list pair) }
  [N C V F] -> V)

(define prof-faults
  { profile --> (list string) }
  [N C V F] -> F)

(define step-rule
  { step --> string }
  [R S O D] -> R)

(define step-subject
  { step --> string }
  [R S O D] -> S)

(define step-ok
  { step --> boolean }
  [R S O D] -> O)

\\ ---------------------------- lookups -----------------------------------

(define el-find-comp
  { string --> (list component) --> compopt }
  N [] -> []
  N [C | Cs] -> (if (= (comp-name C) N) [found C] (el-find-comp N Cs)))

(define el-find-prof
  { string --> (list profile) --> profopt }
  N [] -> []
  N [P | Ps] -> (if (= (prof-name P) N) [found P] (el-find-prof N Ps)))

(define el-find-port-in
  { string --> (list port) --> portopt }
  N [] -> []
  N [P | Ps] -> (if (= (port-name P) N) [found P] (el-find-port-in N Ps)))

\\ "component.port" -> [Component Port]; no dot -> [Whole ""].
(define el-split-dot
  { string --> string --> pair }
  Acc "" -> [Acc ""]
  Acc S -> (if (= (hdstr S) ".")
               [Acc (tlstr S)]
               (el-split-dot (cn Acc (hdstr S)) (tlstr S))))

(define el-port-of
  { compopt --> string --> portopt }
  [] Port -> []
  [found C] Port -> (el-find-port-in Port (comp-ports C)))

(define el-find-port
  { string --> (list component) --> portopt }
  Endpoint Comps -> (let P (el-split-dot "" Endpoint)
                      (el-port-of (el-find-comp (pair-key P) Comps) (pair-val P))))

(define el-comp-or-empty
  { compopt --> component }
  [] -> ["" "" "" [] []]
  [found C] -> C)

(define el-pick-comps
  { (list string) --> (list component) --> (list component) }
  [] Comps -> []
  [N | Ns] Comps -> [(el-comp-or-empty (el-find-comp N Comps)) | (el-pick-comps Ns Comps)])

(define el-sorted-comps
  { (list component) --> (list component) }
  Comps -> (el-pick-comps (el-sort-strings (map (function comp-name) Comps)) Comps))

(define el-find-chan
  { string --> (list channel) --> channel }
  N [] -> ["" "" "" "" ""]
  N [C | Cs] -> (if (= (chan-name C) N) C (el-find-chan N Cs)))

(define el-sorted-chans
  { (list channel) --> (list channel) }
  Chans -> (map (/. N (el-find-chan N Chans))
                (el-sort-strings (map (function chan-name) Chans))))

(define el-find-eff
  { string --> (list effect) --> effect }
  N [] -> ["" "" "" "" ""]
  N [E | Es] -> (if (= (eff-name E) N) E (el-find-eff N Es)))

(define el-sorted-effs
  { (list effect) --> (list effect) }
  Effs -> (map (/. N (el-find-eff N Effs))
               (el-sort-strings (map (function eff-name) Effs))))

(define el-find-inv
  { string --> (list invariant) --> invariant }
  N [] -> ["" "" []]
  N [I | Is] -> (if (= (inv-id I) N) I (el-find-inv N Is)))

(define el-sorted-invs
  { (list invariant) --> (list invariant) }
  Invs -> (map (/. N (el-find-inv N Invs))
               (el-sort-strings (map (function inv-id) Invs))))

(define el-insert-pair
  { pair --> (list pair) --> (list pair) }
  X [] -> [X]
  X [Y | Ys] -> (if (el-str< (pair-key X) (pair-key Y))
                    [X Y | Ys]
                    [Y | (el-insert-pair X Ys)]))

(define el-sort-pairs
  { (list pair) --> (list pair) }
  [] -> []
  [X | Xs] -> (el-insert-pair X (el-sort-pairs Xs)))

\\ ---------------------------- lattice -----------------------------------

(define el-index
  { string --> (list string) --> number --> number }
  V [] I -> -1
  V [X | Xs] I -> (if (= X V) I (el-index V Xs (+ I 1))))

(define el-order-values
  { string --> (list order) --> (list string) }
  Dim [] -> []
  Dim [[D Vs] | Os] -> (if (= D Dim) Vs (el-order-values Dim Os)))

(define el-known-dim?
  { string --> (list order) --> boolean }
  Dim Orders -> (or (= Dim "fault_controls")
                    (not (= (el-order-values Dim Orders) []))))

(define el-vector-value
  { string --> (list pair) --> string }
  Dim [] -> ""
  Dim [[K V] | Ps] -> (if (= K Dim) V (el-vector-value Dim Ps)))

(define el-meets?
  { string --> string --> string --> (list order) --> boolean }
  Dim Req Sup Orders -> (let Vs (el-order-values Dim Orders)
                          (let R (el-index Req Vs 0)
                            (let S (el-index Sup Vs 0)
                              (and (>= R 0) (and (>= S 0) (>= S R)))))))

(define el-or-none
  { string --> string }
  "" -> "none"
  S -> S)

\\ Unmet dimensions of a sorted requires list against a profile.
(define el-unmet
  { (list pair) --> profile --> (list order) --> (list unmet) }
  [] Prof Orders -> []
  [[K V] | Ps] Prof Orders ->
    (let Dim (el-normalize-dim K)
      (if (= Dim "fault_controls")
          (if (el-all-in? (el-split "," V) (prof-faults Prof))
              (el-unmet Ps Prof Orders)
              [[Dim V (el-join "," (prof-faults Prof))] | (el-unmet Ps Prof Orders)])
          (let Sup (el-vector-value Dim (prof-vec Prof))
            (if (and (el-known-dim? Dim Orders) (el-meets? Dim V Sup Orders))
                (el-unmet Ps Prof Orders)
                [[(if (el-known-dim? Dim Orders) Dim "unknown") V (el-or-none Sup)]
                 | (el-unmet Ps Prof Orders)])))))

\\ ---------------------------- rules -------------------------------------

(define el-r1
  { (list component) --> (list profile) --> (list step) }
  [] Profs -> []
  [C | Cs] Profs ->
    (let Known (not (= (el-find-prof (comp-sub C) Profs) []))
      [["component-well-formed" (comp-name C) Known
        (if Known
            (cn "contract " (cn (comp-contract C) (cn " on " (comp-sub C))))
            (cn "unknown substrate " (comp-sub C)))]
       | (el-r1 Cs Profs)]))

(define el-r2-judge
  { channel --> portopt --> portopt --> step }
  Ch [] To -> ["channel-endpoints" (chan-name Ch) false
               (cn "from endpoint " (cn (chan-from Ch) " is not a declared port"))]
  Ch From [] -> ["channel-endpoints" (chan-name Ch) false
                 (cn "to endpoint " (cn (chan-to Ch) " is not a declared port"))]
  Ch [found F] [found T] ->
    (if (not (= (port-dir F) "out"))
        ["channel-endpoints" (chan-name Ch) false "from endpoint must be an out port"]
        (if (not (= (port-dir T) "in"))
            ["channel-endpoints" (chan-name Ch) false "to endpoint must be an in port"]
            (if (not (= (port-type F) (port-type T)))
                ["channel-endpoints" (chan-name Ch) false
                 (cn "port types do not compose: " (cn (port-type F) (cn " vs " (port-type T))))]
                ["channel-endpoints" (chan-name Ch) true
                 (cn (chan-from Ch)
                     (cn " -> " (cn (chan-to Ch)
                                    (cn " : " (cn (port-type F)
                                                  (cn " " (cn (chan-del Ch)
                                                              (cn "/" (chan-ord Ch)))))))))]))))

(define el-r2
  { (list channel) --> (list component) --> (list step) }
  [] Comps -> []
  [Ch | Chs] Comps -> [(el-r2-judge Ch (el-find-port (chan-from Ch) Comps)
                                       (el-find-port (chan-to Ch) Comps))
                       | (el-r2 Chs Comps)])

(define el-protocol-req
  { string --> string }
  "durable-intent-commit" -> "durable-intent-commit"
  "recorded" -> "recorded"
  "ambient" -> "ambient"
  X -> "")

(define el-r3-prof
  { effect --> component --> profopt --> (list order) --> step }
  E C [] Orders -> ["effect-owner" (eff-name E) false
                    (cn "substrate " (cn (comp-sub C) " unknown"))]
  E C [found P] Orders ->
    (let Req (el-protocol-req (eff-proto E))
      (let Sup (el-vector-value "external_effects" (prof-vec P))
        (if (el-meets? "external_effects" Req Sup Orders)
            ["effect-owner" (eff-name E) true
             (cn "owned by " (cn (eff-owner E) (cn " under " (eff-proto E))))]
            ["effect-owner" (eff-name E) false
             (cn "external_effects needs " (cn Req (cn " got " (cn (el-or-none Sup)
                                                                   (cn " on " (comp-sub C))))))]))))

(define el-r3-judge
  { effect --> compopt --> (list string) --> (list profile) --> (list order) --> step }
  E [] Ex Profs Orders -> ["effect-owner" (eff-name E) false
                           (cn "owner " (cn (eff-owner E) " is not a component"))]
  E [found C] Ex Profs Orders ->
    (if (and (= (eff-ident E) "host-derived") (not (= (eff-proto E) "durable-intent-commit")))
        ["effect-owner" (eff-name E) false
         "host-derived identity requires the durable-intent-commit protocol"]
        (if (and (not (= (eff-target E) "")) (not (element? (eff-target E) Ex)))
            ["effect-owner" (eff-name E) false
             (cn "target " (cn (eff-target E) " is not a declared external"))]
            (el-r3-prof E C (el-find-prof (comp-sub C) Profs) Orders))))

(define el-r3
  { (list effect) --> (list component) --> (list string) --> (list profile)
    --> (list order) --> (list step) }
  [] Comps Ex Profs Orders -> []
  [E | Es] Comps Ex Profs Orders ->
    [(el-r3-judge E (el-find-comp (eff-owner E) Comps) Ex Profs Orders)
     | (el-r3 Es Comps Ex Profs Orders)])

(define el-unmet-step
  { component --> unmet --> step }
  C [Dim Req Sup] -> ["substrate-satisfies" (cn (comp-name C) (cn "." Dim)) false
                      (cn "needs " (cn Req (cn " got " (cn Sup (cn " on " (comp-sub C))))))])

(define el-r4-comp
  { component --> profopt --> (list order) --> (list step) }
  C [] Orders -> [["substrate-satisfies" (cn (comp-name C) ".profile") false
                   (cn "needs " (cn (comp-sub C) (cn " got unknown on " (comp-sub C))))]]
  C [found P] Orders ->
    (let Unmet (el-unmet (el-sort-pairs (comp-req C)) P Orders)
      (if (= Unmet [])
          [["substrate-satisfies" (comp-name C) true
            (cn (str (length (comp-req C))) (cn " dimension(s) met by " (comp-sub C)))]]
          (map (/. U (el-unmet-step C U)) Unmet))))

(define el-r4
  { (list component) --> (list profile) --> (list order) --> (list step) }
  [] Profs Orders -> []
  [C | Cs] Profs Orders -> (append (el-r4-comp C (el-find-prof (comp-sub C) Profs) Orders)
                                   (el-r4 Cs Profs Orders)))

(define el-r5-comp
  { component --> profopt --> step }
  C [] -> ["substrate-admissible" (comp-name C) false
           (cn "unknown runtime profile: " (comp-sub C))]
  C [found P] -> (if (prof-claims P)
                     ["substrate-admissible" (comp-name C) true
                      (cn (comp-sub C) " may back claims")]
                     ["substrate-admissible" (comp-name C) false
                      (cn "runtime profile " (cn (comp-sub C) " is experimental and cannot back a claim"))]))

(define el-r5
  { (list component) --> (list profile) --> (list step) }
  [] Profs -> []
  [C | Cs] Profs -> [(el-r5-comp C (el-find-prof (comp-sub C) Profs)) | (el-r5 Cs Profs)])

(define el-r6
  { (list invariant) --> (list string) --> (list step) }
  [] Names -> []
  [I | Is] Names ->
    (let Unknown (el-not-in (inv-about I) Names)
      [(if (= Unknown [])
           ["invariant-scope" (inv-id I) true
            (cn (inv-kind I) (cn " over " (el-join ", " (inv-about I))))]
           ["invariant-scope" (inv-id I) false
            (cn "unknown names: " (el-join ", " Unknown))])
       | (el-r6 Is Names)]))

(define el-r7
  { (list string) --> (list step) }
  [] -> []
  [F | Fs] -> [["failure-model" F true "in vocabulary"] | (el-r7 Fs)])

(define el-names
  { (list component) --> (list channel) --> (list effect) --> (list string) --> (list string) }
  Comps Chans Effs Ex -> (append (map (function comp-name) Comps)
                                 (append (map (function chan-name) Chans)
                                         (append (map (function eff-name) Effs) Ex))))

(define el-failed
  { (list step) --> (list string) }
  [] -> []
  [S | Ss] -> (if (step-ok S)
                  (el-failed Ss)
                  [(cn (step-rule S) (cn ":" (step-subject S))) | (el-failed Ss)]))

\\ ---------------------------- obligations -------------------------------

(define el-obl-comps
  { (list component) --> (list string) }
  [] -> []
  [C | Cs] -> [(cn "runtime:replay-stable:" (comp-name C))
               (cn "runtime:checkpoint-recovered:" (comp-name C))
               | (el-obl-comps Cs)])

(define el-obl-chans
  { (list channel) --> (list string) }
  [] -> []
  [Ch | Chs] -> [(cn "tla:delivery-" (cn (chan-del Ch) (cn ":" (chan-name Ch))))
                 | (el-obl-chans Chs)])

(define el-obl-effs
  { (list effect) --> (list string) }
  [] -> []
  [E | Es] -> (if (= (eff-proto E) "durable-intent-commit")
                  [(cn "runtime:effects-exactly-once:" (eff-name E)) | (el-obl-effs Es)]
                  (el-obl-effs Es)))

(define el-obl-inv
  { invariant --> string }
  I -> (let Kind (inv-kind I)
         (if (= Kind "forbidden-path")
             (cn "netkat:isolated:" (el-join "->" (inv-about I)))
             (if (= Kind "required-waypoint")
                 (cn "netkat:waypoint:" (el-join "->" (inv-about I)))
                 (if (= Kind "liveness")
                     (cn "tla:liveness:" (inv-id I))
                     (cn "tla:invariant:" (inv-id I)))))))

(define el-obl-fails
  { string --> (list string) --> (list string) }
  System [] -> []
  System [F | Fs] -> [(cn "exploration:" (cn F (cn ":" System))) | (el-obl-fails System Fs)])

(define el-obligations
  { string --> (list component) --> (list channel) --> (list effect)
    --> (list invariant) --> (list string) --> (list string) }
  System Comps Chans Effs Invs Fails ->
    (append (el-obl-comps Comps)
            (append (el-obl-chans Chans)
                    (append (el-obl-effs Effs)
                            (append (map (function el-obl-inv) Invs)
                                    (el-obl-fails System Fails))))))

\\ ---------------------------- entry -------------------------------------

(define el-judge
  { string --> (list component) --> (list channel) --> (list effect)
    --> (list string) --> (list invariant) --> (list string)
    --> (list profile) --> (list order) --> derivation }
  System Comps Chans Effs Ex Invs Fails Profs Orders ->
    (let SC (el-sorted-comps Comps)
      (let SCh (el-sorted-chans Chans)
        (let SE (el-sorted-effs Effs)
          (let SI (el-sorted-invs Invs)
            (let SF (el-sort-strings Fails)
              (let Steps (append (el-r1 SC Profs)
                           (append (el-r2 SCh Comps)
                             (append (el-r3 SE Comps Ex Profs Orders)
                               (append (el-r4 SC Profs Orders)
                                 (append (el-r5 SC Profs)
                                   (append (el-r6 SI (el-names Comps Chans Effs Ex))
                                           (el-r7 SF)))))))
                (let Failed (el-failed Steps)
                  (if (= Failed [])
                      [accepted Steps [] (el-obligations System SC SCh SE SI SF)]
                      [rejected Steps Failed []])))))))))

(define elaborate
  { string --> (list component) --> (list channel) --> (list effect)
    --> (list string) --> (list invariant) --> (list string)
    --> (list profile) --> (list order) --> derivation }
  System Comps Chans Effs Ex Invs Fails Profs Orders ->
    (trap-error
      (el-judge System Comps Chans Effs Ex Invs Fails Profs Orders)
      (/. E [rejected [["elaborate" "host" false (error-to-string E)]]
                      [(cn "elaborate:" "host")] []])))
