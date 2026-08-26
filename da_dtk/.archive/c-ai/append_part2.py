
with open("ops-Tooling/1_Apps_Dash/ccusage_report.py", "a") as f:
    f.write(r'''

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

    # Print DASH Block
    print()
    print("╔" + "═" * 108 + "╗")
    print("║" + "  DASH  ".center(108) + "║")
    print("╠" + "═" * 108 + "╣")
    print("║" + "  Current Plan: Claude Max 5x".ljust(108) + "║")
    print("║" + "-" * 108 + "║")

    # SESSION Section
    # Calculate finish time
    try:
        start_dt = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        finish_dt = start_dt + datetime.timedelta(hours=5)
        finish_time = finish_dt.strftime("%H:%M:%S")
    except:
        finish_time = "?"

    print("║" + "  SESSION".ljust(108) + "║")
    print("║" + f"    Time Started: {start_time:<20}  Time Finish: {finish_time:<20}".ljust(108) + "║")
    print("║" + f"    Total:        5h 0m                 Elapsed:     {format_duration(elapsed_minutes):<20}".ljust(108) + "║")
    print("║" + f"    Remaining:    {format_duration(remaining_minutes):<20}".ljust(108) + "║")
    print("║" + "-" * 108 + "║")

    # USAGE Section (Table)
    # Columns: Type | Input | CacheCr | CacheRd | Output | Storage | T.API | T.Plan | $Plan | $API | Burn$/12h | BurnTk/h
    # Widths:  20   | 7     | 7       | 7       | 7      | 7       | 7     | 7      | 6     | 6    | 9         | 9
    
    header = f"  {'Type':<20} {'Input':>7} {'CacheCr':>7} {'CacheRd':>7} {'Output':>7} {'Storage':>7} {'T.API':>7} {'T.Plan':>7} {'$Plan':>6} {'$API':>6} {'Burn$/12h':>9} {'BurnTk/h':>9}"
    print("║" + "  USAGE".ljust(108) + "║")
    print("║" + header.ljust(108) + "║")
    print("║" + "  " + "-" * 106 + "║")

    # Row for Total Claude (using aggregate data)
    row_claude = f"  {'Total Claude':<20} {format_tokens(tokens_in):>7} {format_tokens(cache_create):>7} {format_tokens(cache_read):>7} {format_tokens(tokens_out):>7} {'-':>7} {format_tokens(total_tokens):>7} {format_tokens(plan_tokens):>7} {cost_in+cost_out:>6.2f} {total_api_cost:>6.2f} {burn_cost_12h:>9.2f} {format_tokens(int(burn_tk_hour)):>9}"
    print("║" + row_claude.ljust(108) + "║")
    
    # Placeholder rows for sub-models
    print("║" + f"  {'  - Haiku 3.5':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")
    print("║" + f"  {'  - Sonnet 3.5':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")
    print("║" + f"  {'  - Opus 3.5':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")

    # Placeholder row for Total Gemini
    row_gemini = f"  {'Total Gemini':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}"
    print("║" + row_gemini.ljust(108) + "║")
    print("║" + f"  {'  - Flash 2.0':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")
    print("║" + f"  {'  - Pro 2.0':<20} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>7} {'-':>6} {'-':>6} {'-':>9} {'-':>9}".ljust(108) + "║")

    print("║" + "-" * 108 + "║")

    # PROJECTION Section
    print("║" + "  PROJECTION".ljust(108) + "║")
    print("║" + f"    End of 5h: ~{format_tokens(int(projected_plan))} plan, ~${projected_cost:.2f} API".ljust(108) + "║")
    if time_to_limit != float('inf') and time_to_limit > 0:
         print("║" + f"    Time to 450k limit: {format_duration(time_to_limit)}".ljust(108) + "║")
    if time_to_100 != float('inf') and time_to_100 > 0:
         print("║" + f"    Time to $100 budget: {format_duration(time_to_100)}".ljust(108) + "║")
    
    # Visual Bar
    bar_width = 80
    filled = int(bar_width * min(usage_pct, 100) / 100)
    bar = "█" * filled + "░" * (bar_width - filled)
    print("║" + "-" * 108 + "║")
    print("║" + f"  [{bar}] {usage_pct:.1f}%".ljust(108) + "║")

    print("╚" + "═" * 108 + "╝")
    print()
'''
    )
