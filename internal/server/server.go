package server

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/antoniosarro/rdplauncher/internal/logger"
)

// Server represents the HTTP server
type Server struct {
	port       string
	httpServer *http.Server
	logger     *logger.Logger
}

// New creates a new HTTP server instance
func New(port string, log *logger.Logger) *Server {
	s := &Server{
		port:   port,
		logger: log,
	}

	// Create HTTP server with routes
	mux := http.NewServeMux()

	// Health check endpoint
	mux.HandleFunc("/health", s.handleHealth)

	// System information endpoint
	mux.HandleFunc("/api/system-info", s.handleSystemInfo)

	// Application discovery endpoint
	mux.HandleFunc("/api/apps", s.handleApps)

	s.httpServer = &http.Server{
		Addr:         fmt.Sprintf(":%s", port),
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	return s
}

// Start starts the HTTP server
func (s *Server) Start() error {
	s.logger.Info("Starting HTTP server", "port", s.port)

	if err := s.httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("server error: %w", err)
	}

	return nil
}

// Shutdown gracefully shuts down the HTTP server
func (s *Server) Shutdown(ctx context.Context) error {
	s.logger.Info("Shutting down HTTP server")
	return s.httpServer.Shutdown(ctx)
}
