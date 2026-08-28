defmodule LdHost.CLITest do
  use ExUnit.Case, async: true

  alias LdHost.CLI

  describe "parse_truthy/1 (LD_ALLOW_MODEL_CHECKS)" do
    test "truthy values" do
      assert CLI.parse_truthy("1") == true
      assert CLI.parse_truthy("true") == true
      assert CLI.parse_truthy("TRUE") == true
      assert CLI.parse_truthy(" true ") == true
    end

    test "everything else is nil so run_opts drops it" do
      assert CLI.parse_truthy(nil) == nil
      assert CLI.parse_truthy("") == nil
      assert CLI.parse_truthy("0") == nil
      assert CLI.parse_truthy("false") == nil
      assert CLI.parse_truthy("yes") == nil
    end
  end

  describe "run_opts/2" do
    test "threads allow_model_checks and dictionary_dir (LD_DICTIONARY) extras" do
      opts =
        CLI.run_opts(System.tmp_dir!(),
          allow_model_checks: true,
          dictionary_dir: "/some/dictionary"
        )

      assert opts[:allow_model_checks] == true
      assert opts[:dictionary_dir] == "/some/dictionary"
    end

    test "nil extras are dropped, keeping run defaults" do
      opts = CLI.run_opts(System.tmp_dir!(), allow_model_checks: nil, dictionary_dir: nil)

      refute Keyword.has_key?(opts, :allow_model_checks)
      refute Keyword.has_key?(opts, :dictionary_dir)
    end

    test "env-shaped composition: truthy env turns the mode on, unset leaves it off" do
      on = CLI.run_opts(System.tmp_dir!(), allow_model_checks: CLI.parse_truthy("1"))
      off = CLI.run_opts(System.tmp_dir!(), allow_model_checks: CLI.parse_truthy(nil))

      assert on[:allow_model_checks] == true
      refute Keyword.has_key?(off, :allow_model_checks)
    end
  end
end
