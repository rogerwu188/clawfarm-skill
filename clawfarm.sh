#!/bin/bash
# ClawFarm Skill for OpenClaw

set -e

SUPABASE_URL="${CLAWFARM_SUPABASE_URL:-https://caxxwrpnjqgnqhmycohs.supabase.co}"
SUPABASE_KEY="${CLAWFARM_SUPABASE_KEY:-sb_publishable_xa-sR9iM5xdGuPsgndAoFw_ia9e6TPq}"
WALLET="${CLAWFARM_WALLET:-}"
NODE_ID=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[ClawFarm]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[ClawFarm]${NC} $1"; }
log_error() { echo -e "${RED}[ClawFarm]${NC} $1" >&2; }

# Check config
check_config() {
  if [ -z "$SUPABASE_KEY" ]; then
    log_error "Not configured. Run: clawfarm config --supabase-key <KEY>"
    exit 1
  fi
}

# API call helper
api_call() {
  local method="$1"
  local endpoint="$2"
  local data="$3"
  
  curl -s -X "$method" \
    -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    "${SUPABASE_URL}/rest/v1/${endpoint}" \
    ${data:+-d "$data"}
}

# Register node
cmd_register() {
  check_config
  
  if [ -z "$WALLET" ]; then
    log_error "Wallet not set. Run: clawfarm config --wallet <ADDRESS>"
    exit 1
  fi
  
  NODE_ID="node-$(date +%s)"
  
  log_info "Registering node: $NODE_ID"
  
  api_call "POST" "nodes" "{\"node_id\":\"$NODE_ID\",\"wallet_address\":\"$WALLET\",\"status\":\"online\",\"points_balance\":0}"
  
  log_info "Node registered successfully!"
  log_info "Node ID: $NODE_ID"
  echo "export CLAWFARM_NODE_ID='$NODE_ID'" >> ~/.clawfarm_env
}

# Show status
cmd_status() {
  check_config
  
  if [ -z "$NODE_ID" ]; then
    # Try to load from env
    source ~/.clawfarm_env 2>/dev/null || true
  fi
  
  if [ -z "$NODE_ID" ]; then
    log_warn "Node not registered. Run: clawfarm register"
    return
  fi
  
  local result
  result=$(curl -s -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    "${SUPABASE_URL}/rest/v1/nodes?node_id=eq.$NODE_ID")
  
  if echo "$result" | grep -q "node_id"; then
    log_info "Node Status:"
    echo "$result" | jq -r '.[] | "  Node ID: \(.node_id)\n  Wallet: \(.wallet_address)\n  Status: \(.status)\n  Points: \(.points_balance)\n  Created: \(.created_at)"'
  else
    log_error "Node not found"
  fi
}

# Record usage
cmd_usage() {
  check_config
  
  local amount="${1:-0}"
  
  if [ "$amount" -eq 0 ] 2>/dev/null; then
    log_error "Usage amount required. Example: clawfarm usage 1000"
    exit 1
  fi
  
  if [ -z "$NODE_ID" ]; then
    source ~/.clawfarm_env 2>/dev/null || true
  fi
  
  if [ -z "$NODE_ID" ]; then
    log_error "Node not registered. Run: clawfarm register"
    exit 1
  fi
  
  log_info "Recording usage: $amount tokens"
  
  api_call "POST" "usage_ledger" "{\"node_id\":\"$NODE_ID\",\"usage_tokens\":$amount,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
  
  log_info "Usage recorded!"
}

# List tasks
cmd_tasks() {
  check_config
  
  local result
  result=$(curl -s -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    "${SUPABASE_URL}/rest/v1/tasks?status=eq.open&limit=10")
  
  if echo "$result" | grep -q "\["; then
    local count
    count=$(echo "$result" | jq 'length')
    if [ "$count" -eq 0 ]; then
      log_info "No tasks available"
    else
      log_info "Available Tasks:"
      echo "$result" | jq -r '.[] | "  \(.id | .[0:8]) - \(.title) [\$\(.budget // 0) budget]"'
    fi
  else
    log_info "No tasks available"
  fi
}

# Claim task
cmd_claim() {
  check_config
  
  local task_id="$1"
  
  if [ -z "$task_id" ]; then
    log_error "Task ID required. Example: clawfarm claim <id>"
    exit 1
  fi
  
  api_call "PATCH" "tasks?id=eq.$task_id" "{\"status\":\"assigned\",\"assigned_to\":\"$NODE_ID\"}"
  
  log_info "Task claimed: $task_id"
}

# Complete task
cmd_complete() {
  check_config
  
  local task_id="$1"
  
  if [ -z "$task_id" ]; then
    log_error "Task ID required. Example: clawfarm complete <id>"
    exit 1
  fi
  
  # Get task budget
  local task
  task=$(curl -s -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    "${SUPABASE_URL}/rest/v1/tasks?id=eq.$task_id")
  
  local reward
  reward=$(echo "$task" | jq -r '.[0].budget // 0')
  
  # Mark complete
  api_call "PATCH" "tasks?id=eq.$task_id" "{\"status\":\"completed\"}"
  
  # Add points to node
  local current
  current=$(curl -s -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    "${SUPABASE_URL}/rest/v1/nodes?node_id=eq.$NODE_ID" | jq -r '.[0].points_balance // 0')
  
  local new_balance=$((current + reward))
  
  api_call "PATCH" "nodes?node_id=eq.$NODE_ID" "{\"points_balance\":$new_balance}"
  
  log_info "Task completed! Earned $reward Points"
  log_info "New balance: $new_balance Points"
}

# Config command
cmd_config() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --supabase-url)
        SUPABASE_URL="$2"
        export CLAWFARM_SUPABASE_URL="$2"
        shift 2
        ;;
      --supabase-key)
        SUPABASE_KEY="$2"
        export CLAWFARM_SUPABASE_KEY="$2"
        shift 2
        ;;
      --wallet)
        WALLET="$2"
        export CLAWFARM_WALLET="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  
  # Save to env file
  mkdir -p ~/.clawfarm
  cat > ~/.clawfarm/config << EOF
export CLAWFARM_SUPABASE_URL="$SUPABASE_URL"
export CLAWFARM_SUPABASE_KEY="$SUPABASE_KEY"
export CLAWFARM_WALLET="$WALLET"
EOF
  
  log_info "Configuration saved!"
}

# Main
case "${1:-}" in
  register)
    cmd_register "${@:2}"
    ;;
  status)
    cmd_status "${@:2}"
    ;;
  usage)
    cmd_usage "${@:2}"
    ;;
  tasks)
    cmd_tasks "${@:2}"
    ;;
  claim)
    cmd_claim "${@:2}"
    ;;
  complete)
    cmd_complete "${@:2}"
    ;;
  config)
    cmd_config "${@:2}"
    ;;
  *)
    echo "ClawFarm Skill"
    echo ""
    echo "Usage: clawfarm <command> [options]"
    echo ""
    echo "Commands:"
    echo "  register              Register this node to the network"
    echo "  status                Show node status"
    echo "  usage <tokens>        Record inference usage"
    echo "  tasks                 List available tasks"
    echo "  claim <id>            Claim a task"
    echo "  complete <id>         Complete a task"
    echo "  config                Configure connection"
    echo ""
    echo "First time setup:"
    echo "  clawfarm config --supabase-key <KEY> --wallet <ADDRESS>"
    ;;
esac
