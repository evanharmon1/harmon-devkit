// =============================================================================
//
//	                    goScriptTemplate.go
//
// =============================================================================
// Template to create new go cli app
// Author: Evan Harmon
// Usage: go run main.go --input input.txt --output output.txt --verbose
// Build: go build -o cliapp
// Then: ./cliapp --input input.txt --verbose

package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

// Version of the CLI application
const Version = "1.0.0"

// Global logger
var logger *log.Logger

func init() {
	// Initialize the logger
	logger = log.New(os.Stdout, "INFO: ", log.Ldate|log.Ltime|log.Lshortfile)
}

func main() {
	// Define and parse command-line arguments
	input := flag.String("input", "", "Path to the input file (required)")
	output := flag.String("output", "output.txt", "Path to the output file (default: output.txt)")
	verbose := flag.Bool("verbose", false, "Enable verbose mode")
	version := flag.Bool("version", false, "Print version and exit")
	flag.Parse()

	// If version flag is set, print the version and exit
	if *version {
		fmt.Printf("CLI App version: %s\n", Version)
		os.Exit(0)
	}

	// Check if input argument is provided
	if *input == "" {
		fmt.Println("Error: Input file path is required")
		flag.Usage()
		os.Exit(1)
	}

	// Enable verbose logging if requested
	if *verbose {
		logger.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)
		logger.SetPrefix("DEBUG: ")
	}

	logger.Println("Starting CLI application")

	// Validate the input arguments
	if err := validateArgs(*input, *output); err != nil {
		logger.Fatalf("Validation error: %v", err)
	}

	// Process the file
	if err := processFile(*input, *output); err != nil {
		logger.Fatalf("File processing error: %v", err)
	}

	logger.Println("CLI application completed successfully")
}

// validateArgs validates the input and output file paths
func validateArgs(input string, output string) error {
	// Check if the input file exists
	if _, err := os.Stat(input); os.IsNotExist(err) {
		return fmt.Errorf("input file does not exist: %s", input)
	}

	// Check if the output directory is writable
	outputDir := filepath.Dir(output)
	if _, err := os.Stat(outputDir); os.IsNotExist(err) {
		return fmt.Errorf("output directory does not exist: %s", outputDir)
	}

	logger.Printf("Using input file: %s", input)
	logger.Printf("Output will be saved to: %s", output)

	return nil
}

// processFile is a placeholder for the main file processing logic
func processFile(input string, output string) error {
	// Example: Read the input file and write its contents to the output file
	inputFile, err := os.ReadFile(input)
	if err != nil {
		return fmt.Errorf("could not read input file: %v", err)
	}

	if err := os.WriteFile(output, inputFile, 0644); err != nil {
		return fmt.Errorf("could not write to output file: %v", err)
	}

	logger.Println("File processed successfully")
	return nil
}
