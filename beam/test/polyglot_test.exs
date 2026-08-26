defmodule LdHost.Bench.PolyglotTest do
  use ExUnit.Case

  alias LdHost.Bench.Polyglot
  alias LdHost.Policy

  # Loader tests run against the real sibling clone of
  # Aider-AI/polyglot-benchmark and skip cleanly when it is missing.
  defp with_bench(fun) do
    root = Polyglot.default_root()

    if File.dir?(root) do
      fun.(root)
    else
      IO.puts(
        "\nSKIP #{inspect(__MODULE__)}: polyglot-benchmark clone missing at #{root} " <>
          "(git clone https://github.com/Aider-AI/polyglot-benchmark there, " <>
          "or set POLYGLOT_BENCH_ROOT)"
      )

      :ok
    end
  end

  # The workspace dir is named after the exercise slug: the cpp
  # CMakeLists derives its target and source names from the dir name.
  defp tmp_ws(task) do
    base = System.tmp_dir!() |> Path.join("ldpoly-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    Path.join(base, Path.basename(task.id))
  end

  test "tasks/2: alphabetical sequence, goal text, hidden contract per language" do
    with_bench(fn root ->
      for lang <- ["rust", "go", "cpp"] do
        tasks = Polyglot.tasks(lang, root)
        assert tasks != [], "#{lang} track must have exercises"

        slugs = Enum.map(tasks, &Path.basename(&1.id))
        assert slugs == Enum.sort(slugs), "#{lang} tasks must be alphabetical"
        assert Enum.map(tasks, & &1.sequence) == Enum.to_list(1..length(tasks))

        for task <- tasks do
          assert task.family == lang
          assert String.starts_with?(task.id, lang <> "/")
          assert String.trim(task.goal) != ""

          assert [%{"kind" => "check", "command" => command, "timeout_seconds" => t}] =
                   task.contract["claims"]

          assert is_integer(t) and t >= 180
          assert command =~ ~r/cargo test|go test|cmake/
        end
      end

      # Goal carries instructions.md plus instructions.append.md.
      rust = Polyglot.tasks("rust", root)
      accumulate = Enum.find(rust, &(&1.id == "rust/accumulate"))
      assert accumulate.goal =~ "Implement the `accumulate` operation"
      assert accumulate.goal =~ "Instructions append"

      # Offline guards on every track's test command.
      [go_cmd] = Enum.uniq(for t <- Polyglot.tasks("go", root), do: hd(t.contract["claims"])["command"])
      assert go_cmd =~ "GOPROXY=off"
      [rust_cmd] = Enum.uniq(for t <- rust, do: hd(t.contract["claims"])["command"])
      assert rust_cmd =~ "CARGO_NET_OFFLINE=true"
    end)
  end

  test "seeding excludes .meta/.docs (reference solutions never reach a workspace)" do
    with_bench(fn root ->
      for lang <- ["rust", "go", "cpp"] do
        task = Polyglot.tasks(lang, root) |> hd()
        ws = tmp_ws(task)
        Polyglot.seed_workspace(task, ws)

        entries = File.ls!(ws)
        refute Enum.any?(entries, &String.starts_with?(&1, ".")), "#{lang}: no dot-entries seeded, got #{inspect(entries)}"
        refute File.exists?(Path.join(ws, ".meta"))
        refute File.exists?(Path.join(ws, ".docs"))
        assert File.read!(Path.join(ws, "TASK.md")) == task.goal

        # No reference-solution file content anywhere in the seed.
        seeded = Policy.snapshot(ws) |> Map.keys()
        refute Enum.any?(seeded, &String.contains?(&1, ".meta"))
      end
    end)
  end

  test "globs: solution stubs writable, test files and bookkeeping frozen" do
    with_bench(fn root ->
      checks = %{
        # {lang, exercise, writable paths, frozen paths}
        "rust" =>
          {"rust/accumulate", ["src/lib.rs", "Cargo.toml"],
           ["tests/accumulate.rs"]},
        "go" =>
          {"go/alphametics", ["alphametics.go"],
           ["alphametics_test.go", "cases_test.go"]},
        "cpp" =>
          {"cpp/all-your-base", ["all_your_base.cpp", "all_your_base.h"],
           ["all_your_base_test.cpp", "test/catch.hpp", "test/tests-main.cpp", "CMakeLists.txt"]}
      }

      for {lang, {id, writable, frozen}} <- checks do
        task = Polyglot.tasks(lang, root) |> Enum.find(&(&1.id == id))
        assert task, "#{id} must exist in the clone"

        ws = tmp_ws(task)
        Polyglot.seed_workspace(task, ws)
        policy = Policy.new(ws, task.allowed_globs, task.forbidden_globs)

        for rel <- writable do
          assert File.exists?(Path.join(ws, rel)), "#{id}: stub #{rel} must be seeded"
          assert Policy.write_allowed(policy, rel) == nil, "#{id}: #{rel} must be writable"
        end

        for rel <- frozen do
          assert File.exists?(Path.join(ws, rel)), "#{id}: #{rel} must be seeded"
          assert Policy.write_allowed(policy, rel) != nil, "#{id}: #{rel} must be frozen"
        end
      end
    end)
  end

  @tag :e2e
  @tag timeout: 600_000
  test "reference solutions discharge the hidden contract (rust, go, cpp)" do
    with_bench(fn root ->
      for lang <- ["rust", "go", "cpp"] do
        task = Polyglot.tasks(lang, root) |> hd()
        ws = tmp_ws(task)
        Polyglot.seed_workspace(task, ws)
        overlay_reference_solution(task, ws)

        [claim] = task.contract["claims"]
        result = LdHost.Cmd.sh(claim["command"], ws, claim["timeout_seconds"] * 1000)

        assert result.returncode == 0,
               "#{task.id}: reference solution must pass its own hidden contract " <>
                 "(rc=#{inspect(result.returncode)} timed_out=#{result.timed_out})\n#{result.output}"
      end
    end)
  end

  # Overlay .meta reference files onto the seeded stubs using the
  # exercise's own config.json manifest: each files.example entry lands
  # on the first files.solution entry with the same extension.
  defp overlay_reference_solution(task, ws) do
    config = File.read!(Path.join([task.dir, ".meta", "config.json"])) |> JSON.decode!()
    solutions = get_in(config, ["files", "solution"]) || []
    examples = get_in(config, ["files", "example"]) || []

    {placements, leftover} =
      Enum.map_reduce(examples, solutions, fn example, remaining ->
        target = Enum.find(remaining, &(Path.extname(&1) == Path.extname(example)))

        unless target do
          raise "no solution slot for reference file #{example} in #{task.id}"
        end

        {{example, target}, List.delete(remaining, target)}
      end)

    _ = leftover

    Enum.each(placements, fn {example, target} ->
      dest = Path.join(ws, target)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(Path.join(task.dir, example), dest)
    end)
  end
end
