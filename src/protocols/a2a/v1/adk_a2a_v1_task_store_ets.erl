%% @doc Bounded process-owned ETS-style A2A task store.
-module(adk_a2a_v1_task_store_ets).
-behaviour(adk_a2a_v1_task_store).
-behaviour(gen_server).

-export([start_link/0, start_link/1, stop/1, capabilities/1,
         load/1, put/2, delete/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_MAX_TASKS, 10000).
-define(DEFAULT_MAX_BYTES, 268435456).
-define(CALL_TIMEOUT, 5000).

start_link() -> start_link(#{}).
start_link(Options) when is_map(Options) ->
    gen_server:start_link(?MODULE, Options, []);
start_link(_) -> {error, invalid_a2a_task_store_options}.

stop(Store) -> gen_server:stop(Store).
capabilities(Store) -> call(Store, capabilities).
load(Store) -> call(Store, load).
put(Store, Snapshot) -> call(Store, {put, Snapshot}).
delete(Store, TaskId) -> call(Store, {delete, TaskId}).

init(Options) ->
    MaxTasks = maps:get(max_tasks, Options, ?DEFAULT_MAX_TASKS),
    MaxBytes = maps:get(max_bytes, Options, ?DEFAULT_MAX_BYTES),
    case positive(MaxTasks) andalso positive(MaxBytes) of
        true -> {ok, #{rows => #{}, bytes => 0,
                       limits => #{max_tasks => MaxTasks,
                                   max_bytes => MaxBytes}}};
        false -> {stop, invalid_a2a_task_store_options}
    end.

handle_call(capabilities, _From, State) ->
    {reply, #{contract_version => 1, durable => false,
              atomic_replace => true, limits => maps:get(limits, State)},
     State};
handle_call(load, _From, State) ->
    Rows = [Snapshot || {_Id, #{snapshot := Snapshot}} <-
                            lists:keysort(1, maps:to_list(maps:get(rows, State)))],
    {reply, {ok, Rows}, State};
handle_call({put, Snapshot0}, _From, State0) ->
    case adk_a2a_v1_task_store:prepare_snapshot(Snapshot0) of
        {ok, Snapshot, Bytes} ->
            Id = maps:get(id, Snapshot),
            Rows0 = maps:get(rows, State0),
            OldBytes = case maps:get(Id, Rows0, undefined) of
                #{bytes := Existing} -> Existing;
                undefined -> 0
            end,
            Count = case maps:is_key(Id, Rows0) of
                true -> map_size(Rows0);
                false -> map_size(Rows0) + 1
            end,
            Total = maps:get(bytes, State0) - OldBytes + Bytes,
            Limits = maps:get(limits, State0),
            case Count =< maps:get(max_tasks, Limits) andalso
                 Total =< maps:get(max_bytes, Limits) of
                true ->
                    Rows = Rows0#{Id => #{snapshot => Snapshot, bytes => Bytes}},
                    {reply, ok, State0#{rows => Rows, bytes => Total}};
                false ->
                    {reply, {error, a2a_task_store_capacity_reached}, State0}
            end;
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({delete, TaskId}, _From, State0) when is_binary(TaskId) ->
    case maps:take(TaskId, maps:get(rows, State0)) of
        {#{bytes := Bytes}, Rows} ->
            {reply, ok, State0#{rows => Rows,
                                bytes => maps:get(bytes, State0) - Bytes}};
        error -> {reply, ok, State0}
    end;
handle_call({delete, _}, _From, State) ->
    {reply, {error, invalid_a2a_task_id}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_a2a_task_store_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.
format_status(State) -> maps:with([bytes, limits], State).

positive(Value) -> is_integer(Value) andalso Value > 0.

call(Store, Request) ->
    try gen_server:call(Store, Request, ?CALL_TIMEOUT) of
        Reply -> Reply
    catch exit:_ -> {error, a2a_task_store_unavailable}
    end.
