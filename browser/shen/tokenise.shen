\\ Forth tokeniser in portable Shen. Matches livingdict.forth / forth.lua.
\\ No lua.call / js.call. Tokens are [Kind Value Index] with 0-based Index.

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

(define skip-paren
  "" -> ""
  S -> (if (= (hdstr S) ")") (tlstr S) (skip-paren (tlstr S))))

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
                  (tokenise-h (skip-paren (tlstr S)) true Acc)
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
