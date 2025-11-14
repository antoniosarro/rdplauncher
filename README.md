# Windows Service - Go Web Server

A production-ready Windows service written in Go that provides system information via HTTP endpoints using PowerShell scripts.

## Features

- **Windows Service Integration**: Runs as a native Windows service with automatic start capability
- **HTTP API**: RESTful endpoints for system information retrieval
- **Registry Management**: Automatic Windows registry configuration with backup/restore
- **Structured Logging**: Environment-aware logging (development/production)
- **Graceful Shutdown**: Proper cleanup and shutdown procedures
- **Comprehensive Testing**: Unit tests with high coverage
- **PowerShell Integration**: Executes embedded PowerShell scripts for system info

## Project Structure
```
├── cmd/service/          # Application entry point
├── internal/
│   ├── config/          # Configuration management
│   ├── logger/          # Structured logging
│   ├── registry/        # Windows registry operations
│   ├── server/          # HTTP server and handlers
│   └── service/         # Windows service implementation
├── scripts/             # Embedded PowerShell scripts
└── testdata/            # Test fixtures
```

## Prerequisites

- Go 1.25.2 or later
- Windows OS (for service features)
- Administrator privileges (for service installation)

## Building
```bash
# Build for Windows (64-bit)
make build

# Build for Windows (32-bit)
make build-32

# Install dependencies
make deps
```

## Installation
```bash
# Install the service (requires admin)
myservice.exe install

# Start the service
myservice.exe start

# Or use Windows Services Manager (services.msc)
```

## Usage

### Service Commands
```bash
# Install service
myservice.exe install

# Remove service
myservice.exe remove

# Start service
myservice.exe start

# Stop service
myservice.exe stop

# Run in debug mode (foreground)
myservice.exe debug
```

### API Endpoints

Once the service is running, the following endpoints are available:

#### Health Check
```
GET http://localhost:8080/health
```

Response:
```json
{
  "status": "ok",
  "service": "RDPLauncher"
}
```

#### System Information
```
GET http://localhost:8080/api/system-info
```

Response:
```json
{
  "ComputerName": "DESKTOP-ABC123",
  "OSVersion": "Microsoft Windows NT 10.0.19045.0",
  "ProcessorCount": "8",
  "Uptime": "2024-01-15T08:30:00Z",
  "Memory": 17179869184
}
```

## Configuration

The service can be configured using environment variables:

- `SERVER_PORT`: HTTP server port (default: 8080)
- `GO_ENV`: Environment mode - `development` or `production` (default: development)
- `INSTALL_PATH`: Service installation path
- `DATA_DIR`: Data directory path

Example:
```bash
set GO_ENV=production
set SERVER_PORT=8085
myservice.exe debug
```

## Development

### Running Tests
```bash
# Run all tests
make test

# Run tests with coverage
make test-coverage

# Run benchmarks
make bench
```

### Code Quality
```bash
# Format code
make fmt

# Run static analysis
make vet

# Run linter
make lint

# Run all checks
make check
```

### Debug Mode

For development, run the service in debug mode:
```bash
make run
# or
myservice.exe debug
```

This runs the service in the foreground with detailed logging to both console and file.

## Logging

Logs are written to different locations based on the environment:

- **Development**: `service_debug.log` (+ console output)
- **Production**: `C:\ProgramData\RDPLauncher\service.log`

Log levels:
- DEBUG (development only)
- INFO
- WARN
- ERROR
- FATAL

Example log entry:
```
[2024-01-15 10:30:45.123] [INFO] Service starting name=RDPLauncher
```

## Registry Entries

The service creates the following registry entries:

**HKLM\SOFTWARE\RDPLauncher:**
- `InstallPath` (REG_SZ): Installation directory
- `ServerPort` (REG_DWORD): HTTP server port
- `EnableLogging` (REG_DWORD): Logging flag

**HKCU\SOFTWARE\RDPLauncher\User:**
- `LastRun` (REG_SZ): Last execution timestamp

Registry entries are automatically backed up during installation and restored during removal.

## Troubleshooting

### Service Won't Start

1. Check logs in `C:\ProgramData\RDPLauncher\service.log`
2. Verify port 8080 is not in use
3. Ensure admin privileges
4. Check Windows Event Viewer

### Port Already in Use

Change the server port:
```bash
set SERVER_PORT=9090
myservice.exe install
```

### Registry Errors

If registry operations fail:
1. Run as Administrator
2. Check registry permissions
3. Review service logs for detailed errors

## License

[Your License Here]

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run tests: `make check`
4. Submit a pull request