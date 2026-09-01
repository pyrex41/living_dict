defmodule LdHost.Bench.PostHarvestTest do
  use ExUnit.Case

  alias LdHost.Bench.PostHarvest

  test "manifest fixes three parser replicates and graph confirmation" do
    repo = LdHost.Critic.repo_root()

    manifest =
      PostHarvest.manifest(
        repo: repo,
        out: Path.join(System.tmp_dir!(), "ld-post-harvest-test"),
        run_id: "fixed"
      )

    campaigns = manifest["campaigns"]

    assert is_binary(manifest["source"]["revision"])
    assert is_binary(manifest["source"]["dirty_diff_sha256"])

    assert Enum.map(Enum.take(campaigns, 3), & &1["id"]) == [
             "parser-r1",
             "parser-r2",
             "parser-r3"
           ]

    assert Enum.at(campaigns, 3)["id"] == "graph-confirmation"
    assert Enum.at(campaigns, 3)["tasks"] == Enum.map(1..8, &"graph-0#{&1}")
    assert Enum.all?(Enum.take(campaigns, 4), &(&1["enabled"] == true))
    assert Enum.at(campaigns, 4)["enabled"] == false
  end

  test "manifest commands run from beam and retain isolated outputs" do
    manifest =
      PostHarvest.manifest(
        repo: LdHost.Critic.repo_root(),
        out: Path.join(System.tmp_dir!(), "ld-post-harvest-test"),
        run_id: "paths"
      )

    for campaign <- manifest["campaigns"] do
      refute campaign["cwd"] == manifest["repo"]
      refute campaign["out"] == manifest["repo"]
      assert campaign["retention"] =~ "retain"
      assert List.first(campaign["command"]) == "mix"
    end
  end

  test "settings and blockers make the dry-run boundary explicit" do
    assert PostHarvest.settings()["max_episodes"] == 6
    assert PostHarvest.settings()["token_bar_fraction"] == 0.25
    assert Enum.any?(PostHarvest.blockers(), &String.contains?(&1, "used_words"))
    assert Enum.any?(PostHarvest.blockers(), &String.contains?(&1, "judge provenance"))

    manifest =
      PostHarvest.manifest(
        repo: LdHost.Critic.repo_root(),
        out: Path.join(System.tmp_dir!(), "ld-post-harvest-test"),
        run_id: "fields"
      )

    assert "unused_eligible_words" in hd(manifest["campaigns"])["required_row_fields"]
  end
end
