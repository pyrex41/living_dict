------------------------------ MODULE Episode ------------------------------
(* Transcription of harness/src/livingdict/kernel.py reduce + reconcile.
   TLC-ready subset: no I/O, no clocks. Unikraft does not appear; organs
   only emit these events onto the sequencer. *)

EXTENDS Naturals, Sequences, TLC

CONSTANTS Cap

VARIABLES revision, pending, critic, used, gatesPassed, consecutiveDup

vars == <<revision, pending, critic, used, gatesPassed, consecutiveDup>>

TypeOK ==
  /\ revision \in Nat
  /\ pending \in BOOLEAN
  /\ critic \in {"", "accepted", "rejected"}
  /\ used \in Nat
  /\ gatesPassed \in BOOLEAN
  /\ consecutiveDup \in Nat

Init ==
  /\ revision = 0
  /\ pending = FALSE
  /\ critic = ""
  /\ used = 0
  /\ gatesPassed = FALSE
  /\ consecutiveDup = 0

Plan ==
  /\ ~gatesPassed
  /\ used < Cap
  /\ consecutiveDup < 2
  /\ pending' = TRUE
  /\ consecutiveDup' = 0
  /\ revision' = revision + 1
  /\ UNCHANGED <<critic, used, gatesPassed>>

Reject ==
  /\ pending
  /\ critic' = "rejected"
  /\ pending' = FALSE
  /\ used' = used + 1
  /\ revision' = revision + 1
  /\ UNCHANGED <<gatesPassed, consecutiveDup>>

AcceptAndApply ==
  /\ pending
  /\ critic' = "accepted"
  /\ pending' = FALSE
  /\ used' = used + 1
  /\ revision' = revision + 1
  /\ gatesPassed' \in BOOLEAN
  /\ UNCHANGED consecutiveDup

Next == Plan \/ Reject \/ AcceptAndApply

Spec == Init /\ [][Next]_vars

Success == gatesPassed
Blocked == consecutiveDup >= 2
HaltCap == used >= Cap

(* Safety: artifacts/gates cannot fire unless the critic accepted this episode.
   Encode as: gatesPassed implies critic = "accepted". *)
AcceptBeforeMeasure == [](gatesPassed => critic = "accepted")

(* Safety: reject clears pending, so a rejected plan cannot apply. *)
RejectNotPending == [](critic = "rejected" => ~pending)

=============================================================================
