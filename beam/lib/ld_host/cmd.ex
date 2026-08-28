defmodule LdHost.Cmd do
  @moduledoc """
  Bounded shell execution for gates: run a command, capture merged output,
  enforce a wall-clock timeout. On timeout the shell's OS pid is killed;
  grandchildren that double-fork can linger (documented limitation, same
  class as the Python harness's process-group caveat).
  """

  @max_output 65_536

  @doc "Run `sh -lc command` in cwd. Returns %{output, returncode, timed_out}."
  def sh(command, cwd, timeout_ms) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["-lc", command],
        cd: cwd
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    collect(port, os_pid, [], timeout_ms)
  end

  defp collect(port, os_pid, acc, timeout_ms) do
    started = System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, chunk}} ->
        elapsed = System.monotonic_time(:millisecond) - started
        collect(port, os_pid, [acc, chunk], max(timeout_ms - elapsed, 0))

      {^port, {:exit_status, code}} ->
        %{output: truncate(acc), returncode: code, timed_out: false}
    after
      timeout_ms ->
        if os_pid, do: System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
        safe_close(port)
        %{output: truncate(acc), returncode: nil, timed_out: true}
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp truncate(iodata) do
    out = IO.iodata_to_binary(iodata)

    out =
      if byte_size(out) > @max_output do
        binary_part(out, byte_size(out) - @max_output, @max_output)
      else
        out
      end

    # Command output is arbitrary bytes; downstream it lands in ledgers,
    # gate feedback, and planner requests — all JSON. Scrub once here.
    if String.valid?(out), do: out, else: String.replace_invalid(out)
  end
end
