package config

import (
	"os"
)

// Environment represents the application environment
type Environment string

const (
	Development Environment = "development"
	Production  Environment = "production"
)

// Config holds the application configuration
type Config struct {
	// Server configuration
	ServerPort string

	// Logging configuration
	LogPath     string
	Environment Environment

	// Registry configuration
	InstallPath   string
	EnableLogging bool
	DataDirectory string
}

// New creates a new configuration with default or environment-based values
func New() *Config {
	env := getEnvironment()

	cfg := &Config{
		ServerPort:    getEnvOrDefault("SERVER_PORT", "8080"),
		LogPath:       getLogPath(env),
		Environment:   env,
		InstallPath:   getEnvOrDefault("INSTALL_PATH", `C:\Program Files\RDPLauncher`),
		EnableLogging: true,
		DataDirectory: getEnvOrDefault("DATA_DIR", `C:\ProgramData\RDPLauncher`),
	}

	return cfg
}

// getEnvironment determines the current environment
func getEnvironment() Environment {
	env := os.Getenv("GO_ENV")
	switch env {
	case "production", "prod":
		return Production
	default:
		return Development
	}
}

// getLogPath returns the appropriate log path based on environment
func getLogPath(env Environment) string {
	if env == Development {
		return "service_debug.log"
	}
	return `C:\ProgramData\RDPLauncher\service.log`
}

// getEnvOrDefault retrieves an environment variable or returns a default value
func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
