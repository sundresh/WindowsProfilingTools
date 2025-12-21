# XML Schema Description: macOS Instruments Time Profile Trace

This XML file is a **time-profile sampling trace** exported from Apple's Instruments command-line tool (`xctrace`). It captures periodic CPU samples of all running processes on the system at approximately 1ms intervals.

## Root Structure

```
<trace-query-result>
  <node xpath="//trace-toc[1]/run[1]/data[1]/table[13]">
    <schema>...</schema>
    <row>...</row>
    <row>...</row>
    ...
  </node>
</trace-query-result>
```

- **`<trace-query-result>`**: Document root element
- **`<node xpath="...">`**: Container referencing the source table location in the original `.trace` bundle. The xpath indicates this is table 13 from run 1.

## Schema Definition

The `<schema name="time-profile">` element defines seven columns:

| Mnemonic | Name | Engineering Type |
|----------|------|------------------|
| time | Sample Time | sample-time |
| thread | Thread | thread |
| process | Process | process |
| core | Core | core |
| thread-state | State | thread-state |
| weight | Weight | weight |
| stack | Backtrace | backtrace |

## Data Rows (`<row>`)

Each `<row>` represents a single CPU sample with these elements:

### 1. `<sample-time>`

```xml
<sample-time id="36" fmt="00:00.300.613">300613208</sample-time>
```

- `id`: Unique identifier for deduplication
- `fmt`: Human-readable timestamp (MM:SS.ms.µs format)
- Content: Absolute time in nanoseconds from trace start

### 2. `<thread>`

```xml
<thread id="37" fmt="Main Thread 0x12aa (WindowServer, pid: 581)">
  <tid id="38" fmt="0x12aa">4778</tid>
  <process id="39" fmt="WindowServer (581)">
    <pid id="40" fmt="581">581</pid>
    <device-session id="6" fmt="TODO">TODO</device-session>
  </process>
</thread>
```

- `fmt`: Descriptive name with thread ID and process context
- `<tid>`: Thread ID in hex/decimal
- `<process>`: Containing process with `<pid>` and `<device-session>`

### 3. `<process>`

References or repeats the process from the thread element.

### 4. `<core>`

```xml
<core id="41" fmt="CPU 0 (E Core)">0</core>
```

CPU core number with type indicator:
- **E Core**: Efficiency cores (0-3 on this Apple Silicon M4 Pro)
- **P Core**: Performance cores (4-15)

### 5. `<thread-state>`

```xml
<thread-state id="8" fmt="Running">Running</thread-state>
```

Only samples of running threads are captured.

### 6. `<weight>`

```xml
<weight id="9" fmt="1.00 ms">1000000</weight>
```

Sample weight in nanoseconds (1,000,000 ns = 1 ms sampling interval).

### 7. `<backtrace>` or `<sentinel/>`

Either a full stack trace or an empty `<sentinel/>` marker (when backtrace is unavailable):

```xml
<backtrace id="42">
  <frame id="43" name="mach_msg2_trap" addr="0x1a0241c35">
    <binary id="44" name="libsystem_kernel.dylib"
            UUID="E5D90565-FA1A-3112-B048-59E321191677"
            arch="arm64e"
            load-addr="0x1a0241000"
            path="/usr/lib/system/libsystem_kernel.dylib"/>
  </frame>
  <frame id="45" name="mach_msg2_internal" addr="0x1a02543a0">
    <binary ref="44"/>   <!-- Reference to previously defined binary -->
  </frame>
  <!-- ... more frames, bottom of stack last -->
</backtrace>
```

**Frame attributes:**
- `id`: Unique identifier
- `name`: Symbol name or hex address (e.g., `0x19ffe6b30` for unsymbolicated frames)
- `addr`: Instruction address

**Binary attributes:**
- `name`: Library/executable name
- `UUID`: Build UUID for matching debug symbols
- `arch`: Architecture (`arm64e`, `arm64`, `x86_64`)
- `load-addr`: Load address in memory
- `path`: Filesystem path

**Source information** (optional, for symbolicated frames):

```xml
<source line="39">
  <path id="535">/path/to/source.swift</path>
</source>
```

## Deduplication Mechanism

The schema uses `id`/`ref` attribute pairs for space efficiency:
- First occurrence: `id="N"` defines the element
- Subsequent occurrences: `ref="N"` references it

This applies to all element types (threads, processes, cores, backtraces, frames, binaries, paths).

## Summary Statistics

From this trace file:
- **Duration**: ~65 seconds (00:00.300 to 01:05.760)
- **Rows**: ~179,000 samples
- **Unique IDs**: 530,000+ (indicates heavy deduplication)
- **Architectures**: arm64e (Apple Silicon native), arm64 (standard), x86_64 (Rosetta 2)
- **CPU Cores**: 16 (4 E-cores + 12 P-cores, consistent with M4 Pro)
