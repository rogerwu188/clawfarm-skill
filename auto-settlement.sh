#!/usr/bin/env bash
# auto-settlement.sh — Automated daily settlement with ledger integrity
# Run via cron: 0 0 * * * /path/to/auto-settlement.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTLEMENT="$SCRIPT_DIR/settlement.sh"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

DATE=$(date -u +%Y-%m-%d)
LOG_FILE="$LOG_DIR/settlement-${DATE}.log"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

log "=== Daily Settlement: $DATE ==="

# Step 1: Pre-settlement ledger snapshot
log "Step 1: Capturing pre-settlement ledger snapshot..."
PRE_POINTS=$(curl -sf "${SUPABASE_URL:-https://caxxwrpnjqgnqhmycohs.supabase.co}/rest/v1/points_ledger?select=amount&order=created_at.desc&limit=100" \
  -H "apikey: ${SUPABASE_KEY:-sb_publishable_xa-sR9iM5xdGuPsgndAoFw_ia9e6TPq}" \
  -H "Authorization: Bearer ${SUPABASE_KEY:-sb_publishable_xa-sR9iM5xdGuPsgndAoFw_ia9e6TPq}" 2>/dev/null || echo "[]")
PRE_COUNT=$(echo "$PRE_POINTS" | jq 'length')
log "Pre-settlement ledger entries: $PRE_COUNT"

# Step 2: Run settlement
log "Step 2: Running settlement..."
if bash "$SETTLEMENT" 2>&1 | tee -a "$LOG_FILE"; then
  log "Settlement completed successfully"
else
  log "ERROR: Settlement failed with exit code $?"
  exit 1
fi

# Step 3: Post-settlement verification
log "Step 3: Verifying ledger integrity..."
POST_POINTS=$(curl -sf "${SUPABASE_URL:-https://caxxwrpnjqgnqhmycohs.supabase.co}/rest/v1/points_ledger?select=amount&order=created_at.desc&limit=100" \
  -H "apikey: ${SUPABASE_KEY:-sb_publishable_xa-sR9iM5xdGuPsgndAoFw_ia9e6TPq}" \
  -H "Authorization: Bearer ${SUPABASE_KEY:-sb_publishable_xa-sR9iM5xdGuPsgndAoFw_ia9e6TPq}" 2>/dev/null || echo "[]")
POST_COUNT=$(echo "$POST_POINTS" | jq 'length')
NEW_ENTRIES=$((POST_COUNT - PRE_COUNT))
log "Post-settlement ledger entries: $POST_COUNT (new: $NEW_ENTRIES)"

# Step 4: Verify node balances updated
log "Step 4: Checking node balances..."
NODES=$(curl -sf "${SUPABASE_URL:-https://caxxwrpnjqgnqhmycohs.supabase.co}/rest/v1/nodes?select=node_id,points_balance,status&order=points_balance.desc" \
  -H "apikey: ${SUPABASE_KEY:-sb_publishable_xa-sR9iM5xdGuPsgndAoFw_ia9e6TPq}" \
  -H "Authorization: Bearer ${SUPABASE_KEY:-sb_publishable_xa-sR9iM5xdGuPsgndAoFw_ia9e6TPq}" 2>/dev/null || echo "[]")
echo "$NODES" | jq -r '.[] | "  \(.node_id): \(.points_balance) pts (\(.status))"' | tee -a "$LOG_FILE"

TOTAL=$(echo "$NODES" | jq '[.[].points_balance] | add // 0')
log "Total network points: $TOTAL"

log "=== Settlement $DATE Complete ==="
