defmodule ErlangAdkUi.TestProviderCallValid do
  @behaviour ErlangAdkUi.Auth.Provider

  @impl true
  def authorization_request do
    {:ok, "https://identity.example.test/authorize", %{"state" => "state"}}
  end

  @impl true
  def complete(_params, _flow), do: {:ok, ErlangAdkUi.TestAuthProvider.identity()}
end

defmodule ErlangAdkUi.TestProviderCallTimeout do
  @behaviour ErlangAdkUi.Auth.Provider

  @impl true
  def authorization_request, do: wait_forever()

  @impl true
  def complete(_params, _flow), do: wait_forever()

  defp wait_forever do
    receive do
      :never_sent -> {:error, :provider_unavailable}
    end
  end
end

defmodule ErlangAdkUi.TestProviderCallCrash do
  @behaviour ErlangAdkUi.Auth.Provider

  @impl true
  def authorization_request do
    Process.exit(self(), :kill)
    {:error, :provider_unavailable}
  end

  @impl true
  def complete(_params, _flow), do: authorization_request()
end

defmodule ErlangAdkUi.TestProviderCallHeap do
  @behaviour ErlangAdkUi.Auth.Provider

  @impl true
  def authorization_request, do: exhaust_heap([])

  @impl true
  def complete(_params, _flow), do: exhaust_heap([])

  defp exhaust_heap(accumulator) do
    values = Enum.map(1..2_000, &{&1, make_ref(), &1})
    exhaust_heap([values | accumulator])
  end
end

defmodule ErlangAdkUi.TestProviderCallSecretCrash do
  @behaviour ErlangAdkUi.Auth.Provider

  @impl true
  def authorization_request, do: raise("top-secret-provider-value")

  @impl true
  def complete(_params, _flow), do: authorization_request()
end

defmodule ErlangAdkUi.TestProviderCallControlled do
  @behaviour ErlangAdkUi.Auth.Provider

  @impl true
  def authorization_request, do: controlled_result()

  @impl true
  def complete(_params, _flow), do: controlled_result()

  defp controlled_result do
    owner = :persistent_term.get({__MODULE__, :owner})
    send(owner, {:provider_call_worker, self()})

    receive do
      {:release_provider_call, ^owner} ->
        {:ok, "https://identity.example.test/authorize", %{"state" => "state"}}
    end
  end
end
