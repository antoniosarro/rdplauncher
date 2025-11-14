package service

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/antoniosarro/rdplauncher/internal/config"
	"github.com/antoniosarro/rdplauncher/internal/logger"
	"github.com/antoniosarro/rdplauncher/internal/registry"
	"github.com/antoniosarro/rdplauncher/internal/server"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// windowsService implements the Windows service interface
type windowsService struct {
	config *config.Config
	logger *logger.Logger
	server *server.Server
}

// Execute runs the service
func (s *windowsService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (ssec bool, errno uint32) {
	const cmdsAccepted = svc.AcceptStop | svc.AcceptShutdown

	changes <- svc.Status{State: svc.StartPending}
	s.logger.Info("Service starting")

	// Start HTTP server in goroutine
	errChan := make(chan error, 1)
	go func() {
		if err := s.server.Start(); err != nil {
			s.logger.Error("Server error", "error", err)
			errChan <- err
		}
	}()

	changes <- svc.Status{State: svc.Running, Accepts: cmdsAccepted}
	s.logger.Info("Service running")

	// Service control loop
loop:
	for {
		select {
		case err := <-errChan:
			s.logger.Error("Server failed", "error", err)
			break loop

		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				changes <- c.CurrentStatus

			case svc.Stop, svc.Shutdown:
				s.logger.Info("Service stop requested")

				// Graceful shutdown
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer cancel()

				if err := s.server.Shutdown(ctx); err != nil {
					s.logger.Error("Error during server shutdown", "error", err)
				}

				break loop

			default:
				s.logger.Warn("Unexpected service control request", "cmd", c.Cmd)
			}
		}
	}

	changes <- svc.Status{State: svc.StopPending}
	s.logger.Info("Service stopped")

	return false, 0
}

// Run starts the service
func Run(name string, cfg *config.Config, log *logger.Logger) error {
	srv := &windowsService{
		config: cfg,
		logger: log,
		server: server.New(cfg.ServerPort, log),
	}

	return svc.Run(name, srv)
}

// RunDebug runs the service in debug mode
func RunDebug(name string, cfg *config.Config, log *logger.Logger) error {
	log.Info("Starting in debug mode", "name", name, "port", cfg.ServerPort)

	// Create the server
	srv := server.New(cfg.ServerPort, log)

	// Handle graceful shutdown with Ctrl+C
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	// Start server in goroutine
	errChan := make(chan error, 1)
	go func() {
		log.Info("HTTP server starting")
		if err := srv.Start(); err != nil {
			errChan <- err
		}
	}()

	log.Info("Server running. Press Ctrl+C to stop")

	// Wait for shutdown signal or error
	select {
	case err := <-errChan:
		return fmt.Errorf("server error: %w", err)
	case sig := <-sigChan:
		log.Info("Received shutdown signal", "signal", sig)

		// Graceful shutdown
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if err := srv.Shutdown(ctx); err != nil {
			log.Error("Error during shutdown", "error", err)
			return err
		}

		log.Info("Server stopped gracefully")
	}

	return nil
}

// Install installs the Windows service
func Install(name, desc string, log *logger.Logger) error {
	exepath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("failed to get executable path: %w", err)
	}

	log.Info("Installing service", "name", name, "path", exepath)

	// Create configuration and registry manager
	cfg := config.New()

	// Ensure data directory exists
	if err := os.MkdirAll(cfg.DataDirectory, 0755); err != nil {
		return fmt.Errorf("failed to create data directory: %w", err)
	}

	port, _ := strconv.ParseUint(cfg.ServerPort, 10, 32)
	regMgr := registry.NewManager(cfg.InstallPath, uint32(port), cfg.DataDirectory)

	// Create registry entries (backups are automatically saved)
	log.Info("Creating registry entries")
	backups, err := regMgr.CreateAll()
	if err != nil {
		log.Warn("Some registry entries failed to create", "error", err)
	} else {
		log.Info("Registry entries created and backed up", "count", len(backups))
	}

	// Connect to service manager
	m, err := mgr.Connect()
	if err != nil {
		log.Error("Failed to connect to service manager, rolling back", "error", err)
		regMgr.RemoveAll()
		return fmt.Errorf("failed to connect to service manager: %w", err)
	}
	defer m.Disconnect()

	// Check if service already exists
	s, err := m.OpenService(name)
	if err == nil {
		s.Close()
		log.Error("Service already exists, rolling back")
		regMgr.RemoveAll()
		return fmt.Errorf("service %s already exists", name)
	}

	// Create service
	s, err = m.CreateService(name, exepath, mgr.Config{
		DisplayName: name,
		Description: desc,
		StartType:   mgr.StartAutomatic,
	})
	if err != nil {
		log.Error("Failed to create service, rolling back", "error", err)
		regMgr.RemoveAll()
		return fmt.Errorf("failed to create service: %w", err)
	}
	defer s.Close()

	log.Info("Service created successfully")

	// Start the service
	if err = s.Start(); err != nil {
		log.Warn("Service created but failed to start", "error", err)
	} else {
		log.Info("Service started successfully")
	}

	return nil
}

// Remove uninstalls the Windows service
func Remove(name string, log *logger.Logger) error {
	log.Info("Removing service", "name", name)

	// Connect to service manager
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("failed to connect to service manager: %w", err)
	}
	defer m.Disconnect()

	// Open service
	s, err := m.OpenService(name)
	if err != nil {
		return fmt.Errorf("service %s is not installed: %w", name, err)
	}
	defer s.Close()

	// Stop service
	log.Info("Stopping service")
	status, err := s.Control(svc.Stop)
	if err != nil {
		log.Warn("Failed to stop service", "error", err)
	} else {
		log.Debug("Service stop initiated", "state", status.State)
	}

	// Wait for service to stop
	timeout := time.Now().Add(30 * time.Second)
	for status.State != svc.Stopped {
		if time.Now().After(timeout) {
			log.Warn("Service did not stop within timeout")
			break
		}
		time.Sleep(500 * time.Millisecond)
		status, err = s.Query()
		if err != nil {
			log.Warn("Failed to query service status", "error", err)
			break
		}
	}

	// Delete service
	log.Info("Deleting service")
	if err = s.Delete(); err != nil {
		return fmt.Errorf("failed to delete service: %w", err)
	}
	log.Info("Service deleted successfully")

	// Remove registry entries (will restore from backup)
	log.Info("Restoring registry entries from backup")
	cfg := config.New()
	port, _ := strconv.ParseUint(cfg.ServerPort, 10, 32)
	regMgr := registry.NewManager(cfg.InstallPath, uint32(port), cfg.DataDirectory)

	if err = regMgr.RemoveAll(); err != nil {
		log.Warn("Some registry entries failed to restore", "error", err)
	} else {
		log.Info("Registry entries restored from backup successfully")
	}

	return nil
}

// Start starts an installed service
func Start(name string, log *logger.Logger) error {
	log.Info("Starting service", "name", name)

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("failed to connect to service manager: %w", err)
	}
	defer m.Disconnect()

	s, err := m.OpenService(name)
	if err != nil {
		return fmt.Errorf("could not access service: %w", err)
	}
	defer s.Close()

	err = s.Start()
	if err != nil {
		return fmt.Errorf("could not start service: %w", err)
	}

	log.Info("Service started successfully")
	return nil
}

// Stop stops a running service
func Stop(name string, log *logger.Logger) error {
	log.Info("Stopping service", "name", name)

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("failed to connect to service manager: %w", err)
	}
	defer m.Disconnect()

	s, err := m.OpenService(name)
	if err != nil {
		return fmt.Errorf("could not access service: %w", err)
	}
	defer s.Close()

	status, err := s.Control(svc.Stop)
	if err != nil {
		return fmt.Errorf("could not send stop control: %w", err)
	}

	log.Info("Stop signal sent", "state", status.State)

	// Wait for service to stop
	timeout := time.Now().Add(30 * time.Second)
	for status.State != svc.Stopped {
		if time.Now().After(timeout) {
			return fmt.Errorf("service did not stop within timeout")
		}
		time.Sleep(500 * time.Millisecond)
		status, err = s.Query()
		if err != nil {
			return fmt.Errorf("could not query service status: %w", err)
		}
	}

	log.Info("Service stopped successfully")
	return nil
}

// ShowBackups displays the current registry backup
func ShowBackups(log *logger.Logger) error {
	cfg := config.New()
	port, _ := strconv.ParseUint(cfg.ServerPort, 10, 32)
	regMgr := registry.NewManager(cfg.InstallPath, uint32(port), cfg.DataDirectory)

	backups, err := regMgr.LoadBackups()
	if err != nil {
		return fmt.Errorf("failed to load backups: %w", err)
	}

	fmt.Printf("\nRegistry Backups (%d entries):\n", len(backups))
	fmt.Println(strings.Repeat("=", 80))

	for i, backup := range backups {
		fmt.Printf("\n%d. %s\\%s\n", i+1, backup.Entry.Path, backup.Entry.Name)
		fmt.Printf("   Existed: %v\n", backup.Existed)
		if backup.Existed && backup.Entry.Value != nil {
			fmt.Printf("   Original Value: %v\n", backup.Entry.Value)
		}
		fmt.Printf("   Type: %d\n", backup.Entry.Type)
	}

	fmt.Println()
	return nil
}

// RestoreBackupsManually manually restores registry from backup
func RestoreBackupsManually(log *logger.Logger) error {
	cfg := config.New()
	port, _ := strconv.ParseUint(cfg.ServerPort, 10, 32)
	regMgr := registry.NewManager(cfg.InstallPath, uint32(port), cfg.DataDirectory)

	log.Info("Loading registry backups")
	backups, err := regMgr.LoadBackups()
	if err != nil {
		return fmt.Errorf("failed to load backups: %w", err)
	}

	log.Info("Restoring registry entries", "count", len(backups))
	if err := regMgr.Restore(backups); err != nil {
		return fmt.Errorf("failed to restore: %w", err)
	}

	log.Info("Registry restored successfully")
	return nil
}
