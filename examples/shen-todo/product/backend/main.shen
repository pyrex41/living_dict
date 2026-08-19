\\ HTTP entry: route /todos to the Shen todo API

(package main [handle route start])

(load "backend/todo.shen")

(define route
  "GET"  "/todos"     _     -> (json (todo.get-todos))
  "POST" "/todos"     Body  -> (json (todo.add-todo (get-title Body)))
  "POST" "/todos/done" Body -> (json (todo.complete-todo (get-id Body)))
  Method Path         _     -> [status 404 body "not found"])

(define handle
  Request -> (let Method (nth 2 Request)
                  Path   (nth 4 Request)
                  Body   (nth 6 Request)
               (route Method Path Body)))

(define get-title
  Body -> (trap-error (get-key Body title) (/. E "untitled")))

(define get-id
  Body -> (trap-error (get-key Body id) (/. E 0)))

(define start
  Port -> (listen Port (function handle)))
