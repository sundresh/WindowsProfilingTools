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

#csv_reader = csv.reader(open("../13/stats/trace-1768346843829391-swift-frontend-Example-Example.swift-arm64_apple_macosx15.0-o-Onone-2390402430.csv"))
csv_reader = csv.reader(open("stats/trace-1768419180674345-swift-frontend-hello-hello.swift-arm64_apple_macosx15.0-o-Onone-195120723.csv"))
column_headers = next(csv_reader)

event_to_counter_names = collections.defaultdict(lambda: set())
event_name_stack = []
last_pushed_event_key = None
last_popped_event_key = None
max_stack_depth = 0
longest_stack = []
for row in csv_reader:
  event_key = tuple(row[0:4])
  is_entry = row[2]
  event_name = row[3]
  counter_name = row[4]
  if counter_name in event_to_counter_names[event_key]:
    print(f"Duplicate: {row}")
  event_to_counter_names[event_key].add(counter_name)
  if is_entry == "entry":
    if event_key != last_pushed_event_key:
      print(("  " * len(event_name_stack)) + repr(event_key))
      event_name_stack.append(event_name)
      last_pushed_event_key = event_key
  else:
    if event_key != last_popped_event_key:
      assert(is_entry == "exit")
      assert(len(event_name_stack) > 0)
      assert(event_name_stack[-1] == event_name)
      event_name_stack.pop()
      last_popped_event_key = event_key
      print(("  " * len(event_name_stack)) + repr(event_key))
  if len(event_name_stack) > max_stack_depth:
    max_stack_depth = len(event_name_stack)
    longest_stack = event_name_stack[:]

print("-------------------------------------------------------------")
print(event_name_stack)
print(max_stack_depth)
print(longest_stack)
