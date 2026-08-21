%% @doc Persistence contract for A2A task snapshots.
%%
%% Snapshots never contain subscribers, worker references, principals, headers,
%% or credentials.  Adapters must atomically replace one task by id and return
%% a bounded complete snapshot set on load.
-module(adk_a2a_v1_task_store).

-export([validate_descriptor/1, prepare_snapshot/1]).

-callback capabilities(Handle :: term()) -> map().
-callback load(Handle :: term()) -> {ok, [map()]} | {error, term()}.
-callback put(Handle :: term(), Snapshot :: map()) -> ok | {error, term()}.
-callback delete(Handle :: term(), TaskId :: binary()) ->
    ok | {error, term()}.

-define(MAX_TASK_ID_BYTES, 512).
-define(MAX_SNAPSHOT_BYTES, 8388608).
-define(MAX_EVENTS, 4096).

validate_descriptor(undefined) -> {ok, undefined};
validate_descriptor({Module, Handle}) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Required = [{capabilities, 1}, {load, 1}, {put, 2}, {delete, 2}],
            case lists:all(
                   fun({Function, Arity}) ->
                           erlang:function_exported(Module, Function, Arity)
                   end, Required) of
                true -> {ok, {Module, Handle}};
                false -> {error, invalid_a2a_task_store}
            end;
        _ -> {error, invalid_a2a_task_store}
    end;
validate_descriptor(_) -> {error, invalid_a2a_task_store}.

prepare_snapshot(Snapshot) when is_map(Snapshot) ->
    Required = [id, scope, task, events, next_seq, updated_ms, terminal_at],
    case lists:sort(maps:keys(Snapshot)) =:= lists:sort(Required) andalso
         valid_snapshot_fields(Snapshot) of
        true ->
            try erlang:external_size(Snapshot) of
                Bytes when Bytes =< ?MAX_SNAPSHOT_BYTES ->
                    {ok, Snapshot, Bytes};
                _ -> {error, a2a_task_snapshot_too_large}
            catch _:_ -> {error, invalid_a2a_task_snapshot}
            end;
        false -> {error, invalid_a2a_task_snapshot}
    end;
prepare_snapshot(_) -> {error, invalid_a2a_task_snapshot}.

valid_snapshot_fields(#{id := Id, scope := Scope, task := Task,
                        events := Events, next_seq := Next,
                        updated_ms := Updated, terminal_at := Terminal}) ->
    valid_id(Id) andalso is_binary(Scope) andalso byte_size(Scope) =:= 32
    andalso is_map(Task) andalso
    adk_a2a_v1_codec:validate_task(Task) =:= {ok, Task}
    andalso is_list(Events) andalso length(Events) =< ?MAX_EVENTS
    andalso lists:all(fun valid_event/1, Events)
    andalso is_integer(Next) andalso Next > 0
    andalso is_integer(Updated) andalso Updated >= 0
    andalso (Terminal =:= undefined orelse
             (is_integer(Terminal) andalso Terminal >= 0)).

valid_event({Sequence, Payload}) when is_integer(Sequence), Sequence > 0,
                                      is_map(Payload) ->
    adk_a2a_v1_codec:validate_stream_response(Payload) =:= {ok, Payload};
valid_event(_) -> false.

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< ?MAX_TASK_ID_BYTES ->
    unicode:characters_to_binary(Value, utf8, utf8) =:= Value;
valid_id(_) -> false.
