/*
 * hpdcache_pinning.svh
 *
 * Shared helper for the HPDcache pinning feature.
 */
`ifndef __HPDCACHE_PINNING_SVH__
`define __HPDCACHE_PINNING_SVH__

/*
 * Evaluates to 1 if a cacheline is pinned, 0 otherwise. A cacheline is
 * pinned if its line address (byte address without the cacheline offset
 * bits) belongs to the region [__start__, __stop__)
 *
 * Being a macro, it is width-agnostic: each argument is used with its own
 * type from the call site.
 *
 * @param __line_addr__ line address of the cacheline to test
 * @param __start__     line address of the first pinned cacheline (inclusive)
 * @param __stop__      line address after the last pinned cacheline (exclusive)
 */
`define HPDCACHE_LINE_ADDR_IS_PINNED(__line_addr__, __start__, __stop__) \
    (((__line_addr__) >= (__start__)) && ((__line_addr__) < (__stop__)))

`endif

/// vim: sw=4 ts=4 et
