# Critic engine benchmark: identical validate workloads across engines.
# Run: cd beam && mix run bench/critic_bench.exs

defmodule CriticBench do
  @simple ~s{S" src/records.py" USE-ARTIFACT S" src/records.py" WRITE-FILE RUN-TESTS RECEIPT}
  @colon ~s{: INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
           ~s{S" app/a.py" S" app/a.py" INSTALL S" app/b.py" S" app/b.py" INSTALL RUN-GATES DROP RECEIPT}
  @reject ~s{DROP MYSTERY S" tests/test_public.py" WRITE-FILE}

  def big do
    defs =
      for i <- 1..10 do
        ": W#{i} ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ;"
      end

    calls = for i <- 1..10, do: ~s{S" app/f#{i}.py" S" app/f#{i}.py" W#{i}}
    Enum.join(defs ++ calls ++ ["RUN-GATES DROP RECEIPT"], " ")
  end

  def workloads do
    artifacts = ["src/records.py"] ++ for(i <- 1..10, do: "app/f#{i}.py") ++ ["app/a.py", "app/b.py"]

    [
      {"simple-accept", @simple, artifacts},
      {"colon-contracts", @colon, artifacts},
      {"reject-3-errors", @reject, artifacts},
      {"big-10-words", big(), artifacts}
    ]
  end

  def args(program, artifacts) do
    {program, ["read", "write", "exec"], ["**"], ["tests/*"], artifacts}
  end

  # ---- shen-erl (in-process BEAM) ----

  def bench_beam(n) do
    ebin = LdHost.Critic.beam_artifact()
    true = :code.add_patha(String.to_charlist(ebin))
    {boot_us, _} =
      if :ets.whereis(:_kl_funs_store) != :undefined do
        {0, :already_booted_by_app}
      else
        :timer.tc(fn ->
          :ok = :shen_erl_global_stores.init()
          :shen_erl_kl_primitives.set(:"*stoutput*", :standard_io)
          :shen_erl_kl_primitives.set(:"*stinput*", :standard_io)
          :ok = :shen_erl_kl_compiler.boot_shaken([:kl_kernel, :kl_validate])
          :ok = :shen_erl_kl_compiler.run_shaken([:kl_kernel, :kl_validate])
        end)
      end

    str = fn s -> {:string, String.to_charlist(s)} end
    strs = fn l -> Enum.map(l, str) end

    rows =
      for {name, program, artifacts} <- workloads() do
        {p, e, g, f, a} = args(program, artifacts)
        call = fn -> :kl_validate.validate(str.(p), strs.(e), strs.(g), strs.(f), strs.(a)) end
        call.()
        {us, _} = :timer.tc(fn -> for _ <- 1..n, do: call.() end)
        {name, us / n}
      end

    {boot_us, rows}
  end

  # ---- node (JS artifact via port round-trip) ----

  def bench_node(n) do
    server = Path.join(:code.priv_dir(:ld_host), "critic_server.mjs")
    node = System.find_executable("node")
    artifact = LdHost.Critic.js_artifact()

    {boot_us, port} =
      :timer.tc(fn ->
        port =
          Port.open({:spawn_executable, node}, [
            :binary, :exit_status, {:line, 1_048_576},
            args: [server, artifact]
          ])

        receive do
          {^port, {:data, {:eol, _ready}}} -> port
        after
          30_000 -> raise "node boot timeout"
        end
      end)

    call = fn id, {p, e, g, f, a} ->
      req = JSON.encode!(%{id: id, program: p, effects: e, globs: g, forbidden: f, artifacts: a})
      Port.command(port, req <> "\n")

      receive do
        {^port, {:data, {:eol, _line}}} -> :ok
      after
        30_000 -> raise "node call timeout"
      end
    end

    rows =
      for {name, program, artifacts} <- workloads() do
        spec = args(program, artifacts)
        call.(0, spec)
        {us, _} = :timer.tc(fn -> for i <- 1..n, do: call.(i, spec) end)
        {name, us / n}
      end

    Port.close(port)
    {boot_us, rows}
  end

  def print(label, boot_us, rows) do
    IO.puts("\n#{label}  (boot: #{Float.round(boot_us / 1000, 1)} ms)")

    for {name, us} <- rows do
      IO.puts("  #{String.pad_trailing(name, 18)} #{Float.round(us / 1.0, 1)} us/call")
    end
  end
end

n = 200
{boot, rows} = CriticBench.bench_beam(n)
CriticBench.print("shen-erl (:beam, in-process)", boot, rows)

{boot, rows} = CriticBench.bench_node(n)
CriticBench.print("ShenScript JS (:node, port round-trip)", boot, rows)
