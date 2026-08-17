\ A minimal capability program for the forth and forth-shen arms.
\ Stack effects are documentary here; the production harness supplies words.

TASK           \ ( -- task )
OBSERVE        \ ( task -- observation )
PROPOSE-PATCH  \ ( observation -- patch )
CHECK-PATCH    \ ( patch -- checked-patch )
APPLY-PATCH    \ ( checked-patch -- mutation-receipt )
RUN-TESTS      \ ( mutation-receipt -- test-receipt )
REQUIRE-PASS   \ ( test-receipt -- verified-receipt )
RECEIPT        \ ( verified-receipt -- receipt )
