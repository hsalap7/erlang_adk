defmodule ErlangAdkUi.Auth.ProviderCallTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ErlangAdkUi.Auth.ProviderCall

  @fast_options [timeout_ms: 25, max_heap_words: 200_000]

  test "successful provider values are normalized inside the worker" do
    assert {:ok, "https://identity.example.test/authorize", %{"state" => "state"}} =
             ProviderCall.authorization_request(
               ErlangAdkUi.TestProviderCallValid,
               @fast_options
             )

    assert {:ok, %{subject: "alice", claims: %{}}} =
             ProviderCall.complete(
               ErlangAdkUi.TestProviderCallValid,
               %{"code" => "code"},
               %{"state" => "state"},
               @fast_options
             )
  end

  test "authorization and code exchange time out without blocking the caller" do
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :provider_unavailable} =
             ProviderCall.authorization_request(
               ErlangAdkUi.TestProviderCallTimeout,
               @fast_options
             )

    assert {:error, :provider_unavailable} =
             ProviderCall.complete(
               ErlangAdkUi.TestProviderCallTimeout,
               %{"code" => "code"},
               %{"state" => "state"},
               @fast_options
             )

    assert System.monotonic_time(:millisecond) - started_at < 500
  end

  test "an untrappable provider crash is reduced to a public error" do
    assert {:error, :provider_unavailable} =
             ProviderCall.authorization_request(
               ErlangAdkUi.TestProviderCallCrash,
               @fast_options
             )
  end

  test "a provider exceeding its heap budget is killed and reduced to a public error" do
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :provider_unavailable} =
             ProviderCall.authorization_request(
               ErlangAdkUi.TestProviderCallHeap,
               timeout_ms: 2_000,
               max_heap_words: 20_000
             )

    assert System.monotonic_time(:millisecond) - started_at < 1_500
  end

  test "provider exception text is neither returned nor logged" do
    log =
      capture_log(fn ->
        assert {:error, :provider_unavailable} =
                 ProviderCall.authorization_request(
                   ErlangAdkUi.TestProviderCallSecretCrash,
                   @fast_options
                 )
      end)

    refute log =~ "top-secret-provider-value"
  end

  test "provider worker dies when its request owner is killed" do
    key = {ErlangAdkUi.TestProviderCallControlled, :owner}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)

    caller =
      spawn(fn ->
        ProviderCall.authorization_request(
          ErlangAdkUi.TestProviderCallControlled,
          timeout_ms: 5_000,
          max_heap_words: 200_000
        )
      end)

    assert_receive {:provider_call_worker, worker}, 1_000
    Process.exit(caller, :kill)

    caller_ref = Process.monitor(caller)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, _reason}, 1_000
    assert_eventually_dead(worker)
  end

  test "shared request binaries count toward the provider heap budget" do
    large_code = :binary.copy(<<"x">>, 2_000_000)

    assert {:error, :provider_unavailable} =
             ProviderCall.complete(
               ErlangAdkUi.TestProviderCallValid,
               %{"code" => large_code},
               %{"state" => "state"},
               timeout_ms: 2_000,
               max_heap_words: 10_000
             )
  end

  defp assert_eventually_dead(pid, attempts \\ 100)

  defp assert_eventually_dead(pid, 0), do: refute(Process.alive?(pid))

  defp assert_eventually_dead(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(2)
      assert_eventually_dead(pid, attempts - 1)
    else
      :ok
    end
  end
end
