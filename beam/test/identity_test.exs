defmodule LdHost.IdentityTest do
  use ExUnit.Case, async: false

  alias LdHost.{Dictionary, Forth, Ledger, Run, Store}

  @pc String.duplicate("a", 64)
  @src String.duplicate("b", 64)
  @golden_hex "3ef5f55c145eee6e66b846d12dd1caa837c2f57bd561f9951d6697bc5d737c6f"

  defp tmp(prefix) do
    path =
      System.tmp_dir!()
      |> Path.join("#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    path
  end

  defp dict_dir do
    dir = tmp("ldid")
    File.mkdir_p!(Path.join(dir, "words"))
    dir
  end

  test "canonical identity JSON matches Python sort_keys/separators golden hash" do
    words = %{
      "ZZZ" => %{
        "source" => @src,
        "contract" => "( n -- n n )",
        "effects" => ["write", "read"],
        "callees" => ["WRITE-FILE", "DUP"],
        "path_region" => ["app/**", "**"],
        "primitive_contract" => @pc,
        "episode" => 9,
        "gates" => %{"ok" => true},
        "cost" => 12,
        "latency_ms" => 4,
        "tokens" => 99,
        "replay_ok" => true,
        "counterexamples" => ["config-08"],
        "task_families" => ["config"]
      },
      "AAA" => %{
        "source" => @src,
        "contract" => "( -- )",
        "effects" => [],
        "callees" => ["ZZZ"],
        "path_region" => ["**"],
        "primitive_contract" => @pc
      }
    }

    obj = Dictionary.identity(nil, @pc, words)
    bytes = Store.canonical_json(obj)
    {_b, hex, display} = Dictionary.hash_identity(nil, @pc, words)

    refute Map.has_key?(obj, "episode")
    refute Map.has_key?(obj["words"]["ZZZ"], "episode")
    refute Map.has_key?(obj["words"]["ZZZ"], "gates")
    refute Map.has_key?(obj["words"]["ZZZ"], "cost")
    refute Map.has_key?(obj["words"]["ZZZ"], "latency_ms")
    refute Map.has_key?(obj["words"]["ZZZ"], "tokens")
    refute Map.has_key?(obj["words"]["ZZZ"], "replay_ok")
    refute Map.has_key?(obj["words"]["ZZZ"], "counterexamples")
    refute Map.has_key?(obj["words"]["ZZZ"], "task_families")

    assert obj["words"]["ZZZ"]["effects"] == ["read", "write"]
    assert obj["words"]["ZZZ"]["callees"] == ["DUP", "WRITE-FILE"]
    assert obj["words"]["ZZZ"]["path_region"] == ["**", "app/**"]
    assert obj["parent"] == nil
    refute String.contains?(bytes, "sha256:")
    assert hex == @golden_hex
    assert display == "sha256:" <> @golden_hex
    assert LdHost.Policy.sha256_hex(bytes) == @golden_hex
  end

  test "two intern passes of the same admitted source mint the same D*" do
    store = Store.new(tmp("ldobj"))

    words = %{
      "GREET" => %{
        "source" => Store.intern(store, ~s{: GREET ( -- | write ) S" hi" S" greet.txt" WRITE-FILE DROP ;\n}),
        "contract" => "( -- | write )",
        "effects" => ["write"],
        "callees" => ["DROP", "WRITE-FILE"],
        "path_region" => ["greet.txt"],
        "primitive_contract" => Forth.primitive_contract()
      }
    }

    {hex1, display1, _} = Dictionary.intern_identity(store, nil, Forth.primitive_contract(), words)
    Process.sleep(15)
    {hex2, display2, _} = Dictionary.intern_identity(store, nil, Forth.primitive_contract(), words)

    assert hex1 == hex2
    assert display1 == display2
    assert String.length(hex1) == 64
    refute String.starts_with?(hex1, "sha256:")
    assert display1 == "sha256:" <> hex1
    assert Store.has?(store, hex1)
    {:ok, blob} = Store.get(store, hex1)
    assert Store.canonical_json(Dictionary.identity(nil, Forth.primitive_contract(), words)) == blob
  end

  test "intern_from_dir hashes persist identity; sidecar evidence stays off the blob" do
    store = Store.new(tmp("ldobj2"))
    dir = dict_dir()

    Dictionary.save_words(
      dir,
      [{"GREET", ~s{S" hi" S" greet.txt" WRITE-FILE DROP}, "( -- | write )"}],
      allowed_globs: ["app/**"]
    )

    {hex, display, _} = Dictionary.intern_from_dir(store, dir)
    {hex2, _, _} = Dictionary.intern_from_dir(store, dir)
    assert hex == hex2
    assert display == "sha256:" <> hex

    entries = Dictionary.words_identity(store, dir)
    assert entries["GREET"]["effects"] == ["write"]
    assert entries["GREET"]["path_region"] == ["greet.txt"]
    assert entries["GREET"]["callees"] == ["DROP", "WRITE-FILE"]
    assert Dictionary.callees(~s{S" hi" S" greet.txt" WRITE-FILE DROP}, "GREET") == ["DROP", "WRITE-FILE"]
    {:ok, blob} = Store.get(store, hex)
    refute blob =~ "task_families"
    refute blob =~ "episode"
  end

  test "ledger accepts five overlay kinds and refuses unknown" do
    dir = tmp("ldledger")
    {:ok, ledger} = Ledger.start_link(dir)

    for kind <-
          ~w(dictionary.overlay.proposed dictionary.overlay.admitted dictionary.overlay.rejected dictionary.narrowed dictionary.discarded) do
      assert {:ok, _seq} = Ledger.commit(ledger, kind, %{})
    end

    assert {:error, "unknown event kind: dictionary.overlay.surprise"} =
             Ledger.commit(ledger, "dictionary.overlay.surprise", %{})

    kinds = Ledger.event_kinds()
    assert "dictionary.overlay.proposed" in kinds
    assert "dictionary.overlay.admitted" in kinds
    assert "dictionary.overlay.rejected" in kinds
    assert "dictionary.narrowed" in kinds
    assert "dictionary.discarded" in kinds
    assert "dictionary.promoted" in kinds
  end

  test "freeze_of is last overlay.admitted; rejected/proposed/discarded do not move it" do
    pc = Forth.primitive_contract()
    d1 = String.duplicate("c", 64)
    d2 = String.duplicate("d", 64)
    o1 = String.duplicate("e", 64)
    o2 = String.duplicate("f", 64)

    events = [
      %{"kind" => "dictionary.overlay.proposed", "payload" => %{"overlay_hash" => o1}},
      %{
        "kind" => "dictionary.overlay.admitted",
        "payload" => %{
          "dictionary_hash" => "sha256:" <> d1,
          "overlay_hash" => o1,
          "primitive_contract" => pc
        }
      },
      %{
        "kind" => "dictionary.overlay.rejected",
        "payload" => %{"overlay_hash" => o2, "errors" => ["stack underflow"]}
      },
      %{"kind" => "dictionary.discarded", "payload" => %{"overlay_hash" => o1}},
      %{"kind" => "dictionary.promoted", "payload" => %{"word" => "GREET"}},
      %{"kind" => "dictionary.narrowed", "payload" => %{"word" => "GREET"}}
    ]

    freeze = Run.freeze_of(events)
    assert freeze.dictionary_hash == d1
    assert freeze.overlay_hash == o1
    assert freeze.primitive_contract == pc

    later = events ++ [
      %{
        "kind" => "dictionary.overlay.admitted",
        "payload" => %{
          "dictionary_hash" => d2,
          "overlay_hash" => o2,
          "primitive_contract" => pc
        }
      }
    ]

    freeze2 = Run.freeze_of(later)
    assert freeze2.dictionary_hash == d2
    assert freeze2.overlay_hash == o2
    assert Run.freeze_of([]) == :empty
  end

  test "overlay.admitted replay restores freeze via host fold from events.jsonl" do
    dir = tmp("ldfreeze")
    {:ok, ledger} = Ledger.start_link(dir)
    pc = Forth.primitive_contract()
    dh = String.duplicate("1", 64)
    oh = String.duplicate("2", 64)

    {:ok, _} =
      Ledger.commit(ledger, "dictionary.overlay.admitted", %{
        dictionary_hash: dh,
        overlay_hash: oh,
        primitive_contract: pc
      })

    {:ok, _} =
      Ledger.commit(ledger, "dictionary.overlay.rejected", %{
        overlay_hash: String.duplicate("3", 64),
        errors: ["nope"]
      })

    freeze = Run.freeze_from_dir(dir)
    assert freeze == %{dictionary_hash: dh, overlay_hash: oh, primitive_contract: pc}
  end

  test "facts project overlay kinds; rejected errors are not duplicated" do
    pc = Forth.primitive_contract()
    parent = String.duplicate("a", 64)
    oh = String.duplicate("b", 64)
    dh = String.duplicate("c", 64)

    events = [
      %{"kind" => "episode.planned", "payload" => %{"episode" => 1}, "sequence" => 1},
      %{
        "kind" => "critic.rejected",
        "payload" => %{"episode" => 1, "errors" => ["stack underflow at X"]},
        "sequence" => 2
      },
      %{
        "kind" => "dictionary.overlay.rejected",
        "payload" => %{"episode" => 1, "overlay_hash" => oh, "errors" => ["stack underflow at X"]},
        "sequence" => 3
      },
      %{
        "kind" => "dictionary.overlay.proposed",
        "payload" => %{"overlay_hash" => oh, "parent" => parent, "primitive_contract" => pc},
        "sequence" => 4
      },
      %{
        "kind" => "dictionary.overlay.admitted",
        "payload" => %{
          "overlay_hash" => oh,
          "dictionary_hash" => dh,
          "parent" => parent,
          "effects" => ["write", "read"],
          "primitive_contract" => pc
        },
        "sequence" => 5
      }
    ]

    rows = Store.facts(events)
    errors = for {e, ":critic/error", v, _} <- rows, do: {e, v}
    assert errors == [{"episode/1", "stack underflow at X"}]
    assert {"overlay/#{oh}", ":overlay/verdict", ":reject", 3} in rows
    assert {"overlay/#{oh}", ":overlay/verdict", ":admit", 5} in rows
    assert {"overlay/#{oh}", ":overlay/parent", "dict/#{parent}", 4} in rows
    assert {"dict/#{dh}", ":dict/parent", "dict/#{parent}", 5} in rows
  end
end
