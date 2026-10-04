#!/usr/bin/env python3
"""
Claude Code Usage Report Generator

Reads ccusage data and generates reports with:
- Daily token usage (in, out, cache read)
- Costs per token type
- Percentage of Max5 plan limits (5h window * 3 = daily estimate)

Requirements:
    - ccusage (npm install -g ccusage)
"""

import json
import csv
import sys
import shutil
import subprocess
from pathlib import Path
from datetime import datetime

# Claude plan limits per 5-hour window (Input + Output tokens)
# Source: Internal usage data analysis
PRO_TOTAL_5H = 200000       # Pro: 45 messages, ~200k tokens per 5h
MAX5_TOTAL_5H = 450000      # Max 5x: 225 messages, ~450k tokens per 5h
MAX20_TOTAL_5H = 1800000    # Max 20x: 900 messages, ~1.8M tokens per 5h

# Daily limits (3 windows per day as reasonable usage)
WINDOWS_PER_DAY = 3
MAX_INPUT_DAILY = 1350000   # 1.35M input/day (Max5x)
MAX_OUTPUT_DAILY = 450000   # 450k output/day (Max5x)
MAX_CACHE_DAILY = 9000000   # 9M cache/day (Max5x)

# API Pricing per 1M tokens (Claude 3.5/3.7 Sonnet - DEFAULT)
# Source: https://www.anthropic.com/pricing
PRICE_INPUT = 3.00          # $3.00 per 1M input tokens
PRICE_OUTPUT = 15.00        # $15.00 per 1M output tokens
PRICE_CACHE_READ = 0.30     # $0.30 per 1M cache read tokens
PRICE_CACHE_CREATE = 3.75   # $3.75 per 1M cache creation tokens

# Model-specific pricing (per 1M tokens)
MODEL_PRICING = {
    "haiku": {"input": 0.80, "output": 4.00, "cache_read": 0.08, "cache_create": 1.00},
    "sonnet": {"input": 3.00, "output": 15.00, "cache_read": 0.30, "cache_create": 3.75},
    "opus": {"input": 15.00, "output": 75.00, "cache_read": 1.50, "cache_create": 18.75},
}

# Budget configuration
MONTHLY_BUDGET = 100.00  # USD
ALERT_THRESHOLDS = [50, 75, 90, 100]  # percent
OPUS_ALERT_PERCENT = 10  # Alert if Opus > 10% of tokens


def check_ccusage_installed() -> bool:
    """Check if ccusage is installed."""
    return shutil.which("ccusage") is not None


def get_ccusage_data() -> dict:
    """Run ccusage --json and return parsed JSON data."""
    if not check_ccusage_installed():
        print("Error: ccusage is not installed.")
        print("\nInstall it with:")
        print("  npm install -g ccusage")
        print("\nMore info: https://github.com/ryoppippi/ccusage")
        sys.exit(1)

    try:
        result = subprocess.run(
            ["ccusage", "--json"],
            capture_output=True,
            text=True,
            timeout=60
        )
        if result.returncode != 0:
            print(f"Error running ccusage: {result.stderr}")
            sys.exit(1)

        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        print("Error: ccusage timed out")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error parsing ccusage output: {e}")
        sys.exit(1)


def get_daily_time_from_blocks() -> dict:
    """Get actual time usage per day from blocks data."""
    if not check_ccusage_installed():
        return {}

    try:
        result = subprocess.run(
            ["ccusage", "blocks", "--json"],
            capture_output=True,
            text=True,
            timeout=60
        )
        if result.returncode != 0:
            return {}

        data = json.loads(result.stdout)
        blocks = data.get("blocks", [])

        # Aggregate time by date
        daily_time = {}
        for block in blocks:
            if block.get("isGap"):
                continue

            start_str = block.get("startTime", "")
            end_str = block.get("actualEndTime") or block.get("endTime", "")

            if not start_str or not end_str:
                continue

            try:
                start = datetime.fromisoformat(start_str.replace("Z", "+00:00"))
                end = datetime.fromisoformat(end_str.replace("Z", "+00:00"))
                duration_hours = (end - start).total_seconds() / 3600

                # Get date from start time
                date = start_str[:10]

                if date not in daily_time:
                    daily_time[date] = 0
                daily_time[date] += duration_hours
            except:
                continue

        return daily_time
    except:
        return {}


def get_blocks_data() -> dict:
    """Run ccusage blocks --active --json and return parsed JSON data."""
    if not check_ccusage_installed():
        print("Error: ccusage is not installed.")
        print("\nInstall it with:")
        print("  npm install -g ccusage")
        print("\nMore info: https://github.com/ryoppippi/ccusage")
        sys.exit(1)

    try:
        result = subprocess.run(
            ["ccusage", "blocks", "-a", "--json"],
            capture_output=True,
            text=True,
            timeout=60
        )
        if result.returncode != 0:
            print(f"Error running ccusage blocks: {result.stderr}")
            sys.exit(1)

        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        print("Error: ccusage timed out")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error parsing ccusage output: {e}")
        sys.exit(1)


def calculate_cost(tokens: int, price_per_million: float) -> float:
    """Calculate cost for given tokens at price per million."""
    return (tokens / 1_000_000) * price_per_million

def format_duration(minutes: float) -> str:
    """Format minutes as Xh Ym."""
    hours = int(minutes // 60)
    mins = int(minutes % 60)
    if hours > 0:
        return f"{hours}h {mins}m"
    return f"{mins}m"

def format_tokens(n: int) -> str:
    """Format tokens as Xk with 1k precision."""
    if n >= 1000:
        return f"{round(n / 1000)}k"
    return str(n)

def normalize_model_name(model_name: str) -> str:
    """Convert full model name to simple category (haiku/sonnet/opus)."""
    model_lower = model_name.lower()
    if 'haiku' in model_lower:
        return 'haiku'
    elif 'opus' in model_lower:
        return 'opus'
    elif 'sonnet' in model_lower:
        return 'sonnet'
    return 'unknown'

def get_model_breakdown_from_daily(data: dict) -> dict:
    """Extract per-model breakdown from daily ccusage data."""
    breakdown = {
        "haiku": {"tokens_in": 0, "tokens_out": 0, "cost": 0},
        "sonnet": {"tokens_in": 0, "tokens_out": 0, "cost": 0},
        "opus": {"tokens_in": 0, "tokens_out": 0, "cost": 0},
        "unknown": {"tokens_in": 0, "tokens_out": 0, "cost": 0}
    }

    daily = data.get("daily", [])
    for day in daily:
        model_breakdowns = day.get("modelBreakdowns", [])
        for model_data in model_breakdowns:
            model_name = model_data.get("modelName", "")
            category = normalize_model_name(model_name)

            breakdown[category]["tokens_in"] += model_data.get("inputTokens", 0)
            breakdown[category]["tokens_out"] += model_data.get("outputTokens", 0)
            breakdown[category]["cost"] += model_data.get("cost", 0)

    return breakdown

def get_model_distribution(breakdown: dict) -> dict:
    """Calculate percentage distribution of tokens by model."""
    total_tokens = sum(
        m["tokens_in"] + m["tokens_out"]
        for m in breakdown.values()
    )

    if total_tokens == 0:
        return {model: 0 for model in breakdown.keys()}

    distribution = {}
    for model, stats in breakdown.items():
        model_tokens = stats["tokens_in"] + stats["tokens_out"]
        distribution[model] = (model_tokens / total_tokens) * 100

    return distribution

def calculate_mtd_budget(daily_data: list) -> dict:
    """Calculate month-to-date budget status with alerts."""
    from datetime import datetime

    # Get current month
    now = datetime.now()
    current_month = now.month
    current_year = now.year
    current_day = now.day

    # Filter to current month and sum costs
    mtd_cost = 0
    for day in daily_data:
        date_str = day.get("date", "")
        if not date_str:
            continue

        day_date = datetime.strptime(date_str, "%Y-%m-%d")
        if day_date.month == current_month and day_date.year == current_year:
            mtd_cost += day.get("cost", 0)

    # Calculate metrics
    mtd_days = current_day
    daily_avg = mtd_cost / mtd_days if mtd_days > 0 else 0

    # Project to end of month (approximate 30 days)
    days_in_month = 30
    projected_eom = daily_avg * days_in_month

    # Budget percentage
    budget_pct = (mtd_cost / MONTHLY_BUDGET) * 100 if MONTHLY_BUDGET > 0 else 0

    # Determine alert level
    alert_level = "ok"
    if budget_pct >= 100:
        alert_level = "exceeded"
    elif budget_pct >= 90:
        alert_level = "danger"
    elif budget_pct >= 75:
        alert_level = "warning"

    return {
        "mtd_cost": mtd_cost,
        "mtd_days": mtd_days,
        "daily_avg": daily_avg,
        "projected_eom": projected_eom,
        "budget_pct": budget_pct,
        "alert_level": alert_level
    }

def output_now_detailed(data: dict):
    """Print detailed current 5h block status with cost breakdown."""

    # Find active block from blocks array
    blocks = data.get("blocks", [])
    block = None
    for b in blocks:
        if b.get("isActive", False):
            block = b
            break

    if not block:
        print("No active block found.")
        return

    # Extract token counts from nested structure
    token_counts = block.get("tokenCounts", {})
    tokens_in = token_counts.get("inputTokens", 0)
    tokens_out = token_counts.get("outputTokens", 0)
    cache_read = token_counts.get("cacheReadInputTokens", 0)
    cache_create = token_counts.get("cacheCreationInputTokens", 0)
    total_tokens = block.get("totalTokens", 0)

    # Time info
    start_time = block.get("startTime", "")
    projection = block.get("projection", {})
    remaining_minutes = projection.get("remainingMinutes", 0)

    # Calculate elapsed from start time
    try:
        start_dt = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        elapsed_minutes = (datetime.now(start_dt.tzinfo) - start_dt).total_seconds() / 60
    except:
        elapsed_minutes = 300 - remaining_minutes  # fallback

    # Calculate API costs
    cost_in = calculate_cost(tokens_in, PRICE_INPUT)
    cost_out = calculate_cost(tokens_out, PRICE_OUTPUT)
    cost_cache_read = calculate_cost(cache_read, PRICE_CACHE_READ)
    cost_cache_create = calculate_cost(cache_create, PRICE_CACHE_CREATE)
    total_api_cost = cost_in + cost_out + cost_cache_read + cost_cache_create

    # Calculate BILLABLE tokens (likely what counts toward limit)
    # Input + Output + Cache Create (Cache Read may not count)
    billable_tokens = tokens_in + tokens_out + cache_create

    # Burn rate
    billable_per_min = billable_tokens / elapsed_minutes if elapsed_minutes > 0 else 0
    cost_per_hour = (total_api_cost / elapsed_minutes * 60) if elapsed_minutes > 0 else 0

    # Projections for end of block
    projected_billable = billable_tokens + (billable_per_min * remaining_minutes) if billable_per_min > 0 else billable_tokens
    projected_cost = total_api_cost + (cost_per_hour * remaining_minutes / 60) if cost_per_hour > 0 else total_api_cost
    
    # Calculate burn rates for display
    burn_cost_12h = cost_per_hour * 12
    # Plan tokens per hour (approx)
    plan_tokens = tokens_in + tokens_out
    plan_per_min = plan_tokens / elapsed_minutes if elapsed_minutes > 0 else 0
    burn_tk_hour = plan_per_min * 60
    
    # Time to reach 225k plan tokens
    tokens_to_limit = MAX5_TOTAL_5H - plan_tokens
    time_to_limit = tokens_to_limit / plan_per_min if plan_per_min > 0 else float('inf')
    
    # Time to reach $100 API cost
    cost_to_100 = 100 - total_api_cost
    time_to_100 = cost_to_100 / cost_per_min if cost_per_min > 0 and cost_to_100 > 0 else float('inf')
    
    # Usage pct
    usage_pct = (plan_tokens / MAX5_TOTAL_5H) * 100 if MAX5_TOTAL_5H > 0 else 0

    # Print DATA Block (Prices + Limits)
    print()
    print("╔" + "═" * 108 + "╗")
    print("║" + "  DATA  ".center(108) + "║")
    print("╠" + "═" * 108 + "╣")
    
    print("║" + "  PRICES (per 1M tokens):".ljust(108) + "║")
    print("║" + "    Type            Claude_Haiku_4_5  Claude_Sonnet_4_5   Claude_Opus_4_5  Gemini_Flash_3_0  Gemini_Pro_3_0   ".ljust(108) + "║")
    print("║" + "    Input (no Cache)      $0.80             $3.00           $15.00            $1.25             $1.25     ".ljust(108) + "║")
    print("║" + "    Cache Create          $1.00             $3.75           $18.75            $1.25             $1.25     ".ljust(108) + "║")
    print("║" + "    Cache Read            $0.08             $0.30            $1.50            $0.31             $0.31     ".ljust(108) + "║")
    print("║" + "    Output                $4.00            $15.00           $75.00            $5.00             $5.00     ".ljust(108) + "║")
    print("║" + "    Cache Storage ($/1M token/hr)".ljust(108) + "║")
    print("║" + "                            $0.01             $0.01            $0.01            $1.00             $4.50     ".ljust(108) + "║")
    print("║" + "-" * 108 + "║")
    print("║" + "  TOKENS BURN RATE LIMIT (per 5h window, assuming 2k tokens/msg):".ljust(108) + "║")
    print("║" + "    Claude Pro:   45 msgs / 90k tokens".ljust(108) + "║")
    print("║" + "    Claude Max5x: 225 msgs / 450k tokens".ljust(108) + "║")
    print("║" + "    Claude Max20x:900 msgs / 1.8M tokens".ljust(108) + "║")
    print("║" + "    Gemini Flash 3.5: 166 msgs / 332k tokens".ljust(108) + "║")
    print("║" + "    Gemini Pro 3.5:   33 msgs / 66k tokens".ljust(108) + "║")
    print("╚" + "═" * 108 + "╝")
    print()
