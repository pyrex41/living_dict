defmodule LdHost.Exp0Test do
  use ExUnit.Case, async: true

  alias LdHost.{Bench.Exp0, Dictionary, Retrieve}

  test "discover reads eval/ tasks without writing; warm is seq 1-7 mixed families" do
    eval_root = Path.join(LdHost.Critic.repo_root(), "eval")
    found = Exp0.discover(eval_root)

    assert File.dir?(found.eval_root)
    assert "config_migration" in found.families
    assert "parser_repair" in found.families
    assert "graph_coordination" in found.families
    assert "safety_boundary" in found.families
    assert "validation_ladder" in found.families

    assert Enum.all?(found.warm, &(&1.sequence in 1..7))
    assert Enum.all?(found.score, &(&1.sequence == 8))
    assert length(found.warm) == length(found.families) * 7
    assert length(found.score) == length(found.families)
    assert Enum.any?(found.warm, &(&1.id == "config-01"))
    assert Enum.any?(found.score, &(&1.id == "config-08"))
    refute Enum.any?(found.warm, &(&1.sequence == 8))
  end

  test "kill switch: non-inferior seq-8 plus shrink; equal failure is not a kill if shrunk" do
    load_all = %{seq8_success: 0.4, prelude_bytes: 100, prelude_word_count: 10, unused_loaded_words: 8}
    retrieved = %{seq8_success: 0.4, prelude_bytes: 40, prelude_word_count: 3, unused_loaded_words: 1}
    go = Exp0.kill_switch(load_all, retrieved)
    assert go.proceed
    assert go.seq8_non_inferior
    assert go.shrunk

    worse = Exp0.kill_switch(load_all, %{retrieved | seq8_success: 0.2})
    refute worse.proceed
    refute worse.seq8_non_inferior

    both_fail =
      Exp0.kill_switch(
        %{seq8_success: 0.0, prelude_bytes: 100, prelude_word_count: 10, unused_loaded_words: 8},
        %{seq8_success: 0.0, prelude_bytes: 40, prelude_word_count: 3, unused_loaded_words: 1}
      )

    assert both_fail.seq8_non_inferior
    assert both_fail.proceed

    no_shrink = Exp0.kill_switch(load_all, %{seq8_success: 0.4, prelude_bytes: 100, prelude_word_count: 10, unused_loaded_words: 8})
    refute no_shrink.proceed
    assert no_shrink.seq8_non_inferior

    unusable =
      Exp0.kill_switch(
        %{seq8_success: 0.0, prelude_bytes: 100, prelude_word_count: 10, unused_loaded_words: 8},
        %{seq8_success: 0.0, prelude_bytes: 40, prelude_word_count: 3, unused_loaded_words: 1},
        verifier_usable: false
      )

    refute unusable.proceed
    refute unusable.verifier_usable
    assert "verifier slot missing or unusable" in unusable.reasons
  end

  test "seq-8 eval tasks have a usable hidden verifier slot" do
    found = Exp0.discover(Path.join(LdHost.Critic.repo_root(), "eval"))
    assert found.score != []

    for task <- found.score do
      assert File.regular?(Exp0.verifier_path(task)), "#{task.id} missing protected/verify.py"
      assert {:ok, meta} = Exp0.probe_verifier(task)
      assert meta.checks > 0
      assert task.contract
      [claim] = task.contract.claims
      assert claim["id"] == "hidden-verifier"
      assert claim["kind"] == "check"
      assert claim["command"] =~ "verify.py"
    end
  end

  test "config-08 hidden-verifier contract fails on seed repo and passes oracle" do
    task = Exp0.load_task(Path.join([LdHost.Critic.repo_root(), "eval", "tasks", "config-08"]))
    [claim] = task.contract.claims
    cmd = claim["command"]

    seed =
      System.tmp_dir!()
      |> Path.join("ld-exp0-seed-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.cp_r!(Path.join(task.dir, "repo"), seed)
    refute LdHost.Cmd.sh(cmd, seed, 60_000).returncode == 0

    oracle_ws =
      System.tmp_dir!()
      |> Path.join("ld-exp0-oracle-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.cp_r!(Path.join(task.dir, "repo"), oracle_ws)
    File.cp_r!(Path.join([task.dir, "protected", "oracle", "files"]), oracle_ws)
    assert LdHost.Cmd.sh(cmd, oracle_ws, 60_000).returncode == 0
  end

  test "run refuses to proceed when the seq-8 verifier slot is missing" do
    out =
      System.tmp_dir!()
      |> Path.join("ld-exp0-run-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    fake_dir =
      System.tmp_dir!()
      |> Path.join("ld-exp0-fake-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fake_dir)

    task = %{
      id: "fake-08",
      dir: fake_dir,
      family: "fake",
      sequence: 8,
      goal: "nope",
      allowed_effects: ["read", "write", "exec"],
      allowed_globs: ["**"],
      forbidden_globs: [],
      contract: nil
    }

    planner = fn _g, _o, _f -> flunk("planner must not run without a usable verifier") end

    receipt =
      Exp0.run(
        warm_tasks: [],
        score_tasks: [task],
        out: out,
        planner_fn: planner,
        max_episodes: 1,
        reps: 1
      )

    refute receipt.kill_switch.proceed
    assert receipt.verifier.usable == false
    assert "verifier slot missing or unusable" in receipt.kill_switch.reasons
    assert hd(receipt.verifier.errors)["task"] == "fake-08"
  end

  test "prelude_metrics retrieved is smaller on mixed-family dict" do
    dir =
      System.tmp_dir!()
      |> Path.join("ldexp0-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "words"))

    Dictionary.save_words(dir, [
      {"CONFIG", ~s{S" x" S" app/config.py" WRITE-FILE DROP}, "( -- | write )"},
      {"PARSER", ~s{S" x" S" src/records.py" WRITE-FILE DROP}, "( -- | write )"}
    ])

    q = Retrieve.host_query(["read", "write", "exec"], ["app/config.py"], ["tests/**"])
    all = Exp0.prelude_metrics(dir, :load_all, q)
    got = Exp0.prelude_metrics(dir, :retrieved, q)
    assert all.prelude_word_count == 2
    assert got.prelude_word_count == 1
    assert got.prelude_bytes < all.prelude_bytes
    assert got.prelude_words == ["CONFIG"]
  end
end
