#!/usr/bin/env bash
# rdp-launcher-rofi.sh - Multi-step Rofi menu for RDP Launcher
# Optimized with caching and icon deduplication

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rdp-launcher"
readonly CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rdp-launcher"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly STATE_FILE="$CACHE_DIR/state.json"
readonly APPS_CACHE="$CACHE_DIR/apps.json"
readonly ICONS_DIR="$CACHE_DIR/icons"
readonly ICON_MAP="$CACHE_DIR/icon_map.json"

readonly LOG_LEVEL="${RDP_LOG_LEVEL:-ERROR}"
readonly CLOSE_AFTER_LAUNCH="${RDP_CLOSE_AFTER_LAUNCH:-true}"

# Rofi configuration
readonly ROFI_THEME="${ROFI_THEME:-$HOME/.config/rofi/rdp-launcher.rasi}"
readonly ROFI_PROMPT_HOST="Select Host"
readonly ROFI_PROMPT_ACTION="Actions"
readonly ROFI_PROMPT_APP="Applications"

# ============================================================================
# Logging
# ============================================================================

log_debug() { [[ "$LOG_LEVEL" == "DEBUG" ]] && echo "[DEBUG] $*" >&2 || true; }
log_info() { [[ "$LOG_LEVEL" =~ ^(DEBUG|INFO)$ ]] && echo "[INFO] $*" >&2 || true; }
log_error() { echo "[ERROR] $*" >&2; }

# ============================================================================
# Utilities
# ============================================================================

die() {
    log_error "$@"
    if command -v notify-send &>/dev/null; then
        notify-send -u critical "RDP Launcher Error" "$*"
    fi
    exit 1
}

check_dependencies() {
    local missing=()
    for cmd in jq curl xfreerdp rofi; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}"
    fi
}

init_directories() {
    mkdir -p "$CONFIG_DIR" "$CACHE_DIR" "$ICONS_DIR"
}

# ============================================================================
# Rofi Helper
# ============================================================================

rofi_menu() {
    local prompt="$1"
    shift
    
    local rofi_cmd=(
        rofi
        -dmenu
        -i
        -p "$prompt"
        -format "i:s"
        -no-custom
    )
    
    [[ -n "$ROFI_THEME" ]] && rofi_cmd+=(-theme "$ROFI_THEME")
    
    printf '%s\n' "$@" | "${rofi_cmd[@]}"
}

rofi_menu_with_icons() {
    local prompt="$1"
    shift
    
    local rofi_cmd=(
        rofi
        -dmenu
        -i
        -p "$prompt"
        -format "i:s"
        -no-custom
        -show-icons
    )
    
    [[ -n "$ROFI_THEME" ]] && rofi_cmd+=(-theme "$ROFI_THEME")
    
    printf '%s\n' "$@" | "${rofi_cmd[@]}"
}

# ============================================================================
# Icon Management with Deduplication
# ============================================================================

# Generate hash from base64 content (for deduplication)
hash_icon_content() {
    local base64_data="$1"
    echo -n "$base64_data" | sha256sum | cut -d' ' -f1
}

# Get or create icon file from base64 data
get_or_create_icon() {
    local base64_data="$1"
    
    # Skip empty/null data
    if [[ -z "$base64_data" ]] || [[ "$base64_data" == "null" ]]; then
        return 1
    fi
    
    # Generate content hash
    local content_hash
    content_hash=$(hash_icon_content "$base64_data")
    
    local icon_path="$ICONS_DIR/${content_hash}.png"
    
    # Return path if icon already exists
    if [[ -f "$icon_path" ]]; then
        echo "$icon_path"
        return 0
    fi
    
    # Create icon file
    if echo "$base64_data" | base64 -d > "$icon_path" 2>/dev/null; then
        # Verify it's a valid PNG
        if file "$icon_path" 2>/dev/null | grep -q "PNG image"; then
            log_debug "Created deduplicated icon: $content_hash"
            echo "$icon_path"
            return 0
        else
            rm -f "$icon_path"
            return 1
        fi
    fi
    
    return 1
}

# Update icon map with deduplication
update_icon_map() {
    local host_index="$1"
    
    if [[ ! -f "$APPS_CACHE" ]]; then
        return 1
    fi
    
    log_info "Updating icon map with deduplication for host $host_index"
    
    # Initialize icon map if it doesn't exist
    if [[ ! -f "$ICON_MAP" ]]; then
        echo '{}' > "$ICON_MAP"
    fi
    
    local app_count
    app_count=$(jq 'length' "$APPS_CACHE")
    
    local icon_map='{}'
    
    for ((i = 0; i < app_count; i++)); do
        local icon_data
        icon_data=$(jq -r ".[$i].icon // empty" "$APPS_CACHE")
        
        if [[ -n "$icon_data" ]] && [[ "$icon_data" != "null" ]]; then
            local icon_path
            if icon_path=$(get_or_create_icon "$icon_data"); then
                # Store mapping: host_index-app_index -> icon_path
                icon_map=$(echo "$icon_map" | jq \
                    --arg key "${host_index}-${i}" \
                    --arg path "$icon_path" \
                    '. + {($key): $path}')
            fi
        fi
    done
    
    # Merge with existing icon map
    if [[ -f "$ICON_MAP" ]]; then
        local existing_map
        existing_map=$(cat "$ICON_MAP")
        icon_map=$(jq -s '.[0] * .[1]' <(echo "$existing_map") <(echo "$icon_map"))
    fi
    
    echo "$icon_map" > "$ICON_MAP"
    log_info "Icon map updated"
}

get_app_icon() {
    local host_index="$1"
    local app_index="$2"
    
    if [[ ! -f "$ICON_MAP" ]]; then
        return 1
    fi
    
    local key="${host_index}-${app_index}"
    local icon_path
    icon_path=$(jq -r --arg k "$key" '.[$k] // empty' "$ICON_MAP")
    
    if [[ -n "$icon_path" ]] && [[ -f "$icon_path" ]]; then
        echo "$icon_path"
        return 0
    fi
    
    return 1
}

# ============================================================================
# Configuration Management
# ============================================================================

validate_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        return 1
    fi
    
    local host_count
    host_count=$(jq '.rdp_hosts | length' "$CONFIG_FILE")
    
    [[ "$host_count" -gt 0 ]]
}

get_host_count() {
    jq '.rdp_hosts | length' "$CONFIG_FILE"
}

get_host_field() {
    local index="$1"
    local field="$2"
    jq -r ".rdp_hosts[$index].$field // empty" "$CONFIG_FILE"
}

# ============================================================================
# State Management
# ============================================================================

get_current_host_index() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi
    jq -r '.current_host // empty' "$STATE_FILE" 2>/dev/null || return 1
}

set_current_host() {
    local index="$1"
    local name="$2"
    
    jq -n \
        --arg idx "$index" \
        --arg name "$name" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{current_host: $idx, current_host_name: $name, last_update: $ts}' \
        > "$STATE_FILE"
}

clear_current_host() {
    rm -f "$STATE_FILE"
}

# ============================================================================
# API Communication
# ============================================================================

check_service_health() {
    local host="$1"
    local port="$2"
    
    curl -sf --connect-timeout 3 --max-time 5 \
        "http://${host}:${port}/health" >/dev/null 2>&1
}

fetch_apps_from_service() {
    local host="$1"
    local port="$2"
    local url="http://${host}:${port}/api/apps"
    
    log_info "Fetching apps from $url"
    
    if curl -sf --connect-timeout 10 --max-time 30 "$url" -o "$APPS_CACHE.tmp" 2>/dev/null; then
        if jq empty "$APPS_CACHE.tmp" 2>/dev/null; then
            mv "$APPS_CACHE.tmp" "$APPS_CACHE"
            log_info "Apps fetched successfully"
            return 0
        fi
    fi
    
    rm -f "$APPS_CACHE.tmp"
    return 1
}

# ============================================================================
# Application Management
# ============================================================================

get_app_count() {
    if [[ ! -f "$APPS_CACHE" ]]; then
        echo "0"
        return
    fi
    jq 'length' "$APPS_CACHE" 2>/dev/null || echo "0"
}

get_app_field() {
    local index="$1"
    local field="$2"
    jq -r ".[$index].$field // empty" "$APPS_CACHE" 2>/dev/null || echo ""
}

# ============================================================================
# RDP Launch
# ============================================================================

launch_app() {
    local host_index="$1"
    local app_index="$2"
    
    log_info "Launching app $app_index from host $host_index"
    
    # Get host config
    local host port username domain password
    host=$(get_host_field "$host_index" "host")
    port=$(get_host_field "$host_index" "port")
    username=$(get_host_field "$host_index" "username")
    domain=$(get_host_field "$host_index" "domain")
    password=$(get_host_field "$host_index" "password")
    
    # Get app details
    local app_name app_path app_args
    app_name=$(get_app_field "$app_index" "name")
    app_path=$(get_app_field "$app_index" "path")
    app_args=$(get_app_field "$app_index" "args")
    
    [[ "$app_args" == "null" ]] && app_args=""
    
    if [[ -z "$app_name" ]] || [[ -z "$app_path" ]]; then
        die "Invalid app at index $app_index"
    fi
    
    # Build xfreerdp command
    local cmd=(
        xfreerdp
        "/v:${host}:${port}"
        "/u:${username}"
    )
    
    [[ -n "$domain" ]] && [[ "$domain" != "null" ]] && cmd+=("/d:${domain}")
    [[ -n "$password" ]] && [[ "$password" != "null" ]] && cmd+=("/p:${password}")
    
    # Add options from config
    mapfile -t opts < <(jq -r '.xfreerdp_options[]' "$CONFIG_FILE")
    cmd+=("${opts[@]}")
    
    # Add RemoteApp config
    local clean_name="${app_name//[^a-zA-Z0-9 -]/-}"
    cmd+=("/wm-class:rdplauncher-${clean_name}")
    
    local app_param="/app:program:\"${app_path}\""
    [[ -n "$app_args" ]] && app_param="${app_param},args:\"${app_args}\""
    cmd+=("${app_param}")
    
    # Launch
    if command -v notify-send &>/dev/null; then
        notify-send "RDP Launcher" "Launching $app_name..."
    fi
    
    "${cmd[@]}" </dev/null >/dev/null 2>&1 &
    disown
    
    log_info "Launched: $app_name"
}

# ============================================================================
# Menu Screens
# ============================================================================

menu_select_host() {
    local host_count
    host_count=$(get_host_count)
    
    if [[ "$host_count" -eq 0 ]]; then
        die "No RDP hosts configured in $CONFIG_FILE"
    fi
    
    # Build host entries
    local -a entries=()
    local -a display_entries=()
    
    for ((i = 0; i < host_count; i++)); do
        local name host port
        name=$(get_host_field "$i" "name")
        host=$(get_host_field "$i" "host")
        port=$(get_host_field "$i" "port")
        
        entries+=("$i")
        display_entries+=("$name  -  ${host}:${port}")
    done
    
    # Show menu
    local selection
    if ! selection=$(rofi_menu "$ROFI_PROMPT_HOST" "${display_entries[@]}" | cut -d: -f1); then
        return 1
    fi
    
    # Get the selected index
    local selected_index="${entries[$selection]}"
    
    # Set current host
    local host_name
    host_name=$(get_host_field "$selected_index" "name")
    set_current_host "$selected_index" "$host_name"
    
    log_info "Selected host: $host_name"
    return 0
}

menu_host_actions() {
    local host_index="$1"
    local host_name
    host_name=$(get_host_field "$host_index" "name")
    
    while true; do
        local entries=(
            "Browse Applications"
            "Refresh Application List"
            "Show Connection Status"
            "Change Host"
        )
        
        local selection
        if ! selection=$(rofi_menu "$ROFI_PROMPT_ACTION - $host_name" "${entries[@]}" | cut -d: -f1); then
            exit 0
        fi
        
        local action="${entries[$selection]}"
        
        case "$action" in
            "Browse Applications")
                menu_applications "$host_index"
                ;;
            "Refresh Application List")
                action_refresh "$host_index"
                ;;
            "Show Connection Status")
                action_status "$host_index"
                ;;
            "Change Host")
                clear_current_host
                return 1
                ;;
        esac
    done
}

menu_applications() {
    local host_index="$1"
    
    if [[ ! -f "$APPS_CACHE" ]]; then
        rofi_menu "Error" "No applications cached|Please run 'Refresh Application List' first|Back" >/dev/null || true
        return 0
    fi
    
    local app_count
    app_count=$(get_app_count)
    
    if [[ "$app_count" -eq 0 ]]; then
        rofi_menu "No Applications" "No applications found on this host|Back" >/dev/null || true
        return 0
    fi
    
    while true; do
        # Build app entries
        local -a entries=()
        local -a display_entries=()
        
        # Add back option first
        entries+=("back")
        display_entries+=("Back")
        
        # Sort apps by name and build entries
        local sorted_indices
        mapfile -t sorted_indices < <(
            for ((i = 0; i < app_count; i++)); do
                local name
                name=$(get_app_field "$i" "name")
                echo "$i|$name"
            done | sort -t'|' -k2 | cut -d'|' -f1
        )
        
        for idx in "${sorted_indices[@]}"; do
            local name
            name=$(get_app_field "$idx" "name")

            entries+=("$idx")
            display_entries+=("$name")
        done
        
        # Build rofi command with icon support
        local -a rofi_cmd=(
            rofi
            -dmenu
            -i
            -p "$ROFI_PROMPT_APP"
            -format "i"
            -no-custom
            -show-icons
        )
        
        [[ -n "$ROFI_THEME" ]] && rofi_cmd+=(-theme "$ROFI_THEME")
        
        # Build rofi input with proper icon meta
        local rofi_input=""
        for i in "${!display_entries[@]}"; do
            local icon_meta=""
            
            # Try to get icon path (skip for back option)
            if [[ "${entries[$i]}" != "back" ]]; then
                local icon_path
                if icon_path=$(get_app_icon "$host_index" "${entries[$i]}"); then
                    icon_meta="\0icon\x1f${icon_path}"
                fi
            fi
            
            rofi_input+="${display_entries[$i]}${icon_meta}\n"
        done
        
        # Show menu and get selection
        local selection
        if ! selection=$(echo -en "$rofi_input" | "${rofi_cmd[@]}"); then
            return 0
        fi
        
        # Handle selection
        local selected_action="${entries[$selection]}"
        
        if [[ "$selected_action" == "back" ]]; then
            return 0
        fi
        
        # Launch app
        launch_app "$host_index" "$selected_action"
        
        # Exit the menu after launching if configured to do so
        if [[ "$CLOSE_AFTER_LAUNCH" == "true" ]]; then
            exit 0
        fi
        
        # Optional: Add a small delay to prevent menu from reopening too quickly
        sleep 0.1
    done
}

# ============================================================================
# Actions
# ============================================================================

action_refresh() {
    local host_index="$1"
    local host service_port
    host=$(get_host_field "$host_index" "host")
    service_port=$(get_host_field "$host_index" "service_port")
    
    if ! check_service_health "$host" "$service_port"; then
        rofi_menu "Connection Error" "Service not responding at ${host}:${service_port}|Please check the host connection|Back" >/dev/null || true
        return 1
    fi
    
    if fetch_apps_from_service "$host" "$service_port"; then
        update_icon_map "$host_index"
        
        local count
        count=$(get_app_count)
        rofi_menu "Success" "Successfully refreshed $count applications" >/dev/null || true
    else
        rofi_menu "Fetch Error" "Failed to fetch applications from server|Please try again later|Back" >/dev/null || true
    fi
}

action_status() {
    local host_index="$1"
    local host_name service_port app_count
    host_name=$(get_host_field "$host_index" "name")
    service_port=$(get_host_field "$host_index" "service_port")
    app_count=$(get_app_count)
    
    local host_addr
    host_addr=$(get_host_field "$host_index" "host")
    
    local status_health="Offline"
    if check_service_health "$host_addr" "$service_port"; then
        status_health="Online"
    fi
    
    local icon_count="0"
    if [[ -d "$ICONS_DIR" ]]; then
        icon_count=$(find "$ICONS_DIR" -name "*.png" 2>/dev/null | wc -l)
    fi
    
    rofi_menu "Status: $host_name" \
        "Address: ${host_addr}:${service_port}" \
        "Status: $status_health" \
        "Cached Applications: $app_count" \
        "Cached Icons: $icon_count"
}

# ============================================================================
# Main
# ============================================================================

main() {
    check_dependencies
    init_directories
    
    if ! validate_config; then
        die "Invalid or missing config: $CONFIG_FILE"
    fi
    
    while true; do
        # Check if we have a current host
        local host_index
        if ! host_index=$(get_current_host_index); then
            # No host selected, show host selection
            if ! menu_select_host; then
                exit 0
            fi
            host_index=$(get_current_host_index)
        fi
        
        # Show host actions menu
        if ! menu_host_actions "$host_index"; then
            # User wants to change host, clear current host and loop back
            continue
        fi
    done
}

main "$@"