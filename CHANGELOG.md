# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Cacheline pinning: a memory region, defined by two new control registers
  (`pinned_line_addr_start`, the line address of the first pinned cacheline,
  and `pinned_line_addr_size`, the length of the region in cachelines; CFIG
  segment, offsets 0x00 and 0x08), can be pinned in the cache. The cachelines of
  that region are never selected as victims by the replacement algorithm (PLRU
  or pseudo-random), so they cannot be evicted by other cachelines, and they are
  always allocated with the write-back policy, whatever the write-policy hint
  of the request is.
- New `pinned` metadata bit in the cache directory (one bit per way, stored in
  the Tag RAM) recording whether a cacheline belongs to the pinned region. It
  is maintained by the pipeline, the refill path, the CMO handler and the
  pinned region writeback controller, and it is taken into account by the
  victim selection logic.
- Handling of the case where all the ways of a set are already pinned: a pinned
  request that needs to allocate a cacheline in such a set is kept in the RTAB
  and replayed as soon as the directory shows at least one unpinned way in that
  set. Requests that do not belong to the pinned region are executed as
  uncacheable requests in that case.
- New control/status registers block (`hpdcache_csr`) which services the
  accesses issued by the requesters to the CFIG address segment. It implements
  the pinned region registers and read-only status registers to check the tag of
  a cacheline (segment 0x1) and its pinned status (segment 0x2), given the set
  and the way.
- Pinned region writeback: when the pinned region control registers
  (`pinned_line_addr_start` or `pinned_line_addr_size`) are modified, the cache
  walks the whole directory and writes back to memory, then invalidates, every
  dirty cacheline of the new region which is not marked pinned yet, i.e. the
  cachelines which should have been pinned when they were dirtied. The activated
  region therefore holds no cacheline dirtied before its activation; the pinned
  bit of the other cachelines is aligned with the new region and the cachelines
  already pinned are left untouched. The walk is the lowest priority user of the
  cache directory, so the cache keeps executing requests while it is on-going. A
  new read-only status register (CFIG segment, offset 0x10) is set when the walk
  and all its writebacks are complete, and cleared when the region is modified.
- A pinned store hitting a cacheline which is dirty and not marked pinned yet
  writes that value back to the memory before overwriting it, and pins the
  cacheline: the store waits in the RTAB while the flush controller reads the
  cacheline, and is replayed once the memory has acknowledged the writeback. It
  therefore cannot destroy a value the memory has not received, and what it
  leaves in the cache is the new value in a dirty and pinned cacheline.

### Removed

### Changed

- The cache directory entries store one additional metadata bit per cacheline
  (pinned), which increases the width of the Tag RAM entries.

### Fixed

- A cacheline invalidated in the cache directory could keep its `pinned` bit
  set: the refill path did not clear it when the refill response reported an
  error, and the invalidations of the control module (CMO and NoC) left it to
  the value written by the previous cycle. A way which is invalid and pinned is
  selected by no victim policy, and its set is not reported as fully pinned
  either, so such a way could never be allocated again. The `pinned` bit is now
  written 0 whenever `valid` is written 0, and the memory controller asserts
  that no directory entry is ever invalid and pinned.

## [6.0.0] 2026-03-13

### Added

- Error correction and detection mechanisms for bit-flips in dir and data SRAMs
- New parameters: eccEn, eccScrubberEn
- Vendorized lowRISC OpenTitan subdirectory with ECC primitives and generators

## [5.2.0] 2026-03-13

### Added

- Testbench: add sequence that reads trace file from QEMU execution
- Testbench: add direct mapped configuration and validate it in the CI
- Add plugin for QEMU to generate memory access traces
- Add cache invalidation signal in the memory response interface

### Changed

- Enable concurrent read and write if they target different banks
- Optimize write byte enable logic for timing towards data SRAMs
- Improve wake-up logic in the RTAB for requests waiting for a refill

### Fixed

- Prevent invalidations to go into the uncached handler (on OpenPiton platform)
- Correctly support direct mapped configuration of the cache

## [5.1.0] 2025-07-02

### Added

- New lowLatency parameter: When enabled, load requests have a latency of 1
  cycle. When disabled, load requests have a latency 2 cycles. This may improve
  the throughput on some access patterns because it reduces port conflicts
  between loads and stores.
- New coalescing buffer for write misses. On write misses, the write data is
  stored in a dedicated buffer, and coalesced when the refill response arrives
  before writing it into the cache.
- Heuristic mechanism to reduce the latency of flush operations. The cache
  stores both the min and max index of dirty cachelines and perform the flush
  only on within that boundary.

### Removed

### Changed

- Use RTAB to drain pipeline upon UC/AMO requests. On a UC/AMO request, the
  cache puts the request into the RTAB, and waits for all transactions into the
  pipeline to be completed before replaying the UC/AMO request.

### Fixed

- Missing reset of some registers in the uncached requests handler.

## [5.0.1] 2025-01-30

This releases include some bugfixes and optimizations.

### Added

- Support responses for CMO operations when ``need_rsp`` in the request is set
- Support not-power-of-two number of entries in the Flush controller

### Removed

### Changed

### Fixed

- Fix implementation of the data merge logic in the write buffer to improve the area
- Fix assertions syntax
- Fix CMO flushes shall unset the dirty bit in the cache directory
- Fix handling of bus errors on write misses
- Fix prefetch requests shall update PLRU bits
- Fix initialization of the CMO handler flush request valid register

## [5.0.0] 2024-10-10

The major modification in this release is the support of the write-back (WB) policy (in
addition to the write-through (WT) policy). The cache can either implement one of these
policies or both in a per-cacheline basis.

### Added

- Support of the WB policy.
- Configuration parameters to choose between WT or WB, or both, at synthesis time.
- Validation testbench compatible to Verilator.
- Add a write-policy hint field in the request to select between WT and WB, dynamically.

### Removed

- WbufSendFeedThrough parameter removed

### Changed

- Arbitration between cacheable and uncacheable memory requests is done inside the
  HPDcache. The memory interface implements 5 channels, instead of 10.
- The CMO type is into the operation field of the request (instead of the size field).
- Select the victim cacheline at cache miss time (before was done on refill time). The
  slot is pre-allocated and written by the miss handler when the refill response arrives.

### Fixed

## [4.0.0] 2024-08-20

The major modification in this release is the new scheme to set parameters of the HPDcache

### Added

- Add utility macros to define the types in the interface of the HPDcache.
- Add scripts for code static check (lint)
- Add new User Guide document in reStructuredText format

### Removed

### Changed

- Pass configuration parameters through the top module of the HPDcache instead of
  defining them in a package. This allows different instances of the HPDcache to have
  different parameters.
- Add round-robin priority arbiter in the write-buffer to select an entry to send.
- Add fix-priority arbiter in the write-buffer to select a free entry.
- Make AXI transactions modifiable by default

### Fixed

- Fix some synthesis warnings

## [3.1.0] 2024-04-20

### Added

- Add support for pseudo-random (using a LFSR) algorithm for the victim selection
- Add support for the OpenPiton Cache-Coherent Network-on-Chip
- Add support for full-associative, direct-mapped or single-entry MSHR

### Removed

### Changed

- Cache directory valid bits are relocated in the Tag RAM
- Modify the arbitration between the different sources of requests (refill is now prioritary)
- Add feedthrough (optional) fifo in both wbuf and refill handler
- Disable assertions during reset
- Modify write buffer microarchitecture to improve both area and performance

### Fixed

- Fix support for AMOs when using a 32-bit request interface

## [3.0.0] 2023-10-08

### Added

- Add support for virtually-indexed addressing

### Fixed

- Fix forwarding logic of uncacheable Icache response in the cva6 cache subsystem.
- Fix wrong mask signal when implementing the MSHR in registers

## [2.1.0] - 2023-09-25

### Added

- Add additional configuration to implement MSHR in registers (when the number
  of entries is low)

### Fixed

- Fix cache data SRAM chip-select generation when word width is different than
  64 bits (e.g. 32 bits)

## [2.0.0] - 2023-09-18

### Added

- Add parameters in the HPDcache module to define the types of interfaces to
  the memory
- Add helper verilog header file with macros to ease the type definition of
  interfaces to the memory
- Add new event signals in the HPDCache top module
- Add generic single-port RAM macros with byte-enable signals
- Add parameters in the package to choose between RAM macros implementing
  byte-enable or bitmask for the different RAMs instances
- Add additional assertions to verify parameters
- Add additional configuration signal to inhibit write coalescing in the write
  buffer

### Removed

- Remove base_id ports in the HPDCache top module
- Remove nettype (wire,var) in ports as it looks like is badly supported in
  some cases by some simulation tools

### Changed

- Split the hpdcache_pkg into: (1) the hpdcache_pkg contains internally defined
  parameters; (2) a new hpdcache_params_pkg that defines user parameters
- New selection policy of ready requests in the replay table. It gives priority
  to requests in the same linked list.
- The write buffer now accepts writes from requesters in a pending slot when it
  is waiting for the internal arbiter to forward the data to the NoC.

### Fixed

- Correctly support HPDCACHE_ACCESS_WORDS=1
- Correctly support HPDCACHE_ACCESS_WORDS=HPDCACHE_CL_WORDS
- Fix width of the nlines count register in the HW memory prefetcher.

## [1.0.0] - 2023-02-22

### Added
- Initial release to the OpenHW Group
