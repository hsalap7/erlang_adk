%% @doc Fail-open, metadata-only observability for Live sessions.
%%
%% Live media, text, transcripts, tool arguments/results, credentials, and
%% resumption handles are deliberately absent from this API. Operation spans
%% use the v2 observability signal path and metrics use the bounded v2 registry.
-module(adk_live_observability).

-export([validate_config/1, new/3,
         start_connect/2, finish_connect/2,
         start_receive/1, finish_receive/3,
         start_tool/3, finish_tool/3,
         lifecycle/2, media/4, tool/3, close/2]).

-type state() :: disabled | map().
-export_type([state/0]).

-spec validate_config(disabled | map()) ->
    {ok, disabled | map()} | {error, term()}.
validate_config(disabled) ->
    {ok, disabled};
validate_config(Config) when is_map(Config) ->
    Allowed = [delivery, exporters, bus, failure_policy, metrics],
    Unknown = maps:keys(Config) -- Allowed,
    Delivery = maps:get(delivery, Config, sync),
    Exporters = maps:get(exporters, Config, []),
    Bus = maps:get(bus, Config, adk_observability_bus),
    FailurePolicy = maps:get(failure_policy, Config, open),
    Metrics = maps:get(metrics, Config, adk_observability_metrics),
    case {Unknown, valid_metrics_server(Metrics),
          validate_delivery(Delivery, Exporters, Bus, FailurePolicy)} of
        {[], true, {ok, DeliveryConfig}} ->
            {ok, #{delivery => DeliveryConfig, metrics => Metrics}};
        {[_ | _], _, _} ->
            {error, {invalid_live_observability_option, hd(Unknown)}};
        {_, false, _} ->
            {error, invalid_live_observability_metrics};
        {_, _, {error, _} = Error} -> Error
    end;
validate_config(_) ->
    {error, invalid_live_observability}.

-spec new(binary(), binary(), disabled | map()) ->
    {ok, state()} | {error, term()}.
new(_SessionId, _Model, disabled) ->
    {ok, disabled};
new(SessionId, Model, #{delivery := Delivery, metrics := Metrics})
  when is_binary(SessionId), is_binary(Model) ->
    case adk_observability:new_context(
           #{<<"session_id">> => SessionId, <<"model">> => Model}) of
        {ok, Context} ->
            {ok, #{context => Context,
                   delivery => Delivery,
                   metrics => Metrics,
                   provider => <<"google">>,
                   model => Model,
                   connect_span => undefined,
                   closed => false}};
        {error, _} = Error -> Error
    end;
new(_, _, _) ->
    {error, invalid_live_observability}.

-spec start_connect(initial | reconnect, state()) -> state().
start_connect(_Phase, disabled) -> disabled;
start_connect(Phase, Obs0) ->
    Obs = finish_connect({error, superseded}, Obs0),
    Handle = safe_start_span(live_connect, client, details(Obs), Obs),
    lifecycle(Phase, Obs#{connect_span => Handle}).

-spec finish_connect(term(), state()) -> state().
finish_connect(_Status, disabled) -> disabled;
finish_connect(_Status, #{connect_span := undefined} = Obs) -> Obs;
finish_connect(Status, #{connect_span := Handle} = Obs) ->
    _ = safe_finish_span(Handle, Status, details(Obs)),
    Obs#{connect_span => undefined}.

-spec start_receive(state()) -> undefined | map().
start_receive(disabled) -> undefined;
start_receive(Obs) ->
    safe_start_span(live_receive, consumer, details(Obs), Obs).

-spec finish_receive(undefined | map(), term(), state()) -> state().
finish_receive(_Handle, _Status, disabled) -> disabled;
finish_receive(undefined, _Status, Obs) -> Obs;
finish_receive(Handle, Status, Obs) ->
    _ = safe_finish_span(Handle, Status, details(Obs)),
    Obs.

-spec start_tool(binary(), binary(), state()) -> undefined | map().
start_tool(_Name, _CallId, disabled) -> undefined;
start_tool(Name, CallId, Obs) ->
    safe_start_span(execute_tool, internal,
                    (details(Obs))#{tool => Name, call_id => CallId}, Obs).

-spec finish_tool(undefined | map(), term(), state()) -> state().
finish_tool(_Handle, _Status, disabled) -> disabled;
finish_tool(undefined, _Status, Obs) -> Obs;
finish_tool(Handle, Status, Obs) ->
    _ = safe_finish_span(Handle, Status, #{}),
    Obs.

-spec lifecycle(atom(), state()) -> state().
lifecycle(_Name, disabled) -> disabled;
lifecycle(Name, Obs) ->
    record(<<"erlang_adk.live.lifecycle.count">>, counter, 1,
           (base_labels(live_connect, Obs))#{
             <<"stream">> => atom_to_binary(Name, utf8)}, Obs),
    Obs.

-spec media(input | output, audio | video, non_neg_integer(), state()) ->
    state().
media(_Direction, _Modality, _Bytes, disabled) -> disabled;
media(Direction, Modality, Bytes, Obs)
  when is_integer(Bytes), Bytes >= 0 ->
    Stream = <<(atom_to_binary(Direction, utf8))/binary, ".",
               (atom_to_binary(Modality, utf8))/binary>>,
    Labels = (base_labels(live_receive, Obs))#{<<"stream">> => Stream},
    record(<<"erlang_adk.live.media.bytes">>, counter, Bytes, Labels, Obs),
    record(<<"erlang_adk.live.media.frames">>, counter, 1, Labels, Obs),
    Obs.

-spec tool(atom(), binary(), state()) -> state().
tool(_Outcome, _Name, disabled) -> disabled;
tool(Outcome, Name, Obs) when is_atom(Outcome), is_binary(Name) ->
    Labels = (base_labels(execute_tool, Obs))#{
               <<"gen_ai.tool.name">> => Name,
               <<"stream">> => atom_to_binary(Outcome, utf8)},
    record(<<"erlang_adk.live.tool.count">>, counter, 1, Labels, Obs),
    Obs.

-spec close(term(), state()) -> state().
close(_Status, disabled) -> disabled;
close(_Status, #{closed := true} = Obs) -> Obs;
close(Status, Obs0) ->
    Obs1 = finish_connect(Status, Obs0),
    lifecycle(closed, Obs1#{closed => true}).

validate_delivery(sync, Exporters, _Bus, FailurePolicy)
  when FailurePolicy =:= open; FailurePolicy =:= closed ->
    case adk_observability:validate_exporters(Exporters) of
        ok -> {ok, #{delivery => sync, exporters => Exporters}};
        {error, _} = Error -> Error
    end;
validate_delivery(async, [], Bus, FailurePolicy)
  when (is_atom(Bus) orelse is_pid(Bus)),
       (FailurePolicy =:= open orelse FailurePolicy =:= closed) ->
    {ok, #{delivery => async, bus => Bus,
           failure_policy => FailurePolicy}};
validate_delivery(async, _Exporters, _Bus, _FailurePolicy) ->
    {error, live_observability_async_exporters_belong_to_bus};
validate_delivery(_, _, _, _) ->
    {error, invalid_live_observability_delivery}.

valid_metrics_server(undefined) -> true;
valid_metrics_server(Server) -> is_atom(Server) orelse is_pid(Server).

details(Obs) ->
    #{provider => maps:get(provider, Obs),
      request_model => maps:get(model, Obs)}.

base_labels(Operation, Obs) ->
    #{<<"gen_ai.operation.name">> => atom_to_binary(Operation, utf8),
      <<"gen_ai.provider.name">> => maps:get(provider, Obs),
      <<"gen_ai.request.model">> => maps:get(model, Obs)}.

safe_start_span(Operation, Kind, Details, Obs) ->
    try adk_observability:start_span(
          Operation, Kind, maps:get(context, Obs), Details,
          maps:get(delivery, Obs)) of
        {ok, Handle} -> Handle;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

safe_finish_span(undefined, _Status, _Details) -> ok;
safe_finish_span(Handle, Status, Details) ->
    try adk_observability:finish_span(Handle, Status, Details) of
        _ -> ok
    catch
        _:_ -> ok
    end.

record(_Name, _Type, _Value, _Labels, #{metrics := undefined}) -> ok;
record(Name, Type, Value, Labels, #{metrics := Server}) ->
    try adk_observability_metrics:record(
          Server, Name, Type, Value, Labels) of
        _ -> ok
    catch
        _:_ -> ok
    end.
