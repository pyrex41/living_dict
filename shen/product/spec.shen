\\ Typed product spec. Typechecked by `yggdrasil check`; types erased in
\\ the shake. Self-contained: no load / eval / runtime (tc +).
\\ `.` is cons, so obligation-kind constructors use hyphens; compile-product
\\ restores the dotted host strings Space.@allowed_kinds uses.

(datatype claimkind
  ______________
  check : claimkind;

  ______________
  source : claimkind;

  ______________
  file : claimkind;

  ______________
  absent : claimkind;)

(datatype glob
  S : string;
  =======================
  S : glob;)

(datatype effect
  ___________
  read : effect;

  ___________
  write : effect;

  ___________
  exec : effect;)

(datatype obligation-kind
  ________________
  node-ready : obligation-kind;

  ________________
  gate-result : obligation-kind;

  ________________
  critic-reject : obligation-kind;

  ________________
  obligation : obligation-kind;)

(datatype claim
  Id : string; Kind : claimkind; Command : string; Path : string;
  ==============================================================
  [Id Kind Command Path] : claim;)

(datatype product
  Claims : (list claim); Globs : (list glob);
  Effects : (list effect); Kinds : (list obligation-kind);
  =======================================================
  [Claims Globs Effects Kinds] : product;)

(datatype claimmap
  Id : string; Kind : string; Command : string; Path : string;
  ____________________________________________________________
  [Id Kind Command Path] : claimmap;)

(datatype compiled
  Claims : (list claimmap); Globs : (list string);
  Effects : (list string); Kinds : (list string);
  ______________________________________________
  [Claims Globs Effects Kinds] : compiled;)

(define claimkind-name
  { claimkind --> string }
  check -> "check"
  source -> "source"
  file -> "file"
  absent -> "absent")

(define effect-name
  { effect --> string }
  read -> "read"
  write -> "write"
  exec -> "exec")

(define obligation-kind-name
  { obligation-kind --> string }
  node-ready -> "node.ready"
  gate-result -> "gate.result"
  critic-reject -> "critic.reject"
  obligation -> "obligation")

(define glob-name
  { glob --> string }
  S -> S)

(define claim-id
  { claim --> string }
  [Id _ _ _] -> Id)

(define claim-kind
  { claim --> claimkind }
  [_ Kind _ _] -> Kind)

(define claim-command
  { claim --> string }
  [_ _ Command _] -> Command)

(define claim-path
  { claim --> string }
  [_ _ _ Path] -> Path)

(define product-claims
  { product --> (list claim) }
  [Claims _ _ _] -> Claims)

(define product-globs
  { product --> (list glob) }
  [_ Globs _ _] -> Globs)

(define product-effects
  { product --> (list effect) }
  [_ _ Effects _] -> Effects)

(define product-kinds
  { product --> (list obligation-kind) }
  [_ _ _ Kinds] -> Kinds)

(define compile-claim
  { claim --> claimmap }
  C -> [(claim-id C)
        (claimkind-name (claim-kind C))
        (claim-command C)
        (claim-path C)])

(define compile-claims
  { (list claim) --> (list claimmap) }
  [] -> []
  [C | Cs] -> (cons (compile-claim C) (compile-claims Cs)))

(define compile-globs
  { (list glob) --> (list string) }
  [] -> []
  [G | Gs] -> (cons (glob-name G) (compile-globs Gs)))

(define compile-effects
  { (list effect) --> (list string) }
  [] -> []
  [E | Es] -> (cons (effect-name E) (compile-effects Es)))

(define compile-kinds
  { (list obligation-kind) --> (list string) }
  [] -> []
  [K | Ks] -> (cons (obligation-kind-name K) (compile-kinds Ks)))

(define compile-product
  { product --> compiled }
  P -> [(compile-claims (product-claims P))
        (compile-globs (product-globs P))
        (compile-effects (product-effects P))
        (compile-kinds (product-kinds P))])

(define fixture-product
  { --> product }
  -> [[["greets" check "grep -q hello greet.txt" ""]]
      ["greet.txt"]
      [read write exec]
      [obligation]])

(define compile-fixture
  { --> compiled }
  -> (compile-product (fixture-product)))
