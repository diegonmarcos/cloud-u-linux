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
    """Print detailed current 5h block status with cost breakdown matching HTML spec."""

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

    # Extract token counts
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

    # Calculate elapsed
    try:
        start_dt = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        elapsed_minutes = (datetime.now(start_dt.tzinfo) - start_dt).total_seconds() / 60
    except:
        elapsed_minutes = 300 - remaining_minutes

    # Calculate Costs
    cost_in = calculate_cost(tokens_in, PRICE_INPUT)
    cost_out = calculate_cost(tokens_out, PRICE_OUTPUT)
    cost_cache_read = calculate_cost(cache_read, PRICE_CACHE_READ)
    cost_cache_create = calculate_cost(cache_create, PRICE_CACHE_CREATE)
    total_api_cost = cost_in + cost_out + cost_cache_read + cost_cache_create

    # Rates & Projections
    plan_tokens = tokens_in + tokens_out
    plan_per_min = plan_tokens / elapsed_minutes if elapsed_minutes > 0 else 0
    cost_per_hour = (total_api_cost / elapsed_minutes * 60) if elapsed_minutes > 0 else 0
    cost_per_min = total_api_cost / elapsed_minutes if elapsed_minutes > 0 else 0
    
    projected_plan = plan_tokens + (plan_per_min * remaining_minutes) if plan_per_min > 0 else plan_tokens
    projected_cost = total_api_cost + (cost_per_hour * remaining_minutes / 60) if cost_per_hour > 0 else total_api_cost
    
    burn_cost_12h = cost_per_hour * 12
    burn_tk_hour = plan_per_min * 60
    
    usage_pct = (plan_tokens / MAX5_TOTAL_5H) * 100 if MAX5_TOTAL_5H > 0 else 0
    
    tokens_to_limit = MAX5_TOTAL_5H - plan_tokens
    time_to_limit = tokens_to_limit / plan_per_min if plan_per_min > 0 else float('inf')
    cost_to_100 = 100 - total_api_cost
    time_to_100 = cost_to_100 / cost_per_min if cost_per_min > 0 and cost_to_100 > 0 else float('inf')

    try:
        finish_dt = start_dt + datetime.timedelta(hours=5)
        finish_time = finish_dt.strftime("%H:%M:%S")
    except:
        finish_time = "?"

    # --- TUI OUTPUT ---
    print()
    print("╔" + "═" * 108 + "╗")
    
    # 1. BACK AND VARIABLES (Skipped for TUI brevity, just title)
    # print("║" + "  BACK AND VARIABLES".ljust(108) + "║")
    
    # 2. TOKENS BURN RATE LIMIT
    print("║" + "  TOKENS BURN RATE LIMIT (per 5h window)".ljust(108) + "║")
    print("║" + "    Plan             Messages (0)    Tokens          |  Plan             Messages        Tokens".ljust(108) + "║")
    print("║" + "    Pro (H+O+S)      45              90,000          |  Flash_3_5        166             332,000".ljust(108) + "║")
    print("║" + "    Max 5x (H+O+S)   225             450,000         |  Pro_3_5          33              66,000".ljust(108) + "║")
    print("║" + "    Max 20x (H+O+S)  900             1,800,000       |  -                -               -".ljust(108) + "║")
    print("║" + "    (0) Assuming 2,000 tokens per message".ljust(108) + "║")
    print("║" + "-" * 108 + "║")

    # 3. PRICES
    print("║" + "  PRICES".ljust(108) + "║")
    print("║" + "    Type            Token Type        Claude_Haiku_4.5  Sonnet_4.5  Opus_4.5   Gemini_Flash_3.0  Gemini_Pro_3.0 ".ljust(108) + "║")
    print("║" + "    $/1M Tokens     Input (no Cache)  $0.80             $3.00       $15.00     $1.25             $1.25          ".ljust(108) + "║")
    print("║" + "    $/1M Tokens     Cache Create      $1.00             $3.75       $18.75     $1.25             $1.25          ".ljust(108) + "║")
    print("║" + "    $/1M Tokens     Cache Read        $0.08             $0.30       $1.50      $0.31             $0.31          ".ljust(108) + "║")
    print("║" + "    $/1M Tokens     Output            $4.00             $15.00      $75.00     $5.00             $5.00          ".ljust(108) + "║")
    print("║" + "    $/1M Tk/hr      Cache Storage     $0.01             $0.01       $0.01      $1.00             $4.50          ".ljust(108) + "║")
    print("║" + "-" * 108 + "║")

    # 4. CACHE LIMIT
    print("║" + "  CACHE LIMIT".ljust(108) + "║")
    print("║" + "    Plan             Max Context W     Reset         Cache Storage Price".ljust(108) + "║")
    print("║" + "    Pro (H+O+S)      200,000           no limit      0.01".ljust(108) + "║")
    print("║" + "    Gemini_Flash_3.0 1,000,000         24h           1.00".ljust(108) + "║")
    print("║" + "    Gemini_Pro_3.0   1,000,000         24h           4.50".ljust(108) + "║")
    print("║" + "═" * 108 + "║")

    # 5. DASH
    print("║" + "  DASH".center(108) + "║")
    print("║" + "  Current Plan: Claude Max 5x".ljust(108) + "║")
    print("║" + "-" * 108 + "║")

    # SESSION
    print("║" + "  ## SESSION".ljust(108) + "║")
    print("║" + f"    Time Started: {start_time:<20}  Time Finish: {finish_time:<20}".ljust(108) + "║")
    print("║" + f"    Total:        5h 0m                 Elapsed:     {format_duration(elapsed_minutes):<20}".ljust(108) + "║")
    print("║" + f"    Remaining:    {format_duration(remaining_minutes):<20}".ljust(108) + "║")
    print("║" + "-" * 108 + "║")

    # USAGE
    print("║" + "  ## USAGE".ljust(108) + "║")
    header = f"  {'Type':<20} {'Input':>7} {'CacheCr':>7} {'CacheRd':>7} {'Output':>7} {'Storage':>7} {'T.API':>7} {'T.Plan':>7} {'$Plan':>6} {'$API':>6} {'Burn$/12h':>9} {'BurnTk/h':>9}"
    print("║" + header.ljust(108) + "║")
    print("║" + "  " + "-" * 106 + "║")

    row_claude = f"  {'Total Claude':<20} {format_tokens(tokens_in):>7} {format_tokens(cache_create):>7} {format_tokens(cache_read):>7} {format_tokens(tokens_out):>7} {'-':>7} {format_tokens(total_tokens):>7} {format_tokens(plan_tokens):>7} {cost_in+cost_out:>6.2f} {total_api_cost:>6.2f} {burn_cost_12h:>9.2f} {format_tokens(int(burn_tk_hour)):>9}"
    print("║" + row_claude.ljust(108) + "║")
    
    # Placeholder rows
    print("║" + f"  {'  - Haiku 3.5':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")
    print("║" + f"  {'  - Sonnet 3.5':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")
    print("║" + f"  {'  - Opus 3.5':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")
    
    row_gemini = f"  {'Total Gemini':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}"
    print("║" + row_gemini.ljust(108) + "║")
    print("║" + f"  {'  - Flash 2.0':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")
    print("║" + f"  {'  - Pro 2.0':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")
    print("║" + "-" * 108 + "║")

    # PROJECTION
    print("║" + "  ## PROJECTION".ljust(108) + "║")
    print("║" + f"    End of 5h: ~{format_tokens(int(projected_plan))} plan, ~${projected_cost:.2f} API".ljust(108) + "║")
    if time_to_limit != float('inf') and time_to_limit > 0:
         print("║" + f"    Time to 450k limit: {format_duration(time_to_limit)}".ljust(108) + "║")
    if time_to_100 != float('inf') and time_to_100 > 0:
         print("║" + f"    Time to $100 budget: {format_duration(time_to_100)}".ljust(108) + "║")
    
    bar_width = 80
    filled = int(bar_width * min(usage_pct, 100) / 100)
    bar = "█" * filled + "░" * (bar_width - filled)
    print("║" + "-" * 108 + "║")
    print("║" + f"  [{bar}] {usage_pct:.1f}%".ljust(108) + "║")
    
    print("╚" + "═" * 108 + "╝")
    print()


def get_usage_rows(data: dict) -> list:
    """Process ccusage data and return list of row dicts."""
    rows = []

    for day in data.get("daily", []):
        date = day["date"]
        tokens_in = day["inputTokens"]
        tokens_out = day["outputTokens"]
        cache_read = day["cacheReadTokens"]
        cache_create = day.get("cacheCreationTokens", 0)
        total_tokens = day["totalTokens"]

        # Calculate costs
        cost_in = calculate_cost(tokens_in, PRICE_INPUT)
        cost_out = calculate_cost(tokens_out, PRICE_OUTPUT)
        cost_cache_read = calculate_cost(cache_read, PRICE_CACHE_READ)
        cost_cache_create = calculate_cost(cache_create, PRICE_CACHE_CREATE)
        total_cost = day["totalCost"]

        # Calculate percentages of daily limits
        pct_in = (tokens_in / MAX_INPUT_DAILY) * 100
        pct_out = (tokens_out / MAX_OUTPUT_DAILY) * 100
        pct_cache = (cache_read / MAX_CACHE_DAILY) * 100

        rows.append({
            "date": date,
            "tokens_in": tokens_in,
            "tokens_out": tokens_out,
            "cache_read": cache_read,
            "cache_create": cache_create,
            "total_tokens": total_tokens,
            "cost_in": round(cost_in, 4),
            "cost_out": round(cost_out, 4),
            "cost_cache_read": round(cost_cache_read, 4),
            "cost_cache_create": round(cost_cache_create, 4),
            "total_cost": round(total_cost, 2),
            "pct_in": round(pct_in, 1),
            "pct_out": round(pct_out, 1),
            "pct_cache": round(pct_cache, 1),
        })

    # Add totals row
    if data.get("total"):
        totals = data["total"]
        rows.append({
            "date": "TOTAL",
            "tokens_in": totals["inputTokens"],
            "tokens_out": totals["outputTokens"],
            "cache_read": totals["cacheReadTokens"],
            "cache_create": totals.get("cacheCreationTokens", 0),
            "total_tokens": totals["totalTokens"],
            "cost_in": round(calculate_cost(totals["inputTokens"], PRICE_INPUT), 4),
            "cost_out": round(calculate_cost(totals["outputTokens"], PRICE_OUTPUT), 4),
            "cost_cache_read": round(calculate_cost(totals["cacheReadTokens"], PRICE_CACHE_READ), 4),
            "cost_cache_create": round(calculate_cost(totals.get("cacheCreationTokens", 0), PRICE_CACHE_CREATE), 4),
            "total_cost": round(totals["totalCost"], 2),
            "pct_in": "-",
            "pct_out": "-",
            "pct_cache": "-",
        })

    return rows


def output_table(rows: list, daily_time: dict = None):
    """Print daily usage table to stdout."""
    daily_plan_limit = MAX5_TOTAL_5H * WINDOWS_PER_DAY  # 675k
    if daily_time is None:
        daily_time = {}

    print()
    print("=" * 135)
    print(f"{'Date':<12} {'Input':>7} {'Output':>7} {'CacheRd':>9} {'CacheCr':>9} {'T.Plan':>7} {'T.API':>9} {'$Plan':>7} {'$API':>7} {'%Plan':>6} {'Time':>6} {'Burn$':>8} {'BurnTk':>8}")
    print("-" * 135)

    for row in rows:
        if row["date"] == "TOTAL":
            print("-" * 135)

        # Plan tokens = Input + Output
        plan_tokens = row['tokens_in'] + row['tokens_out']
        total_api_tokens = row['tokens_in'] + row['tokens_out'] + row['cache_read'] + row['cache_create']

        # Costs
        plan_cost = calculate_cost(row['tokens_in'], PRICE_INPUT) + calculate_cost(row['tokens_out'], PRICE_OUTPUT)
        api_cost = row['total_cost']

        # % of daily plan limit (3 windows × 225k = 675k)
        pct_plan = (plan_tokens / daily_plan_limit) * 100 if row['date'] != "TOTAL" else None
        pct_str = f"{pct_plan:.0f}%" if pct_plan is not None else "-"

        # Get actual time from blocks data
        # Burn$ = ($Plan / Time) × 12h
        # BurnTk = T.Plan / Time
        if row['date'] != "TOTAL":
            time_hours = daily_time.get(row['date'], 0)
            if time_hours > 0:
                time_str = f"{time_hours:.1f}h"
                burn_cost = (plan_cost / time_hours) * 12
                burn_cost_str = f"${burn_cost:.2f}"
                burn_tokens = plan_tokens / time_hours
                burn_tk_str = f"{burn_tokens/1000:.1f}k/h"
            else:
                time_str = "-"
                burn_cost_str = "-"
                burn_tk_str = "-"
        else:
            time_str = "-"
            burn_cost_str = "-"
            burn_tk_str = "-"

        print(f"{row['date']:<12} {format_tokens(row['tokens_in']):>7} {format_tokens(row['tokens_out']):>7} {format_tokens(row['cache_read']):>9} {format_tokens(row['cache_create']):>9} {format_tokens(plan_tokens):>7} {format_tokens(total_api_tokens):>9} ${plan_cost:>5.2f} ${api_cost:>5.2f} {pct_str:>6} {time_str:>6} {burn_cost_str:>8} {burn_tk_str:>8}")

    print("=" * 135)
    print()
    print("Notes:")
    print("  T.Plan = Input + Output | T.API = all tokens | $Plan = In×$3 + Out×$15 | $API = all costs")
    print("  %Plan = T.Plan / 675k | Time = actual session hours | Burn$ = ($Plan/Time)×12h | BurnTk = T.Plan/Time")
    print()


def output_csv(rows: list, daily_time: dict, output_file: Path):
    """Write CSV file."""
    daily_plan_limit = MAX5_TOTAL_5H * WINDOWS_PER_DAY  # 675k

    fieldnames = [
        "date", "input", "output", "cache_read", "cache_create",
        "total_plan", "total_api", "cost_plan", "cost_api", "pct_plan", "time_hours", "burn_cost_12h", "burn_tokens_per_hour"
    ]

    csv_rows = []
    for row in rows:
        plan_tokens = row['tokens_in'] + row['tokens_out']
        total_api_tokens = row['tokens_in'] + row['tokens_out'] + row['cache_read'] + row['cache_create']
        plan_cost = calculate_cost(row['tokens_in'], PRICE_INPUT) + calculate_cost(row['tokens_out'], PRICE_OUTPUT)

        if row['date'] != "TOTAL":
            pct_plan = round((plan_tokens / daily_plan_limit) * 100, 1)
            time_hours = daily_time.get(row['date'], 0)
            if time_hours > 0:
                burn_cost_12h = round((plan_cost / time_hours) * 12, 2)
                burn_tokens = int(plan_tokens / time_hours)
            else:
                burn_cost_12h = "-"
                burn_tokens = "-"
            time_hours = round(time_hours, 1) if time_hours > 0 else "-"
        else:
            pct_plan = "-"
            time_hours = "-"
            burn_cost_12h = "-"
            burn_tokens = "-"

        csv_rows.append({
            "date": row['date'],
            "input": row['tokens_in'],
            "output": row['tokens_out'],
            "cache_read": row['cache_read'],
            "cache_create": row['cache_create'],
            "total_plan": plan_tokens,
            "total_api": total_api_tokens,
            "cost_plan": round(plan_cost, 2),
            "cost_api": row['total_cost'],
            "pct_plan": pct_plan,
            "time_hours": time_hours,
            "burn_cost_12h": burn_cost_12h,
            "burn_tokens_per_hour": burn_tokens
        })

    with open(output_file, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(csv_rows)

    print(f"CSV report saved: {output_file}")
    total_row = rows[-1] if rows and rows[-1]["date"] == "TOTAL" else None
    if total_row:
        print(f"  Days: {len(rows) - 1}")
        print(f"  Total cost: ${total_row['total_cost']:.2f}")


def output_markdown(rows: list, daily_time: dict, output_file: Path):
    """Write Markdown file with table."""
    daily_plan_limit = MAX5_TOTAL_5H * WINDOWS_PER_DAY  # 675k

    lines = []
    lines.append("# Claude Code Usage Report")
    lines.append("")
    lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    lines.append("## Daily Usage")
    lines.append("")
    lines.append("| Date | Input | Output | Cache Rd | Cache Cr | T.Plan | T.API | $Plan | $API | %Plan | Time | Burn$ | BurnTk |")
    lines.append("|------|------:|-------:|---------:|---------:|-------:|------:|------:|-----:|------:|-----:|------:|-------:|")

    for row in rows:
        plan_tokens = row['tokens_in'] + row['tokens_out']
        total_api_tokens = row['tokens_in'] + row['tokens_out'] + row['cache_read'] + row['cache_create']
        plan_cost = calculate_cost(row['tokens_in'], PRICE_INPUT) + calculate_cost(row['tokens_out'], PRICE_OUTPUT)

        if row['date'] != "TOTAL":
            pct_plan = (plan_tokens / daily_plan_limit) * 100
            pct_str = f"{pct_plan:.0f}%"
            # Get actual time from blocks data
            time_hours = daily_time.get(row['date'], 0)
            if time_hours > 0:
                time_str = f"{time_hours:.1f}h"
                burn_cost = (plan_cost / time_hours) * 12
                burn_cost_str = f"${burn_cost:.2f}"
                burn_tokens = plan_tokens / time_hours
                burn_tk_str = f"{burn_tokens/1000:.1f}k/h"
            else:
                time_str = "-"
                burn_cost_str = "-"
                burn_tk_str = "-"
        else:
            pct_str = "-"
            time_str = "-"
            burn_cost_str = "-"
            burn_tk_str = "-"

        date_str = f"**{row['date']}**" if row['date'] == "TOTAL" else row['date']
        api_cost_str = f"**${row['total_cost']:.2f}**" if row['date'] == "TOTAL" else f"${row['total_cost']:.2f}"
        plan_cost_str = f"**${plan_cost:.2f}**" if row['date'] == "TOTAL" else f"${plan_cost:.2f}"

        lines.append(f"| {date_str} | {format_tokens(row['tokens_in'])} | {format_tokens(row['tokens_out'])} | {format_tokens(row['cache_read'])} | {format_tokens(row['cache_create'])} | {format_tokens(plan_tokens)} | {format_tokens(total_api_tokens)} | {plan_cost_str} | {api_cost_str} | {pct_str} | {time_str} | {burn_cost_str} | {burn_tk_str} |")

    lines.append("")
    lines.append("## Notes")
    lines.append("")
    lines.append("- **T.Plan** = Input + Output (tokens that count toward plan limit)")
    lines.append("- **T.API** = all tokens (Input + Output + Cache Read + Cache Create)")
    lines.append("- **$Plan** = Input×$3 + Output×$15")
    lines.append("- **$API** = all token costs")
    lines.append("- **%Plan** = T.Plan / daily Max5x limit (~675k = 3 × 225k)")
    lines.append("- **Time** = actual session hours from blocks data")
    lines.append("- **Burn$** = ($Plan / Time) × 12h (projected 12h cost)")
    lines.append("- **BurnTk** = T.Plan / Time (tokens per hour)")
    lines.append("")
    lines.append("## Prices")
    lines.append("")
    lines.append("| Type | Token Type | Claude_Haiku_4_5 | Claude_Sonnet_4_5 | Claude_Opus_4_5 | Gemini_Flash_3_0 | Gemini_Pro_3_0 |")
    lines.append("|:---|:---|---:|---:|---:|---:|---:|")
    lines.append("| $/1M Tokens | Input (no Cache) | 0.80 | 3.00 | 15.00 | 1.25 | 1.25 |")
    lines.append("| $/1M Tokens | Cache Create | 1.00 | 3.75 | 18.75 | 1.25 | 1.25 |")
    lines.append("| $/1M Tokens | Cache Read | 0.08 | 0.30 | 1.50 | 0.31 | 0.31 |")
    lines.append("| $/1M Tokens | Output | 4.00 | 15.00 | 75.00 | 5.00 | 5.00 |")
    lines.append("| $/1M Tokens/hr | Cache Storage | 0.01 | 0.01 | 0.01 | 1.00 | 4.50 |")
    lines.append("")
    lines.append("## Tokens Burn Rate Limit")
    lines.append("")
    lines.append("| Plan | Messages (0) | Tokens | Plan | Messages | Tokens |")
    lines.append("|:---|---:|---:|:---|---:|---:|")
    lines.append("| **Claude** | | | **Gemini (1)** | | |")
    lines.append("| Pro (H+O+S) | 45 | 90,000 | Flash_3_5 | 166 | 332,000 |")
    lines.append("| Max 5x (H+O+S) | 225 | 450,000 | Pro_3_5 | 33 | 66,000 |")
    lines.append("| Max 20x (H+O+S) | 900 | 1,800,000 | - | - | - |")
    lines.append("")
    lines.append("(0) Assuming 2,000 tokens per message")
    lines.append("(1) Standardized with Claude by dividing it 24h window by 3, assuming 3 windows of 5h per day.")
    lines.append("")
    lines.append("## Plan Limits (per 5h window, estimates)")
    lines.append("")
    lines.append("| Plan | Messages | Tokens |")
    lines.append("|------|----------|--------|")
    lines.append("| Pro | ~45 | ~45k |")
    lines.append("| Max 5x | ~225 | ~225k |")
    lines.append("| Max 20x | ~900 | ~900k |")
    lines.append("")
    lines.append("## API Pricing (per 1M tokens)")
    lines.append("")
    lines.append("| Token Type | Price |")
    lines.append("|------------|------:|")
    lines.append(f"| Input | ${PRICE_INPUT:.2f} |")
    lines.append(f"| Output | ${PRICE_OUTPUT:.2f} |")
    lines.append(f"| Cache Read | ${PRICE_CACHE_READ:.2f} |")
    lines.append(f"| Cache Create | ${PRICE_CACHE_CREATE:.2f} |")
    lines.append("")

    with open(output_file, 'w') as f:
        f.write("\n".join(lines))

    print(f"Markdown report saved: {output_file}")
    total_row = rows[-1] if rows and rows[-1]["date"] == "TOTAL" else None
    if total_row:
        print(f"  Days: {len(rows) - 1}")
        print(f"  Total cost: ${total_row['total_cost']:.2f}")


def show_help():
    """Show help message."""
    help_text = """
╔═══════════════════════════════════════════════════════════════════════════════╗
║                      Claude Code Usage Report Generator                        ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║                                                                               ║
║  USAGE:                                                                       ║
║    python ccusage_report.py [OPTIONS]                                         ║
║                                                                               ║
║  OPTIONS:                                                                     ║
║    --now              Show current 5h block with detailed breakdown           ║
║    --daily            Display daily usage table in terminal                   ║
║    --csv [FILE]       Export to CSV file (default: ccusage_report.csv)        ║
║    --md  [FILE]       Export to Markdown file (default: ccusage_report.md)    ║
║    -h, --help         Show this help message                                  ║
║                                                                               ║
║  EXAMPLES:                                                                    ║
║    python ccusage_report.py --now                                             ║
║    python ccusage_report.py --daily                                           ║
║    python ccusage_report.py --csv                                             ║
║    python ccusage_report.py --daily --csv --md    (all outputs)               ║
║                                                                               ║
║  PLAN LIMITS (per 5h window, estimates):                                      ║
║    Pro: ~45 msgs (~45k)   Max5x: ~225 msgs (~225k)   Max20x: ~900 msgs (~900k)║
║                                                                               ║
║  API PRICING (per 1M tokens):                                                 ║
║    Input: $3.00   Output: $15.00   Cache Read: $0.30   Cache Create: $3.75    ║
║                                                                               ║
║  REQUIREMENTS:                                                                ║
║    ccusage - Install with: npm install -g ccusage                             ║
║    More info: https://github.com/ryoppippi/ccusage                            ║
║                                                                               ║
║  DATA SOURCE:                                                                 ║
║    Reads from ~/.claude/projects/ local JSONL files                           ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
"""
    print(help_text)


def main():
    script_dir = Path(__file__).parent

    # Custom argument parsing to handle optional file arguments
    args = sys.argv[1:]

    # Check for help
    if not args or "-h" in args or "--help" in args:
        show_help()
        sys.exit(0)

    do_now = False
    do_daily = False
    do_csv = False
    do_md = False
    csv_file = script_dir / "ccusage_report.csv"
    md_file = script_dir / "ccusage_report.md"

    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--now":
            do_now = True
        elif arg == "--daily":
            do_daily = True
        elif arg == "--csv":
            do_csv = True
            # Check if next arg is a filename (not another flag)
            if i + 1 < len(args) and not args[i + 1].startswith("-"):
                csv_file = Path(args[i + 1])
                i += 1
        elif arg == "--md":
            do_md = True
            # Check if next arg is a filename (not another flag)
            if i + 1 < len(args) and not args[i + 1].startswith("-"):
                md_file = Path(args[i + 1])
                i += 1
        else:
            print(f"Unknown option: {arg}")
            print("Use --help for usage information")
            sys.exit(1)
        i += 1

    # Handle --now (current 5h block with detailed breakdown)
    if do_now:
        if not check_ccusage_installed():
            print("Error: ccusage is not installed.")
            print("\nInstall it with:")
            print("  npm install -g ccusage")
            sys.exit(1)

        try:
            data = get_blocks_data()
            output_now_detailed(data)
        except Exception as e:
            print(f"Error getting block data: {e}")
            print("Falling back to standard ccusage blocks -a...")
            subprocess.run(["ccusage", "blocks", "-a"])

        if not (do_daily or do_csv or do_md):
            sys.exit(0)

    # Fetch data for other reports
    if do_daily or do_csv or do_md:
        print("Fetching usage data from ccusage...")
        data = get_ccusage_data()
        rows = get_usage_rows(data)

        if not rows:
            print("No usage data found.")
            sys.exit(1)

        # Get actual time data from blocks
        daily_time = get_daily_time_from_blocks()

        # Output based on flags
        if do_daily:
            output_table(rows, daily_time)

        if do_csv:
            output_csv(rows, daily_time, csv_file)

        if do_md:
            output_markdown(rows, daily_time, md_file)

    if not (do_now or do_daily or do_csv or do_md):
        show_help()


# =============================================================================
# FLASK API MODULE INTERFACE
# =============================================================================
# These functions provide a clean interface for importing into Flask apps.
# They return JSON-serializable dicts without any print side effects.

def get_now_json() -> dict:
    """Return current 5h block status as JSON-serializable dict for API."""
    data = get_blocks_data()
    if not data or "blocks" not in data:
        return {"error": "No blocks data available"}

    # Find active block
    blocks = data.get("blocks", [])
    block = None
    for b in blocks:
        if b.get("isActive", False):
            block = b
            break

    if not block:
        return {"error": "No active block found"}

    # Extract data
    token_counts = block.get("tokenCounts", {})
    tokens_in = token_counts.get("inputTokens", 0)
    tokens_out = token_counts.get("outputTokens", 0)
    cache_read = token_counts.get("cacheReadInputTokens", 0)
    cache_create = token_counts.get("cacheCreationInputTokens", 0)
    total_tokens = block.get("totalTokens", 0)

    # Calculate costs (using default Sonnet pricing)
    cost_in = (tokens_in / 1_000_000) * PRICE_INPUT
    cost_out = (tokens_out / 1_000_000) * PRICE_OUTPUT
    cost_cache_read = (cache_read / 1_000_000) * PRICE_CACHE_READ
    cost_cache_create = (cache_create / 1_000_000) * PRICE_CACHE_CREATE
    total_cost = cost_in + cost_out + cost_cache_read + cost_cache_create

    # Get time info
    elapsed_ms = block.get("elapsedMs", 0)
    remaining_ms = block.get("remainingMs", 0)
    elapsed_hours = elapsed_ms / (1000 * 60 * 60)

    # Calculate rates
    burn_rate_tokens = (total_tokens / (elapsed_ms / 1000)) * 60 if elapsed_ms > 0 else 0
    burn_rate_cost = (total_cost / elapsed_hours) if elapsed_hours > 0 else 0

    # Get model info if available
    models = block.get("models", [])

    return {
        "block_start": block.get("startTime"),
        "block_end": block.get("endTime"),
        "elapsed_ms": elapsed_ms,
        "remaining_ms": remaining_ms,
        "tokens": {
            "input": tokens_in,
            "output": tokens_out,
            "cache_read": cache_read,
            "cache_create": cache_create,
            "total": total_tokens
        },
        "costs": {
            "input": cost_in,
            "output": cost_out,
            "cache_read": cost_cache_read,
            "cache_create": cost_cache_create,
            "total": total_cost
        },
        "rates": {
            "tokens_per_min": burn_rate_tokens,
            "cost_per_hour": burn_rate_cost
        },
        "models": models
    }


def get_daily_json() -> list:
    """Return daily usage rows as list of dicts for API."""
    data = get_ccusage_data()
    if not data or "daily" not in data:
        return []

    rows = []
    for day in data["daily"]:
        # Calculate costs
        tokens_in = day.get("inputTokens", 0)
        tokens_out = day.get("outputTokens", 0)
        cache_read = day.get("cacheReadInputTokens", 0)
        cache_create = day.get("cacheCreationInputTokens", 0)
        total_tokens = day.get("totalTokens", 0)

        cost = (tokens_in / 1_000_000) * PRICE_INPUT + \
               (tokens_out / 1_000_000) * PRICE_OUTPUT + \
               (cache_read / 1_000_000) * PRICE_CACHE_READ + \
               (cache_create / 1_000_000) * PRICE_CACHE_CREATE

        row = {
            "date": day.get("date", ""),
            "tokens_in": tokens_in,
            "tokens_out": tokens_out,
            "cache_read": cache_read,
            "cache_create": cache_create,
            "total_tokens": total_tokens,
            "cost": cost
        }

        # Add model breakdowns if available
        if "modelBreakdowns" in day:
            row["model_breakdowns"] = day["modelBreakdowns"]

        rows.append(row)

    return rows


def get_budget_json() -> dict:
    """Return budget status as dict for API."""
    data = get_ccusage_data()
    if not data or "daily" not in data:
        return {"error": "No data available"}

    budget = calculate_mtd_budget(data["daily"])
    return budget


def get_models_json() -> dict:
    """Return model breakdown as dict for API."""
    data = get_ccusage_data()
    if not data or "daily" not in data:
        return {"error": "No data available"}

    breakdown = get_model_breakdown_from_daily(data)
    distribution = get_model_distribution(breakdown)

    # Check for Opus alert
    opus_alert = distribution.get("opus", 0) > OPUS_ALERT_PERCENT

    return {
        "breakdown": breakdown,
        "distribution": distribution,
        "opus_alert": opus_alert
    }


if __name__ == "__main__":
    main()
