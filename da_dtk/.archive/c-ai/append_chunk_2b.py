
def append_to_file():
    with open("ops-Tooling/1_Apps_Dash/ccusage_report.py", "a") as f:
        f.write(r'''

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
""")
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
