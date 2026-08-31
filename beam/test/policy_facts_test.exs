defmodule LdHost.PolicyFactsTest do
  use ExUnit.Case, async: true

  alias LdHost.PolicyFacts

  test "parses empty ALIASES as forbids_aliases and DEFAULTS keys" do
    ws = tmp()
    File.mkdir_p!(Path.join(ws, "app"))

    File.write!(Path.join(ws, "app/config.py"), """
    DEFAULTS = {'compatibility_mode': False, "retries": 2}
    ALIASES = {}

    def normalize(user):
        if key not in result:
            raise KeyError(key)
    """)

    File.write!(Path.join(ws, "claims.json"), "{}")

    fact = PolicyFacts.extract(ws, ["app/config.py", "claims.json"], %{})
    assert fact["path_region"] == ["app/config.py"]
    assert fact["forbids_aliases"] == true
    assert fact["must_raise_keyerror"] == true
    assert fact["defaults_keys"]["app/config.py"] == ["compatibility_mode", "retries"]
    assert fact["aliases"]["app/config.py"] == %{}
  end

  test "records a one-key rename from previous DEFAULTS" do
    ws = tmp()
    File.mkdir_p!(Path.join(ws, "app"))
    File.write!(Path.join(ws, "app/config.py"), "DEFAULTS = {'compatibility_mode': False}\nALIASES = {}\n")

    previous = %{"app/config.py" => "DEFAULTS = {'legacy_mode': False}\nALIASES = {'legacy_mode': 'compatibility_mode'}\n"}
    fact = PolicyFacts.extract(ws, ["app/config.py"], previous)
    assert fact["renames"]["app/config.py"] == %{"legacy_mode" => "compatibility_mode"}
  end

  test "persist/load round-trip and grant matching" do
    dict = tmp()
    fact = %{"path_region" => ["app/config.py"], "forbids_aliases" => true, "aliases" => %{}}
    assert :ok = PolicyFacts.persist(dict, fact)
    loaded = PolicyFacts.load(dict)
    assert length(loaded) == 1
    assert PolicyFacts.matching(loaded, ["app/config.py"]) != []
    assert PolicyFacts.matching(loaded, ["src/records.py"]) == []
  end

  test "plumbing_note only when INSTALL- words are loaded" do
    assert PolicyFacts.plumbing_note(["INSTALL-APP-CONFIG"]) =~ "PLUMBING"
    assert PolicyFacts.plumbing_note(["FOO"]) == ""
  end

  test "parse_verifier_checks pulls failed ids from JSON output" do
    raw = "noise " <> JSON.encode!(%{"checks" => [%{"id" => "alias", "passed" => false, "detail" => "legacy alias present"}]})
    [c] = PolicyFacts.parse_verifier_checks(raw)
    assert c["id"] == "alias"
    assert c["passed"] == false
  end

  test "format_diffs skips identical files and claims.json" do
    diff =
      PolicyFacts.format_diffs(
        %{"app/config.py" => "old\n", "claims.json" => "{}"},
        %{"app/config.py" => "new\n", "claims.json" => "{}"},
        ["app/config.py", "claims.json"]
      )

    assert diff =~ "PRODUCT DIFF"
    assert diff =~ "app/config.py"
    refute diff =~ "claims.json"
  end

  defp tmp do
    path = Path.join(System.tmp_dir!(), "ld-pol-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
