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

# Claude Max5 plan limits per 5-hour window
# Source: https://support.claude.com/en/articles/11014257-about-claude-s-max-plan-usage
# NOTE: Anthropic does NOT disclose exact token limits publicly!
# The "225 messages per 5h" is the only official guidance for Max5x
# Token counting formula is not disclosed - these are ESTIMATES only
MAX5_TOTAL_5H = 225000      # ESTIMATE - actual limit unknown, varies by usage pattern

# Daily limits (3 windows per day as reasonable usage)
WINDOWS_PER_DAY = 3
MAX_INPUT_DAILY = 900000    # 900k input/day
MAX_OUTPUT_DAILY = 300000   # 300k output/day
MAX_CACHE_DAILY = 3000000   # 3M cache/day

# API Pricing per 1M tokens (Claude 3.5/3.7 Sonnet)
# Source: https://www.anthropic.com/pricing
PRICE_INPUT = 3.00          # $3.00 per 1M input tokens
PRICE_OUTPUT = 15.00        # $15.00 per 1M output tokens
PRICE_CACHE_READ = 0.30     # $0.30 per 1M cache read tokens
PRICE_CACHE_CREATE = 3.75   # $3.75 per 1M cache creation tokens


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

    # Print output
    print()
    print("╔" + "═" * 78 + "╗")
    print("║" + "  CURRENT 5-HOUR BLOCK STATUS  ".center(78) + "║")
    print("╠" + "═" * 78 + "╣")

    # Time section
    print("║" + f"  Block Started: {start_time}".ljust(78) + "║")
    print("║" + f"  Elapsed: {format_duration(elapsed_minutes)}  |  Remaining: {format_duration(remaining_minutes)}".ljust(78) + "║")
    print("╠" + "═" * 78 + "╣")

    # Token breakdown
    print("║" + "  TOKEN BREAKDOWN".ljust(78) + "║")
    print("║" + "-" * 78 + "║")
    print("║" + f"  {'Type':<20} {'Tokens':>12} {'Cost':>10}".ljust(78) + "║")
    print("║" + "-" * 78 + "║")
    print("║" + f"  {'Input (New)':<20} {format_tokens(tokens_in):>12} {'$'+f'{cost_in:.2f}':>10}".ljust(78) + "║")
    print("║" + f"  {'Output':<20} {format_tokens(tokens_out):>12} {'$'+f'{cost_out:.2f}':>10}".ljust(78) + "║")
    print("║" + f"  {'Cache Create':<20} {format_tokens(cache_create):>12} {'$'+f'{cost_cache_create:.2f}':>10}".ljust(78) + "║")
    print("║" + f"  {'Cache Read':<20} {format_tokens(cache_read):>12} {'$'+f'{cost_cache_read:.2f}':>10}".ljust(78) + "║")
    print("║" + "-" * 78 + "║")
    plan_tokens = tokens_in + tokens_out
    print("║" + f"  {'Total Plan':<20} {format_tokens(plan_tokens):>12} {'$'+f'{cost_in+cost_out:.2f}':>10}  (Input + Output)".ljust(78) + "║")
    print("║" + f"  {'Total API':<20} {format_tokens(total_tokens):>12} {'$'+f'{total_api_cost:.2f}':>10}  (all tokens)".ljust(78) + "║")
    print("╠" + "═" * 78 + "╣")

    # Usage bar (Plan tokens vs 225k estimate)
    usage_pct = (plan_tokens / MAX5_TOTAL_5H) * 100 if MAX5_TOTAL_5H > 0 else 0
    print("║" + "  USAGE".ljust(78) + "║")
    print("║" + "-" * 78 + "║")
    bar_width = 50
    filled = int(bar_width * min(usage_pct, 100) / 100)
    bar = "█" * filled + "░" * (bar_width - filled)
    print("║" + f"  [{bar}] {usage_pct:.1f}%".ljust(78) + "║")
    print("║" + f"  Plan: {format_tokens(plan_tokens)} / ~225k (Input + Output vs Max5x estimate)".ljust(78) + "║")
    print("╠" + "═" * 78 + "╣")

    # Stats section
    plan_per_min = plan_tokens / elapsed_minutes if elapsed_minutes > 0 else 0
    cost_per_min = total_api_cost / elapsed_minutes if elapsed_minutes > 0 else 0
    projected_plan = plan_tokens + (plan_per_min * remaining_minutes) if plan_per_min > 0 else plan_tokens

    # Time to reach 225k plan tokens
    tokens_to_limit = MAX5_TOTAL_5H - plan_tokens
    time_to_limit = tokens_to_limit / plan_per_min if plan_per_min > 0 else float('inf')
    cost_at_limit = total_api_cost + (cost_per_min * time_to_limit) if time_to_limit != float('inf') else 0

    # Time to reach $100 API cost
    cost_to_100 = 100 - total_api_cost
    time_to_100 = cost_to_100 / cost_per_min if cost_per_min > 0 and cost_to_100 > 0 else float('inf')
    plan_at_100 = plan_tokens + (plan_per_min * time_to_100) if time_to_100 != float('inf') else 0

    print("║" + "  STATS".ljust(78) + "║")
    print("║" + "-" * 78 + "║")
    print("║" + f"  Burn rate: {format_tokens(int(plan_per_min))}/min plan, ${cost_per_hour:.2f}/hour API".ljust(78) + "║")
    if time_to_limit != float('inf') and time_to_limit > 0:
        print("║" + f"  Time to 225k: {format_duration(time_to_limit)} (~${cost_at_limit:.2f} API) | E: {format_duration(elapsed_minutes)} | R: {format_duration(remaining_minutes)}".ljust(78) + "║")
    if time_to_100 != float('inf') and time_to_100 > 0:
        print("║" + f"  Time to $100: {format_duration(time_to_100)} (~{format_tokens(int(plan_at_100))} plan)".ljust(78) + "║")
    print("║" + f"  End of 5h: ~{format_tokens(int(projected_plan))} plan, ~${projected_cost:.2f} API".ljust(78) + "║")
    print("╠" + "═" * 78 + "╣")

    # Notes section
    print("║" + "  NOTES".ljust(78) + "║")
    print("║" + "-" * 78 + "║")
    print("║" + "  Current plan: Max 5x".ljust(78) + "║")
    print("║" + "-" * 78 + "║")
    print("║" + "  Plan Limits (per 5h window, estimates):".ljust(78) + "║")
    print("║" + "    Pro: ~45 msgs (~45k tokens)   Max5x: ~225 msgs (~225k tokens)".ljust(78) + "║")
    print("║" + "    Max20x: ~900 msgs (~900k tokens)".ljust(78) + "║")
    print("║" + "-" * 78 + "║")
    print("║" + "  API Prices (per 1M tokens):".ljust(78) + "║")
    print("║" + "    Input: $3.00   Output: $15.00   Cache Read: $0.30   Cache Create: $3.75".ljust(78) + "║")
    print("╚" + "═" * 78 + "╝")
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


if __name__ == "__main__":
    main()
