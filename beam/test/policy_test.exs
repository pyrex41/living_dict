defmodule LdHost.PolicyTest do
  use ExUnit.Case, async: true

  alias LdHost.Policy

  test "glob semantics: * and ? cross slashes (fnmatch parity)" do
    assert Policy.glob_match?("tests/test_public.py", "tests/**")
    assert Policy.glob_match?("tests/deep/nested.py", "tests/*")
    assert Policy.glob_match?("a/b/c", "**")
    refute Policy.glob_match?("src/app.py", "tests/**")
    assert Policy.glob_match?("app/config.py", "app/config.p?")
  end

  test "write_allowed reasons match the reference" do
    policy = Policy.new("/tmp", ["app/*"], ["tests/*"])
    assert Policy.write_allowed(policy, "tests/x.py") == "forbidden path: tests/x.py"
    assert Policy.write_allowed(policy, "other/x.py") == "path outside allowed change set: other/x.py"
    assert Policy.write_allowed(policy, "app/x.py") == nil
  end

  test "relative confines to workspace" do
    tmp = System.tmp_dir!() |> Path.join("ldpol-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    policy = Policy.new(tmp, ["**"], [])

    assert {:ok, "a/b.txt"} = Policy.relative(policy, "a/b.txt")
    assert {:ok, ""} = Policy.relative(policy, tmp)
    assert {:error, "path escapes workspace: ../../etc/passwd"} = Policy.relative(policy, "../../etc/passwd")
    assert {:error, _} = Policy.relative(policy, "/etc/passwd")
  end

  test "snapshot skips bookkeeping dirs and diffs changes" do
    tmp = System.tmp_dir!() |> Path.join("ldsnap-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, ".git"))
    File.mkdir_p!(Path.join(tmp, "src"))
    File.write!(Path.join(tmp, ".git/config"), "hidden")
    File.write!(Path.join(tmp, "src/a.py"), "one")

    before = Policy.snapshot(tmp)
    assert Map.keys(before) == ["src/a.py"]

    File.write!(Path.join(tmp, "src/a.py"), "two")
    File.write!(Path.join(tmp, "b.txt"), "new")
    assert Policy.changed_files(before, Policy.snapshot(tmp)) == ["b.txt", "src/a.py"]
  end
end
