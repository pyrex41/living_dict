\\ Transducer ABI for a Unikraft-shaped organ.
\\ Portable, eval-free. Complements shen/critic/contracts.shen:
\\ that file owns Forth words; this file owns the organ bus.

(define organ-name?
  "seq" -> true
  "critic" -> true
  "host" -> true
  "store" -> true
  "gates" -> true
  "planner" -> true
  X -> false)

(define kind-name?
  "plan" -> true
  "verdict" -> true
  "execute" -> true
  "intern" -> true
  "interned" -> true
  "applied" -> true
  "measure" -> true
  "report" -> true
  "ack" -> true
  X -> false)

(define hop-ok?
  "planner" "seq" "plan" -> true
  "seq" "critic" "plan" -> true
  "critic" "seq" "verdict" -> true
  "seq" "host" "execute" -> true
  "host" "store" "intern" -> true
  "store" "host" "interned" -> true
  "host" "seq" "applied" -> true
  "seq" "gates" "measure" -> true
  "gates" "seq" "report" -> true
  "seq" "planner" "ack" -> true
  X Y Z -> false)

(define message-ok?
  Src Dst Kind ->
    (and (organ-name? Src)
         (organ-name? Dst)
         (kind-name? Kind)
         (hop-ok? Src Dst Kind)))

\\ The critic organ still never writes, never calls a model, never
\\ executes. hop-ok? makes execute-from-critic unrepresentable.
