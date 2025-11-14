.PHONY: build test clean run install uninstall fmt vet lint help

# Variables
BINARY_NAME=myservice.exe
BUILD_DIR=bin
GO=go
GOFLAGS=-v

# Default target
all: test build

# Build the application
build:
	@echo "Building $(BINARY_NAME)..."
	@mkdir -p $(BUILD_DIR)
	GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME) ./cmd/service

# Build for 32-bit Windows
build-32:
	@echo "Building $(BINARY_NAME) for 32-bit..."
	@mkdir -p $(BUILD_DIR)
	GOOS=windows GOARCH=386 $(GO) build $(GOFLAGS) -o $(BUILD_DIR)/myservice-32.exe ./cmd/service

# Format code
fmt:
	@echo "Formatting code..."
	$(GO) fmt ./...

# Run go vet
vet:
	@echo "Running go vet..."
	$(GO) vet ./...

# Run staticcheck (install with: go install honnef.co/go/tools/cmd/staticcheck@latest)
lint:
	@echo "Running staticcheck..."
	staticcheck ./...

# Clean build artifacts
clean:
	@echo "Cleaning..."
	rm -rf $(BUILD_DIR)
	rm -f coverage.out coverage.html
	rm -f *.log

# Install dependencies
deps:
	@echo "Installing dependencies..."
	$(GO) mod download
	$(GO) mod tidy

# Run in debug mode (requires Windows)
run:
	$(GO) run ./cmd/service debug

# Quick checks before commit
check: fmt vet test

# Help command
help:
	@echo "Available targets:"
	@echo "  build          - Build the Windows service executable"
	@echo "  build-32       - Build 32-bit Windows executable"
	@echo "  fmt            - Format code"
	@echo "  vet            - Run go vet"
	@echo "  lint           - Run staticcheck"
	@echo "  clean          - Remove build artifacts"
	@echo "  deps           - Install dependencies"
	@echo "  run            - Run in debug mode"
	@echo "  check          - Run fmt, vet, and test"
	@echo "  help           - Show this help message"