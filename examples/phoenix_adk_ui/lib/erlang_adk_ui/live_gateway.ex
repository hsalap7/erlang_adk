defmodule ErlangAdkUi.LiveGateway do
  @moduledoc """
  Server-owned boundary between the authenticated Phoenix UI and ADK Live.

  A browser can select only identifiers returned by `discover/1`. The adapter
  is release configuration and is never selected from request parameters.
  Every operation receives the complete, server-side identity so adapters can
  enforce both the exact principal and capability-specific scopes.

  Subscriptions are future-only: this contract has no cursor or replay API.
  """

  alias ErlangAdkUi.Auth.Provider

  @type identity :: Provider.identity()
  @type session_id :: binary()
  @type attachment_ref :: term()
  @type credit :: %{messages: pos_integer(), bytes: pos_integer()}
  @type session :: %{
          required(:id) => session_id(),
          required(:state) => binary(),
          optional(:model) => binary(),
          optional(:latest_sequence) => non_neg_integer()
        }
  @type evaluation :: %{required(:id) => binary(), required(:label) => binary()}

  @callback discover(identity()) :: {:ok, [session()]} | {:error, atom()}
  @callback attach(identity(), session_id(), pid(), credit()) ::
              {:ok, map()} | {:error, atom() | tuple()}
  @callback detach(identity(), attachment_ref(), pid()) :: :ok | {:error, atom() | tuple()}
  @callback send_text(identity(), attachment_ref(), binary()) ::
              {:ok, pos_integer()} | {:error, atom() | tuple()}
  @callback ack(identity(), attachment_ref(), pid(), non_neg_integer()) ::
              :ok | {:error, atom() | tuple()}
  @callback observability_snapshot(identity()) :: {:ok, map()} | {:error, atom()}
  @callback list_evaluations(identity()) :: {:ok, [evaluation()]} | {:error, atom()}
  @callback evaluation_report(identity(), binary()) :: {:ok, binary()} | {:error, atom()}
  @callback compare_evaluations(identity(), binary(), binary()) ::
              {:ok, binary()} | {:error, atom()}

  def discover(identity), do: invoke(:discover, [identity])

  def attach(identity, session_id, subscriber, credit),
    do: invoke(:attach, [identity, session_id, subscriber, credit])

  def detach(identity, attachment_ref, subscriber),
    do: invoke(:detach, [identity, attachment_ref, subscriber])

  def send_text(identity, attachment_ref, text),
    do: invoke(:send_text, [identity, attachment_ref, text])

  def ack(identity, attachment_ref, subscriber, sequence),
    do: invoke(:ack, [identity, attachment_ref, subscriber, sequence])

  def observability_snapshot(identity), do: invoke(:observability_snapshot, [identity])
  def list_evaluations(identity), do: invoke(:list_evaluations, [identity])

  def evaluation_report(identity, report_id),
    do: invoke(:evaluation_report, [identity, report_id])

  def compare_evaluations(identity, baseline_id, current_id),
    do: invoke(:compare_evaluations, [identity, baseline_id, current_id])

  defp invoke(function, arguments) do
    adapter = Application.fetch_env!(:erlang_adk_ui, :live_gateway)
    apply(adapter, function, arguments)
  rescue
    _error -> {:error, :gateway_unavailable}
  catch
    _kind, _reason -> {:error, :gateway_unavailable}
  end
end
