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

  test "intern is idempotent and fetch_object returns the blob" do
    ws = workspace()
    objects = Path.join(ws, "objects")
    host = Host.new(ws, objects_dir: objects)

    sha = Host.intern(host, "payload")
    assert sha == Host.intern(host, "payload")
    assert sha == LdHost.Policy.sha256_hex("payload")

    path = Path.join([objects, String.slice(sha, 0, 2), sha])
    assert File.exists?(path)
    assert File.read!(path) == "payload"
    assert {:ok, "payload", _} = Host.fetch_object(host, sha)

    Host.intern_blob(host, "payload", sha)
    assert sha in File.ls!(Path.dirname(path))
    refute Enum.any?(File.ls!(Path.dirname(path)), &String.starts_with?(&1, ".tmp-"))

    File.write!(path, "garbage")
    assert {:trap, "missing_object", _} = Host.fetch_object(host, sha)
  end

  test "write_file interns into objects_dir" do
    ws = workspace()
    objects = Path.join(ws, "objects")
    host = Host.new(ws, objects_dir: objects)
    {:ok, receipt, _} = Host.write_file(host, "hello\n", "greet.txt")
    sha = receipt.sha256
    assert File.exists?(Path.join([objects, String.slice(sha, 0, 2), sha]))
  end
end
