#!/bin/bash
# ClawFarm Daily Settlement Script
# Runs daily at 00:00 UTC to calculate and distribute Points

set -e

SUPABASE_URL="${CLAWFARM_SUPABASE_URL:-https://caxxwrpnjqgnqhmycohs.supabase.co}"
SUPABASE_KEY="${CLAWFARM_SUPABASE_KEY:-sb_publishable_xa-sR9iM5xdGuPsgndAoFw_ia9e6TPq}"

# Genesis emission schedule (Points per day)
DAILY_EMISSION=10000000  # 10M Points/day (Month 1-3)
BASE_POOL_RATIO=50       # 50% - distributed by compute/usage
REVENUE_POOL_RATIO=50    # 50% - distributed by output/tasks
TREASURY_TAX=3           # 3% tax on user earnings → treasury buyback

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[Settlement]${NC} $1"; }
warn() { echo -e "${YELLOW}[Settlement]${NC} $1"; }
err() { echo -e "${RED}[Settlement]${NC} $1" >&2; }

# API helper
api() {
  local method="$1" endpoint="$2" data="$3"
  curl -s -X "$method" \
    -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    "${SUPABASE_URL}/rest/v1/${endpoint}" \
    ${data:+-d "$data"}
}

# Get today's date range (UTC)
TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
START="${TODAY}T00:00:00Z"
END="${TODAY}T23:59:59Z"

log "=== ClawFarm Daily Settlement ==="
log "Date: $TODAY"
log "Daily Emission: $DAILY_EMISSION Points"
log ""

# Step 1: Get all usage for today
log "Step 1: Collecting usage data..."
USAGE_DATA=$(api GET "usage_ledger?timestamp=gte.$START&timestamp=lte.$END&select=node_id,token_usage")

# Calculate total usage
TOTAL_USAGE=$(echo "$USAGE_DATA" | jq '[.[] | .token_usage // 0] | add // 0')
log "Total network usage today: $TOTAL_USAGE tokens"

# Get per-node usage
NODE_USAGE=$(echo "$USAGE_DATA" | jq '[group_by(.node_id)[] | {node_id: .[0].node_id, total: [.[] | .token_usage // 0] | add}]')
log "Nodes with usage: $(echo "$NODE_USAGE" | jq 'length')"

# Step 2: Get completed tasks for today
log ""
log "Step 2: Collecting task completions..."
COMPLETED_TASKS=$(api GET "tasks?status=eq.completed&updated_at=gte.$START&updated_at=lte.$END&select=id,assigned_to,budget")

TOTAL_COMPLETED=$(echo "$COMPLETED_TASKS" | jq 'length')
log "Tasks completed today: $TOTAL_COMPLETED"

# Get per-node task counts
NODE_TASKS=$(echo "$COMPLETED_TASKS" | jq '[group_by(.assigned_to)[] | {node_id: .[0].assigned_to, count: length, total_budget: [.[] | .budget // 0] | add}]')

# Step 3: Calculate rewards
log ""
log "Step 3: Calculating rewards..."

BASE_POOL=$((DAILY_EMISSION * BASE_POOL_RATIO / 100))
REVENUE_POOL=$((DAILY_EMISSION * REVENUE_POOL_RATIO / 100))
TREASURY_TOTAL=0  # Accumulated from 3% tax on earnings

log "Base Pool: $BASE_POOL Points (50% compute)"
log "Revenue Pool: $REVENUE_POOL Points (50% output)"
log "Treasury Tax: ${TREASURY_TAX}% on all earnings → buyback"

# Step 4: Distribute Base Pool (by usage)
log ""
log "Step 4: Distributing Base Pool..."

if [ "$TOTAL_USAGE" -gt 0 ] 2>/dev/null; then
  echo "$NODE_USAGE" | jq -c '.[]' | while read -r node; do
    NODE_ID=$(echo "$node" | jq -r '.node_id')
    NODE_TOKENS=$(echo "$node" | jq -r '.total')
    
    # Calculate share: node_usage / total_usage * base_pool
    REWARD=$(echo "scale=0; $NODE_TOKENS * $BASE_POOL / $TOTAL_USAGE" | bc)
    
    if [ "$REWARD" -gt 0 ] 2>/dev/null; then
      # Apply 3% treasury tax
      TAX=$((REWARD * TREASURY_TAX / 100))
      NET_REWARD=$((REWARD - TAX))
      TREASURY_TOTAL=$((TREASURY_TOTAL + TAX))
      
      log "  $NODE_ID: +$NET_REWARD Points (gross: $REWARD, tax: $TAX) [usage: $NODE_TOKENS tokens]"
      
      # Write to points_ledger
      api POST "points_ledger" "{\"node_id\":\"$NODE_ID\",\"amount\":$NET_REWARD,\"source\":\"base_pool\"}" > /dev/null
      
      # Update node balance
      CURRENT=$(api GET "nodes?node_id=eq.$NODE_ID&select=points_balance" | jq '.[0].points_balance // 0')
      NEW_BALANCE=$((CURRENT + NET_REWARD))
      api PATCH "nodes?node_id=eq.$NODE_ID" "{\"points_balance\":$NEW_BALANCE}" > /dev/null
    fi
  done
else
  warn "  No usage recorded today. Base Pool not distributed."
fi

# Step 5: Distribute Revenue Pool (by tasks)
log ""
log "Step 5: Distributing Revenue Pool..."

if [ "$TOTAL_COMPLETED" -gt 0 ] 2>/dev/null; then
  echo "$NODE_TASKS" | jq -c '.[]' | while read -r node; do
    NODE_ID=$(echo "$node" | jq -r '.node_id')
    NODE_COUNT=$(echo "$node" | jq -r '.count')
    
    # Calculate share: node_tasks / total_tasks * revenue_pool
    REWARD=$(echo "scale=0; $NODE_COUNT * $REVENUE_POOL / $TOTAL_COMPLETED" | bc)
    
    if [ "$REWARD" -gt 0 ] 2>/dev/null; then
      # Apply 3% treasury tax
      TAX=$((REWARD * TREASURY_TAX / 100))
      NET_REWARD=$((REWARD - TAX))
      TREASURY_TOTAL=$((TREASURY_TOTAL + TAX))
      
      log "  $NODE_ID: +$NET_REWARD Points (gross: $REWARD, tax: $TAX) [tasks: $NODE_COUNT]"
      
      # Write to points_ledger
      api POST "points_ledger" "{\"node_id\":\"$NODE_ID\",\"amount\":$NET_REWARD,\"source\":\"revenue_pool\"}" > /dev/null
      
      # Update node balance
      CURRENT=$(api GET "nodes?node_id=eq.$NODE_ID&select=points_balance" | jq '.[0].points_balance // 0')
      NEW_BALANCE=$((CURRENT + NET_REWARD))
      api PATCH "nodes?node_id=eq.$NODE_ID" "{\"points_balance\":$NEW_BALANCE}" > /dev/null
    fi
  done
else
  warn "  No tasks completed today. Revenue Pool not distributed."
fi

# Step 6: Treasury (3% buyback fund)
log ""
log "Step 6: Treasury buyback fund..."
if [ "$TREASURY_TOTAL" -gt 0 ] 2>/dev/null; then
  api POST "points_ledger" "{\"node_id\":\"treasury\",\"amount\":$TREASURY_TOTAL,\"source\":\"buyback_tax\"}" > /dev/null
  log "  Treasury: +$TREASURY_TOTAL Points (3% tax from all earnings → buyback)"
else
  log "  Treasury: 0 (no earnings today)"
fi

# Step 7: Summary
log ""
log "=== Settlement Complete ==="
log "Date: $TODAY"
log "Total Emission: $DAILY_EMISSION Points"

# Get all nodes summary
ALL_NODES=$(api GET "nodes?select=node_id,points_balance&order=points_balance.desc")
log "Network Leaderboard:"
echo "$ALL_NODES" | jq -r '.[] | "  \(.node_id): \(.points_balance) Points"'

log ""
log "Done."
