package main

import (
	"fmt"
	"os"

	"github.com/antoniosarro/rdplauncher/internal/config"
	"github.com/antoniosarro/rdplauncher/internal/logger"
	"github.com/antoniosarro/rdplauncher/internal/service"
	"golang.org/x/sys/windows/svc"
)

const (
	serviceName = "RDPLauncher"
	serviceDesc = "Go Web Server with PowerShell Integration"
)

func main() {
	// Initialize configuration
	cfg := config.New()

	// Initialize logger
	log, err := logger.New(cfg.LogPath, string(cfg.Environment))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Close()

	// First check if we have command line arguments
	// If we do, we're in interactive mode
	if len(os.Args) >= 2 {
		handleCommand(os.Args[1], cfg, log)
		return
	}

	// No arguments - check if we're running as a Windows service
	isService, err := svc.IsWindowsService()
	if err != nil {
		log.Fatal("Failed to determine if running as Windows service", "error", err)
	}

	if isService {
		// Running as a Windows service (started by SCM)
		log.Info("Running as Windows service")
		if err := service.Run(serviceName, cfg, log); err != nil {
			log.Fatal("Service execution failed", "error", err)
		}
	} else {
		// No arguments and not a service - show usage
		usage()
	}
}

// handleCommand processes command-line commands
func handleCommand(cmd string, cfg *config.Config, log *logger.Logger) {
	switch cmd {
	case "install":
		if err := service.Install(serviceName, serviceDesc, log); err != nil {
			log.Fatal("Failed to install service", "error", err)
		}
		fmt.Printf("Service %s installed successfully\n", serviceName)

	case "remove", "uninstall":
		if err := service.Remove(serviceName, log); err != nil {
			log.Fatal("Failed to remove service", "error", err)
		}
		fmt.Printf("Service %s removed successfully\n", serviceName)

	case "start":
		if err := service.Start(serviceName, log); err != nil {
			log.Fatal("Failed to start service", "error", err)
		}
		fmt.Printf("Service %s started successfully\n", serviceName)

	case "stop":
		if err := service.Stop(serviceName, log); err != nil {
			log.Fatal("Failed to stop service", "error", err)
		}
		fmt.Printf("Service %s stopped successfully\n", serviceName)

	case "debug":
		log.Info("Starting service in debug mode (foreground)")
		if err := service.RunDebug(serviceName, cfg, log); err != nil {
			log.Fatal("Debug mode failed", "error", err)
		}

	case "show-backups":
		if err := service.ShowBackups(log); err != nil {
			log.Fatal("Failed to show backups", "error", err)
		}

	case "restore-backups":
		if err := service.RestoreBackupsManually(log); err != nil {
			log.Fatal("Failed to restore backups", "error", err)
		}
		fmt.Println("Registry backups restored successfully")

	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n\n", cmd)
		usage()
		os.Exit(1)
	}
}

// usage prints the command-line usage information
func usage() {
	fmt.Fprintf(os.Stderr, "Usage: %s <command>\n", os.Args[0])
	fmt.Fprintf(os.Stderr, "\nCommands:\n")
	fmt.Fprintf(os.Stderr, "  install   - Install the service\n")
	fmt.Fprintf(os.Stderr, "  remove    - Remove the service\n")
	fmt.Fprintf(os.Stderr, "  start     - Start the service\n")
	fmt.Fprintf(os.Stderr, "  stop      - Stop the service\n")
	fmt.Fprintf(os.Stderr, "  debug     - Run in debug mode (foreground)\n")
}
