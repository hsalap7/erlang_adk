defmodule ErlangAdkUi.TestLiveTransport do
  @moduledoc false

  @behaviour :adk_live_transport
  use GenServer

  @impl true
  def open(owner, %{test_pid: test_pid}) when is_pid(owner) and is_pid(test_pid),
    do: GenServer.start_link(__MODULE__, {owner, test_pid})

  def open(_owner, _options), do: {:error, :invalid_test_transport_options}

  @impl true
  def send(handle, frame) when is_pid(handle) and is_binary(frame),
    do: GenServer.call(handle, {:send, frame})

  def send(_handle, _frame), do: {:error, :invalid_frame}

  @impl true
  def close(handle, reason) when is_pid(handle) do
    GenServer.call(handle, {:close, reason})
  catch
    :exit, _reason -> :ok
  end

  def close(_handle, _reason), do: :ok

  def inject(handle, payload) when is_pid(handle) and is_map(payload),
    do: GenServer.cast(handle, {:inject, Jason.encode!(payload)})

  @impl true
  def init({owner, test_pid}) do
    Kernel.send(self(), :connected)
    Kernel.send(test_pid, {:test_live_transport, :opened, self()})
    {:ok, %{owner: owner, test_pid: test_pid}}
  end

  @impl true
  def handle_call({:send, frame}, _from, state) do
    Kernel.send(state.test_pid, {:test_live_transport, :sent, self(), frame})
    {:reply, :ok, state}
  end

  def handle_call({:close, reason}, _from, state) do
    Kernel.send(state.test_pid, {:test_live_transport, :closed, self(), reason})
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast({:inject, frame}, state) do
    Kernel.send(state.owner, {:adk_live_transport, self(), {:frame, frame}})
    {:noreply, state}
  end

  @impl true
  def handle_info(:connected, state) do
    Kernel.send(state.owner, {:adk_live_transport, self(), :connected})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
