-module(erlang_adk_session).

-export([init/0, save/2, load/1, delete/1]).

-define(TABLE, adk_sessions).

%% @doc Initialize the ETS table. Should be called by the application startup.
init() ->
    ets:new(?TABLE, [set, public, named_table, {read_concurrency, true}, {write_concurrency, true}]).

%% @doc Save memory list for a given SessionId
save(SessionId, Memory) ->
    ets:insert(?TABLE, {SessionId, Memory}),
    ok.

%% @doc Load memory list for a given SessionId. Returns empty list if not found.
load(SessionId) ->
    case ets:lookup(?TABLE, SessionId) of
        [{SessionId, Memory}] -> Memory;
        [] -> []
    end.

%% @doc Delete a session
delete(SessionId) ->
    ets:delete(?TABLE, SessionId),
    ok.
