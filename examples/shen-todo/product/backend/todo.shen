\\ Shen-Go todo store: in-memory list with add / get / complete

(package todo [get-todos add-todo complete-todo find-todo])

(set *todos* [])
(set *next-id* 1)

(define get-todos
  -> (value *todos*))

(define add-todo
  Title -> (let Id (value *next-id*)
                Item [id Id title Title done false]
                _ (set *todos* (append (value *todos*) [Item]))
                _ (set *next-id* (+ Id 1))
             Item))

(define complete-todo
  Id -> (let Updated (map (/. T (mark-done Id T)) (value *todos*))
             _ (set *todos* Updated)
          (find-todo Id)))

(define mark-done
  Id [id I title Title done D] -> (if (= Id I)
                                      [id I title Title done true]
                                      [id I title Title done D]))

(define find-todo
  Id -> (head (filter (/. T (= (nth 2 T) Id)) (value *todos*))))
