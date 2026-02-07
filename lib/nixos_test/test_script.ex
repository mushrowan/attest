defmodule NixosTest.TestScript do
  @moduledoc """
  Evaluates elixir test scripts with machine bindings

  Test scripts are plain elixir code that receive bindings for each
  machine (by name), plus `driver` and `start_all`. This mirrors
  the python driver's `exec(test_script, symbols)` approach.

  ## Example test script

      start_all.()
      server |> NixosTest.wait_for_unit("nginx.service")
      client |> NixosTest.succeed("curl http://server")
  """

  alias NixosTest.Driver

  @doc """
  Evaluate an elixir string as a test script

  Injects bindings for each machine name, plus `driver` and `start_all`.
  Returns the result of the last expression.
  """
  @spec eval_string(String.t(), GenServer.server()) :: term()
  def eval_string(code, driver) do
    bindings = build_bindings(driver)
    {result, _bindings} = Code.eval_string(code, bindings)
    result
  end

  @doc """
  Evaluate an elixir file as a test script

  Same as `eval_string/2` but reads the code from a file.
  """
  @spec eval_file(String.t(), GenServer.server()) :: term()
  def eval_file(path, driver) do
    code = File.read!(path)
    eval_string(code, driver)
  end

  defp build_bindings(driver) do
    # get all machines from the driver
    machine_bindings =
      case :sys.get_state(driver) do
        %{machines: machines} ->
          Enum.map(machines, fn {name, pid} ->
            {String.to_atom(name), pid}
          end)
      end

    start_all_fn = fn -> Driver.start_all(driver) end

    [{:driver, driver}, {:start_all, start_all_fn} | machine_bindings]
  end
end
