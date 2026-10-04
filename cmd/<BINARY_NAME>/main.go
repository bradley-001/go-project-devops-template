package main

import (
	"fmt"
	"io"
	"os"
)

// environment is the build channel (prod | pre-prod | staging | dev)
var environment = "-1"

// version is the semantic release version, mirrored with a corresponding git tag
var version = "-1"

func main() {
	os.Exit(run(os.Args, os.Stdout, os.Stderr, os.Stdin))
}

func run(args []string, stdOut, stdErr io.Writer, stdIn io.Reader) int {
	if version == "-1" || environment == "-1" {
		fmt.Fprintln(stdErr, "ERROR: version and environment must be stamped via -ldflags; build with make or goreleaser")
		return 1
	}
	fmt.Fprintf(stdOut, "%s %s (%s)\n", "<BINARY_NAME>", version, environment)
	return 0
}
