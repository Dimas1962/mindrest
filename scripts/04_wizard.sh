#!/bin/bash

# Script to guide user through service selection for n8n-installer

# Source utility functions, if any, assuming it's in the same directory
# and .env is in the parent directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
# UTILS_SCRIPT="$SCRIPT_DIR/utils.sh" # Uncomment if utils.sh contains relevant functions

# if [ -f "$UTILS_SCRIPT" ]; then
#     source "$UTILS_SCRIPT"
# fi

# Function to check if whiptail is installed
check_whiptail() {
    if ! command -v whiptail &> /dev/null; then
        echo "--------------------------------------------------------------------"
        echo "ERROR: 'whiptail' is not installed."
        echo "This tool is required for the interactive service selection."
        echo "On Debian/Ubuntu, you can install it using: sudo apt-get install whiptail"
        echo "Please install whiptail and try again."
        echo "--------------------------------------------------------------------"
        exit 1
    fi
}

# Call the check
check_whiptail

# Store original DEBIAN_FRONTEND and set to dialog for whiptail
ORIGINAL_DEBIAN_FRONTEND="$DEBIAN_FRONTEND"
export DEBIAN_FRONTEND=dialog

# Define available services and their descriptions for the checklist
# Format: "tag" "description" "ON/OFF"
# Caddy, Postgres, and Redis are core services and will always be enabled implicitly
# if dependent services are chosen, or by default as they won't have profiles.
services=(
    "n8n" "n8n, n8n-worker, n8n-import (Workflow Automation)" "ON"
    "flowise" "Flowise (AI Agent Builder)" "ON"
    "monitoring" "Monitoring Suite (Prometheus, Grafana, cAdvisor, Node-Exporter)" "ON"
    "qdrant" "Qdrant (Vector Database)" "OFF"
    "supabase" "Supabase (Backend as a Service)" "OFF"
    "langfuse" "Langfuse Suite (AI Observability - includes Clickhouse, Minio)" "OFF"
    "open-webui" "Open WebUI (ChatGPT-like Interface)" "OFF"
    "searxng" "SearXNG (Private Metasearch Engine)" "OFF"
    "crawl4ai" "Crawl4ai (Web Crawler for AI)" "OFF"
    "letta" "Letta (Agent Server & SDK)" "OFF"
    "ollama" "Ollama (Local LLM Runner - select hardware in next step)" "OFF"
)

# Use whiptail to display the checklist
CHOICES=$(whiptail --title "Service Selection Wizard" --checklist \
  "Choose the services you want to deploy.\nUse ARROW KEYS to navigate, SPACEBAR to select/deselect, ENTER to confirm." 22 78 10 \
  "${services[@]}" \
  3>&1 1>&2 2>&3)

# Restore original DEBIAN_FRONTEND
if [ -n "$ORIGINAL_DEBIAN_FRONTEND" ]; then
  export DEBIAN_FRONTEND="$ORIGINAL_DEBIAN_FRONTEND"
else
  unset DEBIAN_FRONTEND
fi

# Exit if user pressed Cancel or Esc
exitstatus=$?
if [ $exitstatus -ne 0 ]; then
    echo "--------------------------------------------------------------------"
    echo "INFO: Service selection cancelled by user. Exiting wizard."
    echo "No changes made to service profiles. Default services will be used."
    echo "--------------------------------------------------------------------"
    # Set COMPOSE_PROFILES to empty to ensure only core services run
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE"
    fi
    if grep -q "^COMPOSE_PROFILES=" "$ENV_FILE"; then
        sed -i.bak "/^COMPOSE_PROFILES=/d" "$ENV_FILE"
    fi
    echo "COMPOSE_PROFILES=" >> "$ENV_FILE"
    exit 0
fi

# Process selected services
selected_profiles=()
ollama_selected=0
ollama_profile=""

if [ -n "$CHOICES" ]; then
    # Whiptail returns a string like "tag1" "tag2" "tag3"
    # We need to remove quotes and convert to an array
    temp_choices=()
    eval "temp_choices=($CHOICES)"

    for choice in "${temp_choices[@]}"; do
        if [ "$choice" == "ollama" ]; then
            ollama_selected=1
        else
            selected_profiles+=("$choice")
        fi
    done
fi

# If Ollama was selected, prompt for the hardware profile
if [ $ollama_selected -eq 1 ]; then
    ollama_hardware_options=(
        "cpu" "CPU (Recommended for most users)" "ON"
        "gpu-nvidia" "NVIDIA GPU (Requires NVIDIA drivers & CUDA)" "OFF"
        "gpu-amd" "AMD GPU (Requires ROCm drivers)" "OFF"
    )
    CHOSEN_OLLAMA_PROFILE=$(whiptail --title "Ollama Hardware Profile" --radiolist \
      "Choose the hardware profile for Ollama. This will be added to your Docker Compose profiles." 15 78 3 \
      "${ollama_hardware_options[@]}" \
      3>&1 1>&2 2>&3)

    ollama_exitstatus=$?
    if [ $ollama_exitstatus -eq 0 ] && [ -n "$CHOSEN_OLLAMA_PROFILE" ]; then
        selected_profiles+=("$CHOSEN_OLLAMA_PROFILE")
        ollama_profile="$CHOSEN_OLLAMA_PROFILE" # Store for user message
        echo "INFO: Ollama hardware profile selected: $CHOSEN_OLLAMA_PROFILE"
    else
        echo "INFO: Ollama hardware profile selection cancelled or no choice made. Ollama will not be configured with a specific hardware profile."
        # ollama_selected remains 1, but no specific profile is added.
        # This means "ollama" won't be in COMPOSE_PROFILES unless a hardware profile is chosen.
        ollama_selected=0 # Mark as not fully selected if profile choice is cancelled
    fi
fi

echo "--------------------------------------------------------------------"
if [ ${#selected_profiles[@]} -eq 0 ]; then
    echo "INFO: No optional services selected."
    COMPOSE_PROFILES_VALUE=""
else
    echo "INFO: You have selected the following service profiles to be deployed:"
    # Join the array into a comma-separated string
    COMPOSE_PROFILES_VALUE=$(IFS=,; echo "${selected_profiles[*]}")
    for profile in "${selected_profiles[@]}"; do
        # Check if the curr
        if [ "$profile" == "cpu" ] || [ "$profile" == "gpu-nvidia" ] || [ "$profile" == "gpu-amd" ]; then
            if [ "$profile" == "$ollama_profile" ]; then # Make sure this is the ollama profile we just selected
                 echo "  - Ollama ($profile profile)"
            else # It could be another service that happens to be named "cpu" if we add one later
                 echo "  - $profile"
            fi
        else
            echo "  - $profile"
        fi
    done
fi
echo "--------------------------------------------------------------------"

# Update or add COMPOSE_PROFILES in .env file
# Ensure .env file exists (it should have been created by 03_generate_secrets.sh)
if [ ! -f "$ENV_FILE" ]; then
    echo "WARNING: '.env' file not found at $ENV_FILE. Creating it."
    touch "$ENV_FILE"
fi

# Remove existing COMPOSE_PROFILES line if it exists
if grep -q "^COMPOSE_PROFILES=" "$ENV_FILE"; then
    # Using a different delimiter for sed because a profile name might contain '/' (unlikely here)
    sed -i.bak "\|^COMPOSE_PROFILES=|d" "$ENV_FILE"
fi

# Add the new COMPOSE_PROFILES line
echo "COMPOSE_PROFILES=${COMPOSE_PROFILES_VALUE}" >> "$ENV_FILE"
echo "INFO: COMPOSE_PROFILES has been set in '$ENV_FILE'."
if [ -z "$COMPOSE_PROFILES_VALUE" ]; then
    echo "Only core services (Caddy, Postgres, Redis) will be started."
else
    echo "The following Docker Compose profiles will be active: ${COMPOSE_PROFILES_VALUE}"
fi
echo "--------------------------------------------------------------------"

# Make the script executable (though install.sh calls it with bash)
chmod +x "$SCRIPT_DIR/04_wizard.sh"

exit 0 