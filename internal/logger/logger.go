package logger

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"time"
)

// Level represents the logging level
type Level int

const (
	LevelDebug Level = iota
	LevelInfo
	LevelWarn
	LevelError
	LevelFatal
)

// String returns the string representation of the log level
func (l Level) String() string {
	switch l {
	case LevelDebug:
		return "DEBUG"
	case LevelInfo:
		return "INFO"
	case LevelWarn:
		return "WARN"
	case LevelError:
		return "ERROR"
	case LevelFatal:
		return "FATAL"
	default:
		return "UNKNOWN"
	}
}

// Logger provides structured logging functionality
type Logger struct {
	logger *log.Logger
	file   *os.File
	level  Level
	isDev  bool
}

// New creates a new logger instance
func New(logPath string, env string) (*Logger, error) {
	isDev := env == "development"

	// Create log directory if it doesn't exist
	logDir := filepath.Dir(logPath)
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create log directory: %w", err)
	}

	// Open log file
	file, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		return nil, fmt.Errorf("failed to open log file: %w", err)
	}

	// Configure output writers
	var output io.Writer
	if isDev {
		// In development, write to both file and stdout
		output = io.MultiWriter(file, os.Stdout)
	} else {
		// In production, write only to file
		output = file
	}

	// Set minimum log level
	minLevel := LevelInfo
	if isDev {
		minLevel = LevelDebug
	}

	logger := &Logger{
		logger: log.New(output, "", 0),
		file:   file,
		level:  minLevel,
		isDev:  isDev,
	}

	return logger, nil
}

// Close closes the log file
func (l *Logger) Close() error {
	if l.file != nil {
		return l.file.Close()
	}
	return nil
}

// log writes a log message at the specified level
func (l *Logger) log(level Level, msg string, keysAndValues ...interface{}) {
	if level < l.level {
		return
	}

	timestamp := time.Now().Format("2006-01-02 15:04:05.000")
	levelStr := level.String()

	// Build the log message
	logMsg := fmt.Sprintf("[%s] [%s] %s", timestamp, levelStr, msg)

	// Append key-value pairs
	if len(keysAndValues) > 0 {
		for i := 0; i < len(keysAndValues); i += 2 {
			if i+1 < len(keysAndValues) {
				logMsg += fmt.Sprintf(" %v=%v", keysAndValues[i], keysAndValues[i+1])
			}
		}
	}

	l.logger.Println(logMsg)

	// If fatal, exit the program
	if level == LevelFatal {
		os.Exit(1)
	}
}

// Debug logs a debug message
func (l *Logger) Debug(msg string, keysAndValues ...interface{}) {
	l.log(LevelDebug, msg, keysAndValues...)
}

// Info logs an info message
func (l *Logger) Info(msg string, keysAndValues ...interface{}) {
	l.log(LevelInfo, msg, keysAndValues...)
}

// Warn logs a warning message
func (l *Logger) Warn(msg string, keysAndValues ...interface{}) {
	l.log(LevelWarn, msg, keysAndValues...)
}

// Error logs an error message
func (l *Logger) Error(msg string, keysAndValues ...interface{}) {
	l.log(LevelError, msg, keysAndValues...)
}

// Fatal logs a fatal message and exits the program
func (l *Logger) Fatal(msg string, keysAndValues ...interface{}) {
	l.log(LevelFatal, msg, keysAndValues...)
}
