defmodule Attest.DSL do
  @moduledoc """
  Syntactic sugar for test scripts

  Provides helpers that make test scripts more readable:

  - `subtest/2` — labelled sections with timing and pass/fail logging
  - `assert_contains/2` — check a string contains a substring
  - `assert_matches/2` — check a string matches a regex
  - `retry/2` — retry a block until it succeeds

  These are automatically available in test scripts evaluated via
  `Attest.TestScript`. For use in regular modules:

      import Attest.DSL
  """

  require Logger

  @doc """
  Run a labelled section of a test script

  Logs the section name and timing. Re-raises errors with context.

      subtest "nginx is running" do
        wait_for_unit(server, "nginx.service")
        wait_for_open_port(server, 80)
      end
  """
  @spec subtest(String.t(), (-> term())) :: term()
  def subtest(label, fun) when is_function(fun, 0) do
    Logger.info("subtest: #{label}")
    start = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      elapsed = System.monotonic_time(:millisecond) - start
      Logger.info("subtest: #{label} — passed (#{elapsed}ms)")
      result
    rescue
      e ->
        elapsed = System.monotonic_time(:millisecond) - start
        Logger.error("subtest: #{label} — failed (#{elapsed}ms): #{Exception.message(e)}")
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Assert a string contains a substring, raise with context if not

      output = succeed(machine, "cat /etc/hostname")
      assert_contains(output, "server")
  """
  @spec assert_contains(String.t(), String.t()) :: :ok
  def assert_contains(string, substring) do
    unless String.contains?(string, substring) do
      raise "expected #{inspect(String.slice(string, 0, 200))} to contain #{inspect(substring)}"
    end

    :ok
  end

  @doc """
  Assert a string matches a regex, raise with context if not

      output = succeed(machine, "uname -r")
      assert_matches(output, ~r/6\\.1/)
  """
  @spec assert_matches(String.t(), Regex.t()) :: :ok
  def assert_matches(string, regex) do
    unless Regex.match?(regex, string) do
      raise "expected #{inspect(String.slice(string, 0, 200))} to match #{inspect(regex)}"
    end

    :ok
  end

  @doc """
  Retry a block until it succeeds or exhausts attempts

  Catches exceptions and retries. Raises the last exception on failure.

      retry attempts: 10, delay: 1000 do
        succeed(machine, "curl http://server")
      end
  """
  defmacro retry(opts, do: block) do
    quote do
      Attest.DSL.__retry__(
        Keyword.get(unquote(opts), :attempts, 10),
        Keyword.get(unquote(opts), :delay, 1000),
        fn -> unquote(block) end
      )
    end
  end

  @doc false
  def __retry__(attempts, delay, fun) do
    do_retry(attempts, delay, fun, nil)
  end

  defp do_retry(0, _delay, _fun, last_error), do: raise(last_error)

  defp do_retry(remaining, delay, fun, _last_error) do
    try do
      fun.()
    rescue
      e ->
        if remaining > 1 do
          Process.sleep(delay)
          do_retry(remaining - 1, delay, fun, e)
        else
          reraise e, __STACKTRACE__
        end
    end
  end
end
