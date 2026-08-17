\\ Living Dictionary capability contracts.
\\ Portable spec for shen-lua / ShenScript.
\\ The eval harness critic is livingdict.preflight (Python).
\\ The live kernel critic is openresty/shen/contracts.shen + preflight.shen
\\ (named validate, loaded by openresty/lua/bridge.lua).
\\
\\ Stack effects are documentary. The Forth body remains the only executor.

(package living-dictionary
  [read-file list-dir search write-file run-tests receipt use-artifact]

\\ read  ( path -- content )
\\ list-dir ( path -- listing )
\\ search ( query -- hits )
\\ write-file ( content path -- receipt )
\\ run-tests ( -- test-receipt )
\\ receipt ( -- receipt )
\\ use-artifact ( path -- content )

(define allowed-effect?
  read -> true
  write -> true
  exec -> true
  X -> false)

(define write-ok?
  {string --> (list string) --> (list string) --> boolean}
  Path Allowed Forbidden ->
    (and (element? Path Allowed)
         (not (element? Path Forbidden))))
)
