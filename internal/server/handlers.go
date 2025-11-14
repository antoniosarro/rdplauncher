package server

import (
	"context"
	"encoding/json"
	"net/http"
	"os/exec"
	"time"

	"github.com/antoniosarro/rdplauncher/internal/scripts"
)

// Application represents a discovered application
type Application struct {
	Name   string `json:"name"`
	Path   string `json:"path"`
	Args   string `json:"args"`
	Icon   string `json:"icon"`   // Base64 PNG
	Source string `json:"source"` // system, winreg, startmenu, uwp, choco, scoop
}

// handleHealth responds to health check requests
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.logger.Debug("Health check requested", "remote_addr", r.RemoteAddr)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	response := map[string]string{
		"status":  "ok",
		"service": "RDPLauncher",
	}

	json.NewEncoder(w).Encode(response)
}

// handleSystemInfo executes a PowerShell script and returns system information
func (s *Server) handleSystemInfo(w http.ResponseWriter, r *http.Request) {
	s.logger.Info("System info requested", "remote_addr", r.RemoteAddr)

	// Read the embedded PowerShell script
	scriptContent, err := scripts.FS.ReadFile("system_info.ps1")
	if err != nil {
		s.logger.Error("Failed to read PowerShell script", "error", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Execute PowerShell script
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", string(scriptContent))
	output, err := cmd.CombinedOutput()
	if err != nil {
		s.logger.Error("Failed to execute PowerShell script",
			"error", err,
			"output", string(output))
		http.Error(w, "Failed to execute system info script", http.StatusInternalServerError)
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal(output, &result); err != nil {
		s.logger.Error("Failed to parse PowerShell output",
			"error", err,
			"output", string(output))
		http.Error(w, "Failed to parse system info", http.StatusInternalServerError)
		return
	}

	// Return JSON response
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(result); err != nil {
		s.logger.Error("Failed to encode response", "error", err)
	}

	s.logger.Debug("System info request completed successfully")
}

// handleApps discovers and returns installed applications
func (s *Server) handleApps(w http.ResponseWriter, r *http.Request) {
	s.logger.Info("Apps discovery requested", "remote_addr", r.RemoteAddr)

	// Read the embedded PowerShell script
	scriptContent, err := scripts.FS.ReadFile("discover_apps.ps1")
	if err != nil {
		s.logger.Error("Failed to read app discovery script", "error", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Execute PowerShell script with timeout
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "powershell",
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-Command", string(scriptContent))

	output, err := cmd.CombinedOutput()
	if err != nil {
		s.logger.Error("Failed to execute app discovery script",
			"error", err,
			"output", string(output))
		http.Error(w, "Failed to discover applications", http.StatusInternalServerError)
		return
	}

	// Parse JSON output
	var apps []Application
	if err := json.Unmarshal(output, &apps); err != nil {
		s.logger.Error("Failed to parse app discovery output",
			"error", err,
			"output", string(output))
		http.Error(w, "Failed to parse application list", http.StatusInternalServerError)
		return
	}

	s.logger.Info("Apps discovered successfully", "count", len(apps))

	// Return JSON response
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(apps); err != nil {
		s.logger.Error("Failed to encode apps response", "error", err)
	}

	s.logger.Debug("Apps discovery request completed successfully", "app_count", len(apps))
}
