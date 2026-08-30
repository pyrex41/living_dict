# Exp 0 runner: mixed-family warm, then seq-8 load-all vs grant+path retrieved.
# Reads eval/ read-only. Never edits eval/.
#
#   cd beam && mix run bench/exp0.exs --discover
#   cd beam && mix run bench/exp0.exs --out /tmp/ld-exp0 --reps 1
#
# Default LD_DICT_MODE remains load-all. Kill switch is human review of receipt.json.

LdHost.Bench.Exp0.main(System.argv())
