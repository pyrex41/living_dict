package main

import (
	"encoding/json"
	"net/http"
	"os"
	"sync"
)

type todo struct {
	ID    int    `json:"id"`
	Title string `json:"title"`
	Done  bool   `json:"done"`
}

var (
	mu     sync.Mutex
	todos  = []todo{}
	nextID = 1
)

func handleTodos(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		mu.Lock()
		defer mu.Unlock()
		json.NewEncoder(w).Encode(todos)
	case http.MethodPost:
		var body struct {
			Title string `json:"title"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Title == "" {
			body.Title = "untitled"
		}
		mu.Lock()
		item := todo{ID: nextID, Title: body.Title, Done: false}
		nextID++
		todos = append(todos, item)
		mu.Unlock()
		json.NewEncoder(w).Encode(item)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

func handleDone(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ID int `json:"id"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	mu.Lock()
	defer mu.Unlock()
	for i := range todos {
		if todos[i].ID == body.ID {
			todos[i].Done = true
			json.NewEncoder(w).Encode(todos[i])
			return
		}
	}
	http.Error(w, "not found", http.StatusNotFound)
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(`<!doctype html><html><head><title>Shen Todos</title></head>
<body><h1>todo</h1><p>Shen-Go + bifrost --shake shen-go + ShenScript frontend</p>
<ul id="list"></ul></body></html>`))
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleIndex)
	mux.HandleFunc("/todos", handleTodos)
	mux.HandleFunc("/todos/done", handleDone)
	addr := ":8080"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}
	_ = http.ListenAndServe(addr, mux)
}
