// scudcheck pipes a rho.run/v1 JSONL transcript into scud's ConsumeRhoV1.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/reuben/scud/pkg/executor"
)

func main() {
	runID := flag.String("run-id", "", "expected run_id (default: first event)")
	flag.Parse()
	payload, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "scudcheck: read stdin: %v\n", err)
		os.Exit(2)
	}
	expected := *runID
	if expected == "" {
		expected, err = firstRunID(payload)
		if err != nil {
			fmt.Fprintf(os.Stderr, "scudcheck: %v\n", err)
			os.Exit(2)
		}
	}
	if _, err := executor.ConsumeRhoV1(bytes.NewReader(payload), expected, nil); err != nil {
		fmt.Fprintf(os.Stderr, "scudcheck: %v\n", err)
		os.Exit(1)
	}
}

func firstRunID(payload []byte) (string, error) {
	for _, line := range strings.Split(string(payload), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var event struct {
			RunID string `json:"run_id"`
		}
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			return "", fmt.Errorf("decode first event: %w", err)
		}
		if event.RunID == "" {
			return "", fmt.Errorf("first event missing run_id")
		}
		return event.RunID, nil
	}
	return "", fmt.Errorf("empty transcript")
}
