#
# Run on a trace CSV output from:
#   swiftc -stats-output-dir <stats_dir> -Xfrontend -trace-stats-events ...
#
# * Check for ambiguous trace events (same timestamp, same event name)
# * Keep track of the stack of trace events
# * Print out simplified trace events indented by stack depth
#
import collections
import csv
import glob
import os
import sys
import typing

#STATS_DIR = "S:\\Temp\\stats"
#STATS_DIR = "C:\\Users\\sundresh\\Downloads"
STATS_DIR = "S:\\Temp\\cassowary\\stats"

MAX_PRINT_DEPTH = 2

trace_files = glob.glob(os.path.join(STATS_DIR, "trace-*all-x*.csv"))
if len(trace_files) != 1:
    sys.exit(f"Error: Expected exactly 1 trace-*.csv file in {STATS_DIR}, found {len(trace_files)}")

csv_reader = csv.reader(open(trace_files[0]))
column_headers = next(csv_reader)
last_row = None

def format_rows_recursively(csv_reader, depth):
  output_lines = []
  for row in csv_reader:
    global last_row
    last_row = row
    is_exit = row[2] == "exit"
    event_name = row[3]
    counter_name = row[4]
    counter_value = int(row[6])
    #if counter_name in ("Frontend.NumInstructionsExecuted", "Frontend.NumCyclesExecuted"):
    if counter_name == "Frontend.WallClockMicroseconds":
      if is_exit:
        return (output_lines, row)
      returned_output_lines, exit_row = format_rows_recursively(csv_reader, depth + 1)
      if exit_row is not None:
        assert(exit_row[3] == event_name)
        delta_t = (int(exit_row[6]) - counter_value)/1000000.0
        if depth < MAX_PRINT_DEPTH:
          output_lines.append("  " * depth + f"{event_name} {delta_t}")
      else:
        delta_t = (int(last_row[6]) - counter_value)/1000000.0
        if depth < MAX_PRINT_DEPTH:
          output_lines.append("  " * depth + f"{event_name} >={delta_t}")
      output_lines.extend(returned_output_lines)
  return (output_lines, None)

output_lines, exit_row = format_rows_recursively(csv_reader, 0)
assert(exit_row is None)
for output_line in output_lines:
  print(output_line)
