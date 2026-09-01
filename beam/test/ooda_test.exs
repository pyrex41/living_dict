defmodule LdHost.OODATest do
  use ExUnit.Case

  alias LdHost.OODA

  defp workspace do
    path = Path.join(System.tmp_dir!(), "ld-ooda-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, "src"))
    File.write!(Path.join(path, "src/app.py"), "def answer():\n    return 41\n")
    File.write!(Path.join(path, "README.md"), "answer docs\n")
    path
  end

  test "orients a contracted narrow workspace directly" do
    manifest = OODA.manifest(workspace(), allowed_globs: ["src/*.py"], approved_contract: true)
    assert %{route: :direct, effort: "low"} = OODA.orient(manifest)
    assert OODA.direct_context(manifest) =~ "return 41"
  end

  test "broad scope invokes research and sensitive files stay out of the manifest" do
    ws = workspace()
    File.write!(Path.join(ws, ".env"), "TOKEN=do-not-read")
    manifest = OODA.manifest(ws, allowed_globs: ["**"], approved_contract: false)
    assert OODA.orient(manifest).route in [:research, :deep_research]
    refute Enum.any?(manifest.files, &(&1.path == ".env"))
  end

  test "research tools are confined, bounded, and cite source hashes" do
    manifest = OODA.manifest(workspace(), allowed_globs: ["src/*.py"], approved_contract: true)
    budget = OODA.new_budget()

    assert {:ok, result, budget} =
             OODA.tool(manifest, "search_text", %{"query" => "answer"}, budget)

    assert [%{path: "README.md"} | _] = result.hits
    assert budget.calls_left == OODA.limits().tool_calls - 1
    assert {:error, _} = OODA.tool(manifest, "read_lines", %{"path" => "../outside"}, budget)

    hit = List.last(result.hits)

    brief = %{
      "findings" => [
        %{
          "claim" => "function exists",
          "evidence" => [%{"path" => hit.path, "sha256" => hit.sha256}]
        }
      ],
      "recommended_files" => ["src/app.py"]
    }

    assert length(OODA.validate_brief(brief, budget.evidence)["findings"]) == 1
  end

  test "symlinked files are not researchable" do
    ws = workspace()
    outside = Path.join(System.tmp_dir!(), "ld-ooda-secret-#{System.unique_integer([:positive])}")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(ws, "src/link.py"))
    manifest = OODA.manifest(ws, allowed_globs: ["src/*.py"], approved_contract: true)
    refute Enum.any?(manifest.files, &(&1.path == "src/link.py"))
  end
end
