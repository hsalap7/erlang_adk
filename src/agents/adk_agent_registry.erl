%% @doc Process registry for ADK agents.
%%
%% Agent names are kept as binaries in ETS rather than converted to atoms. This
%% makes names safe to accept from configuration or remote A2A requests without
%% consuming the VM's finite atom table.
-module(adk_agent_registry).
-behaviour(gen_server).

-export([start_link/0, lookup/1, list/0]).
-export([register_name/2, unregister_name/1, whereis_name/1, send/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TABLE, adk_agent_registry).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

lookup(Name) ->
    case whereis_name(Name) of
        undefined -> {error, not_found};
        Pid -> {ok, Pid}
    end.

list() ->
    case ets:info(?TABLE) of
        undefined -> [];
        _ -> ets:tab2list(?TABLE)
    end.

%% via-registry callbacks
register_name(Name, Pid) when is_pid(Pid) ->
    Key = normalize(Name),
    case ets:insert_new(?TABLE, {Key, Pid}) of
        true -> yes;
        false -> no
    end.

unregister_name(Name) ->
    ets:delete(?TABLE, normalize(Name)),
    ok.

whereis_name(Name) ->
    Key = normalize(Name),
    case ets:lookup(?TABLE, Key) of
        [{Key, Pid}] ->
            case is_process_alive(Pid) of
                true -> Pid;
                false ->
                    %% Delete only the stale row we observed. A replacement
                    %% process may have registered the same name concurrently.
                    ets:delete_object(?TABLE, {Key, Pid}),
                    undefined
            end;
        [] -> undefined
    end.

send(Name, Message) ->
    case whereis_name(Name) of
        undefined -> exit({badarg, {Name, Message}});
        Pid -> Pid ! Message, Pid
    end.

init([]) ->
    _ = ets:new(?TABLE, [named_table, set, public,
                         {read_concurrency, true},
                         {write_concurrency, true}]),
    {ok, #{}}.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

normalize(Name) when is_binary(Name) -> Name;
normalize(Name) when is_list(Name) -> unicode:characters_to_binary(Name);
normalize(Name) when is_atom(Name) -> atom_to_binary(Name, utf8).
