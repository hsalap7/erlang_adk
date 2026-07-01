-module(erlang_adk_session_mnesia).
-export([init/0, save/2, load/1, delete/1]).

-record(adk_sessions_mnesia, {id, memory}).

%% @doc Initialize the Mnesia table. Call this if you intend to use Mnesia sessions.
init() ->
    application:ensure_all_started(mnesia),
    %% Try to change node to disc schema on the fly if it's currently ram
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    
    mnesia:create_table(adk_sessions_mnesia, [
        {attributes, record_info(fields, adk_sessions_mnesia)},
        {disc_copies, [node()]}
    ]),
    mnesia:wait_for_tables([adk_sessions_mnesia], 5000).

save(SessionId, Memory) ->
    F = fun() ->
        mnesia:write(#adk_sessions_mnesia{id = SessionId, memory = Memory})
    end,
    {atomic, _} = mnesia:transaction(F),
    ok.

load(SessionId) ->
    F = fun() ->
        mnesia:read({adk_sessions_mnesia, SessionId})
    end,
    case mnesia:transaction(F) of
        {atomic, [#adk_sessions_mnesia{memory = Memory}]} -> Memory;
        {atomic, []} -> [];
        _ -> []
    end.

delete(SessionId) ->
    F = fun() ->
        mnesia:delete({adk_sessions_mnesia, SessionId})
    end,
    {atomic, _} = mnesia:transaction(F),
    ok.
