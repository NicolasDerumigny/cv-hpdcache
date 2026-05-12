let $HPDCACHE_DIR = expand('<sfile>:p:h')
let g:ale_fixers =
            \{
            \    'c': ['clang-format', 'remove_trailing_lines', 'trim_whitespace'],
            \    'cpp': ['clang-format', 'remove_trailing_lines', 'trim_whitespace'],
            \    'systemverilog': ['remove_trailing_lines', 'trim_whitespace'],
            \}


let g:ale_verilog_verilator_options = "--cc -Wall -Wno-pinconnectempty -Wno-fatal  --Wno-MODDUP -error-limit 100 --top hpdcache_lint -f " . $HPDCACHE_DIR . "/rtl/hpdcache.Flist " . $HPDCACHE_DIR . "/rtl/src/common/macros/behav/*.sv " . $HPDCACHE_DIR . "/rtl/lint/hpdcache_lint.sv"

