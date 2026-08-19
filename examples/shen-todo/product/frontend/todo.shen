\\ ShenScript frontend: render a todo list and talk to /todos
\\ uses pyrex41/ShenScript for the browser layer

(package frontend [render fetch-todos submit-todo])

(define shenscript-app
  -> [div [class "todo-app"]
          [h1 "Shen Todos"]
          [form [onsubmit submit-todo]
                [input [id "title"] [placeholder "what needs doing?"]]
                [button "add"]]
          [ul [id "list"] (map render-item (fetch-todos))]])

(define render
  State -> (shenscript-app))

(define render-item
  [id Id title Title done Done]
  -> [li [class (if Done "done" "open")]
         [span Title]
         [button [onclick (/. _ (complete Id))] "ok"]])

(define fetch-todos
  -> (json-parse (http-get "/todos")))

(define submit-todo
  Event -> (do (prevent-default Event)
               (http-post "/todos" [title (input-value "title")])
               (rerender)))
