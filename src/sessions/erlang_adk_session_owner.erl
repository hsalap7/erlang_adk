%% @doc Owns the in-memory session ETS table for the lifetime of the ADK app.
%%
%% ETS tables are destroyed with their owner. Keeping ownership in a permanent
%% supervised worker prevents an agent that happened to initialize the session
%% backend from taking the table (and all sessions) down when it exits.
-module(erlang_adk_session_owner).

-behaviour(gen_server).

-export([start_link/0, ensure_table/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TABLE, adk_sessions).
-define(SERVER, ?MODULE).

start_link() ->
    case gen_server:start_link({local, ?SERVER}, ?MODULE, [], []) of
        {error, {already_started, Pid}} ->
            %% init/0 supports callers that use the ETS backend without first
            %% starting the application. Adopt that process as this supervisor's
            %% child when the application is subsequently started.
            link(Pid),
            {ok, Pid};
        Result ->
            Result
    end.

%% @doc Ensure the owner and its table exist. Concurrent callers are safe: the
%% local registration permits only one owner to win gen_server:start/4.
ensure_table() ->
    case whereis(?SERVER) of
        undefined ->
            case gen_server:start({local, ?SERVER}, ?MODULE, [], []) of
                {ok, Pid} -> call_ensure_table(Pid);
                {error, {already_started, Pid}} -> call_ensure_table(Pid);
                {error, Reason} -> {error, Reason}
            end;
        Pid ->
            call_ensure_table(Pid)
    end.

init([]) ->
    case ets:whereis(?TABLE) of
        undefined ->
            _ = create_table(),
            {ok, #{}};
        Table ->
            case ets:info(Table, owner) of
                Owner when Owner =:= self() ->
                    {ok, #{}};
                Owner ->
                    {stop, {table_owned_by_another_process, Owner}}
            end
    end.

handle_call(ensure_table, _From, State) ->
    case ets:whereis(?TABLE) of
        undefined ->
            %% A public table can be explicitly deleted by another process.
            %% Recreate it here so ownership remains with this worker.
            _ = create_table(),
            {reply, ok, State};
        Table ->
            case ets:info(Table, owner) of
                Owner when Owner =:= self() -> {reply, ok, State};
                Owner -> {reply, {error, {unexpected_table_owner, Owner}}, State}
            end
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

create_table() ->
    ets:new(?TABLE, [set, public, named_table,
                     {read_concurrency, true},
                     {write_concurrency, true}]).

call_ensure_table(Pid) ->
    try gen_server:call(Pid, ensure_table) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> ensure_table();
        exit:{normal, _} -> ensure_table()
    end.
