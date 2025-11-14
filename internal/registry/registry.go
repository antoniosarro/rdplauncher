package registry

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows/registry"
)

// Entry represents a Windows registry entry
type Entry struct {
	Root  registry.Key
	Path  string
	Name  string
	Value interface{}
	Type  uint32
}

// Backup stores information about a registry entry for restoration
type Backup struct {
	Entry   Entry
	Existed bool
}

// SerializableBackup is a JSON-serializable version of Backup
type SerializableBackup struct {
	RootKey uint32      `json:"root_key"`
	Path    string      `json:"path"`
	Name    string      `json:"name"`
	Value   interface{} `json:"value"`
	Type    uint32      `json:"type"`
	Existed bool        `json:"existed"`
}

// Manager handles Windows registry operations
type Manager struct {
	entries    []Entry
	backupPath string
}

// NewManager creates a new registry manager with RDP-specific entries
func NewManager(installPath string, serverPort uint32, dataDir string) *Manager {
	return &Manager{
		entries: []Entry{
			// Service configuration entries
			{
				Root:  registry.LOCAL_MACHINE,
				Path:  `SOFTWARE\RDPLauncher`,
				Name:  "InstallPath",
				Value: installPath,
				Type:  registry.SZ,
			},
			{
				Root:  registry.LOCAL_MACHINE,
				Path:  `SOFTWARE\RDPLauncher`,
				Name:  "ServerPort",
				Value: serverPort,
				Type:  registry.DWORD,
			},
			{
				Root:  registry.LOCAL_MACHINE,
				Path:  `SOFTWARE\RDPLauncher`,
				Name:  "EnableLogging",
				Value: uint32(1),
				Type:  registry.DWORD,
			},

			// RDP Configuration: Disable RemoteApp allowlist
			{
				Root:  registry.LOCAL_MACHINE,
				Path:  `SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList`,
				Name:  "fDisabledAllowList",
				Value: uint32(1),
				Type:  registry.DWORD,
			},

			// RDP Configuration: Allow unlisted programs
			{
				Root:  registry.LOCAL_MACHINE,
				Path:  `SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`,
				Name:  "fAllowUnlistedRemotePrograms",
				Value: uint32(1),
				Type:  registry.DWORD,
			},

			// Security: Disable automatic administrator logon
			{
				Root:  registry.LOCAL_MACHINE,
				Path:  `SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`,
				Name:  "AutoAdminLogon",
				Value: "0",
				Type:  registry.SZ,
			},

			// Keyboard Layout: Always use server's keyboard layout
			{
				Root:  registry.LOCAL_MACHINE,
				Path:  `SYSTEM\CurrentControlSet\Control\Keyboard Layout`,
				Name:  "IgnoreRemoteKeyboardLayout",
				Value: uint32(1),
				Type:  registry.DWORD,
			},

			// Network Discovery: Disable network discovery prompt
			{
				Root:  registry.LOCAL_MACHINE,
				Path:  `SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff`,
				Name:  "",
				Value: "",
				Type:  registry.SZ,
			},

			// User-specific: Last run timestamp
			{
				Root:  registry.CURRENT_USER,
				Path:  `SOFTWARE\RDPLauncher\User`,
				Name:  "LastRun",
				Value: "",
				Type:  registry.SZ,
			},
		},
		backupPath: filepath.Join(dataDir, "registry_backup.json"),
	}
}

// CreateAll creates or updates all registry entries and saves backups
func (m *Manager) CreateAll() ([]Backup, error) {
	var backups []Backup
	var errors []error

	for _, entry := range m.entries {
		backup, err := m.create(entry)
		if err != nil {
			errors = append(errors, fmt.Errorf("failed to create %s\\%s: %w", entry.Path, entry.Name, err))
			continue
		}
		backups = append(backups, backup)
	}

	// Save backups to file
	if err := m.SaveBackups(backups); err != nil {
		return backups, fmt.Errorf("failed to save backups: %w", err)
	}

	if len(errors) > 0 {
		return backups, fmt.Errorf("encountered %d errors during registry creation", len(errors))
	}

	return backups, nil
}

// SaveBackups saves registry backups to a JSON file
func (m *Manager) SaveBackups(backups []Backup) error {
	// Ensure backup directory exists
	backupDir := filepath.Dir(m.backupPath)
	if err := os.MkdirAll(backupDir, 0755); err != nil {
		return fmt.Errorf("failed to create backup directory: %w", err)
	}

	// Convert to serializable format
	serializableBackups := make([]SerializableBackup, len(backups))
	for i, backup := range backups {
		serializableBackups[i] = SerializableBackup{
			RootKey: uint32(backup.Entry.Root),
			Path:    backup.Entry.Path,
			Name:    backup.Entry.Name,
			Value:   backup.Entry.Value,
			Type:    backup.Entry.Type,
			Existed: backup.Existed,
		}
	}

	// Marshal to JSON
	data, err := json.MarshalIndent(serializableBackups, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal backups: %w", err)
	}

	// Write to file
	if err := os.WriteFile(m.backupPath, data, 0600); err != nil {
		return fmt.Errorf("failed to write backup file: %w", err)
	}

	return nil
}

// LoadBackups loads registry backups from a JSON file
func (m *Manager) LoadBackups() ([]Backup, error) {
	// Check if backup file exists
	if _, err := os.Stat(m.backupPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("backup file not found: %s", m.backupPath)
	}

	// Read backup file
	data, err := os.ReadFile(m.backupPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read backup file: %w", err)
	}

	// Unmarshal JSON
	var serializableBackups []SerializableBackup
	if err := json.Unmarshal(data, &serializableBackups); err != nil {
		return nil, fmt.Errorf("failed to unmarshal backups: %w", err)
	}

	// Convert to Backup format
	backups := make([]Backup, len(serializableBackups))
	for i, sb := range serializableBackups {
		backups[i] = Backup{
			Entry: Entry{
				Root:  registry.Key(sb.RootKey),
				Path:  sb.Path,
				Name:  sb.Name,
				Value: sb.Value,
				Type:  sb.Type,
			},
			Existed: sb.Existed,
		}
	}

	return backups, nil
}

// DeleteBackupFile removes the backup file
func (m *Manager) DeleteBackupFile() error {
	if err := os.Remove(m.backupPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to delete backup file: %w", err)
	}
	return nil
}

// create creates or updates a single registry entry
func (m *Manager) create(entry Entry) (Backup, error) {
	backup := Backup{Entry: entry}

	// Try to read existing value for backup
	k, err := registry.OpenKey(entry.Root, entry.Path, registry.QUERY_VALUE)
	if err == nil {
		backup.Existed = true

		// Only backup if the value name is not empty
		if entry.Name != "" {
			backup.Entry.Value = m.readValue(k, entry.Name, entry.Type)
		}
		k.Close()
	}

	// Create or open the key with write access
	k, _, err = registry.CreateKey(entry.Root, entry.Path, registry.SET_VALUE)
	if err != nil {
		return backup, fmt.Errorf("failed to create key: %w", err)
	}
	defer k.Close()

	// Write the value (only if name is not empty)
	if entry.Name != "" {
		if err := m.writeValue(k, entry.Name, entry.Value, entry.Type); err != nil {
			return backup, fmt.Errorf("failed to write value: %w", err)
		}
	}

	return backup, nil
}

// readValue reads a registry value based on its type
func (m *Manager) readValue(k registry.Key, name string, valueType uint32) interface{} {
	switch valueType {
	case registry.SZ, registry.EXPAND_SZ:
		if val, _, err := k.GetStringValue(name); err == nil {
			return val
		}
	case registry.DWORD:
		if val, _, err := k.GetIntegerValue(name); err == nil {
			return uint32(val)
		}
	case registry.QWORD:
		if val, _, err := k.GetIntegerValue(name); err == nil {
			return uint64(val)
		}
	case registry.BINARY:
		if val, _, err := k.GetBinaryValue(name); err == nil {
			return val
		}
	}
	return nil
}

// writeValue writes a registry value based on its type
func (m *Manager) writeValue(k registry.Key, name string, value interface{}, valueType uint32) error {
	switch valueType {
	case registry.SZ:
		strVal, ok := value.(string)
		if !ok {
			return fmt.Errorf("invalid type for SZ value")
		}
		return k.SetStringValue(name, strVal)

	case registry.EXPAND_SZ:
		strVal, ok := value.(string)
		if !ok {
			return fmt.Errorf("invalid type for EXPAND_SZ value")
		}
		return k.SetExpandStringValue(name, strVal)

	case registry.DWORD:
		intVal, ok := value.(uint32)
		if !ok {
			return fmt.Errorf("invalid type for DWORD value")
		}
		return k.SetDWordValue(name, intVal)

	case registry.QWORD:
		intVal, ok := value.(uint64)
		if !ok {
			return fmt.Errorf("invalid type for QWORD value")
		}
		return k.SetQWordValue(name, intVal)

	case registry.BINARY:
		binVal, ok := value.([]byte)
		if !ok {
			return fmt.Errorf("invalid type for BINARY value")
		}
		return k.SetBinaryValue(name, binVal)

	default:
		return fmt.Errorf("unsupported registry value type: %d", valueType)
	}
}

// RemoveAll removes all registry entries and restores original values from backup
func (m *Manager) RemoveAll() error {
	var errors []error

	// Try to load backups
	backups, err := m.LoadBackups()
	if err != nil {
		// No backup file - just remove service-specific entries
		for _, entry := range m.entries {
			if entry.Name != "" {
				if err := m.removeValue(entry.Root, entry.Path, entry.Name); err != nil {
					errors = append(errors, err)
				}
			}
		}
	} else {
		// Restore from backups
		if err := m.Restore(backups); err != nil {
			errors = append(errors, fmt.Errorf("failed to restore backups: %w", err))
		}
	}

	// Remove empty service-specific keys
	serviceSpecificPaths := map[string]bool{
		`SOFTWARE\RDPLauncher`:      true,
		`SOFTWARE\RDPLauncher\User`: true,
	}

	processedPaths := make(map[string]bool)
	for _, entry := range m.entries {
		keyPath := fmt.Sprintf("%v\\%s", entry.Root, entry.Path)
		if !processedPaths[keyPath] && serviceSpecificPaths[entry.Path] {
			processedPaths[keyPath] = true
			if err := m.removeEmptyKey(entry.Root, entry.Path); err != nil {
				errors = append(errors, err)
			}
		}
	}

	// Delete backup file
	if err := m.DeleteBackupFile(); err != nil {
		errors = append(errors, fmt.Errorf("failed to delete backup file: %w", err))
	}

	if len(errors) > 0 {
		return fmt.Errorf("encountered %d errors during registry cleanup", len(errors))
	}

	return nil
}

// removeValue removes a single registry value
func (m *Manager) removeValue(root registry.Key, path, name string) error {
	k, err := registry.OpenKey(root, path, registry.SET_VALUE)
	if err != nil {
		return nil // Key doesn't exist
	}
	defer k.Close()

	err = k.DeleteValue(name)
	if err != nil && err != registry.ErrNotExist {
		return fmt.Errorf("failed to delete %s\\%s: %w", path, name, err)
	}

	return nil
}

// removeEmptyKey removes a registry key if it has no values
func (m *Manager) removeEmptyKey(root registry.Key, path string) error {
	k, err := registry.OpenKey(root, path, registry.QUERY_VALUE)
	if err != nil {
		return nil // Key doesn't exist
	}

	valueNames, err := k.ReadValueNames(0)
	k.Close()

	if err != nil || len(valueNames) > 0 {
		return nil // Key has values, don't remove
	}

	err = registry.DeleteKey(root, path)
	if err != nil && err != registry.ErrNotExist {
		return fmt.Errorf("failed to delete key %s: %w", path, err)
	}

	return nil
}

// Restore restores registry entries from backups
func (m *Manager) Restore(backups []Backup) error {
	var errors []error

	for _, backup := range backups {
		if err := m.restore(backup); err != nil {
			errors = append(errors, err)
		}
	}

	if len(errors) > 0 {
		return fmt.Errorf("encountered %d errors during registry restoration", len(errors))
	}

	return nil
}

// restore restores a single registry entry
func (m *Manager) restore(backup Backup) error {
	if !backup.Existed {
		// Value didn't exist before, remove it
		if backup.Entry.Name != "" {
			return m.removeValue(backup.Entry.Root, backup.Entry.Path, backup.Entry.Name)
		}
		return nil
	}

	// Restore previous value
	k, _, err := registry.CreateKey(backup.Entry.Root, backup.Entry.Path, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("failed to open key %s: %w", backup.Entry.Path, err)
	}
	defer k.Close()

	if backup.Entry.Name != "" && backup.Entry.Value != nil {
		return m.writeValue(k, backup.Entry.Name, backup.Entry.Value, backup.Entry.Type)
	}

	return nil
}
