Baseline: d38bc7e; candidate: 7c5549f plus the string-input guard.
Candidate ll.lua blob: 3b61fcf4f0e0d64b7d99704962dd586eb4085dcd.
Three interleaved master/candidate pairs; fresh resty process per case.
Native arm64 macOS, OpenResty 1.31.8.1, LuaJIT 2.1.ROLLING.
Samples are in run order; medians are in parentheses.

| Case | Driver | CPU ns/op | Wall ops/s |
| --- | --- | --- | --- |
| objectid_generate | master | 525.44, 476.43, 468.40 (476.43) | 1901550.00, 2087850.00, 2132450.00 (2087850.00) |
| objectid_generate | candidate | 197.42, 189.55, 188.50 (189.55) | 4995000.00, 5261200.00, 5297900.00 (5261200.00) |
| objectid_access | master | 4841.76, 4728.19, 4828.53 (4828.53) | 205400.00, 211200.00, 206800.00 (206800.00) |
| objectid_access | candidate | 4.30, 4.33, 4.41 (4.33) | 232040650.00, 230631900.00, 225353100.00 (230631900.00) |
