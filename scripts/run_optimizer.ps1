# AutoRAG Optimizer Loop (PowerShell - Windows)
# ================================================
# Runs the optimizer agent in a continuous loop with budget tracking.
# Each iteration: read history, modify config/skills, evaluate, keep/discard.
#
# Usage:
#   .\scripts\run_optimizer.ps1
#
# Prerequisites:
#   - LLM CLI agent installed and authenticated
#   - Git initialized with baseline committed
#   - results.tsv initialized with baseline
#   - Vector index built (uv run scripts/build_index.py --eval-only --force)
#
# To stop: Ctrl+C or wait for budget limit

$ErrorActionPreference = "SilentlyContinue"

# --- Budget Configuration ---
$BUDGET_LIMIT = 15.00       # Total API budget in USD
$totalSpent = 0.0            # Cumulative spend tracker

# Initialize results.tsv with header if it doesn't exist
if (-not (Test-Path "results.tsv")) {
    "experiment_id`tdecision`told_score`tnew_score`tfiles_modified`treindexed`tdescription" | Out-File -FilePath "results.tsv" -Encoding utf8
    Write-Host "Initialized results.tsv with header"
    Write-Host ""
    Write-Host "WARNING: No baseline score recorded yet."
    Write-Host "Run 'uv run evaluate.py --split dev' first to get baseline, then add it to results.tsv"
    Write-Host ""
}

# Initialize git branch
$branch = git branch --show-current
if ($branch -ne "autoresearch/optimizer-rag") {
    try {
        git checkout -b "autoresearch/optimizer-rag"
    } catch {
        git checkout "autoresearch/optimizer-rag"
    }
    Write-Host "On branch: autoresearch/optimizer-rag"
}

Write-Host ""
Write-Host "=========================================="
Write-Host "AutoRAG Optimizer Loop"
Write-Host "=========================================="
Write-Host "Budget: `$$BUDGET_LIMIT | Eval: 100 questions (~`$0.78/run)"
Write-Host "Press Ctrl+C to stop"
Write-Host ""

$iteration = 1

while ($true) {
    # --- Budget check ---
    $remaining = $BUDGET_LIMIT - $totalSpent
    if ($remaining -le 0.50) {
        Write-Host ""
        Write-Host "=========================================="
        Write-Host "BUDGET REACHED: `$$([math]::Round($totalSpent, 2)) / `$$BUDGET_LIMIT spent"
        Write-Host "=========================================="
        Write-Host "Stopping optimizer. Check results.tsv for experiment history."
        break
    }

    Write-Host ""
    Write-Host "--- Iteration $iteration | Spent: `$$([math]::Round($totalSpent, 2)) / `$$BUDGET_LIMIT ---"
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""

    # Run the optimizer agent (use & call operator, check $LASTEXITCODE)
    & claude --dangerously-skip-permissions --max-turns 50 "Read optimizer_program.md and execute ONE experiment iteration. Read results.tsv first to see what has been tried. Make one focused change to config.yaml or a skill file, run the evaluation with 'uv run evaluate.py --split dev --max-questions 100', and decide keep or discard. Update results.tsv with the result."
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] Iteration $iteration exited with code $LASTEXITCODE - continuing..."
    }

    # --- Track cost from run.log ---
    if (Test-Path "run.log") {
        $costLine = Select-String -Path "run.log" -Pattern "total_cost_usd:" | Select-Object -Last 1
        if ($costLine) {
            $costStr = $costLine.Line -replace ".*total_cost_usd:\s*", ""
            try {
                $iterCost = [double]$costStr
                $totalSpent += $iterCost
                Write-Host ""
                Write-Host "[BUDGET] Iteration cost: `$$([math]::Round($iterCost, 2)) | Total: `$$([math]::Round($totalSpent, 2)) / `$$BUDGET_LIMIT"
            } catch {
                Write-Host "[WARN] Could not parse cost from run.log"
            }
        }
    }

    $iteration++

    # Brief pause between iterations
    Start-Sleep -Seconds 5
}
