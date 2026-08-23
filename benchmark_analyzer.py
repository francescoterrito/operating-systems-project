#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
import re
import numpy as np
import argparse
from collections import defaultdict
import matplotlib.pyplot as plt

def parse_log_file(filename):
    """
    Parses a QEMU output log file to extract wait_sum data for each scenario.
    """
    results = defaultdict(list)
    current_children = 0
    try:
        with open(filename, 'r') as f:
            for line in f:
                # Updated regex to match the new output format
                scenario_match = re.search(r"Starting test scenario with (\d+) CPU children", line)
                if scenario_match:
                    current_children = int(scenario_match.group(1))
                    continue
                # Regex to find the total wait sum from io_load's output
                iteration_match = re.search(
                    r"TOTAL_WAIT_SUM: ([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)",
                    line,
                )
                if iteration_match and current_children > 0:
                    wait_sum = float(iteration_match.group(1))
                    results[current_children].append(wait_sum)
    except FileNotFoundError:
        print(f"Error: File not found at '{filename}'")
        return None
    return dict(sorted(results.items()))

def calculate_robust_stats(data):
    """
    Calculates robust average and standard deviation by removing outliers using the IQR method.
    Returns mean and standard deviation of the filtered data.
    """
    if len(data) < 4: # Need enough data for meaningful stats
        return np.mean(data) if data else 0.0, np.std(data) if data else 0.0

    data_array = np.array(data)
    q1 = np.percentile(data_array, 25)
    q3 = np.percentile(data_array, 75)
    iqr = q3 - q1
    lower_bound = q1 - 1.5 * iqr
    upper_bound = q3 + 1.5 * iqr
    
    filtered_data = data_array[(data_array >= lower_bound) & (data_array <= upper_bound)]
    
    if filtered_data.size == 0: # Handle case where all data is filtered
        return 0.0, 0.0
        
    return np.mean(filtered_data), np.std(filtered_data)

def create_plot(results_data, output_filename="benchmark_comparison.png"):
    """
    Generates and saves a bar chart comparing benchmark results with error bars.
    """
    if not results_data:
        print("No data available to plot.")
        return

    labels = [res["children"] for res in results_data]
    before_means = [res["before_avg"] for res in results_data]
    after_means = [res["after_avg"] for res in results_data]
    before_std = [res["before_std"] for res in results_data]
    after_std = [res["after_std"] for res in results_data]
    improvements = [res["improvement"] for res in results_data]

    x = np.arange(len(labels))
    width = 0.35

    fig, ax1 = plt.subplots(figsize=(12, 7))

    # **FIXED**: Changed color from 'rgba(...)' string to a float tuple (R, G, B, Alpha)
    rects1 = ax1.bar(x - width/2, before_means, width, yerr=before_std, capsize=5,
                     label='Before Patch', color=(0.4, 0.6, 0.8, 0.8), edgecolor='black')
    rects2 = ax1.bar(x + width/2, after_means, width, yerr=after_std, capsize=5,
                     label='After Patch', color=(1.0, 0.4, 0.4, 0.8), edgecolor='black')

    ax1.set_ylabel('Mean Wait Time (ms)', fontsize=12)
    ax1.set_xlabel('Number of Competing CPU-Bound Processes', fontsize=12)
    ax1.set_title('Scheduler Wait Time Before vs. After Wakeup Boost Patch', fontsize=16, pad=20)
    ax1.set_xticks(x)
    ax1.set_xticklabels(labels)
    ax1.legend(loc='upper left')
    ax1.grid(axis='y', linestyle='--', alpha=0.7)

    ax1.bar_label(rects1, padding=3, fmt='%.0f')
    ax1.bar_label(rects2, padding=3, fmt='%.0f')

    # Line Chart for Improvement
    ax2 = ax1.twinx()
    ax2.set_ylabel('Improvement (%)', color='#006400', fontsize=12)
    ax2.plot(x, improvements, color='#006400', marker='o', linestyle='--', label='Improvement (%)')
    ax2.tick_params(axis='y', labelcolor='#006400')
    improvement_min = min(0, min(improvements))
    improvement_max = max(0, max(improvements))
    improvement_padding = max(1, (improvement_max - improvement_min) * 0.1)
    ax2.set_ylim(improvement_min - (improvement_padding if improvement_min < 0 else 0),
                 improvement_max + (improvement_padding if improvement_max > 0 else 0))
    ax2.legend(loc='upper right')

    fig.tight_layout()
    plt.savefig(output_filename, dpi=300)
    print(f"\nGraph saved successfully as '{output_filename}'")


def main():
    parser = argparse.ArgumentParser(description="Analyzes and plots benchmark output files.")
    parser.add_argument("before_file", help="Path to the 'before' patch output file.")
    parser.add_argument("after_file", help="Path to the 'after' patch output file.")
    parser.add_argument("--output", default="benchmark_comparison.png",
                        help="Path for the generated comparison graph.")
    args = parser.parse_args()

    print("--- Robust Benchmark Analysis ---")
    before_data = parse_log_file(args.before_file)
    after_data = parse_log_file(args.after_file)

    if before_data is None or after_data is None:
        return

    results_table_data = []
    all_scenarios = sorted(list(set(before_data.keys()) | set(after_data.keys())))

    for children in all_scenarios:
        before_raw = before_data.get(children, [])
        after_raw = after_data.get(children, [])
        if not before_raw or not after_raw:
            continue
        if len(before_raw) != len(after_raw):
            print(f"Warning: skipping {children} children because the sample counts differ "
                  f"({len(before_raw)} before, {len(after_raw)} after).")
            continue

        before_avg, before_std = calculate_robust_stats(before_raw)
        after_avg, after_std = calculate_robust_stats(after_raw)
        improvement = ((before_avg - after_avg) / before_avg) * 100 if before_avg > 0 else 0

        results_table_data.append({
            "children": children, 
            "before_avg": before_avg, "before_std": before_std,
            "after_avg": after_avg, "after_std": after_std,
            "improvement": improvement
        })

    print("\n--- Final Results (IQR Outliers Removed When Possible) ---")
    header = "| {:<12} | {:<22} | {:<21} | {:<20} |".format(
        "CPU Children", "Mean Before (ms)", "Mean After (ms)", "Improvement"
    )
    print(header)
    print("|" + "-" * (len(header) - 2) + "|")
    for res in results_table_data:
        print("| {:<12} | {:<22.2f} | {:<21.2f} | {:>16.1f}%     |".format(
            res["children"], res["before_avg"], res["after_avg"], res["improvement"]
        ))
    
    create_plot(results_table_data, args.output)

if __name__ == "__main__":
    main()
