package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestIndexHasTodo(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rw := httptest.NewRecorder()
	handleIndex(rw, req)
	if rw.Code != 200 {
		t.Fatalf("status %d", rw.Code)
	}
	body := rw.Body.String()
	if len(body) < 4 {
		t.Fatal("empty")
	}
}
