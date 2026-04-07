#!/usr/bin/env bash
# AutoRAG Optimizer Loop (Bash)
# ================================================
# Runs the optimizer agent in a continuous loop with budget tracking.
# Each iteration: read history, modify config/skills, evaluate, keep/discard.
#
# Usage:
#   chmod +x scripts/run_optimizer.sh
#   ./scripts/run_optimizer.sh
#
# Prerequisites:
#   - LLM CLI agent installed and authenticated
#   - Git initialized with baseline committed
#   - results.tsv initialized with baseline
#   - Vector index built (uv run scripts/build_index.py --eval-only --force)
#
# To stop: Ctrl+C or wait for budget limit

# Do NOT use "set -e" — if the optimizer exits non-zero the loop must continue
set +e

# --- Budget Configuration ---
BUDGET_LIMIT=15.00       # Total API budget in USD
TOTAL_SPENT=0.00         # Cumulative spend tracker

# Initialize results.tsv with header if it doesn't exist
if [ ! -f "results.tsv" ]; then
    printf "experiment_id\tdecision\told_score\tnew_score\tfiles_modified\treindexed\tdescription\n" > results.tsv
    echo "Initialized results.tsv with header"
    echo ""
    echo "WARNING: No baseline score recorded yet."
    echo "Run 'uv run evaluate.py --split dev' first to get baseline, then add it to results.tsv"
    echo ""
fi

# Initialize git branch
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "autoresearch/optimizer-rag" ]; then
    git checkout -b "autoresearch/optimizer-rag" 2>/dev/null || git checkout "autoresearch/optimizer-rag"
    echo "On branch: autoresearch/optimizer-rag"
fi

echo ""
echo "=========================================="
echo "AutoRAG Optimizer Loop"
echo "=========================================="
echo "Budget: \$${BUDGET_LIMIT} | Eval: 100 questions (~\$0.78/run)"
echo "Press Ctrl+C to stop"
echo ""

ITERATION=1

while true; do
    # --- Budget check ---
    REMAINING=$(echo "$BUDGET_LIMIT - $TOTAL_SPENT" | bc 2>/dev/null || echo "15")
    OVER=$(echo "$REMAINING <= 0.50" | bc 2>/dev/null || echo "0")
    if [ "$OVER" = "1" ]; then
        echo ""
        echo "=========================================="
        echo "BUDGET REACHED: \$${TOTAL_SPENT} / \$${BUDGET_LIMIT} spent"
        echo "=========================================="
        echo "Stopping optimizer. Check results.tsv for experiment history."
        break
    fi

    echo ""
    echo "--- Iteration $ITERATION | Spent: \$${TOTAL_SPENT} / \$${BUDGET_LIMIT} ---"
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # Run the optimizer agent
    claude --dangerously-skip-permissions --max-turns 50 \
        "Read optimizer_program.md and execute ONE experiment iteration. Read results.tsv first to see what has been tried. Make one focused change to config.yaml or a skill file, run the evaluation with 'uv run evaluate.py --split dev --max-questions 100', and decide keep or discard. Update results.tsv with the result." \
        || echo "[WARN] Iteration $ITERATION exited with code $? — continuing..."

    # --- Track cost from run.log ---
    if [ -f "run.log" ]; then
        ITER_COST=$(grep "total_cost_usd:" run.log | tail -1 | sed 's/.*total_cost_usd: *//')
        if [ -n "$ITER_COST" ]; then
            TOTAL_SPENT=$(echo "$TOTAL_SPENT + $ITER_COST" | bc 2>/dev/null || echo "$TOTAL_SPENT")
            echo ""
            echo "[BUDGET] Iteration cost: \$${ITER_COST} | Total: \$${TOTAL_SPENT} / \$${BUDGET_LIMIT}"
        fi
    fi

    ITERATION=$((ITERATION + 1))

    # Brief pause between iterations
    sleep 5
done
