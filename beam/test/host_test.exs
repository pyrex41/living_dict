defmodule LdHost.HostTest do
  use ExUnit.Case, async: true

  alias LdHost.Host

  defp workspace do
    tmp =
      System.tmp_dir!()
      |> Path.join("ldhost-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    tmp
  end

  defp host(ws), do: Host.new(ws, emit: fn _, _ -> :ok end)

  test "READ-FILE on a binary file returns a summary value, no decode trap" do
    ws = workspace()
    File.write!(Path.join(ws, "blob.bin"), <<0, 1, 2, 255>>)

    assert {:ok, value, %Host{}} = Host.read_file(host(ws), "blob.bin")
    assert value == "<<binary file: 4 bytes, magic 000102ff>>"
  end

  test "READ-FILE binary summary includes the printable head" do
    ws = workspace()
    File.write!(Path.join(ws, "db.sqlite"), "SQLite format 3" <> <<0, 255, 254, 253>>)

    assert {:ok, value, _} = Host.read_file(host(ws), "db.sqlite")
    assert value == "<<binary file: 19 bytes, magic 53514c69 'SQLite format 3'>>"
  end

  test "READ-FILE on utf-8 text still returns the content unchanged" do
    ws = workspace()
    File.write!(Path.join(ws, "hello.txt"), "hi there\n")

    assert {:ok, "hi there\n", _} = Host.read_file(host(ws), "hello.txt")
  end

  test "Host.new defaults allow_model_checks to false and accepts the opt" do
    ws = workspace()
    assert %Host{allow_model_checks: false} = Host.new(ws)
    assert %Host{allow_model_checks: true} = Host.new(ws, allow_model_checks: true)
  end

  test "intern_blob is idempotent" do
    ws = workspace()
    objects = Path.join(ws, "objects")
    File.mkdir_p!(objects)
    host = Host.new(ws, objects_dir: objects, emit: fn _, _ -> :ok end)
    {:ok, receipt, _} = Host.write_file(host, "hello", "a.txt")
    path = Host.object_path(objects, receipt.sha256)
    assert File.exists?(path)
    mtime = File.stat!(path).mtime
    {:ok, receipt2, _} = Host.write_file(host, "hello", "b.txt")
    assert receipt.sha256 == receipt2.sha256
    assert File.stat!(path).mtime == mtime
    {:ok, "hello", _} = Host.fetch_object(host, receipt.sha256)
  end
end
